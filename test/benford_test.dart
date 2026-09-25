import 'dart:math';

import 'package:pool_coordinator/src/benford.dart';
import 'package:test/test.dart';

/// The vendored splitter: exact sums, the floor held, and leading digits
/// that follow Benford's law (coin-pool, "Splitting").
void main() {
  const floor = 10000;
  final minOut = BigInt.from(floor);

  test('over 1,000 random totals and counts the outputs sum to the total and none is below the floor', () {
    final r = Random(7);
    for (int i = 0; i < 1000; i++) {
      final count = 2 + r.nextInt(99);
      final total = BigInt.from(floor * count + r.nextInt(50000000));
      final out = BenfordDistribution.distribute(total, count, minOutputAmount: minOut);
      expect(out, hasLength(count));
      expect(out.fold(BigInt.zero, (a, b) => a + b), total, reason: 'total $total, count $count');
      expect(out.every((a) => a >= minOut), isTrue, reason: 'total $total, count $count: ${out.reduce((a, b) => a < b ? a : b)}');
    }
  });

  test('a total too small for the count at the floor, or a count under 2, is refused', () {
    expect(() => BenfordDistribution.distribute(BigInt.from(floor * 3 - 1), 3, minOutputAmount: minOut), throwsArgumentError);
    expect(() => BenfordDistribution.distribute(BigInt.from(floor * 10), 1, minOutputAmount: minOut), throwsArgumentError);
  });

  test('the leading digits follow Benford: 1,000 outputs of splits of totals at least 100 x the floor, each digit within 0.05', () {
    final r = Random(11);
    final counts = List.filled(10, 0);
    var n = 0;
    while (n < 1000) {
      final total = floor * 100 + r.nextInt(floor * 100000);
      final cap = min(100, total ~/ (2 * floor));
      final count = 2 + r.nextInt(cap - 1);
      for (final a in BenfordDistribution.distribute(BigInt.from(total), count, minOutputAmount: minOut)) {
        counts[int.parse(a.toString()[0])]++;
        n++;
      }
    }
    for (int d = 1; d <= 9; d++) {
      expect(counts[d] / n, closeTo(log(1 + 1 / d) / ln10, 0.05), reason: 'digit $d');
    }
  });
}
