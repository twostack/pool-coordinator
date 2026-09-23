/// The library's test chain, which tstokenlib now exports for dependent
/// packages (`package:tstokenlib/testing.dart`), so this package builds
/// byte for byte the chain the library's own tests build instead of
/// keeping a copy that drifts from it.
library;

export 'package:tstokenlib/testing.dart';
