import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../config.dart';
import '../metrics/metrics_history.dart';
import '../metrics/metrics_recorder.dart';
import 'publication_gate.dart';

/// The pool's public facts that never change while it runs, which the API
/// serves beside the history: all of them are in the pool's descriptor or
/// its configuration's public half.
class PoolFacts {
  final NetworkType network;
  final String plan;
  final int capacity;
  final String issuance, witness0, slot0;
  final Duration roundDeadline;

  /// Which public explorer holds the pool's transactions: `main`, `test`,
  /// or null for a chain no explorer sees (a regtest node), so the page
  /// links to the chain only where the link resolves. The page builds the
  /// link itself from this name, never from a URL it is served.
  final String? explorer;

  /// What a wallet needs to join the pool, or null when the operator has
  /// not named it (`api.wallet`).
  final WalletFacts? wallet;
  const PoolFacts({
    required this.network,
    required this.plan,
    required this.capacity,
    required this.issuance,
    required this.witness0,
    required this.slot0,
    required this.roundDeadline,
    this.explorer,
    this.wallet,
  });
}

/// What `/api/pool` tells a wallet: the values `cloak init` and a wallet's
/// `config.yaml` take, with the network named as cloak names it.
class WalletFacts {
  final String network;
  final String server;
  final String coordinator;
  final List<String> peers;
  final String? arcUrl;
  const WalletFacts({required this.network, required this.server, required this.coordinator, this.peers = const [], this.arcUrl});

  Map<String, Object?> toJson() =>
      {'network': network, 'server': server, 'coordinator': coordinator, 'peers': peers, 'arcUrl': arcUrl};
}

/// The read-only HTTP view of the pool: the summary, pages of rounds, the
/// statistics, time series, and the live state as server-sent events.
///
/// It answers from the history and the publication gate only, never from
/// the chain, the store or the ledger, so a request costs a SQLite read at
/// most and can never wait on or change a round. Every request is hostile:
/// only GET and HEAD, a bounded request line, every parameter checked for
/// type and range, every answer JSON. Every time it serves is rounded to
/// the publication interval.
class PoolApi {
  /// Response versions: fields are only added within one.
  static const version = 1;
  static const maxRequestLine = 2048;
  static const defaultLimit = 20;
  static const maxRoundsBuffered = 64;

  final PoolFacts facts;
  final PublicSource source;
  final PublicationGate gate;
  final int maxSubscribers;
  final Duration heartbeat;
  final Logger log;
  final HttpServer _server;
  final _subscribers = <_Subscriber>{};
  StreamSubscription<GateEvent>? _gateSub;
  Timer? _heartbeat;

  PoolApi._(this.facts, this.source, this.gate, this.maxSubscribers, this.heartbeat, this.log, this._server);

  Duration get interval => gate.interval;

  /// The port bound, which a configured port of 0 leaves to the system.
  int get port => _server.port;

  int get subscribers => _subscribers.length;

  /// Binds [config]'s loopback address and starts answering.
  static Future<PoolApi> start({
    required ApiConfig config,
    required PoolFacts facts,
    required PublicSource source,
    required PublicationGate gate,
    Duration heartbeat = const Duration(seconds: 15),
    Logger? log,
  }) async {
    late final PoolApi api;
    // an explicit backlog: the system's default can be small, and a burst
    // of page loads should queue rather than be reset
    final server = await HttpServer.bind(config.bind, config.port, backlog: 128);
    server.serverHeader = null;
    server.listen((request) {
      // shelf cannot build a request whose target is not a path (`*`, a bare
      // fragment) and answers such a one with its own plain 500; it is the
      // client's error, so it gets the API's 400
      if (!request.uri.path.startsWith('/')) {
        request.response
          ..statusCode = 400
          ..headers.contentType = ContentType.json
          ..headers.set('cache-control', 'no-store')
          ..write(jsonEncode({'v': version, 'error': 'the request target is not a path'}));
        unawaited(request.response.close().catchError((_) {}));
        return;
      }
      shelf_io.handleRequest(request, api._handle, poweredByHeader: null);
    });
    api = PoolApi._(facts, source, gate, config.maxSubscribers, heartbeat, log ?? Logger('api'), server);
    api._gateSub = gate.events.listen(api._broadcast);
    api._heartbeat = Timer.periodic(heartbeat, (_) => api._send(': heartbeat\n\n', live: false, heartbeat: true));
    return api;
  }

  Future<void> close() async {
    _heartbeat?.cancel();
    await _gateSub?.cancel();
    for (final s in [..._subscribers]) {
      await s.close();
    }
    _subscribers.clear();
    await _server.close(force: true);
  }

  // ---------------------------------------------------------------- routing

  FutureOr<Response> _handle(Request request) {
    try {
      if (request.requestedUri.toString().length > maxRequestLine) {
        return _error(414, 'the request line is over $maxRequestLine bytes');
      }
      final method = request.method;
      if (method != 'GET' && method != 'HEAD') {
        return _error(405, 'this API only reads; $method is not allowed', headers: {'allow': 'GET, HEAD'});
      }
      final Response response = switch (request.url.path) {
        'api/pool' => _pool(),
        'api/rounds' => _rounds(request.url.queryParameters),
        'api/stats' => _stats(),
        'api/series' => _series(request.url.queryParameters),
        'api/events' => method == 'HEAD' ? _json(200, const {'v': version}) : _events(),
        _ => _error(404, 'no such route'),
      };
      return method == 'HEAD' ? Response(response.statusCode, headers: response.headers) : response;
    } on _BadRequest catch (e) {
      return _error(400, e.message);
    } catch (e, st) {
      log.warning('the API failed a request: $e', e, st);
      return _error(500, 'the request could not be answered');
    }
  }

  static const _jsonType = 'application/json; charset=utf-8';

  Response _json(int status, Map<String, Object?> body, {String cache = 'no-store', Map<String, String> headers = const {}}) =>
      Response(status,
          body: jsonEncode({'v': version, ...body}),
          headers: {'content-type': _jsonType, 'cache-control': cache, 'x-content-type-options': 'nosniff', ...headers});

  Response _error(int status, String message, {Map<String, String> headers = const {}}) =>
      _json(status, {'error': message}, headers: headers);

  int? _time(DateTime? t) => t == null ? null : floorTo(t.toUtc(), interval).millisecondsSinceEpoch ~/ 1000;

  Map<String, Object?> _live(LiveState s, DateTime at) => {
        'at': _time(at),
        'assembling': s.assembling,
        // already rounded up to the interval by the gate
        'closesBy': s.deadline == null ? null : s.deadline!.millisecondsSinceEpoch ~/ 1000,
        'rounds': [
          for (final r in s.rounds) {'number': r.number, 'stage': r.stage.name},
        ],
      };

  Map<String, Object?> _round(RoundRecord r) => {
        'number': r.number,
        'y': r.y,
        'round': r.round,
        'witness': r.witness,
        'transfers': r.transfers,
        'capacity': r.capacity,
        'balance': r.balance,
        'cost': r.cost,
        'buildMs': r.buildMs,
        'provingMs': r.provingMs,
        'publishedAt': _time(r.publishedAt),
        'minedHeight': r.minedHeight,
        'minedAt': _time(r.minedAt),
      };

  // ----------------------------------------------------------------- routes

  Response _pool() {
    final tip = source.history.page(limit: 1);
    return _json(200, {
      'network': facts.network == NetworkType.MAIN ? 'main' : 'test',
      'plan': facts.plan,
      'capacity': facts.capacity,
      'explorer': facts.explorer,
      'genesis': {'issuance': facts.issuance, 'witness0': facts.witness0, 'slot0': facts.slot0},
      'tip': tip.isEmpty ? 0 : tip.single.number,
      'balance': tip.isEmpty ? null : tip.single.balance,
      'roundDeadlineSeconds': facts.roundDeadline.inSeconds,
      'publishIntervalSeconds': interval.inSeconds,
      'live': _live(gate.published, gate.publishedAt),
      'wallet': facts.wallet?.toJson(),
    });
  }

  Response _rounds(Map<String, String> q) {
    _only(q, const {'before', 'limit'});
    final before = _int(q, 'before', min: 1);
    final limit = _int(q, 'limit', min: 1, max: MetricsHistory.maxPage) ?? defaultLimit;
    final rows = source.history.page(before: before, limit: limit);
    final next = rows.isNotEmpty && rows.last.number > 1 ? rows.last.number : null;
    // a page below a given round whose rounds are all mined never changes
    final settled = before != null && rows.every((r) => r.mined);
    return _json(200, {'rounds': [for (final r in rows) _round(r)], 'next': next},
        cache: settled ? 'public, max-age=31536000, immutable' : 'no-store');
  }

  Response _stats() {
    final s = source.history.stats();
    return _json(200, {
      'roundsMined': s.roundsMined,
      'transfers': s.transfers,
      'tip': s.tip ?? 0,
      'medianIntervalSeconds': s.medianInterval == null ? null : s.medianInterval!.inMilliseconds / 1000,
      'medianProvingSeconds': s.medianProving == null ? null : s.medianProving!.inMilliseconds / 1000,
      'meanCost': s.meanCost,
      'firstPublishedAt': _time(s.firstPublished),
    });
  }

  Response _series(Map<String, String> q) {
    _only(q, const {'metric', 'bucket', 'from', 'to'});
    final metric = _enum(q, 'metric', SeriesMetric.values);
    final bucket = _enum(q, 'bucket', SeriesBucket.values);
    if (metric == null) throw const _BadRequest('metric is required');
    final b = bucket ?? SeriesBucket.hour;
    // seconds since the epoch; the range defaults to the last 1,000 buckets
    final toS = _int(q, 'to', min: 0, max: 1 << 40);
    final fromS = _int(q, 'from', min: 0, max: 1 << 40);
    final to = toS == null ? DateTime.now().toUtc() : DateTime.fromMillisecondsSinceEpoch(toS * 1000, isUtc: true);
    final from = fromS == null ? to.subtract(b.width * MetricsHistory.maxPoints) : DateTime.fromMillisecondsSinceEpoch(fromS * 1000, isUtc: true);
    if (!from.isBefore(to)) throw const _BadRequest('from must be before to');
    final points = source.history.series(metric, b, from: from, to: to);
    return _json(200, {
      'metric': metric.name,
      'bucket': b.name,
      'points': [
        for (final pt in points) {'t': _time(pt.at), 'value': pt.value},
      ],
    });
  }

  // ------------------------------------------------------------- parameters

  static void _only(Map<String, String> q, Set<String> known) {
    for (final k in q.keys) {
      if (!known.contains(k)) throw _BadRequest('$k is not a parameter of this route');
    }
  }

  static int? _int(Map<String, String> q, String name, {required int min, int? max}) {
    final s = q[name];
    if (s == null) return null;
    if (s.length > 15 || !RegExp(r'^[0-9]+$').hasMatch(s)) throw _BadRequest('$name is not a whole number');
    final v = int.parse(s);
    if (v < min || (max != null && v > max)) throw _BadRequest('$name must be between $min and ${max ?? 'any'}');
    return v;
  }

  static T? _enum<T extends Enum>(Map<String, String> q, String name, List<T> values) {
    final s = q[name];
    if (s == null) return null;
    for (final v in values) {
      if (v.name == s) return v;
    }
    throw _BadRequest('$name is not one of ${values.map((v) => v.name).join(', ')}');
  }

  // ----------------------------------------------------------------- events

  Response _events() {
    if (_subscribers.length >= maxSubscribers) {
      return _error(503, 'the event stream has its most subscribers; try again later', headers: {'retry-after': '30'});
    }
    late final _Subscriber sub;
    sub = _Subscriber(onGone: () => _subscribers.remove(sub));
    _subscribers.add(sub);
    sub.send(_frame('live', _live(gate.published, gate.publishedAt)), live: true);
    return Response.ok(sub.stream, headers: {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store',
      'x-accel-buffering': 'no',
      'x-content-type-options': 'nosniff',
    }, context: {
      'shelf.io.buffer_output': false
    });
  }

  static String _frame(String event, Map<String, Object?> data) => 'event: $event\ndata: ${jsonEncode({'v': version, ...data})}\n\n';

  void _broadcast(GateEvent e) {
    switch (e) {
      case LiveEvent(:final state, :final at):
        _send(_frame('live', _live(state, at)), live: true);
      case RoundEvent(:final round):
        _send(_frame('round', {'round': _round(round)}), live: false);
    }
  }

  void _send(String frame, {required bool live, bool heartbeat = false}) {
    for (final s in [..._subscribers]) {
      s.send(frame, live: live, heartbeat: heartbeat);
    }
  }
}

class _BadRequest implements Exception {
  final String message;
  const _BadRequest(this.message);
}

/// One event-stream client. While the connection cannot keep up (the
/// response stream is paused) only the latest live state is kept, and up
/// to [PoolApi.maxRoundsBuffered] round events; a client further behind
/// than that is dropped, and reconnects to a fresh snapshot.
class _Subscriber {
  final void Function() onGone;
  late final StreamController<List<int>> _out;
  bool _paused = false, _closed = false;
  String? _pendingLive;
  final _pendingRounds = Queue<String>();

  _Subscriber({required this.onGone}) {
    _out = StreamController<List<int>>(
      // what was sent before the server started reading (the snapshot)
      onListen: _flush,
      onPause: () => _paused = true,
      onResume: _flush,
      onCancel: close,
    );
  }

  Stream<List<int>> get stream => _out.stream;

  void send(String frame, {required bool live, bool heartbeat = false}) {
    if (_closed) return;
    if (!_paused && _out.hasListener) {
      _out.add(utf8.encode(frame));
      return;
    }
    if (heartbeat) return;
    if (live) {
      _pendingLive = frame;
    } else {
      _pendingRounds.add(frame);
      if (_pendingRounds.length > PoolApi.maxRoundsBuffered) unawaited(close());
    }
  }

  void _flush() {
    _paused = false;
    while (_pendingRounds.isNotEmpty && !_paused) {
      _out.add(utf8.encode(_pendingRounds.removeFirst()));
    }
    final l = _pendingLive;
    if (l != null && !_paused) {
      _pendingLive = null;
      _out.add(utf8.encode(l));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onGone();
    // not awaited: a controller nobody listened to never reports done
    unawaited(_out.close());
  }
}
