import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:tstokenlib/tstokenlib.dart';

import '../round_store.dart';
import '../transport.dart';
import 'metrics_recorder.dart';
import 'round_facts.dart';

/// Fills [recorder]'s history with the stored rounds it lacks (a deleted
/// or replaced file, or rounds from before the API was enabled), from the
/// store's transactions and the headers the feed announced, and hands each
/// rebuilt round to [rebuilt] so its height is asked for. Returns how many
/// rounds it rebuilt.
///
/// The server runs it after ready. Each stored round is read, checked and
/// counted in a short-lived worker isolate: at production that is over a
/// second of parsing and hashing a round (`tool/scratch/metrics_probe.dart
/// start`), which on the server's isolate would hold intake that long. It
/// waits while [building] (the round matters more than the history), stops
/// when [stopping], and yields between rounds.
/// Nothing it meets stops the pool: a failure is logged and the rest of
/// the history is left for the next start.
Future<int> rebuildHistory({
  required MetricsRecorder recorder,
  required RoundStore store,
  required PoolTransport transport,
  required bool Function() building,
  required bool Function() stopping,
  required Duration pause,
  required void Function(int number, String witness) rebuilt,
  Logger? log,
}) async {
  final l = log ?? Logger('metrics');
  var count = 0;
  try {
    final last = await store.lastNumber() ?? 0;
    final have = recorder.recorded();
    final missing = [for (int n = 1; n <= last; n++) if (!have.contains(n)) n];
    if (missing.isEmpty) return 0;
    final sw = Stopwatch()..start();
    l.info('rebuilding the pool history: ${missing.length} rounds');
    final announced = <int, PoolAnnouncement>{};
    final length = await transport.feedLength();
    for (int from = 2; from <= length; from += 100) {
      for (final item in await transport.feed(from, limit: 100)) {
        try {
          final a = PoolMessage.decode(item.content);
          if (a is PoolAnnouncement) announced[a.round] = a;
        } catch (_) {
          // the feed was checked at start; an entry past it that does not
          // decode is not this rebuild's to judge
        }
      }
    }
    for (final n in missing) {
      while (building() && !stopping()) {
        await Future<void>.delayed(pause);
      }
      if (stopping()) return count;
      final a = announced[n];
      if (a == null) {
        l.warning('round $n is stored but not on the feed; the history leaves it out');
        continue;
      }
      final witnessId = a.witnessId;
      final facts = await Isolate.run(() async {
        final r = await store.read(n);
        if (r == null) return null;
        // a store and a feed that disagree are not papered over
        if (r.witness.id != witnessId) return (announced: false, transfers: 0);
        return (announced: true, transfers: realTransfersIn(r.witness));
      });
      if (facts == null) continue;
      if (!facts.announced) {
        l.warning('round $n\'s stored witness is not the one the feed announced; the history leaves it out');
        continue;
      }
      recorder.roundRebuilt(a, facts.transfers);
      rebuilt(n, witnessId);
      count++;
      await Future<void>.delayed(Duration.zero);
    }
    l.info('rebuilt the pool history: $count rounds in ${sw.elapsedMilliseconds} ms');
  } catch (e, st) {
    l.warning('rebuilding the pool history failed; the rounds are unaffected: $e', e, st);
  }
  return count;
}
