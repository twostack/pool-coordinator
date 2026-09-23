import 'dart:async';

import 'package:tstokenlib/tstokenlib.dart' show CoordinatorAlarm, CoordinatorClock;

import '../metrics/metrics_history.dart';
import '../metrics/metrics_recorder.dart';

/// [t] rounded down to a multiple of [q] since the epoch.
DateTime floorTo(DateTime t, Duration q) {
  final ms = t.millisecondsSinceEpoch, qm = q.inMilliseconds;
  return DateTime.fromMillisecondsSinceEpoch(ms - ms % qm, isUtc: true);
}

/// [t] rounded up to a multiple of [q] since the epoch.
DateTime ceilTo(DateTime t, Duration q) {
  final f = floorTo(t, q);
  return f.isAtSameMomentAs(t) ? f : f.add(q);
}

/// Something the gate lets out: the live state, or a round seen mined.
sealed class GateEvent {}

class LiveEvent extends GateEvent {
  final LiveState state;

  /// The tick that published it, a multiple of the interval.
  final DateTime at;
  LiveEvent(this.state, this.at);
}

class RoundEvent extends GateEvent {
  final RoundRecord round;
  RoundEvent(this.round);
}

/// What the public sees of the live state, and when: the source's state
/// read on a fixed tick, every [interval] on the multiples of it, with the
/// deadline rounded up to it, and let out only when it differs from the
/// last published. Rounds seen mined wait for the same tick.
///
/// So nothing the API serves changes more often than the interval or
/// carries a time finer than it, and the moment a round opened (its first
/// transfer's arrival) is known to the public only to the interval, which
/// is coarser than the chain's own timing of the round it ends up in.
class PublicationGate {
  final PublicSource source;
  final Duration interval;
  final CoordinatorClock clock;

  late LiveState _published;
  late DateTime _publishedAt;
  final _mined = <RoundRecord>[];
  CoordinatorAlarm? _alarm;
  StreamSubscription<RoundRecord>? _sub;
  final _events = StreamController<GateEvent>.broadcast(sync: true);
  bool _closed = false;

  PublicationGate(this.source, {required this.interval, required this.clock}) {
    _published = coarse(source.live);
    _publishedAt = floorTo(clock.now, interval);
    _sub = source.minedRounds.listen(_mined.add);
    _schedule();
  }

  /// The live state as last let out, and the tick that let it out.
  LiveState get published => _published;
  DateTime get publishedAt => _publishedAt;

  Stream<GateEvent> get events => _events.stream;

  /// [s] with its deadline rounded up to the interval.
  LiveState coarse(LiveState s) => LiveState(
        assembling: s.assembling,
        deadline: s.deadline == null ? null : ceilTo(s.deadline!.toUtc(), interval),
        rounds: s.rounds,
      );

  void _schedule() {
    if (_closed) return;
    final now = clock.now;
    var next = ceilTo(now, interval);
    if (!next.isAfter(now)) next = next.add(interval);
    _alarm = clock.after(next.difference(now), _tick);
  }

  void _tick() {
    if (_closed) return;
    final at = floorTo(clock.now, interval);
    // the rounds first, so a reader sees a round mined before the live
    // state that no longer has it in flight
    for (final r in _mined) {
      _events.add(RoundEvent(r));
    }
    _mined.clear();
    final next = coarse(source.live);
    if (next != _published) {
      _published = next;
      _publishedAt = at;
      _events.add(LiveEvent(next, at));
    }
    _schedule();
  }

  Future<void> close() async {
    _closed = true;
    _alarm?.cancel();
    await _sub?.cancel();
    await _events.close();
  }
}
