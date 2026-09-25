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

  /// The store of ready coins funding requests are served from.
  final CoinsConfig coins;
  const WalletConfig({required this.file, this.passphraseFile, this.warnRoundsLeft = 5, this.coins = const CoinsConfig()});
}

/// The coin pool's settings (`wallet.coins`): the smallest coin a request
/// is served from, how many ready coins the wallet keeps, the count below
/// which it splits more, and the most outputs one split makes.
class CoinsConfig {
  /// The most outputs one split makes, whatever the configuration says.
  static const maxSplitOutputs = 100;

  final int floor;
  final int target;
  final int lowWater;
  final int splitMaxOutputs;
  const CoinsConfig({this.floor = 10000, this.target = 30, this.lowWater = 12, this.splitMaxOutputs = maxSplitOutputs});
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

  /// Rounds published and not yet mined at which the next round's funding
  /// waits, keeping the pool's unconfirmed chain inside the ancestor limits
  /// of the chain it publishes to.
  final int maxUnminedRounds;

  /// Blocks past a round's publication after which it is broadcast again,
  /// funding first, when it is still unmined.
  final int rebroadcastAfterBlocks;
  const ServerConfig({
    this.pollInterval = const Duration(seconds: 2),
    this.statusFile = 'status.json',
    this.minedPoll = const Duration(seconds: 2),
    this.fundingTimeout = const Duration(hours: 1),
    this.maxUnminedRounds = 10,
    this.rebroadcastAfterBlocks = 3,
  });
}

/// The read-only API a public page reads the pool's history and live state
/// from. It binds to loopback only: the public reach it through a proxy on
/// the same host, which is where TLS, rate limits and the content policy
/// belong, so nothing in this process ever answers the internet directly.
class ApiConfig {
  /// The least publication interval: every time the API serves is rounded
  /// to the interval, and a shorter one would start to time individual
  /// submissions.
  static const minPublishInterval = Duration(seconds: 10);

  final InternetAddress bind;
  final int port;
  final String metricsFile;
  final Duration publishInterval;
  final int maxSubscribers;

  /// What wallets are told to join the pool with, or null when the operator
  /// has not named it.
  final WalletConnect? wallet;
  const ApiConfig({
    required this.bind,
    required this.port,
    required this.metricsFile,
    required this.publishInterval,
    required this.maxSubscribers,
    this.wallet,
  });
}

/// What a wallet needs to join the pool that the coordinator cannot work
/// out for itself: the ricochet server as wallets reach it (the
/// coordinator's own `ricochet.server` may be loopback), chain peers a
/// wallet's header sync can use, and an ARC endpoint that needs no key.
/// Served on `/api/pool` and shown by the page as a command and a config
/// file to paste, so every value is held to a closed grammar here.
class WalletConnect {
  static const maxPeers = 8;

  final String server;
  final List<String> peers;
  final Uri? arcUrl;
  const WalletConnect({required this.server, this.peers = const [], this.arcUrl});

  static final _peerId = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{46,60}$');
  static final _serverShape = RegExp(r'^/(ip4|ip6)/([^/]+)/udp/([0-9]{1,5})/udx/p2p/([^/]+)$');
  static final _ip4 = RegExp(r'^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$');
  static final _ip6 = RegExp(r'^[0-9A-Fa-f:.]{2,45}$');
  static final _hostName = RegExp(r'^(?=.{1,253}$)[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})*$');
  static final _arc = RegExp(r'^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$');

  static bool _port(String p) {
    final n = int.tryParse(p);
    return n != null && n >= 1 && n <= 65535 && p == '$n';
  }

  /// The peer id at the end of [multiaddr], or null.
  static String? peerIdOf(String multiaddr) => RegExp(r'/p2p/([^/]+)$').firstMatch(multiaddr)?.group(1);

  /// Why [s] is not a server address a wallet can dial, or null when it is.
  static String? serverProblem(String s) {
    if (s.startsWith('/dns')) return '"$s" is a name; wallets dial only /ip4 or /ip6 addresses';
    final m = _serverShape.firstMatch(s);
    if (m == null) return '"$s" is not /ip4|/ip6/<address>/udp/<port>/udx/p2p/<peer id>';
    final ok = m.group(1) == 'ip4' ? _ip4.hasMatch(m.group(2)!) : _ip6.hasMatch(m.group(2)!) && m.group(2)!.contains(':');
    if (!ok) return '"${m.group(2)}" is not an ${m.group(1)} address';
    if (!_port(m.group(3)!)) return '${m.group(3)} is not a port';
    if (!_peerId.hasMatch(m.group(4)!)) return '"${m.group(4)}" is not a peer id';
    return null;
  }

  /// Why [s] is not `host:port`, or null when it is.
  static String? peerProblem(String s) {
    final i = s.lastIndexOf(':');
    if (i < 1) return '"$s" is not host:port';
    final host = s.substring(0, i), port = s.substring(i + 1);
    if (!_ip4.hasMatch(host) && !_hostName.hasMatch(host)) return '"$host" is not an IPv4 address or host name';
    if (!_port(port)) return '"$port" is not a port';
    return null;
  }

  /// Why [s] is not an ARC URL to hand a wallet, or null when it is.
  static String? arcProblem(String s) => _arc.hasMatch(s) ? null : '"$s" is not an https URL of plain characters';
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

  /// The read-only API, or null when the configuration has no enabled
  /// `api:` section; a configuration from before the API runs as it did.
  final ApiConfig? api;

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
    this.api,
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
    var coins = const CoinsConfig();
    if (w.has('coins')) {
      final co = w.section('coins');
      coins = CoinsConfig(
        floor: co.integer('floor', 10000),
        target: co.integer('target', 30),
        lowWater: co.integer('low_water', 12),
        splitMaxOutputs: co.integer('split_max_outputs', CoinsConfig.maxSplitOutputs),
      );
      co.done();
      if (coins.floor < 1) throw ConfigError('wallet.coins.floor', 'must be at least 1 satoshi');
      if (coins.target < 1) throw ConfigError('wallet.coins.target', 'must be at least 1 coin');
      if (coins.lowWater < 0 || coins.lowWater > coins.target) {
        throw ConfigError('wallet.coins.low_water', 'is ${coins.lowWater}; it is from 0 to the target, ${coins.target}');
      }
      if (coins.splitMaxOutputs < 2 || coins.splitMaxOutputs > CoinsConfig.maxSplitOutputs) {
        throw ConfigError('wallet.coins.split_max_outputs', 'is ${coins.splitMaxOutputs}; it is from 2 to ${CoinsConfig.maxSplitOutputs}');
      }
    }
    final wallet = WalletConfig(
        file: path(w.string('file')),
        passphraseFile: w.optionalString('passphrase_file')?.let(path),
        warnRoundsLeft: w.integer('warn_rounds_left', 5),
        coins: coins);
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
        maxUnminedRounds: sv.integer('max_unmined_rounds', 10),
        rebroadcastAfterBlocks: sv.integer('rebroadcast_after_blocks', 3),
      );
      if (server.maxUnminedRounds < 1) throw ConfigError('server.max_unmined_rounds', 'must be at least 1');
      if (server.rebroadcastAfterBlocks < 1) throw ConfigError('server.rebroadcast_after_blocks', 'must be at least 1');
      sv.done();
    } else {
      server = ServerConfig(statusFile: path('status.json'));
    }
    ApiConfig? api;
    if (root.has('api')) {
      final a = root.section('api');
      final enabled = a.boolean('enabled', false);
      final bindText = a.string('bind', '127.0.0.1');
      final bind = InternetAddress.tryParse(bindText);
      if (bind == null || !bind.isLoopback) {
        throw ConfigError('api.bind', '"$bindText" is not a loopback address; the API is reached through a proxy on this host');
      }
      // 0 lets the system pick a free port, which the tests use
      final port = a.integer('port', 8787);
      if (port < 0 || port > 65535) throw ConfigError('api.port', '$port is not a port');
      final metricsFile = path(a.string('metrics_file', 'metrics.sqlite'));
      final interval = Duration(seconds: a.integer('publish_interval_seconds', 30));
      if (interval < ApiConfig.minPublishInterval) {
        throw ConfigError('api.publish_interval_seconds',
            'is ${interval.inSeconds}; the least is ${ApiConfig.minPublishInterval.inSeconds}, so no time served times one submission');
      }
      final maxSubscribers = a.integer('max_subscribers', 200);
      if (maxSubscribers < 1) throw ConfigError('api.max_subscribers', 'must be at least 1');
      WalletConnect? walletConnect;
      if (a.has('wallet')) {
        if (!enabled) throw ConfigError('api.wallet', 'is set while the API is disabled, so no wallet would be told');
        walletConnect = _walletConnect(a.section('wallet'), ricochet.server);
      }
      a.done();
      if (enabled) {
        api = ApiConfig(
            bind: bind,
            port: port,
            metricsFile: metricsFile,
            publishInterval: interval,
            maxSubscribers: maxSubscribers,
            wallet: walletConnect);
      }
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
        server: server,
        api: api);
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

WalletConnect _walletConnect(_Section wc, String ricochetServer) {
  final server = wc.string('server');
  final problem = WalletConnect.serverProblem(server);
  if (problem != null) throw ConfigError('api.wallet.server', problem);
  final ours = WalletConnect.peerIdOf(ricochetServer);
  if (WalletConnect.peerIdOf(server) != ours) {
    throw ConfigError('api.wallet.server', 'names peer ${WalletConnect.peerIdOf(server)}, and ricochet.server is $ours');
  }
  final peers = wc.stringList('peers');
  if (peers.length > WalletConnect.maxPeers) {
    throw ConfigError('api.wallet.peers', 'names ${peers.length}; the most is ${WalletConnect.maxPeers}');
  }
  for (final p in peers) {
    final why = WalletConnect.peerProblem(p);
    if (why != null) throw ConfigError('api.wallet.peers', why);
  }
  final arc = wc.optionalString('arc_url');
  if (arc != null) {
    final why = WalletConnect.arcProblem(arc);
    if (why != null) throw ConfigError('api.wallet.arc_url', why);
  }
  wc.done();
  return WalletConnect(server: server, peers: peers, arcUrl: arc == null ? null : Uri.parse(arc));
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

  /// A list of values, empty when absent.
  List<String> stringList(String key) {
    final v = _take(key);
    if (v == null) return const [];
    if (v is! YamlList) throw ConfigError(_path(key), 'is not a list');
    return [
      for (final x in v)
        if (x is String || x is num) '$x' else throw ConfigError(_path(key), 'holds something that is not a value')
    ];
  }

  bool boolean(String key, bool fallback) {
    final v = _take(key);
    if (v == null) return fallback;
    if (v is! bool) throw ConfigError(_path(key), 'is not true or false');
    return v;
  }

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
