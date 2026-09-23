import 'package:dartsv/dartsv.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// How many of a round's transfers are real, read from its witness the way
/// any chain reader can: every transfer's ciphertext bundle is pushed in
/// the unlock of the witness's PP1 input, and padding carries an empty one
/// (the ledger refuses an empty bundle on a transfer that is not padding).
///
/// Counting from the published witness rather than from anything the
/// coordinator knows privately is the point: the number the page shows is
/// one the chain already shows, so publishing it tells nobody anything new.
/// It also means the live path and a rebuild from the store agree by
/// construction.
///
/// Throws [FormatException] when the witness is not a round witness.
int realTransfersIn(Transaction witness) {
  if (witness.inputs.length < 2) throw const FormatException('a round witness spends PP1 at input 1, and this one has no input 1');
  final unlock = witness.inputs[1].script?.buffer;
  if (unlock == null) throw const FormatException('the witness\'s input 1 has no unlock');
  final bundles = PP1SpUnlockBuilder.readRound(unlock)['bundles'];
  if (bundles == null) throw const FormatException('the witness\'s unlock carries no bundles');
  return PoolOutHash.decodeBundles(bundles).where((b) => b.isNotEmpty).length;
}
