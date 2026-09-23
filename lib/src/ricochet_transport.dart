import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:logging/logging.dart';
import 'package:ricochet/protocol/maa/access_handler.dart';
import 'package:ricochet/protocol/msa/submission_handler.dart';
import 'package:ricochet/ricochet.dart';

import 'transport.dart';

/// The pool's transport on ricochet: a libp2p host of this identity (UDX,
/// Noise, yamux, as ricochet's own tests build one), connected to the one
/// configured server and protected from the connection manager, and an
/// `SFClient` over it with the identity's payload encryptor.
///
/// The mailbox calls (retrieve, submit, mark delivered, delete) open their
/// own streams here and close them, rather than going through the client:
/// the client leaves a submission's stream open, and a yamux session
/// allows 256, so a thousand sends would stall at the 253rd; and the
/// client's retrieval opens every sealed payload and gives up the whole
/// batch when one does not open, which a hostile sender could arrange.
/// Here a payload that does not open is handed over as it is, and the
/// server finds it is not a submission. The feed calls go through the
/// client, which closes those streams. The same host serves a wallet in
/// the tests, which is why the wallet side's calls are here too.
class RicochetTransport implements PoolTransport {
  final BasicHost host;
  SFClient client;
  final PeerId serverId;
  final MultiAddr serverAddr;
  final PayloadEncryptor encryptor;
  final int sendRetries;
  final int batch;
  final Duration retryDelay;
  final Duration connectionTimeout, messageTimeout;
  final Logger log;

  /// The zone every call runs in. The transport stack throws on futures
  /// nobody awaits when a connection dies mid-dial; in this zone those are
  /// logged, not fatal to the process, and not surfaced to the caller of an
  /// unrelated call. dart_libp2p's own case is fixed in 2.0.0, but the
  /// ricochet client still leaves such futures behind.
  late final Zone _zone;

  RicochetTransport._(this.host, this.client, this.serverId, this.serverAddr, this.encryptor,
      {required this.sendRetries,
      required this.batch,
      required this.retryDelay,
      required this.connectionTimeout,
      required this.messageTimeout,
      required this.log});

  @override
  String get peerId => host.id.toBase58();

  /// Connects to [server], a multiaddr ending in `/p2p/<peer id>`, as the
  /// identity of [seed]. The server's address is registered with the host
  /// and the client, so a dropped connection is redialled.
  static Future<RicochetTransport> connect({
    required Uint8List seed,
    required String server,
    int sendRetries = 3,
    int batch = 100,
    Duration retryDelay = const Duration(seconds: 1),
    Duration connectionTimeout = const Duration(seconds: 10),
    Duration messageTimeout = const Duration(seconds: 30),
    int connectAttempts = 5,
    Logger? log,
  }) async {
    final l = log ?? Logger('ricochet');
    final serverMa = MultiAddr(server);
    final serverPeer = serverMa.valueForProtocol(Protocols.p2p.name);
    if (serverPeer == null) throw ArgumentError('the ricochet server address needs a /p2p/<peer id>: $server');
    final serverId = PeerId.fromString(serverPeer);
    final connectAddr = serverMa.decapsulate(Protocols.p2p.name)!;

    late final Zone zone;
    final ready = Completer<void>();
    runZonedGuarded(() {
      zone = Zone.current;
      ready.complete();
    }, (e, st) => l.warning('stray error in the transport stack: $e'));
    await ready.future;
    final keyPair = await crypto_ed25519.generateEd25519KeyPairFromSeed(seed);
    final host = await zone.run(() => _createHost(keyPair));
    await zone.run(() => host.start());
    await host.peerStore.addrBook.addAddr(serverId, connectAddr, const Duration(hours: 24));
    Object? lastError;
    for (int attempt = 1; attempt <= connectAttempts; attempt++) {
      try {
        await zone.run(() => host.connect(AddrInfo(serverId, [connectAddr]), context: core_context.Context()).timeout(connectionTimeout));
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        l.warning('connect to the ricochet server, attempt $attempt of $connectAttempts: $e');
        await Future<void>.delayed(retryDelay);
      }
    }
    if (lastError != null) {
      await host.close();
      throw TransportFailure('connect to $server', '$lastError');
    }
    host.connManager.protect(serverId, 'pool-ricochet-server');
    final encryptor = PayloadEncryptor.fromEd25519Seed(seed);
    final client = await zone.run(() => _newClient(host, serverId, connectAddr, encryptor, connectionTimeout, messageTimeout));
    l.info('ricochet identity ${host.id.toBase58()} connected to $serverPeer');
    final t = RicochetTransport._(host, client, serverId, connectAddr, encryptor,
        sendRetries: sendRetries,
        batch: batch,
        retryDelay: retryDelay,
        connectionTimeout: connectionTimeout,
        messageTimeout: messageTimeout,
        log: l);
    t._zone = zone;
    return t;
  }

  static Future<SFClient> _newClient(BasicHost host, PeerId serverId, MultiAddr addr, PayloadEncryptor encryptor,
      Duration connectionTimeout, Duration messageTimeout) async {
    final client = SFClient(
        host: host,
        config: SFClientConfig(
            preferredServers: [SFServerPreference(serverId: serverId, priority: 10)],
            connectionTimeout: connectionTimeout,
            messageTimeout: messageTimeout),
        encryptor: encryptor);
    client.registerServerAddress(serverId, addr);
    await client.start();
    return client;
  }

  /// A host with UDX, Noise and yamux and nothing else: no relay, no DHT,
  /// no NAT traversal, since the server is one configured address.
  static Future<BasicHost> _createHost(KeyPair keyPair) async {
    final connMgr = ConnectionManager(idleTimeout: const Duration(seconds: 60));
    final udx = UDXTransport(connManager: connMgr);
    final yamux = MultiplexerConfig(
      keepAliveInterval: const Duration(seconds: 60),
      maxStreamWindowSize: 1024 * 1024,
      initialStreamWindowSize: 256 * 1024,
      streamWriteTimeout: const Duration(seconds: 30),
      maxStreams: 256,
    );
    final options = <p2p_config.Option>[
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connMgr),
      p2p_config.Libp2p.transport(udx),
      p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
      p2p_config.Libp2p.muxer('/yamux/1.0.0', (Conn secureConn, bool isClient) {
        if (secureConn is! TransportConn) throw ArgumentError('yamux expects a TransportConn, got ${secureConn.runtimeType}');
        return YamuxSession(secureConn, yamux, isClient, null);
      }),
      p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/udp/0/udx')]),
    ];
    return await p2p_config.Libp2p.new_(options) as BasicHost;
  }

  /// Dials the server again, for a retry after it went away and came back,
  /// and replaces the client: the client's server selector marks a server
  /// unavailable for 30 s after a failed probe, which would turn one
  /// dropped connection into 30 s of failed sends.
  Future<void> reconnect() async {
    try {
      await host.peerStore.addrBook.addAddr(serverId, serverAddr, const Duration(hours: 24));
      await host.connect(AddrInfo(serverId, [serverAddr]), context: core_context.Context()).timeout(connectionTimeout);
    } catch (e) {
      log.fine('reconnect: $e');
      return;
    }
    try {
      await client.stop();
    } catch (_) {}
    client = await _newClient(host, serverId, serverAddr, encryptor, connectionTimeout, messageTimeout);
  }

  /// Runs [fn] on a fresh stream to the server of [protocol], closed after.
  Future<T> _stream<T>(String protocol, Future<T> Function(P2PStream stream) fn) async {
    final P2PStream stream;
    try {
      stream = await host.newStream(serverId, [protocol], core_context.Context()).timeout(connectionTimeout);
    } on StateError catch (e) {
      if (!'$e'.contains('Maximum streams')) rethrow;
      await recycle();
      return _stream(protocol, fn);
    }
    try {
      return await fn(stream).timeout(messageTimeout);
    } finally {
      if (!stream.isClosed) {
        try {
          await stream.close();
        } catch (_) {}
      }
    }
  }

  /// Closes the connection to the server and dials it again. A connection
  /// that refuses new streams is the one failure a redial reliably clears,
  /// so [_stream] falls back to this rather than failing the round.
  Future<void> recycle() async {
    log.fine('recycling the connection to the ricochet server');
    try {
      await host.network.closePeer(serverId);
    } catch (e) {
      log.fine('closePeer: $e');
    }
    await reconnect();
  }

  // ---- the coordinator's side ----

  @override
  Future<List<InboxMessage>> drain() => guarded(() => _retrieve(PoolTransport.submissionsFolder));

  Future<List<InboxMessage>> _retrieve(String folder) async {
    try {
      final response = await _stream(AccessHandler.protocolId,
          (stream) => AccessHandler.retrieveMessages(stream, host.id, folderPath: folder, maxMessages: batch));
      final out = <InboxMessage>[];
      for (final m in response.messages) {
        Uint8List payload = m.payload;
        if (m.flags.isEncrypted) {
          try {
            payload = (await openIfEncrypted(m, encryptor)).payload;
          } on PayloadDecryptException catch (e) {
            // not sealed to this identity: the bytes are handed over as they
            // are, and the server finds they are not a submission
            log.fine('message ${m.messageId} from ${m.senderPeerId.toBase58()} did not open: ${e.message}');
          }
        }
        out.add(InboxMessage(m.messageId, m.senderPeerId.toBase58(), payload));
      }
      return out;
    } catch (e) {
      log.warning('drain of $folder failed: $e');
      return const [];
    }
  }

  @override
  Future<void> delivered(List<String> ids) => guarded(() => _delivered(ids, PoolTransport.submissionsFolder));

  /// Marks [ids] delivered and then deletes them. The ricochet server keeps
  /// a persistent message after it is marked delivered (it gains the seen
  /// flag and stays), and the protocol sends submissions persistent, so
  /// the delete is what makes a consumed message leave the folder.
  Future<void> _delivered(List<String> ids, String folder) async {
    if (ids.isEmpty) return;
    var marked = false;
    String? why;
    for (int attempt = 0; attempt <= sendRetries; attempt++) {
      try {
        if (!marked) {
          final ack = await _stream(AccessHandler.protocolId, (s) => AccessHandler.markDelivered(s, ids, folderPath: folder));
          marked = ack.success;
          if (!marked) why = ack.errorMessage ?? 'not acknowledged';
        }
        if (marked) {
          final gone = await _stream(AccessHandler.protocolId, (s) => AccessHandler.deleteMessages(s, ids));
          if (gone.success) return;
          why = gone.errorMessage ?? 'not deleted';
        }
      } catch (e) {
        why = '$e';
      }
      if (attempt < sendRetries) {
        await Future<void>.delayed(retryDelay);
        await reconnect();
      }
    }
    throw TransportFailure('mark ${ids.length} messages delivered in $folder', 'after ${sendRetries + 1} attempts: $why');
  }

  @override
  Future<void> reply(String peerId, Uint8List bytes) =>
      guarded(() => _send(PeerId.fromString(peerId), bytes, PoolTransport.repliesFolder, 'reply to $peerId'));

  Future<void> _send(PeerId to, Uint8List bytes, String folder, String what) async {
    if (bytes.length > PoolTransport.maxFrame) throw TransportFailure(what, '${bytes.length} bytes is over the transport\'s frame');
    String? why;
    for (int attempt = 0; attempt <= sendRetries; attempt++) {
      try {
        // sealing binds the ciphertext to the message id, so the id is
        // minted here and sent with the message
        final messageId = _uuid();
        final sealed = await encryptor.encryptBound(
            bytes, PayloadBinding.forMessage(recipientPeerId: to, folderPath: folder, messageId: messageId), to);
        final ack = await _stream(
            SubmissionHandler.protocolId,
            (s) => SubmissionHandler.submitMessage(s, to, sealed,
                folderPath: folder, persistent: true, messageId: messageId, flags: SFMessageFlags.none.withFlag(SFMessageFlags.encrypted)));
        if (ack.success) return;
        why = ack.errorMessage ?? 'the server did not store it';
      } catch (e) {
        why = '$e';
      }
      log.warning('$what, attempt ${attempt + 1} of ${sendRetries + 1}: $why');
      if (attempt < sendRetries) {
        await Future<void>.delayed(retryDelay);
        await reconnect();
      }
    }
    throw TransportFailure(what, why ?? 'the send failed');
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  @override
  Future<int> announce(Uint8List bytes) => guarded(() => _announce(bytes));

  Future<int> _announce(Uint8List bytes) async {
    if (bytes.length > PoolTransport.maxFrame) throw TransportFailure('announce', '${bytes.length} bytes is over the transport\'s frame');
    for (int attempt = 0; attempt <= sendRetries; attempt++) {
      final r = await client.appendFeedEntry(path: PoolTransport.feedPath, content: bytes, entryType: 'pool');
      if (r != null) return r.sequence;
      log.warning('announce, attempt ${attempt + 1} of ${sendRetries + 1}: the append failed');
      if (attempt < sendRetries) {
        await Future<void>.delayed(retryDelay);
        await reconnect();
      }
    }
    throw TransportFailure('announce', 'the feed append failed ${sendRetries + 1} times');
  }

  @override
  Future<List<FeedItem>> feed(int fromSequence, {int limit = 100}) => feedOf(host.id, fromSequence, limit: limit);

  /// Runs [f] in the transport's zone and hands its outcome back to the
  /// caller's: the completer lives in the caller's zone, so a failure of
  /// [f] reaches the caller, while a future inside [f] that nobody awaits
  /// fails into the zone's handler instead of the caller's.
  Future<T> guarded<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _zone.run(() {
      f().then(c.complete, onError: (Object e, StackTrace st) => c.completeError(e, st));
    });
    return c.future;
  }

  /// Whether this identity's feed exists on the server.
  Future<bool> feedExists() => guarded(() async {
          return await client.getFeed(ownerPeerId: host.id, path: PoolTransport.feedPath) != null;
      });

  @override
  Future<int> feedLength() => guarded(() async {
          final info = await client.getFeed(ownerPeerId: host.id, path: PoolTransport.feedPath);
        return info?.currentSequence ?? 0;
      });

  @override
  Future<void> ensureFeed() async {
    if (!await feedExists()) await createFeed();
  }

  /// Creates this identity's feed, once, before the descriptor goes on it.
  Future<void> createFeed() => guarded(() async {
          final r = await client.createFeed(
            path: PoolTransport.feedPath, title: 'pool rounds', description: 'the descriptor, then one announcement a round');
        if (r == null) throw TransportFailure('create the feed', 'the ricochet server did not create it');
      });

  // ---- the wallet's side, for the tests and a wallet client ----

  /// The feed of [owner] from [fromSequence] on.
  Future<List<FeedItem>> feedOf(PeerId owner, int fromSequence, {int limit = 100}) => guarded(() => _feedOf(owner, fromSequence, limit));

  Future<List<FeedItem>> _feedOf(PeerId owner, int fromSequence, int limit) async {
    final r = await client.getFeedEntries(ownerPeerId: owner, path: PoolTransport.feedPath, fromSequence: fromSequence, limit: limit);
    if (r == null) return const [];
    return [for (final e in r.entries) FeedItem(e.sequence, e.content)];
  }

  /// Sends [bytes] as a submission to [coordinator].
  Future<void> submit(String coordinator, Uint8List bytes) =>
      guarded(() => _send(PeerId.fromString(coordinator), bytes, PoolTransport.submissionsFolder, 'submit to $coordinator'));

  /// The replies in this identity's replies folder, marked delivered.
  Future<List<InboxMessage>> readReplies() => guarded(() async {
        final got = await _retrieve(PoolTransport.repliesFolder);
        if (got.isNotEmpty) await _delivered([for (final m in got) m.id], PoolTransport.repliesFolder);
        return got;
      });

  @override
  Future<void> close() => guarded(() async {
        try {
          await client.stop();
        } catch (_) {}
        try {
          await host.close();
        } catch (_) {}
      });
}
