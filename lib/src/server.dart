import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';
import 'package:tstokenlib/src/crypto/stark_kernels.dart' show StarkKernels;
import 'package:tstokenlib/tstokenlib.dart';

import 'chain_access.dart';
import 'api/api_host.dart';
import 'api/pool_api.dart';
import 'config.dart';
import 'metrics/history_rebuild.dart';
import 'metrics/metrics_history.dart';
import 'metrics/metrics_recorder.dart';
import 'plans.dart';
import 'round_store.dart';
import 'status.dart';
import 'transport.dart';
import 'wallet.dart';

/// The server would not start: what disagreed, in a sentence for the
/// operator.
class StartRefusal implements Exception {
  final String reason;
  const StartRefusal(this.reason);
  @override
  String toString() => 'the server refuses to start: $reason';
}

/// The coordinator as a process: opens or recovers the pool, drains the
/// inbox into the library's intake, lets the library close, fund, build,
/// store and publish rounds through the chain access, announces each on
/// the feed after its witness is broadcast, keeps the status file, and
/// stops with nothing half-published.
///
/// One loop, single-threaded: a timer drains the inbox every poll
/// interval, the library's own deadline closes rounds, and a publish in
/// progress is the one thing a stop waits for. The four collaborators are
/// interfaces, so the tests run the whole of this on fakes and the
/// library's test chain.
class PoolServer {
  final PoolConfig config;
  final CoordinatorWallet wallet;
  final RoundStore store;
  final ChainAccess chain;
  final PoolTransport transport;
  final Logger log;
  final CoordinatorClock clock;
  final ServerStatus status;

  late final ShieldedPoolTool tool;
  late final PoolAggregation plan;
  late final ShieldedCoordinator co;
  late final Transaction issuance, witness0, slot0;

  Timer? _poll;
  bool _draining = false;
  bool _stopping = false;

  /// The publish sequence of the round being published, awaited by [stop].
  Completer<void>? _publishing;

  /// Who submitted each accepted transfer, by submission id, for the
  /// expired replies the library hands back at close. Cleared as rounds
  /// publish.
  final _submitters = <String, String>{};

  /// Announcements that could not be appended, retried on a timer.
  final _unannounced = <PoolAnnouncement>[];
  Timer? _announceRetry;

  /// The public view of the pool, when the configuration enables the API;
  /// null otherwise, or when its history could not be opened.
  MetricsRecorder? metrics;

  /// The read-only API over [metrics], in its own isolate so that proving
  /// a round does not stop it answering.
  ApiHost? api;

  /// Whether the round [_watched] is still being built, and the timing of
  /// the last build that ended: until the next build starts its own, the
  /// library's timing is that one, and reading it would show a finished
  /// round as the one in progress.
  bool _buildInFlight = false;
  RoundTiming? _endedTiming;

  /// Published rounds whose witness is not yet seen mined, by number, and
  /// whether the one loop that watches them is running.
  final _minedQueue = SplayTreeMap<int, String>();
  bool _watchingMined = false;

  PoolServer._({
    required this.config,
    required this.wallet,
    required this.store,
    required this.chain,
    required this.transport,
    required this.clock,
    Logger? log,
  })  : log = log ?? Logger('server'),
        status = ServerStatus(transport.peerId);

  /// Opens or recovers the pool and starts taking submissions.
  static Future<PoolServer> start({
    required PoolConfig config,
    required CoordinatorWallet wallet,
    required RoundStore store,
    required ChainAccess chain,
    required PoolTransport transport,
    CoordinatorClock clock = const SystemClock(),
    Logger? log,
  }) async {
    final s = PoolServer._(config: config, wallet: wallet, store: store, chain: chain, transport: transport, clock: clock, log: log);
    await s._start();
    return s;
  }

  Future<void> _start() async {
    final sw = Stopwatch()..start();
    final laps = <String>[];
    void lap(String what) {
      laps.add('$what ${sw.elapsedMilliseconds} ms');
      sw.reset();
    }

    if (StarkKernels.tryLoad() == null) {
      throw StartRefusal('the native kernels (${StarkKernels.fileName}) were not found; set ${StarkKernels.envVar} '
          'or build native/stark_kernels beside the process');
    }
    final genesis = config.genesis;
    if (genesis == null) throw StartRefusal('the configuration names no genesis; run `create` first');
    tool = ShieldedPoolTool(networkType: config.network);
    plan = planNamed(config.plan);
    final layout = ShieldedPoolLayout.of(plan.tree);
    lap('plan');

    // the genesis, from the chain
    issuance = await _fetchGenesis(genesis.issuance, 'issuance');
    witness0 = await _fetchGenesis(genesis.witness0, 'witness0');
    slot0 = await _fetchGenesis(genesis.slot0, 'slot0');
    lap('genesis');

    // the ledger: the store's last round restored, checked against the
    // chain and re-broadcast where the chain lacks it, or the genesis
    final ShieldedLedger ledger;
    final last = await store.last();
    if (last == null) {
      ledger = ShieldedCoordinator.recover(layout, issuance: issuance, witness0: witness0, slot0: slot0, triples: const [], lastRound: 0);
      await _refuseIfSpent(issuance.id, 0);
      log.info('opened the pool at round 0 from the genesis');
    } else {
      final snapshot = last.snapshot;
      if (snapshot == null) throw StartRefusal('round ${last.number} in the store has no snapshot');
      await _reBroadcast(last);
      try {
        ledger = ShieldedCoordinator.recover(layout, snapshot: snapshot, triples: const [], lastRound: last.number);
      } on LedgerRefusal catch (e) {
        throw StartRefusal('round ${last.number}\'s snapshot does not restore: $e');
      } on RecoveryRefusal catch (e) {
        throw StartRefusal('$e');
      }
      if (ledger.tipRound.id != last.round.id) {
        throw StartRefusal('round ${last.number}\'s snapshot has tip ${ledger.tipRound.id}, the store\'s record ${last.round.id}');
      }
      await _refuseIfSpent(last.round.id, last.number);
      log.info('recovered the pool at round ${last.number} from the store');
    }
    lap('ledger');

    await wallet.reconcile();
    lap('wallet');
    co = ShieldedCoordinator(
      config: CoordinatorConfig(
          plan: plan,
          roundDeadline: config.round.deadline,
          paddingStock: config.round.paddingStock,
          feeRate: config.round.feeRate,
          feeFloor: config.round.feeFloor,
          depositMargin: config.round.depositMargin),
      tool: tool,
      ledger: ledger,
      funding: wallet,
      store: store,
      publish: _publish,
      owner: wallet.owner,
      ownerPub: wallet.ownerPub,
      clock: clock,
      notify: _notify,
    );
    co.chainHeight = await chain.height();
    lap('coordinator');

    await _checkFeed();
    lap('feed');
    status.ready = true;
    _openMetrics();
    await _startApi();
    await _refresh();
    _poll = Timer.periodic(config.server.pollInterval, (_) => _tick());
    log.info('ready (${laps.join(', ')}): tip round ${co.ledger.round}, ${wallet.report}, peer id ${transport.peerId}');
    unawaited(co.runIdleWork());
    if (metrics != null) unawaited(_rebuildHistory());
  }

  Future<Transaction> _fetchGenesis(String txid, String what) async {
    final tx = await chain.fetch(txid);
    if (tx == null) throw StartRefusal('the genesis $what $txid is not known to ${chain.name}');
    return tx;
  }

  /// The tip's PP3 spent on the chain means a round the store does not
  /// hold: the chain contradicts the store, and building on the store's
  /// tip would fork the pool.
  Future<void> _refuseIfSpent(String tipRoundId, int number) async {
    if (!await chain.unspent(tipRoundId, 3)) {
      throw StartRefusal('the chain has spent round $number\'s PP3 ($tipRoundId:3) and the store holds no round ${number + 1}; '
          'the chain has a round this server did not build');
    }
  }

  /// Re-broadcasts what the chain does not show of the stored round, in
  /// order, and waits until all three are mined.
  Future<void> _reBroadcast(StoredRound r) async {
    for (final (tx, what) in [(r.y, 'Y'), (r.round, 'round'), (r.witness, 'witness')]) {
      if (await chain.minedHeight(tx.id) != null) continue;
      if (await chain.fetch(tx.id) != null) {
        log.info('round ${r.number}\'s $what ${tx.id} is known to the chain but not mined; waiting');
      } else {
        log.warning('round ${r.number}\'s $what ${tx.id} is not on the chain; broadcasting it again');
        try {
          await chain.broadcast(tx);
        } on BroadcastRefusal catch (e) {
          throw StartRefusal('round ${r.number}\'s $what ${tx.id} was refused when broadcast again: ${e.reason}');
        }
      }
      await _waitMined(tx.id, 'round ${r.number}\'s $what');
    }
  }

  Future<void> _waitMined(String txid, String what) async {
    final deadline = DateTime.now().add(config.server.fundingTimeout);
    while (await chain.minedHeight(txid) == null) {
      if (DateTime.now().isAfter(deadline)) throw StartRefusal('$what $txid was not mined within ${config.server.fundingTimeout}');
      await Future<void>.delayed(config.server.minedPoll);
    }
  }

  PoolDescriptor get descriptor => co.descriptor(config.network, issuance, witness0, slot0);

  /// The feed's first entry is the descriptor, and its last announcement
  /// is the tip: a crash between a witness's broadcast and its
  /// announcement is made good here.
  Future<void> _checkFeed() async {
    final length = await transport.feedLength();
    if (length == 0) {
      await transport.ensureFeed();
      final seq = await transport.announce(descriptor.encode());
      log.info('the descriptor is the feed\'s entry $seq');
    } else {
      final first = await transport.feed(1, limit: 1);
      final PoolDescriptor d;
      try {
        d = PoolMessage.decode(first.single.content) as PoolDescriptor;
      } catch (e) {
        throw StartRefusal('the feed\'s first entry is not a descriptor ($e)');
      }
      if (hex.encode(d.encode()) != hex.encode(descriptor.encode())) {
        throw StartRefusal('the feed\'s descriptor is not this pool\'s: it names issuance ${hex.encode(d.issuance)}');
      }
      final tail = await transport.feed(length, limit: 1);
      int announced = 0;
      if (length > 1 && tail.isNotEmpty) {
        try {
          announced = (PoolMessage.decode(tail.single.content) as PoolAnnouncement).round;
        } catch (e) {
          throw StartRefusal('the feed\'s last entry is not an announcement ($e)');
        }
      }
      status.lastAnnouncedRound = announced == 0 ? null : announced;
      status.lastAnnouncementSequence = announced == 0 ? null : length;
      if (announced < co.ledger.round) {
        // only the tip can be missing: every earlier round was announced
        // before the next was built
        final r = (await store.read(co.ledger.round))!;
        final a = PoolAnnouncement.of(co.ledger.round, co.ledger.header, r.round, r.witness, r.y, blockRoot: co.ledger.blockRoot);
        log.warning('round ${a.round} was published but not announced; announcing it now');
        await _announce(a);
      }
    }
  }

  // ---------------------------------------------------------------- intake

  Future<PoolAnnouncement?>? _watched;

  /// Every poll: notice a round being built, so its outcome (a failure at
  /// funding, say) reaches the status when it ends, then drain the inbox.
  void _tick() {
    final b = co.building;
    if (b != null && b != _watched) {
      _watched = b;
      _buildInFlight = true;
      b.whenComplete(() {
        _buildInFlight = false;
        _endedTiming = co.lastTiming;
        if (!_stopping) unawaited(_refresh());
      });
    }
    _observe();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining || _stopping) return;
    _draining = true;
    try {
      final batch = await transport.drain();
      if (batch.isEmpty) return;
      try {
        co.chainHeight = await chain.height();
      } on ChainError catch (e) {
        log.warning('height: $e');
      }
      final done = <String>[];
      for (final m in batch) {
        if (_stopping) break;
        await _handle(m);
        done.add(m.id);
      }
      try {
        await transport.delivered(done);
      } on TransportFailure catch (e) {
        status.fail('$e');
        log.warning('$e');
      }
      await _refresh();
    } finally {
      _draining = false;
    }
  }

  /// One message, hostile until the library says otherwise: routed by its
  /// kind, its deposit confirmed on the chain, taken through the library's
  /// intake, and answered to its sender. It ends in a reply or a drop,
  /// never anything else.
  Future<void> _handle(InboxMessage m) async {
    final sender = m.sender;
    try {
      if (PoolMessage.kindOf(m.payload) != PoolMessageKind.submission) {
        status.submissionsDropped++;
        log.info('dropped a message from $sender: not a submission (${m.payload.length} bytes)');
        return;
      }
      final reply = await _depositCheck(m.payload) ?? co.submitBytes(m.payload);
      if (reply == null) {
        status.submissionsDropped++;
        log.info('dropped a submission from $sender: no readable id');
        return;
      }
      final id = hex.encode(reply.id);
      if (reply.isAccepted) {
        status.submissionsAccepted++;
        _submitters[id] = sender;
        log.info('submission $id from $sender: accepted into round ${reply.round}');
      } else {
        status.submissionsRefused++;
        log.info('submission $id from $sender: refused (${reply.reason!.name}): ${reply.sentence}');
      }
      await _reply(sender, reply);
    } catch (e, st) {
      // the library ends every submission in a reply or a drop; anything
      // else is a bug here, and the next message is still served
      status.fail('message ${m.id} from $sender: $e');
      log.severe('message ${m.id} from $sender failed unexpectedly: $e', e, st);
    }
  }

  /// A deposit's covenant must be mined and its output unspent before the
  /// library, which reads only the bytes, checks the covenant's terms.
  /// Null when there is nothing to check or it passes.
  Future<PoolReply?> _depositCheck(Uint8List bytes) async {
    final PoolSubmission s;
    try {
      s = PoolSubmission.decode(bytes);
    } on ProtocolRefusal {
      return null; // the library names the field
    }
    if (s.depositTx == null) return null;
    final List<int>? outpoint;
    try {
      outpoint = s.transfer(plan.spendP).depositOutpoint;
    } catch (_) {
      return null; // the library names the field
    }
    if (outpoint == null) return null; // the library refuses the stray covenant
    final txid = hex.encode(outpoint.sublist(0, 32).reversed.toList());
    final vout = ByteData.sublistView(Uint8List.fromList(outpoint), 32).getUint32(0, Endian.little);
    try {
      if (await chain.minedHeight(txid) == null) {
        return PoolReply.refused(s.id, RefusalReason.depositCovenant, 'the deposit covenant $txid is not mined');
      }
      if (!await chain.unspent(txid, vout)) {
        return PoolReply.refused(s.id, RefusalReason.depositCovenant, 'the deposit covenant output $txid:$vout is spent');
      }
    } on ChainError catch (e) {
      return PoolReply.refused(s.id, RefusalReason.depositCovenant, 'the deposit covenant could not be checked on the chain ($e)');
    }
    return null;
  }

  Future<void> _reply(String sender, PoolReply reply) async {
    try {
      await transport.reply(sender, reply.encode());
    } on TransportFailure catch (e) {
      status.fail('reply to submission ${hex.encode(reply.id)} could not be sent: $e');
      log.warning('reply to submission ${hex.encode(reply.id)} for $sender could not be sent: $e');
    }
  }

  /// The library's expired replies, for transfers dropped at close.
  void _notify(PoolReply reply) {
    final id = hex.encode(reply.id);
    final sender = _submitters.remove(id);
    log.info('submission $id: ${reply.outcome.name}: ${reply.sentence}');
    if (sender != null) unawaited(_reply(sender, reply));
  }

  // ------------------------------------------------------------ publishing

  /// The library's publish callback, called with Y, the round and the
  /// witness in order after the store has them. A refusal is thrown back
  /// so the library records the round's failure; the store keeps the round
  /// for the next start to re-broadcast. The witness's broadcast is
  /// followed by the announcement.
  Future<void> _publish(Transaction tx) async {
    final n = (await store.lastNumber())!;
    final r = (await store.read(n))!;
    final what = tx.id == r.y.id
        ? 'Y'
        : tx.id == r.round.id
            ? 'round'
            : tx.id == r.witness.id
                ? 'witness'
                : 'transaction';
    if (what == 'Y') _publishing = Completer<void>();
    try {
      final st = await chain.broadcast(tx);
      log.info('round $n $what ${tx.id} broadcast ($st)');
    } catch (e) {
      status.fail('round $n $what ${tx.id} was refused: $e');
      log.severe('round $n $what ${tx.id} was refused: $e');
      await _refresh();
      _finishPublish();
      rethrow;
    }
    if (what == 'witness') {
      // the library's own announcement of the round, which carries its
      // block root
      final a = co.announcements.lastWhere((a) => a.round == n);
      await _announce(a);
      metrics?.roundPublished(a, r.witness, co.lastTiming);
      _watchMined(n, a.witnessId);
      _submitters.clear();
      try {
        await wallet.reconcile(roundTxs: [r.y, r.round, r.witness]);
        final cost = wallet.lastRoundCost;
        if (cost != null) metrics?.costKnown(n, cost);
      } catch (e) {
        log.warning('reconcile after round $n: $e');
      }
      await _refresh();
      _finishPublish();
      final left = wallet.roundsLeft;
      if (left != null && left < config.wallet.warnRoundsLeft) {
        log.warning('the wallet can pay for $left more rounds at the last round\'s cost (${wallet.lastRoundCost} sat); top it up');
      }
      unawaited(co.runIdleWork());
    }
  }

  void _finishPublish() {
    final p = _publishing;
    if (p != null && !p.isCompleted) p.complete();
    _publishing = null;
  }

  Future<void> _announce(PoolAnnouncement a) async {
    try {
      final seq = await transport.announce(a.encode());
      status.lastAnnouncedRound = a.round;
      status.lastAnnouncementSequence = seq;
      log.info('round ${a.round} announced as feed entry $seq');
    } on TransportFailure catch (e) {
      status.fail('round ${a.round} could not be announced: $e');
      log.warning('round ${a.round} could not be announced, will retry: $e');
      _unannounced.add(a);
      _announceRetry ??= Timer.periodic(const Duration(seconds: 30), (_) => _retryAnnouncements());
    }
  }

  Future<void> _retryAnnouncements() async {
    if (_unannounced.isEmpty) {
      _announceRetry?.cancel();
      _announceRetry = null;
      return;
    }
    final a = _unannounced.first;
    try {
      final seq = await transport.announce(a.encode());
      _unannounced.removeAt(0);
      status.lastAnnouncedRound = a.round;
      status.lastAnnouncementSequence = seq;
      log.info('round ${a.round} announced as feed entry $seq after a retry');
      await _refresh();
    } on TransportFailure catch (e) {
      log.warning('round ${a.round} still not announced: $e');
    }
  }

  // ---------------------------------------------------------------- status

  Future<void> _refresh() async {
    _observe();
    final s = co.status;
    status.fromCoordinator(s);
    status.tipY = co.ledger.tipSlot.id;
    status.tipRoundTxId = co.ledger.tipRound.id;
    status.tipWitness = co.ledger.tipWitness.id;
    status.wallet = wallet.report;
    final f = s.lastFailure;
    if (f != null && '$f' != status.lastFailure) status.fail('$f');
    status.needsTopUp = (f != null && f.stage == 'funding') || wallet.roundsLeft == 0;
    status.stopping = _stopping;
    try {
      await status.write(config.server.statusFile);
    } catch (e) {
      log.warning('status file: $e');
    }
  }

  // --------------------------------------------------------------- metrics

  void _openMetrics() {
    final api = config.api;
    if (api == null) return;
    try {
      final history = MetricsHistory.open(api.metricsFile);
      if (history.movedAside != null) {
        log.warning('the pool history at ${api.metricsFile} was not one this server reads; moved it to ${history.movedAside} and started afresh');
      }
      final m = metrics = MetricsRecorder(history, capacity: co.capacity, clock: clock);
      for (final (n, witness) in m.unminedWitnesses()) {
        _watchMined(n, witness);
      }
    } catch (e) {
      // the pool runs without its public view rather than not at all
      log.warning('the pool history could not be opened, so the API is off: $e');
      metrics = null;
    }
  }

  Future<void> _startApi() async {
    final m = metrics, cfg = config.api, genesis = config.genesis;
    if (m == null || cfg == null || genesis == null) return;
    try {
      api = await ApiHost.start(
        config: cfg,
        recorder: m,
        facts: PoolFacts(
          network: config.network,
          plan: config.plan,
          capacity: co.capacity,
          issuance: genesis.issuance,
          witness0: genesis.witness0,
          slot0: genesis.slot0,
          roundDeadline: config.round.deadline,
          explorer: switch ((config.network, config.chain.kind)) {
            (NetworkType.MAIN, _) => 'main',
            (_, ChainKind.testnet) => 'test',
            // A test-network node is the regtest localnet: no explorer.
            _ => null,
          },
        ),
      );
      log.info('the API is at http://${cfg.bind.address}:${api!.port}/api/');
    } catch (e) {
      log.warning('the API could not start on ${cfg.bind.address}:${cfg.port}, so it is off; the pool runs on: $e');
    }
  }

  /// Hands the recorder what the library says the pool is doing: whether
  /// transfers are pending, and the laps of the round being built.
  void _observe() {
    final m = metrics;
    if (m == null) return;
    final s = co.status;
    final t = co.lastTiming;
    final Iterable<String>? laps = !_buildInFlight
        ? null
        : t == null || identical(t, _endedTiming)
            ? const []
            : t.stages.keys;
    m.observe(assembling: s.pending > 0, deadline: s.deadline, tipRound: co.ledger.round, laps: laps);
  }

  void _watchMined(int number, String witness) {
    if (metrics == null) return;
    _minedQueue[number] = witness;
    if (!_watchingMined) unawaited(_watchMinedLoop());
  }

  /// One round at a time, oldest first: a witness cannot be mined before
  /// the rounds it builds on, and a backlog after an outage should not
  /// burst the chain service's rate limit. A round not mined within the
  /// funding timeout is left for the next start.
  Future<void> _watchMinedLoop() async {
    _watchingMined = true;
    try {
      while (_minedQueue.isNotEmpty && !_stopping) {
        final n = _minedQueue.firstKey()!;
        final txid = _minedQueue[n]!;
        final giveUp = DateTime.now().add(config.server.fundingTimeout);
        int? height;
        while (!_stopping) {
          try {
            height = await chain.minedHeight(txid);
          } catch (e) {
            log.fine('asking whether round $n\'s witness is mined: $e');
          }
          if (height != null || DateTime.now().isAfter(giveUp)) break;
          await Future<void>.delayed(config.server.minedPoll);
        }
        if (_stopping) break;
        _minedQueue.remove(n);
        if (height != null) {
          metrics?.mined(n, height);
        } else {
          log.warning('round $n\'s witness $txid was not mined within ${config.server.fundingTimeout}; the next start asks again');
        }
      }
    } finally {
      _watchingMined = false;
    }
  }

  /// Fills the history with the stored rounds it lacks, after ready; see
  /// [rebuildHistory].
  Future<void> _rebuildHistory() => rebuildHistory(
        recorder: metrics!,
        store: store,
        transport: transport,
        building: () => _buildInFlight,
        stopping: () => _stopping,
        pause: config.server.pollInterval,
        rebuilt: _watchMined,
        log: log,
      );

  /// Whether a round is being published right now.
  bool get publishing => _publishing != null;

  // -------------------------------------------------------------- shutdown

  /// Takes no further submissions, finishes the publish in progress, and
  /// closes the transport. A round being proved is abandoned with it.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    // the public view goes first: nothing it serves matters to the stop
    await api?.close();
    _poll?.cancel();
    _announceRetry?.cancel();
    log.info('stopping: no further submissions');
    final p = _publishing;
    if (p != null) {
      log.info('a publish is in progress; waiting for it');
      await p.future;
    }
    status.ready = false;
    await _refresh();
    await metrics?.close();
    await transport.close();
    log.info('stopped at round ${co.ledger.round}');
  }
}
