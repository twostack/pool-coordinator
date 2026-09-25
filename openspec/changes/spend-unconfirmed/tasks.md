## 1. Prerequisites

- [x] 1.1 Archive `coordinator-server` so `coordinator-wallet`, `server-process` and `round-store` exist under `openspec/specs/`; verify `openspec validate spend-unconfirmed` passes with this change's MODIFIED requirements resolved against them.
- [x] 1.2 Give the fake chain access in `test/fakes.dart` the three things this change's scenarios need: blocks mined on demand, a transaction accepted and not mined until the next block, and a transaction dropped from its mempool. Verify each in `test/fakes_test.dart`.

- [x] 1.3 Build the ricochet host without AutoNAT or hole punching (config by hand, since `Libp2p.new_`'s defaults switch AutoNAT on after the options), and on any failure to open a stream re-add the server's address, dial, and try once more. Verify ricochet-transport "Recovering the server's connection" in `test/transport_test.dart`: the connection closed and the address cleared, then one drain returns the waiting submission and a reply arrives; the host has no AutoNAT service. Both fail against the old transport.

## 2. The Benford split

- [x] 2.1 Vendor libspiffy's `BenfordDistribution` (`lib/src/utils/benford_distribution.dart`, commit 1fe54cc) as `lib/src/benford.dart`, with a header naming the source and the licence. Verify with `test/benford_test.dart` that the outputs sum to the total and that none is below the floor, over 1,000 random totals and counts.
- [x] 2.2 Verify coin-pool "The leading digits follow Benford": 1,000 outputs from splits of totals at least 100 × the floor, each digit's share within 0.05 of log10(1 + 1/d).

## 3. The wallet file, format 2

- [x] 3.1 Add each coin's `height` (null while pending) and the `splits` record to `WalletContents`. Read format 1 by asking the chain access for each coin's height, and write format 2. Verify coin-pool "An old wallet file" with the fake chain, and that an unknown format is refused, naming it.
- [x] 3.2 Verify coordinator-wallet "Nothing in the clear" still holds for format 2: the file's bytes contain no run equal to the key, its public key, an outpoint or a split's txid.

## 4. The coin pool

- [x] 4.1 Add the `wallet.coins` configuration (`floor`, `target`, `low_water`, `split_max_outputs`, with the design's defaults) to `lib/src/config.dart` and both config examples. Verify in `test/config_test.dart` the defaults, and that a floor or target of 0 is refused.
- [x] 4.2 Implement ready and pending classification in `reconcile`: mined, at the owner's address, at least the floor, not offered. Report ready and pending counts and values in `WalletReport` and the status file. Verify coin-pool "A split's outputs mature" and "A coin below the floor".
- [x] 4.3 Implement splitting at the end of `reconcile`: the low-water check, the source choice, the output count capped at `split_max_outputs` and at `total / (2 × floor)`, no change output, recorded before broadcast. Verify coin-pool "Low water refills the store", "Nothing big enough to split" and "A split refused".
- [x] 4.4 Verify coin-pool "A crash before the split's broadcast": the wallet file written with the split and the process stopped before `broadcast`, then a restart broadcasts it exactly once.

## 5. Funding without waits

- [x] 5.1 Rewrite `FileWallet.output`:
  - the smallest ready coin that covers the need, ties broken by outpoint;
  - the round's request gets the coin itself;
  - Y's and the witness's requests get a one-input exact funding transaction, handed over on the broadcast's acceptance;
  - `_waitMined` removed from funding;
  - a request no coin covers waits for a ready coin up to the funding timeout;
  - a request larger than every coin fails at once.

  Verify coordinator-wallet "Three outputs a round" (with the fake chain: no block mined, every funding transaction spends a mined coin, each output handed over within 1 s), "Not enough coins", and coin-pool "A round funded from three coins" and "Waiting for the first split".
- [x] 5.2 Keep re-offering a stranded output, mined or not. Verify coordinator-wallet "A stranded output is reused" and "A top-up is noticed" (pending first, ready after the block).
- [ ] 5.3 Include the funding and split fees in the round's cost. Verify coordinator-wallet "Rounds left" on localnet (`POOL_LOCALNET=1`): 20 test-parameter rounds through at least one split, the figure reported before them within one round's cost of what they spent.

## 6. The round store, version 2

- [x] 6.1 Write record version 2 with the funding txids and store the raw funding transactions beside the round's. Read version 1 as "no funding". Verify round-store "Unknown version", "A round stored before this change" and the existing "A file cut short" for the funding files.
- [x] 6.2 Pass each round's funding transactions from the wallet to the store before the first publish, so the store's write-before-publish still holds. Verify round-store "Files before the first broadcast", now including the funding files.

## 7. The server

- [x] 7.1 Change start's recovery to broadcast in order any unknown funding transaction, then Y, the round and the witness, and to start on acceptance, not on mining. Verify server-process "A stored round the chain does not show" and round-store "The witness was never broadcast" with the fake chain holding blocks back.
- [x] 7.2 Add `server.max_unmined_rounds` (default 10), enforced by holding Y's funding request, with the reason in the status. Verify server-process "The limit holds a round".
- [x] 7.3 Add `server.rebroadcast_after_blocks` (default 3) to the mined watcher: funding first, "already known" counted as success, a refusal recorded as the last failure. Verify server-process "A round dropped from the mempool".
- [ ] 7.4 Verify the robustness of 7.1 to 7.3 by mutation testing: the fake chain answers each broadcast and mined query with an error, a refusal, an "already known" or a drop, 1,000 random sequences over three rounds. Afterwards the server is running, the store and the wallet file agree with the fake chain, and no round is published twice under different txids.

## 8. Create

- [x] 8.1 Rewrite `create`: wait once for the operator's funding to be mined, fund and publish Y_0, the issuance (output 1 of its funding transaction) and witness 0 without waits, split the remainder, then write the genesis and the descriptor. Verify coordinator-wallet "A pool from nothing on localnet" (`POOL_LOCALNET=1`, no block mined after the funding until `create` ends, then `run` opens at round 0 with ready coins after one block).

## 9. Measurements and the record

- [ ] 9.1 Measure on localnet in `tool/scratch/server_cost_probe.dart roundtrip`, extended, the time from a round's close to its announcement with ready coins and no block mined, against the bound of the proof time plus 10 s. Record the proof time, the five broadcast latencies and the total in `docs/DESIGN.md`. Verify coordinator-wallet "From close to announcement".
- [ ] 9.2 Measure in `tool/scratch/create_probe.dart` (new) `create`'s time from the funding being mined to the descriptor on the feed on localnet, against 30 s. Record it in `docs/DESIGN.md`.
- [ ] 9.3 On testnet (overmedia, after upgrading to the release), measure over at least 10 rounds:
  - close to announcement;
  - the deepest unmined round count reached;
  - rounds per block;
  - ARC's answer if a chain is refused as too long (run with `max_unmined_rounds` raised to 30 for one burst).

  Record them in a dated section of `docs/DESIGN.md` with the ARC endpoint, and set the `max_unmined_rounds` default from the measured limit if it is below 30.
- [ ] 9.4 Update `docs/DEPLOYING.md`:
  - `create` waits for one block;
  - the `wallet.coins` settings;
  - the status's ready and pending counts;
  - the first rounds after an upgrade wait for one split to be mined;
  - rollback keeps the format 1 wallet backup.

  Verify by following it on a fresh droplet or on overmedia's upgrade.
- [ ] 9.5 Append the dated section for this change to `docs/DESIGN.md` (the decisions, the measured numbers from 9.1 to 9.3, what changed from the proposal) before archiving; verify it is there.
