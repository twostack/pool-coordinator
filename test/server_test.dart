import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:pool_coordinator/src/metrics/metrics_history.dart';
import 'package:pool_coordinator/src/metrics/metrics_recorder.dart';
import 'package:pool_coordinator/src/metrics/round_stage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';
import 'support/coordinator_setup.dart';
import 'support/http.dart';
import 'support/pool_test_chain.dart';
import 'support/test_keys.dart';

/// The server on the fakes and the library's test chain: two rounds
/// through the inbox, what the status and the feed say, what a restart
/// recovers, what it re-broadcasts, what it refuses, and what a stop
/// leaves behind.
void main() {
  late PoolTestChain c;
  late _Run run;
  final rng = Random(11);
  final logRecords = <LogRecord>[];

  setUpAll(() async {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen(logRecords.add);
    c = await PoolTestChain.build();
    run = await _Run.twoRounds(c, rng);
  });

  tearDownAll(() => run.dispose());

  Future<void> until(Future<bool> Function() cond, {Duration timeout = const Duration(minutes: 3), String? what}) async {
    final deadline = DateTime.now().add(timeout);
    while (!await cond()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for ${what ?? 'the condition'}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  group('two rounds of the test chain through the server', () {
    test('a submission is answered within 2 s with an accepted reply naming the round, and the pending count rises', () {
      for (final r in run.replies1) {
        expect(r.reply.isAccepted, isTrue, reason: '${r.reply}');
        expect(r.reply.round, 1);
        expect(r.elapsed, lessThan(const Duration(seconds: 2)));
      }
      expect(run.pendingAfterFirst, 1);
    });

    test('both rounds are mined, the feed holds two announcements after the descriptor, and a reader from the descriptor reaches the status\'s header', () async {
      expect(run.chain.broadcasts, [run.a1.slotId, run.a1.roundId, run.a1.witnessId, run.a2.slotId, run.a2.roundId, run.a2.witnessId]);
      for (final id in run.chain.broadcasts) {
        expect(run.chain.minedAt[id], isNotNull);
      }
      final feed = run.transport.entries;
      expect(feed, hasLength(3));
      final d = PoolMessage.decode(feed[0]) as PoolDescriptor;
      expect(hex.encode(d.issuance), c.r0.id);
      expect(hex.encode(d.witness0), c.w0.id);
      expect(hex.encode(d.slot0), c.y0.tx.id);
      final a1 = PoolMessage.decode(feed[1]) as PoolAnnouncement, a2 = PoolMessage.decode(feed[2]) as PoolAnnouncement;
      expect(a1.round, 1);
      expect(a2.round, 2);
      // a reader opened from the descriptor and fed the announced triples
      final reader = ShieldedChainReader.open(d.layout, c.r0, c.w0, c.y0.tx, tokenId: d.tokenId, genesisHeader: d.genesisHeader);
      for (final a in [a1, a2]) {
        final round = run.chain.known[a.roundId]!, witness = run.chain.known[a.witnessId]!, slot = run.chain.known[a.slotId]!;
        final applied = reader.read([(round: round, witness: witness, nextSlot: slot)]);
        expect(reader.stopped, isFalse, reason: '${reader.refusal}');
        expect(a.disagreement(applied.single), isNull);
      }
      final status = run.statusAfterRound2;
      expect(status['tip']['round'], 2);
      expect(status['tip']['roundTx'], a2.roundId);
      expect(reader.ledger.tipRound.id, status['tip']['roundTx']);
      expect(reader.ledger.snapshot(), run.snapshotAfterRound2);
    });

    test('status after a round names the round, its three txids and the wallet\'s balance after paying it', () {
      final s = run.statusAfterRound1;
      expect(s['tip']['round'], 1);
      expect(s['tip']['y'], run.a1.slotId);
      expect(s['tip']['roundTx'], run.a1.roundId);
      expect(s['tip']['witness'], run.a1.witnessId);
      expect(s['wallet']['balance'], run.balanceAfterRound1.toString());
      expect(BigInt.parse(s['wallet']['balance'] as String), lessThan(run.balanceBefore));
      expect(s['lastAnnouncement']['round'], 1);
      expect(s['lastAnnouncement']['sequence'], 2);
      expect(s['ready'], isTrue);
      expect(s['submissions']['accepted'], 4);
      expect(run.wallet.asked, hasLength(6), reason: 'three funding outputs a round');
    });

    test('nothing secret in the output: the log and the status hold no owner key, seed or submitted transfer', () {
      final text = [for (final r in logRecords) r.message, run.statusText].join('\n');
      expect(text, isNot(contains(opKey.toHex())));
      expect(text, isNot(contains(opKey.toWIF())));
      expect(text, isNot(contains(hex.encode(run.seed))));
      for (final t in run.transfers) {
        final h = hex.encode(t);
        expect(text, isNot(contains(h)));
        expect(text, isNot(contains(h.substring(0, 64))));
        expect(text, isNot(contains(base64.encode(t))));
      }
      expect(text, contains('accepted into round 1'), reason: 'the log names outcomes');
    });

    test('restart after two rounds: the ledger equals the one it stopped with, the status reports round 2, and a new submission is accepted', () async {
      final again = await run.restart();
      try {
        expect(again.server.co.ledger.snapshot(), run.snapshotAfterRound2);
        expect(again.server.co.ledger.round, 2);
        final s = jsonDecode(File(again.config.server.statusFile).readAsStringSync());
        expect(s['tip']['round'], 2);
        expect(s['tip']['witness'], run.a2.witnessId);
        expect(again.chain.broadcasts, isEmpty, reason: 'everything was on the chain');
        // snapshot restored: no round was read from the chain
        expect(again.chain.fetches, 3, reason: 'the genesis only');
        final padding = c.f.transfers2[1];
        final bytes = PoolSubmission.of(padding, c.f.agg.spendP, rng: rng).encode();
        again.transport.send('w9', bytes);
        await until(() async => again.transport.replies['w9'] != null, what: 'a reply');
        final r = PoolReply.decode(again.transport.replies['w9']!.single);
        expect(r.isAccepted, isTrue, reason: '$r');
        expect(r.round, 3);
        expect(again.server.co.pending, 1);
      } finally {
        await again.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('start and recovery', () {
    test('a stored round the chain does not show is re-broadcast in order, and the server starts once mined', () async {
      final again = await run.restart(before: (chain) {
        for (final id in [run.a2.slotId, run.a2.roundId, run.a2.witnessId]) {
          chain.forget(id);
        }
      });
      try {
        expect(again.chain.broadcasts, [run.a2.slotId, run.a2.roundId, run.a2.witnessId]);
        expect(again.server.co.ledger.round, 2);
        expect(again.chain.minedAt[run.a2.witnessId], isNotNull);
      } finally {
        await again.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a re-broadcast the chain refuses stops the start and names it', () async {
      await expectLater(
          run.restart(before: (chain) {
            chain.forget(run.a2.roundId);
            chain.forget(run.a2.witnessId);
            chain.refuse = (tx) => tx.id == run.a2.roundId ? 'missing inputs' : null;
          }),
          throwsA(isA<StartRefusal>()
              .having((e) => e.reason, 'reason', contains('round 2\'s round'))
              .having((e) => e.reason, 'reason', contains(run.a2.roundId))
              .having((e) => e.reason, 'reason', contains('missing inputs'))));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the witness was never broadcast: the server broadcasts it, waits for it to be mined, then starts', () async {
      final again = await run.restart(before: (chain) => chain.forget(run.a2.witnessId));
      try {
        expect(again.chain.broadcasts, [run.a2.witnessId]);
        expect(again.chain.minedAt[run.a2.witnessId], isNotNull);
        expect(again.server.status.ready, isTrue);
      } finally {
        await again.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a store whose last round the chain contradicts stops the server, naming both', () async {
      await expectLater(run.restart(before: (chain) => chain.spentOutpoints.add('${run.a2.roundId}:3')),
          throwsA(isA<StartRefusal>().having((e) => e.reason, 'reason', contains('round 2')).having((e) => e.reason, 'reason', contains('round 3'))));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a round published but not announced is announced at the next start', () async {
      final again = await run.restart(before: (chain) => run.transport.entries.removeLast());
      try {
        expect(again.transport.entries, hasLength(3));
        expect((PoolMessage.decode(again.transport.entries[2]) as PoolAnnouncement).round, 2);
        expect(again.server.status.lastAnnouncedRound, 2);
      } finally {
        await again.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('intake', () {
    test('a covenant not yet mined is refused as such, and nothing is pending', () async {
      final fresh = await _Run.fresh(c, rng, before: (chain) => chain.minedAt.remove(c.depositTx.id));
      try {
        final s = CoordinatorSetup(c);
        final bytes = PoolSubmission.of(s.deposit(), c.f.agg.spendP, depositTx: c.depositTx, rng: rng).encode();
        fresh.transport.send('w1', bytes);
        await until(() async => fresh.transport.replies['w1'] != null, what: 'a reply');
        final r = PoolReply.decode(fresh.transport.replies['w1']!.single);
        expect(r.reason, RefusalReason.depositCovenant);
        expect(r.sentence, contains('not mined'));
        expect(fresh.server.co.pending, 0);
        // a covenant already spent is refused too
        fresh.chain.minedAt[c.depositTx.id] = 5;
        fresh.chain.spentOutpoints.add('${c.depositTx.id}:${ShieldedPoolTool.depositVout}');
        fresh.transport.send('w2', bytes);
        await until(() async => fresh.transport.replies['w2'] != null, what: 'a reply');
        expect(PoolReply.decode(fresh.transport.replies['w2']!.single).sentence, contains('spent'));
        // garbage in the inbox is marked delivered without a reply, and the next valid one is answered
        fresh.transport.send('w3', [1, 2, 3]);
        fresh.transport.send('w3', Uint8List(0));
        fresh.transport.send('w3', PoolReply.accepted(List.filled(16, 0), 1).encode());
        final padding = PoolSubmission.of(c.f.transfers1[1], c.f.agg.spendP, rng: rng).encode();
        fresh.transport.send('w4', padding);
        await until(() async => fresh.transport.replies['w4'] != null, what: 'a reply');
        expect(fresh.transport.replies['w3'], isNull);
        expect(PoolReply.decode(fresh.transport.replies['w4']!.single).isAccepted, isTrue);
        expect(fresh.transport.undelivered, 0);
        expect(fresh.server.status.submissionsDropped, 3);
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('mutated submissions through the inbox: each answered or dropped, only the accepted pending, still answering', () async {
      // a fresh pool, where the fixture's deposit is accepted once and a
      // second copy is a pending double deposit
      final again = await _Run.fresh(c, rng);
      try {
        final valid = again.round1Bytes()[0];
        for (int i = 0; i < 1000; i++) {
          final at = rng.nextInt(valid.length);
          final mutated = Uint8List.fromList(valid)..[at] = (valid[at] + 1 + rng.nextInt(255)) & 0xff;
          again.transport.send('m$i', mutated);
        }
        await until(() async => again.transport.undelivered == 0, timeout: const Duration(minutes: 5), what: 'the inbox to drain');
        final s = again.server.status;
        // round 2 already spent the note: the valid one itself would be refused
        expect(s.submissionsAccepted + s.submissionsRefused + s.submissionsDropped, 1000);
        expect(again.transport.replies.length, s.submissionsAccepted + s.submissionsRefused);
        expect(again.server.co.pending, s.submissionsAccepted);
        expect(s.submissionsAccepted, lessThanOrEqualTo(1), reason: 'the same covenant twice is a pending deposit');
        print('  accepted ${s.submissionsAccepted}, refused ${s.submissionsRefused}, dropped ${s.submissionsDropped}');
        final padding = PoolSubmission.of(c.f.transfers1[2], c.f.agg.spendP, rng: rng).encode();
        again.transport.send('after', padding);
        await until(() async => again.transport.replies['after'] != null, what: 'a reply');
        expect(PoolReply.decode(again.transport.replies['after']!.single).isAccepted, isTrue);
      } finally {
        await again.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('publishing and stopping', () {
    test('a broadcast refused: the round is not announced, the store holds it, the failure is in the status, and submissions go on; the next start re-broadcasts and announces', () async {
      final fresh = await _Run.fresh(c, rng, before: (chain) => chain.refuse = (tx) => chain.broadcasts.length == 2 ? 'script failed' : null);
      try {
        fresh.submitRound1();
        await until(() async => fresh.status()['lastFailure'] != null && !fresh.server.publishing, what: 'the refused witness');
        expect(fresh.chain.broadcasts, hasLength(2));
        expect(fresh.transport.entries, hasLength(1), reason: 'the descriptor only');
        expect(await fresh.store.lastNumber(), 1);
        expect(fresh.server.co.ledger.round, 1);
        final s = fresh.status();
        expect(s['lastFailure'], contains('witness'));
        expect(s['lastFailure'], contains('script failed'));
        expect(fresh.server.metrics!.recorded(), isEmpty, reason: 'a round whose witness was refused is not in the history');
        final padding = PoolSubmission.of(c.f.transfers2[1], c.f.agg.spendP, rng: rng).encode();
        fresh.transport.send('w5', padding);
        await until(() async => fresh.transport.replies['w5'] != null, what: 'a reply');
        expect(PoolReply.decode(fresh.transport.replies['w5']!.single).round, 2);
        // the next start broadcasts the witness and announces round 1
        await fresh.server.stop();
        fresh.chain.refuse = null;
        final witness = (await fresh.store.read(1))!.witness.id;
        final again = await fresh.restart();
        try {
          expect(again.chain.broadcasts, [witness]);
          expect(again.transport.entries, hasLength(2));
          expect((PoolMessage.decode(again.transport.entries[1]) as PoolAnnouncement).round, 1);
          await until(() async => again.server.metrics!.recorded().isNotEmpty, what: 'round 1 in the history');
          await again.server.stop();
          expect(again.historyRows().map((r) => r.number), [1], reason: 'exactly one row once re-broadcast and announced');
        } finally {
          await again.dispose();
        }
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('not enough coins: the round is not proved, the transfers are pending again, and the status says the wallet needs a top-up', () async {
      final fresh = await _Run.fresh(c, rng, balance: BigInt.from(100));
      try {
        fresh.submitRound1();
        await until(() async => fresh.status()['needsTopUp'] == true, what: 'the funding failure');
        expect(fresh.chain.broadcasts, isEmpty);
        expect(fresh.server.co.pending, 4, reason: 'pending again');
        final s = fresh.status();
        expect(s['needsTopUp'], isTrue);
        expect(s['lastFailure'], contains('funding'));
        expect(s['lastFailure'], contains('100'));
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('stop during a publish: the witness is broadcast before exit', () async {
      final fresh = await _Run.fresh(c, rng, before: (chain) {
        chain.beforeBroadcast = (tx) async {
          if (chain.broadcasts.length == 1) await Future<void>.delayed(const Duration(milliseconds: 400));
        };
      });
      try {
        fresh.submitRound1();
        await until(() async => fresh.chain.broadcasts.length == 1, what: 'Y to be broadcast');
        final sw = Stopwatch()..start();
        await fresh.server.stop();
        expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 300)), reason: 'the stop waited for the publish');
        expect(fresh.chain.broadcasts, hasLength(3), reason: 'Y, the round and the witness before exit');
        expect(fresh.transport.entries, hasLength(2), reason: 'announced before exit');
        expect(fresh.transport.closed, isTrue);
        final s = jsonDecode(File(fresh.config.server.statusFile).readAsStringSync());
        expect(s['ready'], isFalse);
        expect(s['tip']['round'], 1);
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('the API', () {
    test('a configuration without the api section opens no port and records nothing', () async {
      final fresh = await _Run.fresh(c, rng, api: false);
      try {
        expect(fresh.config.api, isNull);
        expect(fresh.server.api, isNull);
        expect(fresh.server.metrics, isNull);
        await fresh._round(1, fresh.round1Bytes());
        expect(fresh.transport.entries, hasLength(2));
        expect(File(p.join(fresh.dir.path, 'metrics.sqlite')).existsSync(), isFalse);
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a history that cannot be opened turns the API off with a logged reason, and the pool runs on', () async {
      final from = logRecords.length;
      // the same path a missing libsqlite3 takes: opening the history throws
      final fresh = await _Run.fresh(c, rng, metricsFile: '/nonexistent-${rng.nextInt(1 << 30)}/metrics.sqlite');
      try {
        expect(fresh.server.metrics, isNull);
        expect(fresh.server.api, isNull);
        expect([for (final r in logRecords.sublist(from)) r.message], contains(startsWith('the pool history could not be opened, so the API is off')));
        await fresh._round(1, fresh.round1Bytes());
        expect(fresh.transport.entries, hasLength(2), reason: 'round 1 announced without the API');
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('secrets: no route, during or after the two rounds, holds an owner key, seed, wallet balance, submission id or sender', () {
      // during round 1's intake, after round 1 and after round 2
      expect(run.apiBodies.length, 3 * (_Run.apiRoutes.length + 1));
      final secrets = _secretsOf(run);
      for (final b in run.apiBodies) {
        expect(_leaks(utf8.encode(b), secrets), isEmpty, reason: b);
      }
      final rounds = jsonDecode(run.apiBodies.lastWhere((b) => b.contains('"rounds":[{'))) as Map<String, dynamic>;
      expect(rounds['rounds'], isNotEmpty, reason: 'the scan read real answers');
      // the scan sees a wallet balance slipped into the pool route
      final pool = jsonDecode(run.apiBodies.firstWhere((b) => b.contains('"genesis"'))) as Map<String, dynamic>;
      final leaky = jsonEncode({...pool, 'walletBalance': run.walletBalances.last.toInt()});
      expect(_leaks(utf8.encode(leaky), secrets), ['wallet balance ${run.walletBalances.last}']);
    });

    test('mutated requests: 10,000 answered with JSON or closed, the ranges held, and a submission in flight answered within 2 s', () async {
      final fresh = await _Run.fresh(c, rng);
      try {
        final port = fresh.server.api!.port;
        final fuzz = Random(29);
        const bases = [
          '/api/pool',
          '/api/rounds?before=2&limit=20',
          '/api/stats',
          '/api/series?metric=rounds&bucket=hour&from=0&to=1790000000',
          '/api/nothing',
        ];
        const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~%/?&=#+:;,!\$\'()*@[] ';
        List<int> target() {
          final roll = fuzz.nextInt(100);
          if (roll < 10) {
            // a range probe: a whole number in or out of range
            final n = [0, 1, 99, 100, 101, 1000, -5, 1 << 40][fuzz.nextInt(8)];
            return ascii.encode(fuzz.nextBool() ? '/api/rounds?limit=$n' : '/api/rounds?before=$n');
          }
          if (roll < 15) return [for (int i = 0; i < fuzz.nextInt(80); i++) fuzz.nextInt(256)];
          final t = ascii.encode(bases[fuzz.nextInt(bases.length)]).toList();
          for (int k = 0; k <= fuzz.nextInt(4); k++) {
            final at = fuzz.nextInt(t.length + 1);
            switch (fuzz.nextInt(4)) {
              case 0:
                if (at < t.length) t[at] = alphabet.codeUnitAt(fuzz.nextInt(alphabet.length));
              case 1:
                t.insert(at, alphabet.codeUnitAt(fuzz.nextInt(alphabet.length)));
              case 2:
                if (at < t.length) t.removeAt(at);
              case 3:
                t.insertAll(at, ascii.encode('&limit=${fuzz.nextInt(300)}'));
            }
          }
          if (fuzz.nextInt(50) == 0) t.addAll(List.filled(2100, 0x61));
          return t;
        }

        const methods = ['GET', 'GET', 'GET', 'HEAD', 'POST', 'DELETE', 'OPTIONS', 'get', 'TRACE'];
        final statuses = <int, int>{};
        var closed = 0, unparsed = 0;
        final padding = PoolSubmission.of(c.f.transfers1[1], c.f.agg.spendP, rng: rng).encode();
        for (int batch = 0; batch < 500; batch++) {
          if (batch == 250) fresh.transport.send('in-flight', padding);
          await Future.wait([
            for (int i = 0; i < 20; i++)
              () async {
                final t = target();
                final line = [...ascii.encode('${methods[fuzz.nextInt(methods.length)]} '), ...t, ...ascii.encode(' HTTP/1.1')];
                final uri = Uri.tryParse(latin1.decode(t));
                // the event stream never ends; the fuzz leaves it to its own tests
                if (uri?.path == '/api/events') return;
                final a = await rawRequest(port, line);
                if (a == null) {
                  closed++;
                  return;
                }
                statuses[a.status] = (statuses[a.status] ?? 0) + 1;
                final what = latin1.decode(line);
                expect(const {200, 400, 404, 405, 414}, contains(a.status), reason: what);
                // a HEAD is answered with the headers alone
                if (line.take(5).toList().toString() == ascii.encode('HEAD ').toString()) return;
                // dart:io refuses a request line it cannot parse before any
                // route sees it; the API's own refusals are always JSON
                if (a.status == 400 && !a.body.trimLeft().startsWith('{')) {
                  unparsed++;
                  return;
                }
                final Map<String, dynamic> body;
                try {
                  body = jsonDecode(a.body) as Map<String, dynamic>;
                } catch (e) {
                  fail('not JSON for $what: ${a.body}');
                }
                expect(body['v'], 1, reason: what);
                // the oracle for ranges: a rounds request with a limit out
                // of 1..100 or a before under 1 is refused, whatever else
                if (a.status == 200 && uri != null && uri.path == '/api/rounds' && !uri.hasFragment) {
                  final q = uri.queryParametersAll;
                  final limit = int.tryParse((q['limit'] ?? const ['20']).last);
                  final before = int.tryParse((q['before'] ?? const ['1']).last);
                  expect(limit == null || (limit >= 1 && limit <= 100), isTrue, reason: 'accepted $what');
                  expect(before == null || before >= 1, isTrue, reason: 'accepted $what');
                  expect((body['rounds'] as List).length, lessThanOrEqualTo(100));
                }
              }(),
          ]);
        }
        print('  answers $statuses, of which $unparsed the HTTP layer\'s own 400; closed without an answer $closed');
        expect(statuses.values.fold<int>(0, (a, b) => a + b) + closed, greaterThan(9000));
        expect(statuses[200], greaterThan(0));
        expect(statuses[400], greaterThan(0));
        await until(() async => fresh.transport.replies['in-flight'] != null, what: 'the reply in flight');
        expect(fresh.transport.repliedAt['in-flight']!.difference(fresh.transport.sentAt['in-flight']!), lessThan(const Duration(seconds: 2)));
        final ok = await request(port, '/api/pool');
        expect(ok.status, 200, reason: 'still answering');
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('load while intake runs: 50 requests a second across every route through two rounds, each submission answered within 2 s', () async {
      final fresh = await _Run.fresh(c, rng);
      try {
        final port = fresh.server.api!.port;
        // the load comes from an isolate of its own, as a browser's would:
        // this one is the coordinator's, and proving holds it for seconds
        var worstGap = Duration.zero;
        final gapWatch = Stopwatch()..start();
        final gapTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
          final gap = gapWatch.elapsed;
          if (gap > worstGap) worstGap = gap;
          gapWatch.reset();
        });
        final results = ReceivePort();
        await Isolate.spawn(_load, (results.sendPort, port, _Run.apiRoutes));
        final inbox = StreamIterator(results);
        await inbox.moveNext();
        final stopLoad = inbox.current as SendPort;
        await fresh._round(1, fresh.round1Bytes());
        await fresh._round(2, [for (final t in c.f.transfers2) PoolSubmission.of(t, c.f.agg.spendP, rng: rng).encode()]);
        stopLoad.send('stop');
        await inbox.moveNext();
        final (sent, failed, reasons, elapsedMs) = inbox.current as (int, int, List<String>, int);
        results.close();
        gapTimer.cancel();
        print('  the longest the coordinator\'s isolate did not run: ${worstGap.inMilliseconds} ms');
        print('  $sent requests in $elapsedMs ms, $failed failed${reasons.isEmpty ? '' : ': ${reasons.take(5).join('; ')}'}');
        final elapsed = Duration(milliseconds: elapsedMs);
        expect(sent / elapsed.inMilliseconds * 1000, greaterThan(45));
        expect(failed, 0);
        expect(fresh.transport.entries, hasLength(3), reason: 'both rounds announced');
        for (final peer in fresh.senders) {
          expect(fresh.transport.repliedAt[peer]!.difference(fresh.transport.sentAt[peer]!), lessThan(const Duration(seconds: 2)), reason: peer);
        }
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('the pool history', () {
    int realIn(List<ShieldedTransfer> ts) => ts.where((t) => !t.isPadding).length;

    test('two rounds of the test chain: each recorded with its txids, real transfers, capacity, balance, timings, cost and height', () async {
      final rows = run.historyRows();
      expect(rows.map((r) => r.number), [1, 2]);
      final expected = [
        (a: run.a1, real: realIn(CoordinatorSetup(c).round1)),
        (a: run.a2, real: realIn(c.f.transfers2)),
      ];
      for (int i = 0; i < 2; i++) {
        final r = rows[i], a = expected[i].a;
        final stored = (await run.store.read(r.number))!;
        expect((r.y, r.round, r.witness), (stored.y.id, stored.round.id, stored.witness.id));
        expect((r.round, r.witness, r.y), (a.roundId, a.witnessId, a.slotId));
        expect(r.transfers, expected[i].real, reason: 'round ${r.number}');
        expect(r.capacity, 4);
        expect(r.balance, a.header.balance.toInt());
        expect(r.provingMs, greaterThan(0));
        expect(r.buildMs, greaterThanOrEqualTo(r.provingMs!));
        expect(r.cost, 4790);
        expect(r.publishedAt, isNotNull);
        expect(r.minedHeight, run.chain.minedAt[r.witness]);
        expect(r.minedAt, isNotNull);
      }
      expect(expected.map((e) => e.real), everyElement(inInclusiveRange(1, 3)), reason: 'neither all padding nor full');
    });

    test('mined after publish: the height is recorded within two mined poll intervals of the block', () async {
      final fresh = await _Run.fresh(c, rng, before: (chain) => chain.mineOnBroadcast = false);
      try {
        fresh.submitRound1();
        await until(() async => fresh.transport.entries.length == 2 && !fresh.server.publishing, what: 'round 1 announced');
        final m = fresh.server.metrics!;
        expect(m.history.read(1)!.mined, isFalse);
        expect(m.live.rounds, [const LiveRound(1, RoundStage.broadcast)]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(m.history.read(1)!.mined, isFalse, reason: 'nothing mined yet');
        final height = fresh.chain.mine();
        final sw = Stopwatch()..start();
        await until(() async => m.history.read(1)!.mined, timeout: const Duration(seconds: 5), what: 'the height');
        expect(sw.elapsed, lessThan(fresh.config.server.minedPoll * 2 + const Duration(milliseconds: 150)));
        expect(m.history.read(1)!.minedHeight, height);
        expect(m.live.rounds, isEmpty);
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('not yet mined at stop: the next start asks again and records the height', () async {
      final fresh = await _Run.fresh(c, rng, before: (chain) => chain.mineOnBroadcast = false);
      try {
        fresh.submitRound1();
        await until(() async => fresh.transport.entries.length == 2 && !fresh.server.publishing, what: 'round 1 announced');
        await fresh.server.stop();
        expect(fresh.historyRows().single.mined, isFalse);
        final height = fresh.chain.mine();
        final again = await fresh.restart();
        try {
          final m = again.server.metrics!;
          await until(() async => m.history.read(1)!.mined, timeout: const Duration(seconds: 5), what: 'the height after the start');
          expect(m.history.read(1)!.minedHeight, height);
          expect(m.history.read(1)!.provingMs, isNotNull, reason: 'the measured row is kept, not rebuilt');
        } finally {
          await again.dispose();
        }
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('stages in order: proving, funding, broadcast, never backwards, and gone once mined', () async {
      // funding that takes a while, as a real wallet's does, so the ticks see it
      final fresh = await _Run.fresh(c, rng, walletDelay: const Duration(milliseconds: 300));
      try {
        final m = fresh.server.metrics!;
        final seen = <RoundStage>[];
        var minedSeen = false;
        m.changes.listen((live) {
          final r = live.rounds.where((r) => r.number == 1);
          if (r.isEmpty) {
            if (seen.isNotEmpty) minedSeen = true;
            return;
          }
          expect(minedSeen, isFalse, reason: 'round 1 came back after leaving');
          if (seen.isEmpty || seen.last != r.single.stage) seen.add(r.single.stage);
        });
        fresh.submitRound1();
        await until(() async => m.history.read(1)?.mined ?? false, what: 'round 1 mined');
        await until(() async => minedSeen, timeout: const Duration(seconds: 5), what: 'round 1 to leave the live state');
        expect(seen, [RoundStage.proving, RoundStage.funding, RoundStage.broadcast]);
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('assembling and idle: one transfer opens a round with the library\'s deadline, and its close ends it', () async {
      final fresh = await _Run.fresh(c, rng);
      try {
        final m = fresh.server.metrics!;
        expect(m.live, LiveState.idle);
        final padding = PoolSubmission.of(c.f.transfers1[1], c.f.agg.spendP, rng: rng).encode();
        fresh.transport.send('a1', padding);
        await until(() async => m.live.assembling, what: 'assembling');
        expect(m.live.deadline, fresh.server.co.status.deadline);
        expect(m.live.deadline, isNotNull);
        (fresh.server.clock as FakeClock).advance(fresh.config.round.deadline);
        await until(() async => !m.live.assembling, what: 'the deadline to close the round');
        expect(m.live.deadline, isNull);
        expect(m.live.rounds.map((r) => r.number), contains(1));
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('privacy: the history file and every live state hold no submission id, sender, owner key, seed or wallet balance', () {
      expect(run.liveStates, isNotEmpty);
      final secrets = _secretsOf(run);
      final file = [
        for (final f in [run.metricsFile, '${run.metricsFile}-wal']) if (File(f).existsSync()) ...File(f).readAsBytesSync(),
      ];
      expect(_leaks(file, secrets), isEmpty);
      expect(_leaks(utf8.encode(run.liveStates.join('\n')), secrets), isEmpty);

      // the scan would see one: a copy of the history with a sender in a row
      final copy = p.join(run.dir.path, 'leaky.sqlite');
      File(run.metricsFile).copySync(copy);
      final h = MetricsHistory.open(copy);
      h.record(RoundRecord(number: 99, y: run.senders.first, round: 'r', witness: 'w', transfers: 0, capacity: 4, balance: 0));
      h.close();
      expect(_leaks(File(copy).readAsBytesSync(), secrets), [run.senders.first]);
    });

    test('database locked: round 2 is published and announced as without the history, the log names the failure, and intake goes on', () async {
      final fresh = await _Run.fresh(c, rng);
      try {
        await fresh._round(1, fresh.round1Bytes());
        // another connection holds the write lock, so every write the
        // recorder tries fails at once
        final lock = sqlite3.open(fresh.metricsFile)..execute('BEGIN EXCLUSIVE');
        try {
          final from = logRecords.length;
          await fresh._round(2, [for (final t in c.f.transfers2) PoolSubmission.of(t, c.f.agg.spendP, rng: rng).encode()]);
          final a2 = PoolMessage.decode(fresh.transport.entries[2]) as PoolAnnouncement;
          expect(a2.round, 2);
          expect(fresh.chain.broadcasts.sublist(3), [a2.slotId, a2.roundId, a2.witnessId]);
          final failures = [for (final r in logRecords.sublist(from)) if (r.loggerName == 'metrics') r.message];
          expect(failures, contains(startsWith('the pool history failed recording round 2')));
          final padding = PoolSubmission.of(c.f.transfers2[1], c.f.agg.spendP, rng: rng).encode();
          fresh.transport.send('after-lock', padding);
          await until(() async => fresh.transport.replies['after-lock'] != null, what: 'a reply');
          expect(fresh.transport.repliedAt['after-lock']!.difference(fresh.transport.sentAt['after-lock']!),
              lessThan(const Duration(seconds: 2)));
          expect(PoolReply.decode(fresh.transport.replies['after-lock']!.single).isAccepted, isTrue);
        } finally {
          lock
            ..execute('ROLLBACK')
            ..dispose();
        }
        expect(fresh.server.metrics!.recorded(), {1}, reason: 'round 2 was not recorded while locked');
      } finally {
        await fresh.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('database deleted between runs: rebuilt after ready with the same facts, and no times, durations or cost', () async {
      final before = run.historyRows();
      final sw = Stopwatch()..start();
      final again = await run.restart(history: false);
      try {
        expect(again.server.status.ready, isTrue);
        final m = again.server.metrics!;
        await until(() async => m.history.unmined().isEmpty && m.recorded().length == 2,
            timeout: const Duration(seconds: 10), what: 'the rebuild');
        print('  ready and rebuilt in ${sw.elapsedMilliseconds} ms');
        final rows = m.history.page().reversed.toList();
        for (int i = 0; i < 2; i++) {
          final a = before[i], b = rows[i];
          expect((b.number, b.y, b.round, b.witness, b.transfers, b.capacity, b.balance, b.minedHeight),
              (a.number, a.y, a.round, a.witness, a.transfers, a.capacity, a.balance, a.minedHeight));
          expect((b.cost, b.buildMs, b.provingMs, b.publishedAt, b.minedAt), (null, null, null, null, null));
        }
        expect(m.live.rounds, isEmpty, reason: 'rebuilt rounds are history, not in flight');
      } finally {
        await again.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('same store, same history: two rebuilds give identical rows', () async {
      Future<List<RoundRecord>> rebuild() async {
        final again = await run.restart(history: false);
        try {
          final m = again.server.metrics!;
          await until(() async => m.history.unmined().isEmpty && m.recorded().length == 2,
              timeout: const Duration(seconds: 10), what: 'the rebuild');
        } finally {
          await again.server.stop();
        }
        final rows = again.historyRows();
        await again.dispose();
        return rows;
      }

      expect(await rebuild(), await rebuild());
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

/// 50 requests a second across [routes] until told to stop, then the count
/// sent, the count failed, why, and how long it ran.
Future<void> _load((SendPort, int, List<String>) args) async {
  final (results, port, routes) = args;
  final control = ReceivePort();
  results.send(control.sendPort);
  var stop = false;
  control.listen((_) => stop = true);
  final client = HttpClient();
  final pending = <Future<void>>[];
  final reasons = <String>[];
  var sent = 0, failed = 0;
  final sw = Stopwatch()..start();
  while (!stop) {
    final path = routes[sent % routes.length];
    sent++;
    pending.add(() async {
      try {
        final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'))).close();
        await res.drain<void>();
        if (res.statusCode != 200) {
          failed++;
          reasons.add('$path ${res.statusCode}');
        }
      } catch (e) {
        failed++;
        reasons.add('$path $e');
      }
    }());
    // on schedule however long each takes
    final wait = Duration(milliseconds: 20 * sent) - sw.elapsed;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }
  await Future.wait(pending);
  final elapsed = sw.elapsedMilliseconds;
  client.close();
  control.close();
  results.send((sent, failed, reasons, elapsed));
}

/// What must never reach the pool history or the API: every submission
/// id and sender of the run, the owner key, the identity seed, and every
/// balance the wallet held, each as text and, for the balances, as the
/// big-endian integers SQLite stores.
Map<String, List<List<int>>> _secretsOf(_Run run) {
  List<int> be(BigInt v, int bytes) => [for (int i = bytes - 1; i >= 0; i--) ((v >> (8 * i)) & BigInt.from(0xff)).toInt()];
  return {
    for (final id in run.submissionIds) id: [utf8.encode(id), hex.decode(id)],
    for (final s in run.senders) s: [utf8.encode(s)],
    'owner key': [utf8.encode(opKey.toHex()), utf8.encode(opKey.toWIF()), hex.decode(opKey.toHex())],
    'seed': [utf8.encode(hex.encode(run.seed)), run.seed],
    for (final b in run.walletBalances) 'wallet balance $b': [utf8.encode('$b'), be(b, 4), be(b, 6), be(b, 8)],
  };
}

/// The names of the [secrets] found anywhere in [bytes].
List<String> _leaks(List<int> bytes, Map<String, List<List<int>>> secrets) {
  bool has(List<int> needle) {
    outer:
    for (int i = 0; i + needle.length <= bytes.length; i++) {
      for (int j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  return [for (final e in secrets.entries) if (e.value.any(has)) e.key];
}

/// A reply and how long it took from the send.
class _Answered {
  final PoolReply reply;
  final Duration elapsed;
  _Answered(this.reply, this.elapsed);
}

/// One server on the fakes, in its own directory.
class _Run {
  final PoolTestChain c;
  final Random rng;
  final Directory dir;
  final FakeChain chain;
  final FakeWallet wallet;
  final FakeTransport transport;
  final FileRoundStore store;
  final PoolConfig config;
  final Uint8List seed = Uint8List.fromList(List.filled(32, 0x5e));
  late PoolServer server;

  // what the two-round run recorded
  final replies1 = <_Answered>[];
  int pendingAfterFirst = 0;
  late PoolAnnouncement a1, a2;
  late Map<String, dynamic> statusAfterRound1, statusAfterRound2;
  late String statusText;
  late Uint8List snapshotAfterRound2;
  late BigInt balanceBefore, balanceAfterRound1;
  final transfers = <Uint8List>[];
  final submissionIds = <String>[];
  final senders = <String>[];
  final walletBalances = <BigInt>[];
  final liveStates = <LiveState>[];

  /// Every API answer taken during and after the two-round run.
  final apiBodies = <String>[];

  _Run._(this.c, this.rng, this.dir, this.chain, this.wallet, this.transport, this.store, this.config);

  static Future<_Run> _make(PoolTestChain c, Random rng,
      {Directory? dir, FakeChain? chain, BigInt? balance, FakeTransport? transport, Duration walletDelay = Duration.zero, bool api = true, String? metricsFile}) async {
    final d = dir ?? Directory.systemTemp.createTempSync('pool-server');
    final log = EventLog();
    final ch = chain ?? (FakeChain(log: log)
      ..addMined(c.y0.tx)
      ..addMined(c.r0)
      ..addMined(c.w0)
      ..addMined(c.depositTx));
    final signer = DefaultTransactionSigner(sigHashAll, opKey);
    final opAddr = Address.fromPublicKey(opKey.publicKey, NetworkType.TEST);
    final wallet = FakeWallet(signer, opKey.publicKey, opAddr, balance: balance, delay: walletDelay);
    final t = transport ?? FakeTransport(log: log, peerId: 'coordinator');
    final config = PoolConfig.parse('''
plan: test
network: test
chain:
  kind: node
  rpc_url: http://localhost:18332
  rpc_user: bitcoin
ricochet:
  server: /ip4/127.0.0.1/udp/55223/udx/p2p/12D3KooWExample
  identity_file: identity.seed
wallet:
  file: wallet.enc
  warn_rounds_left: 5
store:
  directory: store
genesis:
  issuance: ${c.r0.id}
  witness0: ${c.w0.id}
  slot0: ${c.y0.tx.id}
round:
  fee_rate: 1
  fee_floor: 135
  deadline_seconds: 600
  padding_stock: 0
  deposit_margin: 100
server:
  poll_ms: 50
  status_file: status.json
  mined_poll_ms: 20
  funding_timeout_seconds: 60
${api ? 'api:\n  enabled: true\n  port: 0\n${metricsFile == null ? '' : '  metrics_file: $metricsFile\n'}' : ''}''', baseDir: d.path);
    final store = FileRoundStore(config.store.directory, keepSnapshots: 10);
    return _Run._(c, rng, d, ch, wallet, t, store, config);
  }

  Future<void> _start() async {
    server = await PoolServer.start(config: config, wallet: wallet, store: store, chain: chain, transport: transport, clock: FakeClock());
    server.metrics?.changes.listen(liveStates.add);
  }

  /// A server on an empty store.
  static Future<_Run> fresh(PoolTestChain c, Random rng,
      {void Function(FakeChain chain)? before, BigInt? balance, Duration walletDelay = Duration.zero, bool api = true, String? metricsFile}) async {
    final r = await _make(c, rng, balance: balance, walletDelay: walletDelay, api: api, metricsFile: metricsFile);
    before?.call(r.chain);
    await r._start();
    return r;
  }

  /// The two rounds of the test chain through a fresh server, recorded.
  static Future<_Run> twoRounds(PoolTestChain c, Random rng) async {
    final r = await fresh(c, rng);
    // the fake wallet measures nothing; a real one reports this after reconciling
    r.wallet.lastRoundCost = BigInt.from(4790);
    r.balanceBefore = r.wallet.balance;
    await r._round(1, r.round1Bytes());
    r.statusAfterRound1 = r.status();
    await r.captureApi();
    r.balanceAfterRound1 = r.wallet.balance;
    r.a1 = PoolMessage.decode(r.transport.entries[1]) as PoolAnnouncement;
    await r._round(2, [for (final t in c.f.transfers2) PoolSubmission.of(t, c.f.agg.spendP, rng: rng).encode()]);
    r.statusAfterRound2 = r.status();
    r.a2 = PoolMessage.decode(r.transport.entries[2]) as PoolAnnouncement;
    r.snapshotAfterRound2 = r.server.co.ledger.snapshot();
    r.statusText = File(r.config.server.statusFile).readAsStringSync();
    await r.captureApi();
    await r.server.stop();
    r.walletBalances.add(r.wallet.balance);
    return r;
  }

  List<Uint8List> round1Bytes() {
    final s = CoordinatorSetup(c);
    return [for (final t in s.round1) PoolSubmission.of(t, c.f.agg.spendP, depositTx: t.depositOutpoint == null ? null : c.depositTx, rng: rng).encode()];
  }

  void submitRound1() {
    var i = 0;
    for (final b in round1Bytes()) {
      transport.send('w${i++}', b);
    }
  }

  Future<void> _round(int n, List<Uint8List> submissions) async {
    var i = 0;
    for (final b in submissions) {
      final sub = PoolSubmission.decode(b);
      transfers.add(sub.transferBytes);
      submissionIds.add(hex.encode(sub.id));
      walletBalances.add(wallet.balance);
      final peer = 'r${n}w${i++}';
      senders.add(peer);
      transport.send(peer, b);
      while (transport.replies[peer] == null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final reply = PoolReply.decode(transport.replies[peer]!.single);
      if (n == 1) {
        replies1.add(_Answered(reply, transport.repliedAt[peer]!.difference(transport.sentAt[peer]!)));
        if (i == 1) {
          pendingAfterFirst = server.co.pending;
          // a round assembling: what the API says while transfers are pending
          await captureApi();
        }
      }
      if (!reply.isAccepted) throw StateError('round $n submission $i: $reply');
    }
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (transport.entries.length < n + 1 || server.publishing) {
      if (DateTime.now().isAfter(deadline)) throw StateError('round $n was not announced: ${server.status.lastFailure}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  String get metricsFile => config.api!.metricsFile;

  static const apiRoutes = [
    '/api/pool',
    '/api/rounds',
    '/api/rounds?before=2&limit=1',
    '/api/stats',
    '/api/series?metric=rounds',
    '/api/series?metric=balance&bucket=day',
    '/api/series?metric=cost',
    '/api/series?metric=proving',
    '/api/series?metric=transfers',
  ];

  /// Every route's answer, and the event stream's snapshot, into [apiBodies].
  Future<void> captureApi() async {
    if (server.api == null) return;
    final port = server.api!.port;
    for (final path in apiRoutes) {
      apiBodies.add((await request(port, path)).body);
    }
    final events = await EventClient.connect(port);
    await events.until(() => events.events.isNotEmpty);
    apiBodies.addAll([for (final e in events.events) jsonEncode(e.data)]);
    await events.close();
  }

  /// The history as this run's server left it; the server must be stopped.
  List<RoundRecord> historyRows() {
    final h = MetricsHistory.open(metricsFile);
    try {
      return h.page(limit: 100).reversed.toList();
    } finally {
      h.close();
    }
  }

  Map<String, dynamic> status() => jsonDecode(File(config.server.statusFile).readAsStringSync()) as Map<String, dynamic>;

  /// A new server on a copy of this run's store, chain and feed, and of its
  /// pool history unless [history] is false.
  Future<_Run> restart({void Function(FakeChain chain)? before, bool history = true}) async {
    final d = Directory.systemTemp.createTempSync('pool-server-again');
    await Process.run('cp', ['-R', '${dir.path}/store', d.path]);
    if (history) {
      for (final f in [metricsFile, '$metricsFile-wal', '$metricsFile-shm']) {
        if (File(f).existsSync()) File(f).copySync(p.join(d.path, p.basename(f)));
      }
    }
    final t = FakeTransport(peerId: 'coordinator')..entries.addAll(transport.entries);
    final r = await _make(c, rng, dir: d, chain: chain.clone(), transport: t);
    before?.call(r.chain);
    await r._start();
    return r;
  }

  Future<void> dispose() async {
    try {
      await server.stop();
    } catch (_) {}
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
