import 'dart:convert';
import 'dart:io';

import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:path/path.dart' as p;
import 'package:pool_coordinator/src/api/pool_api.dart';
import 'package:pool_coordinator/src/api/publication_gate.dart';
import 'package:pool_coordinator/src/config.dart';
import 'package:pool_coordinator/src/metrics/metrics_history.dart';
import 'package:pool_coordinator/src/metrics/metrics_recorder.dart';
import 'package:pool_coordinator/src/metrics/round_stage.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/http.dart';
import 'support/pool_test_chain.dart';

/// The read-only API over a history and a recorder on a fake clock: its
/// routes, what it refuses, the coarse times, and the event stream.
void main() {
  late PoolTestChain c;
  setUpAll(() async => c = await PoolTestChain.build());

  late Directory dir;
  late MetricsHistory history;
  late FakeClock clock;
  late MetricsRecorder recorder;
  late PublicationGate gate;
  late PoolApi api;
  const interval = Duration(seconds: 30);

  Future<void> startApi({int maxSubscribers = 200, Duration heartbeat = const Duration(seconds: 15)}) async {
    gate = PublicationGate(recorder, interval: interval, clock: clock);
    api = await PoolApi.start(
      config: ApiConfig(
          bind: InternetAddress.loopbackIPv4,
          port: 0,
          metricsFile: history.path,
          publishInterval: interval,
          maxSubscribers: maxSubscribers),
      facts: PoolFacts(
          network: NetworkType.TEST,
          plan: 'test',
          capacity: 4,
          issuance: c.r0.id,
          witness0: c.w0.id,
          slot0: c.y0.tx.id,
          roundDeadline: const Duration(minutes: 10),
          explorer: 'test'),
      source: recorder,
      gate: gate,
      heartbeat: heartbeat,
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pool-api');
    history = MetricsHistory.open(p.join(dir.path, 'metrics.sqlite'));
    // an arbitrary second, so nothing lands on the interval by accident
    clock = FakeClock(DateTime.utc(2026, 9, 23, 12, 0, 7));
    recorder = MetricsRecorder(history, capacity: 4, clock: clock);
  });

  tearDown(() async {
    await api.close();
    await gate.close();
    await recorder.close();
    dir.deleteSync(recursive: true);
  });

  /// Rounds 1 and 2 of the test chain, published and mined at odd seconds.
  void twoRounds() {
    recorder.roundPublished(PoolAnnouncement.of(1, c.f.h1, c.r1, c.w1, c.y1.tx, blockRoot: List.filled(32, 0)), c.w1, null);
    clock.advance(const Duration(seconds: 41));
    recorder.mined(1, 101);
    clock.advance(const Duration(minutes: 7, seconds: 3));
    recorder.roundPublished(PoolAnnouncement.of(2, c.f.h2, c.r2, c.w2, c.y2.tx, blockRoot: List.filled(32, 0)), c.w2, null);
    clock.advance(const Duration(seconds: 19));
    recorder.mined(2, 102);
  }

  group('routes', () {
    test('paging rounds: newest first, and the next page named until round 1', () async {
      await startApi();
      twoRounds();
      final first = await getJson(api.port, '/api/rounds?limit=1');
      expect([for (final r in first['rounds'] as List) r['number']], [2]);
      expect(first['next'], 2);
      final second = await getJson(api.port, '/api/rounds?before=2&limit=1');
      expect([for (final r in second['rounds'] as List) r['number']], [1]);
      expect(second['next'], isNull);
      final all = await getJson(api.port, '/api/rounds');
      final r1 = (all['rounds'] as List).last as Map<String, dynamic>;
      expect(r1['y'], c.y1.tx.id);
      expect(r1['round'], c.r1.id);
      expect(r1['witness'], c.w1.id);
      expect(r1['minedHeight'], 101);
      expect(r1['capacity'], 4);
    });

    test('a page below a round whose rounds are all mined may be cached for good; the newest page may not', () async {
      await startApi();
      twoRounds();
      expect((await request(api.port, '/api/rounds?before=3')).headers.value('cache-control'), contains('immutable'));
      expect((await request(api.port, '/api/rounds')).headers.value('cache-control'), 'no-store');
      recorder.roundPublished(PoolAnnouncement.of(3, c.f.h2, c.r2, c.w2, c.y2.tx, blockRoot: List.filled(32, 0)), c.w2, null);
      expect((await request(api.port, '/api/rounds?before=4')).headers.value('cache-control'), 'no-store', reason: 'round 3 is unmined');
    });

    test('the pool route names the pool, its tip and balance, and the live state', () async {
      await startApi();
      twoRounds();
      final pool = await getJson(api.port, '/api/pool');
      expect(pool['network'], 'test');
      expect(pool['explorer'], 'test');
      expect(pool['plan'], 'test');
      expect(pool['capacity'], 4);
      expect(pool['genesis'], {'issuance': c.r0.id, 'witness0': c.w0.id, 'slot0': c.y0.tx.id});
      expect(pool['tip'], 2);
      expect(pool['balance'], c.f.h2.balance.toInt());
      expect(pool['roundDeadlineSeconds'], 600);
      expect(pool['publishIntervalSeconds'], 30);
      expect(pool['live'], containsPair('assembling', false));
    });

    test('stats and series answer from the history, with a dash-worthy null where nothing is known', () async {
      await startApi();
      final empty = await getJson(api.port, '/api/stats');
      expect(empty['roundsMined'], 0);
      expect(empty['meanCost'], isNull);
      twoRounds();
      final stats = await getJson(api.port, '/api/stats');
      expect(stats['roundsMined'], 2);
      expect(stats['transfers'], history.read(1)!.transfers + history.read(2)!.transfers);
      expect(stats['tip'], 2);
      expect(stats['medianIntervalSeconds'], isNotNull);
      final series = await getJson(api.port, '/api/series?metric=rounds&bucket=day');
      expect(series['metric'], 'rounds');
      expect([for (final pt in series['points'] as List) pt['value']], [2]);
    });

    test('writes refused on every route, and nothing changes', () async {
      await startApi();
      twoRounds();
      final before = history.page(limit: 100);
      for (final path in ['/api/pool', '/api/rounds', '/api/stats', '/api/series?metric=rounds', '/api/events', '/api/nothing']) {
        for (final m in ['POST', 'PUT', 'DELETE', 'PATCH']) {
          final a = await request(api.port, path, method: m);
          expect(a.status, 405, reason: '$m $path');
          expect(a.headers.value('allow'), 'GET, HEAD');
          expect(jsonDecode(a.body)['v'], 1);
        }
      }
      expect(history.page(limit: 100), before);
    });

    test('version on every route, HEAD answers without a body, and an unknown path is a JSON 404', () async {
      await startApi();
      twoRounds();
      for (final path in ['/api/pool', '/api/rounds', '/api/stats', '/api/series?metric=balance']) {
        final a = await request(api.port, path);
        expect(a.status, 200, reason: path);
        expect(a.headers.contentType?.mimeType, 'application/json');
        expect(jsonDecode(a.body)['v'], 1, reason: path);
        final h = await request(api.port, path, method: 'HEAD');
        expect(h.status, 200);
        expect(h.body, isEmpty);
      }
      final events = await EventClient.connect(api.port);
      await events.until(() => events.events.isNotEmpty);
      expect(events.events.first.data['v'], 1);
      await events.close();
      for (final path in ['/', '/api', '/api/pool/', '/api/Pool', '/index.html']) {
        final a = await request(api.port, path);
        expect(a.status, 404, reason: path);
        expect(jsonDecode(a.body), {'v': 1, 'error': 'no such route'});
      }
    });

    test('bad parameters are a 400 naming the parameter; a long request line a 414', () async {
      await startApi();
      for (final (path, name) in [
        ('/api/rounds?limit=0', 'limit'),
        ('/api/rounds?limit=101', 'limit'),
        ('/api/rounds?limit=-1', 'limit'),
        ('/api/rounds?before=x', 'before'),
        ('/api/rounds?before=0', 'before'),
        ('/api/rounds?before=99999999999999999999', 'before'),
        ('/api/rounds?sort=asc', 'sort'),
        ('/api/series', 'metric'),
        ('/api/series?metric=wallet', 'metric'),
        ('/api/series?metric=rounds&bucket=minute', 'bucket'),
        ('/api/series?metric=rounds&from=10&to=5', 'from'),
      ]) {
        final a = await request(api.port, path);
        expect(a.status, 400, reason: path);
        expect(jsonDecode(a.body)['error'], contains(name), reason: path);
      }
      final long = await request(api.port, '/api/rounds?limit=1&x=${'a' * 2100}');
      expect(long.status, 414);
    });
  });

  group('coarse time', () {
    test('every time served is a multiple of the interval, the deadline rounded up, and live events at least an interval apart', () async {
      await startApi();
      final live = <LiveEvent>[];
      gate.events.listen((e) {
        if (e is LiveEvent) live.add(e);
      });
      final events = await EventClient.connect(api.port);
      // a round opens at an odd second, is built, published and mined at others
      recorder.observe(assembling: true, deadline: clock.now.add(const Duration(minutes: 10)), tipRound: 0);
      clock.advance(const Duration(seconds: 11));
      recorder.observe(assembling: false, tipRound: 0, laps: libraryLaps.take(3));
      clock.advance(const Duration(seconds: 3));
      recorder.observe(assembling: false, tipRound: 0, laps: libraryLaps.take(7));
      clock.advance(const Duration(seconds: 17));
      recorder.observe(assembling: true, deadline: clock.now.add(const Duration(minutes: 10)), tipRound: 1, laps: libraryLaps.take(12));
      clock.advance(const Duration(seconds: 4));
      twoRounds();
      for (int i = 0; i < 6; i++) {
        clock.advance(Duration(seconds: 7 + 13 * i));
      }
      await events.until(() => events.events.where((e) => e.event == 'round').length == 2);

      expect(live, isNotEmpty);
      for (int i = 0; i < live.length; i++) {
        expect(live[i].at.millisecondsSinceEpoch % interval.inMilliseconds, 0);
        if (i > 0) expect(live[i].at.difference(live[i - 1].at), greaterThanOrEqualTo(interval));
        final d = live[i].state.deadline;
        if (d != null) expect(d.millisecondsSinceEpoch % interval.inMilliseconds, 0);
      }
      final bodies = [
        for (final path in ['/api/pool', '/api/rounds', '/api/stats', '/api/series?metric=rounds&bucket=hour']) (await request(api.port, path)).body,
        for (final e in events.events) jsonEncode(e.data),
      ];
      final times = <int>[];
      void walk(Object? v, [String? key]) {
        if (v is Map) {
          v.forEach((k, x) => walk(x, k as String));
        } else if (v is List) {
          v.forEach(walk);
        } else if (v is int && const {'at', 'closesBy', 'publishedAt', 'minedAt', 'firstPublishedAt', 't'}.contains(key)) {
          times.add(v);
        }
      }

      for (final b in bodies) {
        walk(jsonDecode(b));
      }
      expect(times, isNotEmpty);
      expect(times.where((t) => t % interval.inSeconds != 0), isEmpty);
      await events.close();
    });
  });

  group('the event stream', () {
    test('a round mined reaches a subscriber at the next tick, then the live state without it', () async {
      await startApi();
      recorder.roundPublished(PoolAnnouncement.of(1, c.f.h1, c.r1, c.w1, c.y1.tx, blockRoot: List.filled(32, 0)), c.w1, null);
      clock.advance(interval);
      final events = await EventClient.connect(api.port);
      await events.until(() => events.events.isNotEmpty);
      expect(events.events.first.event, 'live');
      expect(events.events.first.data['rounds'], [
        {'number': 1, 'stage': 'broadcast'},
      ]);
      recorder.mined(1, 101);
      expect(events.events, hasLength(1), reason: 'nothing leaves before the tick');
      final sw = Stopwatch()..start();
      clock.advance(interval);
      await events.until(() => events.events.length == 3, timeout: const Duration(seconds: 2));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(events.events[1].event, 'round');
      expect(events.events[1].data['round']['number'], 1);
      expect(events.events[1].data['round']['minedHeight'], 101);
      expect(events.events[2].event, 'live');
      expect(events.events[2].data['rounds'], isEmpty);
      await events.close();
    });

    test('subscriber cap: one more gets 503, and those connected keep receiving', () async {
      // a client's leaving is noticed at the next write, which the heartbeat
      // guarantees; a short one keeps the test short
      await startApi(maxSubscribers: 2, heartbeat: const Duration(milliseconds: 200));
      final a = await EventClient.connect(api.port), b = await EventClient.connect(api.port);
      await a.until(() => a.events.isNotEmpty);
      await b.until(() => b.events.isNotEmpty);
      final third = await request(api.port, '/api/events');
      expect(third.status, 503);
      expect(jsonDecode(third.body)['v'], 1);
      recorder.observe(assembling: true, deadline: clock.now.add(const Duration(minutes: 10)), tipRound: 0);
      clock.advance(interval);
      await a.until(() => a.events.length == 2);
      await b.until(() => b.events.length == 2);
      expect(a.events.last.data['assembling'], isTrue);
      // a subscriber that leaves frees its place by the next heartbeat
      await a.close();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (api.subscribers > 1 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final c3 = await EventClient.connect(api.port);
      expect(c3.status, 200);
      await c3.close();
      await b.close();
    });

    test('a heartbeat comment keeps an idle stream open', () async {
      await startApi(heartbeat: const Duration(milliseconds: 100));
      final e = await EventClient.connect(api.port);
      await e.until(() => e.comments.length >= 2);
      expect(e.comments.first, ': heartbeat');
      await e.close();
    });
  });
}
