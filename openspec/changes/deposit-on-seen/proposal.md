## Why

A deposit today waits for a block before the coordinator will take it. cloak broadcasts the covenant itself, waits for it to be mined, and only a later `cloak sync` submits it. On testnet that was about 11 minutes on 2026-09-25 (deposits broadcast just after block 1759899 at 15:00:09, mined in 1759900 at 15:10:59), plus a manual step. A covenant also names exactly one round (round N+1 through round N's PP3), so if round N+1 closes while the covenant waits for its block, the deposit can never be taken in and stays locked until its refund height, 144 blocks (about a day) later. The block wait only guards against the covenant being double-spent before its round is mined. On BSV that guard is not needed once the network has seen the transaction: under Teranode a conflicting spend is detected and dropped long before the next block. So the coordinator can admit a deposit as soon as ARC reports it SEEN_ON_NETWORK, provided the coordinator is the one that broadcasts it.

## What Changes

- **The depositor hands the covenant transaction to the coordinator** instead of broadcasting it. The submission already carries the transaction's bytes, so the wire format does not change.
- **The coordinator broadcasts the covenant to ARC** and admits the deposit when ARC reports SEEN_ON_NETWORK or better. "Already known" and MINED count as seen. It broadcasts only after every check of the submission has passed, the spend proof last, so an inbox anyone can write to cannot make it broadcast arbitrary transactions.
- **The deposit's place in the round is reserved while it is being broadcast.** The round it targets cannot close without it, and if the broadcast fails the place is released and padding fills it. This needs a hook in tstokenlib's `ShieldedCoordinator` (see Impact).
- **BREAKING (policy, not wire):** the server no longer refuses an unmined covenant. A covenant that is already mined is still checked unspent, so a covenant spent by its refund cannot be admitted.
- **Admitted covenant transactions are stored with the round** in the funding list the round store already keeps, so a restart or a mempool drop broadcasts them again before the round that spends them.
- **Deposit replies are answered after the broadcast**, within a bound below cloak's 30 s reply timeout. Other submissions keep their 2 s bound: a deposit's broadcast does not hold up the rest of the inbox.
- **cloak's deposit becomes one command**: build, record, submit, and report the outcome. It no longer broadcasts or waits for a block. A refused deposit leaves the depositor's coins unspent, since the covenant was never broadcast. `cloak deposit --broadcast` stays as the fallback for a coordinator that cannot be reached.
- **The refund margin is unchanged.** A refund mined before the round would still invalidate it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `server-process`: "A deposit is confirmed before it is accepted" becomes admission on SEEN_ON_NETWORK through the coordinator's own broadcast. The intake bound gets a separate, longer bound for deposits, and non-deposit submissions keep 2 s while a deposit is being broadcast.
- `round-store`: the transactions stored for re-broadcast include the admitted covenant transactions a round spends, not only the wallet's funding.
- `chain-access`: a broadcast whose transaction the chain already has, or has mined, reports it seen, so the server can tell a covenant it must still check unspent.

Specs in other repos, changed by their own changes and referenced here, never copied:
- tstokenlib `pool-coordinator`, "Deposits by covenant": "together with the mined transaction" becomes a transaction the coordinator admits before the round is built, with the reservation while it does.
- tstokenlib `pool-protocol`, "No secrets in a message": "which the chain publishes once it is mined" becomes "which the coordinator publishes".
- cloak-cli `deposits`: "A deposit is submitted once its covenant is mined" becomes one-command submission.

## Measured numbers and bounds

- **Deposit latency** (built to accepted) moves from one block plus a manual `cloak sync` (about 11 min measured above) to one ARC broadcast. ARC with X-WaitFor SEEN_ON_NETWORK took 4 to 5 s a transaction in live round 2 (docs/DESIGN.md, spend-unconfirmed). The specs make a deposit reply within 20 s a requirement; 20 s is below cloak's 30 s reply timeout (`cloak-cli/lib/src/wallet/config.dart`).
- **Other submissions** keep "answered within 2 s at test parameters on localnet" while a deposit is being broadcast; that is a requirement.
- **Deposits a round**: at most the plan's receipt slots (8), reservations included. That bounds the broadcasts one round can cause and is a requirement.
- **Untouched:** round time from close to announcement (52 to 53 s live) gains nothing on the critical path when the covenants are admitted before the round closes. A task measures it with a deposit in the round.

## Non-functional contract

- **Untrusted input:** the broadcast is the last step of intake, after the proof. The receipt-slot cap bounds broadcasts a round. Covered by requirements.
- **Secrets and privacy:** the covenant transaction was already in the submission and is public once broadcast. The depositor's own address no longer reaches ARC or a node with the covenant, since the coordinator broadcasts it. No new secret is handled. Covered by a requirement.
- **Trust:** the coordinator trusts ARC's SEEN_ON_NETWORK as final for a covenant, as it already does for its own funding (spend-unconfirmed). If the covenant is dropped anyway, the round's re-broadcast of its funding list sends it again. Covered by requirements.
- **Determinism:** not applicable. Admission depends on the network, and the round built from admitted entries is as deterministic as before.
- **Compatibility:** an older cloak that broadcasts and submits after mining still works: its covenant is "already known" or MINED, and is checked unspent. A new cloak against an older coordinator gets "not mined" and falls back to broadcasting and waiting. Covered by requirements and tasks.
- **Performance and resources:** the bounds above.
- **Failure behaviour:** when ARC refuses, times out or cannot be reached, the deposit is refused and its place released. An ambiguous timeout is checked by the transaction's status before refusing, so a covenant the network did see is not refused into a dead round. Covered by requirements.

## Impact

- **pool-coordinator:**
  - `lib/src/server.dart`: `_depositCheck` and `_handle`, deposit replies off the drain loop, and the admitted-covenant map feeding `FundedStore`;
  - `lib/src/testnet_chain.dart` and `node_chain.dart`: the broadcast status and a status query by txid;
  - tests: `server_test.dart` (the deposit cases at lines 270 to 320), `localnet_e2e_test.dart` and `fakes.dart`.
- **tstokenlib:** `ShieldedCoordinator` gains a deposit-admission hook, and intake reserves a deposit's place while the hook runs. This is a library API addition. The coordinator's release branch `release/0.1` is locked to tstokenlib 2.0.1 from pub.dev, so shipping needs a tstokenlib patch release on the 2.0.x line (2.0.2) as well as the change on its main line. Publishing to pub.dev needs the user's go-ahead.
- **cloak-cli:** `lib/src/commands/deposit_commands.dart` (`runDeposit`, `submitWaitingDeposits`), its deposits spec, the README's deposit section, and the localnet e2e test.
- **shieldpool.net:** none. The connect section's commands do not mention the block wait.
- **Operators:** none. There is no new configuration; the admission bound is a constant in design.md.
