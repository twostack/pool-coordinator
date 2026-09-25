import 'dart:io';

import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:pool_coordinator/src/config.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The configuration names what is missing and refuses what it does not
/// know, and the example holds nothing secret.
void main() {
  final full = '''
plan: test
network: test
chain:
  kind: node
  rpc_url: http://localhost:18332
  rpc_user: bitcoin
ricochet:
  server: /ip4/127.0.0.1/udp/55223/udx/p2p/12D3KooWExample
  identity_file: identity.seed
wallet:
  file: wallet.enc
store:
  directory: store
genesis:
  issuance: ${'a' * 64}
  witness0: ${'b' * 64}
  slot0: ${'c' * 64}
round:
  fee_rate: 1
  fee_floor: 135
  deadline_seconds: 600
  padding_stock: 3
  deposit_margin: 100
''';

  test('a full configuration parses, with paths against the file\'s directory', () {
    final c = PoolConfig.parse(full, baseDir: '/etc/pool');
    expect(c.plan, 'test');
    expect(c.network, NetworkType.TEST);
    expect(c.chain.kind, ChainKind.node);
    expect(c.chain.rpcUrl.toString(), 'http://localhost:18332');
    expect(c.chain.timeout, const Duration(seconds: 30));
    expect(c.ricochet.identityFile, '/etc/pool/identity.seed');
    expect(c.wallet.file, '/etc/pool/wallet.enc');
    expect(c.store.directory, '/etc/pool/store');
    expect(c.genesis!.issuance, 'a' * 64);
    expect(c.round.deadline, const Duration(minutes: 10));
    expect(c.server.statusFile, '/etc/pool/status.json');
  });

  test('each required field removed in turn is named', () {
    const required = [
      'plan',
      'network',
      'chain',
      'chain.kind',
      'chain.rpc_url',
      'chain.rpc_user',
      'ricochet',
      'ricochet.server',
      'ricochet.identity_file',
      'wallet',
      'wallet.file',
      'store',
      'store.directory',
      'genesis.issuance',
      'genesis.witness0',
      'genesis.slot0',
      'round',
      'round.fee_rate',
      'round.fee_floor',
      'round.deadline_seconds',
      'round.padding_stock',
      'round.deposit_margin',
    ];
    for (final field in required) {
      final without = _remove(full, field);
      expect(() => PoolConfig.parse(without), throwsA(isA<ConfigError>().having((e) => e.field, 'field', field)),
          reason: 'removing $field');
    }
    // testnet needs its own endpoints
    final testnet = full.replaceFirst('kind: node', 'kind: testnet').replaceFirst('  rpc_url: http://localhost:18332\n  rpc_user: bitcoin\n', '  woc_url: https://api.whatsonchain.com/v1/bsv/test\n');
    expect(() => PoolConfig.parse(testnet), throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'chain.arc_url')));
  });

  test('a field the server does not know is named, and so is a wrong value', () {
    expect(() => PoolConfig.parse(full.replaceFirst('fee_floor: 135', 'fee_floor: 135\n  fee_rat: 2')),
        throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'round.fee_rat')));
    expect(() => PoolConfig.parse('$full\nextra: 1'), throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'extra')));
    expect(() => PoolConfig.parse(full.replaceFirst('plan: test', 'plan: huge')),
        throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'plan')));
    expect(() => PoolConfig.parse(full.replaceFirst('kind: node', 'kind: mainnet')),
        throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'chain.kind')));
    expect(() => PoolConfig.parse(full.replaceFirst('fee_rate: 1', 'fee_rate: one')),
        throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'round.fee_rate')));
    expect(() => PoolConfig.parse(full.replaceFirst('a' * 64, 'xyz')),
        throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'genesis.issuance')));
    expect(() => PoolConfig.parse('- a list'), throwsA(isA<ConfigError>()));
    expect(() => PoolConfig.parse('plan: [unclosed'), throwsA(isA<ConfigError>()));
  });

  test('the unmined bound and re-broadcast: 10 rounds and 3 blocks by default, read when set, and 0 refused', () {
    expect(PoolConfig.parse(full).server.maxUnminedRounds, 10);
    expect(PoolConfig.parse(full).server.rebroadcastAfterBlocks, 3);
    final set = PoolConfig.parse('${full}server:\n  max_unmined_rounds: 30\n  rebroadcast_after_blocks: 5\n').server;
    expect([set.maxUnminedRounds, set.rebroadcastAfterBlocks], [30, 5]);
    for (final (field, line) in [('server.max_unmined_rounds', 'max_unmined_rounds: 0'), ('server.rebroadcast_after_blocks', 'rebroadcast_after_blocks: 0')]) {
      expect(() => PoolConfig.parse('${full}server:\n  $line\n'), throwsA(isA<ConfigError>().having((e) => e.field, 'field', field)));
    }
    final example = PoolConfig.parse(File('deploy/debian/config.example.yaml').readAsStringSync(), baseDir: '/etc/pool-coordinator').server;
    expect([example.maxUnminedRounds, example.rebroadcastAfterBlocks], [10, 3], reason: 'the example says the defaults');
  });

  group('the coin store (wallet.coins)', () {
    String withCoins(String coins) => full.replaceFirst('  file: wallet.enc\n', '  file: wallet.enc\n  coins:\n$coins');

    test('absent, the defaults: floor 10,000 sat, target 30, low water 12, at most 100 outputs a split', () {
      final c = PoolConfig.parse(full).wallet.coins;
      expect([c.floor, c.target, c.lowWater, c.splitMaxOutputs], [10000, 30, 12, 100]);
      final e = PoolConfig.parse(File('config.example.yaml').readAsStringSync()).wallet.coins;
      expect([e.floor, e.target, e.lowWater, e.splitMaxOutputs], [10000, 30, 12, 100], reason: 'the example says the defaults');
    });

    test('set, the values are read', () {
      final c = PoolConfig.parse(withCoins('    floor: 5000\n    target: 50\n    low_water: 20\n    split_max_outputs: 60\n')).wallet.coins;
      expect([c.floor, c.target, c.lowWater, c.splitMaxOutputs], [5000, 50, 20, 60]);
    });

    test('a floor or target of 0, low water above the target, a split over 100 outputs or an unknown field is refused, named', () {
      String field(String coins) {
        try {
          PoolConfig.parse(withCoins(coins));
        } on ConfigError catch (e) {
          return e.field;
        }
        fail('parsed with $coins');
      }

      expect(field('    floor: 0\n'), 'wallet.coins.floor');
      expect(field('    target: 0\n'), 'wallet.coins.target');
      expect(field('    low_water: 31\n'), 'wallet.coins.low_water');
      expect(field('    split_max_outputs: 101\n'), 'wallet.coins.split_max_outputs');
      expect(field('    split_max_outputs: 1\n'), 'wallet.coins.split_max_outputs');
      expect(field('    flor: 1\n'), 'wallet.coins.flor');
    });
  });

  group('the api section', () {
    const api = """
api:
  enabled: true
""";

    test('absent or commented out, the API is off, as before the section existed', () {
      expect(PoolConfig.parse(full).api, isNull);
      expect(PoolConfig.parse(File('config.example.yaml').readAsStringSync()).api, isNull);
      expect(PoolConfig.parse('$full${api.replaceFirst('true', 'false')}').api, isNull);
    });

    test('enabled, it takes loopback defaults and resolves the metrics file against the file\'s directory', () {
      final a = PoolConfig.parse('$full$api', baseDir: '/etc/pool').api!;
      expect(a.bind.address, '127.0.0.1');
      expect(a.port, 8787);
      expect(a.metricsFile, '/etc/pool/metrics.sqlite');
      expect(a.publishInterval, const Duration(seconds: 30));
      expect(a.maxSubscribers, 200);
      expect(PoolConfig.parse('$full$api  bind: "::1"\n').api!.bind.isLoopback, isTrue);
    });

    test('a bind that is not loopback is refused naming api.bind', () {
      for (final b in ['0.0.0.0', '192.168.1.10', '"::"', 'localhost', 'example.com']) {
        expect(() => PoolConfig.parse('$full$api  bind: $b\n'),
            throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'api.bind')), reason: b);
      }
    });

    test('an interval under 10 s, a bad port, no subscribers or an unknown field is named', () {
      ConfigError err(String extra) {
        try {
          PoolConfig.parse('$full$api$extra');
        } on ConfigError catch (e) {
          return e;
        }
        fail('parsed with $extra');
      }

      expect(err('  publish_interval_seconds: 5\n').field, 'api.publish_interval_seconds');
      expect(err('  port: 70000\n').field, 'api.port');
      expect(err('  max_subscribers: 0\n').field, 'api.max_subscribers');
      expect(err('  enabled_: true\n').field, 'api.enabled_');
      expect(() => PoolConfig.parse('$full${api.replaceFirst('true', 'yes please')}'),
          throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'api.enabled')));
      expect(PoolConfig.parse('$full$api  publish_interval_seconds: 10\n').api!.publishInterval, const Duration(seconds: 10));
    });

    group('what wallets are told', () {
      const relay = '12D3KooWFuA6F9bBybjmQ6ZWUd9hKK4GXHXGTnyY11zAXA1gbeu7';
      final base = full.replaceFirst('/ip4/127.0.0.1/udp/55223/udx/p2p/12D3KooWExample', '/ip4/127.0.0.1/udp/55223/udx/p2p/$relay');
      const good = '''
  wallet:
    server: /ip4/139.59.159.19/udp/55223/udx/p2p/$relay
    peers:
      - 198.154.93.206:18333
      - seed.example.org:18333
    arc_url: https://testnet.arc.gorillapool.io/v1
''';
      ConfigError err(String wallet, {String apiText = api}) {
        try {
          PoolConfig.parse('$base$apiText$wallet');
        } on ConfigError catch (e) {
          return e;
        }
        fail('parsed with $wallet');
      }

      test('absent, nothing is told; present, the server, the peers and the ARC URL are read', () {
        expect(PoolConfig.parse('$base$api').api!.wallet, isNull);
        final w = PoolConfig.parse('$base$api$good').api!.wallet!;
        expect(w.server, '/ip4/139.59.159.19/udp/55223/udx/p2p/$relay');
        expect(w.peers, ['198.154.93.206:18333', 'seed.example.org:18333']);
        expect(w.arcUrl.toString(), 'https://testnet.arc.gorillapool.io/v1');
        final bare = PoolConfig.parse('$base$api  wallet:\n    server: /ip6/2001:db8::7/udp/55223/udx/p2p/$relay\n').api!.wallet!;
        expect(bare.peers, isEmpty);
        expect(bare.arcUrl, isNull);
      });

      test('another relay\'s peer id is refused naming api.wallet.server', () {
        final e = err(good.replaceFirst('p2p/$relay', 'p2p/12D3KooWG1BX6cWMmpR5wVCWyST5HCa5WmeVoCcZpFss4pzv8TSY'));
        expect(e.field, 'api.wallet.server');
        expect(e.reason, contains(relay));
      });

      test('a name, not an address, is refused: wallets dial only /ip4 or /ip6', () {
        final e = err(good.replaceFirst('/ip4/139.59.159.19/', '/dns4/relay.testnet.shieldpool.net/'));
        expect(e.field, 'api.wallet.server');
        expect(e.reason, contains('/ip4 or /ip6'));
      });

      test('a server that is not a plain UDX multiaddr is refused', () {
        for (final bad in [
          '/ip4/139.59.159.300/udp/55223/udx/p2p/$relay',
          '/ip4/139.59.159.19/udp/0/udx/p2p/$relay',
          '/ip4/139.59.159.19/udp/70000/udx/p2p/$relay',
          '/ip4/139.59.159.19/tcp/55223/p2p/$relay',
          '/ip4/139.59.159.19/udp/55223/udx/p2p/$relay/extra',
          '"/ip4/139.59.159.19/udp/55223/udx/p2p/$relay; curl x | sh"',
        ]) {
          expect(err(good.replaceFirst('/ip4/139.59.159.19/udp/55223/udx/p2p/$relay', bad)).field, 'api.wallet.server', reason: bad);
        }
      });

      test('a peer without a port, a bad one, or nine peers are refused naming api.wallet.peers', () {
        for (final bad in ['198.154.93.206', '198.154.93.206:0', '198.154.93.206:99999', '"a b:18333"', '"x;rm:18333"', '":18333"']) {
          expect(err(good.replaceFirst('198.154.93.206:18333', bad)).field, 'api.wallet.peers', reason: bad);
        }
        final nine = '  wallet:\n    server: /ip4/139.59.159.19/udp/55223/udx/p2p/$relay\n    peers:\n${List.generate(9, (i) => '      - 10.0.0.$i:18333\n').join()}';
        expect(err(nine).field, 'api.wallet.peers');
      });

      test('an ARC URL that is not plain https is refused naming api.wallet.arc_url', () {
        for (final bad in ['http://testnet.arc.gorillapool.io/v1', '"https://a.example/v1 --x"', '"https://a.example/\$HOME"', 'javascript:alert(1)']) {
          expect(err(good.replaceFirst('https://testnet.arc.gorillapool.io/v1', bad)).field, 'api.wallet.arc_url', reason: bad);
        }
      });

      test('the section under a disabled API is refused naming api.wallet', () {
        expect(err(good, apiText: api.replaceFirst('true', 'false')).field, 'api.wallet');
      });

      test('an unknown field in the section is named', () {
        expect(err('$good    port: 1\n').field, 'api.wallet.port');
      });
    });
  });

  test('a configuration without genesis parses, for create', () {
    final c = PoolConfig.parse(_remove(full, 'genesis'));
    expect(c.genesis, isNull);
  });

  test('secrets come from the environment or a named file, never the configuration', () {
    final c = PoolConfig.parse(full);
    expect(() => Secrets.load(c, env: {}),
        throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'wallet.passphrase_file').having((e) => e.reason, 'reason', contains('POOL_WALLET_PASSPHRASE'))));
    expect(() => Secrets.load(c, env: {'POOL_WALLET_PASSPHRASE': 'x'}),
        throwsA(isA<ConfigError>().having((e) => e.field, 'field', 'chain.rpc_password_file')));
    final s = Secrets.load(c, env: {'POOL_WALLET_PASSPHRASE': 'x', 'POOL_RPC_PASSWORD': 'y'});
    expect(s.walletPassphrase, 'x');
    expect(s.rpcPassword, 'y');
    final dir = Directory.systemTemp.createTempSync('pool-config');
    try {
      File('${dir.path}/pass').writeAsStringSync('from a file\n');
      final withFile = PoolConfig.parse(full.replaceFirst('file: wallet.enc', 'file: wallet.enc\n  passphrase_file: pass'), baseDir: dir.path);
      expect(Secrets.load(withFile, env: {'POOL_RPC_PASSWORD': 'y'}).walletPassphrase, 'from a file');
      final missing = PoolConfig.parse(full.replaceFirst('file: wallet.enc', 'file: wallet.enc\n  passphrase_file: nowhere'), baseDir: dir.path);
      expect(() => Secrets.load(missing, env: {'POOL_RPC_PASSWORD': 'y'}),
          throwsA(isA<ConfigError>().having((e) => e.reason, 'reason', contains('does not exist'))));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  for (final example in const ['config.example.yaml', 'deploy/debian/config.example.yaml']) {
    test('$example parses and holds no key, seed, passphrase or password', () {
      final text = File(example).readAsStringSync();
      final c = PoolConfig.parse(text);
      expect(c.genesis, isNull);
      expect(c.chain.kind, ChainKind.node);
      // every field whose name suggests a secret only says where it is found
      final doc = loadYaml(text) as YamlMap;
      final secretish = RegExp(r'passphrase|password|key|seed|secret', caseSensitive: false);
      void walk(String prefix, YamlMap m) {
        for (final e in m.entries) {
          final k = '$prefix${e.key}';
          if (secretish.hasMatch('${e.key}')) {
            expect('${e.key}', endsWith('_file'), reason: '$k names a secret value rather than where it is found');
          }
          if (e.value is YamlMap) walk('$k.', e.value as YamlMap);
        }
      }

      walk('', doc);
      // and the comments name only the places, never a value
      for (final line in text.split('\n')) {
        if (!secretish.hasMatch(line)) continue;
        expect(line, isNot(matches(RegExp(r'(passphrase|password|key|seed|secret)\s*[:=]\s*[^\s#]', caseSensitive: false))),
            reason: 'a secret with a value: "$line"');
      }
    });
  }

  // The package copies this to /etc/pool-coordinator/config.yaml and runs
  // the service in /var/lib/pool-coordinator, the one directory it owns.
  test('the packaged example keeps everything the pool writes in /var/lib/pool-coordinator, with the API on', () {
    final c = PoolConfig.parse(File('deploy/debian/config.example.yaml').readAsStringSync(), baseDir: '/etc/pool-coordinator');
    const data = '/var/lib/pool-coordinator/';
    expect(c.ricochet.identityFile, startsWith(data));
    expect(c.wallet.file, startsWith(data));
    expect(c.store.directory, startsWith(data));
    expect(c.server.statusFile, startsWith(data));
    expect(c.api?.metricsFile, startsWith(data));
    expect(c.api?.bind.address, '127.0.0.1');
  });
}

/// [yaml] with the field at dotted [path] removed, by text: a top-level
/// key and its block, or one indented line.
String _remove(String yaml, String path) {
  final parts = path.split('.');
  final lines = yaml.split('\n');
  if (parts.length == 1) {
    final start = lines.indexWhere((l) => l.startsWith('${parts[0]}:'));
    var end = start + 1;
    while (end < lines.length && lines[end].startsWith(' ')) {
      end++;
    }
    lines.removeRange(start, end);
  } else {
    final start = lines.indexWhere((l) => l.startsWith('${parts[0]}:'));
    final i = lines.indexWhere((l) => l.startsWith('  ${parts[1]}:'), start);
    lines.removeAt(i);
  }
  return lines.join('\n');
}
