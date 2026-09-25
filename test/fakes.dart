/// In-memory stand-ins for the four interfaces, so the server, the wallet
/// and the store can be tested without a node, a ricochet server or a
/// disk. Each records what it was asked, in order, since most of what the
/// specs say about the server is about the order things happen in.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// Every event the fakes see, in order: `broadcast <txid>`, `store <n>`,
/// `reply <peer>`, `announce <seq>`.
class EventLog {
  final events = <String>[];
  void add(String e) => events.add(e);
}

/// A chain that mines what it is given. Broadcasting mines at once unless
/// [mineOnBroadcast] is off, in which case [mine] does; [refuse] turns a
/// broadcast into a refusal with its reason.
class FakeChain implements ChainAccess {
  final EventLog log;
  final known = <String, Transaction>{};
  final minedAt = <String, int>{};
  final spentOutpoints = <String>{};
  final broadcasts = <String>[];
  int _height;
  bool mineOnBroadcast = true;
  String? Function(Transaction tx)? refuse;
  Future<void> Function(Transaction tx)? beforeBroadcast;
  int fetches = 0, unspentCalls = 0;

  FakeChain({EventLog? log, int height = 100})
      : log = log ?? EventLog(),
        _height = height;

  @override
  String get name => 'the fake chain';

  /// Adds [tx] as already mined, for a genesis or a deposit the test made.
  void addMined(Transaction tx) {
    known[tx.id] = tx;
    _mineOne(tx, _height);
  }

  /// Mines every known unconfirmed transaction into one new block.
  int mine() {
    _height++;
    for (final tx in known.values) {
      if (!minedAt.containsKey(tx.id)) _mineOne(tx, _height);
    }
    return _height;
  }

  void _mineOne(Transaction tx, int height) {
    minedAt[tx.id] = height;
    for (final i in tx.inputs) {
      spentOutpoints.add('${i.prevTxnId}:${i.prevTxnOutputIndex}');
    }
  }

  @override
  Future<Transaction?> fetch(String txid) async {
    fetches++;
    return known[txid];
  }

  @override
  Future<int> height() async => _height;

  /// A copy of this chain's state, for a test that starts from it.
  FakeChain clone({EventLog? log}) => FakeChain(log: log, height: _height)
    ..known.addAll(known)
    ..minedAt.addAll(minedAt)
    ..spentOutpoints.addAll(spentOutpoints);

  /// Forgets [txid] as if it had never been broadcast.
  void forget(String txid) {
    final tx = known.remove(txid);
    minedAt.remove(txid);
    if (tx != null) {
      for (final i in tx.inputs) {
        spentOutpoints.remove('${i.prevTxnId}:${i.prevTxnOutputIndex}');
      }
    }
  }

  /// Takes [tx] as another party broadcast it, not the server: known, its
  /// inputs spent, mined when the chain mines on broadcast, and not in
  /// [broadcasts]. The fake wallet's funding reaches the chain this way.
  void accept(Transaction tx) {
    known[tx.id] = tx;
    for (final i in tx.inputs) {
      spentOutpoints.add('${i.prevTxnId}:${i.prevTxnOutputIndex}');
    }
    if (mineOnBroadcast) _mineOne(tx, _height);
  }

  /// Drops [txid] from the mempool, as an eviction would: an unmined
  /// transaction is forgotten and its inputs are unspent again, and a
  /// broadcast of it later is taken afresh. A mined one is left alone.
  bool drop(String txid) {
    if (minedAt.containsKey(txid) || !known.containsKey(txid)) return false;
    forget(txid);
    dropped.add(txid);
    return true;
  }

  final dropped = <String>[];

  @override
  Future<String> broadcast(Transaction tx) async {
    await beforeBroadcast?.call(tx);
    final why = refuse?.call(tx);
    if (why != null) throw BroadcastRefusal(name, why);
    broadcasts.add(tx.id);
    log.add('broadcast ${tx.id}');
    known[tx.id] = tx;
    // accepted into the mempool: its inputs are spent from now on, mined
    // or not, as a node's mempool would have them
    for (final i in tx.inputs) {
      spentOutpoints.add('${i.prevTxnId}:${i.prevTxnOutputIndex}');
    }
    if (mineOnBroadcast) _mineOne(tx, ++_height);
    return 'fake';
  }

  @override
  Future<int?> minedHeight(String txid) async => minedAt[txid];

  /// The transactions mined at [height], in the order they were mined:
  /// the fake chain's block there.
  List<String> blockAt(int height) => [for (final e in minedAt.entries) if (e.value == height) e.key];

  /// A made-up hash for the block at [height]; nothing checks it but the
  /// tests, which compare branches with [merkleRootAt].
  static String blockHashAt(int height) => height.toRadixString(16).padLeft(64, '0');

  String merkleRootAt(int height) {
    final txs = blockAt(height);
    return TxPlace.rootOf(txs.first, 0, TxPlace.branchFor(txs, 0));
  }

  @override
  Future<TxPlace?> placeOf(String txid) async {
    final h = minedAt[txid];
    if (h == null) return null;
    final txs = blockAt(h);
    final i = txs.indexOf(txid);
    return TxPlace(blockHashAt(h), i, TxPlace.branchFor(txs, i));
  }

  @override
  Future<bool> unspent(String txid, int vout) async {
    unspentCalls++;
    final tx = known[txid];
    if (tx == null || vout >= tx.outputs.length) return false;
    return !spentOutpoints.contains('$txid:$vout');
  }

  /// Whether [unspentOf] lists unmined outputs as well, as WhatsOnChain's
  /// `unspent/all` does on testnet; by default it lists mined ones only.
  bool listUnmined = false;

  @override
  Future<List<UnspentOutput>> unspentOf(Address address) async {
    final pkh = address.pubkeyHash160;
    final out = <UnspentOutput>[];
    for (final tx in known.values) {
      if (!listUnmined && !minedAt.containsKey(tx.id)) continue;
      for (int v = 0; v < tx.outputs.length; v++) {
        if (spentOutpoints.contains('${tx.id}:$v')) continue;
        if (paysPKH(tx.outputs[v], pkh)) out.add(UnspentOutput(tx.id, v, tx.outputs[v].satoshis, height: minedAt[tx.id]));
      }
    }
    return out;
  }

  static bool paysPKH(TransactionOutput o, String pkhHex) {
    final s = o.script.buffer;
    return s.length == 25 && s[0] == 0x76 && s[1] == 0xa9 && hex.encode(s.sublist(3, 23)) == pkhHex;
  }
}

/// A wallet that mints an output of exactly the value asked, paid to the
/// owner's key, as the library's own tests do. It keeps a balance so a
/// server test can see it fall, and can be told to refuse.
class FakeWallet implements CoordinatorWallet {
  @override
  final TransactionSigner owner;
  @override
  final SVPublicKey ownerPub;
  @override
  final Address address;
  final asked = <BigInt>[];

  /// When each request was answered, which a test polling [asked] can see
  /// late: the library proves on this isolate right after.
  final askedAt = <DateTime>[];
  final given = <Transaction>[];
  bool dead = false;
  int? failAt;
  @override
  FundingKind Function()? requestKind;
  @override
  Future<void> Function()? beforeRequest;
  @override
  BigInt balance;
  @override
  BigInt? lastRoundCost;
  int reconciles = 0;

  /// How long a funding request takes, standing in for the broadcast a
  /// real wallet waits on; zero still yields once.
  final Duration delay;

  /// Called with each funding transaction handed out, as a real wallet
  /// broadcasts it: a server test puts it on its fake chain.
  void Function(Transaction tx)? onGiven;

  FakeWallet(this.owner, this.ownerPub, this.address, {BigInt? balance, this.delay = Duration.zero})
      : balance = balance ?? BigInt.from(100000000);

  @override
  Future<FundingOutput?> output(BigInt minValue) async {
    // a real wallet broadcasts and waits for a block here, which is what
    // lets the reply to the round-filling submission out before the
    // build's proving takes the isolate; the fake yields once for the same
    await beforeRequest?.call();
    await Future<void>.delayed(delay);
    final n = asked.length;
    asked.add(minValue);
    askedAt.add(DateTime.now());
    if (dead || failAt == n) return null;
    if (minValue > balance) throw WalletRefusal('the wallet holds $balance satoshis, the request needs $minValue');
    final prev = List.filled(32, 0x50)
      ..[0] = n & 0xff
      ..[1] = n >> 8;
    final tx = Transaction()
      ..version = 1
      ..nLockTime = 0
      ..addInput(TransactionInput(hex.encode(prev), 0, TransactionInput.MAX_SEQ_NUMBER))
      ..addOutput(TransactionOutput(minValue, P2PKHLockBuilder.fromAddress(address).getScriptPubkey()));
    given.add(tx);
    onGiven?.call(tx);
    balance -= minValue;
    return FundingOutput(tx, 0, owner, ownerPub);
  }

  @override
  List<Transaction> fundingOf(List<Transaction> spenders) {
    final ids = {for (final s in spenders) for (final i in s.inputs) i.prevTxnId};
    return [for (final t in given) if (ids.contains(t.id)) t];
  }

  @override
  int? get roundsLeft => lastRoundCost == null || lastRoundCost == BigInt.zero ? null : (balance ~/ lastRoundCost!).toInt();

  @override
  WalletReport get report =>
      WalletReport(balance: balance, lastRoundCost: lastRoundCost, roundsLeft: roundsLeft, coins: 1, offered: 0);

  @override
  Future<void> reconcile({Iterable<Transaction> roundTxs = const []}) async => reconciles++;
}

/// A store in memory. [roundBuilt] logs `store <n>` so a test can check
/// it came before the first broadcast.
class FakeStore extends RoundStore {
  final EventLog log;
  final rounds = <int, StoredRound>{};
  FakeStore({EventLog? log}) : log = log ?? EventLog();

  @override
  Future<void> roundBuiltWith(int number, Transaction y, Transaction round, Transaction witness, Uint8List snapshot,
      {List<Transaction> funding = const []}) async {
    log.add('store $number');
    rounds[number] = StoredRound(number, y, round, witness, Uint8List.fromList(snapshot), funding: funding);
  }

  @override
  Future<int?> lastNumber() async => rounds.isEmpty ? null : rounds.keys.reduce((a, b) => a > b ? a : b);

  @override
  Future<StoredRound?> read(int number) async => rounds[number];
}

/// A transport whose inbox a test fills with [send], whose replies it
/// reads per peer, and whose feed is a list. A send can be made to fail
/// for a number of attempts, to see the retries.
class FakeTransport implements PoolTransport {
  final EventLog log;
  @override
  final String peerId;
  final _inbox = <InboxMessage>[];
  final deliveredIds = <String>[];
  final replies = <String, List<Uint8List>>{};
  final entries = <Uint8List>[];
  final replyAttempts = <String, int>{};

  /// When each peer's first reply reached the transport, which is when it
  /// was answered; a test polling for it in the same isolate may see it
  /// later, when proving lets its timer run.
  final repliedAt = <String, DateTime>{};
  final sentAt = <String, DateTime>{};
  int _next = 0;
  int batch;

  /// Sends that fail before one succeeds: each reply or announce consumes
  /// this many failures first.
  int failNextSends = 0;

  /// Peers whose replies take this long to send, as a slow link would.
  final slowPeers = <String, Duration>{};
  int retries;
  bool closed = false;

  FakeTransport({EventLog? log, this.peerId = 'coordinator', this.batch = 100, this.retries = 3}) : log = log ?? EventLog();

  /// A wallet sending [payload] from [sender].
  String send(String sender, List<int> payload) {
    final id = 'm${_next++}';
    sentAt.putIfAbsent(sender, DateTime.now);
    _inbox.add(InboxMessage(id, sender, Uint8List.fromList(payload)));
    return id;
  }

  int get undelivered => _inbox.length;

  @override
  Future<List<InboxMessage>> drain() async => _inbox.take(batch).toList();

  @override
  Future<void> delivered(List<String> ids) async {
    _inbox.removeWhere((m) => ids.contains(m.id));
    deliveredIds.addAll(ids);
  }

  Future<void> _attempt(String what) async {
    for (int attempt = 0; attempt <= retries; attempt++) {
      if (failNextSends > 0) {
        failNextSends--;
        continue;
      }
      return;
    }
    throw TransportFailure(what, 'the fake transport failed ${retries + 1} times');
  }

  @override
  Future<void> reply(String peerId, Uint8List bytes) async {
    replyAttempts[peerId] = (replyAttempts[peerId] ?? 0) + 1;
    await _attempt('reply to $peerId');
    final slow = slowPeers[peerId];
    if (slow != null) await Future<void>.delayed(slow);
    replies.putIfAbsent(peerId, () => []).add(bytes);
    repliedAt.putIfAbsent(peerId, DateTime.now);
    log.add('reply $peerId');
  }

  /// What each peer was sent unasked, apart from its replies.
  final notices = <String, List<Uint8List>>{};

  @override
  Future<void> notify(String peerId, Uint8List bytes) async {
    await _attempt('notice to $peerId');
    notices.putIfAbsent(peerId, () => []).add(bytes);
    log.add('notice $peerId');
  }

  @override
  Future<int> announce(Uint8List bytes) async {
    await _attempt('announce');
    entries.add(bytes);
    log.add('announce ${entries.length}');
    return entries.length;
  }

  @override
  Future<List<FeedItem>> feed(int fromSequence, {int limit = 100}) async => [
        for (int s = fromSequence; s <= entries.length && s - fromSequence < limit; s++)
          if (s >= 1) FeedItem(s, entries[s - 1])
      ];

  @override
  Future<int> feedLength() async => entries.length;

  bool feedCreated = false;

  @override
  Future<void> ensureFeed() async => feedCreated = true;

  @override
  Future<void> close() async => closed = true;
}
