import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:pool_coordinator/pool_coordinator.dart';
import 'package:test/test.dart';

import 'support/fake_http.dart';

/// The testnet implementation against a fake HTTP server replaying
/// WhatsOnChain's and ARC's answers as recorded on 2026-09-22 (testnet's
/// block 1 coinbase and its address; localnet's ARC v1.5.11 for the error
/// shapes, ARC's documented shape for acceptance).
void main() {
  // testnet block 1's coinbase, as WhatsOnChain returns it
  const coinbaseId = 'f0315ffc38709d70ad5647e22048358dd3745f3ce3874223c80a7c92fab0c8ba';
  const coinbaseHex =
      '01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0e0420e7494d017f062f503253482fffffffff0100f2052a010000002321021aeaf2f8638a129a3156fbe7e5ef635226b0bafd495ff03afe2c843d7e3a4b51ac00000000';
  const txHash =
      '{"txid":"$coinbaseId","hash":"$coinbaseId","version":1,"size":109,"locktime":0,"vin":[{"coinbase":"0420e7494d017f062f503253482f","txid":"","vout":0,"scriptSig":{"asm":"","hex":""},"sequence":4294967295}],"vout":[{"value":50,"n":0,"scriptPubKey":{"asm":"021aeaf2f8638a129a3156fbe7e5ef635226b0bafd495ff03afe2c843d7e3a4b51 OP_CHECKSIG","hex":"21021aeaf2f8638a129a3156fbe7e5ef635226b0bafd495ff03afe2c843d7e3a4b51ac","reqSigs":1,"type":"pubkey","addresses":["n3GNqMveyvaPvUbH469vDRadqpJMPc84JA"],"isTruncated":false}}],"blockhash":"00000000b873e79784647a6c82962c70d228557d24a747ea4d1b8bbe878e1206","confirmations":1759424,"time":1296688928,"blocktime":1296688928,"blockheight":1}';
  const chainInfo =
      '{"chain":"test","blocks":1759424,"headers":1759424,"bestblockhash":"00000000be8511295a76a350cc74a993d849e24720bc19f364a490fc74a39178","difficulty":1,"mediantime":1790076765,"verificationprogress":0.9999987632702424,"pruned":false,"chainwork":"00000000000000000000000000000000000000000000015828f4e5b43ba12ea9"}';
  const spent = '{"txid":"5f2052ac5cb8eed1995a087b8f4777b27345acf97a193ef8af536ed5dd4935ce","vin":0,"status":"confirmed"}';
  const unspentAll =
      '{"address":"n3GNqMveyvaPvUbH469vDRadqpJMPc84JA","script":"a7ecc21d4b41234b3eff65a0bac69c54de166c1e1ccee3ae730637c4346cbf1a","result":[{"height":280589,"tx_pos":0,"tx_hash":"99845fd840ad2cc4d6f93fafb8b072d188821f55d9298772415175c456f3077d","value":50000,"isSpentInMempoolTx":false,"status":"confirmed"},{"height":466228,"tx_pos":0,"tx_hash":"6ec6b313788063402c7404b00433b7a30bb511fb2f73429097e0cbc4dea3be33","value":2000000,"isSpentInMempoolTx":true,"status":"confirmed"},{"height":554588,"tx_pos":0,"tx_hash":"d9d587c9f77996e5618141a564d46f3bb7c92a7cdd8cbe9142bc43eb18a63887","value":13999000,"isSpentInMempoolTx":false,"status":"confirmed"}]}';
  const arcMalformed =
      '{"detail":"The request seems to be malformed and cannot be processed","extraInfo":"unexpected EOF","instance":null,"status":400,"title":"Bad request","txid":null,"type":"https://bitcoin-sv.github.io/arc/#/errors?id=_400"}';

  late FakeHttp fake;
  late TestnetChain chain;
  final key = SVPrivateKey.fromWIF('cStLVGeWx7fVYKKDXYWVeEbEcPZEC4TD73DjQpHCks2Y8EAjVDSS');
  final addr = Address.fromPublicKey(key.publicKey, NetworkType.TEST);
  final coinbase = Transaction.fromHex(coinbaseHex);

  setUp(() async {
    fake = await FakeHttp.start();
    chain = TestnetChain(arcUrl: fake.url.resolve('/arc/v1'), wocUrl: fake.url.resolve('/woc/v1/bsv/test'), retries: 0);
    fake.routes['/woc/v1/bsv/test/tx/$coinbaseId/hex'] = (_) => const Answer(200, coinbaseHex);
    fake.routes['/woc/v1/bsv/test/tx/hash/$coinbaseId'] = (_) => const Answer(200, txHash);
    fake.routes['/woc/v1/bsv/test/chain/info'] = (_) => const Answer(200, chainInfo);
    fake.routes['/woc/v1/bsv/test/tx/$coinbaseId/0/spent'] = (_) => const Answer(200, spent);
    fake.routes['/woc/v1/bsv/test/address/${addr.toBase58()}/unspent/all'] = (_) => const Answer(200, unspentAll);
  });

  tearDown(() async {
    chain.close();
    await fake.close();
  });

  /// A spend of the coinbase, whose one input ARC needs the parent for.
  Transaction spend({int scriptSigBytes = 0}) {
    final tx = Transaction()
      ..addInput(TransactionInput(coinbaseId, 0, TransactionInput.MAX_SEQ_NUMBER))
      ..addOutput(TransactionOutput(BigInt.from(4999999000), P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));
    if (scriptSigBytes > 0) tx.inputs[0].script = SVScript.fromByteArray(List.filled(scriptSigBytes, 0));
    return tx;
  }

  test('a fetch, the height, mined-ness and an address\'s outputs come from WhatsOnChain', () async {
    final tx = (await chain.fetch(coinbaseId))!;
    expect(tx.id, coinbaseId);
    expect(await chain.height(), 1759424);
    expect(await chain.minedHeight(coinbaseId), 1);
    fake.routes['/woc/v1/bsv/test/tx/hash/${'11' * 32}'] = (_) => const Answer(404, '');
    fake.routes['/woc/v1/bsv/test/tx/${'11' * 32}/hex'] = (_) => const Answer(404, '');
    expect(await chain.minedHeight('11' * 32), isNull);
    expect(await chain.fetch('11' * 32), isNull);
    final found = await chain.unspentOf(addr);
    expect(found.map((u) => u.satoshis.toInt()), [50000, 13999000], reason: 'the one spent in the mempool is left out');
    expect(found[0].outpoint, '99845fd840ad2cc4d6f93fafb8b072d188821f55d9298772415175c456f3077d:0');
    expect(fake.requests.map((r) => r.path), contains('/woc/v1/bsv/test/chain/info'));
  });

  test('an outpoint is unspent when nothing spends it and the transaction has it', () async {
    expect(await chain.unspent(coinbaseId, 0), isFalse, reason: 'block 1\'s coinbase was spent');
    fake.routes['/woc/v1/bsv/test/tx/$coinbaseId/0/spent'] = (_) => const Answer(404, '');
    expect(await chain.unspent(coinbaseId, 0), isTrue);
    fake.routes['/woc/v1/bsv/test/tx/$coinbaseId/5/spent'] = (_) => const Answer(404, '');
    expect(await chain.unspent(coinbaseId, 5), isFalse, reason: 'no output 5');
    fake.routes['/woc/v1/bsv/test/tx/${'11' * 32}/0/spent'] = (_) => const Answer(404, '');
    fake.routes['/woc/v1/bsv/test/tx/${'11' * 32}/hex'] = (_) => const Answer(404, '');
    expect(await chain.unspent('11' * 32, 0), isFalse, reason: 'unknown transaction');
  });

  test('a broadcast goes to ARC in the extended format and is accepted at SEEN_ON_NETWORK', () async {
    final tx = spend();
    String? sent;
    fake.routes['/arc/v1/tx'] = (body) {
      sent = jsonDecode(body)['rawTx'] as String;
      return Answer.json(200, {
        'txid': tx.id,
        'txStatus': 'SEEN_ON_NETWORK',
        'blockHash': '',
        'blockHeight': 0,
        'timestamp': '2026-09-22T12:00:00Z',
        'extraInfo': '',
        'status': 200,
        'title': 'OK',
        'merklePath': ''
      });
    };
    expect(await chain.broadcast(tx), 'SEEN_ON_NETWORK');
    final ef = hex.decode(sent!);
    expect(ef.sublist(4, 10), [0, 0, 0, 0, 0, 0xef], reason: 'the extended format marker');
    // the input is followed by the coinbase output's value and script
    final input = tx.inputs[0].serialize();
    final at = 11 + input.length;
    expect(ef.sublist(at, at + 8), [0x00, 0xf2, 0x05, 0x2a, 0x01, 0, 0, 0], reason: '50 BSV little-endian');
    expect(ef[at + 8], coinbase.outputs[0].script.buffer.length);
    final arc = fake.requests.where((r) => r.path == '/arc/v1/tx').single;
    expect(arc.method, 'POST');
  });

  test('ARC without peers: STORED is a refusal with that status', () async {
    fake.routes['/arc/v1/tx'] = (_) => Answer.json(200, {'txid': spend().id, 'txStatus': 'STORED', 'status': 200, 'title': 'OK'});
    await expectLater(chain.broadcast(spend()),
        throwsA(isA<BroadcastRefusal>().having((e) => e.status, 'status', 'STORED').having((e) => e.endpoint, 'endpoint', contains('ARC'))));
    fake.routes['/arc/v1/tx'] = (_) => Answer.json(200, {'txid': spend().id, 'txStatus': 'ANNOUNCED_TO_NETWORK', 'status': 200, 'title': 'OK'});
    await expectLater(chain.broadcast(spend()), throwsA(isA<BroadcastRefusal>().having((e) => e.status, 'status', 'ANNOUNCED_TO_NETWORK')));
    fake.routes['/arc/v1/tx'] = (_) => const Answer(400, arcMalformed);
    await expectLater(
        chain.broadcast(spend()),
        throwsA(isA<BroadcastRefusal>()
            .having((e) => e.reason, 'reason', contains('malformed'))
            .having((e) => e.reason, 'reason', contains('unexpected EOF'))
            .having((e) => e.status, 'status', '400')));
  });

  test('size limits are known before sending: a 1.9 MB unlock is refused naming the input and the limit', () async {
    fake.routes['/arc/v1/tx'] = (_) => Answer.json(200, {'txStatus': 'SEEN_ON_NETWORK', 'status': 200});
    final big = spend(scriptSigBytes: 1900000);
    await expectLater(
        chain.broadcast(big),
        throwsA(isA<BroadcastRefusal>()
            .having((e) => e.reason, 'reason', contains('input 0'))
            .having((e) => e.reason, 'reason', contains('1636802'))
            .having((e) => e.reason, 'reason', contains('1900000'))));
    expect(fake.requests.where((r) => r.path == '/arc/v1/tx'), isEmpty, reason: 'nothing was sent');
    // one byte under the limit goes out
    final under = spend(scriptSigBytes: 1636802);
    expect(chain.overLimit(under), isNull);
    expect(chain.overLimit(spend(scriptSigBytes: 1636803)), 0);
  });

  test('a wrong transaction returned is refused naming both txids', () async {
    fake.routes['/woc/v1/bsv/test/tx/${'11' * 32}/hex'] = (_) => const Answer(200, coinbaseHex);
    await expectLater(
        chain.fetch('11' * 32),
        throwsA(isA<ChainError>()
            .having((e) => e.reason, 'reason', contains('11' * 32))
            .having((e) => e.reason, 'reason', contains(coinbaseId))
            .having((e) => e.endpoint, 'endpoint', contains('WhatsOnChain'))));
  });

  test('a height or a status that does not parse is an error naming the endpoint', () async {
    fake.routes['/woc/v1/bsv/test/chain/info'] = (_) => const Answer(200, 'Bad Request');
    await expectLater(chain.height(), throwsA(isA<ChainError>().having((e) => e.endpoint, 'endpoint', contains('WhatsOnChain'))));
    fake.routes['/woc/v1/bsv/test/chain/info'] = (_) => const Answer(200, '{"blocks":"many"}');
    await expectLater(chain.height(), throwsA(isA<ChainError>()));
    fake.routes['/woc/v1/bsv/test/tx/hash/$coinbaseId'] = (_) => const Answer(200, '{"confirmations":3}');
    await expectLater(chain.minedHeight(coinbaseId), throwsA(isA<ChainError>().having((e) => e.reason, 'reason', contains('height'))));
    fake.routes['/woc/v1/bsv/test/tx/hash/$coinbaseId'] = (_) => const Answer(200, '{"confirmations":0}');
    expect(await chain.minedHeight(coinbaseId), isNull);
    fake.routes['/arc/v1/tx'] = (_) => const Answer(502, '<html>bad gateway</html>');
    await expectLater(chain.broadcast(spend()), throwsA(isA<ChainError>().having((e) => e.reason, 'reason', contains('not JSON'))));
  });
}
