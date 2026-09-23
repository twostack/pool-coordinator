import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';
import 'package:tstokenlib/src/crypto/nullifier_tree.dart' show NullifierTree;
import 'package:tstokenlib/src/script_gen/pool_verifier_gen.dart' show PoolStatement;
import 'package:tstokenlib/src/script_gen/slot_script_common.dart' show SlotScript;
import 'package:tstokenlib/src/script_gen/stark_verifier_gen.dart' show StarkVerifierGen;
import 'package:tstokenlib/tstokenlib.dart';

import 'chain_access.dart';
import 'config.dart';
import 'file_wallet.dart';
import 'identity.dart';
import 'plans.dart';
import 'transport.dart';
import 'wallet_file.dart';

/// `create` would not run: what is in the way, for the operator.
class CreateRefusal implements Exception {
  final String reason;
  const CreateRefusal(this.reason);
  @override
  String toString() => 'create refuses: $reason';
}

/// What `create` made: the genesis txids and where things are.
class Created {
  final Transaction slot0, issuance, witness0;
  final String peerId;
  final Address address;
  const Created({required this.slot0, required this.issuance, required this.witness0, required this.peerId, required this.address});
}

/// Issues a pool from nothing: the owner key and the ricochet identity
/// generated and written, the operator asked to fund the address, then
/// Y_0, the issuance and witness 0 built through the library's tool,
/// sized as the localnet harness sizes them, mined one after another, the
/// genesis txids written into the configuration and the descriptor
/// appended as the feed's first entry. The only time the owner key is
/// generated, which is why it refuses to run over an existing wallet.
class PoolCreator {
  final PoolConfig config;
  final String configPath;
  final Secrets secrets;
  final ChainAccess chain;
  final Future<PoolTransport> Function(Uint8List seed) connect;
  final Duration pollInterval;
  final void Function(String line) say;
  final Logger log;
  final KdfParams kdf;

  PoolCreator({
    required this.config,
    required this.configPath,
    required this.secrets,
    required this.chain,
    required this.connect,
    this.pollInterval = const Duration(seconds: 5),
    void Function(String line)? say,
    Logger? log,
    this.kdf = const KdfParams(),
  })  : say = say ?? print,
        log = log ?? Logger('create');

  /// The coins the issuance is funded with, as the harness funds it; the
  /// change comes back to the wallet.
  static final issuanceFunding = BigInt.from(1000000);

  /// The value Y needs: its size at the configured rate plus its two
  /// satoshi outputs; the witness: V's body three times and the round's
  /// bundles, as the harness prices witness 0.
  static BigInt ySats(int bodyLength, int feeRate) => BigInt.from(((bodyLength + 1000) * feeRate + 999) ~/ 1000 + 2);
  static BigInt wSats(int bodyLength, int feeRate) => BigInt.from(((3 * bodyLength + 1000000) * feeRate + 999) ~/ 1000 + 1);

  Future<Created> run() async {
    if (config.genesis != null) throw CreateRefusal('the configuration already names a genesis; this pool exists');
    if (File(config.wallet.file).existsSync()) throw CreateRefusal('the wallet file ${config.wallet.file} exists; a pool is created once');
    if (File(config.ricochet.identityFile).existsSync()) throw CreateRefusal('the identity file ${config.ricochet.identityFile} exists');

    final plan = planNamed(config.plan);
    final tool = ShieldedPoolTool(networkType: config.network);
    final stmt = PoolStatement.of(plan.tree);
    final body = ShieldedPoolTool.poolVerifier(stmt, verifier: StarkVerifierGen(plan.rootP, plan.rootAir(List.filled(stmt.numPublics, 0)))).body();
    final g = PoolHeader.genesis(
        emptyCmRoot: SlotScript.lanesBytes(NoteCommitmentTree().root), emptyNfRoot: SlotScript.lanesBytes(NullifierTree().root));
    final rate = config.round.feeRate;
    final y = ySats(body.length, rate), w = wSats(body.length, rate);

    // the keys and the files
    final key = SVPrivateKey(networkType: config.network);
    final contents = WalletContents(ownerKey: key, network: config.network);
    final file = await WalletFile.create(config.wallet.file, secrets.walletPassphrase, contents, kdf: kdf);
    final seed = await IdentityFile.create(config.ricochet.identityFile);
    final wallet = FileWallet(
        file: file,
        contents: contents,
        chain: chain,
        feeRate: rate,
        feeFloor: config.round.feeFloor,
        minedPoll: config.server.minedPoll,
        fundingTimeout: config.server.fundingTimeout);
    say('wallet written to ${config.wallet.file}; back it up: losing the owner key after a round is published freezes the pool');
    say('identity written to ${config.ricochet.identityFile}');

    // the coins
    final need = issuanceFunding + y + w + wallet.fundingFee(1) * BigInt.from(3);
    say('fund ${wallet.address.toBase58()} with at least $need satoshis (Y_0 $y, witness 0 $w, the issuance $issuanceFunding with change back)');
    await wallet.reconcile();
    while (wallet.balance < need) {
      await Future<void>.delayed(pollInterval);
      await wallet.reconcile();
    }
    say('the wallet holds ${wallet.balance} satoshis');

    // the genesis: Y_0, the issuance spending its anchor, witness 0
    final signer = wallet.owner, pub = wallet.ownerPub, addr = wallet.address;
    final pkh = hex.decode(addr.pubkeyHash160);
    final fY0 = (await wallet.output(y))!;
    final y0 = tool.buildSlotTxn(
        header: g,
        verifierBody: body,
        fundingTx: fY0.tx,
        fundingVout: fY0.vout,
        fundingSigner: signer,
        fundingPubKey: pub,
        anchorPKH: pkh,
        signerPKH: pkh);
    await _publish(y0.tx, 'Y_0');
    final fI = (await wallet.output(issuanceFunding))!;
    if (fI.vout != 1) throw CreateRefusal('the issuance must spend output 1 of its funding transaction, and the wallet paid it at output ${fI.vout}');
    final fW0 = (await wallet.output(w))!;
    final r0 = tool.createTokenIssuanceTxn(
        fI.tx, signer, pub, addr, crypto.sha256.convert(body).bytes, g, y0.outpoint, fW0.tx.hash,
        slotTx: y0.tx, fundingVout: fI.vout, witnessFundingVout: fW0.vout);
    await _publish(r0, 'the issuance');
    final w0 = tool.createWitnessTxn(signer, fW0.tx, r0, hex.decode(fI.tx.serialize()), pub, addr.pubkeyHash160, ShieldedPoolAction.CREATE,
        fundingVout: fW0.vout, slotParts: y0.parts, verifierBody: body);
    await _publish(w0, 'witness 0');
    await wallet.reconcile(roundTxs: [y0.tx, r0, w0]);

    // the configuration, then the feed
    await writeGenesis(configPath, issuance: r0.id, witness0: w0.id, slot0: y0.tx.id);
    say('genesis written to $configPath');
    final transport = await connect(seed);
    try {
      await transport.ensureFeed();
      final d = PoolDescriptor.forPool(network: config.network, issuance: r0, witness0: w0, slot0: y0.tx, plan: plan);
      final seq = await transport.announce(d.encode());
      say('descriptor appended as feed entry $seq under peer id ${transport.peerId}');
      say('issuance ${r0.id}');
      say('witness0 ${w0.id}');
      say('slot0    ${y0.tx.id}');
      return Created(slot0: y0.tx, issuance: r0, witness0: w0, peerId: transport.peerId, address: addr);
    } finally {
      await transport.close();
    }
  }

  Future<void> _publish(Transaction tx, String what) async {
    final st = await chain.broadcast(tx);
    log.info('$what ${tx.id} broadcast ($st)');
    final deadline = DateTime.now().add(config.server.fundingTimeout);
    while (await chain.minedHeight(tx.id) == null) {
      if (DateTime.now().isAfter(deadline)) throw CreateRefusal('$what ${tx.id} was not mined within ${config.server.fundingTimeout}');
      await Future<void>.delayed(config.server.minedPoll);
    }
    say('$what ${tx.id} mined');
  }

  /// Writes the genesis block into the configuration file's text: the
  /// existing `genesis:` block (commented or not) replaced, or one
  /// appended.
  static Future<void> writeGenesis(String path, {required String issuance, required String witness0, required String slot0}) async {
    final f = File(path);
    final lines = f.readAsLinesSync();
    final block = ['genesis:', '  issuance: $issuance', '  witness0: $witness0', '  slot0: $slot0'];
    final out = <String>[];
    var replaced = false;
    for (int i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (!replaced && RegExp(r'^#?\s*genesis:\s*$').hasMatch(l)) {
        out.addAll(block);
        replaced = true;
        // skip the block's indented (or commented, indented) lines
        while (i + 1 < lines.length && RegExp(r'^(#\s+|\s+)\S').hasMatch(lines[i + 1])) {
          i++;
        }
        continue;
      }
      out.add(l);
    }
    if (!replaced) {
      if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
      out.addAll(block);
    }
    final tmp = File('$path.tmp');
    await tmp.writeAsString('${out.join('\n')}\n', flush: true);
    await tmp.rename(path);
  }
}
