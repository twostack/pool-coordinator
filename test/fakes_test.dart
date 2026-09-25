import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// The fakes behave as the interfaces say, since every other test leans
/// on them: a broadcast mines, a spent outpoint is spent, the inbox
/// empties as messages are marked delivered, and a failing send retries.
void main() {
  final key = SVPrivateKey.fromWIF('cStLVGeWx7fVYKKDXYWVeEbEcPZEC4TD73DjQpHCks2Y8EAjVDSS');
  final addr = Address.fromPublicKey(key.publicKey, NetworkType.TEST);
  final signer = DefaultTransactionSigner(SighashType.SIGHASH_FORKID.value | SighashType.SIGHASH_ALL.value, key);

  Transaction coin(int n, BigInt sats) => Transaction()
    ..version = 1
    ..addInput(TransactionInput(hex.encode(List.filled(32, n)), 0, TransactionInput.MAX_SEQ_NUMBER))
    ..addOutput(TransactionOutput(sats, P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));

  group('FakeChain', () {
    test('a broadcast is mined, and its inputs are spent', () async {
      final chain = FakeChain(height: 10);
      final a = coin(1, BigInt.from(1000));
      chain.addMined(a);
      expect(await chain.minedHeight(a.id), 10);
      expect(await chain.unspent(a.id, 0), isTrue);
      final b = Transaction()
        ..addInput(TransactionInput(a.id, 0, TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(TransactionOutput(BigInt.from(900), P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));
      expect(await chain.broadcast(b), 'fake');
      expect(await chain.minedHeight(b.id), 11);
      expect(await chain.height(), 11);
      expect(await chain.unspent(a.id, 0), isFalse);
      expect(await chain.unspent(b.id, 0), isTrue);
      expect(await chain.fetch(b.id), isNotNull);
      expect(await chain.fetch('00' * 32), isNull);
      expect((await chain.unspentOf(addr)).map((u) => u.outpoint), ['${b.id}:0']);
      expect(chain.broadcasts, [b.id]);
      expect(chain.log.events, ['broadcast ${b.id}']);
    });

    test('mining can be deferred, and a refusal names its reason', () async {
      final chain = FakeChain()..mineOnBroadcast = false;
      final a = coin(2, BigInt.from(500));
      await chain.broadcast(a);
      expect(await chain.minedHeight(a.id), isNull);
      chain.mine();
      expect(await chain.minedHeight(a.id), isNotNull);
      chain.refuse = (tx) => 'no';
      expect(() => chain.broadcast(coin(3, BigInt.one)), throwsA(isA<BroadcastRefusal>().having((e) => e.reason, 'reason', 'no')));
    });
  });

  group('FakeChain for the coin pool', () {
    Transaction spend(Transaction from, int n) => Transaction()
      ..version = 1
      ..addInput(TransactionInput(from.id, 0, TransactionInput.MAX_SEQ_NUMBER))
      ..addOutput(TransactionOutput(BigInt.from(n), P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));

    test('blocks are mined on demand, each taking every unmined transaction', () async {
      final chain = FakeChain(height: 50)..mineOnBroadcast = false;
      final a = coin(7, BigInt.from(1000));
      chain.addMined(a);
      final b = spend(a, 900);
      await chain.broadcast(b);
      expect(chain.mine(), 51);
      expect(await chain.minedHeight(b.id), 51);
      expect(chain.mine(), 52, reason: 'an empty block still moves the height');
      expect(await chain.height(), 52);
    });

    test('a transaction accepted is not mined until the next block, and can be spent meanwhile', () async {
      final chain = FakeChain(height: 50)..mineOnBroadcast = false;
      final a = coin(8, BigInt.from(1000));
      chain.addMined(a);
      final b = spend(a, 900);
      expect(await chain.broadcast(b), 'fake');
      expect(await chain.minedHeight(b.id), isNull);
      expect(await chain.fetch(b.id), isNotNull);
      expect(await chain.unspent(b.id, 0), isTrue, reason: 'an unmined output is spendable');
      final c = spend(b, 800);
      await chain.broadcast(c);
      expect(await chain.unspent(b.id, 0), isFalse, reason: 'spent by an unmined child');
      chain.mine();
      expect(await chain.minedHeight(b.id), 51);
      expect(await chain.minedHeight(c.id), 51);
    });

    test('a transaction dropped from the mempool is unknown, its inputs are unspent again, and it can be broadcast again', () async {
      final chain = FakeChain(height: 50)..mineOnBroadcast = false;
      final a = coin(9, BigInt.from(1000));
      chain.addMined(a);
      final b = spend(a, 900);
      await chain.broadcast(b);
      expect(chain.drop(b.id), isTrue);
      expect(await chain.fetch(b.id), isNull);
      expect(await chain.unspent(a.id, 0), isTrue);
      chain.mine();
      expect(await chain.minedHeight(b.id), isNull, reason: 'a dropped transaction is not mined');
      expect(chain.drop(a.id), isFalse, reason: 'a mined transaction cannot be dropped');
      await chain.broadcast(b);
      chain.mine();
      expect(await chain.minedHeight(b.id), 52);
    });
  });

  group('FakeWallet', () {
    test('an output of exactly the value asked, paid to the owner, and the balance falls', () async {
      final w = FakeWallet(signer, key.publicKey, addr, balance: BigInt.from(5000));
      final f = (await w.output(BigInt.from(1234)))!;
      expect(f.value, BigInt.from(1234));
      expect(FakeChain.paysPKH(f.tx.outputs[f.vout], addr.pubkeyHash160), isTrue);
      expect(w.balance, BigInt.from(3766));
      w.dead = true;
      expect(await w.output(BigInt.one), isNull);
      w.dead = false;
      expect(() => w.output(BigInt.from(10000)), throwsA(isA<WalletRefusal>()));
      w.lastRoundCost = BigInt.from(1000);
      expect(w.roundsLeft, 3);
    });
  });

  group('FakeStore', () {
    test('a round stored is read back, and the last number is the highest', () async {
      final s = FakeStore();
      final y = coin(4, BigInt.one), r = coin(5, BigInt.one), w = coin(6, BigInt.one);
      expect(await s.lastNumber(), isNull);
      expect(await s.last(), isNull);
      await s.roundBuilt(1, y, r, w, Uint8List.fromList([1, 2, 3]));
      await s.roundBuilt(2, y, r, w, Uint8List.fromList([4]));
      expect(await s.lastNumber(), 2);
      final back = (await s.read(1))!;
      expect(back.number, 1);
      expect(back.y.id, y.id);
      expect(back.snapshot, [1, 2, 3]);
      expect(back.triple.nextSlot.id, y.id);
      expect((await s.last())!.snapshot, [4]);
      expect(s.log.events, ['store 1', 'store 2']);
    });
  });

  group('FakeTransport', () {
    test('messages sent are drained, leave once delivered, and replies land per peer', () async {
      final t = FakeTransport(batch: 2);
      t.send('alice', [1]);
      t.send('bob', [2]);
      t.send('carol', [3]);
      final first = await t.drain();
      expect(first.map((m) => m.sender), ['alice', 'bob']);
      expect(await t.drain(), hasLength(2), reason: 'nothing left until delivered');
      await t.delivered([first[0].id, first[1].id]);
      final second = await t.drain();
      expect(second.single.sender, 'carol');
      expect(second.single.payload, [3]);
      await t.delivered([second.single.id]);
      expect(t.undelivered, 0);
      await t.reply('alice', Uint8List.fromList([9]));
      expect(t.replies['alice']!.single, [9]);
      expect(t.replies['bob'], isNull);
    });

    test('the feed numbers from 1 and reads from a sequence; a failing send retries then fails', () async {
      final t = FakeTransport(retries: 2);
      expect(await t.announce(Uint8List.fromList([1])), 1);
      expect(await t.announce(Uint8List.fromList([2])), 2);
      expect(await t.announce(Uint8List.fromList([3])), 3);
      expect((await t.feed(2)).map((e) => e.sequence), [2, 3]);
      expect((await t.feed(1, limit: 1)).single.content, [1]);
      expect(await t.feed(4), isEmpty);
      t.failNextSends = 2;
      await t.announce(Uint8List.fromList([4]));
      expect(t.entries, hasLength(4), reason: 'two failures are within the retries');
      t.failNextSends = 3;
      expect(() => t.reply('x', Uint8List(1)), throwsA(isA<TransportFailure>()));
    });
  });
}
