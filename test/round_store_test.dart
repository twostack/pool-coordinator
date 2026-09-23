import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/coordinator_setup.dart';
import 'support/pool_test_chain.dart';

/// The store on disk: written before the first broadcast, whole or
/// absent, versioned, the same wherever it is copied, and pruned of old
/// snapshots but never of transactions.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pool-store'));
  tearDown(() => dir.deleteSync(recursive: true));

  Transaction fakeTx(int n) => Transaction()
    ..version = 1
    ..addInput(TransactionInput(hex.encode(List.filled(32, n)), 0, TransactionInput.MAX_SEQ_NUMBER))
    ..addOutput(TransactionOutput(BigInt.one, SVScript()));

  group('with the test chain', () {
    late PoolTestChain c;
    setUpAll(() async => c = await PoolTestChain.build());

    test('files before the first broadcast, and the round reads back equal to what was built', () async {
      final s = CoordinatorSetup(c);
      final store = FileRoundStore(dir.path);
      var completeAtFirstBroadcast = false;
      final co = s.make(
          store: store,
          publish: (tx) async {
            if (s.chain.broadcasts.isEmpty) completeAtFirstBroadcast = store.complete(1);
            await s.chain.broadcast(tx);
          });
      final a = await s.close(co, s.round1);
      expect(a.round, 1);
      expect(completeAtFirstBroadcast, isTrue, reason: 'the four files and the record existed before Y was broadcast');
      expect(s.chain.broadcasts, [a.slotId, a.roundId, a.witnessId]);
      expect(await store.lastNumber(), 1);
      final back = (await store.read(1))!;
      expect(back.y.serialize(), co.ledger.tipSlot.serialize());
      expect(back.round.serialize(), co.ledger.tipRound.serialize());
      expect(back.witness.serialize(), co.ledger.tipWitness.serialize());
      expect(back.snapshot, co.ledger.snapshot());
      expect(await store.read(2), isNull);

      // a copied store: the same round, the same ledger
      final copy = Directory.systemTemp.createTempSync('pool-store-copy');
      try {
        await Process.run('cp', ['-R', '${dir.path}/rounds', copy.path]);
        final other = FileRoundStore(copy.path);
        expect(await other.lastNumber(), 1);
        final there = (await other.read(1))!;
        expect(there.snapshot, back.snapshot);
        expect(there.round.serialize(), back.round.serialize());
        final restored = ShieldedLedger.restore(co.ledger.layout, there.snapshot!);
        expect(restored.round, 1);
        expect(restored.header.encode(), co.ledger.header.encode());
        expect(restored.snapshot(), co.ledger.snapshot());
      } finally {
        copy.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  test('a file cut short is refused naming the round and the file', () async {
    final store = FileRoundStore(dir.path);
    await store.roundBuilt(3, fakeTx(1), fakeTx(2), fakeTx(3), Uint8List.fromList([1, 2, 3]));
    final f = File('${dir.path}/rounds/000003/round.tx');
    final bytes = f.readAsBytesSync();
    f.writeAsBytesSync(bytes.sublist(0, bytes.length - 5));
    await expectLater(
        store.read(3),
        throwsA(isA<StoreRefusal>()
            .having((e) => e.round, 'round', 3)
            .having((e) => e.file, 'file', 'round.tx')
            .having((e) => e.reason, 'reason', contains('cut short'))));
    // a transaction that is whole but not the one recorded is refused too
    f.writeAsBytesSync(hex.decode(fakeTx(9).serialize()));
    await expectLater(store.read(3), throwsA(isA<StoreRefusal>().having((e) => e.reason, 'reason', contains(fakeTx(9).id))));
    // and one with bytes after the end
    f.writeAsBytesSync([...bytes, 0]);
    await expectLater(store.read(3), throwsA(isA<StoreRefusal>().having((e) => e.file, 'file', 'round.tx')));
    File('${dir.path}/rounds/000003/witness.tx').deleteSync();
    f.writeAsBytesSync(bytes);
    await expectLater(store.read(3), throwsA(isA<StoreRefusal>().having((e) => e.file, 'file', 'witness.tx')));
  });

  test('an unknown record version is refused naming the round and the version', () async {
    final store = FileRoundStore(dir.path);
    await store.roundBuilt(2, fakeTx(1), fakeTx(2), fakeTx(3), Uint8List(0));
    final f = File('${dir.path}/rounds/000002/round.json');
    final record = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    expect(record['version'], 1);
    expect(record['round'], fakeTx(2).id);
    f.writeAsStringSync(jsonEncode({...record, 'version': 7}));
    await expectLater(
        store.read(2),
        throwsA(isA<StoreRefusal>()
            .having((e) => e.round, 'round', 2)
            .having((e) => e.reason, 'reason', contains('version 7'))
            .having((e) => e.reason, 'reason', contains('version 1'))));
    f.writeAsStringSync('not json');
    await expectLater(store.read(2), throwsA(isA<StoreRefusal>().having((e) => e.file, 'file', 'round.json')));
  });

  test('old snapshots are pruned, every round\'s transactions remain, and no temporary file stays', () async {
    final store = FileRoundStore(dir.path, keepSnapshots: 2);
    for (int n = 1; n <= 5; n++) {
      await store.roundBuilt(n, fakeTx(n), fakeTx(10 + n), fakeTx(20 + n), Uint8List.fromList([n]));
    }
    for (int n = 1; n <= 5; n++) {
      final d = '${dir.path}/rounds/00000$n';
      expect(File('$d/y.tx').existsSync(), isTrue);
      expect(File('$d/round.tx').existsSync(), isTrue);
      expect(File('$d/witness.tx').existsSync(), isTrue);
      expect(File('$d/snapshot.bin').existsSync(), n >= 4, reason: 'round $n');
      final r = (await store.read(n))!;
      expect(r.round.id, fakeTx(10 + n).id);
      expect(r.snapshot, n >= 4 ? [n] : isNull);
    }
    expect(await store.lastNumber(), 5);
    expect((await store.last())!.snapshot, [5]);
    expect(dir.listSync(recursive: true).where((e) => e.path.endsWith('.tmp')), isEmpty);
    // an empty store
    expect(await FileRoundStore('${dir.path}/none').lastNumber(), isNull);
  });
}
