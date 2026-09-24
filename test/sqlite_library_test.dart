import 'dart:io';
import 'dart:isolate';

import 'package:pool_coordinator/src/metrics/metrics_history.dart';
import 'package:pool_coordinator/src/metrics/sqlite_library.dart';
import 'package:test/test.dart';

/// The history is opened in the server's isolate and attached in the API's,
/// and each isolate has its own copy of the sqlite3 package's loader. An
/// isolate that opens the history without the runtime library's name would,
/// on a Linux install without libsqlite3-dev, lose the API at start.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('sqlite_library'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // The name a runtime install has; elsewhere, whichever library opened.
  final Matcher expected = Platform.isLinux ? equals('libsqlite3.so.0') : isNotNull;

  test('opening the history loads the runtime library', () {
    final h = MetricsHistory.open('${tmp.path}/history.db');
    h.close();
    expect(sqliteLibrary, expected);
  });

  test('attaching in another isolate loads it there too', () async {
    final path = '${tmp.path}/history.db';
    MetricsHistory.open(path).close();
    final there = await Isolate.run(() {
      final before = sqliteLibrary;
      MetricsHistory.attach(path).close();
      return (before, sqliteLibrary);
    });
    expect(there.$1, isNull, reason: 'a new isolate starts with its own loader');
    expect(there.$2, expected);
  });
}
