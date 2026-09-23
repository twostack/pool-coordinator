import 'dart:async';

import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'metrics_history.dart';
import 'round_facts.dart';
import 'round_stage.dart';

/// A round the coordinator is working on or waiting to see mined.
class LiveRound {
  final int number;
  final RoundStage stage;
  const LiveRound(this.number, this.stage);

  @override
  bool operator ==(Object other) => other is LiveRound && other.number == number && other.stage == stage;
  @override
  int get hashCode => Object.hash(number, stage);
  @override
  String toString() => 'round $number ${stage.name}';
}

/// What the pool is doing now, as the page shows it: whether a round is
/// assembling and when it closes at the latest, and the rounds in flight,
/// oldest first. The deadline is kept at full precision here; the API
/// coarsens every time it serves.
///
/// Deliberately absent: how many transfers are pending. Each change of that
/// count is one submission's arrival time.
class LiveState {
  final bool assembling;
  final DateTime? deadline;
  final List<LiveRound> rounds;
  const LiveState({this.assembling = false, this.deadline, this.rounds = const []});

  static const idle = LiveState();

  @override
  bool operator ==(Object other) =>
      other is LiveState &&
      other.assembling == assembling &&
      other.deadline == deadline &&
      other.rounds.length == rounds.length &&
      Iterable.generate(rounds.length).every((i) => other.rounds[i] == rounds[i]);
  @override
  int get hashCode => Object.hash(assembling, deadline, Object.hashAll(rounds));
  @override
  String toString() => 'assembling ${assembling ? 'until $deadline' : 'no'}; ${rounds.isEmpty ? 'nothing in flight' : rounds.join(', ')}';
}

/// What the public view is read from: the live state, the rounds as they
/// are seen mined, and the history. The recorder is one; the API's own
/// isolate keeps another, fed by messages from the recorder, so the API
/// answers while proving holds the coordinator's isolate.
abstract interface class PublicSource {
  LiveState get live;
  Stream<RoundRecord> get minedRounds;
  MetricsHistory get history;
}

/// The one place the public view of the pool is written: the history of
/// rounds and the live state. Everything the API will ever serve passes
/// through here, so this class is the privacy boundary; it is handed
/// transactions, headers, the library's stage timings and the wallet's
/// cost of a round, and nothing about a submission.
///
/// Every call is guarded: a failure of the history is logged and swallowed,
/// since the server's rounds must never wait on or fail because of it.
class MetricsRecorder implements PublicSource {
  @override
  final MetricsHistory history;
  final int capacity;
  final CoordinatorClock clock;
  final Logger log;

  /// Rounds published and not yet seen mined, by number.
  final _unmined = <int>{};
  LiveRound? _building;

  /// The last round published: a build numbered at or below it is over,
  /// whatever the timing still says, since the library's timing outlives
  /// its round until the next build replaces it.
  int _lastPublished = 0;
  bool _assembling = false;
  DateTime? _deadline;
  LiveState _live = LiveState.idle;

  final _changes = StreamController<LiveState>.broadcast(sync: true);
  final _minedRounds = StreamController<RoundRecord>.broadcast(sync: true);

  MetricsRecorder(this.history, {required this.capacity, required this.clock, Logger? log})
      : log = log ?? Logger('metrics') {
    _guard('reading the unmined rounds', () {
      for (final r in history.unmined()) {
        // a round rebuilt without times was not seen published by any run
        // of this server; it is history, not something in flight
        if (r.publishedAt != null) _unmined.add(r.number);
      }
      _update();
    });
  }

  @override
  LiveState get live => _live;

  /// The live state each time it changes, at full precision.
  Stream<LiveState> get changes => _changes.stream;

  /// Each round's record as it is seen mined.
  @override
  Stream<RoundRecord> get minedRounds => _minedRounds.stream;

  /// Every server tick: whether transfers are pending and the deadline
  /// the library set, the tip round, and, while a round is being built,
  /// the laps its timing holds so far (null when nothing is being built).
  void observe({required bool assembling, DateTime? deadline, required int tipRound, Iterable<String>? laps}) =>
      _guard('observing the live state', () {
        _assembling = assembling;
        _deadline = assembling ? deadline : null;
        if (laps == null) {
          _building = null;
        } else {
          final lapped = laps.toList();
          // the ledger moves to the round at apply
          final n = lapped.contains('apply') ? tipRound : tipRound + 1;
          final stage = stageOf(lapped);
          // never backwards: a tick that reads the timing a moment before
          // its lap would otherwise flicker
          final prior = _building;
          if (n <= _lastPublished) {
            _building = null;
          } else {
            _building = prior != null && prior.number == n && prior.stage.index > stage.index ? prior : LiveRound(n, stage);
          }
        }
        _update();
      });

  /// A round's witness was broadcast and announced: records the round from
  /// its announcement and its [witness], with its durations from the
  /// library's [timing].
  ///
  /// The txids come from the announcement rather than the transactions: a
  /// transaction's id is a hash of its serialization, which for a production
  /// witness of 2.5 MB costs hundreds of milliseconds on the publish path
  /// (measured by `tool/scratch/metrics_probe.dart record`). The witness is
  /// read only for its bundles.
  void roundPublished(PoolAnnouncement a, Transaction witness, RoundTiming? timing) =>
      _guard('recording round ${a.round}', () {
        final number = a.round;
        int? sum(List<String> laps) {
          if (timing == null || !laps.every(timing.stages.containsKey)) return null;
          return laps.fold<int>(0, (a, l) => a + timing.stages[l]!.inMilliseconds);
        }

        history.record(RoundRecord(
          number: number,
          y: a.slotId,
          round: a.roundId,
          witness: a.witnessId,
          transfers: realTransfersIn(witness),
          capacity: capacity,
          balance: a.header.balance.toInt(),
          buildMs: sum(buildLaps),
          provingMs: sum(provingLaps),
          publishedAt: clock.now.toUtc(),
        ));
        _unmined.add(number);
        if (number > _lastPublished) _lastPublished = number;
        if (_building != null && _building!.number <= number) _building = null;
        _update();
      });

  /// A round the store holds and the history does not, rebuilt from its
  /// announcement on the feed and the real [transfers] its stored witness
  /// carries (counted where the rebuild read it, off this isolate). It gets
  /// no times, durations or cost, which only the run that published it
  /// measured, and it never replaces a row that has them.
  void roundRebuilt(PoolAnnouncement a, int transfers) => _guard('rebuilding round ${a.round}', () {
        history.recordIfAbsent(RoundRecord(
          number: a.round,
          y: a.slotId,
          round: a.roundId,
          witness: a.witnessId,
          transfers: transfers,
          capacity: capacity,
          balance: a.header.balance.toInt(),
        ));
      });

  /// The round numbers the history holds, or none when it cannot be read.
  Set<int> recorded() => _read('reading the recorded rounds', () => history.numbers().toSet(), <int>{});

  /// Each round the history does not know to be mined, with its witness's
  /// txid, oldest first.
  List<(int, String)> unminedWitnesses() =>
      _read('reading the unmined rounds', () => [for (final r in history.unmined()) (r.number, r.witness)], const []);

  /// What round [number] cost the wallet, once the wallet has reconciled.
  void costKnown(int number, BigInt cost) => _guard('recording round $number\'s cost', () => history.setCost(number, cost.toInt()));

  /// Round [number]'s witness is mined at [height].
  void mined(int number, int height) => _guard('recording round $number mined', () {
        final r = history.read(number);
        if (r == null) return;
        // only a round this server saw published gets an observation time;
        // a rebuilt one was mined at some time nobody here saw
        history.setMined(number, height, r.publishedAt == null ? null : clock.now.toUtc());
        _unmined.remove(number);
        _update();
        _minedRounds.add(history.read(number)!);
      });

  void _update() {
    final rounds = [
      for (final n in _unmined.toList()..sort())
        if (_building?.number != n) LiveRound(n, RoundStage.broadcast),
      if (_building != null) _building!,
    ]..sort((a, b) => a.number.compareTo(b.number));
    final next = LiveState(assembling: _assembling, deadline: _deadline, rounds: rounds);
    if (next == _live) return;
    _live = next;
    _changes.add(next);
  }

  T _read<T>(String what, T Function() f, T fallback) {
    try {
      return f();
    } catch (e, st) {
      log.warning('the pool history failed $what: $e', e, st);
      return fallback;
    }
  }

  void _guard(String what, void Function() f) {
    try {
      f();
    } catch (e, st) {
      log.warning('the pool history failed $what; the round is unaffected: $e', e, st);
    }
  }

  Future<void> close() async {
    await _changes.close();
    await _minedRounds.close();
    _guard('closing', history.close);
  }
}
