import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';

import 'chain_access.dart';
import 'http_json.dart';

/// The endpoints the testnet implementation calls, named so the decoding
/// of each answer can be tested apart from the transport.
enum TestnetCall { fetch, chainInfo, txStatus, proof, spent, unspentAll, arcTx }

/// The chain through ARC and WhatsOnChain, for BSV testnet: a broadcast
/// goes to ARC in the extended format (each input with the output it
/// spends, so ARC validates without the parents), and a fetch, the height,
/// a transaction's status and an address's outputs come from
/// WhatsOnChain.
///
/// ARC parses a scriptSig only up to [scriptSigLimit] bytes (1,636,802,
/// measured on localnet), so a transaction over it is refused here, before
/// anything is sent, naming the input: production witnesses go through a
/// node instead.
class TestnetChain implements ChainAccess {
  final Uri arcUrl;
  final Uri wocUrl;
  final int scriptSigLimit;
  final BoundedHttp _http;

  /// Transactions seen, so a broadcast finds the outputs it spends without
  /// fetching them again.
  final _known = <String, Transaction>{};

  static const acceptedStatuses = {'SEEN_ON_NETWORK', 'ACCEPTED_BY_NETWORK', 'MINED', 'CONFIRMED'};

  TestnetChain({
    required this.arcUrl,
    required this.wocUrl,
    this.scriptSigLimit = 1636802,
    Duration timeout = const Duration(seconds: 30),
    int retries = 3,
  }) : _http = BoundedHttp(timeout: timeout, retries: retries);

  @override
  String get name => 'testnet (ARC at $arcUrl, WhatsOnChain at $wocUrl)';

  String get _woc => 'WhatsOnChain at $wocUrl';
  String get _arc => 'ARC at $arcUrl';

  /// What [call]'s answer means. The whole of the endpoints' untrusted
  /// input passes through here, so a test can feed it anything: the
  /// outcome is a value, a [ChainError] or a [BroadcastRefusal].
  static dynamic decode(TestnetCall call, String endpoint, int status, String body, {String? txid}) {
    switch (call) {
      case TestnetCall.fetch:
        if (status == 404) return null;
        if (status != 200) throw ChainError(endpoint, 'answered $status to a transaction fetch: ${_short(body)}');
        final List<int> bytes;
        try {
          bytes = hex.decode(body.trim());
        } catch (_) {
          throw ChainError(endpoint, 'returned something other than hex for transaction $txid');
        }
        return checkFetched(endpoint, txid!, bytes);
      case TestnetCall.chainInfo:
        final j = _json(endpoint, status, body);
        final blocks = j['blocks'];
        if (blocks is! int || blocks < 0) throw ChainError(endpoint, 'chain/info has no height');
        return blocks;
      case TestnetCall.txStatus:
        if (status == 404) return null;
        final j = _json(endpoint, status, body);
        final confirmations = j['confirmations'];
        if (confirmations == null) return null;
        if (confirmations is! int) throw ChainError(endpoint, 'tx/hash returned confirmations that are not a number');
        if (confirmations < 1) return null;
        final height = j['blockheight'];
        if (height is! int || height < 0) throw ChainError(endpoint, 'tx/hash returned a mined transaction without its height');
        return height;
      case TestnetCall.proof:
        // 404, or an empty list: not mined yet. WhatsOnChain answers a
        // list of proofs, one a block the transaction is in; a reorg can
        // briefly leave two, and the last is the newest
        if (status == 404) return null;
        if (status != 200) throw ChainError(endpoint, 'answered $status to a merkle proof: ${_short(body)}');
        final dynamic j;
        try {
          j = jsonDecode(body);
        } catch (_) {
          throw ChainError(endpoint, 'answered a merkle proof with a body that is not JSON: ${_short(body)}');
        }
        if (j == null) return null;
        final proof = j is List ? (j.isEmpty ? null : j.last) : j;
        if (proof == null) return null;
        return TxPlace.fromTsc(endpoint, txid!, proof);
      case TestnetCall.spent:
        // 200 with the spending transaction: spent; 404: nothing spends it,
        // or nothing to spend, which the caller settles with a fetch
        if (status == 404) return false;
        if (status != 200) throw ChainError(endpoint, 'answered $status to a spent lookup: ${_short(body)}');
        final j = _json(endpoint, status, body);
        final spender = j['txid'];
        if (spender is! String || !_isTxid(spender)) throw ChainError(endpoint, 'a spent lookup returned no spending txid');
        return true;
      case TestnetCall.unspentAll:
        final j = _json(endpoint, status, body);
        final result = j['result'];
        if (result is! List) throw ChainError(endpoint, 'unspent/all returned no result list');
        final out = <UnspentOutput>[];
        for (final u in result) {
          if (u is! Map<String, dynamic>) throw ChainError(endpoint, 'unspent/all returned an entry that is not an output');
          final id = u['tx_hash'], pos = u['tx_pos'], value = u['value'];
          if (id is! String || !_isTxid(id) || pos is! int || pos < 0 || value is! int || value < 0) {
            throw ChainError(endpoint, 'unspent/all returned an output it did not describe');
          }
          if (u['isSpentInMempoolTx'] == true) continue;
          // a mined output's block height; 0, or unconfirmed, while unmined
          final h = u['height'];
          final mined = u['status'] != 'unconfirmed' && h is int && h > 0;
          out.add(UnspentOutput(id, pos, BigInt.from(value), height: mined ? h : null));
        }
        return out;
      case TestnetCall.arcTx:
        final dynamic j;
        try {
          j = jsonDecode(body);
        } catch (_) {
          throw ChainError(endpoint, 'answered $status with a body that is not JSON: ${_short(body)}');
        }
        if (j is! Map<String, dynamic>) throw ChainError(endpoint, 'answered $status with something other than a status');
        final txStatus = j['txStatus'];
        if (status == 200 && txStatus is String && acceptedStatuses.contains(txStatus)) {
          final id = j['txid'];
          if (id is String && id != txid) throw ChainError(endpoint, 'accepted $id when $txid was sent');
          return txStatus;
        }
        // Anything short of a node holding it is not acceptance: ARC with no
        // connected peers stores the transaction and answers STORED.
        final words = [j['title'], j['detail'], j['extraInfo']].whereType<String>().where((s) => s.isNotEmpty).join('; ');
        throw BroadcastRefusal(endpoint, words.isEmpty ? 'status $status' : words,
            status: txStatus is String ? txStatus : '$status');
    }
  }

  static Map<String, dynamic> _json(String endpoint, int status, String body) {
    if (status != 200) throw ChainError(endpoint, 'answered $status: ${_short(body)}');
    final dynamic j;
    try {
      j = jsonDecode(body);
    } catch (_) {
      throw ChainError(endpoint, 'answered with a body that is not JSON: ${_short(body)}');
    }
    if (j is! Map<String, dynamic>) throw ChainError(endpoint, 'answered with something other than a JSON object');
    return j;
  }

  static String _short(String s) => s.length > 120 ? '${s.substring(0, 120)}...' : s;
  static bool _isTxid(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

  Future<dynamic> _get(TestnetCall call, String path, {String? txid}) async {
    final uri = Uri.parse('${wocUrl.toString().replaceAll(RegExp(r'/$'), '')}/$path');
    final reply = await _http.send(_woc, uri);
    return decode(call, _woc, reply.status, reply.body, txid: txid);
  }

  @override
  Future<Transaction?> fetch(String txid) async {
    final cached = _known[txid];
    if (cached != null) return cached;
    final tx = await _get(TestnetCall.fetch, 'tx/$txid/hex', txid: txid) as Transaction?;
    if (tx != null) _known[txid] = tx;
    return tx;
  }

  @override
  Future<int> height() async => await _get(TestnetCall.chainInfo, 'chain/info') as int;

  @override
  Future<int?> minedHeight(String txid) async => await _get(TestnetCall.txStatus, 'tx/hash/$txid') as int?;

  @override
  Future<TxPlace?> placeOf(String txid) async => await _get(TestnetCall.proof, 'tx/$txid/proof/tsc', txid: txid) as TxPlace?;

  @override
  Future<bool> unspent(String txid, int vout) async {
    if (await _get(TestnetCall.spent, 'tx/$txid/$vout/spent') as bool) return false;
    final tx = await fetch(txid);
    return tx != null && vout < tx.outputs.length;
  }

  @override
  Future<List<UnspentOutput>> unspentOf(Address address) async =>
      await _get(TestnetCall.unspentAll, 'address/${address.toBase58()}/unspent/all') as List<UnspentOutput>;

  /// The input of [tx], if any, whose scriptSig ARC cannot parse.
  int? overLimit(Transaction tx) {
    for (int i = 0; i < tx.inputs.length; i++) {
      final s = tx.inputs[i].script;
      if (s != null && s.buffer.length > scriptSigLimit) return i;
    }
    return null;
  }

  @override
  Future<String> broadcast(Transaction tx) async {
    final over = overLimit(tx);
    if (over != null) {
      throw BroadcastRefusal(_arc,
          'input $over carries a scriptSig of ${tx.inputs[over].script!.buffer.length} bytes, over ARC\'s parse limit of $scriptSigLimit');
    }
    final ef = await extended(tx);
    final uri = Uri.parse('${arcUrl.toString().replaceAll(RegExp(r'/$'), '')}/tx');
    final reply = await _http.send(_arc, uri,
        method: 'POST',
        headers: {'content-type': 'application/json', 'X-WaitFor': 'SEEN_ON_NETWORK', 'X-MaxTimeout': '30'},
        body: jsonEncode({'rawTx': hex.encode(ef)}));
    final status = decode(TestnetCall.arcTx, _arc, reply.status, reply.body, txid: tx.id) as String;
    _known[tx.id] = tx;
    return status;
  }

  /// [tx] in Extended Format (BRC-30): each input followed by the value and
  /// locking script it spends, fetched when not already known.
  Future<List<int>> extended(Transaction tx) async {
    final raw = hex.decode(tx.serialize());
    final out = <int>[...raw.sublist(0, 4), 0, 0, 0, 0, 0, 0xef, ..._varint(tx.inputs.length)];
    for (final i in tx.inputs) {
      final parent = await fetch(i.prevTxnId);
      if (parent == null) throw ChainError(_woc, 'does not know ${i.prevTxnId}, which the transaction spends');
      if (i.prevTxnOutputIndex >= parent.outputs.length) {
        throw ChainError(_woc, '${i.prevTxnId} has no output ${i.prevTxnOutputIndex}, which the transaction spends');
      }
      final spent = parent.outputs[i.prevTxnOutputIndex];
      final value = ByteData(8)..setUint64(0, spent.satoshis.toInt(), Endian.little);
      out
        ..addAll(i.serialize())
        ..addAll(value.buffer.asUint8List())
        ..addAll(_varint(spent.script.buffer.length))
        ..addAll(spent.script.buffer);
    }
    out.addAll(_varint(tx.outputs.length));
    for (final o in tx.outputs) {
      out.addAll(o.serialize());
    }
    out.addAll(raw.sublist(raw.length - 4));
    return out;
  }

  /// Makes [tx] known, so a broadcast spending it needs no fetch.
  void remember(Transaction tx) => _known[tx.id] = tx;

  static List<int> _varint(int n) {
    if (n < 0xfd) return [n];
    if (n <= 0xffff) return [0xfd, n & 0xff, n >> 8];
    return [0xfe, n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff];
  }

  void close() => _http.close();
}
