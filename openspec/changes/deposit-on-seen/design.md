## Context

See proposal.md for why. The current state this design works from:

- **The server's deposit check** (`lib/src/server.dart:487`, `_depositCheck`) runs before the library's intake. It asks the chain access `minedHeight` and `unspent` for the covenant's outpoint and refuses with `depositCovenant` otherwise. The submission already carries the covenant transaction (`PoolSubmission.depositTx`).
- **The library's intake** (`tstokenlib/lib/src/shielded_pool/shielded_coordinator.dart:581`, `intake`) is synchronous. It checks in cost order, with the proof last. It then adds the entry to the pending round and closes the round when it is full. The deadline alarm closes it from inside the library. `_checkDeposit` enforces the tip's PP3, the refund margin (`chainHeight + depositMargin`), the receipt, one pending transfer per covenant, and the receipt-slot cap (8).
- **The server drains its inbox sequentially** (`_drain`: `for (final m in batch) await _handle(m)`). A 4 to 5 s broadcast inside `_handle` would push every later message in the batch past the 2 s bound.
- **Broadcast:**
  - `TestnetChain.broadcast` posts to ARC with `X-WaitFor: SEEN_ON_NETWORK`, `X-MaxTimeout: 30` and accepts SEEN_ON_NETWORK, ACCEPTED_BY_NETWORK, MINED and CONFIRMED;
  - `NodeChain.broadcast` is `sendrawtransaction`;
  - "already known" refusals are recognised by `FileWallet.alreadyKnown`, a pattern whose live ARC wording is still unverified (spend-unconfirmed 9.x).
- **The round store** keeps a funding list per round (record version 2, `funding-N.tx`). `FundedStore` fills it from `wallet.fundingOf(spenders)`. Start and `_reBroadcastDuringRun` broadcast the funding before Y, the round and the witness.
- **cloak** (`cloak-cli/lib/src/commands/deposit_commands.dart`) records, then broadcasts the covenant, then returns. `submitWaitingDeposits` submits deposits whose status is `broadcast` once `t.mined(covenantTxid)`. cloak waits 30 s for a reply (`wallet/config.dart:93`).
- **Releases:** release/0.1 builds against tstokenlib 2.0.1 from pub.dev (main is on 2.1.0, whose build hook breaks packaging). cloak uses tstokenlib ^2.1.0.

## Goals / Non-Goals

**Goals:**
- A deposit is admitted seconds after its submission, in the round it targets, with no window in which that round can close without it.
- Nothing is broadcast for a submission that fails any check.
- Old and new wallets and coordinators work together during the rollout.

**Non-Goals:**
- Changing the covenant script, the refund margin or the wire format. A new `RefusalReason` would be a protocol change; the existing `depositCovenant` (7) carries the new sentences.
- A covenant that can target any later round. With admission in seconds, the one-round target stops being a practical problem.
- Watching for double-spends of an admitted covenant beyond what re-broadcast already does.

## Decisions

### 1. The library reserves the deposit's place; the server supplies the broadcast

`ShieldedCoordinator` gets an optional admission hook, `DepositAdmission = Future<String?> Function(Transaction covenant)`, which answers null for admitted or a sentence for why not; a throw counts as a refusal naming the error. It also gets asynchronous entry points beside `submitBytes`, `submit` and `intake`: `receiveBytes`, `receive` and `admit`, which return futures. (Built in tstokenlib change `deposit-admission`. It was first sketched as a result type; a sentence is all the library does anything with.)

For a deposit, the synchronous part runs every check exactly as `intake` does, proof last. When the checks pass, the entry is added to the pending round, marked admitting, and the hook is called. Adding it makes the entry count toward capacity, the receipt slots, the covenant's pending key and the nullifiers. The future completes with `accepted` when the hook reports seen, and with `refused(depositCovenant, reason)` when it does not. On a refusal the entry leaves the pending round at once. Building it also found and fixed an existing leak: a closed round whose transfers had all expired stayed in `_inFlight`, so every later deposit was refused as targeting a round being built. If the round is left empty, the deadline alarm is cancelled.

`_buildAndPublish` gains a first stage, `admission`. It awaits the admissions still open in the closed round, and drops the refused ones with `notify(refused)`. Padding fills the places they leave, since `padding.take(capacity - live.length)` already counts live entries.

With no hook, behaviour is unchanged. That keeps the library's other users and its test suite as they are.

*Alternative: all in the server.* The server would pre-check what it can (covenant parse, proof), broadcast, then call `submitBytes`. It needs no library release. It was rejected because the round can close during the 4 to 5 s broadcast, by deadline or by other transfers filling it. The covenant would then name a spent PP3, be on the network, and be locked for about a day. That is the failure this change exists to remove. It would also verify the proof twice.

*Alternative: the server holds the round open.* The library closes rounds from inside `intake` and from its own alarm, and has no API to defer a close. Adding one would be a larger library change than the reservation.

### 2. Deposit replies leave the drain loop

`_handle` calls the asynchronous entry point for every submission, then waits in one of two ways:
- when the synchronous part has already decided the reply (every non-deposit, and every refused deposit), it sends the reply inline, as now;
- for a deposit being admitted, it attaches the reply to the future and moves on to the next message.

The message is marked delivered with its batch, as now. An admitting entry lives in memory like any pending entry, so a crash loses it the same way. A deposit's covenant that was already broadcast then waits for the refund, which is today's behaviour for any pending deposit lost in a crash.

### 3. The hook in the server: broadcast, classify, bound

The server's hook works in three steps:
1. It calls `chain.broadcast(covenant)`. When that returns seen, it admits.
2. When the broadcast reports the transaction mined, which is "already known" in a block, it checks the covenant outpoint with `chain.unspent` and refuses a spent one.
3. When the broadcast throws a `BroadcastRefusal` that is not "already known", it refuses with the chain's text.

On a `ChainError` or a timeout, it asks `chain.statusOf(txid)` once, within the remaining time:
- seen admits;
- mined goes through the unspent check;
- unknown, or no answer, refuses.

The whole hook is bounded at 20 s by the server's own timer. The ARC broadcast's `X-MaxTimeout` for a covenant is 12 s, which leaves the status query and intake inside 20 s and 20 s inside cloak's 30 s. The server keeps admitted covenants in a map keyed by txid until their round is stored.

*Why 20 s:* the measured ARC latency is 4 to 5 s (live round 2). If the testnet measurement in tasks shows the 95th percentile over 12 s, raise `X-MaxTimeout` toward 20 s and the bound toward 25 s, which is still under cloak's 30 s. Record the change in docs/DESIGN.md.

### 4. The chain access says "seen" or "mined", and answers by txid

`broadcast` returns a small result, seen or mined, instead of the status string:
- testnet takes it from ARC's `txStatus`;
- the node reports mined for "already in block chain" and seen for acceptance or "txn-already-known".

`FileWallet.alreadyKnown` stays the one place that recognises the wording.

A new call, `statusOf(txid)`, returns seen, mined or unknown:
- testnet uses ARC `GET /v1/tx/{txid}` (404 means unknown);
- the node uses `getrawtransaction` verbose (confirmations), falling back to `getmempoolentry`.

Callers that only need acceptance, which is the wallet and the round broadcasts, treat both results as accepted.

### 5. Covenants join the round's funding list

`FundedStore`'s `fundingOf(spenders)` becomes the wallet's funding plus every covenant admitted unmined that the round transaction spends, in input order, after the wallet's. A covenant already mined at admission is not kept: it needs no broadcast again, and a mempool-drop test would find it undroppable. (Decided while applying.) They are all parents of the round, so the order among them does not matter; it is fixed only for determinism of the stored list. The record format is unchanged. Start and `_reBroadcastDuringRun` already broadcast the funding list before the round.

### 6. cloak: submit first, broadcast only as a fallback

`cloak deposit` builds and records the deposit, as now. It then submits it with the covenant attached, in place of broadcasting it:
- **accepted:** status `accepted`, and the covenant is marked broadcast, since the coordinator sent it.
- **refused with "is not mined":** this is an older coordinator. cloak broadcasts the covenant itself and sets status `broadcast`, which is the old two-step flow. The text match is deliberate and temporary; it is removed once no coordinator older than this change runs.
- **refused otherwise:** cloak asks its chain whether the covenant txid is known.
  - Unknown: status `refused`, and the funding coins are released, since nothing was spent.
  - Known: status `broadcast`, and the refund path applies.
- **unanswered or unsent:** status `submitting`.

`cloak sync` resubmits deposits whose status is `submitting`, and also still submits `broadcast` deposits once they are mined. A resubmission refused with `depositPending` means the earlier submission is pending, so cloak treats it as accepted.

## Risks / Trade-offs

- **A seen covenant could still lose to a double-spend.** Mitigation: the risk is accepted per the Teranode argument, and the testnet ARC in use may not yet be Teranode. The re-broadcast during a run and at start sends the covenant again. If the chain refuses it, the existing behaviour stops the server naming the transaction, which is an operator rollback. Record it in docs/DESIGN.md if it is ever seen.
- **A round that closes during an admission waits up to 20 s.** Mitigation: only when a deposit arrives in the seconds before the close. The round time is measured with a deposit in it (tasks).
- **ARC's "already known" wording is unverified live.** Mitigation: the status-by-txid query decides any broadcast that ends in a refusal the pattern does not recognise.
- **The library change needs a release on two lines.** tstokenlib 2.0.2 is needed for release/0.1 and 2.2.0 for main. Mitigation: the hook is additive and off by default, so the patch is small. Publishing needs the user's go-ahead. Until then the coordinator side cannot ship.
- **Sending bytes that cloak recorded.** Mitigation: the coordinator broadcasts exactly the submitted transaction, and the covenant's txid is what cloak recorded. A coordinator that changed it could not produce a transaction cloak would accept as its own deposit.
- **The cloak fallback matches refusal text.** Mitigation: it is temporary, it is covered by a test against the old server behaviour, and removing it is a task once overmedia runs the new coordinator.

## Migration Plan

1. **tstokenlib:** land the hook on main, then back-port it to a 2.0.x branch from the v2.0.1 tag. Publish 2.0.2, with the user's go-ahead.
2. **pool-coordinator:** land on main, then cherry-pick to release/0.1 with the lock on 2.0.2. Release 0.1.8, install it on overmedia and run a smoke round with a deposit.
3. **cloak-cli:** release with the new flow. It works against 0.1.7 through its fallback.
4. **Rollback:** reinstall the coordinator's previous .deb. The store format is unchanged, and the old coordinator refuses unmined covenants, which new cloaks fall back from.

## Open Questions

- When to remove cloak's "is not mined" fallback. After overmedia runs 0.1.8 and no other coordinator is known, this can be decided later without changing the specs.
