/// The keys and funding transactions tstokenlib's pool tests share
/// (`pool_round_v_test.dart`), copied so this package's tests build the
/// same chain the library's do. The keys are test vectors of the library,
/// not anyone's coins.
library;

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';

final opKey = SVPrivateKey.fromWIF('cStLVGeWx7fVYKKDXYWVeEbEcPZEC4TD73DjQpHCks2Y8EAjVDSS');
final strangerKey = SVPrivateKey.fromWIF('cRHYFwjjw2Xn2gjxdGw6RRgKJZqipZx7j8i64NdwzxcD6SezEZV5');
const opPKH = '650c4adb156f19e36a755c820d892cda108299c4';
final sigHashAll = SighashType.SIGHASH_FORKID.value | SighashType.SIGHASH_ALL.value;
final fundingA = Transaction.fromHex(
    '0200000001cf5ae107ead0a5117ea2124aacb61d0d700de05a937ed3e48c9245bfab19dd8c000000004847304402206edac55dd4f791a611e05a6d946862ca45d914d0cdf391bfd982399c3d84ea4602205a196505d536b3646834051793acd5d9e820249979c94d0a4252298d0ffe9a7041feffffff0200196bee000000001976a914da217dfa3513d4224802556228d07b278af36b0388ac00ca9a3b000000001976a914650c4adb156f19e36a755c820d892cda108299c488ac65000000');
final fundingB = Transaction.fromHex(
    '0300000001cf5ae107ead0a5117ea2124aacb61d0d700de05a937ed3e48c9245bfab19dd8c000000004847304402206edac55dd4f791a611e05a6d946862ca45d914d0cdf391bfd982399c3d84ea4602205a196505d536b3646834051793acd5d9e820249979c94d0a4252298d0ffe9a7041feffffff0200196bee000000001976a914da217dfa3513d4224802556228d07b278af36b0388ac00ca9a3b000000001976a914650c4adb156f19e36a755c820d892cda108299c488ac65000000');
TransactionInput slotFunding(int n) => TransactionInput(hex.encode(List.filled(32, n)), 0, 0xffffffff);
