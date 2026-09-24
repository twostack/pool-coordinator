/// A throwaway ricochet server for a test outside Dart: starts one on a
/// fresh database (as the localnet tests do), prints `ricochet <port>
/// <peer id>` on one line, and on SIGINT or SIGTERM stops it and drops the
/// database. tool/deb_e2e.sh runs it on the host for a coordinator in a
/// container.
///
///   dart run tool/ricochet_up.dart
library;

import 'dart:async';
import 'dart:io';

import '../test/support/ricochet_server.dart';

Future<void> main() async {
  final server = await RicochetTestServer.start();
  if (server == null) {
    stderr.writeln('no ricochet server: ${RicochetTestServer.skipReason}');
    exit(69);
  }
  stdout.writeln('ricochet ${server.port} ${server.peerId}');
  final done = Completer<void>();
  final subs = [
    for (final s in [ProcessSignal.sigint, ProcessSignal.sigterm]) s.watch().listen((_) => done.isCompleted ? null : done.complete()),
  ];
  await done.future;
  for (final s in subs) {
    await s.cancel();
  }
  await server.dispose();
  exit(0);
}
