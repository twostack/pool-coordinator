import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// Which request the library is making, from its round's laps: Y before
/// the dry builds, then the witness, then the round (coin-pool, "Serving a
/// request from the store").
void main() {
  test('Y, the witness, the round, round after round, and a round that failed after Y', () {
    RoundTiming? t;
    final kinds = FundingRequests(() => t);
    final seen = <FundingKind>[];

    // round 1: Y, then the dry builds, then the witness and the round
    t = RoundTiming()..lap('expiry');
    seen.add(kinds.next());
    t.lap('funding');
    t.lap(FundingRequests.dryBuilds);
    seen.add(kinds.next());
    seen.add(kinds.next());
    expect(seen, [FundingKind.exact, FundingKind.exact, FundingKind.round]);

    // round 2 fails after Y is funded; round 3 starts on a fresh timing
    t = RoundTiming()..lap('expiry');
    expect(kinds.next(), FundingKind.exact);
    t = RoundTiming()..lap('expiry');
    expect(kinds.next(), FundingKind.exact, reason: 'Y is never taken for the round');
    t.lap(FundingRequests.dryBuilds);
    expect(kinds.next(), FundingKind.exact, reason: 'the witness');
    expect(kinds.next(), FundingKind.round);
    expect(kinds.next(), FundingKind.exact, reason: 'a fourth request on one timing is served exact');
  });

  test('no timing, as before the first round or in create, is served exact', () {
    expect(FundingRequests(() => null).next(), FundingKind.exact);
  });
}
