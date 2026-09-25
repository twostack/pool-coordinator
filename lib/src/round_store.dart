import 'dart:typed_data';

import 'package:convert/convert.dart';
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

/// One round as the store holds it: the three transactions, the funding
/// transactions they spend that the wallet built (empty for a round stored
/// before record version 2), and the ledger's snapshot after them when it
/// has not been pruned.
class StoredRound {
  final int number;
  final Transaction y, round, witness;
  final Uint8List? snapshot;
  final List<Transaction> funding;
  const StoredRound(this.number, this.y, this.round, this.witness, this.snapshot, {this.funding = const []});

  ShieldedRoundTxs get triple => (round: round, witness: witness, nextSlot: y);
}

/// The on-disk record of every round the coordinator built, written before
/// the first publish, as the library's store interface requires, and read
/// back at start. [roundBuilt] is the library's call; the rest is what
/// recovery needs: the last round's number, and any round by number.
abstract class RoundStore implements CoordinatorStore {
  /// Stores round [number] as [roundBuilt] does, with [funding]: the
  /// transactions Y, the round and the witness spend that the wallet built
  /// and the chain may not have mined, so they can be broadcast again
  /// before the round. The server calls it through [FundedStore].
  Future<void> roundBuiltWith(int number, Transaction y, Transaction round, Transaction witness, Uint8List snapshot,
      {List<Transaction> funding = const []});

  @override
  Future<void> roundBuilt(int number, Transaction y, Transaction round, Transaction witness, Uint8List snapshot) =>
      roundBuiltWith(number, y, round, witness, snapshot);

  /// The highest round number stored, or null when the store is empty.
  Future<int?> lastNumber();

  /// Round [number], or null when the store has no such round. Throws
  /// [StoreRefusal] when the round is there but cannot be trusted.
  Future<StoredRound?> read(int number);

  /// Round [number]'s round and witness txids, or null when the store has
  /// no such round. Cheaper than [read] where the store keeps a record.
  Future<({String round, String witness})?> txidsOf(int number) async {
    final r = await read(number);
    return r == null ? null : (round: r.round.id, witness: r.witness.id);
  }

  /// Round [number]'s round and witness transactions as bytes, as a wallet
  /// is sent them, or null when the store has no such round. Cheaper than
  /// [read] where the store keeps the raw bytes: a production witness is
  /// megabytes, and parsing one holds the server's isolate for about a
  /// second.
  Future<({Uint8List round, Uint8List witness})?> rawOf(int number) async {
    final r = await read(number);
    return r == null
        ? null
        : (round: Uint8List.fromList(hex.decode(r.round.serialize())), witness: Uint8List.fromList(hex.decode(r.witness.serialize())));
  }

  /// The last round, or null when the store is empty.
  Future<StoredRound?> last() async {
    final n = await lastNumber();
    return n == null ? null : read(n);
  }
}

/// The store as the library sees it, with each round's funding asked of
/// the wallet and stored beside it. Kept apart from the store itself so
/// the store holds no closure over the wallet: a store is read in a worker
/// isolate, and a wallet cannot be sent to one.
class FundedStore implements CoordinatorStore {
  final RoundStore store;
  final List<Transaction> Function(List<Transaction> spenders) fundingOf;
  FundedStore(this.store, this.fundingOf);

  @override
  Future<void> roundBuilt(int number, Transaction y, Transaction round, Transaction witness, Uint8List snapshot) =>
      store.roundBuiltWith(number, y, round, witness, snapshot, funding: fundingOf([y, round, witness]));
}
