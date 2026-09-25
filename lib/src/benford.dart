// Vendored from libspiffy (github.com/twostack/libspiffy),
// lib/src/utils/benford_distribution.dart at commit 1fe54cc (2025-11-01).
// MIT License, Copyright (c) 2025 - Stephan M. February; the same author as
// this package. Vendored rather than depended on: libspiffy brings Isar,
// eventador, spiffynode and an actor stack that the coordinator's package
// has no use for. Changes from the source are marked "pool-coordinator:".

import 'dart:math' as math;

/// Utility class for distributing amounts according to Benford's Law
/// 
/// Benford's Law describes the frequency distribution of leading digits in many
/// real-life datasets. For privacy purposes, distributing UTXO amounts according
/// to Benford's Law makes transaction patterns appear more natural and organic,
/// making blockchain analysis more difficult.
/// 
/// The probability of a leading digit d (1-9) is: P(d) = log₁₀(1 + 1/d)
class BenfordDistribution {
  /// Benford's Law probabilities for first digits 1-9
  static const Map<int, double> benfordProbabilities = {
    1: 0.30103, // 30.103%
    2: 0.17609, // 17.609%
    3: 0.12494, // 12.494%
    4: 0.09691, // 9.691%
    5: 0.07918, // 7.918%
    6: 0.06695, // 6.695%
    7: 0.05799, // 5.799%
    8: 0.05115, // 5.115%
    9: 0.04576, // 4.576%
  };

  /// Calculate Benford probability for a given first digit
  /// 
  /// Formula: P(d) = log₁₀(1 + 1/d)
  static double calculateProbability(int digit) {
    if (digit < 1 || digit > 9) {
      throw ArgumentError('Digit must be between 1 and 9');
    }
    return math.log(1 + 1 / digit) / math.ln10;
  }

  /// Distribute a total amount into multiple outputs following Benford's Law
  /// 
  /// This function takes a total amount and splits it into [outputCount] outputs
  /// where the leading digits of the output amounts follow Benford's Law distribution.
  /// 
  /// Parameters:
  /// - [totalAmount]: Total amount in satoshis to distribute
  /// - [outputCount]: Number of outputs to create
  /// - [minOutputAmount]: Minimum amount per output (default: 1 sat, BSV has no dust limit)
  /// 
  /// Returns a list of BigInt amounts that sum to approximately totalAmount
  /// (may differ slightly due to rounding and ensuring each output meets minimum)
  /// 
  /// Example:
  /// ```dart
  /// final amounts = BenfordDistribution.distribute(
  ///   BigInt.from(100000),
  ///   10,
  /// );
  /// // Returns 10 amounts with leading digits following Benford distribution
  /// ```
  static List<BigInt> distribute(
    BigInt totalAmount,
    int outputCount, {
    BigInt? minOutputAmount,
  }) {
    if (outputCount < 2) {
      throw ArgumentError('Output count must be at least 2');
    }

    if (totalAmount <= BigInt.zero) {
      throw ArgumentError('Total amount must be positive');
    }

    final minAmount = minOutputAmount ?? BigInt.one;

    // Check if we have enough to create minimum outputs
    if (totalAmount < minAmount * BigInt.from(outputCount)) {
      throw ArgumentError(
        'Total amount ($totalAmount) is too small to create $outputCount '
        'outputs with minimum amount $minAmount each',
      );
    }

    // Calculate target amounts based on Benford distribution
    final amounts = <BigInt>[];
    final targetAmounts = <double>[];
    
    // Generate Benford-distributed proportions
    final proportions = _generateBenfordProportions(outputCount);
    
    // Calculate actual amounts
    double sum = 0;
    for (int i = 0; i < outputCount; i++) {
      final targetAmount = totalAmount.toDouble() * proportions[i];
      targetAmounts.add(targetAmount);
      sum += targetAmount;
    }

    // Normalize to ensure sum equals total (accounting for rounding)
    final normalizationFactor = totalAmount.toDouble() / sum;
    
    BigInt allocatedSum = BigInt.zero;
    for (int i = 0; i < outputCount - 1; i++) {
      final normalized = targetAmounts[i] * normalizationFactor;
      BigInt amount = BigInt.from(normalized.floor());
      
      // Ensure minimum amount
      if (amount < minAmount) {
        amount = minAmount;
      }
      
      amounts.add(amount);
      allocatedSum += amount;
    }

    // Last output gets remainder to ensure exact total
    final lastAmount = totalAmount - allocatedSum;
    if (lastAmount < minAmount) {
      // If last amount is too small, take from previous outputs
      BigInt needed = minAmount - lastAmount;
      BigInt borrowed = BigInt.zero;
      
      for (int i = amounts.length - 1; i >= 0 && borrowed < needed; i--) {
        if (amounts[i] > minAmount) {
          final canBorrow = amounts[i] - minAmount;
          final toBorrow = canBorrow < (needed - borrowed) ? canBorrow : (needed - borrowed);
          amounts[i] -= toBorrow;
          borrowed += toBorrow;
        }
      }
      
      amounts.add(lastAmount + borrowed);
    } else {
      amounts.add(lastAmount);
    }

    return amounts;
  }

  /// Generate proportions following Benford's Law for N outputs
  /// 
  /// This assigns leading digits to outputs according to Benford probabilities,
  /// then adds random trailing digits to create variation.
  static List<double> _generateBenfordProportions(int count) {
    final proportions = <double>[];
    final random = math.Random.secure();

    // Assign leading digits according to Benford distribution
    final leadingDigits = <int>[];
    int remainingCount = count;
    
    for (int digit = 1; digit <= 9 && remainingCount > 0; digit++) {
      final expectedCount = (count * benfordProbabilities[digit]!).round();
      final actualCount = math.min(expectedCount, remainingCount);
      
      for (int i = 0; i < actualCount; i++) {
        leadingDigits.add(digit);
      }
      
      remainingCount -= actualCount;
    }

    // If we still need more digits due to rounding, fill with digit 1 (most common)
    while (leadingDigits.length < count) {
      leadingDigits.add(1);
    }

    // Shuffle to avoid always having same order
    leadingDigits.shuffle(random);

    // Convert to proportions with random trailing digits
    double sum = 0;
    for (final digit in leadingDigits) {
      // Add random decimal part between 0 and 0.9999...
      // This creates variation like: 1.2345, 1.7823, 2.1234, etc.
      final trailingDecimals = random.nextDouble();
      final value = digit + trailingDecimals;
      proportions.add(value);
      sum += value;
    }

    // Normalize proportions to sum to 1.0
    return proportions.map((p) => p / sum).toList();
  }

  /// Verify that a set of amounts follows Benford's Law distribution
  /// 
  /// Returns a map of digit -> actual frequency for analysis
  /// Useful for testing and validation
  static Map<int, double> analyzeDistribution(List<BigInt> amounts) {
    if (amounts.isEmpty) {
      return {};
    }

    final digitCounts = <int, int>{
      1: 0, 2: 0, 3: 0, 4: 0, 5: 0,
      6: 0, 7: 0, 8: 0, 9: 0,
    };

    for (final amount in amounts) {
      final firstDigit = _getFirstDigit(amount);
      if (firstDigit >= 1 && firstDigit <= 9) {
        digitCounts[firstDigit] = (digitCounts[firstDigit] ?? 0) + 1;
      }
    }

    final total = amounts.length;
    return digitCounts.map((digit, count) => 
      MapEntry(digit, count / total)
    );
  }

  /// Extract the first non-zero digit from a number
  static int _getFirstDigit(BigInt number) {
    if (number <= BigInt.zero) {
      return 0;
    }

    final str = number.toString();
    for (int i = 0; i < str.length; i++) {
      final digit = int.parse(str[i]);
      if (digit != 0) {
        return digit;
      }
    }
    return 0;
  }

  /// Get a human-readable explanation of Benford's Law
  static String getExplanation() {
    return '''
Benford's Law describes the frequency of leading digits in many natural datasets.
According to this law, the digit 1 appears as the leading digit about 30% of the time,
while 9 appears only about 4.6% of the time.

By distributing your UTXOs according to Benford's Law:
• Your transactions appear more natural and organic
• Amount patterns are harder to analyze
• Your privacy is enhanced against blockchain analysis
• The distribution mimics naturally occurring financial data

This is a powerful privacy technique that makes your wallet activity blend in with
regular economic activity on the blockchain.
''';
  }
}

