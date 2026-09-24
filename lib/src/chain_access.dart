import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
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

/// Where a mined transaction sits: the hash of its block, its index there
/// and its merkle branch, hashes in the display order a txid is printed in,
/// from the leaf up. A wallet checks the branch against a header of its
/// own; the server only passes it on.
class TxPlace {
  final String blockHash;
  final int index;
  final List<String> branch;
  const TxPlace(this.blockHash, this.index, this.branch);

  /// The merkle root [branch] computes for [txid] at [index], display order.
  static String rootOf(String txid, int index, List<String> branch) {
    var cur = hex.decode(txid).reversed.toList();
    var i = index;
    for (final node in branch) {
      final other = hex.decode(node).reversed.toList();
      cur = _hash2(i.isEven ? cur : other, i.isEven ? other : cur);
      i >>= 1;
    }
    return hex.encode(cur.reversed.toList());
  }

  /// The branch of the transaction at [index] in a block of [txids], the
  /// way a block's merkle tree pairs them: the last of an odd level is
  /// paired with itself.
  static List<String> branchFor(List<String> txids, int index) {
    if (index < 0 || index >= txids.length) throw RangeError.index(index, txids, 'index');
    var level = [for (final t in txids) hex.decode(t).reversed.toList()];
    var i = index;
    final branch = <String>[];
    while (level.length > 1) {
      final sib = i ^ 1 < level.length ? level[i ^ 1] : level[i];
      branch.add(hex.encode(sib.reversed.toList()));
      level = [for (int k = 0; k < level.length; k += 2) _hash2(level[k], k + 1 < level.length ? level[k + 1] : level[k])];
      i >>= 1;
    }
    return branch;
  }

  /// A proof in the TSC format the node's `getmerkleproof2` and
  /// WhatsOnChain's `proof/tsc` answer with: `index`, `txOrId`, `target`
  /// (the block hash) and `nodes`, where `*` stands for the working hash
  /// itself (the last transaction of an odd level). Untrusted: anything
  /// else is a [ChainError].
  static TxPlace fromTsc(String endpoint, String txid, Object? json) {
    if (json is! Map<String, dynamic>) throw ChainError(endpoint, 'a merkle proof is not a JSON object');
    final index = json['index'], target = json['target'], nodes = json['nodes'], of = json['txOrId'];
    if (index is! int || index < 0 || index > 0xffffffff) throw ChainError(endpoint, 'a merkle proof has no index');
    if (target is! String || !_isHash(target)) throw ChainError(endpoint, 'a merkle proof names no block');
    if (of is String && of.length == 64 && of != txid) throw ChainError(endpoint, 'a merkle proof for $txid is of $of');
    if (nodes is! List || nodes.length > PoolMessage.maxBranch) throw ChainError(endpoint, 'a merkle proof has no nodes');
    var cur = txid;
    var i = index;
    final branch = <String>[];
    for (final n in nodes) {
      if (n is! String || (n != '*' && !_isHash(n))) throw ChainError(endpoint, 'a merkle proof has a node that is not a hash');
      final node = n == '*' ? cur : n;
      branch.add(node);
      cur = rootOf(cur, i & 1, [node]);
      i >>= 1;
    }
    return TxPlace(target, index, branch);
  }

  static List<int> _hash2(List<int> a, List<int> b) =>
      crypto.sha256.convert(crypto.sha256.convert([...a, ...b]).bytes).bytes;

  static bool _isHash(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);
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

  /// Where [txid] was mined: its block, index and merkle branch, or null
  /// when it is unknown or not yet mined. A wallet proves a round from it.
  Future<TxPlace?> placeOf(String txid);

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
