import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'wallet_file.dart' show WalletFile;

/// The identity file could not be created or read. The path is named,
/// never the seed.
class IdentityError implements Exception {
  final String path;
  final String reason;
  const IdentityError(this.path, this.reason);
  @override
  String toString() => 'identity file $path: $reason';
}

/// The coordinator's ricochet identity: 32 bytes of Ed25519 seed in a
/// file only the owner can read. The seed rather than a generated key
/// pair, because the payload encryption at both ends derives from it, and
/// because the peer id it gives is what every wallet addresses: `create`
/// writes it once and `run` never regenerates it.
class IdentityFile {
  static const seedSize = 32;

  /// Writes a fresh seed to [path]; refuses to replace one.
  static Future<Uint8List> create(String path) async {
    if (File(path).existsSync()) throw IdentityError(path, 'already exists; the identity is created once');
    final r = Random.secure();
    final seed = Uint8List.fromList(List.generate(seedSize, (_) => r.nextInt(256)));
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(seed, flush: true);
    await WalletFile.ownerOnly(tmp.path);
    await tmp.rename(path);
    return seed;
  }

  static Future<Uint8List> read(String path) async {
    final f = File(path);
    if (!f.existsSync()) throw IdentityError(path, 'does not exist; `create` writes it');
    final bytes = await f.readAsBytes();
    if (bytes.length != seedSize) throw IdentityError(path, 'holds ${bytes.length} bytes, not a $seedSize-byte seed');
    return bytes;
  }
}
