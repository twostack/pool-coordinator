import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:tstokenlib/tstokenlib.dart' show SystemClock;

import '../config.dart';
import '../metrics/metrics_history.dart';
import '../metrics/metrics_recorder.dart';
import 'pool_api.dart';
import 'publication_gate.dart';

/// The API in an isolate of its own.
///
/// Proving a round runs on the coordinator's isolate and holds it for
/// seconds at test parameters and far longer at production; an API there
/// would stop answering, and stop sending heartbeats, for every round. Here
/// it keeps answering from its own connection to the history and from the
/// live state the recorder sends it. The live state cannot change while the
/// coordinator's isolate is held anyway: the recorder is what changes it.
///
/// Only messages cross: the live state when it changes, each round as it
/// is seen mined, and the API's log records coming back.
class ApiHost {
  final Isolate _isolate;
  final SendPort _toApi;
  final ReceivePort _fromApi;
  final int port;
  final List<StreamSubscription<Object>> _subs;
  final Completer<void> _closed;

  ApiHost._(this._isolate, this._toApi, this._fromApi, this.port, this._subs, this._closed);

  /// Starts the API over [recorder]'s history and live state. Throws when
  /// it cannot bind or open the history, having stopped the isolate.
  static Future<ApiHost> start({
    required ApiConfig config,
    required PoolFacts facts,
    required MetricsRecorder recorder,
    Duration heartbeat = const Duration(seconds: 15),
  }) async {
    final fromApi = ReceivePort();
    final hello = Completer<SendPort>(), ready = Completer<int>(), closed = Completer<void>();
    fromApi.listen((m) {
      switch (m) {
        case ('hello', SendPort p):
          hello.complete(p);
        case ('ready', int port):
          ready.complete(port);
        case ('failed', String why):
          ready.completeError(StateError(why));
        case ('log', int level, String name, String message):
          Logger(name).log(Level.LEVELS.firstWhere((l) => l.value == level, orElse: () => Level.INFO), message);
        case ('closed',):
          if (!closed.isCompleted) closed.complete();
      }
    });
    final isolate = await Isolate.spawn(
      _main,
      _Start(
        fromApi.sendPort,
        bind: config.bind.address,
        port: config.port,
        metricsFile: config.metricsFile,
        publishInterval: config.publishInterval,
        maxSubscribers: config.maxSubscribers,
        facts: facts,
        live: recorder.live,
        heartbeat: heartbeat,
      ),
      debugName: 'pool-api',
      errorsAreFatal: false,
    );
    final toApi = await hello.future;
    // what changes from here on; the state at start went with the spawn
    final subs = <StreamSubscription<Object>>[
      recorder.changes.listen((s) => toApi.send(('live', s))),
      recorder.minedRounds.listen((r) => toApi.send(('mined', r))),
    ];
    try {
      final port = await ready.future;
      return ApiHost._(isolate, toApi, fromApi, port, subs, closed);
    } catch (_) {
      for (final s in subs) {
        await s.cancel();
      }
      isolate.kill(priority: Isolate.immediate);
      fromApi.close();
      rethrow;
    }
  }

  /// Stops answering, closes the API's connection to the history, and ends
  /// the isolate.
  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _toApi.send(('stop',));
    await _closed.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    _isolate.kill(priority: Isolate.immediate);
    _fromApi.close();
  }
}

class _Start {
  final SendPort toHost;
  final String bind;
  final int port;
  final String metricsFile;
  final Duration publishInterval, heartbeat;
  final int maxSubscribers;
  final PoolFacts facts;
  final LiveState live;
  _Start(this.toHost,
      {required this.bind,
      required this.port,
      required this.metricsFile,
      required this.publishInterval,
      required this.maxSubscribers,
      required this.facts,
      required this.live,
      required this.heartbeat});
}

/// The live state and mined rounds as the host's messages bring them, over
/// this isolate's own connection to the history.
class _Relayed implements PublicSource {
  @override
  final MetricsHistory history;
  @override
  LiveState live;
  final _mined = StreamController<RoundRecord>.broadcast(sync: true);
  _Relayed(this.history, this.live);
  @override
  Stream<RoundRecord> get minedRounds => _mined.stream;
}

Future<void> _main(_Start start) async {
  final toHost = start.toHost;
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) => toHost.send(('log', r.level.value, r.loggerName, r.error == null ? r.message : '${r.message} (${r.error})')));
  final inbox = ReceivePort();
  toHost.send(('hello', inbox.sendPort));
  MetricsHistory? history;
  PublicationGate? gate;
  PoolApi? api;
  _Relayed? source;
  try {
    history = MetricsHistory.attach(start.metricsFile);
    source = _Relayed(history, start.live);
    gate = PublicationGate(source, interval: start.publishInterval, clock: const SystemClock());
    api = await PoolApi.start(
      config: ApiConfig(
        bind: InternetAddress(start.bind),
        port: start.port,
        metricsFile: start.metricsFile,
        publishInterval: start.publishInterval,
        maxSubscribers: start.maxSubscribers,
      ),
      facts: start.facts,
      source: source,
      gate: gate,
      heartbeat: start.heartbeat,
    );
    toHost.send(('ready', api.port));
  } catch (e) {
    await gate?.close();
    history?.close();
    toHost.send(('failed', '$e'));
    inbox.close();
    return;
  }
  await for (final m in inbox) {
    switch (m) {
      case ('live', LiveState s):
        source.live = s;
      case ('mined', RoundRecord r):
        source._mined.add(r);
      case ('stop',):
        await api.close();
        await gate.close();
        history.close();
        toHost.send(('closed',));
        inbox.close();
    }
  }
}
