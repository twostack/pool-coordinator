import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:logging/logging.dart';
import 'package:pool_coordinator/src/metrics/metrics_history.dart';
import 'package:pool_coordinator/src/metrics/metrics_recorder.dart';
import 'package:pool_coordinator/src/metrics/round_facts.dart';
import 'package:pool_coordinator/src/metrics/round_stage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';
import 'support/coordinator_setup.dart';
import 'support/pool_test_chain.dart';

/// The pool's history and live state: what is recorded, from where, and
/// that nothing in it is more than the chain already shows.
void main() {
  late PoolTestChain c;
  setUpAll(() async => c = await PoolTestChain.build());

  group('the real transfer count', () {
    test('read from each witness, it equals the transfers the ledger does not mark as padding', () {
      final ledger = ShieldedLedger.open(ShieldedPoolLayout.of(c.f.agg.tree), c.r0, c.w0, c.y0.tx,
          tokenId: c.tokenId, genesisHeader: c.genesisHeader);
      for (final (round, witness, slot) in [(c.r1, c.w1, c.y1.tx), (c.r2, c.w2, c.y2.tx)]) {
        final applied = ledger.apply(round, witness, slot);
        final real = applied.padding.where((p) => !p).length;
        expect(realTransfersIn(witness), real, reason: 'round ${applied.number}');
        // the fixture's rounds are neither all padding nor full, so the
        // comparison could tell a count of bundles from a count of reals
        expect(real, inInclusiveRange(1, c.f.agg.transfers - 1), reason: 'round ${applied.number}');
      }
    });

    test('a transaction that is not a round witness is refused, not counted', () {
      for (final tx in [c.r1, c.y1.tx, c.depositTx]) {
        expect(() => realTransfersIn(tx), throwsFormatException);
      }
    });
  });

  group('the history on disk', () {
    late Directory dir;
    late String file;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('pool-metrics');
      file = p.join(dir.path, 'metrics.sqlite');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    final t0 = DateTime.utc(2026, 9, 23, 12);
    RoundRecord row(int n, {int? proving, int? cost, DateTime? at, int? height, int transfers = 2, int? balance}) => RoundRecord(
        number: n,
        y: 'y$n',
        round: 'r$n',
        witness: 'w$n',
        transfers: transfers,
        capacity: 4,
        balance: balance ?? 1000 + n,
        cost: cost,
        buildMs: proving == null ? null : proving + 100,
        provingMs: proving,
        publishedAt: at,
        minedHeight: height);

    test('a new file is version 1 in WAL mode, and a round reads back as recorded', () {
      final h = MetricsHistory.open(file);
      final r = row(1, proving: 900, cost: 4790, at: t0, height: 101);
      h.record(r);
      expect(h.read(1), r);
      expect(h.read(2), isNull);
      h.close();
      final raw = sqlite3.open(file);
      expect(raw.userVersion, 1);
      expect(raw.select('PRAGMA journal_mode').single.values.single, 'wal');
      raw.dispose();
      final again = MetricsHistory.open(file);
      expect(again.movedAside, isNull);
      expect(again.read(1), r);
      again.close();
    });

    test('a measured round replaces a rebuilt row, and a rebuild never overwrites a measured one', () {
      final h = MetricsHistory.open(file);
      h.recordIfAbsent(row(1));
      h.record(row(1, proving: 900, at: t0));
      expect(h.read(1)!.provingMs, 900);
      h.recordIfAbsent(row(1));
      expect(h.read(1)!.provingMs, 900);
      expect(h.numbers(), [1]);
      h.close();
    });

    test('cost and mined are filled in later, and unmined lists what is left, oldest first', () {
      final h = MetricsHistory.open(file);
      for (final n in [3, 1, 2]) {
        h.record(row(n, at: t0.add(Duration(minutes: n))));
      }
      h.setCost(2, 4790);
      h.setMined(2, 102, t0.add(const Duration(minutes: 5)));
      h.setMined(1, 101, null);
      expect(h.read(2)!.cost, 4790);
      expect(h.read(2)!.minedHeight, 102);
      expect(h.read(2)!.minedAt, t0.add(const Duration(minutes: 5)));
      expect(h.read(1)!.minedAt, isNull);
      expect(h.unmined().map((r) => r.number), [3]);
      h.close();
    });

    test('pages run newest first below a number, with the limit held to 1..100', () {
      final h = MetricsHistory.open(file);
      for (int n = 1; n <= 150; n++) {
        h.record(row(n));
      }
      expect(h.page(limit: 3).map((r) => r.number), [150, 149, 148]);
      expect(h.page(before: 3, limit: 5).map((r) => r.number), [2, 1]);
      expect(h.page(before: 1), isEmpty);
      expect(h.page(limit: 0).length, 1);
      expect(h.page(limit: 1000).length, 100);
      h.close();
    });

    test('stats: nothing recorded gives nulls, not zeros', () {
      final h = MetricsHistory.open(file);
      final s = h.stats();
      expect((s.roundsMined, s.transfers, s.tip, s.medianInterval, s.medianProving, s.meanCost, s.firstPublished),
          (0, 0, null, null, null, null, null));
      h.close();
    });

    test('stats: medians and the mean over the recent rounds, intervals only between consecutive timed rounds', () {
      final h = MetricsHistory.open(file);
      // rounds 1 to 4 ten minutes apart, 5 rebuilt without times, 6 and 7 six minutes apart
      for (int n = 1; n <= 4; n++) {
        h.record(row(n, proving: 1000 * n, cost: 100 * n, at: t0.add(Duration(minutes: 10 * n)), height: 100 + n, transfers: n));
      }
      h.recordIfAbsent(row(5, height: 105, transfers: 1));
      h.record(row(6, proving: 9000, at: t0.add(const Duration(minutes: 70)), transfers: 1));
      h.record(row(7, proving: 9000, at: t0.add(const Duration(minutes: 76)), height: 107, transfers: 1));
      final s = h.stats();
      expect(s.roundsMined, 6);
      expect(s.transfers, 1 + 2 + 3 + 4 + 1 + 1 + 1);
      expect(s.tip, 7);
      // gaps 10, 10, 10 and 6 minutes: none across the untimed round 5
      expect(s.medianInterval, const Duration(minutes: 10));
      // proving 1, 2, 3, 4, 9, 9 seconds
      expect(s.medianProving, const Duration(milliseconds: 3500));
      expect(s.meanCost, 250);
      expect(s.firstPublished, t0.add(const Duration(minutes: 10)));
      h.close();
    });

    test('series: per hour, empty buckets left out, the balance at each bucket\'s last round', () {
      final h = MetricsHistory.open(file);
      h.record(row(1, proving: 1000, cost: 100, at: t0.add(const Duration(minutes: 5)), transfers: 1, balance: 500));
      h.record(row(2, proving: 3000, cost: 300, at: t0.add(const Duration(minutes: 50)), transfers: 3, balance: 700));
      h.record(row(3, proving: 2000, at: t0.add(const Duration(hours: 2, minutes: 1)), transfers: 2, balance: 400));
      h.recordIfAbsent(row(4, transfers: 4)); // untimed: in no bucket
      final range = (from: t0, to: t0.add(const Duration(days: 1)));
      List<(DateTime, num)> of(SeriesMetric m) =>
          [for (final pt in h.series(m, SeriesBucket.hour, from: range.from, to: range.to)) (pt.at, pt.value)];
      final h2 = t0.add(const Duration(hours: 2));
      expect(of(SeriesMetric.rounds), [(t0, 2), (h2, 1)]);
      expect(of(SeriesMetric.transfers), [(t0, 4), (h2, 2)]);
      expect(of(SeriesMetric.balance), [(t0, 700), (h2, 400)]);
      expect(of(SeriesMetric.cost), [(t0, 200)]);
      expect(of(SeriesMetric.proving), [(t0, 2000), (h2, 2000)]);
      expect(h.series(SeriesMetric.rounds, SeriesBucket.day, from: t0, to: range.to).single.value, 3);
      expect(h.series(SeriesMetric.rounds, SeriesBucket.hour, from: t0.add(const Duration(hours: 1)), to: range.to).single.at, h2);
      h.close();
    });

    test('series: at most 1,000 points, the newest kept', () {
      final h = MetricsHistory.open(file);
      for (int n = 1; n <= 1200; n++) {
        h.record(row(n, at: t0.add(Duration(hours: n))));
      }
      final pts = h.series(SeriesMetric.rounds, SeriesBucket.hour, from: t0, to: t0.add(const Duration(days: 60)));
      expect(pts.length, MetricsHistory.maxPoints);
      expect(pts.last.at, t0.add(const Duration(hours: 1200)));
      expect(pts.first.at, t0.add(const Duration(hours: 201)));
      h.close();
    });

    test('a file that is not a database is moved aside whole and a fresh history started', () {
      final junk = List.generate(4096, (i) => (i * 7) & 0xff);
      File(file).writeAsBytesSync(junk);
      final h = MetricsHistory.open(file);
      expect(h.movedAside, isNotNull);
      expect(File(h.movedAside!).readAsBytesSync(), junk);
      expect(h.numbers(), isEmpty);
      h.record(row(1));
      expect(h.numbers(), [1]);
      h.close();
    });

    test('a history of another version, or a database of something else, is moved aside', () {
      final v2 = sqlite3.open(file)
        ..execute('CREATE TABLE rounds (number INTEGER PRIMARY KEY)')
        ..execute('INSERT INTO rounds VALUES (9)')
        ..userVersion = 2;
      v2.dispose();
      final h = MetricsHistory.open(file);
      expect(h.movedAside, isNotNull);
      expect(h.numbers(), isEmpty);
      h.close();

      final other = p.join(dir.path, 'other.sqlite');
      sqlite3.open(other)
        ..execute('CREATE TABLE notes (x TEXT)')
        ..dispose();
      final h2 = MetricsHistory.open(other);
      expect(h2.movedAside, isNotNull);
      h2.close();
    });
  });

  group('the stage of a round', () {
    test('pin: the library laps a real round in the order the stage table expects', () async {
      final s = CoordinatorSetup(c);
      // the stage as the recorder sees it on each publish call, the
      // library's timing having been lapped as the round went
      final atPublish = <RoundStage>[];
      late final ShieldedCoordinator co;
      co = s.make(
          store: FakeStore(),
          publish: (tx) async {
            atPublish.add(stageOf(co.lastTiming!.stages.keys));
            await s.chain.broadcast(tx);
          });
      await s.close(co, s.round1);
      expect(co.lastTiming!.stages.keys.toList(), libraryLaps,
          reason: 'the library\'s stages changed; update libraryLaps and stageAfter in round_stage.dart');
      expect(stageAfter.keys.toList(), libraryLaps, reason: 'the stage table names a stage the library does not lap');
      expect(atPublish, [RoundStage.broadcast, RoundStage.broadcast, RoundStage.broadcast]);
      // a real round is proved here, which a small CI runner takes longer than the default 30 s to do
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the stage only moves forward through proving, funding and broadcast as laps accumulate', () {
      final seen = [for (int i = 0; i <= libraryLaps.length; i++) stageOf(libraryLaps.take(i))];
      expect(seen.first, RoundStage.proving);
      expect(seen.last, RoundStage.broadcast);
      for (int i = 1; i < seen.length; i++) {
        expect(seen[i].index, greaterThanOrEqualTo(seen[i - 1].index));
      }
      expect(stageOf(['expiry', 'funding', 'padding', 'trees', 'aggregation']), RoundStage.proving);
      expect(stageOf(['expiry', 'funding', 'padding', 'trees', 'aggregation', 'root unlock']), RoundStage.funding);
      expect(stageOf([...libraryLaps.take(11), 'store']), RoundStage.broadcast);
      // a lap the table does not know holds the stage, never moves it back
      expect(stageOf([...libraryLaps.take(8), 'renamed']), RoundStage.funding);
    });
  });

  group('the recorder', () {
    late Directory dir;
    late MetricsHistory history;
    late FakeClock clock;
    late MetricsRecorder rec;
    late List<LiveState> changes;
    final logged = <LogRecord>[];
    final log = Logger.detached('metrics-test')..onRecord.listen(logged.add);
    setUp(() {
      dir = Directory.systemTemp.createTempSync('pool-recorder');
      history = MetricsHistory.open(p.join(dir.path, 'metrics.sqlite'));
      clock = FakeClock(DateTime.utc(2026, 9, 23, 12));
      rec = MetricsRecorder(history, capacity: 4, clock: clock, log: log);
      changes = [];
      rec.changes.listen(changes.add);
      logged.clear();
    });
    tearDown(() async {
      await rec.close();
      dir.deleteSync(recursive: true);
    });

    RoundTiming timing(Map<String, int> ms) => RoundTiming()..stages.addAll({for (final e in ms.entries) e.key: Duration(milliseconds: e.value)});
    final fullTiming = {for (int i = 0; i < libraryLaps.length; i++) libraryLaps[i]: 10 * (i + 1)};

    test('assembling carries the deadline, and idle clears it', () {
      final deadline = clock.now.add(const Duration(minutes: 10));
      rec.observe(assembling: true, deadline: deadline, tipRound: 0);
      expect(rec.live, LiveState(assembling: true, deadline: deadline));
      rec.observe(assembling: true, deadline: deadline, tipRound: 0);
      expect(changes, hasLength(1), reason: 'an unchanged state is not a change');
      rec.observe(assembling: false, deadline: deadline, tipRound: 0);
      expect(rec.live, LiveState.idle);
      expect(changes, hasLength(2));
    });

    test('a round being built moves through its stages, and is numbered past the tip until it applies', () {
      final seen = <LiveRound>[];
      for (int i = 0; i <= libraryLaps.length; i++) {
        final laps = libraryLaps.take(i).toList();
        // the ledger is at round 1 until the build's apply lap, then at 2
        rec.observe(assembling: false, tipRound: laps.contains('apply') ? 2 : 1, laps: laps);
        seen.add(rec.live.rounds.single);
      }
      expect(seen.every((r) => r.number == 2), isTrue);
      expect(seen.map((r) => r.stage).toSet().toList(), [RoundStage.proving, RoundStage.funding, RoundStage.broadcast]);
      // a tick that reads fewer laps than the last one does not move it back
      rec.observe(assembling: false, tipRound: 1, laps: libraryLaps.take(3));
      expect(rec.live.rounds.single, const LiveRound(2, RoundStage.broadcast));
      // the build ends without a publish (a failure): it leaves the live state
      rec.observe(assembling: false, tipRound: 1);
      expect(rec.live.rounds, isEmpty);
    });

    test('a published round is recorded from its transactions and timing, in flight until mined', () async {
      final mined = <RoundRecord>[];
      rec.minedRounds.listen(mined.add);
      rec.observe(assembling: false, tipRound: 1, laps: libraryLaps.take(12));
      rec.roundPublished(PoolAnnouncement.of(1, c.f.h1, c.r1, c.w1, c.y1.tx, blockRoot: List.filled(32, 0)), c.w1, timing(fullTiming));
      final r = history.read(1)!;
      expect((r.y, r.round, r.witness), (c.y1.tx.id, c.r1.id, c.w1.id));
      expect(r.transfers, realTransfersIn(c.w1));
      expect(r.capacity, 4);
      expect(r.balance, c.f.h1.balance.toInt());
      expect(r.provingMs, fullTiming['trees']! + fullTiming['aggregation']! + fullTiming['root unlock']!);
      expect(r.buildMs, [for (final l in buildLaps) fullTiming[l]!].reduce((a, b) => a + b));
      expect(r.publishedAt, clock.now);
      expect(r.cost, isNull);
      expect(r.mined, isFalse);
      // the build is over; the round waits for its block
      rec.observe(assembling: true, deadline: clock.now.add(const Duration(minutes: 10)), tipRound: 1);
      expect(rec.live.rounds, [const LiveRound(1, RoundStage.broadcast)]);

      rec.costKnown(1, BigInt.from(4790));
      expect(history.read(1)!.cost, 4790);
      clock.advance(const Duration(minutes: 3));
      rec.mined(1, 812);
      expect(history.read(1)!.minedHeight, 812);
      expect(history.read(1)!.minedAt, clock.now);
      expect(rec.live.rounds, isEmpty);
      expect(mined.single.number, 1);
      expect(mined.single.minedHeight, 812);
    });

    test('a round already published is never shown as being built again, whatever the timing still says', () {
      rec.roundPublished(PoolAnnouncement.of(1, c.f.h1, c.r1, c.w1, c.y1.tx, blockRoot: List.filled(32, 0)), c.w1, timing(fullTiming));
      rec.mined(1, 700);
      expect(rec.live.rounds, isEmpty);
      // a tick after the publish, before the server sees the build end
      rec.observe(assembling: false, tipRound: 1, laps: libraryLaps);
      expect(rec.live.rounds, isEmpty);
      // the next build is round 2
      rec.observe(assembling: false, tipRound: 1, laps: const []);
      expect(rec.live.rounds, [const LiveRound(2, RoundStage.proving)]);
    });

    test('a timing without every proving lap records no proving time rather than a wrong one', () {
      rec.roundPublished(PoolAnnouncement.of(1, c.f.h1, c.r1, c.w1, c.y1.tx, blockRoot: List.filled(32, 0)), c.w1, timing({'expiry': 1, 'funding': 2}));
      expect(history.read(1)!.provingMs, isNull);
      expect(history.read(1)!.buildMs, isNull);
      rec.roundPublished(PoolAnnouncement.of(2, c.f.h2, c.r2, c.w2, c.y2.tx, blockRoot: List.filled(32, 0)), c.w2, null);
      expect(history.read(2)!.provingMs, isNull);
    });

    test('at start, rounds published and unmined are in flight again; rebuilt rows are not', () async {
      rec.roundPublished(PoolAnnouncement.of(1, c.f.h1, c.r1, c.w1, c.y1.tx, blockRoot: List.filled(32, 0)), c.w1, null);
      history.recordIfAbsent(RoundRecord(
          number: 2, y: c.y2.tx.id, round: c.r2.id, witness: c.w2.id, transfers: 1, capacity: 4, balance: c.f.h2.balance.toInt()));
      final again = MetricsRecorder(history, capacity: 4, clock: clock, log: log);
      expect(again.live.rounds, [const LiveRound(1, RoundStage.broadcast)]);
      // the rebuilt round's height comes without an observation time
      again.mined(2, 900);
      expect(history.read(2)!.minedHeight, 900);
      expect(history.read(2)!.minedAt, isNull);
    });

    test('a history that fails is logged and swallowed, never thrown to the server', () {
      history.close();
      rec.roundPublished(PoolAnnouncement.of(1, c.f.h1, c.r1, c.w1, c.y1.tx, blockRoot: List.filled(32, 0)), c.w1, null);
      rec.costKnown(1, BigInt.one);
      rec.mined(1, 1);
      rec.observe(assembling: true, deadline: clock.now, tipRound: 0);
      expect(logged.where((r) => r.level == Level.WARNING).length, 3);
      expect(logged.first.message, contains('recording round 1'));
      expect(rec.live.assembling, isTrue, reason: 'the live state lives in memory and goes on');
    });

    test('a witness that is not one is logged, and nothing is recorded', () {
      rec.roundPublished(PoolAnnouncement.of(1, c.f.h1, c.r1, c.r1, c.y1.tx, blockRoot: List.filled(32, 0)), c.r1, null);
      expect(history.read(1), isNull);
      expect(logged.single.message, contains('recording round 1'));
    });
  });
}
