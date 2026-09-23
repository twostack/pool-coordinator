/// The keys and funding transactions of the library's test chain, under
/// the names this package's tests use. They are test vectors of the
/// library (`PoolTestKeys`), not anyone's coins.
library;

import 'package:dartsv/dartsv.dart';
import 'package:tstokenlib/testing.dart';

final opKey = PoolTestKeys.op;
final strangerKey = PoolTestKeys.stranger;
const opPKH = PoolTestKeys.opPKH;
final sigHashAll = PoolTestKeys.sigHashAll;
final fundingA = PoolTestKeys.fundingA;
final fundingB = PoolTestKeys.fundingB;
TransactionInput slotFunding(int n) => PoolTestKeys.slotFunding(n);
