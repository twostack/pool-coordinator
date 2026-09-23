import 'package:dartsv/dartsv.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// An endpoint that did not answer, answered nothing usable, or answered
/// something that does not parse. The endpoint is named so an operator
/// reading the status knows which of the node, ARC or WhatsOnChain to look
/// at; the reason is the endpoint's own text or the parse failure.
class ChainError implements Exception {
  final String endpoint;
  final String reason;
  const ChainError(this.endpoint, this.reason);
  @override
  String toString() => '$endpoint: $reason';
}

/// The chain would not take a transaction. The status is what the endpoint
/// said (the node's error, ARC's txStatus), and the reason its sentence.
class BroadcastRefusal implements Exception {
  final String endpoint;
  final String reason;
  final String? status;
  const BroadcastRefusal(this.endpoint, this.reason, {this.status});
  @override
  String toString() => '$endpoint refused the transaction${status == null ? '' : ' ($status)'}: $reason';
}

/// One unspent output at an address, as the top-up scan finds it.
class UnspentOutput {
  final String txid;
  final int vout;
  final BigInt satoshis;
  const UnspentOutput(this.txid, this.vout, this.satoshis);

  String get outpoint => '$txid:$vout';

  @override
  bool operator ==(Object other) => other is UnspentOutput && other.txid == txid && other.vout == vout && other.satoshis == satoshis;
  @override
  int get hashCode => Object.hash(txid, vout, satoshis);
  @override
  String toString() => '$outpoint ($satoshis sat)';
}

/// What the server needs from the chain, and nothing else: it fetches the
/// genesis and a deposit's covenant, reads the height a deposit's refund is
/// measured against, publishes rounds, and asks whether a stored round is
/// mined and whether a covenant is still unspent. The two implementations
/// (the localnet node's RPC, and ARC with WhatsOnChain for testnet) answer
/// the same questions, so the server never knows which chain it is on.
///
/// Every answer is untrusted: a fetched transaction is parsed as the ledger
/// parses one and its txid checked against the one asked for, and anything
/// that does not parse is a [ChainError] naming the endpoint, never a crash.
/// Every call is bounded by the implementation's timeout and retries.
abstract class ChainAccess {
  /// A name for messages: which chain, at which endpoint.
  String get name;

  /// The transaction with [txid], or null when the chain does not know it.
  Future<Transaction?> fetch(String txid);

  /// The current block height.
  Future<int> height();

  /// Publishes [tx]. Returns the endpoint's acceptance status; throws
  /// [BroadcastRefusal] when the chain would not take it and [ChainError]
  /// when the endpoint could not be asked.
  Future<String> broadcast(Transaction tx);

  /// The height [txid] was mined at, or null when it is unknown or still
  /// unconfirmed.
  Future<int?> minedHeight(String txid);

  /// Whether output [vout] of [txid] is unspent. False when the transaction
  /// is unknown, since nothing can be spent from it.
  Future<bool> unspent(String txid, int vout);

  /// The unspent outputs paying [address], which is how a wallet notices
  /// a top-up and a change output that came back.
  Future<List<UnspentOutput>> unspentOf(Address address);
}

/// The checks every implementation applies to a transaction an endpoint
/// returned: it parses as the ledger parses one, and it is the transaction
/// that was asked for.
Transaction checkFetched(String endpoint, String txid, List<int> bytes) {
  final Transaction tx;
  try {
    tx = ShieldedLedger.parse(bytes);
  } catch (e) {
    throw ChainError(endpoint, 'the bytes returned for $txid are not a transaction ($e)');
  }
  if (tx.id != txid) throw ChainError(endpoint, 'asked for $txid and got ${tx.id}');
  return tx;
}
