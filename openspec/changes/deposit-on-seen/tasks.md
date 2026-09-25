## 1. Prerequisites

- [x] 1.1 Give the fake chain access in `test/fakes.dart` what this change's scenarios need:
  - a broadcast that reports seen or mined;
  - a broadcast delayed by a set time;
  - a broadcast that never answers;
  - `statusOf` answering seen, mined or unknown per txid.

  Verify each in `test/fakes_test.dart`.
- [x] 1.2 Confirm `openspec validate deposit-on-seen` passes. The REMOVED "A deposit is confirmed before it is accepted" must resolve against `openspec/specs/server-process`, and the round-store ADDED requirement must not collide with spend-unconfirmed's MODIFIED ones.

## 2. tstokenlib: the admission hook (in ../tstokenlib, on its main line)

- [x] 2.1 Open a tstokenlib OpenSpec change, `deposit-admission`. It modifies `pool-coordinator` "Deposits by covenant" (the covenant admitted before the round is built, its place held while it is) and `pool-protocol` "No secrets in a message" ("which the coordinator publishes"). Verify `openspec validate` there.
- [x] 2.2 Add the optional admission hook and the asynchronous entry point to `ShieldedCoordinator`, per design 1. With no hook, `intake` and `submitBytes` are unchanged. Verify tstokenlib's existing coordinator tests pass unmodified.
- [x] 2.3 Implement the reservation: an admitting entry counts toward capacity, receipt slots, the covenant's pending key and the nullifiers. A refused admission leaves the pending round at once, and cancels the deadline when the round is left empty. Verify with the fake clock:
  - a ninth deposit is refused while eight are admitting;
  - the same covenant again is refused as a pending deposit while the first is admitting;
  - a refused admission frees the slot for the next deposit.
- [x] 2.4 Add the `admission` stage to `_buildAndPublish`: await open admissions, drop the refused ones with no second reply (their refusal went back through the entry point), and let padding fill their places. Verify both close paths:
  - a round closed by its deadline during an admission is built with the deposit when the hook later reports seen;
  - it is built with padding in the deposit's place when the hook reports refused.
- [x] 2.5 Verify that the hook is called only after the proof. A deposit with a bad proof, a wrong PP3, a close refund or no slot is refused with the hook never called. Mutation test: move the hook call before the proof check and confirm the test fails.
- [x] 2.6 Back-port 2.2 to 2.4 to a 2.0.x branch from the v2.0.1 tag and bump it to 2.0.2. Run the coordinator suite against it through a path override. Publishing 2.0.2 (and the main line's next minor) to pub.dev waits for the user's go-ahead.

## 3. pool-coordinator: chain access

- [x] 3.1 Make `broadcast` report seen or mined, per design 4:
  - testnet from ARC's `txStatus`;
  - the node from acceptance, "txn-already-known" (seen) and "already in block chain" (mined);
  - a recognised "already known" refusal reported as accepted.

  Update the wallet's and the server's callers to treat both as accepted. Verify chain-access "A transaction already mined" and "A transaction already in the mempool" on localnet, and "ARC without peers" still refused.
- [x] 3.2 Add `statusOf(txid)`: ARC `GET /v1/tx/{txid}` with 404 as unknown on testnet; `getrawtransaction` verbose, then `getmempoolentry`, on the node. Unparseable answers are an error naming the endpoint. Verify chain-access "After a broadcast that timed out" (fake) and "A transaction never sent" (localnet and a recorded ARC 404).

## 4. pool-coordinator: admission in the server

- [x] 4.1 Replace `_depositCheck` with the admission hook of design 3: broadcast, the mined-then-unspent check, the status query on a timeout or a chain error, the 20 s bound, and the 12 s `X-MaxTimeout` for a covenant. Verify server-process:
  - "An unmined covenant is admitted";
  - "A mined covenant, as an older wallet sends it";
  - "A mined covenant already refunded";
  - "The broadcast is refused".

  Use the fixture's deposit in `test/server_test.dart`, rewriting the current not-mined refusal cases at lines 270 to 320.
- [x] 4.2 Take deposit replies off the drain loop (design 2). Verify server-process "A deposit and three transfers together": a 5 s fake broadcast, each transfer answered within 2 s, the deposit within 20 s. The test fails against the sequential `_handle`.
- [x] 4.3 Verify server-process:
  - "A broadcast that does not answer" and "…but the network saw it", with the fake's never-answering broadcast and `statusOf`;
  - "More deposits than receipt slots";
  - "The round cannot close without it", through the server with the fake clock.
- [x] 4.4 Verify server-process "A bad proof is never broadcast" through the server: the fake chain records no broadcast. Mutation test: call the hook from the server before the library's checks and confirm the test fails.
- [x] 4.5 Verify server-process "What the server records of a deposit": after an admission, the log and `status.json` contain the covenant txid and no other substring of the transaction's hex longer than 16 characters.

- [x] 4.6 With the move to tstokenlib 2.0.2 (release/0.1) or the main line's next minor, add the library's new first lap, `admission`, to `libraryLaps`, `stageAfter` (proving) and `buildLaps` in `lib/src/metrics/round_stage.dart`. Verify with the pin test in `test/metrics_test.dart`. Against 2.0.2 through a path override it fails without the lap and passes with it (checked 2026-09-25; the rest of the suite, 185 tests, passed).

## 5. pool-coordinator: covenants with their round

- [x] 5.1 Keep admitted covenants by txid and add those the round transaction spends to `fundingOf` (design 5), cleared once the round is stored. Verify round-store "A round with no deposit": the stored funding list is unchanged byte for byte.
- [x] 5.2 Verify round-store "A covenant the network dropped": store round 5 with a deposit, report the covenant unknown at start, and see it broadcast before round 5's round transaction, then start. Also check it through `_reBroadcastDuringRun` with the fake's dropped transaction.

## 6. cloak-cli (in ../cloak-cli)

- [ ] 6.1 Open a cloak-cli OpenSpec change modifying `deposits` "A deposit is submitted once its covenant is mined" into one-command submission with the fallback of design 6. Verify `openspec validate` there.
- [ ] 6.2 Implement design 6 in `runDeposit` and `submitWaitingDeposits`, including the status `submitting`, a `depositPending` refusal treated as accepted, and the funding coins released only when the chain does not know the covenant. Verify against an in-process coordinator on the new behaviour: accepted in one command, nothing broadcast by cloak.
- [ ] 6.3 Verify the fallback against the old behaviour: a coordinator stub that refuses "is not mined" makes cloak broadcast and report the old two-step flow. A refused deposit whose covenant the chain does not know leaves the funding coin spendable (`cloak balance`).
- [ ] 6.4 Update cloak's README deposit section: one command, what a refusal leaves, and `--broadcast` as the fallback. Verify the README's commands against `cloak deposit --help`.

## 7. End to end and measurement

- [x] 7.1 Extend `test/localnet_e2e_test.dart`: a round-1 deposit submitted unmined through ricochet is admitted, the round is mined with its receipt, and no block is mined between the submission and the reply. Verify it fails against the current server.
- [ ] 7.2 Run cloak-cli's localnet e2e against the new server: `cloak deposit` then `cloak sync`, with no block mined in between, yields the depositor's note once the round is mined.
- [ ] 7.3 Measure on testnet after the release, with scratchpad `deposit_latency.sh`:
  - ten deposits' reply times;
  - the covenant's ARC broadcast time;
  - one round's close-to-announcement time with a deposit admitted during the close.

  Record the median and maximum in docs/DESIGN.md. If the maximum reply time exceeds 15 s, apply design 3's fallback and record it.

## 8. Release and record

- [ ] 8.1 Write the dated docs/DESIGN.md section for this change: the decision, the rejected server-only alternative and why, and the measured numbers from 7.3.
- [ ] 8.2 Release, following the release flow once the user approves publishing tstokenlib 2.0.2:
  - cherry-pick to release/0.1 with the lock moved to 2.0.2;
  - release 0.1.8 and install it on overmedia;
  - run a smoke round with a real `cloak deposit`.

  Verify the deposit is accepted with no block between the submission and the reply, and the round announced.
- [ ] 8.3 Release cloak-cli with the new flow. Verify a fresh install deposits into the live pool in one command.
