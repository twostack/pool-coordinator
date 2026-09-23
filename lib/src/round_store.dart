import 'dart:typed_data';

import 'package:dartsv/dartsv.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// A stored round the server will not run on: a file cut short, a record
/// of a version this server does not write, or a transaction that is not
/// the one the record names. The round and the file are named so an
/// operator knows what to look at.
class StoreRefusal implements Exception {
  final int round;
  final String file;
  final String reason;
  const StoreRefusal(this.round, this.file, this.reason);
  @override
  String toString() => 'round $round, $file: $reason';
}

/// One round as the store holds it: the three transactions, and the
/// ledger's snapshot after them when it has not been pruned.
class StoredRound {
  final int number;
  final Transaction y, round, witness;
  final Uint8List? snapshot;
  const StoredRound(this.number, this.y, this.round, this.witness, this.snapshot);

  ShieldedRoundTxs get triple => (round: round, witness: witness, nextSlot: y);
}

/// The on-disk record of every round the coordinator built, written before
/// the first publish, as the library's store interface requires, and read
/// back at start. [roundBuilt] is the library's call; the rest is what
/// recovery needs: the last round's number, and any round by number.
abstract class RoundStore implements CoordinatorStore {
  /// The highest round number stored, or null when the store is empty.
  Future<int?> lastNumber();

  /// Round [number], or null when the store has no such round. Throws
  /// [StoreRefusal] when the round is there but cannot be trusted.
  Future<StoredRound?> read(int number);

  /// The last round, or null when the store is empty.
  Future<StoredRound?> last() async {
    final n = await lastNumber();
    return n == null ? null : read(n);
  }
}
