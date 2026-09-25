import 'package:tstokenlib/tstokenlib.dart';

import 'wallet.dart';

/// Tells the wallet which of a round's requests the library is making.
///
/// The library asks for a value only (`CoordinatorFunding.output`), in a
/// fixed order: Y's before anything is proved, then the witness's and the
/// round's one after the other once the dry builds are done. It laps the
/// round's timing as it goes, and a fresh timing starts every round, so the
/// laps say where a request falls: before `dry builds`, it is Y's; after,
/// the first is the witness's and the next on the same timing is the
/// round's. Anything else is served as [FundingKind.exact], which suits
/// every request and costs at most a funding fee; Y can never be taken for
/// the round, since its round's timing has no `dry builds` yet. The pin
/// test holds the lap name to the library's.
class FundingRequests {
  static const dryBuilds = 'dry builds';

  final RoundTiming? Function() timing;
  RoundTiming? _last;
  int _afterDryBuilds = 0;

  FundingRequests(this.timing);

  FundingKind next() {
    final t = timing();
    if (t == null || !t.stages.containsKey(dryBuilds)) {
      _last = t;
      _afterDryBuilds = 0;
      return FundingKind.exact;
    }
    if (!identical(t, _last)) {
      _last = t;
      _afterDryBuilds = 0;
    }
    _afterDryBuilds++;
    return _afterDryBuilds == 2 ? FundingKind.round : FundingKind.exact;
  }
}
