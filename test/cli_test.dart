import 'dart:io';

import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/src/crypto/stark_kernels.dart';

/// `--version` and `check` on a built program, the way an install runs
/// them: no `dart run`, no configuration. `dart build cli` builds it as the
/// release does, with the kernels tstokenlib's build hook provides in the
/// bundle's lib/; a copy of the program alone, with no lib/ beside it, is how
/// the kernels go missing.
void main() {
  final kernels = StarkKernels.tryLoad();
  final skip = kernels == null ? 'native kernels not built' : null;
  late Directory tmp;
  late String exe;
  late String bare;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('cli_test');
    final r = await Process.run(
        Platform.resolvedExecutable, ['build', 'cli', '--target', 'bin/pool_coordinator.dart', '-o', tmp.path]);
    if (r.exitCode != 0) throw StateError('build failed: ${r.stderr}');
    exe = '${tmp.path}/bundle/bin/pool_coordinator';
    Directory('${tmp.path}/bin').createSync();
    bare = File(exe).copySync('${tmp.path}/bin/pool-coordinator').path;
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<ProcessResult> run(List<String> args, {String? program, String? workingDirectory, String? kernelsEnv}) {
    final env = Map.of(Platform.environment)..remove(StarkKernels.envVar);
    if (kernelsEnv != null) env[StarkKernels.envVar] = kernelsEnv;
    return Process.run(program ?? exe, args,
        workingDirectory: workingDirectory, environment: env, includeParentEnvironment: false);
  }

  test('--version of a build that set none says dev', () async {
    final r = await run(['--version']);
    expect(r.exitCode, 0);
    expect((r.stdout as String).trim(), 'pool-coordinator dev');
    expect(poolVersion, 'dev');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('check passes with the kernels bundled beside the program', () async {
    // from /, so nothing but the bundle can supply them
    final r = await run(['check'], workingDirectory: '/');
    final out = r.stdout as String;
    expect(r.exitCode, 0, reason: out);
    expect(out, contains('version: dev'));
    final bundled = File('${tmp.path}/bundle/lib/${StarkKernels.fileName}').resolveSymbolicLinksSync();
    expect(out, contains('kernels: $bundled (ABI version ${StarkKernels.abiVersion})'));
    expect(out, matches(RegExp(r'sqlite: .+ \(SQLite 3\.\d+')));
    if (Platform.isMacOS) expect(out, contains('metal: '));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('check fails naming the library and where it looked when the kernels are missing', () async {
    // not a library, and from a directory where the search finds nothing else
    final bogus = File('${tmp.path}/not-a-library')..writeAsStringSync('no');
    final r = await run(['check'], program: bare, workingDirectory: tmp.path, kernelsEnv: bogus.path);
    final out = r.stdout as String;
    expect(r.exitCode, isNot(0), reason: out);
    expect(out, contains('kernels: missing'));
    expect(out, contains(StarkKernels.fileName));
    expect(out, contains(bogus.path));
    expect(out, contains('${tmp.path}/bin/${StarkKernels.fileName}'));
    expect(out, contains('sqlite: '), reason: 'the rest of the report still prints');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
