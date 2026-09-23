import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';
import 'support/coordinator_setup.dart';
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
      final reader = ShieldedChainReader.open(d.layout, c.r0, c.w0, c.y0.tx);
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

  _Run._(this.c, this.rng, this.dir, this.chain, this.wallet, this.transport, this.store, this.config);

  static Future<_Run> _make(PoolTestChain c, Random rng, {Directory? dir, FakeChain? chain, BigInt? balance, FakeTransport? transport}) async {
    final d = dir ?? Directory.systemTemp.createTempSync('pool-server');
    final log = EventLog();
    final ch = chain ?? (FakeChain(log: log)
      ..addMined(c.y0.tx)
      ..addMined(c.r0)
      ..addMined(c.w0)
      ..addMined(c.depositTx));
    final signer = DefaultTransactionSigner(sigHashAll, opKey);
    final opAddr = Address.fromPublicKey(opKey.publicKey, NetworkType.TEST);
    final wallet = FakeWallet(signer, opKey.publicKey, opAddr, balance: balance);
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
''', baseDir: d.path);
    final store = FileRoundStore(config.store.directory, keepSnapshots: 10);
    return _Run._(c, rng, d, ch, wallet, t, store, config);
  }

  Future<void> _start() async {
    server = await PoolServer.start(config: config, wallet: wallet, store: store, chain: chain, transport: transport, clock: FakeClock());
  }

  /// A server on an empty store.
  static Future<_Run> fresh(PoolTestChain c, Random rng, {void Function(FakeChain chain)? before, BigInt? balance}) async {
    final r = await _make(c, rng, balance: balance);
    before?.call(r.chain);
    await r._start();
    return r;
  }

  /// The two rounds of the test chain through a fresh server, recorded.
  static Future<_Run> twoRounds(PoolTestChain c, Random rng) async {
    final r = await fresh(c, rng);
    r.balanceBefore = r.wallet.balance;
    await r._round(1, r.round1Bytes());
    r.statusAfterRound1 = r.status();
    r.balanceAfterRound1 = r.wallet.balance;
    r.a1 = PoolMessage.decode(r.transport.entries[1]) as PoolAnnouncement;
    await r._round(2, [for (final t in c.f.transfers2) PoolSubmission.of(t, c.f.agg.spendP, rng: rng).encode()]);
    r.statusAfterRound2 = r.status();
    r.a2 = PoolMessage.decode(r.transport.entries[2]) as PoolAnnouncement;
    r.snapshotAfterRound2 = r.server.co.ledger.snapshot();
    r.statusText = File(r.config.server.statusFile).readAsStringSync();
    await r.server.stop();
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
      transfers.add(PoolSubmission.decode(b).transferBytes);
      final peer = 'r${n}w${i++}';
      transport.send(peer, b);
      while (transport.replies[peer] == null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final reply = PoolReply.decode(transport.replies[peer]!.single);
      if (n == 1) {
        replies1.add(_Answered(reply, transport.repliedAt[peer]!.difference(transport.sentAt[peer]!)));
        if (i == 1) pendingAfterFirst = server.co.pending;
      }
      if (!reply.isAccepted) throw StateError('round $n submission $i: $reply');
    }
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (transport.entries.length < n + 1 || server.publishing) {
      if (DateTime.now().isAfter(deadline)) throw StateError('round $n was not announced: ${server.status.lastFailure}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Map<String, dynamic> status() => jsonDecode(File(config.server.statusFile).readAsStringSync()) as Map<String, dynamic>;

  /// A new server on a copy of this run's store, chain and feed.
  Future<_Run> restart({void Function(FakeChain chain)? before}) async {
    final d = Directory.systemTemp.createTempSync('pool-server-again');
    await Process.run('cp', ['-R', '${dir.path}/store', d.path]);
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
