import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dartsv/dartsv.dart';

/// The wallet file could not be created, opened or trusted. The path is
/// named, never anything in the file.
class WalletFileError implements Exception {
  final String path;
  final String reason;
  const WalletFileError(this.path, this.reason);
  @override
  String toString() => 'wallet file $path: $reason';
}

/// One output the wallet can spend, with the transaction that holds it,
/// since the library signs a spend from the whole parent.
class WalletCoin {
  final Transaction tx;
  final int vout;

  /// True for an output that was offered to the library once and came
  /// back unspent; it is offered again before a new one is made.
  final bool returned;

  /// The height the coin's transaction was mined at, or null while it is
  /// pending. A coin is ready, and can serve a request, only once mined.
  int? height;

  WalletCoin(this.tx, this.vout, {this.returned = false, this.height});

  String get txid => tx.id;
  BigInt get satoshis => tx.outputs[vout].satoshis;
  String get outpoint => '$txid:$vout';
  bool get mined => height != null;

  Map<String, dynamic> toJson() => {'tx': tx.serialize(), 'vout': vout, if (returned) 'returned': true, 'height': height};

  static WalletCoin fromJson(Map<String, dynamic> j) =>
      WalletCoin(Transaction.fromHex(j['tx'] as String), j['vout'] as int, returned: j['returned'] == true, height: j['height'] as int?);
}

/// What the wallet file holds once opened.
class WalletContents {
  final SVPrivateKey ownerKey;
  final NetworkType network;
  final List<WalletCoin> coins;
  final List<WalletCoin> offered;

  /// Splits written before their broadcast and kept until they are mined,
  /// so one a crash left unbroadcast is broadcast at the next start.
  final List<Transaction> splits;

  /// Outpoints the wallet or its rounds spent, kept until the chain's
  /// listing of the address stops showing them: an indexer can list an
  /// output as unspent for a while after its spend is broadcast, and the
  /// wallet must not take it back in meanwhile.
  final Set<String> spent;
  BigInt? lastRoundCost;
  BigInt? balanceAtReconcile;

  /// The fee of the last split over the outputs it made: what each coin a
  /// round spends carries of it, in the round's cost.
  BigInt? splitFeePerCoin;

  /// The format the contents were read in: 1 for a file from before the
  /// coin store, whose coins' heights the wallet asks the chain for.
  final int readFormat;

  WalletContents({
    required this.ownerKey,
    required this.network,
    List<WalletCoin>? coins,
    List<WalletCoin>? offered,
    List<Transaction>? splits,
    Set<String>? spent,
    this.lastRoundCost,
    this.balanceAtReconcile,
    this.splitFeePerCoin,
    this.readFormat = formatVersion,
  })  : coins = coins ?? [],
        offered = offered ?? [],
        splits = splits ?? [],
        spent = spent ?? {};

  static const formatVersion = 2;

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'network': network == NetworkType.MAIN ? 'main' : 'test',
        'ownerKey': ownerKey.toHex(),
        'coins': [for (final c in coins) c.toJson()],
        'offered': [for (final c in offered) c.toJson()],
        'splits': [for (final t in splits) t.serialize()],
        'spent': spent.toList(),
        'lastRoundCost': lastRoundCost?.toString(),
        'balanceAtReconcile': balanceAtReconcile?.toString(),
        'splitFeePerCoin': splitFeePerCoin?.toString(),
      };

  /// Reads format 2, and format 1, whose coins carry no height: they read
  /// as pending until the wallet has asked the chain about each.
  static WalletContents fromJson(Map<String, dynamic> j) {
    final version = j['version'];
    if (version != 1 && version != formatVersion) throw FormatException('contents format $version, and this server reads 1 and $formatVersion');
    final network = j['network'] == 'main' ? NetworkType.MAIN : NetworkType.TEST;
    BigInt? big(String k) => j[k] == null ? null : BigInt.parse(j[k] as String);
    return WalletContents(
      ownerKey: SVPrivateKey.fromHex(j['ownerKey'] as String, network),
      network: network,
      coins: [for (final c in j['coins'] as List) WalletCoin.fromJson(c as Map<String, dynamic>)],
      offered: [for (final c in j['offered'] as List) WalletCoin.fromJson(c as Map<String, dynamic>)],
      splits: [for (final t in (j['splits'] as List?) ?? const []) Transaction.fromHex(t as String)],
      spent: {for (final o in (j['spent'] as List?) ?? const []) o as String},
      lastRoundCost: big('lastRoundCost'),
      balanceAtReconcile: big('balanceAtReconcile'),
      splitFeePerCoin: big('splitFeePerCoin'),
      readFormat: version as int,
    );
  }
}

/// The cost of opening the file: Argon2id's memory in KiB, its passes and
/// lanes. Written in the file's header so a file made at one setting still
/// opens after the default moves. The default (64 MiB, 3 passes) takes
/// about half a second in pure Dart on an M3 Pro; the tests use less.
class KdfParams {
  final int memoryKiB, iterations, parallelism;
  const KdfParams({this.memoryKiB = 65536, this.iterations = 3, this.parallelism = 1});
  static const light = KdfParams(memoryKiB: 1024, iterations: 1);
}

/// The owner key and the coins on disk, encrypted under a passphrase:
/// Argon2id from the passphrase and a fresh salt to a key, XChaCha20-
/// Poly1305 over the contents with the header as associated data. The
/// file is versioned by its first bytes, written to a temporary name and
/// renamed so it is whole or absent, and readable by the owner only.
/// Nothing in it is ever in the clear: the key, its public key and every
/// outpoint are inside the ciphertext.
///
/// Layout: magic `PCWF`, version 1, memory KiB u32, iterations u8,
/// parallelism u8, salt 16, nonce 24, ciphertext, MAC 16.
class WalletFile {
  static const magic = [0x50, 0x43, 0x57, 0x46];
  static const version = 1;
  static const _saltSize = 16, _nonceSize = 24, _macSize = 16;
  static const _headerSize = 4 + 1 + 4 + 1 + 1 + _saltSize;

  final String path;
  final KdfParams kdf;
  final Uint8List _salt;
  final SecretKey _key;

  WalletFile._(this.path, this.kdf, this._salt, this._key);

  /// Writes a new file holding [contents] under [passphrase]; refuses to
  /// replace one that exists, since that would be the owner key.
  static Future<WalletFile> create(String path, String passphrase, WalletContents contents,
      {KdfParams kdf = const KdfParams()}) async {
    if (File(path).existsSync()) throw WalletFileError(path, 'already exists; a wallet is created once');
    final salt = _random(_saltSize);
    final key = await _derive(passphrase, salt, kdf);
    final f = WalletFile._(path, kdf, salt, key);
    await f.write(contents);
    return f;
  }

  /// Opens [path] under [passphrase]. A passphrase that does not open it,
  /// a version this code does not read, or a file cut short is a
  /// [WalletFileError] naming the path.
  static Future<(WalletFile, WalletContents)> open(String path, String passphrase) async {
    final file = File(path);
    if (!file.existsSync()) throw WalletFileError(path, 'does not exist');
    final bytes = await file.readAsBytes();
    if (bytes.length < _headerSize + _nonceSize + _macSize) throw WalletFileError(path, 'is cut short');
    for (int i = 0; i < 4; i++) {
      if (bytes[i] != magic[i]) throw WalletFileError(path, 'is not a wallet file');
    }
    final v = bytes[4];
    if (v != version) throw WalletFileError(path, 'is version $v, and this server reads version $version');
    final bd = ByteData.sublistView(bytes);
    final kdf = KdfParams(memoryKiB: bd.getUint32(5, Endian.little), iterations: bytes[9], parallelism: bytes[10]);
    if (kdf.memoryKiB < 8 || kdf.iterations < 1 || kdf.parallelism < 1) throw WalletFileError(path, 'has a header this server cannot use');
    final salt = Uint8List.sublistView(bytes, 11, _headerSize);
    final header = Uint8List.sublistView(bytes, 0, _headerSize);
    final nonce = Uint8List.sublistView(bytes, _headerSize, _headerSize + _nonceSize);
    final cipherText = Uint8List.sublistView(bytes, _headerSize + _nonceSize, bytes.length - _macSize);
    final mac = Uint8List.sublistView(bytes, bytes.length - _macSize);
    final key = await _derive(passphrase, salt, kdf);
    final List<int> plain;
    try {
      plain = await Xchacha20.poly1305Aead().decrypt(SecretBox(cipherText, nonce: nonce, mac: Mac(mac)), secretKey: key, aad: header);
    } on SecretBoxAuthenticationError {
      throw WalletFileError(path, 'the passphrase does not open it');
    }
    final WalletContents contents;
    try {
      contents = WalletContents.fromJson(jsonDecode(utf8.decode(plain)) as Map<String, dynamic>);
    } catch (e) {
      throw WalletFileError(path, 'opened, but its contents do not read ($e)');
    }
    return (WalletFile._(path, kdf, Uint8List.fromList(salt), key), contents);
  }

  /// Writes [contents], whole or not at all, owner-readable only.
  Future<void> write(WalletContents contents) async {
    final header = BytesBuilder(copy: false)
      ..add(magic)
      ..addByte(version)
      ..add(Uint8List(4)..buffer.asByteData().setUint32(0, kdf.memoryKiB, Endian.little))
      ..addByte(kdf.iterations)
      ..addByte(kdf.parallelism)
      ..add(_salt);
    final head = header.toBytes();
    final nonce = _random(_nonceSize);
    final box = await Xchacha20.poly1305Aead()
        .encrypt(utf8.encode(jsonEncode(contents.toJson())), secretKey: _key, nonce: nonce, aad: head);
    final out = BytesBuilder(copy: false)
      ..add(head)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(out.toBytes(), flush: true);
    await ownerOnly(tmp.path);
    await tmp.rename(path);
  }

  static Future<SecretKey> _derive(String passphrase, List<int> salt, KdfParams p) =>
      Argon2id(parallelism: p.parallelism, memory: p.memoryKiB, iterations: p.iterations, hashLength: 32)
          .deriveKeyFromPassword(password: passphrase, nonce: salt);

  static Uint8List _random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  /// Makes [path] readable and writable by its owner only. Dart has no
  /// permission API, so this is `chmod` where there is one.
  static Future<void> ownerOnly(String path) async {
    if (Platform.isWindows) return;
    final r = await Process.run('chmod', ['600', path]);
    if (r.exitCode != 0) throw WalletFileError(path, 'could not be made owner-only: ${r.stderr}');
  }

  /// The hex of [bytes], for a test that searches a file for a value.
  static String hexOf(List<int> bytes) => hex.encode(bytes);
}
