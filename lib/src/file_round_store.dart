import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart';
import 'package:path/path.dart' as p;

import 'round_store.dart';

/// The store as a directory per round: `rounds/000001/` holds `y.tx`,
/// `round.tx` and `witness.tx` as raw bytes, `snapshot.bin` as the
/// library's snapshot, and `round.json`, a small versioned record of the
/// number and the three txids. Five files an operator can inspect and copy
/// beat a database, and the library's snapshot is already the canonical
/// state.
///
/// Every file is written to a temporary name and renamed, so it is whole
/// or absent; the record is written last, so a round with a record has
/// its files. Reading checks each transaction against the txid the record
/// names, which is what catches a file cut short.
class FileRoundStore extends RoundStore {
  static const recordVersion = 1;
  static const _files = ['y.tx', 'round.tx', 'witness.tx', 'snapshot.bin', 'round.json'];

  final String directory;

  /// Snapshots kept behind the last round; 0 keeps only the last. Every
  /// round's transactions are kept whatever this is, since a reader may
  /// still ask for them.
  final int keepSnapshots;

  FileRoundStore(this.directory, {this.keepSnapshots = 10});

  String get _rounds => p.join(directory, 'rounds');
  String _dir(int n) => p.join(_rounds, n.toString().padLeft(6, '0'));

  @override
  Future<void> roundBuilt(int number, Transaction y, Transaction round, Transaction witness, Uint8List snapshot) async {
    final dir = Directory(_dir(number));
    await dir.create(recursive: true);
    await _put(p.join(dir.path, 'y.tx'), hex.decode(y.serialize()));
    await _put(p.join(dir.path, 'round.tx'), hex.decode(round.serialize()));
    await _put(p.join(dir.path, 'witness.tx'), hex.decode(witness.serialize()));
    await _put(p.join(dir.path, 'snapshot.bin'), snapshot);
    final record = {'version': recordVersion, 'number': number, 'y': y.id, 'round': round.id, 'witness': witness.id};
    await _put(p.join(dir.path, 'round.json'), utf8.encode('${jsonEncode(record)}\n'));
    await prune(number);
  }

  static Future<void> _put(String path, List<int> bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }

  /// Deletes the snapshots of rounds at or below [last] minus
  /// [keepSnapshots], keeping every transaction.
  Future<void> prune(int last) async {
    final cutoff = last - keepSnapshots;
    if (cutoff < 1) return;
    for (final n in await _numbers()) {
      if (n > cutoff) continue;
      final f = File(p.join(_dir(n), 'snapshot.bin'));
      if (f.existsSync()) await f.delete();
    }
  }

  Future<List<int>> _numbers() async {
    final root = Directory(_rounds);
    if (!root.existsSync()) return const [];
    final out = <int>[];
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final n = int.tryParse(p.basename(e.path));
      if (n != null && File(p.join(e.path, 'round.json')).existsSync()) out.add(n);
    }
    return out..sort();
  }

  @override
  Future<int?> lastNumber() async {
    final ns = await _numbers();
    return ns.isEmpty ? null : ns.last;
  }

  @override
  Future<StoredRound?> read(int number) async {
    final dir = _dir(number);
    final recordFile = File(p.join(dir, 'round.json'));
    if (!recordFile.existsSync()) return null;
    final Map<String, dynamic> record;
    try {
      record = jsonDecode(await recordFile.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      throw StoreRefusal(number, 'round.json', 'is not a round record ($e)');
    }
    final v = record['version'];
    if (v != recordVersion) throw StoreRefusal(number, 'round.json', 'is version $v, and this server writes version $recordVersion');
    if (record['number'] != number) throw StoreRefusal(number, 'round.json', 'records round ${record['number']}');
    Future<Transaction> tx(String file, String key) async {
      final id = record[key];
      if (id is! String) throw StoreRefusal(number, 'round.json', 'names no $key txid');
      final f = File(p.join(dir, file));
      if (!f.existsSync()) throw StoreRefusal(number, file, 'is missing');
      final bytes = await f.readAsBytes();
      final Transaction t;
      try {
        t = Transaction.fromHex(hex.encode(bytes));
      } catch (e) {
        throw StoreRefusal(number, file, 'does not parse as a transaction; it may be cut short ($e)');
      }
      if (t.id != id) throw StoreRefusal(number, file, 'is transaction ${t.id}, and the record names $id; it may be cut short');
      if (hex.decode(t.serialize()).length != bytes.length) throw StoreRefusal(number, file, 'has ${bytes.length} bytes, more than the transaction');
      return t;
    }

    final y = await tx('y.tx', 'y');
    final round = await tx('round.tx', 'round');
    final witness = await tx('witness.tx', 'witness');
    final snap = File(p.join(dir, 'snapshot.bin'));
    final snapshot = snap.existsSync() ? await snap.readAsBytes() : null;
    return StoredRound(number, y, round, witness, snapshot);
  }

  Future<Map<String, dynamic>?> _record(int number) async {
    final f = File(p.join(_dir(number), 'round.json'));
    if (!f.existsSync()) return null;
    try {
      final r = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (r['version'] != recordVersion || r['number'] != number) throw const FormatException('another record');
      return r;
    } catch (e) {
      throw StoreRefusal(number, 'round.json', 'is not a round record of this server ($e)');
    }
  }

  /// The record alone, no transaction parsed.
  @override
  Future<({String round, String witness})?> txidsOf(int number) async {
    final r = await _record(number);
    if (r == null) return null;
    final round = r['round'], witness = r['witness'];
    if (round is! String || witness is! String) throw StoreRefusal(number, 'round.json', 'names no round or witness txid');
    return (round: round, witness: witness);
  }

  /// The files as they are, each checked by hashing it against the txid
  /// the record names (tens of milliseconds for a production witness,
  /// where parsing it takes about a second).
  @override
  Future<({Uint8List round, Uint8List witness})?> rawOf(int number) async {
    final ids = await txidsOf(number);
    if (ids == null) return null;
    Future<Uint8List> raw(String file, String id) async {
      final f = File(p.join(_dir(number), file));
      if (!f.existsSync()) throw StoreRefusal(number, file, 'is missing');
      final bytes = await f.readAsBytes();
      final got = hex.encode(crypto.sha256.convert(crypto.sha256.convert(bytes).bytes).bytes.reversed.toList());
      if (got != id) throw StoreRefusal(number, file, 'hashes to $got, and the record names $id; it may be cut short');
      return bytes;
    }

    return (round: await raw('round.tx', ids.round), witness: await raw('witness.tx', ids.witness));
  }

  /// Whether round [number]'s files are all present, for a test that asks
  /// at the moment of the first broadcast.
  bool complete(int number) => _files.every((f) => File(p.join(_dir(number), f)).existsSync());
}
