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

  /// A wallet holding [amounts] as mined coins (100,000 sat by default), on
  /// a fake chain that mines only when told to, with the coin store's
  /// settings [coins].
  Future<(FileWallet, FakeChain)> wallet(
      {List<int> amounts = const [100000],
      int feeRate = 1,
      CoinsConfig coins = const CoinsConfig(floor: 10000, target: 30, lowWater: 0),
      Duration fundingTimeout = const Duration(seconds: 5)}) async {
    final chain = FakeChain(height: 100)..mineOnBroadcast = false;
    final held = <WalletCoin>[];
    for (int i = 0; i < amounts.length; i++) {
      final c = coin(1 + i, amounts[i]);
      chain.addMined(c);
      held.add(WalletCoin(c, 0, height: 100));
    }
    final contents = WalletContents(ownerKey: key, network: NetworkType.TEST, coins: held);
    final f = await WalletFile.create('${dir.path}/wallet.enc', 'open sesame', contents, kdf: kdf);
    return (
      FileWallet(
          file: f,
          contents: contents,
          chain: chain,
          feeRate: feeRate,
          coins: coins,
          minedPoll: const Duration(milliseconds: 20),
          fundingTimeout: fundingTimeout),
      chain
    );
  }

  /// Serves requests as [kinds] says, in order: Y, the witness, the round.
  void kinds(FileWallet w, List<FundingKind> kinds) {
    var i = 0;
    w.requestKind = () => kinds[i++ % kinds.length];
  }

  const roundOrder = [FundingKind.exact, FundingKind.exact, FundingKind.round];

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
        // from Dart rather than stat(1), whose flags differ between macOS and Linux
        final mode = (File(path).statSync().mode & 0x1ff).toRadixString(8);
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

  group('the wallet file, format 2', () {
    test('an old wallet file: format 1 is read, one mined coin is ready and one unmined pending, and the file on disk is format 2', () async {
      final chain = FakeChain(height: 100)..mineOnBroadcast = false;
      final minedCoin = coin(21, 50000), unminedCoin = coin(22, 40000);
      chain.addMined(minedCoin);
      await chain.broadcast(unminedCoin);
      // a format 1 file, as 0.1.0 wrote it: no heights, no splits
      final v1 = {
        'version': 1,
        'network': 'test',
        'ownerKey': key.toHex(),
        'coins': [
          {'tx': minedCoin.serialize(), 'vout': 0},
          {'tx': unminedCoin.serialize(), 'vout': 0},
        ],
        'offered': [],
        'lastRoundCost': '9818',
        'balanceAtReconcile': '90000',
      };
      final path = '${dir.path}/old.enc';
      final contents = WalletContents.fromJson(v1);
      expect(contents.readFormat, 1);
      expect(contents.coins.every((c) => !c.mined), isTrue, reason: 'heights unknown until asked');
      final f = await WalletFile.create(path, 'p', contents, kdf: kdf);
      final w = FileWallet(file: f, contents: contents, chain: chain, feeRate: 1, coins: const CoinsConfig(floor: 10000, lowWater: 0));
      await w.reconcile();
      expect(w.report.readyCoins, 1);
      expect(w.report.pendingCoins, 1);
      expect(w.report.readyValue, BigInt.from(50000));
      expect(w.report.pendingValue, BigInt.from(40000));
      expect(w.lastRoundCost, BigInt.from(9818));
      final (_, back) = await WalletFile.open(path, 'p');
      expect(back.readFormat, 2, reason: 'written back as format 2');
      expect(back.coins.firstWhere((c) => c.txid == minedCoin.id).height, 100);
    });

    test('an unknown format is refused, naming it', () {
      expect(() => WalletContents.fromJson({'version': 7, 'network': 'test', 'ownerKey': key.toHex(), 'coins': [], 'offered': []}),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('format 7'))));
    });

    test('nothing in the clear in format 2: no run equal to the key, its public key, an outpoint or a split\'s txid', () async {
      final (w, chain) = await wallet(amounts: [1000000], coins: const CoinsConfig(floor: 10000, target: 10, lowWater: 5));
      await w.reconcile();
      final split = w.contents.splits.single;
      final bytes = File(w.file.path).readAsBytesSync();
      final text = String.fromCharCodes(bytes);
      for (final needle in [hex.decode(key.toHex()), hex.decode(key.publicKey.toHex()), hex.decode(split.id), split.hash, hex.decode(addr.pubkeyHash160)]) {
        expect(_contains(bytes, needle), isFalse, reason: 'found ${hex.encode(needle)}');
        expect(_contains(bytes, needle.reversed.toList()), isFalse);
      }
      expect(text, isNot(contains(split.id)));
      expect(text, isNot(contains(split.serialize())));
      expect(chain.broadcasts, [split.id]);
    });
  });

  group('the coin store', () {
    test('low water refills the store: one coin of 10,000,000 sat, target 30, low water 12, floor 10,000 gives one split of 30', () async {
      final (w, chain) = await wallet(amounts: [10000000], coins: const CoinsConfig(floor: 10000, target: 30, lowWater: 12));
      await w.reconcile();
      final split = w.splitsBuilt.single;
      expect(chain.broadcasts, [split.id]);
      expect(split.inputs, hasLength(1));
      expect(split.outputs, hasLength(30));
      expect(split.outputs.every((o) => o.satoshis >= BigInt.from(10000)), isTrue);
      expect(split.outputs.every((o) => FakeChain.paysPKH(o, addr.pubkeyHash160)), isTrue, reason: 'no change output: all pay the owner');
      final fee = _feeOf(split, chain.known);
      expect(split.outputs.fold(BigInt.zero, (a, o) => a + o.satoshis) + fee, BigInt.from(10000000));
      expect(fee, BigInt.from(135), reason: 'the floor at 1 sat/kB for 30 outputs');
      expect(w.report.readyCoins, 0);
      expect(w.report.pendingCoins, 30);
      // a second reconcile before the split is mined does not split again
      await w.reconcile();
      expect(chain.broadcasts, hasLength(1));
    });

    test('a split\'s outputs mature: pending until the reconcile after the mining, ready from then on', () async {
      final (w, chain) = await wallet(amounts: [1000000], coins: const CoinsConfig(floor: 10000, target: 10, lowWater: 5));
      await w.reconcile();
      expect(w.report.pendingCoins, 10);
      chain.mine();
      expect(w.report.readyCoins, 0, reason: 'not until a reconcile has asked');
      await w.reconcile();
      expect(w.report.readyCoins, 10);
      expect(w.report.pendingCoins, 0);
      expect(w.contents.splits, isEmpty, reason: 'a mined split is forgotten');
      expect(w.report.toJson()['ready'], {'coins': 10, 'value': w.report.readyValue.toString()});
    });

    test('a coin below the floor is never handed over, and is counted in the balance', () async {
      final (w, chain) = await wallet(amounts: [9999, 30000]);
      kinds(w, [FundingKind.round]);
      final f = (await w.output(BigInt.from(500)))!;
      expect(f.value, BigInt.from(30000), reason: 'the small coin is passed over');
      expect(w.balance, BigInt.from(9999));
      expect(w.report.readyCoins, 0);
      await expectLater(w.output(BigInt.from(500)), throwsA(isA<WalletRefusal>()), reason: 'a coin under the floor serves nothing');
    });

    test('nothing big enough to split: no split, and the status says a top-up is needed', () async {
      final (w, chain) = await wallet(amounts: [20100], coins: const CoinsConfig(floor: 10000, target: 30, lowWater: 12));
      await w.reconcile();
      expect(chain.broadcasts, isEmpty);
      expect(w.report.needsTopUp, isTrue);
    });

    test('a split refused: the source is still ready, the reason is logged, the balance unchanged', () async {
      final (w, chain) = await wallet(amounts: [1000000], coins: const CoinsConfig(floor: 10000, target: 10, lowWater: 5));
      chain.refuse = (_) => 'too-long-mempool-chain';
      final logs = <String>[];
      final sub = w.log.onRecord.listen((r) => logs.add(r.message));
      await w.reconcile();
      await sub.cancel();
      expect(chain.broadcasts, isEmpty);
      expect(w.balance, BigInt.from(1000000));
      expect(w.report.readyCoins, 1);
      expect(w.contents.splits, isEmpty);
      expect(logs.any((m) => m.contains('too-long-mempool-chain')), isTrue);
      final (_, back) = await WalletFile.open(w.file.path, 'open sesame');
      expect(back.coins.single.outpoint, '${chain.known.values.first.id}:0');
    });

    test('a split the chain\'s indexer does not show yet, its source already spent by it: kept after a restart, with no second split and nothing taken as a top-up', () async {
      final coinsCfg = const CoinsConfig(floor: 10000, target: 10, lowWater: 5);
      final (w, chain) = await wallet(amounts: [1000000, 60000], coins: coinsCfg);
      chain.listUnmined = true;
      await w.reconcile();
      final split = w.contents.splits.single;
      expect(await chain.unspent(split.inputs.single.prevTxnId, 0), isFalse, reason: 'spent by the split, in the mempool');
      chain.lagging.add(split.id);
      final logs = <String>[];
      final (file, back) = await WalletFile.open(w.file.path, 'open sesame');
      final restarted = FileWallet(file: file, contents: back, chain: chain, feeRate: 1, coins: coinsCfg);
      final sub = restarted.log.onRecord.listen((r) => logs.add(r.message));
      await restarted.reconcile();
      await sub.cancel();
      expect(restarted.contents.splits.map((t) => t.id), [split.id], reason: 'still recorded');
      expect(restarted.splitsBuilt.where((t) => t.id != split.id), isEmpty, reason: 'no second split');
      expect(logs.where((m) => m.contains('top-up')), isEmpty);
      expect(restarted.report.pendingCoins, 9, reason: 'the split\'s outputs: the target less the one ready coin');
      expect(restarted.report.readyCoins, 1, reason: 'the 60,000 coin, not split');
      chain.mine();
      chain.lagging.clear();
      await restarted.reconcile();
      expect(restarted.contents.splits, isEmpty);
      expect(restarted.report.readyCoins, 10);
    });

    test('a split refused when broadcast again, its source spent elsewhere: dropped, the source not put back', () async {
      final coinsCfg = const CoinsConfig(floor: 10000, target: 10, lowWater: 5);
      final (w, chain) = await wallet(amounts: [1000000], coins: coinsCfg);
      chain.beforeBroadcast = (_) async => throw const _Stopped();
      await expectLater(w.reconcile(), throwsA(isA<_Stopped>()));
      chain.beforeBroadcast = null;
      final (file, back) = await WalletFile.open(w.file.path, 'open sesame');
      final split = back.splits.single;
      // meanwhile the source was spent by another transaction
      final other = Transaction()
        ..version = 1
        ..addInput(TransactionInput(split.inputs.single.prevTxnId, 0, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(BigInt.from(1000), SVScript()));
      chain.accept(other);
      chain.refuse = (tx) => tx.id == split.id ? 'txn-mempool-conflict' : null;
      final restarted = FileWallet(file: file, contents: back, chain: chain, feeRate: 1, coins: coinsCfg);
      await restarted.reconcile();
      expect(restarted.contents.splits, isEmpty);
      expect(restarted.contents.coins, isEmpty, reason: 'neither the split\'s outputs nor the spent source');
    });

    test('a crash before the split\'s broadcast: the next start broadcasts it once, and its outputs are pending', () async {
      final (w, chain) = await wallet(amounts: [1000000], coins: const CoinsConfig(floor: 10000, target: 10, lowWater: 5));
      // the process stops between the file's write and the broadcast
      chain.beforeBroadcast = (_) async => throw const _Stopped();
      await expectLater(w.reconcile(), throwsA(isA<_Stopped>()));
      chain.beforeBroadcast = null;
      expect(chain.broadcasts, isEmpty);
      final (file, back) = await WalletFile.open(w.file.path, 'open sesame');
      expect(back.splits, hasLength(1), reason: 'written before the broadcast');
      final restarted = FileWallet(file: file, contents: back, chain: chain, feeRate: 1, coins: const CoinsConfig(floor: 10000, target: 10, lowWater: 5));
      await restarted.reconcile();
      expect(chain.broadcasts, [back.splits.single.id], reason: 'broadcast once');
      expect(restarted.report.pendingCoins, 10);
      await restarted.reconcile();
      expect(chain.broadcasts, hasLength(1), reason: 'and not again');
    });
  });

  group('funding', () {
    test('three outputs a round: exact values for Y and the witness, a whole coin for the round, each within 1 s, no block mined, every funding transaction over a mined coin', () async {
      final (w, chain) = await wallet(amounts: [40000, 25000, 15000, 12000]);
      kinds(w, roundOrder);
      final heightBefore = await chain.height();
      final asked = [BigInt.from(1784), BigInt.from(2205), BigInt.from(396 + 546)];
      final given = <FundingOutput>[];
      for (final v in asked) {
        final sw = Stopwatch()..start();
        given.add((await w.output(v))!);
        expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
      }
      expect(await chain.height(), heightBefore, reason: 'no block was mined');
      expect(given[0].value, asked[0]);
      expect(given[1].value, asked[1]);
      expect(given[0].vout, 1, reason: 'the change first, as the issuance requires');
      // the smallest ready coin that covers each: 12,000 for Y, 15,000 for the witness, 25,000 for the round
      expect(given[2].value, BigInt.from(25000), reason: 'the round is handed the coin whole');
      expect(w.built, hasLength(2), reason: 'two funding transactions a round');
      for (final t in w.built) {
        expect(t.inputs, hasLength(1));
        expect(await chain.minedHeight(t.inputs.single.prevTxnId), isNotNull, reason: 'spends a mined coin');
        expect(_feeOf(t, chain.known), BigInt.from(135));
      }
      expect(w.report.readyCoins, 1, reason: 'the 40,000 coin is left');
      expect(w.report.pendingCoins, 2, reason: 'the two funding transactions\' change');
    });

    test('a round funded from three coins, from a store of 30', () async {
      final (w, chain) = await wallet(amounts: [for (int i = 0; i < 30; i++) 10000 + i * 1000]);
      kinds(w, roundOrder);
      for (final v in [1784, 2205, 942]) {
        await w.output(BigInt.from(v));
      }
      final spentCoins = {for (final t in w.built) t.inputs.single.prevTxnId, w.contents.offered.last.txid};
      expect(spentCoins, hasLength(3));
      for (final id in spentCoins) {
        expect(await chain.minedHeight(id), isNotNull, reason: 'no funding spends an unmined output');
      }
      expect(w.report.readyCoins, 27);
    });

    test('not enough coins: a request larger than every coin fails at once, naming the balance and the largest coin', () async {
      final (w, chain) = await wallet(amounts: [12000]);
      await expectLater(
          w.output(BigInt.from(20000)),
          throwsA(isA<WalletRefusal>()
              .having((e) => e.reason, 'reason', contains('12000 satoshis'))
              .having((e) => e.reason, 'reason', contains('largest coin 12000'))
              .having((e) => e.reason, 'reason', contains('20000'))));
      expect(chain.broadcasts, isEmpty);
    });

    test('waiting for the first split: served within one mined-poll of the split being mined', () async {
      final (w, chain) = await wallet(amounts: [1000000], coins: const CoinsConfig(floor: 10000, target: 10, lowWater: 5));
      await w.reconcile();
      expect(w.report.readyCoins, 0);
      final logs = <String>[];
      final sub = w.log.onRecord.listen((r) => logs.add(r.message));
      final request = w.output(BigInt.from(1784));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(logs.any((m) => m.contains('waits for a ready coin')), isTrue);
      final minedAt = DateTime.now();
      chain.mine();
      final f = (await request)!;
      await sub.cancel();
      expect(DateTime.now().difference(minedAt), lessThan(const Duration(milliseconds: 200)), reason: 'one poll of 20 ms and the broadcast');
      expect(f.value, BigInt.from(1784));
    });

    test('a stranded output is reused, mined or not: after a failed round the next request gets it, and no funding transaction is built', () async {
      final (w, chain) = await wallet();
      final first = (await w.output(BigInt.from(1784)))!;
      expect(w.built, hasLength(1));
      expect(await chain.minedHeight(first.tx.id), isNull, reason: 'unmined');
      // the round fails; nothing spends the output; the server reconciles
      await w.reconcile();
      expect(w.contents.offered, isEmpty);
      expect(w.contents.coins.where((c) => c.returned).single.outpoint, '${first.tx.id}:1');
      final again = (await w.output(BigInt.from(1784)))!;
      expect(again.tx.id, first.tx.id);
      expect(w.built, hasLength(1), reason: 'no funding transaction was built');
      expect(chain.broadcasts, hasLength(1));
    });

    test('a refused funding transaction leaves the coin ready and fails with the chain\'s reason', () async {
      final (w, chain) = await wallet();
      chain.refuse = (_) => 'mempool full';
      final before = File(w.file.path).readAsBytesSync();
      await expectLater(w.output(BigInt.from(1784)), throwsA(isA<WalletRefusal>().having((e) => e.reason, 'reason', contains('mempool full'))));
      expect(w.balance, BigInt.from(100000));
      expect(w.report.readyCoins, 1);
      expect(w.built, isEmpty);
      expect(File(w.file.path).readAsBytesSync(), before, reason: 'nothing written');
    });

    test('a top-up is noticed: pending until mined, ready after', () async {
      final (w, chain) = await wallet(amounts: [12000]);
      chain.listUnmined = true;
      // an operator pays the address; it is in the mempool, not yet mined
      final top = coin(7, 50000);
      await chain.broadcast(top);
      await w.reconcile();
      expect(w.balance, BigInt.from(62000), reason: 'the balance includes it at once');
      expect(w.report.pendingCoins, 1);
      expect(w.report.readyCoins, 1);
      chain.mine();
      await w.reconcile();
      expect(w.report.pendingCoins, 0);
      expect(w.report.readyCoins, 2);
      await w.reconcile();
      expect(w.contents.coins, hasLength(2), reason: 'nothing taken in twice');
    });

    test('rounds left: a round\'s cost counts its two funding fees and its coins\' share of a split', () async {
      final (w, chain) = await wallet(amounts: [40000, 25000, 15000, 12000]);
      w.contents.splitFeePerCoin = BigInt.from(4);
      kinds(w, roundOrder);
      await w.reconcile();
      expect(w.roundsLeft, isNull, reason: 'no round yet');
      final y = (await w.output(BigInt.from(1784)))!;
      final wt = (await w.output(BigInt.from(2205)))!;
      final r = (await w.output(BigInt.from(942)))!;
      // the round spends its coin and returns the surplus less 396 as change
      final round = Transaction()
        ..addInput(TransactionInput(r.tx.id, r.vout, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(r.value - BigInt.from(396), P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));
      final yTx = Transaction()
        ..addInput(TransactionInput(y.tx.id, y.vout, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(BigInt.one, SVScript()));
      final wTx = Transaction()
        ..addInput(TransactionInput(wt.tx.id, wt.vout, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(BigInt.one, SVScript()));
      for (final t in [yTx, round, wTx]) {
        await chain.broadcast(t);
      }
      chain.mine();
      await w.reconcile(roundTxs: [yTx, round, wTx]);
      // Y 1,784 and the witness 2,205 spent whole, the round 396, two funding
      // fees of 135, and three coins' share of a split at 4 each
      expect(w.lastRoundCost, BigInt.from(1784 + 2205 + 396 + 2 * 135 + 3 * 4));
      expect(w.roundsLeft, (w.balance ~/ w.lastRoundCost!).toInt());
    });
  });
}

class _Stopped implements Exception {
  const _Stopped();
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
