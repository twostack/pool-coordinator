import 'dart:convert';
import 'dart:io';

import 'package:tstokenlib/tstokenlib.dart';

import 'wallet.dart';

/// What an operator reads about the server, written to the status file
/// after every change of state. Nothing per transfer is in it beyond a
/// submission id in a failure, and no key, seed or passphrase ever.
class ServerStatus {
  final String? peerId;
  bool ready = false;
  bool stopping = false;
  int tipRound = 0;
  String? tipY, tipRoundTxId, tipWitness;
  int pending = 0, capacity = 0, inFlight = 0, paddingStock = 0;
  WalletReport? wallet;
  bool needsTopUp = false;
  String? lastFailure;
  final List<String> failures = [];
  int? lastAnnouncedRound, lastAnnouncementSequence;
  int submissionsAccepted = 0, submissionsRefused = 0, submissionsDropped = 0;

  /// The round up to which every round is mined, which catch-up answers
  /// stand at, and what the catch-up service has done.
  int minedTip = 0;
  int catchUpAnswered = 0, catchUpRefused = 0, catchUpDropped = 0, noticesSent = 0;
  DateTime updatedAt = DateTime.now();

  static const keptFailures = 20;

  ServerStatus(this.peerId);

  void fail(String what) {
    lastFailure = what;
    failures.add('${DateTime.now().toUtc().toIso8601String()} $what');
    if (failures.length > keptFailures) failures.removeAt(0);
  }

  void fromCoordinator(CoordinatorStatus s) {
    pending = s.pending;
    capacity = s.capacity;
    inFlight = s.inFlight;
    paddingStock = s.paddingStock;
    tipRound = s.rounds;
  }

  Map<String, dynamic> toJson() => {
        'peerId': peerId,
        'ready': ready,
        'stopping': stopping,
        'tip': {'round': tipRound, 'y': tipY, 'roundTx': tipRoundTxId, 'witness': tipWitness},
        'pending': pending,
        'capacity': capacity,
        'inFlight': inFlight,
        'paddingStock': paddingStock,
        'wallet': wallet?.toJson(),
        'needsTopUp': needsTopUp,
        'lastFailure': lastFailure,
        'failures': failures,
        'lastAnnouncement': lastAnnouncedRound == null ? null : {'round': lastAnnouncedRound, 'sequence': lastAnnouncementSequence},
        'submissions': {'accepted': submissionsAccepted, 'refused': submissionsRefused, 'dropped': submissionsDropped},
        'minedTip': minedTip,
        'catchUp': {'answered': catchUpAnswered, 'refused': catchUpRefused, 'dropped': catchUpDropped, 'notices': noticesSent},
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  /// Writes the status whole or not at all.
  Future<void> write(String path) async {
    updatedAt = DateTime.now();
    final tmp = File('$path.tmp');
    await tmp.writeAsString('${const JsonEncoder.withIndent('  ').convert(toJson())}\n', flush: true);
    await tmp.rename(path);
  }
}
