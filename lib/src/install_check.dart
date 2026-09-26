import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:tstokenlib/src/crypto/stark_kernels.dart';

import 'build_version.dart';
import 'metrics/sqlite_library.dart';

/// The release this binary was built as (`lib/src/build_version.dart`, which
/// the release build writes), or `dev` for a build from source, so an
/// operator and a bug report can tell the two apart.
const poolVersion = buildVersion;

/// Why the kernels did not load, naming the file and every place it was
/// looked for, so an operator can see which one should have held it. `check`
/// and a refused start say the same thing.
String kernelsMissing() {
  final exeDir = File(Platform.resolvedExecutable).parent;
  final env = Platform.environment[StarkKernels.envVar];
  return 'the native kernels (${StarkKernels.fileName}, ABI version ${StarkKernels.abiVersion}) were not found. '
      'Looked in: ${StarkKernels.envVar} (${env ?? 'unset'}); '
      '${exeDir.path}/${StarkKernels.fileName}; ${exeDir.parent.path}/lib/${StarkKernels.fileName}; '
      'native/stark_kernels/target/release under ${Directory.current.path} and its parents. '
      'A file there with another ABI version is not used.';
}

/// What an installed copy can do, as `check` prints it: one line a fact,
/// and whether everything the coordinator needs loaded. Needs no
/// configuration, so it can run right after an install.
({bool ok, List<String> lines}) installCheck() {
  final lines = <String>['version: $poolVersion'];
  var ok = true;

  final kernels = StarkKernels.tryLoad();
  if (kernels == null) {
    ok = false;
    lines.add('kernels: missing: ${kernelsMissing()}');
  } else {
    lines.add('kernels: ${kernels.path} (ABI version ${StarkKernels.abiVersion})');
    if (Platform.isMacOS) {
      final status = kernels.gpuStatus;
      final available = status == 'on' || status.startsWith('off (available');
      lines.add(available ? 'metal: available ($status)' : 'metal: $status');
    }
  }

  try {
    useRuntimeSqlite();
    final version = sqlite3.version;
    lines.add('sqlite: ${sqliteLibrary ?? 'the system library'} (SQLite ${version.libVersion})');
  } catch (e) {
    ok = false;
    lines.add('sqlite: missing: $e');
  }
  return (ok: ok, lines: lines);
}
