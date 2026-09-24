import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// Which SQLite library this isolate opened, for `check` and the log, or
/// null before the history has been opened here. Each isolate has its own.
String? sqliteLibrary;

bool _set = false;

/// Makes this isolate's `sqlite3` package open the library a runtime
/// install has. On Linux the package asks for the bare `libsqlite3.so`,
/// which only the `-dev` package provides, so an installed coordinator would
/// lose its history; the runtime package installs `libsqlite3.so.0`. Every
/// isolate keeps its own copy of the package's state, so whatever opens the
/// history calls this first, and a second call does nothing.
void useRuntimeSqlite() {
  if (_set) return;
  _set = true;
  if (Platform.isLinux) open.overrideFor(OperatingSystem.linux, _openLinux);
  if (Platform.isMacOS) open.overrideFor(OperatingSystem.macOS, _openMacOS);
}

// Top-level, since the package calls these from whichever isolate opens.
DynamicLibrary _openLinux() {
  ArgumentError? last;
  for (final name in const ['libsqlite3.so.0', 'libsqlite3.so']) {
    try {
      final lib = DynamicLibrary.open(name);
      sqliteLibrary = name;
      return lib;
    } on ArgumentError catch (e) {
      last = e;
    }
  }
  throw ArgumentError('no SQLite library: neither libsqlite3.so.0 (package libsqlite3-0) '
      'nor libsqlite3.so opened (${last?.message})');
}

// What the package does itself on a Mac, recorded.
DynamicLibrary _openMacOS() {
  final self = DynamicLibrary.process();
  if (self.providesSymbol('sqlite3_version')) {
    sqliteLibrary = 'the system library, already loaded in the process';
    return self;
  }
  const system = '/usr/lib/libsqlite3.dylib';
  final lib = DynamicLibrary.open(system);
  sqliteLibrary = system;
  return lib;
}
