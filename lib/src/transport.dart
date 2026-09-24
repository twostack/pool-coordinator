import 'dart:typed_data';

/// A send the transport gave up on after its retries. The server records
/// it in the status with what it was sending.
class TransportFailure implements Exception {
  final String what;
  final String reason;
  const TransportFailure(this.what, this.reason);
  @override
  String toString() => '$what: $reason';
}

/// One message from the submissions folder: the transport's id (what is
/// marked delivered), who sent it, and the payload as bytes the server
/// treats as hostile.
class InboxMessage {
  final String id;
  final String sender;
  final Uint8List payload;
  const InboxMessage(this.id, this.sender, this.payload);
}

/// One entry of the pool's feed.
class FeedItem {
  final int sequence;
  final Uint8List content;
  const FeedItem(this.sequence, this.content);
}

/// How the pool's messages ride the transport. Submissions are read
/// from one folder of the coordinator's mailbox and marked delivered once
/// consumed, so the mailbox never fills; a reply goes to the sender's
/// mailbox; the descriptor and every announcement go on one public feed a
/// wallet reads by sequence. Nothing here knows what the bytes mean: the
/// server decodes them as the library does.
abstract class PoolTransport {
  /// The folder wallets submit to, and the folder replies go to, under the
  /// respective peer's mailbox. Fixed, so a wallet knows where to write
  /// and read.
  static const submissionsFolder = 'pool/submissions';
  static const repliesFolder = 'pool/replies';

  /// The folder a peer is sent what it did not ask for: the mined-round
  /// notice. Apart from the replies folder, which holds only answers to
  /// what the peer sent, so a wallet waiting on an answer never takes a
  /// notice for it.
  static const noticesFolder = 'pool/notices';

  /// The feed under the coordinator's peer id.
  static const feedPath = 'pool/rounds';

  /// The largest message the transport carries in one frame.
  static const maxFrame = 10 * 1024 * 1024;

  /// The coordinator's own peer id, which is what wallets address.
  String get peerId;

  /// The next batch of undelivered submissions, oldest first; empty when
  /// there are none. Nothing is marked delivered by this.
  Future<List<InboxMessage>> drain();

  /// Marks [ids] delivered, which takes them out of the folder.
  Future<void> delivered(List<String> ids);

  /// Sends [bytes] as one reply to [peerId]'s replies folder, encrypted to
  /// that peer. Retries a failed send up to the configured count, then
  /// throws [TransportFailure].
  Future<void> reply(String peerId, Uint8List bytes);

  /// Sends [bytes] to [peerId]'s notices folder, as [reply] does.
  Future<void> notify(String peerId, Uint8List bytes);

  /// Appends [bytes] to the pool's feed and returns its sequence. Retries a
  /// failed append up to the configured count, then throws
  /// [TransportFailure].
  Future<int> announce(Uint8List bytes);

  /// The feed's entries from [fromSequence] on, at most [limit].
  Future<List<FeedItem>> feed(int fromSequence, {int limit = 100});

  /// The sequence of the feed's last entry, 0 when it is empty or does not
  /// exist yet.
  Future<int> feedLength();

  /// Creates the feed under this identity, before the descriptor goes on
  /// it. A feed that exists is left as it is.
  Future<void> ensureFeed();

  Future<void> close();
}
