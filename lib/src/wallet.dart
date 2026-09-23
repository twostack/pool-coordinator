import 'package:dartsv/dartsv.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// The wallet could not fund a request: the balance did not cover it, or
/// the chain refused the funding transaction. The library turns it into a
/// round failure at the funding stage, and the status carries the sentence.
class WalletRefusal implements Exception {
  final String reason;
  const WalletRefusal(this.reason);
  @override
  String toString() => reason;
}

/// What an operator reads about the wallet: what it holds, what the last
/// round cost, and how many more it can pay for at that cost.
class WalletReport {
  final BigInt balance;
  final BigInt? lastRoundCost;
  final int? roundsLeft;
  final int coins;
  final int offered;
  const WalletReport({
    required this.balance,
    required this.lastRoundCost,
    required this.roundsLeft,
    required this.coins,
    required this.offered,
  });

  Map<String, dynamic> toJson() => {
        'balance': balance.toString(),
        'lastRoundCost': lastRoundCost?.toString(),
        'roundsLeft': roundsLeft,
        'coins': coins,
        'offered': offered,
      };

  @override
  String toString() => 'balance $balance sat, last round ${lastRoundCost ?? '?'} sat, rounds left ${roundsLeft ?? '?'}';
}

/// The coordinator's wallet: the library's funding interface, plus what a
/// server needs around it. The owner key is also the funding key, as in
/// the library's localnet harness, so one signature scheme covers
/// everything the library signs.
///
/// The wallet mines nothing itself. It spends its own coins into an output
/// of exactly the value the library asked, waits for the chain to mine it,
/// and hands it over; the library spends it into Y, the round or the
/// witness and publishes those through the chain access. The wallet learns
/// what became of an output it offered at [reconcile], which the server
/// calls at start and after every round: an offered output the chain
/// still shows unspent (a round that failed after Y was funded) goes back
/// to be offered again, and any output at the address the wallet does not
/// know (an operator's top-up, a round's change) is taken in.
abstract class CoordinatorWallet implements CoordinatorFunding {
  /// The key that owns the pool and signs its funding.
  TransactionSigner get owner;
  SVPublicKey get ownerPub;
  Address get address;

  /// What the wallet holds in coins it can spend, in satoshis.
  BigInt get balance;

  /// What the last completed round cost, or null before the first.
  BigInt? get lastRoundCost;

  /// How many rounds the balance pays for at the last round's cost, or
  /// null before the first round.
  int? get roundsLeft;

  WalletReport get report;

  /// Takes in what the chain shows at the address, returns unspent offers
  /// to the coins, and measures the last round's cost. Called at start and
  /// after every round, never during one: within a round Y's output is
  /// unspent on the chain until the round publishes, and asking then would
  /// offer it twice. [roundTxs] are the transactions of the round that
  /// completed, whose change at the address is the round's and not a
  /// top-up.
  Future<void> reconcile({Iterable<Transaction> roundTxs = const []});
}
