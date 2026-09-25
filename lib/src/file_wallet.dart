import 'dart:async';

import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'benford.dart';
import 'chain_access.dart';
import 'config.dart';
import 'wallet.dart';
import 'wallet_file.dart';

/// The wallet on its file and the chain access, serving the library from a
/// store of mined coins so that no request waits for a block.
///
/// A coin is ready when its transaction is mined, it pays the owner and it
/// holds at least the floor; every other coin is pending (a split's
/// outputs, change, a top-up) until a reconcile finds it mined. A request
/// takes the smallest ready coin that covers it, never several: the round
/// is handed the coin itself, since the round has change; Y and the
/// witness get an output of exactly the value from a one-input funding
/// transaction over the coin, with the change before it at output 0 (the
/// layout the pool's issuance requires: it spends output 1 of its funding
/// transaction), handed over once the chain has accepted the broadcast.
/// So no funding transaction spends an unmined output.
///
/// At the end of each reconcile, when the ready coins and the outputs of
/// splits on their way number fewer than the low-water mark, the largest
/// mined coin is split into outputs whose amounts follow Benford's law, up
/// to the target. A split is written to the file before its broadcast, so
/// one a crash left unbroadcast is broadcast at the next reconcile.
class FileWallet implements CoordinatorWallet {
  static const dust = 50;
  static final sigHashAll = SighashType.SIGHASH_FORKID.value | SighashType.SIGHASH_ALL.value;

  final WalletFile file;
  final WalletContents contents;
  final ChainAccess chain;
  final int feeRate, feeFloor;
  final CoinsConfig coins;
  final Duration minedPoll, fundingTimeout;
  final Logger log;
  @override
  final TransactionSigner owner;
  @override
  final SVPublicKey ownerPub;
  @override
  final Address address;

  @override
  FundingKind Function()? requestKind;

  /// Lets requests, and a split, be served from pending coins, and not
  /// only from mined ones: `create` alone does this, chaining the
  /// genesis's funding on each other's change above the one mined funding
  /// coin, then splitting what is left.
  bool spendPending = false;

  /// Whether a reconcile may split; `create` turns it off until the
  /// genesis is funded, so the operator's coin is not split first.
  bool splitting = true;

  @override
  Future<void> Function()? beforeRequest;

  /// The funding transactions built, for a log or a test.
  final List<Transaction> built = [];

  /// The splits broadcast, for a log or a test.
  final List<Transaction> splitsBuilt = [];

  bool _needsTopUp = false;

  FileWallet({
    required this.file,
    required this.contents,
    required this.chain,
    required this.feeRate,
    this.feeFloor = 135,
    this.coins = const CoinsConfig(),
    this.minedPoll = const Duration(seconds: 2),
    this.fundingTimeout = const Duration(hours: 1),
    Logger? log,
  })  : log = log ?? Logger('wallet'),
        owner = DefaultTransactionSigner(sigHashAll, contents.ownerKey),
        ownerPub = contents.ownerKey.publicKey,
        address = Address.fromPublicKey(contents.ownerKey.publicKey, contents.network);

  @override
  BigInt get balance => contents.coins.fold(BigInt.zero, (a, c) => a + c.satoshis);

  @override
  BigInt? get lastRoundCost => contents.lastRoundCost;

  @override
  int? get roundsLeft {
    final cost = contents.lastRoundCost;
    if (cost == null || cost <= BigInt.zero) return null;
    return (balance ~/ cost).toInt();
  }

  bool _isReady(WalletCoin c) => c.mined && !c.returned && c.satoshis >= BigInt.from(coins.floor);

  /// The coins requests are served from, smallest first, ties by outpoint.
  List<WalletCoin> get ready => contents.coins.where(_isReady).toList()..sort(_bySize);

  /// The coins not yet mined.
  List<WalletCoin> get pending => contents.coins.where((c) => !c.mined).toList();

  static int _bySize(WalletCoin a, WalletCoin b) {
    final c = a.satoshis.compareTo(b.satoshis);
    return c != 0 ? c : a.outpoint.compareTo(b.outpoint);
  }

  static BigInt _sum(Iterable<WalletCoin> cs) => cs.fold(BigInt.zero, (a, c) => a + c.satoshis);

  @override
  WalletReport get report {
    final r = ready, p = pending;
    return WalletReport(
      balance: balance,
      lastRoundCost: lastRoundCost,
      roundsLeft: roundsLeft,
      coins: contents.coins.length,
      offered: contents.offered.length,
      readyCoins: r.length,
      readyValue: _sum(r),
      pendingCoins: p.length,
      pendingValue: _sum(p),
      needsTopUp: _needsTopUp,
    );
  }

  /// The fee a transaction of [inputs] P2PKH inputs and [outputs] P2PKH
  /// outputs pays at the configured rate: an input is about 148 bytes, an
  /// output 34.
  BigInt feeFor(int inputs, int outputs) {
    final size = 10 + 148 * inputs + 34 * outputs;
    final fee = (size * feeRate + 999) ~/ 1000;
    return BigInt.from(fee < feeFloor ? feeFloor : fee);
  }

  /// A funding transaction's fee: one input, the payment and the change.
  BigInt fundingFee(int inputs) => feeFor(inputs, 2);

  @override
  Future<FundingOutput?> output(BigInt minValue) async {
    await beforeRequest?.call();

    // an output offered before and returned unspent is offered again,
    // mined or not, rather than building a transaction for what exists
    for (final c in contents.coins.where((c) => c.returned)) {
      if (c.satoshis >= minValue) {
        contents.coins.remove(c);
        contents.offered.add(c);
        await file.write(contents);
        log.info('re-offering ${c.outpoint} (${c.satoshis} sat) for a request of $minValue');
        return FundingOutput(c.tx, c.vout, owner, ownerPub);
      }
    }

    final kind = requestKind?.call() ?? FundingKind.exact;
    final fee = fundingFee(1);
    final need = kind == FundingKind.round ? minValue : minValue + fee;

    // a request no coin could ever cover fails at once; one that a pending
    // coin will cover once mined waits for it
    final largest = contents.coins.isEmpty ? BigInt.zero : contents.coins.map((c) => c.satoshis).reduce((a, b) => a > b ? a : b);
    if (largest < need) {
      throw WalletRefusal('the wallet holds $balance satoshis, its largest coin $largest, and the request of $minValue'
          '${kind == FundingKind.round ? '' : ' plus a fee of $fee'} needs $need');
    }
    final coin = await _coinFor(need, minValue);
    return kind == FundingKind.round ? _handOver(coin, minValue) : _fund(coin, minValue, fee);
  }

  /// The smallest usable coin of at least [need], waiting for a pending
  /// one to be mined when no ready coin covers it.
  Future<WalletCoin> _coinFor(BigInt need, BigInt minValue) async {
    final deadline = DateTime.now().add(fundingTimeout);
    var logged = false;
    while (true) {
      final usable = spendPending
          ? (contents.coins.where((c) => !c.returned && c.satoshis >= BigInt.from(coins.floor)).toList()..sort(_bySize))
          : ready;
      for (final c in usable) {
        if (c.satoshis >= need) return c;
      }
      if (!logged) {
        log.info('a request of $minValue waits for a ready coin of $need: ${report.readyCoins} ready, ${report.pendingCoins} pending');
        logged = true;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw WalletRefusal('no ready coin of $need satoshis within ${fundingTimeout.inMinutes} minutes; '
            '${report.pendingCoins} coins are pending, waiting to be mined');
      }
      await Future<void>.delayed(minedPoll);
      await _refreshHeights();
    }
  }

  /// The round's request: the coin itself.
  Future<FundingOutput> _handOver(WalletCoin c, BigInt minValue) async {
    contents.coins.remove(c);
    contents.offered.add(c);
    await file.write(contents);
    log.info('the round gets ${c.outpoint} (${c.satoshis} sat) for a request of $minValue');
    return FundingOutput(c.tx, c.vout, owner, ownerPub);
  }

  /// Y's or the witness's request: [c] alone into exactly [minValue] at
  /// output 1 and the change at output 0, handed over once accepted.
  Future<FundingOutput> _fund(WalletCoin c, BigInt minValue, BigInt fee) async {
    final change = c.satoshis - minValue - fee;
    final builder = TransactionBuilder()
      ..spendFromTxnWithSigner(owner, c.tx, c.vout, TransactionInput.MAX_SEQ_NUMBER, P2PKHUnlockBuilder(ownerPub));
    final hasChange = change >= BigInt.from(dust);
    if (hasChange) builder.spendToPKH(address, change);
    builder.spendToPKH(address, minValue);
    final tx = builder.build(false);
    final vout = hasChange ? 1 : 0;
    if (tx.outputs[vout].satoshis != minValue) throw StateError('the builder did not put the payment at output $vout');

    // the chain first: a refusal leaves the coin where it was
    try {
      await chain.broadcast(tx);
    } on BroadcastRefusal catch (e) {
      throw WalletRefusal('the chain refused the funding transaction: ${e.reason}');
    } on ChainError catch (e) {
      throw WalletRefusal('the funding transaction could not be broadcast: $e');
    }
    built.add(tx);
    contents.coins.remove(c);
    if (hasChange) contents.coins.add(WalletCoin(tx, 0));
    contents.offered.add(WalletCoin(tx, vout));
    await file.write(contents);
    log.info('funding ${tx.id} pays $minValue sat at output $vout from ${c.outpoint}, fee $fee, change ${hasChange ? change : 0}');
    return FundingOutput(tx, vout, owner, ownerPub);
  }

  @override
  List<Transaction> fundingOf(List<Transaction> spenders) {
    final mine = <String, Transaction>{
      for (final t in built) t.id: t,
      for (final c in [...contents.offered, ...contents.coins])
        if (!c.mined) c.txid: c.tx,
    };
    final out = <String, Transaction>{};
    for (final s in spenders) {
      for (final i in s.inputs) {
        final t = mine[i.prevTxnId];
        if (t != null) out[t.id] = t;
      }
    }
    return out.values.toList();
  }

  /// The heights of pending coins: from the address's unspent outputs,
  /// which name every coin the wallet holds (they all pay the owner), and
  /// from the chain's answer for each transaction the list does not name.
  Future<void> _refreshHeights({Map<String, UnspentOutput>? found}) async {
    if (!contents.coins.any((c) => !c.mined)) return;
    final listed = found ?? {for (final u in await chain.unspentOf(address)) u.outpoint: u};
    final heights = <String, int?>{};
    for (final c in contents.coins.where((c) => !c.mined)) {
      final h = listed[c.outpoint]?.height;
      if (h != null) {
        c.height = h;
        heights[c.txid] = h;
      }
    }
    for (final c in contents.coins.where((c) => !c.mined)) {
      final h = heights.containsKey(c.txid) ? heights[c.txid] : (heights[c.txid] = await chain.minedHeight(c.txid));
      c.height = h;
    }
  }

  /// [roundTxs] are the transactions of a round that completed since the
  /// last reconcile, whose change at the address is the round's, not a
  /// top-up; with them the round's cost is measured.
  @override
  Future<void> reconcile({Iterable<Transaction> roundTxs = const []}) async {
    final roundIds = {for (final t in roundTxs) t.id};
    await _resumeSplits();
    final found = {for (final u in await chain.unspentOf(address)) u.outpoint: u};
    final before = contents.balanceAtReconcile;

    // offered outputs the chain still shows unspent come back; one the
    // round's own transactions spend is spent whatever the chain says, since
    // an indexer can lag the round's broadcast by seconds (WhatsOnChain on
    // testnet, 2026-09-25) and an output offered again after that would be
    // spent twice
    final spentByRound = {
      for (final t in roundTxs)
        for (final i in t.inputs) '${i.prevTxnId}:${i.prevTxnOutputIndex}'
    };
    for (final c in [...contents.offered]) {
      contents.offered.remove(c);
      if (spentByRound.contains(c.outpoint)) continue;
      if (found.containsKey(c.outpoint) || await chain.unspent(c.txid, c.vout)) {
        contents.coins.add(WalletCoin(c.tx, c.vout, returned: true, height: c.height));
        log.info('offered output ${c.outpoint} was not spent; it will be offered again');
      }
    }
    // mined coins the chain no longer shows are gone; a pending one is
    // kept, since a dropped parent is broadcast again with its round
    for (final c in [...contents.coins]) {
      if (c.mined && !found.containsKey(c.outpoint) && !await chain.unspent(c.txid, c.vout)) {
        contents.coins.remove(c);
        log.warning('coin ${c.outpoint} is no longer unspent on the chain; dropped');
      }
    }
    // what the chain shows and the wallet does not know: a top-up, or a
    // round's change
    final known = {for (final c in contents.coins) c.outpoint, for (final c in contents.offered) c.outpoint};
    var topUps = BigInt.zero;
    for (final u in found.values) {
      if (known.contains(u.outpoint)) continue;
      final tx = await chain.fetch(u.txid);
      if (tx == null || u.vout >= tx.outputs.length) continue;
      contents.coins.add(WalletCoin(tx, u.vout, height: u.height));
      if (roundIds.contains(u.txid)) {
        log.info('round change ${u.outpoint} (${u.satoshis} sat) taken in');
      } else {
        topUps += u.satoshis;
        log.info('top-up ${u.outpoint} (${u.satoshis} sat) taken in');
      }
    }
    await _refreshHeights(found: found);

    // the round's cost: what the balance fell by since the last reconcile,
    // which a split's fee never falls in (a split is made after the
    // measure and before the balance is recorded), plus the share of a
    // split's fee each of the round's three coins carries
    final after = balance;
    if (roundIds.isNotEmpty && before != null) {
      var cost = before + topUps - after;
      cost += (contents.splitFeePerCoin ?? BigInt.zero) * BigInt.from(3);
      if (cost > BigInt.zero) contents.lastRoundCost = cost;
    }

    await _split();
    contents.balanceAtReconcile = balance;
    await file.write(contents);
    if (contents.readFormat == 1) log.info('the wallet file was format 1; it is format ${WalletContents.formatVersion} from now on');
  }

  /// Splits written but not yet mined: broadcast again any the chain does
  /// not show (a crash between the write and the broadcast), forget those
  /// mined. The chain's word that a split is unknown is not enough to drop
  /// it: an indexer can lag the broadcast by minutes while already showing
  /// the source spent, by the split itself. So a split is broadcast again,
  /// and only a refusal that is not "already known" drops it, putting its
  /// source back when that is still unspent.
  Future<void> _resumeSplits() async {
    for (final s in [...contents.splits]) {
      if (await chain.minedHeight(s.id) != null) {
        contents.splits.remove(s);
        continue;
      }
      if (await chain.fetch(s.id) != null) continue;
      try {
        await chain.broadcast(s);
        splitsBuilt.add(s);
        log.info('split ${s.id}, not shown by the chain, broadcast again');
      } on BroadcastRefusal catch (e) {
        if (alreadyKnown(e)) continue;
        final i = s.inputs.single;
        final sourceUnspent = await chain.unspent(i.prevTxnId, i.prevTxnOutputIndex);
        await _undoSplit(s, restoreSource: sourceUnspent);
        log.warning('split ${s.id} refused by the chain when broadcast again: ${e.reason}; '
            '${sourceUnspent ? 'its source is ready again' : 'its source is spent elsewhere'}');
      } on ChainError catch (e) {
        log.warning('split ${s.id} could not be broadcast again yet: $e');
      }
    }
  }

  /// A refusal that says the chain has the transaction already, which a
  /// transaction broadcast again counts as its acceptance.
  static bool alreadyKnown(BroadcastRefusal e) =>
      RegExp(r'already (known|in|have)|txn-already|known transaction', caseSensitive: false).hasMatch('${e.status ?? ''} ${e.reason}');

  /// The source coin of a split, kept while the split is on its way so a
  /// refusal can put it back.
  final Map<String, WalletCoin> _splitSources = {};

  /// Forgets split [s] and its outputs, and with [restoreSource] puts its
  /// source coin back, from memory or, after a restart, from the chain.
  Future<void> _undoSplit(Transaction s, {required bool restoreSource}) async {
    contents.splits.remove(s);
    contents.coins.removeWhere((c) => c.txid == s.id);
    var source = _splitSources.remove(s.id);
    if (!restoreSource) return;
    if (source == null) {
      final i = s.inputs.single;
      final tx = await chain.fetch(i.prevTxnId);
      if (tx == null) return;
      source = WalletCoin(tx, i.prevTxnOutputIndex, height: await chain.minedHeight(tx.id));
    }
    final back = source;
    if (!contents.coins.any((c) => c.outpoint == back.outpoint)) contents.coins.add(back);
  }

  /// Splits the largest mined coin when the store is below low water.
  Future<void> _split() async {
    if (!splitting) return;
    final floor = BigInt.from(coins.floor);
    final splitIds = {for (final s in contents.splits) s.id};
    final onTheirWay = contents.coins.where((c) => !c.mined && splitIds.contains(c.txid)).length;
    final readyNow = ready;
    if (readyNow.length + onTheirWay >= coins.lowWater) {
      _needsTopUp = false;
      return;
    }
    // the largest mined coin (or any coin, for create); it stops counting
    // as ready once split
    final mined = contents.coins.where((c) => (c.mined || spendPending) && !c.returned).toList()..sort(_bySize);
    final source = mined.isEmpty ? null : mined.last;
    final others = readyNow.length - (source != null && _isReady(source) ? 1 : 0) + onTheirWay;
    var count = coins.target - others;
    if (count > coins.splitMaxOutputs) count = coins.splitMaxOutputs;
    if (source == null || count < 2) {
      _needsTopUp = source == null;
      return;
    }
    var fee = feeFor(1, count);
    final most = ((source.satoshis - fee) ~/ (floor * BigInt.two)).toInt();
    if (count > most) {
      count = most;
      fee = feeFor(1, count);
    }
    if (count < 2) {
      _needsTopUp = true;
      log.warning('the store is below its low-water mark, and no coin is large enough to split: '
          'the largest mined coin holds ${source.satoshis} satoshis; pay the address ${address.toBase58()}');
      return;
    }
    _needsTopUp = false;
    final amounts = BenfordDistribution.distribute(source.satoshis - fee, count, minOutputAmount: floor);
    final builder = TransactionBuilder()
      ..spendFromTxnWithSigner(owner, source.tx, source.vout, TransactionInput.MAX_SEQ_NUMBER, P2PKHUnlockBuilder(ownerPub));
    for (final a in amounts) {
      builder.spendToPKH(address, a);
    }
    final tx = builder.build(false);
    // no change output: the fee is what the outputs leave of the source
    final paid = source.satoshis - tx.outputs.fold(BigInt.zero, (a, o) => a + o.satoshis);
    if (paid != fee) throw StateError('the split pays $paid in fee, expected $fee');

    // recorded before the broadcast, so a crash leaves it to be resumed
    contents.coins.remove(source);
    contents.splits.add(tx);
    _splitSources[tx.id] = source;
    for (int v = 0; v < tx.outputs.length; v++) {
      contents.coins.add(WalletCoin(tx, v));
    }
    await file.write(contents);
    try {
      await chain.broadcast(tx);
    } on BroadcastRefusal catch (e) {
      await _undoSplit(tx, restoreSource: true);
      await file.write(contents);
      log.warning('split of ${source.outpoint} refused by the chain: ${e.reason}; its source is ready again');
      return;
    } on ChainError catch (e) {
      log.warning('split ${tx.id} could not be broadcast yet ($e); it is broadcast again at the next reconcile');
      return;
    }
    splitsBuilt.add(tx);
    contents.splitFeePerCoin = fee ~/ BigInt.from(count);
    log.info('split ${source.outpoint} (${source.satoshis} sat) into $count coins for the store, fee $fee');
  }
}
