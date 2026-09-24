/// A disposable pool on localnet, in one command: a ricochet server, a pool
/// created and funded from the node's wallet, the coordinator running it
/// with the public API on, blocks mined every few seconds, and, with
/// `--sim`, wallets submitting rounds. Ctrl-C stops everything and removes
/// what it made.
///
///   dart run tool/localnet_pool.dart --sim
///   cd web && npm run dev        # the page, at http://localhost:5173
///
/// Needs ../localnet up (the node and its PostgreSQL) and the ricochet
/// server built (see README.md). Run it from the repository's root: the
/// coordinator finds the native kernels and the ricochet binary from there.
///
/// The pool is a fresh one every time: its feed lives in a ricochet
/// database made for this run and dropped at the end, so a kept folder
/// (`--keep`) is for reading the logs and the history afterwards, not for
/// running the same pool again.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';

import '../test/support/ricochet_server.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('dir', help: 'the pool\'s folder (default: a fresh temporary one)')
    ..addFlag('keep', negatable: false, help: 'keep the pool\'s folder, with its logs and history, when stopped')
    ..addOption('api-port', defaultsTo: '8787', help: 'the API\'s loopback port')
    ..addOption('interval', defaultsTo: '10', help: 'the API\'s publication interval in seconds (at least 10)')
    ..addOption('mine-every', defaultsTo: '2', help: 'mine a block every this many seconds, 0 for never')
    ..addFlag('sim', negatable: false, help: 'also run tool/wallet_sim.dart against the pool')
    ..addOption('sim-every', defaultsTo: '30', help: 'with --sim, seconds between rounds')
    ..addOption('deposits', defaultsTo: '1', help: 'with --sim, deposits a round')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exit(64);
  }
  if (args['help'] as bool) {
    stdout.writeln('dart run tool/localnet_pool.dart [options]\n\n${parser.usage}');
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

  final launcher = Launcher(
    dir: args['dir'] as String?,
    keep: args['keep'] as bool,
    apiPort: number('api-port', min: 1),
    interval: number('interval', min: 10),
    mineEvery: number('mine-every'),
    sim: args['sim'] as bool,
    simEvery: number('sim-every'),
    deposits: number('deposits'),
  );
  var stopping = false;
  Future<void> stop(int code) async {
    if (stopping) return;
    stopping = true;
    say('stopping');
    await launcher.stop();
    exit(code);
  }

  for (final s in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    s.watch().listen((_) => stop(0));
  }
  try {
    await launcher.start(onExit: (what) {
      say('$what; stopping');
      unawaited(stop(1));
    });
  } on LaunchFailure catch (e) {
    stderr.writeln('localnet_pool: $e');
    await stop(1);
  }
}

void say(String line) => stdout.writeln('${DateTime.now().toIso8601String().substring(11, 19)}  $line');

class LaunchFailure implements Exception {
  final String message;
  LaunchFailure(this.message);
  @override
  String toString() => message;
}

class Launcher {
  final String? dir;
  final bool keep;
  final int apiPort, interval, mineEvery, simEvery, deposits;
  final bool sim;

  final _env = Platform.environment;
  late final Uri _rpcUrl = Uri.parse(_env['LOCALNET_RPC'] ?? 'http://localhost:18332');
  late final String _rpcPassword = _env[Secrets.rpcPasswordVar] ?? 'bitcoin';
  // the pool's wallet file is encrypted under this; the pool lives as long
  // as this run, so the passphrase is made up here and never shown
  final String _passphrase = base64Url.encode(List.generate(24, (_) => Random.secure().nextInt(256)));

  RicochetTestServer? _ricochet;
  NodeChain? _node;
  Timer? _miner;
  Process? _coordinator, _sim;
  Directory? _dir;

  Launcher({
    required this.dir,
    required this.keep,
    required this.apiPort,
    required this.interval,
    required this.mineEvery,
    required this.sim,
    required this.simEvery,
    required this.deposits,
  });

  Future<void> start({required void Function(String what) onExit}) async {
    if (!File('bin/pool_coordinator.dart').existsSync()) throw LaunchFailure('run this from the pool-coordinator repository\'s root');
    final node = _node = NodeChain(rpcUrl: _rpcUrl, user: 'bitcoin', password: _rpcPassword, timeout: const Duration(seconds: 120));
    try {
      await node.height();
    } catch (e) {
      throw LaunchFailure('no localnet node at $_rpcUrl ($e); start ../localnet');
    }
    final unavailable = await RicochetTestServer.available();
    if (unavailable != null) throw LaunchFailure(unavailable);
    if (await _answers(apiPort)) throw LaunchFailure('something already answers on 127.0.0.1:$apiPort; pass --api-port');

    final d = _dir = dir == null ? Directory.systemTemp.createTempSync('localnet-pool') : (Directory(dir!)..createSync(recursive: true));
    if (File('${d.path}/config.yaml').existsSync()) throw LaunchFailure('${d.path} already holds a pool; name an empty folder');

    say('starting a ricochet server');
    final ricochet = _ricochet = (await RicochetTestServer.start())!;
    final configPath = '${d.path}/config.yaml';
    File(configPath).writeAsStringSync(_config(ricochet.address));

    // blocks from the start: create waits for its funding and genesis
    if (mineEvery > 0) _miner = Timer.periodic(Duration(seconds: mineEvery), (_) => node.generate(1).catchError((_) {}));
    final creating = _miner == null ? Timer.periodic(const Duration(seconds: 1), (_) => node.generate(1).catchError((_) {})) : null;
    say('creating the pool in ${d.path}');
    final config = await PoolConfig.load(configPath);
    final created = await PoolCreator(
      config: config,
      configPath: configPath,
      secrets: Secrets(walletPassphrase: _passphrase, rpcPassword: _rpcPassword),
      chain: node,
      connect: (seed) => RicochetTransport.connect(seed: seed, server: ricochet.address),
      pollInterval: const Duration(milliseconds: 500),
      kdf: KdfParams.light,
      say: (line) {
        final m = RegExp(r'^fund (\S+) with at least (\d+) satoshis').firstMatch(line);
        if (m != null) {
          // the operator's payment, from the node's wallet, with room for
          // a couple of hundred rounds
          unawaited(node.payFromNode(Address.fromBase58(m.group(1)!), BigInt.parse(m.group(2)!) + BigInt.from(1000000)));
        }
      },
    ).run();
    creating?.cancel();
    say('pool created: issuance ${created.issuance.id}');

    say('starting the coordinator (log: ${d.path}/coordinator.log)');
    final log = File('${d.path}/coordinator.log').openWrite();
    final coordinator = _coordinator = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/pool_coordinator.dart', '-c', configPath, 'run'],
      environment: {Secrets.passphraseVar: _passphrase, Secrets.rpcPasswordVar: _rpcPassword},
    );
    coordinator.stdout.listen(log.add);
    coordinator.stderr.listen(log.add);
    unawaited(coordinator.exitCode.then((code) async {
      await log.flush();
      if (_coordinator != null) onExit('the coordinator exited with $code; see ${d.path}/coordinator.log');
    }));
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (!await _answers(apiPort)) {
      if (_coordinator == null) return;
      if (DateTime.now().isAfter(deadline)) throw LaunchFailure('the API did not answer within 2 minutes; see ${d.path}/coordinator.log');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    say('the API is at http://127.0.0.1:$apiPort/api/pool');

    final simCommand = 'POOL_RPC_PASSWORD=$_rpcPassword dart run tool/wallet_sim.dart -c $configPath';
    if (sim) {
      say('starting the wallets (log: ${d.path}/wallets.log)');
      final simLog = File('${d.path}/wallets.log').openWrite();
      final p = _sim = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'tool/wallet_sim.dart', '-c', configPath, '--every', '$simEvery', '--deposits', '$deposits'],
        environment: {Secrets.rpcPasswordVar: _rpcPassword},
      );
      // the simulator's own lines here, everything under it in its log
      final ours = RegExp(r'^\d\d:\d\d:\d\d  ');
      void watch(Stream<List<int>> s) => s.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
            simLog.writeln(line);
            if (ours.hasMatch(line)) stdout.writeln('${line.substring(0, 10)}wallets: ${line.substring(10)}');
            if (line.startsWith('wallet_sim:')) stdout.writeln(line);
          });
      watch(p.stdout);
      watch(p.stderr);
      unawaited(p.exitCode.then((code) {
        if (_sim != null) say('the wallets stopped (exit $code); the pool runs on. Restart them with:\n  $simCommand');
        _sim = null;
      }));
    }

    stdout.writeln('''

The pool is up${mineEvery > 0 ? ', mining a block every $mineEvery s' : ''}.
  the page:     cd web && npm run dev, then http://localhost:5173
  the API:      curl http://127.0.0.1:$apiPort/api/rounds
${sim ? '' : '  rounds:       $simCommand\n'}  Ctrl-C stops everything${keep || dir != null ? '' : ' and removes ${d.path}'}.
''');
  }

  String _config(String ricochetAddress) => '''
# A disposable localnet pool, written by tool/localnet_pool.dart.
plan: test
network: test
chain:
  kind: node
  rpc_url: $_rpcUrl
  rpc_user: bitcoin
ricochet:
  server: $ricochetAddress
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
  mined_poll_ms: 500
  funding_timeout_seconds: 600
api:
  enabled: true
  port: $apiPort
  publish_interval_seconds: $interval
''';

  static Future<bool> _answers(int port) async {
    try {
      final s = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 500));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Stops the wallets, then the coordinator (which closes its API and
  /// history), then the miner and the ricochet server, and removes the
  /// temporary folder.
  Future<void> stop() async {
    // detached first, so their exits read as asked for rather than as a
    // failure (a Ctrl-C in a terminal reaches them as well as this process)
    final children = [_sim, _coordinator];
    _sim = null;
    _coordinator = null;
    for (final p in children) {
      if (p == null) continue;
      p.kill(ProcessSignal.sigterm);
      await p.exitCode.timeout(const Duration(seconds: 20), onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
    _miner?.cancel();
    await _ricochet?.dispose();
    _node?.close();
    final d = _dir;
    if (d != null && dir == null && !keep) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    } else if (d != null) {
      say('the pool\'s folder is kept: ${d.path}');
    }
  }
}
