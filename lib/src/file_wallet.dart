import 'dart:async';

import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'chain_access.dart';
import 'wallet.dart';
import 'wallet_file.dart';

/// The wallet on its file and the chain access: the localnet harness's
/// funding class made persistent. Each request spends the wallet's coins
/// into an output of exactly the value asked, with the change before it
/// at output 0 when there is any (the layout the harness uses, and the one
/// the pool's issuance requires: it must spend output 1 of its funding
/// transaction), broadcasts it, records it, waits for it to be mined and
/// hands it over. The record is written before the wait, so a crash
/// between the broadcast and the mining loses nothing the top-up scan
/// cannot find at the address.
class FileWallet implements CoordinatorWallet {
  static const dust = 50;
  static final sigHashAll = SighashType.SIGHASH_FORKID.value | SighashType.SIGHASH_ALL.value;

  final WalletFile file;
  final WalletContents contents;
  final ChainAccess chain;
  final int feeRate, feeFloor;
  final Duration minedPoll, fundingTimeout;
  final Logger log;
  @override
  final TransactionSigner owner;
  @override
  final SVPublicKey ownerPub;
  @override
  final Address address;

  /// The funding transactions built, for a log or a test.
  final List<Transaction> built = [];

  FileWallet({
    required this.file,
    required this.contents,
    required this.chain,
    required this.feeRate,
    this.feeFloor = 135,
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

  @override
  WalletReport get report => WalletReport(
      balance: balance, lastRoundCost: lastRoundCost, roundsLeft: roundsLeft, coins: contents.coins.length, offered: contents.offered.length);

  /// The fee a funding transaction of [inputs] inputs and two outputs pays
  /// at the configured rate: a P2PKH input is about 148 bytes, an output 34.
  BigInt fundingFee(int inputs) {
    final size = 10 + 148 * inputs + 34 * 2;
    final fee = (size * feeRate + 999) ~/ 1000;
    return BigInt.from(fee < feeFloor ? feeFloor : fee);
  }

  @override
  Future<FundingOutput?> output(BigInt minValue) async {
    // an output offered before and returned unspent is offered again,
    // rather than building a transaction for what already exists
    for (final c in contents.coins.where((c) => c.returned)) {
      if (c.satoshis >= minValue) {
        contents.coins.remove(c);
        contents.offered.add(c);
        await file.write(contents);
        log.info('re-offering ${c.outpoint} (${c.satoshis} sat) for a request of $minValue');
        return FundingOutput(c.tx, c.vout, owner, ownerPub);
      }
    }

    // the coins that cover the value and the fee, largest first
    final sorted = [...contents.coins]..sort((a, b) => b.satoshis.compareTo(a.satoshis));
    final chosen = <WalletCoin>[];
    var sum = BigInt.zero;
    BigInt fee = fundingFee(1);
    for (final c in sorted) {
      chosen.add(c);
      sum += c.satoshis;
      fee = fundingFee(chosen.length);
      if (sum >= minValue + fee) break;
    }
    if (sum < minValue + fee) {
      throw WalletRefusal('the wallet holds $balance satoshis, and the request of $minValue plus a fee of $fee needs ${minValue + fee}');
    }
    final change = sum - minValue - fee;
    final builder = TransactionBuilder();
    for (final c in chosen) {
      builder.spendFromTxnWithSigner(owner, c.tx, c.vout, TransactionInput.MAX_SEQ_NUMBER, P2PKHUnlockBuilder(ownerPub));
    }
    final hasChange = change >= BigInt.from(dust);
    if (hasChange) builder.spendToPKH(address, change);
    builder.spendToPKH(address, minValue);
    final tx = builder.build(false);
    final vout = hasChange ? 1 : 0;
    if (tx.outputs[vout].satoshis != minValue) throw StateError('the builder did not put the payment at output $vout');

    // the chain first: a refusal leaves the record as it was
    try {
      await chain.broadcast(tx);
    } on BroadcastRefusal catch (e) {
      throw WalletRefusal('the chain refused the funding transaction: ${e.reason}');
    } on ChainError catch (e) {
      throw WalletRefusal('the funding transaction could not be broadcast: $e');
    }
    built.add(tx);
    for (final c in chosen) {
      contents.coins.remove(c);
    }
    if (hasChange) contents.coins.add(WalletCoin(tx, 0));
    final funding = WalletCoin(tx, vout);
    contents.offered.add(funding);
    await file.write(contents);
    log.info('funding ${tx.id} pays $minValue sat at output $vout, fee $fee, change ${hasChange ? change : 0}');

    await _waitMined(tx.id);
    return FundingOutput(tx, vout, owner, ownerPub);
  }

  Future<void> _waitMined(String txid) async {
    final deadline = DateTime.now().add(fundingTimeout);
    while (true) {
      if (await chain.minedHeight(txid) != null) return;
      if (DateTime.now().isAfter(deadline)) {
        throw WalletRefusal('funding transaction $txid was not mined within ${fundingTimeout.inMinutes} minutes');
      }
      await Future<void>.delayed(minedPoll);
    }
  }

  /// [roundTxs] are the transactions of a round that completed since the
  /// last reconcile, whose change at the address is the round's, not a
  /// top-up; with them the round's cost is measured.
  @override
  Future<void> reconcile({Iterable<Transaction> roundTxs = const []}) async {
    final roundIds = {for (final t in roundTxs) t.id};
    final found = {for (final u in await chain.unspentOf(address)) u.outpoint: u};
    final before = contents.balanceAtReconcile;

    // offered outputs the chain still shows unspent come back
    for (final c in [...contents.offered]) {
      if (found.containsKey(c.outpoint) || await chain.unspent(c.txid, c.vout)) {
        contents.offered.remove(c);
        contents.coins.add(WalletCoin(c.tx, c.vout, returned: true));
        log.info('offered output ${c.outpoint} was not spent; it will be offered again');
      } else {
        contents.offered.remove(c);
      }
    }
    // coins the chain no longer shows are gone
    for (final c in [...contents.coins]) {
      if (!found.containsKey(c.outpoint) && !await chain.unspent(c.txid, c.vout)) {
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
      contents.coins.add(WalletCoin(tx, u.vout));
      if (roundIds.contains(u.txid)) {
        log.info('round change ${u.outpoint} (${u.satoshis} sat) taken in');
      } else {
        topUps += u.satoshis;
        log.info('top-up ${u.outpoint} (${u.satoshis} sat) taken in');
      }
    }
    final after = balance;
    if (roundIds.isNotEmpty && before != null) {
      final cost = before + topUps - after;
      if (cost > BigInt.zero) contents.lastRoundCost = cost;
    }
    contents.balanceAtReconcile = after;
    await file.write(contents);
  }
}
