import 'dart:math';

import 'package:dartsv/dartsv.dart';
import 'package:tstokenlib/tstokenlib.dart';

import '../fakes.dart';
import 'pool_test_chain.dart';
import 'test_keys.dart';

/// The library's coordinator on the test chain with this package's fakes,
/// as the store and server tests need it.
class CoordinatorSetup {
  final PoolTestChain c;
  final EventLog log = EventLog();
  late final FakeChain chain = FakeChain(log: log)
    ..addMined(c.y0.tx)
    ..addMined(c.r0)
    ..addMined(c.w0)
    ..addMined(c.depositTx);
  final signer = DefaultTransactionSigner(sigHashAll, opKey);
  final opPub = opKey.publicKey;
  late final opAddr = Address.fromPublicKey(opPub, NetworkType.TEST);
  late final FakeWallet wallet = FakeWallet(signer, opPub, opAddr);
  final rng = Random(41);

  CoordinatorSetup(this.c);

  List<int> newId() => List.generate(16, (_) => rng.nextInt(256));

  /// Round 1's deposit transfer, backed by the covenant the test chain built.
  ShieldedTransfer deposit() {
    final d = c.f.transfers1[0];
    return ShieldedTransfer(d.publics, d.proof, d.bundle, depositOutpoint: c.depositOutpoint);
  }

  /// Round 1's transfers with the deposit first, and round 2's.
  List<ShieldedTransfer> get round1 => [deposit(), ...c.f.transfers1.sublist(1)];
  List<ShieldedTransfer> get round2 => c.f.transfers2;

  ShieldedCoordinator make({required CoordinatorStore store, ShieldedLedger? ledger, CoordinatorFunding? funding, Future<void> Function(Transaction)? publish}) =>
      ShieldedCoordinator(
        config: CoordinatorConfig(plan: c.f.agg, feeRate: 1),
        tool: c.svc,
        ledger: ledger ?? ShieldedLedger.open(ShieldedPoolLayout.of(c.f.agg.tree), c.r0, c.w0, c.y0.tx),
        funding: funding ?? wallet,
        store: store,
        publish: publish ?? (tx) async => chain.broadcast(tx),
        owner: signer,
        ownerPub: opPub,
        clock: FakeClock(),
        rng: Random(7),
      );

  /// Closes a round of [transfers] on [co].
  Future<PoolAnnouncement> close(ShieldedCoordinator co, List<ShieldedTransfer> transfers) async {
    for (final t in transfers) {
      final r = co.intake(newId(), t, depositTx: t.depositOutpoint == null ? null : c.depositTx);
      if (!r.isAccepted) throw StateError('$r');
    }
    final a = await (co.building ?? co.closeRound());
    if (a == null) throw StateError('${co.lastFailure}');
    return a;
  }
}
