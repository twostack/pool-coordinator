import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:logging/logging.dart';
import 'package:pool_coordinator/pool_coordinator.dart';

/// The coordinator's commands: `create` issues a pool from the wallet's
/// coins and writes its descriptor, `run` runs it, and `check` reports what
/// an installed copy can do without needing a configuration.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config', abbr: 'c', help: 'The configuration file.', defaultsTo: 'config.yaml')
    ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Log at fine level.')
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('version', negatable: false, help: 'Print the version.');
  parser.addCommand('create');
  parser.addCommand('run');
  parser.addCommand('check');
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _usage(parser);
    exit(64);
  }
  final command = args.command?.name;
  if (args['version'] as bool) {
    stdout.writeln('pool-coordinator $poolVersion');
    exit(0);
  }
  if (command == 'check') {
    final (:ok, :lines) = installCheck();
    lines.forEach(stdout.writeln);
    exit(ok ? 0 : 69);
  }
  if (args['help'] as bool || command == null) {
    _usage(parser);
    exit(command == null ? 64 : 0);
  }
  Logger.root.level = args['verbose'] as bool ? Level.FINE : Level.INFO;
  Logger.root.onRecord.listen((r) {
    // the transport stack's own loggers are chatty at info; the server's are named
    if (!const {'server', 'wallet', 'create', 'ricochet'}.contains(r.loggerName) && r.level < Level.WARNING) return;
    stderr.writeln('${r.time.toUtc().toIso8601String()} ${r.level.name.toLowerCase()} ${r.loggerName}: ${r.message}');
  });

  final configPath = args['config'] as String;
  try {
    final config = await PoolConfig.load(configPath);
    final secrets = Secrets.load(config);
    final chain = _chain(config, secrets);
    switch (command) {
      case 'create':
        await PoolCreator(
          config: config,
          configPath: configPath,
          secrets: secrets,
          chain: chain,
          connect: (seed) => RicochetTransport.connect(seed: seed, server: config.ricochet.server, sendRetries: config.ricochet.sendRetries),
        ).run();
      case 'run':
        await _run(config, secrets, chain);
    }
  } on ConfigError catch (e) {
    stderr.writeln('$e');
    exit(78);
  } on CreateRefusal catch (e) {
    stderr.writeln('$e');
    exit(70);
  } on StartRefusal catch (e) {
    stderr.writeln('$e');
    exit(70);
  } on WalletFileError catch (e) {
    stderr.writeln('$e');
    exit(70);
  } on IdentityError catch (e) {
    stderr.writeln('$e');
    exit(70);
  }
  exit(0);
}

ChainAccess _chain(PoolConfig config, Secrets secrets) {
  final c = config.chain;
  switch (c.kind) {
    case ChainKind.node:
      return NodeChain(rpcUrl: c.rpcUrl!, user: c.rpcUser!, password: secrets.rpcPassword!, timeout: c.timeout, retries: c.retries);
    case ChainKind.testnet:
      return TestnetChain(arcUrl: c.arcUrl!, wocUrl: c.wocUrl!, scriptSigLimit: c.arcScriptSigLimit, timeout: c.timeout, retries: c.retries);
  }
}

Future<void> _run(PoolConfig config, Secrets secrets, ChainAccess chain) async {
  final (file, contents) = await WalletFile.open(config.wallet.file, secrets.walletPassphrase);
  final wallet = FileWallet(
      file: file,
      contents: contents,
      chain: chain,
      feeRate: config.round.feeRate,
      feeFloor: config.round.feeFloor,
      minedPoll: config.server.minedPoll,
      fundingTimeout: config.server.fundingTimeout,
      coins: config.wallet.coins);
  final seed = await IdentityFile.read(config.ricochet.identityFile);
  final transport = await RicochetTransport.connect(
      seed: seed, server: config.ricochet.server, sendRetries: config.ricochet.sendRetries, batch: 100);
  final store = FileRoundStore(config.store.directory, keepSnapshots: config.store.keepSnapshots);
  final server = await PoolServer.start(config: config, wallet: wallet, store: store, chain: chain, transport: transport);
  final stopped = Completer<void>();
  void onSignal(ProcessSignal s) {
    if (stopped.isCompleted) return;
    Logger('server').info('received $s');
    server.stop().then((_) => stopped.complete());
  }

  final subs = [ProcessSignal.sigint.watch().listen(onSignal), ProcessSignal.sigterm.watch().listen(onSignal)];
  await stopped.future;
  for (final s in subs) {
    await s.cancel();
  }
}

void _usage(ArgParser parser) {
  stderr.writeln('usage: pool-coordinator [--config <file>] <create|run|check>');
  stderr.writeln(parser.usage);
}
