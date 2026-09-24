import 'dart:io';

import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/src/crypto/stark_kernels.dart';

/// `--version` and `check` on a compiled binary, the way an install runs
/// them: no `dart run`, no configuration.
void main() {
  final kernels = StarkKernels.tryLoad();
  final skip = kernels == null ? 'native kernels not built' : null;
  late Directory tmp;
  late String exe;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('cli_test');
    exe = '${tmp.path}/bin/pool-coordinator';
    Directory('${tmp.path}/bin').createSync();
    final r = await Process.run(Platform.resolvedExecutable, ['compile', 'exe', 'bin/pool_coordinator.dart', '-o', exe]);
    if (r.exitCode != 0) throw StateError('compile failed: ${r.stderr}');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<ProcessResult> run(List<String> args, {String? workingDirectory, String? kernelsEnv}) {
    final env = Map.of(Platform.environment)..remove(StarkKernels.envVar);
    if (kernelsEnv != null) env[StarkKernels.envVar] = kernelsEnv;
    return Process.run(exe, args, workingDirectory: workingDirectory, environment: env, includeParentEnvironment: false);
  }

  test('--version of a build that set none says dev', () async {
    final r = await run(['--version']);
    expect(r.exitCode, 0);
    expect((r.stdout as String).trim(), 'pool-coordinator dev');
    expect(poolVersion, 'dev');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('check passes on the development machine', () async {
    // from the repository, where the kernels this test process loaded are
    // found the same way (its native/, or the variable a CI build sets)
    final r = await run(['check'],
        workingDirectory: Directory.current.path, kernelsEnv: Platform.environment[StarkKernels.envVar]);
    final out = r.stdout as String;
    expect(r.exitCode, 0, reason: out);
    expect(out, contains('version: dev'));
    expect(out, contains('kernels: ${kernels!.path} (ABI version ${StarkKernels.abiVersion})'));
    expect(out, matches(RegExp(r'sqlite: .+ \(SQLite 3\.\d+')));
    if (Platform.isMacOS) expect(out, contains('metal: '));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('check fails naming the library and where it looked when the kernels are missing', () async {
    // not a library, and from a directory where the search finds nothing else
    final bogus = File('${tmp.path}/not-a-library')..writeAsStringSync('no');
    final r = await run(['check'], workingDirectory: tmp.path, kernelsEnv: bogus.path);
    final out = r.stdout as String;
    expect(r.exitCode, isNot(0), reason: out);
    expect(out, contains('kernels: missing'));
    expect(out, contains(StarkKernels.fileName));
    expect(out, contains(bogus.path));
    expect(out, contains('${tmp.path}/bin/${StarkKernels.fileName}'));
    expect(out, contains('sqlite: '), reason: 'the rest of the report still prints');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
