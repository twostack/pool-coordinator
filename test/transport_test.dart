import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:logging/logging.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/ricochet_server.dart';

/// The protocol's four messages over a real ricochet server, started by
/// the test: submissions land where the server drains, replies where the
/// wallet reads, the feed carries the descriptor first and the
/// announcements in order, and the identity survives a restart.
void main() async {
  final skip = await RicochetTestServer.available();
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((r) { if (r.loggerName == "ServerSelector" || r.level >= Level.WARNING) print("${r.loggerName}: ${r.message}"); });

  group('ricochet transport', () {
    late RicochetTestServer server;
    late RicochetTransport coordinator, wallet;
    final rng = Random(3);
    final coordinatorSeed = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    final walletSeed = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    List<int> id() => List.generate(16, (_) => rng.nextInt(256));

    setUpAll(() async {
      server = (await RicochetTestServer.start())!;
      coordinator = await RicochetTransport.connect(seed: coordinatorSeed, server: server.address, retryDelay: const Duration(milliseconds: 200));
      wallet = await RicochetTransport.connect(seed: walletSeed, server: server.address, retryDelay: const Duration(milliseconds: 200));
    });

    tearDownAll(() async {
      await coordinator.close();
      await wallet.close();
      await server.dispose();
    });

    /// Drains until something arrives, or gives up after [tries].
    Future<List<InboxMessage>> drained({int tries = 20}) async {
      for (int i = 0; i < tries; i++) {
        final got = await coordinator.drain();
        if (got.isNotEmpty) return got;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return const [];
    }

    test('a submission arrives where the server reads, with the wallet\'s peer id as sender', () async {
      final submission = PoolSubmission(id(), List.generate(3000, (i) => i & 0xff)).encode();
      await wallet.submit(coordinator.peerId, submission);
      final got = await drained();
      expect(got, hasLength(1));
      expect(got.single.sender, wallet.peerId);
      expect(got.single.payload, submission);
      expect(PoolMessage.kindOf(got.single.payload), PoolMessageKind.submission);
      await coordinator.delivered([got.single.id]);
      expect(await coordinator.drain(), isEmpty, reason: 'delivered messages leave the folder');
    });

    test('a reply arrives where the wallet reads, and decodes to a reply with the submission\'s id', () async {
      final sid = id();
      final reply = PoolReply.accepted(sid, 3).encode();
      await coordinator.reply(wallet.peerId, reply);
      List<InboxMessage> got = const [];
      for (int i = 0; i < 20 && got.isEmpty; i++) {
        got = await wallet.readReplies();
        if (got.isEmpty) await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(got, hasLength(1));
      expect(got.single.sender, coordinator.peerId);
      final back = PoolReply.decode(got.single.payload);
      expect(back.id, sid);
      expect(back.round, 3);
      expect(await wallet.readReplies(), isEmpty);
    });

    test('descriptor first, announcements in order, and reading from a sequence', () async {
      final descriptor = PoolDescriptor(
          network: NetworkType.TEST,
          issuance: List.filled(32, 1),
          witness0: List.filled(32, 2),
          slot0: List.filled(32, 3),
          arities: const [2, 2],
          nullifierLevel: 1,
          receiptSlots: 2,
          spendP: testSpendParams);
      expect(await coordinator.feedExists(), isFalse);
      await coordinator.createFeed();
      expect(await coordinator.feedExists(), isTrue);
      expect(await coordinator.announce(descriptor.encode()), 1);
      final header = PoolHeader.decode(List.filled(PoolHeader.byteSize, 0));
      PoolAnnouncement a(int n) => PoolAnnouncement(
          round: n, header: header, roundTxId: List.filled(32, 10 + n), witnessTxId: List.filled(32, 20 + n), slotTxId: List.filled(32, 30 + n));
      expect(await coordinator.announce(a(1).encode()), 2);
      expect(await coordinator.announce(a(2).encode()), 3);

      final all = await wallet.feedOf(coordinator.host.id, 1);
      expect(all.map((e) => e.sequence), [1, 2, 3]);
      final d = PoolMessage.decode(all[0].content) as PoolDescriptor;
      expect(hex.encode(d.issuance), hex.encode(List.filled(32, 1)));
      expect(hex.encode(d.slot0), hex.encode(List.filled(32, 3)));
      expect((PoolMessage.decode(all[1].content) as PoolAnnouncement).round, 1);
      expect((PoolMessage.decode(all[2].content) as PoolAnnouncement).round, 2);
      final from3 = await wallet.feedOf(coordinator.host.id, 3);
      expect(from3.map((e) => e.sequence), [3]);
      expect((PoolMessage.decode(from3.single.content) as PoolAnnouncement).round, 2);
      expect(await wallet.feedOf(coordinator.host.id, 4), isEmpty);
      expect((await coordinator.feed(2, limit: 1)).single.sequence, 2);
    });

    test('the same peer id across restarts, and a submission to it is still answered', () async {
      final before = coordinator.peerId;
      await coordinator.close();
      coordinator = await RicochetTransport.connect(seed: coordinatorSeed, server: server.address, retryDelay: const Duration(milliseconds: 200));
      expect(coordinator.peerId, before);
      expect(await coordinator.feedExists(), isTrue, reason: 'the feed is under the same id');
      final submission = PoolSubmission(id(), [1, 2, 3]).encode();
      await wallet.submit(before, submission);
      final got = await drained();
      expect(got.single.payload, submission);
      await coordinator.delivered([got.single.id]);
      await coordinator.reply(got.single.sender, PoolReply.accepted(PoolSubmission.idOf(submission)!, 1).encode());
      List<InboxMessage> replies = const [];
      for (int i = 0; i < 20 && replies.isEmpty; i++) {
        replies = await wallet.readReplies();
        if (replies.isEmpty) await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(replies, hasLength(1));
    });

    test('a fresh sender per submission: two peer ids never seen are both answered to their own ids', () async {
      final a = await RicochetTransport.connect(seed: Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256))), server: server.address);
      final b = await RicochetTransport.connect(seed: Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256))), server: server.address);
      try {
        final sa = PoolSubmission(id(), [1]).encode(), sb = PoolSubmission(id(), [2]).encode();
        await a.submit(coordinator.peerId, sa);
        await b.submit(coordinator.peerId, sb);
        var got = <InboxMessage>[];
        for (int i = 0; i < 20 && got.length < 2; i++) {
          got = await coordinator.drain();
          if (got.length < 2) await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(got.map((m) => m.sender).toSet(), {a.peerId, b.peerId});
        for (final m in got) {
          await coordinator.reply(m.sender, PoolReply.accepted(PoolSubmission.idOf(m.payload)!, 1).encode());
        }
        await coordinator.delivered([for (final m in got) m.id]);
        for (final (t, s) in [(a, sa), (b, sb)]) {
          List<InboxMessage> replies = const [];
          for (int i = 0; i < 20 && replies.isEmpty; i++) {
            replies = await t.readReplies();
            if (replies.isEmpty) await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          expect(PoolReply.decode(replies.single.payload).id, PoolSubmission.idOf(s));
        }
      } finally {
        await a.close();
        await b.close();
      }
    });

    test('random bytes in a message: each is drained as sent, and the transport is unaffected', () async {
      final sent = <List<int>>[];
      for (int i = 0; i < 100; i++) {
        final bytes = Uint8List.fromList(List.generate(rng.nextInt(2000), (_) => rng.nextInt(256)));
        sent.add(bytes);
        await wallet.submit(coordinator.peerId, bytes);
      }
      final all = <InboxMessage>[];
      for (int i = 0; i < 40 && all.length < 100; i++) {
        final got = await coordinator.drain();
        if (got.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        all.addAll(got);
        await coordinator.delivered([for (final m in got) m.id]);
      }
      expect(all, hasLength(100));
      expect(all.map((m) => hex.encode(m.payload)).toSet(), sent.map(hex.encode).toSet());
      expect(await coordinator.drain(), isEmpty);
      final valid = PoolSubmission(id(), [7]).encode();
      await wallet.submit(coordinator.peerId, valid);
      final next = await drained();
      expect(next.single.payload, valid);
      await coordinator.delivered([next.single.id]);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a thousand submissions are consumed over successive drains, and the folder is empty afterwards', () async {
      final sw = Stopwatch()..start();
      for (int i = 0; i < 1000; i++) {
        try {
          await wallet.submit(coordinator.peerId, PoolSubmission(id(), [i & 0xff, i >> 8]).encode());
        } catch (e) {
          print('  send $i failed: $e');
          rethrow;
        }
      }
      print('  1,000 submissions sent in ${sw.elapsedMilliseconds} ms');
      sw.reset();
      var consumed = 0, drains = 0;
      while (consumed < 1000 && drains < 200) {
        final got = await coordinator.drain();
        drains++;
        if (got.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        expect(got.length, lessThanOrEqualTo(100));
        consumed += got.length;
        await coordinator.delivered([for (final m in got) m.id]);
      }
      print('  consumed $consumed in $drains drains, ${sw.elapsedMilliseconds} ms');
      if (consumed != 1000) {
        final lines = server.log.split('\n').where((l) => !l.contains('level=INFO')).toList();
        print(lines.skip(lines.length > 40 ? lines.length - 40 : 0).join('\n'));
      }
      expect(consumed, 1000);
      expect(await coordinator.drain(), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a reply that cannot be sent: the server stopped between the drain and the reply', () async {
      final submission = PoolSubmission(id(), [9]).encode();
      await wallet.submit(coordinator.peerId, submission);
      final got = await drained();
      expect(got, hasLength(1));
      await server.stop();
      final sw = Stopwatch()..start();
      // a connection that dies mid-dial throws inside dart-libp2p on a
      // future nobody awaits; the server runs under such a guard too
      final stray = <Object>[];
      final done = Completer<Object?>();
      runZonedGuarded(() async {
        try {
          await coordinator.reply(got.single.sender, PoolReply.accepted(PoolSubmission.idOf(submission)!, 1).encode());
          done.complete(null);
        } catch (e) {
          done.complete(e);
        }
      }, (e, st) => stray.add(e));
      final failure = await done.future;
      expect(failure, isA<TransportFailure>().having((e) => e.what, 'what', contains(got.single.sender)));
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 600)), reason: 'three retries at 200 ms');
      print('  ${stray.length} stray errors from the transport stack while the server was down');
      // back, and the reply goes through on a retry
      await server.launch();
      await coordinator.reply(got.single.sender, PoolReply.accepted(PoolSubmission.idOf(submission)!, 1).encode());
      List<InboxMessage> replies = const [];
      for (int i = 0; i < 40 && replies.isEmpty; i++) {
        replies = await wallet.readReplies();
        if (replies.isEmpty) await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(replies, hasLength(1));
      await coordinator.delivered([got.single.id]);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: skip);
}
