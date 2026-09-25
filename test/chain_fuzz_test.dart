import 'dart:convert';
import 'dart:math';

import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';

import 'support/fake_http.dart';

/// Every malformed answer from the node, ARC or WhatsOnChain ends in a
/// named error: 10,000 bodies per endpoint, random and mutated from a
/// valid answer, through each implementation's decoding, and a sample of
/// them through the HTTP path as well.
void main() {
  const txid = 'f0315ffc38709d70ad5647e22048358dd3745f3ce3874223c80a7c92fab0c8ba';
  const txHex =
      '01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0e0420e7494d017f062f503253482fffffffff0100f2052a010000002321021aeaf2f8638a129a3156fbe7e5ef635226b0bafd495ff03afe2c843d7e3a4b51ac00000000';
  final rng = Random(2026);

  /// [valid] with one byte changed, a run cut off, or bytes inserted.
  String mutate(String valid) {
    final b = utf8.encode(valid).toList();
    switch (rng.nextInt(4)) {
      case 0:
        if (b.isEmpty) return '';
        b[rng.nextInt(b.length)] = rng.nextInt(256);
      case 1:
        return valid.substring(0, rng.nextInt(valid.length + 1));
      case 2:
        final at = rng.nextInt(b.length + 1);
        b.insertAll(at, List.generate(1 + rng.nextInt(8), (_) => rng.nextInt(256)));
      default:
        final at = rng.nextInt(b.length + 1);
        b.insertAll(at, utf8.encode(['"', '{', '}', '[', 'null', '-1', '1e400', '\\u0000'][rng.nextInt(8)]));
    }
    return utf8.decode(b, allowMalformed: true);
  }

  String random() => utf8.decode(List.generate(rng.nextInt(300), (_) => rng.nextInt(256)), allowMalformed: true);

  /// Runs [decode] on 10,000 bodies and counts the outcomes: a value, a
  /// chain error, a refusal, or anything else, which must not happen.
  Map<String, int> fuzz(String valid, void Function(int status, String body) decode) {
    final counts = <String, int>{};
    void count(String k) => counts[k] = (counts[k] ?? 0) + 1;
    for (int i = 0; i < 10000; i++) {
      final body = i < 3000 ? random() : mutate(valid);
      final status = [200, 200, 200, 404, 500, 400, 502][rng.nextInt(7)];
      try {
        decode(status, body);
        count('value');
      } on ChainError {
        count('ChainError');
      } on BroadcastRefusal {
        count('BroadcastRefusal');
      } catch (e) {
        count('other: ${e.runtimeType}');
      }
    }
    return counts;
  }

  void expectNamed(Map<String, int> counts) {
    expect(counts.keys.where((k) => k.startsWith('other')), isEmpty, reason: '$counts');
    expect(counts.values.reduce((a, b) => a + b), 10000);
  }

  group('the node', () {
    final valid = {
      NodeCall.fetch: jsonEncode({'result': txHex, 'error': null, 'id': 'x'}),
      NodeCall.height: jsonEncode({'result': 15043, 'error': null, 'id': 'x'}),
      NodeCall.broadcast: jsonEncode({'result': txid, 'error': null, 'id': 'x'}),
      NodeCall.mined: jsonEncode({
        'result': {'txid': txid, 'confirmations': 3, 'blockheight': 15040, 'hex': txHex},
        'error': null,
        'id': 'x'
      }),
      NodeCall.block: jsonEncode({
        'result': {'txid': txid, 'confirmations': 3, 'blockheight': 15040, 'blockhash': 'ab' * 32, 'hex': txHex},
        'error': null,
        'id': 'x'
      }),
      NodeCall.proof: jsonEncode({
        'result': {'index': 2, 'txOrId': txid, 'target': 'ab' * 32, 'nodes': ['cd' * 32, '*', 'ef' * 32]},
        'error': null,
        'id': 'x'
      }),
      NodeCall.txout: jsonEncode({
        'result': {'bestblock': '00' * 32, 'confirmations': 1, 'value': 50.0},
        'error': null,
        'id': 'x'
      }),
      NodeCall.validate: jsonEncode({
        'result': {'isvalid': true, 'address': 'n3GNqMveyvaPvUbH469vDRadqpJMPc84JA', 'ismine': false, 'iswatchonly': true},
        'error': null,
        'id': 'x'
      }),
      NodeCall.status: jsonEncode({
        'result': {'txid': txid, 'confirmations': 3, 'blockheight': 5},
        'error': null,
        'id': 'x'
      }),
      NodeCall.unspent: jsonEncode({
        'result': [
          {'txid': txid, 'vout': 0, 'address': 'n3GNqMveyvaPvUbH469vDRadqpJMPc84JA', 'amount': 0.00050000, 'confirmations': 5}
        ],
        'error': null,
        'id': 'x'
      }),
    };
    for (final call in NodeCall.values) {
      test('10,000 bodies for $call end in a value or a named error', () {
        final counts = fuzz(valid[call]!, (status, body) => NodeChain.decode(call, 'the node', status, body, txid: txid));
        expectNamed(counts);
        expect(counts['ChainError'], greaterThan(5000));
      });
    }
  });

  test('a TSC proof\'s "*" is the working hash, and the branch reaches the block\'s root', () {
    // three transactions: the last pairs with itself at the bottom level
    final txs = [for (final b in ['11', '22', '33']) b * 32];
    final root = TxPlace.rootOf(txs[0], 0, TxPlace.branchFor(txs, 0));
    for (int i = 0; i < 3; i++) {
      expect(TxPlace.rootOf(txs[i], i, TxPlace.branchFor(txs, i)), root, reason: 'transaction $i');
    }
    final pair01 = TxPlace.rootOf(txs[0], 0, [txs[1]]);
    final place = TxPlace.fromTsc('the node', txs[2], {'index': 2, 'txOrId': txs[2], 'target': 'ab' * 32, 'nodes': ['*', pair01]});
    expect(place.branch, TxPlace.branchFor(txs, 2));
    expect(TxPlace.rootOf(txs[2], 2, place.branch), root);
    expect(() => TxPlace.fromTsc('the node', txs[2], {'index': 2, 'txOrId': txs[1], 'target': 'ab' * 32, 'nodes': []}),
        throwsA(isA<ChainError>()), reason: 'a proof of another transaction');
  });

  group('testnet', () {
    final valid = {
      TestnetCall.fetch: txHex,
      TestnetCall.chainInfo: '{"chain":"test","blocks":1759424,"headers":1759424,"bestblockhash":"00000000be85","difficulty":1}',
      TestnetCall.txStatus: '{"txid":"$txid","confirmations":1759424,"blockheight":1,"blockhash":"00000000b873"}',
      TestnetCall.proof: '[{"index":2,"txOrId":"$txid","target":"${'ab' * 32}","nodes":["${'cd' * 32}","*","${'ef' * 32}"]}]',
      TestnetCall.spent: '{"txid":"5f2052ac5cb8eed1995a087b8f4777b27345acf97a193ef8af536ed5dd4935ce","vin":0,"status":"confirmed"}',
      TestnetCall.unspentAll:
          '{"address":"n3GNqMveyvaPvUbH469vDRadqpJMPc84JA","script":"a7ec","result":[{"height":280589,"tx_pos":0,"tx_hash":"$txid","value":50000,"isSpentInMempoolTx":false,"status":"confirmed"}]}',
      TestnetCall.arcTx: '{"txid":"$txid","txStatus":"SEEN_ON_NETWORK","blockHash":"","blockHeight":0,"extraInfo":"","status":200,"title":"OK"}',
      TestnetCall.arcStatus: '{"txid":"$txid","txStatus":"MINED","blockHash":"${'ab' * 32}","blockHeight":5,"extraInfo":"","status":200,"title":"OK"}',
    };
    for (final call in TestnetCall.values) {
      test('10,000 bodies for $call end in a value or a named error', () {
        final counts = fuzz(valid[call]!, (status, body) => TestnetChain.decode(call, 'testnet', status, body, txid: txid));
        expectNamed(counts);
        expect((counts['ChainError'] ?? 0) + (counts['BroadcastRefusal'] ?? 0), greaterThan(3000));
      });
    }
  });

  test('200 random bodies through the HTTP path of each implementation end in a named error', () async {
    final fake = await FakeHttp.start();
    var body = '';
    fake.routes['/'] = (_) => Answer(200, body);
    for (final path in ['/woc/tx/$txid/hex', '/woc/chain/info', '/woc/tx/hash/$txid', '/woc/tx/$txid/0/spent', '/arc/tx']) {
      fake.routes[path] = (_) => Answer(200, body);
    }
    final node = NodeChain(rpcUrl: fake.url, user: 'u', password: 'p', retries: 0);
    final testnet = TestnetChain(arcUrl: fake.url.resolve('/arc'), wocUrl: fake.url.resolve('/woc'), retries: 0);
    final tx = Transaction.fromHex(txHex);
    final spend = Transaction()
      ..addInput(TransactionInput(txid, 0, TransactionInput.MAX_SEQ_NUMBER))
      ..addOutput(TransactionOutput(BigInt.one, tx.outputs[0].script));
    testnet.remember(tx);
    final calls = <Future<dynamic> Function()>[
      () => node.fetch(txid),
      () => node.height(),
      () => node.broadcast(spend),
      () => node.minedHeight(txid),
      () => node.unspent(txid, 0),
      () => testnet.height(),
      () => testnet.minedHeight(txid),
      () => testnet.broadcast(spend),
    ];
    var named = 0, values = 0;
    try {
      for (int i = 0; i < 200; i++) {
        body = i.isEven ? random() : mutate('{"result":null,"error":null}');
        for (final call in calls) {
          try {
            await call();
            values++;
          } on ChainError {
            named++;
          } on BroadcastRefusal {
            named++;
          }
        }
      }
    } finally {
      node.close();
      testnet.close();
      await fake.close();
    }
    expect(named + values, 200 * calls.length);
    expect(named, greaterThan(1000));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
