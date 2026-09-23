import 'dart:io';

import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A configuration the server refuses to run on: a field missing, a field
/// it does not know, or a value of the wrong shape. The field is named
/// with its full path so an operator can find it.
class ConfigError implements Exception {
  final String field;
  final String reason;
  const ConfigError(this.field, this.reason);
  @override
  String toString() => 'configuration field "$field": $reason';
}

enum ChainKind { node, testnet }

class ChainConfig {
  final ChainKind kind;

  /// The node's RPC endpoint and user; the password is a secret.
  final Uri? rpcUrl;
  final String? rpcUser;
  final String? rpcPasswordFile;

  /// ARC and WhatsOnChain for testnet.
  final Uri? arcUrl;
  final Uri? wocUrl;

  /// ARC's parse limit on one scriptSig, measured on localnet.
  final int arcScriptSigLimit;
  final Duration timeout;
  final int retries;

  const ChainConfig({
    required this.kind,
    this.rpcUrl,
    this.rpcUser,
    this.rpcPasswordFile,
    this.arcUrl,
    this.wocUrl,
    this.arcScriptSigLimit = 1636802,
    this.timeout = const Duration(seconds: 30),
    this.retries = 3,
  });
}

class RicochetConfig {
  /// The server's multiaddr with its peer id, as `/ip4/.../udp/.../udx/p2p/...`.
  final String server;
  final String identityFile;
  final int sendRetries;
  const RicochetConfig({required this.server, required this.identityFile, this.sendRetries = 3});
}

class WalletConfig {
  final String file;
  final String? passphraseFile;

  /// Below this many rounds left, the server logs a warning.
  final int warnRoundsLeft;
  const WalletConfig({required this.file, this.passphraseFile, this.warnRoundsLeft = 5});
}

class StoreConfig {
  final String directory;

  /// Snapshots kept; every round's transactions are kept regardless.
  final int keepSnapshots;
  const StoreConfig({required this.directory, this.keepSnapshots = 10});
}

class GenesisConfig {
  final String issuance, witness0, slot0;
  const GenesisConfig({required this.issuance, required this.witness0, required this.slot0});
}

class RoundConfig {
  final int feeRate, feeFloor;
  final Duration deadline;
  final int paddingStock, depositMargin;
  const RoundConfig({
    required this.feeRate,
    required this.feeFloor,
    required this.deadline,
    required this.paddingStock,
    required this.depositMargin,
  });
}

class ServerConfig {
  /// How often the inbox is drained.
  final Duration pollInterval;
  final String statusFile;

  /// How often the chain is asked whether a transaction is mined, and how
  /// long a funding output is waited for.
  final Duration minedPoll;
  final Duration fundingTimeout;
  const ServerConfig({
    this.pollInterval = const Duration(seconds: 2),
    this.statusFile = 'status.json',
    this.minedPoll = const Duration(seconds: 2),
    this.fundingTimeout = const Duration(hours: 1),
  });
}

/// The server's configuration: one YAML file, with the secrets elsewhere.
///
/// Every field the server needs is required and named when missing, and
/// a field the server does not know is refused rather than ignored, since
/// a misspelt `fee_rate` that silently took the default would price every
/// round wrong. Paths are resolved against the file's directory, so a
/// config can be copied with its wallet and store beside it.
class PoolConfig {
  final String plan;
  final NetworkType network;
  final ChainConfig chain;
  final RicochetConfig ricochet;
  final WalletConfig wallet;
  final StoreConfig store;
  final GenesisConfig? genesis;
  final RoundConfig round;
  final ServerConfig server;

  const PoolConfig({
    required this.plan,
    required this.network,
    required this.chain,
    required this.ricochet,
    required this.wallet,
    required this.store,
    required this.genesis,
    required this.round,
    required this.server,
  });

  static const planNames = ['test', 'production'];

  static Future<PoolConfig> load(String path) async {
    final file = File(path);
    if (!file.existsSync()) throw ConfigError('', 'no configuration file at $path');
    return parse(await file.readAsString(), baseDir: p.dirname(p.absolute(path)));
  }

  /// Parses [text]. Relative paths resolve against [baseDir] when given.
  static PoolConfig parse(String text, {String? baseDir}) {
    final dynamic doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw ConfigError('', 'not YAML: ${e.message}');
    }
    if (doc is! YamlMap) throw ConfigError('', 'the file is not a map of fields');
    final root = _Section('', doc);
    String path(String s) => baseDir == null || p.isAbsolute(s) ? s : p.join(baseDir, s);

    final plan = root.string('plan');
    if (!planNames.contains(plan)) throw ConfigError('plan', '"$plan" is not one of ${planNames.join(', ')}');
    final networkName = root.string('network');
    final network = switch (networkName) {
      'test' => NetworkType.TEST,
      'main' => NetworkType.MAIN,
      _ => throw ConfigError('network', '"$networkName" is not one of test, main'),
    };

    final c = root.section('chain');
    final kindName = c.string('kind');
    final kind = switch (kindName) {
      'node' => ChainKind.node,
      'testnet' => ChainKind.testnet,
      _ => throw ConfigError('chain.kind', '"$kindName" is not one of node, testnet'),
    };
    final chain = ChainConfig(
      kind: kind,
      rpcUrl: kind == ChainKind.node ? c.uri('rpc_url') : c.optionalUri('rpc_url'),
      rpcUser: kind == ChainKind.node ? c.string('rpc_user') : c.optionalString('rpc_user'),
      rpcPasswordFile: c.optionalString('rpc_password_file')?.let(path),
      arcUrl: kind == ChainKind.testnet ? c.uri('arc_url') : c.optionalUri('arc_url'),
      wocUrl: kind == ChainKind.testnet ? c.uri('woc_url') : c.optionalUri('woc_url'),
      arcScriptSigLimit: c.integer('arc_scriptsig_limit', 1636802),
      timeout: Duration(seconds: c.integer('timeout_seconds', 30)),
      retries: c.integer('retries', 3),
    );
    c.done();

    final r = root.section('ricochet');
    final ricochet = RicochetConfig(
        server: r.string('server'), identityFile: path(r.string('identity_file')), sendRetries: r.integer('send_retries', 3));
    r.done();

    final w = root.section('wallet');
    final wallet = WalletConfig(
        file: path(w.string('file')),
        passphraseFile: w.optionalString('passphrase_file')?.let(path),
        warnRoundsLeft: w.integer('warn_rounds_left', 5));
    w.done();

    final s = root.section('store');
    final store = StoreConfig(directory: path(s.string('directory')), keepSnapshots: s.integer('keep_snapshots', 10));
    s.done();

    GenesisConfig? genesis;
    if (root.has('genesis')) {
      final g = root.section('genesis');
      genesis = GenesisConfig(issuance: g.txid('issuance'), witness0: g.txid('witness0'), slot0: g.txid('slot0'));
      g.done();
    }

    final ro = root.section('round');
    final round = RoundConfig(
      feeRate: ro.integer('fee_rate'),
      feeFloor: ro.integer('fee_floor'),
      deadline: Duration(seconds: ro.integer('deadline_seconds')),
      paddingStock: ro.integer('padding_stock'),
      depositMargin: ro.integer('deposit_margin'),
    );
    ro.done();

    var server = const ServerConfig();
    if (root.has('server')) {
      final sv = root.section('server');
      server = ServerConfig(
        pollInterval: Duration(milliseconds: sv.integer('poll_ms', 2000)),
        statusFile: path(sv.string('status_file', 'status.json')),
        minedPoll: Duration(milliseconds: sv.integer('mined_poll_ms', 2000)),
        fundingTimeout: Duration(seconds: sv.integer('funding_timeout_seconds', 3600)),
      );
      sv.done();
    } else {
      server = ServerConfig(statusFile: path('status.json'));
    }
    root.done();

    return PoolConfig(
        plan: plan,
        network: network,
        chain: chain,
        ricochet: ricochet,
        wallet: wallet,
        store: store,
        genesis: genesis,
        round: round,
        server: server);
  }
}

/// The secrets the configuration never holds: where each is found is in
/// the config, the value in the environment or a file only the operator
/// wrote.
class Secrets {
  static const passphraseVar = 'POOL_WALLET_PASSPHRASE';
  static const rpcPasswordVar = 'POOL_RPC_PASSWORD';

  final String walletPassphrase;
  final String? rpcPassword;
  const Secrets({required this.walletPassphrase, this.rpcPassword});

  /// The wallet passphrase from [passphraseVar] or the configured file, and
  /// the RPC password from [rpcPasswordVar] or its file when the chain is a
  /// node. A missing secret names where it was looked for.
  static Secrets load(PoolConfig config, {Map<String, String>? env}) {
    final e = env ?? Platform.environment;
    final passphrase = _secret(e, passphraseVar, config.wallet.passphraseFile, 'wallet.passphrase_file');
    String? rpc;
    if (config.chain.kind == ChainKind.node) {
      rpc = _secret(e, rpcPasswordVar, config.chain.rpcPasswordFile, 'chain.rpc_password_file');
    }
    return Secrets(walletPassphrase: passphrase, rpcPassword: rpc);
  }

  static String _secret(Map<String, String> env, String variable, String? file, String fileField) {
    final v = env[variable];
    if (v != null && v.isNotEmpty) return v;
    if (file != null) {
      final f = File(file);
      if (!f.existsSync()) throw ConfigError(fileField, 'the secret file $file does not exist');
      final s = f.readAsStringSync().trim();
      if (s.isEmpty) throw ConfigError(fileField, 'the secret file $file is empty');
      return s;
    }
    throw ConfigError(fileField, 'set $variable in the environment or name a file in $fileField');
  }
}

/// One map of the file, reading fields by name and refusing what is left.
class _Section {
  final String prefix;
  final YamlMap map;
  final _read = <String>{};
  _Section(this.prefix, this.map);

  String _path(String key) => prefix.isEmpty ? key : '$prefix.$key';

  bool has(String key) => map.containsKey(key);

  dynamic _take(String key) {
    _read.add(key);
    return map[key];
  }

  String string(String key, [String? fallback]) {
    final v = _take(key);
    if (v == null) {
      if (fallback != null) return fallback;
      throw ConfigError(_path(key), 'missing');
    }
    if (v is! String && v is! num && v is! bool) throw ConfigError(_path(key), 'is not a value');
    return '$v';
  }

  String? optionalString(String key) => has(key) ? string(key) : null;

  int integer(String key, [int? fallback]) {
    final v = _take(key);
    if (v == null) {
      if (fallback != null) return fallback;
      throw ConfigError(_path(key), 'missing');
    }
    if (v is! int) throw ConfigError(_path(key), 'is not a whole number');
    return v;
  }

  Uri uri(String key) {
    final s = string(key);
    final u = Uri.tryParse(s);
    if (u == null || !u.hasScheme) throw ConfigError(_path(key), '"$s" is not a URL');
    return u;
  }

  Uri? optionalUri(String key) => has(key) ? uri(key) : null;

  String txid(String key) {
    final s = string(key);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(s)) throw ConfigError(_path(key), '"$s" is not a 64-digit hex txid');
    return s;
  }

  _Section section(String key) {
    final v = _take(key);
    if (v == null) {
      // a section written with no fields is a section whose fields are
      // missing, and naming the first of them helps more than naming it
      if (has(key)) return _Section(_path(key), YamlMap());
      throw ConfigError(_path(key), 'missing');
    }
    if (v is! YamlMap) throw ConfigError(_path(key), 'is not a map of fields');
    return _Section(_path(key), v);
  }

  /// Refuses any field this section did not read.
  void done() {
    for (final k in map.keys) {
      if (!_read.contains(k)) throw ConfigError(_path('$k'), 'unknown field');
    }
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
