@Tags(['localnet'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart' show FakeChain;
import 'support/pool_test_chain.dart';
import 'support/ricochet_server.dart';
import 'support/test_keys.dart';

/// The whole stack on localnet: `create` issues a pool from a wallet the
/// node funds, `run` opens it, a second ricochet client plays the wallet
/// and submits the fixture's two rounds, and the chain, the feed and the
/// status agree. Off unless POOL_LOCALNET is set and a ricochet server can
/// be started:
///
///   POOL_LOCALNET=1 dart test test/localnet_e2e_test.dart
///
/// `tool/dashboard_e2e.sh` also drives the public page through this run.
/// It sets POOL_DASHBOARD_E2E to a folder of signal files: the run then
/// serves the API on POOL_API_PORT with a 10 s publication interval,
/// writes `ready` once the API is up, waits for the browser's `go` before
/// round 1 so the page sees the round arrive live, and waits for `done`
/// before it floods and restarts the server.
void main() async {
  final env = Platform.environment;
  final signals = env['POOL_DASHBOARD_E2E'];
  Future<void> signal(String name) => File('$signals/$name').writeAsString('');
  Future<void> awaitSignal(String name) async {
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (!File('$signals/$name').existsSync()) {
      if (DateTime.now().isAfter(deadline)) fail('the page never signalled $name');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  final ricochetSkip = await RicochetTestServer.available();
  final skip = env['POOL_LOCALNET'] == null ? 'needs ../localnet up; set POOL_LOCALNET=1' : ricochetSkip;

  group('end to end on localnet', () {
    late PoolTestChain c;
    late RicochetTestServer ricochet;
    late NodeChain node;
    late Directory dir;
    late String configPath;
    late Timer miner;
    late Created created;
    final passphrase = 'e2e passphrase';
    final rng = Random(17);
    final logRecords = <LogRecord>[];
    final timings = <String, Duration>{};

    setUpAll(() async {
      Logger.root.level = Level.INFO;
      Logger.root.onRecord.listen(logRecords.add);
      c = await PoolTestChain.build();
      ricochet = (await RicochetTestServer.start())!;
      node = NodeChain(
          rpcUrl: Uri.parse(env['LOCALNET_RPC'] ?? 'http://localhost:18332'),
          user: 'bitcoin',
          password: env['POOL_RPC_PASSWORD'] ?? 'bitcoin',
          timeout: const Duration(seconds: 120));
      // localnet's autominer mines every ten minutes; the test mines every second
      miner = Timer.periodic(const Duration(seconds: 1), (_) => node.generate(1).catchError((_) {}));
      dir = Directory.systemTemp.createTempSync('pool-e2e');
      configPath = '${dir.path}/config.yaml';
      File(configPath).writeAsStringSync('''
plan: test
network: test
chain:
  kind: node
  rpc_url: ${env['LOCALNET_RPC'] ?? 'http://localhost:18332'}
  rpc_user: bitcoin
ricochet:
  server: ${ricochet.address}
  identity_file: identity.seed
wallet:
  file: wallet.enc
store:
  directory: store
round:
  fee_rate: 1
  fee_floor: 135
  deadline_seconds: 600
  padding_stock: 0
  deposit_margin: 100
server:
  poll_ms: 200
  status_file: status.json
  mined_poll_ms: 200
  funding_timeout_seconds: 600
api:
  enabled: true
  port: ${signals == null ? 0 : env['POOL_API_PORT'] ?? 8787}
${signals == null ? '' : '  publish_interval_seconds: 10'}
''');
    });

    tearDownAll(() async {
      miner.cancel();
      await ricochet.dispose();
      node.close();
      print('  timings: ${timings.entries.map((e) => '${e.key} ${e.value.inMilliseconds} ms').join(', ')}');
    });

    Secrets secrets(PoolConfig config) => Secrets.load(config, env: {'POOL_WALLET_PASSPHRASE': passphrase, 'POOL_RPC_PASSWORD': env['POOL_RPC_PASSWORD'] ?? 'bitcoin'});

    /// The status file once it shows round [n]: the server writes it after
    /// reconciling the round, which can finish after the round's
    /// transactions are mined.
    Future<Map<String, dynamic>> statusAt(String path, int n) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (true) {
        final status = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
        if (status['tip']['round'] == n || DateTime.now().isAfter(deadline)) return status;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    Future<void> untilMined(String txid) async {
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (await node.minedHeight(txid) == null) {
        if (DateTime.now().isAfter(deadline)) fail('$txid was not mined');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    test('create: a pool from nothing, the genesis mined, the descriptor first on the feed', () async {
      final config = await PoolConfig.load(configPath);
      final creator = PoolCreator(
        config: config,
        configPath: configPath,
        secrets: secrets(config),
        chain: node,
        connect: (seed) => RicochetTransport.connect(seed: seed, server: ricochet.address),
        pollInterval: const Duration(milliseconds: 500),
        kdf: KdfParams.light,
        say: (line) {
          print('  create: $line');
          final m = RegExp(r'^fund (\S+) with at least (\d+) satoshis').firstMatch(line);
          if (m != null) {
            // the operator pays the address from the node's wallet
            unawaited(node.payFromNode(Address.fromBase58(m.group(1)!), BigInt.parse(m.group(2)!) + BigInt.from(100000)));
          }
        },
      );
      final sw = Stopwatch()..start();
      created = await creator.run();
      timings['create'] = sw.elapsed;
      for (final tx in [created.slot0, created.issuance, created.witness0]) {
        expect(await node.minedHeight(tx.id), isNotNull, reason: '${tx.id} mined');
      }
      final after = await PoolConfig.load(configPath);
      expect(after.genesis!.issuance, created.issuance.id);
      expect(after.genesis!.witness0, created.witness0.id);
      expect(after.genesis!.slot0, created.slot0.id);
      expect(File(after.wallet.file).existsSync(), isTrue);
      expect(File(after.ricochet.identityFile).existsSync(), isTrue);
      expect(() => creator.run(), throwsA(isA<CreateRefusal>()));
      // the feed's first entry is the descriptor with the genesis txids
      final reader = await RicochetTransport.connect(seed: Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256))), server: ricochet.address);
      try {
        final feed = await reader.feedOf(PeerIdOf(created.peerId).id, 1);
        expect(feed.map((e) => e.sequence), [1]);
        final d = PoolMessage.decode(feed.single.content) as PoolDescriptor;
        expect(hex.encode(d.issuance), created.issuance.id);
        expect(hex.encode(d.witness0), created.witness0.id);
        expect(hex.encode(d.slot0), created.slot0.id);
      } finally {
        await reader.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('run: both rounds of the test chain through the server, answered within 2 s, announced, readable, the folder not left to fill', () async {
      final config = await PoolConfig.load(configPath);
      final s = secrets(config);
      final (file, contents) = await WalletFile.open(config.wallet.file, s.walletPassphrase);
      final wallet = FileWallet(
          file: file,
          contents: contents,
          chain: node,
          feeRate: config.round.feeRate,
          feeFloor: config.round.feeFloor,
          minedPoll: config.server.minedPoll,
          fundingTimeout: config.server.fundingTimeout);
      final seed = await IdentityFile.read(config.ricochet.identityFile);
      final transport = await RicochetTransport.connect(seed: seed, server: ricochet.address, retryDelay: const Duration(milliseconds: 500));
      expect(transport.peerId, created.peerId, reason: 'the identity file gives the peer id the descriptor was published under');
      final store = FileRoundStore(config.store.directory);
      final sw = Stopwatch()..start();
      var server = await PoolServer.start(config: config, wallet: wallet, store: store, chain: node, transport: transport);
      timings['start at round 0'] = sw.elapsed;
      expect(server.co.ledger.round, 0, reason: 'run opens the pool at round 0');
      final walletT = await RicochetTransport.connect(seed: Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256))), server: ricochet.address);
      final coordinator = created.peerId;
      final coordinatorId = PeerIdOf(coordinator).id;
      if (signals != null) {
        await signal('ready');
        await awaitSignal('go');
      }

      try {
        // the depositor pays into a covenant naming PP3_0
        final stranger = strangerKey.publicKey.toAddress(NetworkType.TEST);
        final coinsId = await node.payFromNode(stranger, BigInt.from(100000));
        await untilMined(coinsId);
        final coins = (await node.fetch(coinsId))!;
        final vout = coins.outputs.indexWhere((o) => FakeChain.paysPKH(o, stranger.pubkeyHash160));
        final height = await node.height();
        final covenant = c.svc.createDepositTxn(
            fundingTx: coins,
            fundingVout: vout,
            fundingSigner: DefaultTransactionSigner(sigHashAll, strangerKey),
            fundingPubKey: strangerKey.publicKey,
            changeAddress: stranger,
            commitment: c.f.receipt.commitment,
            satoshis: c.f.receipt.satoshis,
            pp3Outpoint: c.svc.getOutpoint(created.issuance.hash, outputIndex: 3),
            refundPKH: hex.decode(stranger.pubkeyHash160),
            refundAfter: height + 150);
        await node.broadcast(covenant);
        await untilMined(covenant.id);
        final depositOutpoint = c.svc.getOutpoint(covenant.hash, outputIndex: ShieldedPoolTool.depositVout);

        // what the wallet's replies folder holds besides submission replies,
        // and the notices it is sent in a folder of their own
        final notices = <PoolRoundMined>[];
        final catchUps = <PoolCatchUpReply>[];
        List<PoolReply> sortReplies(List<InboxMessage> ms) {
          final out = <PoolReply>[];
          for (final m in ms) {
            final msg = PoolMessage.decode(m.payload);
            if (msg is PoolReply) out.add(msg);
            if (msg is PoolRoundMined) fail('a notice arrived in the replies folder, where a wallet takes it for an answer');
            if (msg is PoolCatchUpReply) catchUps.add(msg);
          }
          return out;
        }

        /// Asks the coordinator for [q] over ricochet, as a wallet does.
        Future<PoolCatchUpReply> catchUp(PoolCatchUpRequest q) async {
          await walletT.submit(coordinator, q.encode());
          final deadline = DateTime.now().add(const Duration(minutes: 1));
          while (true) {
            sortReplies(await walletT.readReplies());
            final i = catchUps.indexWhere((r) => hex.encode(r.id) == hex.encode(q.id));
            if (i >= 0) return catchUps.removeAt(i);
            if (DateTime.now().isAfter(deadline)) fail('no answer to catch-up ${q.what.name}');
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }

        /// The merkle root the node's block [hash] states, display order.
        Future<String> merkleRootOf(List<int> hash) async {
          final r = await Process.run('curl', [
            '-sS', '-u', 'bitcoin:${env['POOL_RPC_PASSWORD'] ?? 'bitcoin'}', '--data-binary',
            jsonEncode({'method': 'getblock', 'params': [hex.encode(hash), 1]}), env['LOCALNET_RPC'] ?? 'http://localhost:18332'
          ]);
          return (jsonDecode(r.stdout as String) as Map<String, dynamic>)['result']['merkleroot'] as String;
        }

        /// Submits [t] and waits for its reply, timing the round trip.
        Future<PoolReply> submit(ShieldedTransfer t, {Transaction? depositTx}) async {
          final sub = PoolSubmission.of(t, c.f.agg.spendP, depositTx: depositTx, rng: rng);
          final bytes = sub.encode();
          final sw = Stopwatch()..start();
          await walletT.submit(coordinator, bytes);
          final deadline = DateTime.now().add(const Duration(minutes: 3));
          while (true) {
            for (final r in sortReplies(await walletT.readReplies())) {
              if (hex.encode(r.id) == hex.encode(sub.id)) {
                final took = sw.elapsed;
                timings['submission ${hex.encode(sub.id).substring(0, 8)}'] = took;
                print('  submission ${hex.encode(sub.id).substring(0, 8)}: $r in ${took.inMilliseconds} ms');
                return r;
              }
            }
            if (DateTime.now().isAfter(deadline)) fail('no reply to ${hex.encode(sub.id)}');
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }

        Future<PoolAnnouncement> announced(int round) async {
          final deadline = DateTime.now().add(const Duration(minutes: 10));
          while (true) {
            final got = await walletT.feedOf(coordinatorId, round + 1, limit: 1);
            if (got.isNotEmpty) {
              final a = PoolMessage.decode(got.single.content) as PoolAnnouncement;
              expect(a.round, round);
              return a;
            }
            if (DateTime.now().isAfter(deadline)) fail('round $round was not announced: ${server.status.lastFailure}');
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }

        Duration announceDelay(int round, PoolAnnouncement a) {
          final broadcast = logRecords.firstWhere((r) => r.message.contains('round $round witness ${a.witnessId} broadcast')).time;
          final announcedAt = logRecords.firstWhere((r) => r.message.contains('round $round announced as feed entry')).time;
          return announcedAt.difference(broadcast);
        }

        // ---- round 1: the deposit and three padding transfers
        final d = c.f.transfers1[0];
        final replies1 = [
          await submit(ShieldedTransfer(d.publics, d.proof, d.bundle, depositOutpoint: depositOutpoint), depositTx: covenant),
          for (final t in c.f.transfers1.sublist(1)) await submit(t),
        ];
        for (final r in replies1) {
          expect(r.isAccepted, isTrue, reason: '$r');
          expect(r.round, 1);
        }
        final roundTrips = [for (final e in timings.entries) if (e.key.startsWith('submission')) e.value];
        for (final t in roundTrips) {
          expect(t, lessThan(const Duration(seconds: 2)), reason: 'a submission is answered within 2 s');
        }
        final a1 = await announced(1);
        timings['announce delay round 1'] = announceDelay(1, a1);
        expect(timings['announce delay round 1']!, lessThan(const Duration(seconds: 5)));
        for (final id in [a1.slotId, a1.roundId, a1.witnessId]) {
          await untilMined(id);
        }
        final status1 = await statusAt(config.server.statusFile, 1);
        expect(status1['tip']['round'], 1);
        expect(status1['tip']['witness'], a1.witnessId);
        print('  after round 1: ${status1['wallet']}');

        // ---- round 2 spends the deposited note and withdraws 300
        final replies2 = [for (final t in c.f.transfers2) await submit(t)];
        for (final r in replies2) {
          expect(r.isAccepted, isTrue, reason: '$r');
          expect(r.round, 2);
        }
        final a2 = await announced(2);
        timings['announce delay round 2'] = announceDelay(2, a2);
        for (final id in [a2.slotId, a2.roundId, a2.witnessId]) {
          await untilMined(id);
        }
        final status2 = await statusAt(config.server.statusFile, 2);
        expect(status2['tip']['round'], 2);
        expect(status2['tip']['roundTx'], a2.roundId);
        expect(status2['wallet']['lastRoundCost'], isNotNull);
        print('  after round 2: ${status2['wallet']}');
        final r2 = (await node.fetch(a2.roundId))!;
        expect(r2.outputs.where((o) => FakeChain.paysPKH(o, stranger.pubkeyHash160) && o.satoshis == BigInt.from(300)), hasLength(1),
            reason: 'the withdrawal is paid');

        // ---- the feed: the descriptor first, the announcements in order, reading from a sequence
        final all = await walletT.feedOf(coordinatorId, 1);
        expect(all.map((e) => e.sequence), [1, 2, 3]);
        final descriptor = PoolMessage.decode(all[0].content) as PoolDescriptor;
        expect(hex.encode(descriptor.issuance), created.issuance.id);
        expect((PoolMessage.decode(all[1].content) as PoolAnnouncement).round, 1);
        expect((PoolMessage.decode(all[2].content) as PoolAnnouncement).round, 2);
        final from3 = await walletT.feedOf(coordinatorId, 3);
        expect(from3.map((e) => e.sequence), [3]);

        // ---- a reader opened from the descriptor, with the chain, reaches the status's header
        final reader = ShieldedChainReader.open(descriptor.layout, created.issuance, created.witness0, created.slot0,
            tokenId: descriptor.tokenId, genesisHeader: descriptor.genesisHeader);
        for (final a in [a1, a2]) {
          final triple = (round: (await node.fetch(a.roundId))!, witness: (await node.fetch(a.witnessId))!, nextSlot: (await node.fetch(a.slotId))!);
          final applied = reader.read([triple]);
          expect(reader.stopped, isFalse, reason: '${reader.refusal}');
          expect(a.disagreement(applied.single), isNull);
        }
        expect(reader.ledger.tipRound.id, status2['tip']['roundTx']);
        expect(reader.ledger.header.encode(), server.co.ledger.header.encode());
        expect(reader.ledger.snapshot(), server.co.ledger.snapshot());

        // ---- the API, as an operator's curl sees it: both rounds mined on localnet
        final port = server.api!.port;
        Future<Map<String, dynamic>> curl(String path) async {
          final r = await Process.run('curl', ['-sS', '-f', 'http://127.0.0.1:$port$path']);
          expect(r.exitCode, 0, reason: '$path: ${r.stderr}');
          final body = jsonDecode(r.stdout as String) as Map<String, dynamic>;
          expect(body['v'], 1, reason: path);
          return body;
        }

        final apiDeadline = DateTime.now().add(const Duration(minutes: 1));
        List<dynamic> rounds;
        while (true) {
          rounds = (await curl('/api/rounds'))['rounds'] as List;
          if (rounds.length == 2 && rounds.every((r) => r['minedHeight'] != null)) break;
          if (DateTime.now().isAfter(apiDeadline)) fail('the API did not show both rounds mined: $rounds');
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect([for (final r in rounds) r['witness']], [a2.witnessId, a1.witnessId]);
        for (final r in rounds) {
          expect(r['minedHeight'], await node.minedHeight(r['witness'] as String));
        }
        final pool = await curl('/api/pool');
        expect(pool['tip'], 2);
        // Regtest has no public explorer, so the page shows txids unlinked.
        expect(pool.containsKey('explorer'), isTrue);
        expect(pool['explorer'], isNull);
        expect(pool['genesis']['issuance'], created.issuance.id);
        expect((await curl('/api/stats'))['roundsMined'], 2);
        expect((await curl('/api/series?metric=rounds&bucket=day'))['points'], isNotEmpty);
        final events = await Process.run('curl', ['-sS', '-m', '2', 'http://127.0.0.1:$port/api/events']);
        expect(events.stdout as String, startsWith('event: live\ndata: {"v":1'));
        final post = await Process.run('curl', ['-sS', '-o', '/dev/null', '-w', '%{http_code}', '-X', 'POST', 'http://127.0.0.1:$port/api/pool']);
        expect(post.stdout, '405');

        // ---- catch-up and notices over ricochet, checked against the node's own blocks
        final noticeDeadline = DateTime.now().add(const Duration(minutes: 1));
        while (notices.map((n) => n.round).toSet().length < 2) {
          if (DateTime.now().isAfter(noticeDeadline)) fail('the submitter was not sent both rounds: ${notices.map((n) => n.round)}');
          for (final m in await walletT.readNotices()) {
            notices.add(PoolMessage.decode(m.payload) as PoolRoundMined);
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        for (final n in notices) {
          final a = n.round == 1 ? a1 : a2;
          expect(hex.encode(n.witnessTxId), a.witnessId);
          expect(hex.encode(n.roundTxId), a.roundId);
          expect(hex.encode(n.computedMerkleRoot()), await merkleRootOf(n.blockHash), reason: 'round ${n.round}\'s notice is in its block');
        }
        final head = await catchUp(PoolCatchUpRequest.head());
        expect(head.round, 2);
        expect(hex.encode(head.computedMerkleRoot()), await merkleRootOf(head.blockHash!));
        final round1 = await catchUp(PoolCatchUpRequest.round(1));
        expect(ShieldedLedger.parse(round1.witnessTx!).id, a1.witnessId);
        expect(hex.encode(round1.computedMerkleRoot()), await merkleRootOf(round1.blockHash!));
        final frontier = await catchUp(PoolCatchUpRequest.frontier());
        expect(frontier.round, 2);
        expect(frontier.blockRoot, a2.blockRoot);
        expect((await catchUp(PoolCatchUpRequest.round(9))).refusal, CatchUpRefusal.notYet);

        if (signals != null) await awaitSignal('done');

        // ---- the folder is not left to fill: 1,100 messages faster than they are answered
        final before = server.status;
        final consumedBefore = before.submissionsAccepted + before.submissionsRefused + before.submissionsDropped;
        final sw2 = Stopwatch()..start();
        for (int i = 0; i < 1100; i++) {
          final garbage = Uint8List.fromList(List.generate(20 + rng.nextInt(200), (_) => rng.nextInt(256)));
          await walletT.submit(coordinator, garbage);
        }
        print('  1,100 messages sent in ${sw2.elapsedMilliseconds} ms');
        final deadline = DateTime.now().add(const Duration(minutes: 5));
        while (true) {
          final s = server.status;
          if (s.submissionsAccepted + s.submissionsRefused + s.submissionsDropped - consumedBefore >= 1100 && await transport.drain().then((m) => m.isEmpty)) break;
          if (DateTime.now().isAfter(deadline)) fail('the folder was not drained: ${server.status.toJson()}');
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        timings['1,100 messages consumed'] = sw2.elapsed;
        expect(await transport.drain(), isEmpty);

        // ---- restart after two rounds
        await server.stop();
        final again = await RicochetTransport.connect(seed: seed, server: ricochet.address);
        final sw3 = Stopwatch()..start();
        server = await PoolServer.start(config: config, wallet: wallet, store: store, chain: node, transport: again);
        timings['restart at round 2'] = sw3.elapsed;
        expect(server.co.ledger.round, 2);
        expect(server.co.ledger.snapshot(), reader.ledger.snapshot());
        final padding = await submit(c.f.transfers2[1]);
        expect(padding.isAccepted, isTrue);
        expect(padding.round, 3);
      } finally {
        await server.stop();
        await walletT.close();
      }
      // nothing secret in the output
      final text = [for (final r in logRecords) r.message, File(config.server.statusFile).readAsStringSync()].join('\n');
      expect(text, isNot(contains(contents.ownerKey.toHex())));
      expect(text, isNot(contains(contents.ownerKey.toWIF())));
      expect(text, isNot(contains(hex.encode(seed))));
      expect(text, isNot(contains(passphrase)));
      for (final t in [...c.f.transfers1, ...c.f.transfers2]) {
        expect(text, isNot(contains(hex.encode(t.encode(c.f.agg.spendP)).substring(0, 64))));
      }
    }, timeout: const Timeout(Duration(minutes: 30)));
  }, skip: skip);
}

/// A peer id from its base58 string.
class PeerIdOf {
  final String s;
  PeerIdOf(this.s);
  PeerId get id => PeerId.fromString(s);
}
