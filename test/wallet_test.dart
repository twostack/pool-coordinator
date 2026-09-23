import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';

/// The wallet file keeps nothing in the clear and opens only with its
/// passphrase; the wallet funds exactly what is asked, keeps a change
/// chain, notices top-ups, re-offers what a failed round stranded, and
/// reports what it can still pay for.
void main() {
  late Directory dir;
  final key = SVPrivateKey.fromWIF('cStLVGeWx7fVYKKDXYWVeEbEcPZEC4TD73DjQpHCks2Y8EAjVDSS');
  final addr = Address.fromPublicKey(key.publicKey, NetworkType.TEST);
  const kdf = KdfParams.light;

  setUp(() => dir = Directory.systemTemp.createTempSync('pool-wallet'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A mined transaction paying [sats] to the owner at output 0.
  Transaction coin(int n, int sats) => Transaction()
    ..version = 1
    ..addInput(TransactionInput(hex.encode(List.filled(32, n)), 0, TransactionInput.MAX_SEQ_NUMBER))
    ..addOutput(TransactionOutput(BigInt.from(sats), P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));

  Future<(FileWallet, FakeChain)> wallet({int sats = 100000, int feeRate = 1, List<WalletCoin>? coins}) async {
    final chain = FakeChain();
    final c = coin(1, sats);
    chain.addMined(c);
    final contents = WalletContents(ownerKey: key, network: NetworkType.TEST, coins: coins ?? [WalletCoin(c, 0)]);
    final f = await WalletFile.create('${dir.path}/wallet.enc', 'open sesame', contents, kdf: kdf);
    return (FileWallet(file: f, contents: contents, chain: chain, feeRate: feeRate, minedPoll: const Duration(milliseconds: 20)), chain);
  }

  group('the wallet file', () {
    test('opens with its passphrase and refuses another, naming the file and not the key', () async {
      final path = '${dir.path}/w.enc';
      final c = coin(2, 777);
      final contents = WalletContents(ownerKey: key, network: NetworkType.TEST, coins: [WalletCoin(c, 0)], lastRoundCost: BigInt.from(4400));
      await WalletFile.create(path, 'right', contents, kdf: kdf);
      final (f, back) = await WalletFile.open(path, 'right');
      expect(back.ownerKey.toHex(), key.toHex());
      expect(back.coins.single.outpoint, '${c.id}:0');
      expect(back.lastRoundCost, BigInt.from(4400));
      expect(f.kdf.memoryKiB, kdf.memoryKiB);
      try {
        await WalletFile.open(path, 'wrong');
        fail('opened');
      } on WalletFileError catch (e) {
        expect(e.path, path);
        expect(e.reason, contains('passphrase'));
        expect('$e', isNot(contains(key.toHex())));
        expect('$e', isNot(contains(key.toWIF())));
      }
      expect(() => WalletFile.create(path, 'again', contents), throwsA(isA<WalletFileError>().having((e) => e.reason, 'reason', contains('already exists'))));
      if (!Platform.isWindows) {
        final mode = (await Process.run('stat', ['-f', '%Lp', path])).stdout.toString().trim();
        expect(mode, '600', reason: 'owner-only');
      }
    });

    test('nothing in the clear: no run equal to the owner key, its public key or an outpoint', () async {
      final path = '${dir.path}/w.enc';
      final c = coin(3, 12345), d = coin(4, 678);
      final contents = WalletContents(ownerKey: key, network: NetworkType.TEST, coins: [WalletCoin(c, 0)], offered: [WalletCoin(d, 0)]);
      await WalletFile.create(path, 'p', contents, kdf: kdf);
      final bytes = File(path).readAsBytesSync();
      final keyBytes = hex.decode(key.toHex());
      final pub = hex.decode(key.publicKey.toHex());
      expect(keyBytes.length, 32);
      expect(pub.length, 33);
      for (final needle in [keyBytes, pub, hex.decode(c.id), hex.decode(d.id), c.hash, d.hash, hex.decode(addr.pubkeyHash160)]) {
        expect(_contains(bytes, needle), isFalse, reason: 'found ${hex.encode(needle)}');
        expect(_contains(bytes, needle.reversed.toList()), isFalse);
      }
      // outpoints as the library writes them: txid bytes then a little-endian vout
      for (final tx in [c, d]) {
        expect(_contains(bytes, [...tx.hash, 0, 0, 0, 0]), isFalse);
      }
      // and not as text either
      final text = String.fromCharCodes(bytes);
      expect(text, isNot(contains(key.toHex())));
      expect(text, isNot(contains(c.id)));
      expect(text, isNot(contains(c.serialize())));
    });

    test('an unknown version and a file cut short are refused naming the file', () async {
      final path = '${dir.path}/w.enc';
      await WalletFile.create(path, 'p', WalletContents(ownerKey: key, network: NetworkType.TEST), kdf: kdf);
      final bytes = File(path).readAsBytesSync();
      final other = Uint8List.fromList(bytes)..[4] = 9;
      File('${dir.path}/v9.enc').writeAsBytesSync(other);
      await expectLater(WalletFile.open('${dir.path}/v9.enc', 'p'),
          throwsA(isA<WalletFileError>().having((e) => e.reason, 'reason', contains('version 9')).having((e) => e.path, 'path', '${dir.path}/v9.enc')));
      File('${dir.path}/short.enc').writeAsBytesSync(bytes.sublist(0, 20));
      await expectLater(WalletFile.open('${dir.path}/short.enc', 'p'), throwsA(isA<WalletFileError>().having((e) => e.reason, 'reason', contains('cut short'))));
      File('${dir.path}/cut.enc').writeAsBytesSync(bytes.sublist(0, bytes.length - 3));
      await expectLater(WalletFile.open('${dir.path}/cut.enc', 'p'), throwsA(isA<WalletFileError>()));
      await expectLater(WalletFile.open('${dir.path}/none.enc', 'p'), throwsA(isA<WalletFileError>().having((e) => e.reason, 'reason', contains('does not exist'))));
      // a write is whole or absent: no temporary file stays behind
      expect(File('$path.tmp').existsSync(), isFalse);
    });
  });

  group('funding', () {
    test('three outputs a round: exactly the values asked, each mined before it is handed over, along a change chain', () async {
      final (w, chain) = await wallet(sats: 100000);
      final asked = [BigInt.from(1784), BigInt.from(2205), BigInt.from(396 + 50)];
      final given = <FundingOutput>[];
      for (final v in asked) {
        final f = (await w.output(v))!;
        expect(f.value, v, reason: 'exactly the value asked');
        expect(f.vout, 1, reason: 'the change comes first, as the issuance requires');
        expect(FakeChain.paysPKH(f.tx.outputs[1], addr.pubkeyHash160), isTrue);
        expect(await chain.minedHeight(f.tx.id), isNotNull, reason: 'mined before the library gets it');
        given.add(f);
      }
      expect(w.built, hasLength(3));
      expect(chain.broadcasts, w.built.map((t) => t.id));
      // the change chain: each funding transaction spends the previous one's change
      expect(w.built[1].inputs.single.prevTxnId, w.built[0].id);
      expect(w.built[1].inputs.single.prevTxnOutputIndex, 0);
      expect(w.built[2].inputs.single.prevTxnId, w.built[1].id);
      final fees = w.built.map((t) => _feeOf(t, chain.known)).toList();
      expect(fees, everyElement(BigInt.from(135)), reason: 'the floor at 1 sat/kB');
      expect(w.balance, BigInt.from(100000 - 1784 - 2205 - 446 - 3 * 135));
      expect(w.contents.offered.map((c) => c.outpoint), given.map((f) => '${f.tx.id}:1'));
      // the record survives a reopen
      final (_, back) = await WalletFile.open(w.file.path, 'open sesame');
      expect(back.offered, hasLength(3));
      expect(back.coins.single.satoshis, w.balance);
    });

    test('the wallet waits for the chain to mine the funding transaction', () async {
      final (w, chain) = await wallet();
      chain.mineOnBroadcast = false;
      final sw = Stopwatch()..start();
      final pending = w.output(BigInt.from(1000));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      chain.mine();
      final f = (await pending)!;
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(100));
      expect(await chain.minedHeight(f.tx.id), isNotNull);
    });

    test('a stranded output is reused: after a failed round the next request gets it, and no funding transaction is built', () async {
      final (w, chain) = await wallet();
      final first = (await w.output(BigInt.from(1784)))!;
      expect(w.built, hasLength(1));
      // the round fails; nothing spends the output; the server reconciles
      await w.reconcile();
      expect(w.contents.offered, isEmpty);
      expect(w.contents.coins.where((c) => c.returned).single.outpoint, '${first.tx.id}:1');
      expect(w.balance, BigInt.from(100000 - 135), reason: 'the returned output counts again');
      final again = (await w.output(BigInt.from(1784)))!;
      expect(again.tx.id, first.tx.id);
      expect(again.vout, 1);
      expect(w.built, hasLength(1), reason: 'no funding transaction was built');
      expect(chain.broadcasts, hasLength(1));
      // a request the stranded output does not cover builds a new one
      final more = (await w.output(BigInt.from(5000)))!;
      expect(more.tx.id, isNot(first.tx.id));
      expect(w.built, hasLength(2));
    });

    test('not enough coins: the request fails naming the balance, and nothing is broadcast', () async {
      final (w, chain) = await wallet(sats: 1000);
      await expectLater(
          w.output(BigInt.from(5000)),
          throwsA(isA<WalletRefusal>()
              .having((e) => e.reason, 'reason', contains('1000 satoshis'))
              .having((e) => e.reason, 'reason', contains('5000'))));
      expect(chain.broadcasts, isEmpty);
      expect(w.balance, BigInt.from(1000));
      // through the library's own funding path it is a round failure at funding
      expect(w.report.toString(), contains('balance 1000'));
    });

    test('a refused funding transaction leaves the record unchanged and fails with the chain\'s reason', () async {
      final (w, chain) = await wallet();
      chain.refuse = (_) => 'mempool full';
      final before = File(w.file.path).readAsBytesSync();
      await expectLater(w.output(BigInt.from(1784)), throwsA(isA<WalletRefusal>().having((e) => e.reason, 'reason', contains('mempool full'))));
      expect(w.balance, BigInt.from(100000));
      expect(w.contents.offered, isEmpty);
      expect(w.built, isEmpty);
      expect(File(w.file.path).readAsBytesSync(), before, reason: 'nothing written');
    });

    test('a top-up is noticed at reconcile, and the balance includes it', () async {
      final (w, chain) = await wallet(sats: 1000);
      chain.addMined(coin(7, 50000));
      expect(w.balance, BigInt.from(1000));
      await w.reconcile();
      expect(w.balance, BigInt.from(51000));
      expect(w.contents.coins, hasLength(2));
      // a second reconcile takes nothing in twice
      await w.reconcile();
      expect(w.contents.coins, hasLength(2));
      // and it survives a reopen
      final (_, back) = await WalletFile.open(w.file.path, 'open sesame');
      expect(back.coins, hasLength(2));
    });

    test('a crash after broadcasting a funding transaction is recovered by the scan', () async {
      final (w, chain) = await wallet();
      // the funding transaction went out, the record was not written
      final f = (await w.output(BigInt.from(1784)))!;
      final (_, stale) = await WalletFile.open(w.file.path, 'open sesame');
      stale.coins
        ..clear()
        ..add(WalletCoin(chain.known[chain.broadcasts.first]!.inputs.single.prevTxnId.let((id) => chain.known[id]!), 0));
      stale.offered.clear();
      final fresh = FileWallet(file: w.file, contents: stale, chain: chain, feeRate: 1);
      await fresh.reconcile();
      // the spent coin is gone, the change and the funding output are found
      expect(fresh.contents.coins.map((c) => c.outpoint), containsAll(['${f.tx.id}:0', '${f.tx.id}:1']));
      expect(fresh.balance, BigInt.from(100000 - 135));
    });

    test('rounds left: 100,000 sat after a round that cost 4,400 reports 22', () async {
      final (w, chain) = await wallet(sats: 104400 + 3 * 135 + 500);
      await w.reconcile();
      expect(w.roundsLeft, isNull, reason: 'no round yet');
      // a production round: Y 1,784, the round 396 plus dust, the witness 2,205
      final y = (await w.output(BigInt.from(1784)))!;
      final r = (await w.output(BigInt.from(396 + 50)))!;
      final wt = (await w.output(BigInt.from(2205)))!;
      // the round spends its funding and returns 440 change to the owner, so
      // the round costs the 4,435 offered plus 405 in funding fees less 440
      final round = Transaction()
        ..addInput(TransactionInput(r.tx.id, r.vout, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(BigInt.from(440), P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));
      final yTx = Transaction()
        ..addInput(TransactionInput(y.tx.id, y.vout, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(BigInt.one, SVScript()));
      final wTx = Transaction()
        ..addInput(TransactionInput(wt.tx.id, wt.vout, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(BigInt.one, SVScript()));
      for (final t in [yTx, round, wTx]) {
        await chain.broadcast(t);
      }
      await w.reconcile(roundTxs: [yTx, round, wTx]);
      // the round cost what its outputs held plus the funding fees, less the change
      expect(w.lastRoundCost, BigInt.from(4400));
      expect(w.balance, BigInt.from(104400 + 3 * 135 + 500 - 4435 - 405 + 440));
      // with 100,000 sat that is 22 rounds, within one
      w.contents.coins
        ..clear()
        ..add(WalletCoin(coin(9, 100000), 0));
      expect(w.balance, BigInt.from(100000));
      expect(w.roundsLeft, 22);
      expect(w.report.roundsLeft, 22);
      expect(w.report.toJson()['lastRoundCost'], '4400');
    });
  });
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

BigInt _feeOf(Transaction tx, Map<String, Transaction> known) {
  var fee = BigInt.zero;
  for (final i in tx.inputs) {
    fee += known[i.prevTxnId]!.outputs[i.prevTxnOutputIndex].satoshis;
  }
  for (final o in tx.outputs) {
    fee -= o.satoshis;
  }
  return fee;
}

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (int i = 0; i + needle.length <= hay.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
