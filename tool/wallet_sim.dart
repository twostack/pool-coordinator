/// Wallets for a pool on localnet, so a pool started with `run` has rounds
/// to build and its public page has something to show.
///
///   POOL_RPC_PASSWORD=... dart run tool/wallet_sim.dart --config config.yaml --mine-every 2
///
/// Each round it proves [--deposits] deposits of a random value, each
/// backed by a covenant it funds from the node's wallet and names the
/// pool's live PP3 in, fills the rest of the round with padding transfers
/// so the round closes at once, submits them all over ricochet, waits for
/// the coordinator's replies and for the round's announcement on the feed,
/// then waits [--every] seconds and does it again. The deposits are the
/// round's real transfers, so the page shows them; their notes go to a key
/// the simulator makes up and forgets, since it never spends them. It is a
/// load for the coordinator, not a wallet: the wallet is cloak.
///
/// Deposits need a node to pay from (chain kind `node`, which is regtest
/// here); `--deposits 0` sends padding only and needs no chain.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:convert/convert.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:tstokenlib/tstokenlib.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('config', abbr: 'c', defaultsTo: 'config.yaml', help: 'the pool\'s configuration, as `run` reads it')
    ..addOption('coordinator', help: 'the coordinator\'s peer id (default: the one in its status file)')
    ..addOption('rounds', defaultsTo: '0', help: 'rounds to submit, 0 for until stopped')
    ..addOption('deposits', defaultsTo: '1', help: 'deposits a round, at most the plan\'s receipt slots')
    ..addOption('every', defaultsTo: '30', help: 'seconds to wait after a round is announced')
    ..addOption('mine-every', defaultsTo: '0', help: 'mine a block every this many seconds (regtest), 0 for never')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exit(64);
  }
  if (args['help'] as bool) {
    stdout.writeln('dart run tool/wallet_sim.dart [options]\n\n${parser.usage}');
    return;
  }
  int number(String name, {int min = 0}) {
    final v = int.tryParse(args[name] as String);
    if (v == null || v < min) {
      stderr.writeln('--$name must be a whole number of at least $min');
      exit(64);
    }
    return v;
  }

  final Simulator sim;
  try {
    sim = await Simulator.open(
      configPath: args['config'] as String,
      coordinator: args['coordinator'] as String?,
      deposits: number('deposits'),
      mineEvery: Duration(seconds: number('mine-every')),
    );
  } on SimFailure catch (e) {
    stderr.writeln('wallet_sim: $e');
    exit(1);
  }
  var stopping = false;
  for (final s in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    s.watch().listen((_) {
      if (stopping) exit(130);
      stopping = true;
      say('stopping after this round (again to quit now)');
    });
  }
  final rounds = number('rounds');
  final every = Duration(seconds: number('every'));
  try {
    for (var i = 0; !stopping && (rounds == 0 || i < rounds); i++) {
      await sim.round();
      if (!stopping && (rounds == 0 || i + 1 < rounds)) await Future<void>.delayed(every);
    }
  } on SimFailure catch (e) {
    stderr.writeln('wallet_sim: $e');
    exitCode = 1;
  } finally {
    await sim.close();
  }
  exit(exitCode);
}

void say(String line) => stdout.writeln('${DateTime.now().toIso8601String().substring(11, 19)}  $line');

class SimFailure implements Exception {
  final String message;
  SimFailure(this.message);
  @override
  String toString() => message;
}

class Simulator {
  final PoolConfig config;
  final PoolAggregation plan;
  final String coordinator;
  final int deposits;
  final NodeChain? node;
  final RicochetTransport transport;
  final Timer? miner;
  final _rng = Random.secure();
  final _svc = ShieldedPoolTool();
  int _feedNext = 2;
  PoolAnnouncement? _tip;

  Simulator._(this.config, this.plan, this.coordinator, this.deposits, this.node, this.transport, this.miner);

  static Future<Simulator> open({
    required String configPath,
    String? coordinator,
    required int deposits,
    required Duration mineEvery,
  }) async {
    final config = await PoolConfig.load(configPath);
    final plan = planNamed(config.plan);
    if (config.genesis == null) throw SimFailure('the pool has no genesis in $configPath yet; run `create` first');
    if (deposits > plan.receiptSlots) {
      throw SimFailure('the ${config.plan} plan takes at most ${plan.receiptSlots} deposits a round');
    }
    if (deposits > plan.transfers) throw SimFailure('a round holds ${plan.transfers} transfers');
    final peer = coordinator ?? _peerFromStatus(config);

    NodeChain? node;
    if (deposits > 0 || mineEvery > Duration.zero) {
      if (config.chain.kind != ChainKind.node) {
        throw SimFailure('deposits and mining need a node to pay from and mine on; use --deposits 0 on ${config.chain.kind.name}');
      }
      node = NodeChain(
          rpcUrl: config.chain.rpcUrl!, user: config.chain.rpcUser!, password: _rpcPassword(config), timeout: const Duration(seconds: 60));
      await node.height().catchError((Object e) => throw SimFailure('the node at ${config.chain.rpcUrl} does not answer: $e'));
    }
    // a fresh identity every run: the simulator's wallets are nobody
    final seed = Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)));
    final transport = await RicochetTransport.connect(seed: seed, server: config.ricochet.server, retryDelay: const Duration(milliseconds: 500));
    final miner = mineEvery > Duration.zero ? Timer.periodic(mineEvery, (_) => node!.generate(1).catchError((_) {})) : null;
    say('wallets as ${transport.peerId} for coordinator $peer; ${config.plan} plan, ${plan.transfers} transfers a round, '
        '$deposits deposit${deposits == 1 ? '' : 's'}${miner == null ? '' : ', mining a block every ${mineEvery.inSeconds} s'}');
    return Simulator._(config, plan, peer, deposits, node, transport, miner);
  }

  static String _peerFromStatus(PoolConfig config) {
    final f = File(config.server.statusFile);
    Object? status;
    try {
      status = (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)['peerId'];
    } catch (_) {}
    if (status is! String) throw SimFailure('no peer id in ${f.path}; start the pool with `run`, or pass --coordinator');
    return status;
  }

  static String _rpcPassword(PoolConfig config) {
    final env = Platform.environment[Secrets.rpcPasswordVar];
    if (env != null && env.isNotEmpty) return env;
    final file = config.chain.rpcPasswordFile;
    if (file != null && File(file).existsSync()) return File(file).readAsStringSync().trim();
    throw SimFailure('set ${Secrets.rpcPasswordVar} (or chain.rpc_password_file) for the node');
  }

  Future<void> close() async {
    miner?.cancel();
    await transport.close();
    node?.close();
  }

  /// One round: the deposits, the padding, the submissions, the replies,
  /// the announcement.
  Future<void> round() async {
    final tip = await _latest();
    final next = (tip?.round ?? 0) + 1;
    final sw = Stopwatch()..start();
    final built = <(ShieldedTransfer, Transaction?)>[];
    for (var i = 0; i < deposits; i++) {
      built.add(await _deposit(tip));
    }
    for (var i = built.length; i < plan.transfers; i++) {
      built.add((ShieldedTransfer.padding(plan.spendP, rng: _rng), null));
    }
    for (final (t, _) in built) {
      final why = t.refusal();
      if (why != null) throw SimFailure('built a transfer that refuses itself: $why');
    }
    say('round $next: ${built.length} transfers ready in ${sw.elapsedMilliseconds} ms; submitting');

    final pending = <String, PoolSubmission>{};
    for (final (t, depositTx) in built) {
      final sub = PoolSubmission.of(t, plan.spendP, depositTx: depositTx, rng: _rng);
      pending[hex.encode(sub.id)] = sub;
      await transport.submit(coordinator, sub.encode());
    }
    final rounds = <int>{};
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (pending.isNotEmpty) {
      for (final m in await transport.readReplies()) {
        final PoolReply r;
        try {
          r = PoolMessage.decode(m.payload) as PoolReply;
        } catch (_) {
          continue;
        }
        if (pending.remove(hex.encode(r.id)) == null) continue;
        if (!r.isAccepted) throw SimFailure('a transfer was refused: ${r.reason?.name} ${r.sentence ?? ''}');
        rounds.add(r.round!);
      }
      if (pending.isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) throw SimFailure('${pending.length} submissions had no reply in 3 minutes');
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    final into = rounds.reduce(max);
    say('round $into: all ${built.length} accepted${rounds.length > 1 ? ' (across rounds ${rounds.join(', ')})' : ''}; waiting for it to be announced');
    final announced = await _announced(into);
    say('round $into: announced, witness ${announced.witnessId} (${sw.elapsed.inSeconds} s from start)');
  }

  /// A deposit of a random value, proved, and its covenant funded, mined
  /// and naming PP3 of [tip] (the issuance's before round 1).
  Future<(ShieldedTransfer, Transaction?)> _deposit(PoolAnnouncement? tip) async {
    final chain = node!;
    final value = 1000 + _rng.nextInt(49) * 1000;
    List<int> lanes(int n) => List.generate(n, (_) => _rng.nextInt(M31.p));
    final keys = PoolWalletKeys(lanes(5));
    final to = await NoteAddress.at(keys.ivk, 0);
    NotePlaintext plain(int v) => NotePlaintext(asset: PoolHash.bsvAsset, d: to.d, value: v, rho: lanes(3), rcm: lanes(4));
    final p1 = plain(value), p2 = plain(0);
    final bundle = [
      ...(await NoteEncryption.encrypt(p1, to, keys.ovk, rng: _rng)).bytes,
      ...(await NoteEncryption.encrypt(p2, to, keys.ovk, rng: _rng)).bytes,
    ];
    SpendNote dummy() => SpendNote.dummy(sk: lanes(5), rho: lanes(3));
    final w = PoolSpendAir.witness(dummy(), dummy(), p1.toOutputNote(to.pkd), p2.toOutputNote(to.pkd), -value,
        outHash: PoolOutHash.transferLanes(PoolOutHash.bundleHash(bundle)), anchor: lanes(8));
    final proof = StarkProver.prove(plan.spendP, PoolSpendAir.air(w.publics), w.rows, rng: _rng, hash: const Poseidon2ProofHash());

    // the covenant, paid from a key made up for it and funded by the node
    final key = SVPrivateKey(networkType: config.network);
    final address = key.publicKey.toAddress(config.network);
    final fundingId = await chain.payFromNode(address, BigInt.from(value + 10000));
    final funding = await _mined(fundingId);
    final vout = funding.outputs.indexWhere((o) => _paysPKH(o, address.pubkeyHash160));
    final issuedOrRound = await chain.fetch(tip?.roundId ?? config.genesis!.issuance);
    if (issuedOrRound == null) throw SimFailure('the node does not have the pool\'s tip transaction');
    final covenant = _svc.createDepositTxn(
        fundingTx: funding,
        fundingVout: vout,
        fundingSigner: DefaultTransactionSigner(FileWallet.sigHashAll, key),
        fundingPubKey: key.publicKey,
        changeAddress: address,
        commitment: lanesToBytes(w.publics.cmOut1),
        satoshis: BigInt.from(value),
        pp3Outpoint: _svc.getOutpoint(issuedOrRound.hash, outputIndex: 3),
        refundPKH: hex.decode(address.pubkeyHash160),
        refundAfter: await chain.height() + 150);
    await chain.broadcast(covenant);
    await _mined(covenant.id);
    final outpoint = _svc.getOutpoint(covenant.hash, outputIndex: ShieldedPoolTool.depositVout);
    return (ShieldedTransfer(w.publics, proof, bundle, depositOutpoint: outpoint), covenant);
  }

  static bool _paysPKH(TransactionOutput o, String pkhHex) {
    final s = o.script.buffer;
    return s.length == 25 && s[0] == 0x76 && s[1] == 0xa9 && hex.encode(s.sublist(3, 23)) == pkhHex;
  }

  Future<Transaction> _mined(String txid) async {
    final chain = node!;
    final start = DateTime.now();
    var told = false;
    while (await chain.minedHeight(txid) == null) {
      if (!told && DateTime.now().difference(start) > const Duration(seconds: 20)) {
        told = true;
        say('waiting for a block to mine $txid (pass --mine-every to mine them here)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return (await chain.fetch(txid))!;
  }

  /// The newest announcement on the coordinator's feed, reading on from
  /// where the last read stopped.
  Future<PoolAnnouncement?> _latest() async {
    final owner = PeerId.fromString(coordinator);
    while (true) {
      final page = await transport.feedOf(owner, _feedNext, limit: 100);
      for (final item in page) {
        final m = PoolMessage.decode(item.content);
        if (m is PoolAnnouncement) _tip = m;
        _feedNext = item.sequence + 1;
      }
      if (page.length < 100) return _tip;
    }
  }

  Future<PoolAnnouncement> _announced(int round) async {
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (true) {
      final tip = await _latest();
      if (tip != null && tip.round >= round) return tip;
      if (DateTime.now().isAfter(deadline)) throw SimFailure('round $round was not announced in 15 minutes');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
}
