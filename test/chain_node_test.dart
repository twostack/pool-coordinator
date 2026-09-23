import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';

import 'fakes.dart' show FakeChain;
import 'support/fake_http.dart';

/// The node implementation: against ../localnet when POOL_LOCALNET is
/// set, and against a fake node that hangs or talks nonsense otherwise.
void main() {
  final env = Platform.environment;

  group('the localnet node', () {
    late NodeChain chain;
    final key = SVPrivateKey(networkType: NetworkType.TEST);
    final addr = Address.fromPublicKey(key.publicKey, NetworkType.TEST);
    final signer = DefaultTransactionSigner(SighashType.SIGHASH_FORKID.value | SighashType.SIGHASH_ALL.value, key);

    setUpAll(() {
      chain = NodeChain(
          rpcUrl: Uri.parse(env['LOCALNET_RPC'] ?? 'http://localhost:18332'),
          user: 'bitcoin',
          password: env['POOL_RPC_PASSWORD'] ?? 'bitcoin',
          timeout: const Duration(seconds: 60));
    });

    test('a broadcast is sendrawtransaction, a fetch getrawtransaction, the height getblockcount', () async {
      final h0 = await chain.height();
      expect(h0, greaterThan(100));
      expect(await chain.fetch('00' * 32), isNull, reason: 'an unknown txid is null, not an error');
      expect(await chain.minedHeight('00' * 32), isNull);
      expect(await chain.unspent('00' * 32, 0), isFalse);

      // coins from the node, mined
      final funded = await chain.payFromNode(addr, BigInt.from(100000));
      await chain.generate(1);
      final coins = (await chain.fetch(funded))!;
      expect(coins.id, funded);
      final vout = coins.outputs.indexWhere((o) => FakeChain.paysPKH(o, addr.pubkeyHash160));
      expect(vout, greaterThanOrEqualTo(0));
      expect(await chain.minedHeight(funded), h0 + 1);
      expect(await chain.unspent(funded, vout), isTrue);
      final found = await chain.unspentOf(addr);
      expect(found.map((u) => u.outpoint), contains('$funded:$vout'));
      expect(found.firstWhere((u) => u.txid == funded).satoshis, BigInt.from(100000));

      // spend it back to ourselves through sendrawtransaction
      final spend = (TransactionBuilder()
            ..spendFromTxnWithSigner(signer, coins, vout, TransactionInput.MAX_SEQ_NUMBER, P2PKHUnlockBuilder(key.publicKey))
            ..spendToPKH(addr, BigInt.from(99000)))
          .build(false);
      expect(await chain.broadcast(spend), 'node');
      expect(await chain.minedHeight(spend.id), isNull, reason: 'in the mempool, not mined');
      expect(await chain.unspent(funded, vout), isFalse, reason: 'gettxout sees the mempool spend');
      await chain.generate(1);
      expect(await chain.minedHeight(spend.id), h0 + 2);
      expect(await chain.unspent(spend.id, 0), isTrue);
      expect((await chain.unspentOf(addr)).map((u) => u.outpoint), contains('${spend.id}:0'));

      // the node's refusal is a refusal with its reason
      expect(() => chain.broadcast(spend),
          throwsA(isA<BroadcastRefusal>().having((e) => e.reason, 'reason', isNotEmpty).having((e) => e.endpoint, 'endpoint', contains('node'))));
      final wrong = Transaction()
        ..addInput(TransactionInput('11' * 32, 0, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(BigInt.one, P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));
      expect(() => chain.broadcast(wrong), throwsA(isA<BroadcastRefusal>()));
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: env['POOL_LOCALNET'] == null ? 'needs ../localnet up; set POOL_LOCALNET=1' : false);

  group('resources', () {
    test('an endpoint that does not answer fails after the retries and the timeout, naming the endpoint', () async {
      final fake = await FakeHttp.start();
      fake.hang = true;
      final chain = NodeChain(rpcUrl: fake.url, user: 'u', password: 'p', timeout: const Duration(milliseconds: 300), retries: 2);
      final sw = Stopwatch()..start();
      try {
        await expectLater(
            chain.fetch('00' * 32),
            throwsA(isA<ChainError>()
                .having((e) => e.endpoint, 'endpoint', contains(fake.url.toString()))
                .having((e) => e.reason, 'reason', contains('3 attempts'))));
        expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(900), reason: 'three attempts of 300 ms');
        expect(sw.elapsedMilliseconds, lessThan(5000));
        expect(fake.requests.length, 3);
      } finally {
        chain.close();
        await fake.close();
      }
    });

    test('a closed port is a network error, retried and then named', () async {
      final fake = await FakeHttp.start();
      final url = fake.url;
      await fake.close();
      final chain = NodeChain(rpcUrl: url, user: 'u', password: 'p', timeout: const Duration(milliseconds: 300), retries: 1);
      await expectLater(chain.height(), throwsA(isA<ChainError>().having((e) => e.reason, 'reason', contains('2 attempts'))));
      chain.close();
    });

    test('an answer that is not JSON-RPC is an error naming the endpoint, never a crash', () async {
      final fake = await FakeHttp.start();
      fake.routes['/'] = (_) => const Answer(200, '<html>not a node</html>');
      final chain = NodeChain(rpcUrl: fake.url, user: 'u', password: 'p', timeout: const Duration(seconds: 2), retries: 0);
      try {
        await expectLater(chain.height(), throwsA(isA<ChainError>().having((e) => e.reason, 'reason', contains('not JSON'))));
        fake.routes['/'] = (_) => rpcResult('zz');
        await expectLater(chain.fetch('00' * 32), throwsA(isA<ChainError>().having((e) => e.reason, 'reason', contains('hex'))));
        fake.routes['/'] = (_) => rpcResult(-1);
        await expectLater(chain.height(), throwsA(isA<ChainError>()));
        fake.routes['/'] = (_) => rpcError(-5, 'No such mempool or blockchain transaction');
        expect(await chain.fetch('00' * 32), isNull);
        expect(await chain.minedHeight('00' * 32), isNull);
        fake.routes['/'] = (_) => rpcError(-26, 'mandatory-script-verify-flag-failed');
        final tx = Transaction()..addInput(TransactionInput('11' * 32, 0, TransactionInput.MAX_SEQ_NUMBER));
        await expectLater(chain.broadcast(tx),
            throwsA(isA<BroadcastRefusal>().having((e) => e.reason, 'reason', contains('mandatory')).having((e) => e.status, 'status', '-26')));
        // the request carries the credentials and the method
        final last = fake.requests.last;
        expect(last.method, 'POST');
        expect(jsonDecode(last.body)['method'], 'sendrawtransaction');
      } finally {
        chain.close();
        await fake.close();
      }
    });

    test('a transaction other than the one asked for is refused naming both txids', () async {
      final fake = await FakeHttp.start();
      final other = Transaction()..addInput(TransactionInput('22' * 32, 0, TransactionInput.MAX_SEQ_NUMBER));
      fake.routes['/'] = (_) => rpcResult(other.serialize());
      final chain = NodeChain(rpcUrl: fake.url, user: 'u', password: 'p', retries: 0);
      try {
        await expectLater(
            chain.fetch('00' * 32),
            throwsA(isA<ChainError>()
                .having((e) => e.reason, 'reason', contains('00' * 32))
                .having((e) => e.reason, 'reason', contains(other.id))));
        expect(hex.encode(hex.decode(other.serialize())), other.serialize());
      } finally {
        chain.close();
        await fake.close();
      }
    });
  });
}
