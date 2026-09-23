import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A Go ricochet server started for a test: the binary at
/// `../go-ricochet/ricochet` against a database this creates on localnet's
/// PostgreSQL and drops afterwards. [start] returns null, with [skipReason]
/// set, when the binary or the database is not there.
class RicochetTestServer {
  static const binary = '../go-ricochet/ricochet';
  static const buildCommand = 'cd ../go-ricochet && GOTOOLCHAIN=go1.25.7 go build -o ricochet ./cmd/ricochet';
  static String get adminUrl => Platform.environment['POOL_RICOCHET_PG'] ?? 'postgresql://monocelo:monocelo@localhost:5433/postgres';

  final String database;
  final int port;
  final Directory dataDir;
  Process? _process;
  String? peerId;
  final _log = StringBuffer();

  RicochetTestServer._(this.database, this.port, this.dataDir);

  /// The server's address with its peer id.
  String get address => '/ip4/127.0.0.1/udp/$port/udx/p2p/$peerId';

  String get log => _log.toString();

  static String? skipReason;

  /// Why the tests would be skipped, or null when a server can be started.
  static Future<String?> available() async {
    if (!File(binary).existsSync()) return 'no ricochet server binary at $binary; build it: $buildCommand';
    final psql = await Process.run('psql', [adminUrl, '-q', '-A', '-t', '-c', 'select 1']);
    if (psql.exitCode != 0) return 'no PostgreSQL at $adminUrl (${psql.stderr.toString().trim()}); start ../localnet or set POOL_RICOCHET_PG';
    return null;
  }

  static Future<RicochetTestServer?> start() async {
    skipReason = await available();
    if (skipReason != null) return null;
    final rng = Random();
    final db = 'pool_ricochet_${rng.nextInt(1 << 30).toRadixString(16)}';
    await _psql(adminUrl, ['-c', 'CREATE DATABASE $db']);
    final dbUrl = adminUrl.replaceFirst(RegExp(r'/[^/]*$'), '/$db');
    await _psql(dbUrl, ['-f', '../go-ricochet/schema.sql']);
    final s = RicochetTestServer._(db, 40000 + rng.nextInt(20000), Directory.systemTemp.createTempSync('pool-ricochet'));
    await s.launch();
    return s;
  }

  static Future<void> _psql(String url, List<String> args) async {
    final r = await Process.run('psql', [url, '-q', '-v', 'ON_ERROR_STOP=1', ...args]);
    if (r.exitCode != 0) throw StateError('psql ${args.join(' ')}: ${r.stderr}');
  }

  /// Starts (or restarts, on the same data directory and database, so the
  /// peer id and the stored messages are the same) the server process.
  Future<void> launch() async {
    final u = Uri.parse(adminUrl);
    final proc = await Process.start(
        binary,
        [
          '--development',
          '--port',
          '$port',
          '--pg-host',
          u.host,
          '--pg-port',
          '${u.port == 0 ? 5432 : u.port}',
          '--pg-database',
          database,
          '--pg-username',
          u.userInfo.split(':').first,
          '--pg-sslmode',
          'disable',
          '--data-dir',
          dataDir.path,
        ],
        environment: {'RICOCHET_PG_PASSWORD': u.userInfo.contains(':') ? u.userInfo.split(':').last : ''});
    _process = proc;
    final started = Completer<void>();
    void watch(Stream<List<int>> s) {
      s.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        _log.writeln(line);
        final m = RegExp(r'msg="server started" peer_id=(\S+)').firstMatch(line);
        if (m != null && !started.isCompleted) {
          peerId = m.group(1);
          started.complete();
        }
        if (line.contains('level=ERROR msg="failed to start server"') && !started.isCompleted) {
          started.completeError(StateError('the ricochet server did not start: $line'));
        }
      });
    }

    watch(proc.stdout);
    watch(proc.stderr);
    await started.future.timeout(const Duration(seconds: 30), onTimeout: () => throw StateError('the ricochet server did not report starting:\n$_log'));
    // the listener is up once reported; a moment for the UDX socket
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  /// Stops the process; the database and data directory stay, so [launch]
  /// brings the same server back.
  Future<void> stop() async {
    final p = _process;
    if (p == null) return;
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
    _process = null;
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _psql(adminUrl, ['-c', 'DROP DATABASE IF EXISTS $database']);
    } catch (_) {}
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
