import 'package:tstokenlib/src/script_gen/pool_spend_air.dart' show PoolSpendAir;
import 'package:tstokenlib/tstokenlib.dart';

/// The two aggregation plans a configuration can name. The plan is the one
/// thing a coordinator and its pool must agree on (the library checks the
/// plan builds the pool's own verifier), so it is named rather than
/// spelled out: a wrong plan is refused by the library, a mistyped
/// parameter would build a pool nobody else can read.
///
/// `production` is the library's 256-transfer throughput plan with
/// nullifiers and 8 receipt slots, as the pool runs it. `test` is the
/// 4-transfer plan at test-size parameters the library's fixture and
/// localnet harness prove under, whose transactions fit ARC's parse limit.
PoolAggregation planNamed(String name) {
  switch (name) {
    case 'production':
      return PoolAggregation.throughput(nullifiers: true, receiptSlots: PoolReceipt.maxPerRound);
    case 'test':
      return testPlan();
    default:
      throw ArgumentError('plan "$name" is not one of test, production');
  }
}

/// Test-size parameters, as tstokenlib's `pool_verifier_proof_test` fixes
/// them; the fixture's transfers decode only at these.
const testSpendParams = StarkParams(
    logTrace: PoolSpendAir.logTrace, logBlowup: 2, logExpand: 3, logFinal: 3, numQueries: 2, grindBytes: 1, zkRandomizers: 16);
const testLevel1Params = StarkParams(logTrace: 15, logBlowup: 2, logExpand: 3, logFinal: 3, numQueries: 2, grindBytes: 1);
const testLevel2Params = StarkParams(logTrace: 17, logBlowup: 2, logExpand: 3, logFinal: 3, numQueries: 2, grindBytes: 1);
const testRootParams = StarkParams(logTrace: 15, logBlowup: 2, logExpand: 3, logFinal: 3, numQueries: 2, grindBytes: 1);

PoolAggregation testPlan() => PoolAggregation(
    spendP: testSpendParams,
    levelSpec: const [
      AggregationLevel(params: testLevel1Params, logTrace: 15, arity: 2),
      AggregationLevel(params: testLevel2Params, logTrace: 17, arity: 2),
    ],
    rootP: testRootParams,
    rootLog: 15,
    nullifierLevel: 1,
    receiptSlots: 2);
