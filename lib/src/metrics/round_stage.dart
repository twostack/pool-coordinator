/// The stage of a round being worked on, as the public page names it. The
/// library's own stages are finer and are the coordinator's business; these
/// three are what a reader of the page can tell apart and what the chain
/// will eventually show.
enum RoundStage {
  /// From close until the aggregation's root unlock is built: deposits
  /// still being admitted, expiry, the funding for Y, padding, the trees and the proving itself.
  proving,

  /// Building Y, the round and the witness at their priced fees, applying
  /// them to the coordinator's ledger and storing them.
  funding,

  /// From the first publish until the witness is mined.
  broadcast,
}

/// The library laps a round's `RoundTiming` after each of its stages, in
/// this order of first appearance (a stage lapped twice, as funding is,
/// keeps its first place, since the timing is a map). A round is in the
/// public stage of the work that follows its last lap.
///
/// The names are the library's, read rather than hooked, so the pin test
/// runs a real round and fails if the library's order ever differs from
/// this one.
const libraryLaps = [
  'admission',
  'expiry',
  'funding',
  'padding',
  'trees',
  'aggregation',
  'root unlock',
  'Y',
  'dry builds',
  'round',
  'witness',
  'apply',
  'store',
  'publish',
];

/// The public stage of the work after each lap: after `root unlock` the
/// round is being built and funded, after `store` it is being published.
const stageAfter = {
  'admission': RoundStage.proving,
  'expiry': RoundStage.proving,
  'funding': RoundStage.proving,
  'padding': RoundStage.proving,
  'trees': RoundStage.proving,
  'aggregation': RoundStage.proving,
  'root unlock': RoundStage.funding,
  'Y': RoundStage.funding,
  'dry builds': RoundStage.funding,
  'round': RoundStage.funding,
  'witness': RoundStage.funding,
  'apply': RoundStage.funding,
  'store': RoundStage.broadcast,
  'publish': RoundStage.broadcast,
};

/// The stage a round is in, given the laps its timing holds so far in the
/// order they were first lapped. Nothing lapped yet is proving. A lap this
/// table does not know is skipped, so a renamed stage can only hold the
/// stage back, never move it backwards; the pin test is what notices.
RoundStage stageOf(Iterable<String> lapped) {
  var stage = RoundStage.proving;
  for (final lap in lapped) {
    final s = stageAfter[lap];
    if (s != null && s.index > stage.index) stage = s;
  }
  return stage;
}

/// The laps whose sum is a round's proving time: the work over a full
/// round of transfers, real or padding, so it does not vary with how many
/// are real.
const provingLaps = ['trees', 'aggregation', 'root unlock'];

/// The laps from close to stored, whose sum is the build time.
const buildLaps = [
  'admission',
  'expiry',
  'funding',
  'padding',
  'trees',
  'aggregation',
  'root unlock',
  'Y',
  'dry builds',
  'round',
  'witness',
  'apply',
  'store',
];
