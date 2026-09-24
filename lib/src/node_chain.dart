import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';

import 'chain_access.dart';
import 'http_json.dart';

/// The RPC methods the node implementation calls, named so the decoding
/// of each answer can be tested apart from the transport.
enum NodeCall { fetch, height, broadcast, mined, block, proof, txout, validate, unspent }

/// The node's own refusal of a call, as its JSON-RPC error.
class _RpcError implements Exception {
  final int code;
  final String message;
  const _RpcError(this.code, this.message);
}

/// The chain through a node's JSON-RPC, as ../localnet runs one: a
/// broadcast is `sendrawtransaction`, a fetch `getrawtransaction`, the
/// height `getblockcount`, mined-ness the verbose `getrawtransaction`, an
/// output's state `gettxout`, and an address's outputs `listunspent` on
/// the address imported as watch-only. The node has no scriptSig limit,
/// which is why production witnesses go this way.
class NodeChain implements ChainAccess {
  final Uri rpcUrl;
  final String user;
  final String password;
  final BoundedHttp _http;
  final _watched = <String>{};

  NodeChain({
    required this.rpcUrl,
    required this.user,
    required this.password,
    Duration timeout = const Duration(seconds: 30),
    int retries = 3,
  }) : _http = BoundedHttp(timeout: timeout, retries: retries);

  @override
  String get name => 'the node at $rpcUrl';

  Future<dynamic> _rpc(NodeCall call, String method, List<dynamic> params) async {
    final reply = await _http.send(name, rpcUrl,
        method: 'POST',
        headers: {
          'authorization': 'Basic ${base64.encode(utf8.encode('$user:$password'))}',
          'content-type': 'application/json',
        },
        body: jsonEncode({'jsonrpc': '1.0', 'id': method, 'method': method, 'params': params}));
    return decodeEnvelope(name, reply.status, reply.body);
  }

  /// The result of a JSON-RPC answer, or an [_RpcError] when the node
  /// refused the call, or a [ChainError] when the body is not an answer.
  static dynamic decodeEnvelope(String endpoint, int status, String body) {
    final dynamic json;
    try {
      json = jsonDecode(body);
    } catch (e) {
      throw ChainError(endpoint, 'answered $status with a body that is not JSON');
    }
    if (json is! Map<String, dynamic>) throw ChainError(endpoint, 'answered $status with a body that is not a JSON-RPC answer');
    final error = json['error'];
    if (error != null) {
      if (error is Map<String, dynamic> && error['code'] is int && error['message'] is String) {
        throw _RpcError(error['code'] as int, error['message'] as String);
      }
      throw ChainError(endpoint, 'answered $status with an error it did not describe: $error');
    }
    if (status != 200) throw ChainError(endpoint, 'answered $status without an error');
    if (!json.containsKey('result')) throw ChainError(endpoint, 'answered without a result');
    return json['result'];
  }

  /// What [call]'s answer [body] means, as the methods below use it. This
  /// is the whole of the node's untrusted input, in one place a test can
  /// feed anything to: the outcome is a value, a [ChainError] or a
  /// [BroadcastRefusal], and nothing else.
  static dynamic decode(NodeCall call, String endpoint, int status, String body, {String? txid}) {
    final dynamic result;
    try {
      result = decodeEnvelope(endpoint, status, body);
    } on _RpcError catch (e) {
      switch (call) {
        case NodeCall.fetch:
        case NodeCall.mined:
        case NodeCall.block:
          if (e.code == -5) return null;
          throw ChainError(endpoint, 'refused $call: ${e.message} (${e.code})');
        case NodeCall.broadcast:
          throw BroadcastRefusal(endpoint, e.message, status: '${e.code}');
        default:
          throw ChainError(endpoint, 'refused $call: ${e.message} (${e.code})');
      }
    }
    switch (call) {
      case NodeCall.fetch:
        if (result == null) return null;
        if (result is! String) throw ChainError(endpoint, 'getrawtransaction returned something other than hex');
        final List<int> bytes;
        try {
          bytes = hex.decode(result);
        } catch (_) {
          throw ChainError(endpoint, 'getrawtransaction returned something other than hex');
        }
        return checkFetched(endpoint, txid!, bytes);
      case NodeCall.height:
        if (result is! int || result < 0) throw ChainError(endpoint, 'getblockcount returned something other than a height');
        return result;
      case NodeCall.broadcast:
        if (result is! String) throw ChainError(endpoint, 'sendrawtransaction returned something other than a txid');
        if (result != txid) throw ChainError(endpoint, 'sendrawtransaction of $txid returned txid $result');
        return 'node';
      case NodeCall.mined:
        if (result == null) return null;
        if (result is! Map<String, dynamic>) throw ChainError(endpoint, 'getrawtransaction returned something other than a transaction');
        final confirmations = result['confirmations'];
        if (confirmations == null) return null;
        if (confirmations is! int) throw ChainError(endpoint, 'getrawtransaction returned confirmations that are not a number');
        if (confirmations < 1) return null;
        final height = result['blockheight'];
        if (height is! int || height < 0) throw ChainError(endpoint, 'getrawtransaction returned a mined transaction without its height');
        return height;
      case NodeCall.block:
        if (result == null) return null;
        if (result is! Map<String, dynamic>) throw ChainError(endpoint, 'getrawtransaction returned something other than a transaction');
        final confirmations = result['confirmations'];
        if (confirmations == null || (confirmations is int && confirmations < 1)) return null;
        final block = result['blockhash'];
        if (block is! String || !_isTxid(block)) throw ChainError(endpoint, 'getrawtransaction returned a mined transaction without its block');
        return block;
      case NodeCall.proof:
        return TxPlace.fromTsc(endpoint, txid!, result);
      case NodeCall.txout:
        if (result == null) return false;
        if (result is! Map<String, dynamic>) throw ChainError(endpoint, 'gettxout returned something other than an output');
        return true;
      case NodeCall.validate:
        if (result is! Map<String, dynamic>) throw ChainError(endpoint, 'validateaddress returned something other than a map');
        if (result['isvalid'] != true) throw ChainError(endpoint, 'validateaddress does not accept the address');
        return result['ismine'] == true || result['iswatchonly'] == true;
      case NodeCall.unspent:
        if (result is! List) throw ChainError(endpoint, 'listunspent returned something other than a list');
        final out = <UnspentOutput>[];
        for (final u in result) {
          if (u is! Map<String, dynamic>) throw ChainError(endpoint, 'listunspent returned an entry that is not an output');
          final id = u['txid'], vout = u['vout'], amount = u['amount'];
          if (id is! String || !_isTxid(id) || vout is! int || vout < 0 || amount is! num || !amount.isFinite || amount < 0 || amount > 21000000) {
            throw ChainError(endpoint, 'listunspent returned an output it did not describe');
          }
          out.add(UnspentOutput(id, vout, BigInt.from((amount * 100000000).round())));
        }
        return out;
    }
  }

  static bool _isTxid(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

  Future<dynamic> _call(NodeCall call, String method, List<dynamic> params, {String? txid}) async {
    final reply = await _http.send(name, rpcUrl,
        method: 'POST',
        headers: {
          'authorization': 'Basic ${base64.encode(utf8.encode('$user:$password'))}',
          'content-type': 'application/json',
        },
        body: jsonEncode({'jsonrpc': '1.0', 'id': method, 'method': method, 'params': params}));
    return decode(call, name, reply.status, reply.body, txid: txid);
  }

  @override
  Future<Transaction?> fetch(String txid) async => await _call(NodeCall.fetch, 'getrawtransaction', [txid, 0], txid: txid) as Transaction?;

  @override
  Future<int> height() async => await _call(NodeCall.height, 'getblockcount', []) as int;

  @override
  Future<String> broadcast(Transaction tx) async =>
      await _call(NodeCall.broadcast, 'sendrawtransaction', [tx.serialize()], txid: tx.id) as String;

  @override
  Future<int?> minedHeight(String txid) async => await _call(NodeCall.mined, 'getrawtransaction', [txid, 1]) as int?;

  /// The block from the verbose `getrawtransaction`, then the node's own
  /// merkle proof of the transaction in it (`getmerkleproof2`, TSC format).
  @override
  Future<TxPlace?> placeOf(String txid) async {
    final block = await _call(NodeCall.block, 'getrawtransaction', [txid, 1]) as String?;
    if (block == null) return null;
    final place = await _call(NodeCall.proof, 'getmerkleproof2', [block, txid], txid: txid) as TxPlace;
    if (place.blockHash != block) throw ChainError(name, 'the merkle proof of $txid names block ${place.blockHash}, not $block');
    return place;
  }

  @override
  Future<bool> unspent(String txid, int vout) async => await _call(NodeCall.txout, 'gettxout', [txid, vout, true]) as bool;

  /// The node answers `listunspent` only for addresses it watches, so the
  /// address is imported watch-only, with a rescan, the first time it is
  /// asked about; a regtest chain rescans in seconds.
  @override
  Future<List<UnspentOutput>> unspentOf(Address address) async {
    final a = address.toBase58();
    if (!_watched.contains(a)) {
      final known = await _call(NodeCall.validate, 'validateaddress', [a]) as bool;
      if (!known) await _rpc(NodeCall.validate, 'importaddress', [a, '', true]);
      _watched.add(a);
    }
    return (await _call(NodeCall.unspent, 'listunspent', [0, 9999999, [a]]) as List<UnspentOutput>);
  }

  /// Mines [n] blocks to a fresh address of the node's wallet. Regtest
  /// only; the tests and the localnet runs drive the chain with it.
  Future<void> generate(int n) async {
    final addr = await _rpc(NodeCall.validate, 'getnewaddress', []);
    await _rpc(NodeCall.validate, 'generatetoaddress', [n, addr]);
  }

  /// Pays [sats] to [address] from the node's wallet and returns the txid.
  /// Regtest only; how the tests fund a wallet.
  Future<String> payFromNode(Address address, BigInt sats) async {
    final r = await _rpc(NodeCall.validate, 'sendtoaddress', [address.toBase58(), sats.toInt() / 100000000]);
    if (r is! String || !_isTxid(r)) throw ChainError(name, 'sendtoaddress returned something other than a txid');
    return r;
  }

  void close() => _http.close();
}
