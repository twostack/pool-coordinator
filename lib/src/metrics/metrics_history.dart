import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// One round as the history holds it. Everything here is either on the
/// chain or the feed already (the txids, the real transfer count, the
/// header's balance, the mined height), or a measure of the coordinator's
/// own work (the durations, the cost it paid). Nothing is per submission.
///
/// A row rebuilt from the store has no cost, durations or times: the store
/// keeps none of them, and a time invented at rebuild would put every old
/// round in the hour of the rebuild.
class RoundRecord {
  final int number;
  final String y, round, witness;
  final int transfers, capacity;

  /// The pool's balance in the round's header, in satoshis.
  final int balance;

  /// What the round cost the coordinator's wallet, in satoshis.
  final int? cost;

  /// Milliseconds from close to the round stored, and of proving within
  /// that (the aggregation and what feeds it).
  final int? buildMs, provingMs;

  final DateTime? publishedAt;
  final int? minedHeight;
  final DateTime? minedAt;

  const RoundRecord({
    required this.number,
    required this.y,
    required this.round,
    required this.witness,
    required this.transfers,
    required this.capacity,
    required this.balance,
    this.cost,
    this.buildMs,
    this.provingMs,
    this.publishedAt,
    this.minedHeight,
    this.minedAt,
  });

  bool get mined => minedHeight != null;

  static RoundRecord _of(Row r) => RoundRecord(
        number: r['number'] as int,
        y: r['y'] as String,
        round: r['round'] as String,
        witness: r['witness'] as String,
        transfers: r['transfers'] as int,
        capacity: r['capacity'] as int,
        balance: r['balance'] as int,
        cost: r['cost'] as int?,
        buildMs: r['build_ms'] as int?,
        provingMs: r['proving_ms'] as int?,
        publishedAt: _time(r['published_at'] as int?),
        minedHeight: r['mined_height'] as int?,
        minedAt: _time(r['mined_at'] as int?),
      );

  static DateTime? _time(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  @override
  bool operator ==(Object other) =>
      other is RoundRecord &&
      other.number == number &&
      other.y == y &&
      other.round == round &&
      other.witness == witness &&
      other.transfers == transfers &&
      other.capacity == capacity &&
      other.balance == balance &&
      other.cost == cost &&
      other.buildMs == buildMs &&
      other.provingMs == provingMs &&
      other.publishedAt == publishedAt &&
      other.minedHeight == minedHeight &&
      other.minedAt == minedAt;

  @override
  int get hashCode => Object.hash(number, y, round, witness, transfers, balance, minedHeight);

  @override
  String toString() => 'round $number: $transfers/$capacity real, balance $balance, mined ${minedHeight ?? '-'}';
}

/// The pool's figures over its recent rounds, as the page's tiles show them.
/// A figure the history cannot give yet (no cost recorded, fewer than two
/// timed rounds) is null rather than zero.
class PoolStats {
  final int roundsMined, transfers;
  final int? tip;
  final Duration? medianInterval, medianProving;
  final int? meanCost;
  final DateTime? firstPublished;
  const PoolStats({
    required this.roundsMined,
    required this.transfers,
    required this.tip,
    required this.medianInterval,
    required this.medianProving,
    required this.meanCost,
    required this.firstPublished,
  });
}

enum SeriesMetric { rounds, transfers, balance, cost, proving }

enum SeriesBucket {
  hour(Duration(hours: 1)),
  day(Duration(days: 1));

  final Duration width;
  const SeriesBucket(this.width);
}

/// One bucket of a series: its start and its value.
typedef SeriesPoint = ({DateTime at, num value});

/// The coordinator's history of rounds, in one SQLite file.
///
/// The file is a cache of what the store, the feed and the chain already
/// hold, plus the durations and costs only this process measured, so it is
/// treated as disposable: one it cannot read, or of another schema version,
/// is moved aside and a fresh one started, and the server rebuilds what it
/// can. The server's rounds never wait on it.
class MetricsHistory {
  static const schemaVersion = 1;

  /// The recent rounds the medians and the mean are taken over.
  static const statsWindow = 50;

  /// The most rounds one page reads and the most points one series returns.
  static const maxPage = 100, maxPoints = 1000;

  final Database _db;
  final String path;

  /// The file this history found unusable and moved aside when it opened,
  /// for the log.
  final String? movedAside;

  MetricsHistory._(this._db, this.path, this.movedAside);

  /// Opens the history at [path], or starts one, moving aside a file that
  /// is not a history of this version.
  static MetricsHistory open(String path) {
    String? aside;
    var db = sqlite3.open(path);
    if (!_usable(db)) {
      db.dispose();
      aside = '$path.unusable-${DateTime.now().toUtc().millisecondsSinceEpoch}';
      File(path).renameSync(aside);
      for (final suffix in ['-wal', '-shm']) {
        final f = File('$path$suffix');
        if (f.existsSync()) f.deleteSync();
      }
      db = sqlite3.open(path);
    }
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    if (db.userVersion == 0) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS rounds (
          number INTEGER PRIMARY KEY,
          y TEXT NOT NULL,
          round TEXT NOT NULL,
          witness TEXT NOT NULL,
          transfers INTEGER NOT NULL,
          capacity INTEGER NOT NULL,
          balance INTEGER NOT NULL,
          cost INTEGER,
          build_ms INTEGER,
          proving_ms INTEGER,
          published_at INTEGER,
          mined_height INTEGER,
          mined_at INTEGER
        )''');
      db.execute('CREATE INDEX IF NOT EXISTS rounds_published ON rounds (published_at)');
      db.userVersion = schemaVersion;
    }
    return MetricsHistory._(db, path, aside);
  }

  /// Opens a history the recorder has already opened, for reading beside
  /// it (WAL lets one connection read while another writes). Never moves
  /// or creates anything: that is the recorder's to do.
  static MetricsHistory attach(String path) {
    if (!File(path).existsSync()) throw StateError('no pool history at $path');
    final db = sqlite3.open(path);
    if (db.userVersion != schemaVersion) {
      db.dispose();
      throw StateError('the pool history at $path is version ${db.userVersion}, not $schemaVersion');
    }
    return MetricsHistory._(db, path, null);
  }

  /// A new file (version 0, no tables), or one of this version whose table
  /// reads; anything else is not ours to use.
  static bool _usable(Database db) {
    try {
      final v = db.userVersion;
      if (v == 0) return db.select("SELECT name FROM sqlite_master WHERE type = 'table'").isEmpty;
      if (v != schemaVersion) return false;
      db.select('SELECT number FROM rounds LIMIT 1');
      return true;
    } on SqliteException {
      return false;
    }
  }

  void close() => _db.dispose();

  static int? _ms(DateTime? t) => t?.millisecondsSinceEpoch;

  /// Records [r], replacing what the history held for its number, since the
  /// server's own measurement of a round beats a row rebuilt without one.
  void record(RoundRecord r) => _put(r, 'INSERT OR REPLACE');

  /// Records [r] only when the history has no row for its number: what a
  /// rebuild writes, so it never overwrites a measured row.
  void recordIfAbsent(RoundRecord r) => _put(r, 'INSERT OR IGNORE');

  void _put(RoundRecord r, String verb) => _db.execute(
        '$verb INTO rounds (number, y, round, witness, transfers, capacity, balance, cost, build_ms, proving_ms, '
        'published_at, mined_height, mined_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          r.number, r.y, r.round, r.witness, r.transfers, r.capacity, r.balance, r.cost, r.buildMs, r.provingMs, //
          _ms(r.publishedAt), r.minedHeight, _ms(r.minedAt),
        ],
      );

  void setCost(int number, int cost) => _db.execute('UPDATE rounds SET cost = ? WHERE number = ?', [cost, number]);

  /// Names the height round [number]'s witness was mined at, and when this
  /// process saw it, if it knows (a row rebuilt without times gets none).
  void setMined(int number, int height, DateTime? at) =>
      _db.execute('UPDATE rounds SET mined_height = ?, mined_at = ? WHERE number = ?', [height, _ms(at), number]);

  RoundRecord? read(int number) {
    final rows = _db.select('SELECT * FROM rounds WHERE number = ?', [number]);
    return rows.isEmpty ? null : RoundRecord._of(rows.single);
  }

  /// Every round number the history holds, ascending.
  List<int> numbers() => [for (final r in _db.select('SELECT number FROM rounds ORDER BY number')) r['number'] as int];

  /// The rounds whose witness is not known to be mined, oldest first.
  List<RoundRecord> unmined() =>
      [for (final r in _db.select('SELECT * FROM rounds WHERE mined_height IS NULL ORDER BY number')) RoundRecord._of(r)];

  /// Up to [limit] rounds numbered below [before] (the newest when null),
  /// newest first. [limit] is clamped to 1..[maxPage].
  List<RoundRecord> page({int? before, int limit = 20}) {
    final n = limit.clamp(1, maxPage);
    final rows = before == null
        ? _db.select('SELECT * FROM rounds ORDER BY number DESC LIMIT ?', [n])
        : _db.select('SELECT * FROM rounds WHERE number < ? ORDER BY number DESC LIMIT ?', [before, n]);
    return [for (final r in rows) RoundRecord._of(r)];
  }

  PoolStats stats() {
    final totals = _db.select('SELECT COUNT(mined_height) AS mined, COALESCE(SUM(transfers), 0) AS transfers, MAX(number) AS tip, '
            'MIN(published_at) AS first FROM rounds')
        .single;
    final recent = page(limit: statsWindow + 1);
    // intervals only between consecutive rounds both timed by this process
    final gaps = <int>[];
    for (int i = 0; i + 1 < recent.length; i++) {
      final a = recent[i], b = recent[i + 1];
      if (a.number == b.number + 1 && a.publishedAt != null && b.publishedAt != null) {
        gaps.add(a.publishedAt!.difference(b.publishedAt!).inMilliseconds);
      }
    }
    final window = recent.take(statsWindow);
    final proving = [for (final r in window) if (r.provingMs != null) r.provingMs!];
    final costs = [for (final r in window) if (r.cost != null) r.cost!];
    return PoolStats(
      roundsMined: totals['mined'] as int,
      transfers: totals['transfers'] as int,
      tip: totals['tip'] as int?,
      medianInterval: _median(gaps),
      medianProving: _median(proving),
      meanCost: costs.isEmpty ? null : (costs.reduce((a, b) => a + b) / costs.length).round(),
      firstPublished: RoundRecord._time(totals['first'] as int?),
    );
  }

  static Duration? _median(List<int> ms) {
    if (ms.isEmpty) return null;
    final s = [...ms]..sort();
    final mid = s.length ~/ 2;
    return Duration(milliseconds: s.length.isOdd ? s[mid] : ((s[mid - 1] + s[mid]) / 2).round());
  }

  /// [metric] per [bucket] from [from] (inclusive) to [to] (exclusive), over
  /// rounds this process timed, empty buckets left out. At most [maxPoints]
  /// points, the newest kept when the range holds more.
  List<SeriesPoint> series(SeriesMetric metric, SeriesBucket bucket, {required DateTime from, required DateTime to}) {
    final w = bucket.width.inMilliseconds;
    final value = switch (metric) {
      SeriesMetric.rounds => 'COUNT(*)',
      SeriesMetric.transfers => 'SUM(transfers)',
      // the balance at the end of the bucket: SQLite takes a bare column
      // from the row MAX(number) picks, which is the bucket's last round
      SeriesMetric.balance => 'balance',
      SeriesMetric.cost => 'AVG(cost)',
      SeriesMetric.proving => 'AVG(proving_ms)',
    };
    final rows = _db.select(
      'SELECT (published_at / ?) * ? AS at, $value AS value, MAX(number) AS last FROM rounds '
      'WHERE published_at >= ? AND published_at < ? GROUP BY at HAVING value IS NOT NULL ORDER BY at DESC LIMIT ?',
      [w, w, _ms(from), _ms(to), maxPoints],
    );
    return [
      for (final r in rows.reversed) (at: DateTime.fromMillisecondsSinceEpoch(r['at'] as int, isUtc: true), value: r['value'] as num),
    ];
  }
}
