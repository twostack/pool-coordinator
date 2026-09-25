## Context

The library asks for funding three times a round (`tstokenlib/lib/src/shielded_pool/shielded_coordinator.dart`):
- **Y**, at `:731`, before proving. Y has no change output.
- **The witness**, at `:920`, after proving and the dry builds, because its fee depends on its size. It has no change output.
- **The round**, at `:921`, right after the witness. It has a change output.

Each call is `CoordinatorFunding.output(minValue)` and returns one `FundingOutput(tx, vout, signer, pubKey)`. `FileWallet.output` (`lib/src/file_wallet.dart`) answers each call the same way: it spends the largest coins into an exact output plus change, broadcasts, and waits in `_waitMined` for a block. So a round's funding is a chain of three transactions, each waiting for a block, and each spending the previous one's change.

The server's `_publish` (`lib/src/server.dart:489`) already broadcasts Y, the round and the witness back to back and announces at the witness's broadcast. `create` (`lib/src/create.dart`) waits in `_publish` for each genesis transaction as well as in the wallet for each funding.

Measured on testnet on 2026-09-25 (overmedia, GorillaPool ARC, WhatsOnChain): one funding transaction mined 5.5 min after its broadcast, another 13 min after. ARC answered `SEEN_ON_NETWORK` to every broadcast, including Y_0, whose parent was then unmined.

## Goals / Non-Goals

**Goals:**
- No funding request waits for a block. The close-to-announcement time is the proof plus seconds of broadcasting.
- No funding transaction spends an unmined output. The only unconfirmed depth the wallet adds is the funding transaction between a mined coin and Y or the witness.
- `create` waits for exactly one block: the operator's funding.
- The unconfirmed depth the pool itself builds up (rounds chaining on unmined rounds) is bounded, and a dropped chain is re-broadcast during a run.

**Non-Goals:**
- A library change to ask for the witness's and the round's outputs in one call. That would save one funding fee a round. It is a tstokenlib change, left for later.
- A new address per coin. Every coin stays at the owner's address, which the pool's genesis makes public anyway. Per-coin addresses would need key derivation in the wallet file for no privacy gain against the pool's own public record.
- Relaxing the mined check on deposits. A third party can double-spend an unmined covenant.

## Decisions

**Hybrid handover.** The round is handed a ready coin directly. Y and the witness are handed an exact output of a one-input funding transaction spending a ready coin.
- The round's change output returns any surplus, so a whole coin costs nothing extra and saves a funding transaction and its fee.
- Y and the witness would lose a whole coin's surplus as fee, and with Benford amounts above a 10,000 sat floor that surplus is thousands of satoshis. So they get an exact output.
- Alternatives:
  - All three through funding transactions: three fees a round, as today.
  - All three handed coins directly: no funding fees, but the surplus on Y and the witness would be burned.
- The user chose the hybrid on 2026-09-25.

**Handover on acceptance, not on mining.** `chain.broadcast` already throws `BroadcastRefusal` on a refusal and returns ARC's `txStatus` (or the node's txid) on acceptance. An acceptance is enough to hand the output over. No new chain-access method is needed.

**Ready means mined.** A coin becomes ready at the reconcile after `chain.minedHeight(txid)` returns a height. The coin records its height in the wallet file, so it is asked once.
- Change from a funding transaction and from a round starts pending, like a split's outputs, and joins the store once mined.
- Alternative: count anything ARC accepted as ready. That makes funding chain on funding again, which is exactly the unbounded unconfirmed depth this change removes.

**Benford splitting, vendored.** `lib/src/benford.dart` is libspiffy's `BenfordDistribution` (`lib/src/utils/benford_distribution.dart`, MIT, same author), copied with its source commit in the header. Its `distribute(total, count, minOutputAmount:)` already clamps each output to a floor and gives the remainder to the last output.
- The wallet builds the split itself, with no change output: the fee comes off the source before `distribute`, as libspiffy's `BenfordCoordinatorActor` does.
- Alternatives:
  - Depend on libspiffy: brings Isar, eventador, spiffynode and the actor stack into the .deb.
  - Extract a shared package: cleaner, one more publish.
- The user chose to vendor it on 2026-09-25.

**The store's settings.** They go in a new `wallet.coins` section of the configuration, with these defaults:
- **`floor`: 10,000 sat.** The largest request measured is the production witness at 2,531 sat (DESIGN.md), plus a 135 sat funding fee. The floor covers four times that.
- **`target`: 30 coins**, ten rounds' worth.
- **`low_water`: 12 coins**, four rounds. A split's outputs become ready one block after the split, so four rounds of ready coins cover a block interval at up to four rounds per block.
- **`split_max_outputs`: 100**, libspiffy's cap.

These only steer the implementation. The spec requires that they are configured and honoured, not their values.

**Coin choice: the smallest ready coin that covers the need.** The large coins stay available for the witness, whose need varies. It is deterministic given the store, with ties broken by outpoint. Coins are never combined for a request. A request no single coin covers waits for the next split instead, and the floor makes that rare.

**When to split.** At the end of each reconcile: at start, after every round, and after `create`'s genesis. Never while a round is funding. The largest mined coin that is not ready (above the target's value, or a top-up) is split first. If none qualifies, the largest ready coin is split. A split never draws the ready count below what one round needs.

**The unmined-round bound.** Configured as `server.max_unmined_rounds`, default 10.
- Each round adds Y, the round, the witness and two funding transactions. Y and the funding transactions hang off mined coins, but the round spends the previous round's outputs, so the pool's own chain grows by three transactions a round.
- Ten rounds is about 30 in-chain ancestors. SV Node's default ancestor limits are far above that. GorillaPool's and TAAL's limits are unmeasured (open question).
- The bound is enforced at Y's funding request, the first thing a closed round does. The library closes rounds on its own deadline timer, so the server cannot stop a close, but it can hold the wallet's answer to Y's request until an earlier round is mined. Nothing is funded or proved meanwhile, and intake goes on. This wait is not limited by `funding_timeout_seconds`: it ends when a block comes, and the status says why the round waits.

**Re-broadcast during a run.** The mined watcher (`_watchMined`, which already follows each witness) records the height at publication. After `server.rebroadcast_after_blocks` blocks (default 3) with the witness still unmined, it broadcasts the funding transactions, Y, the round and the witness again, in order. An "already known" answer counts as success. The funding transactions come from the round store (below), not from the wallet's memory, so this also works after a restart.

**The round store's record, version 2.** It adds the funding txids. Their raw transactions sit beside the round's files. Version 1 is read as "no funding". Since Y's and the witness's funding transactions are parents of the round, a re-broadcast without them fails whenever they were dropped too.

**`create`.**
1. Wait for the operator's funding to be mined. This is the one wait left.
2. Fund Y_0 (the anchor), the issuance (output 1 of its funding transaction, as the library requires) and witness 0, each from the mined funding coin through one-input funding transactions. They chain on each other's change, which only `create` does, three transactions deep.
3. Publish Y_0, the issuance and witness 0 without waiting.
4. Split the remainder.
5. Write the genesis and the descriptor.

The genesis chain is at most seven transactions deep above a mined coin. That is acceptable once per pool.

**The wallet file, format 2.** Each coin gains `height` (null while pending). The file gains `splits`: split transactions written before their broadcast, removed once mined. Format 1 is read by asking the chain access for each coin's height, then written as format 2.

**Decided while applying (2026-09-25):**
- **Which request is the round's.** The library asks `output(minValue)` with no kind, so the server tells the wallet (`lib/src/funding_requests.dart`) from the round's `RoundTiming`, which the library laps as it goes: no `dry builds` lap yet means Y's request; after it, the first request is the witness's and the next on the same timing the round's. Anything else is served as an exact output, which suits every request and costs at most one funding fee. Y can never be taken for the round, since a fresh timing starts every round. The metrics pin test already holds the lap names to the library's.
- **Funding reaches the store through an adapter.** The library calls `roundBuilt` with the three transactions only. The server hands the library `FundedStore(store, wallet.fundingOf)`, which asks the wallet for the unmined transactions it built that the round spends and passes them to the store's `roundBuiltWith`. The hook is not a field of the store because the store is read inside a worker isolate for the history rebuild, and a closure over the wallet cannot be sent to one (it failed exactly so in the first attempt).
- **The bound holds Y's request in the wallet**, through `CoordinatorWallet.beforeRequest`, set by the server. The count is the ledger's tip less the last mined round.
- **`create` needs one payment covering the genesis.** Coins are never combined for a request, and the genesis is funded along one chain of change above one mined coin, so the operator's funding must be a single output of at least the amount `create` names; the prompt says so. The rest of it is split from the unmined change the genesis leaves, the only split made from a pending coin.
- **A round's cost** is the balance's fall between reconciles (a split's fee never falls in it, since a split is made after the measure and before the balance is recorded) plus three coins' share of the last split's fee.
- **Per-split digits.** libspiffy's splitter scales Benford-digit proportions to the total, so the digits of one split's amounts shift with the total. Measured: over 200 splits of 8,990,000 sat into 30 every digit's share is within 0.017 of Benford; over random totals within 0.008. It is vendored unchanged.

## Risks / Trade-offs

- **[A dropped parent drops the round]** If a funding transaction leaves the mempool, Y or the witness goes with it. → Re-broadcast during a run and at start, funding first, from the round store. Testnet's GorillaPool ARC takes 0 sat/kB, so eviction for fee is unlikely, and 1 sat/kB is paid anyway.
- **[Ancestor limits unknown on ARC]** → `max_unmined_rounds` bounds the depth. The testnet trial measures it by lowering the limit and watching for `too-long-mempool-chain`. If ARC refuses at a depth below 30, the default comes down to what was measured, and DESIGN.md records it.
- **[The store runs dry faster than blocks refill it]** At more than four rounds per block the ready coins run out. → Requests wait, logged. The status reports ready and pending counts, and `target` and `low_water` are configurable. A pool that needs more raises them. The trial measures rounds per block.
- **[Benford amounts and the floor]** `distribute` clamps small draws to the floor and takes the difference from others. With a small total the amounts bunch at the floor and stop following Benford. → A split's output count is capped at `total / (2 × floor)`, and the Benford test runs on totals at least 100 × floor.
- **[Reorgs]** A reorg can unmine a ready coin that was already spent into a funding transaction. → The same re-broadcast path covers it. Testnet reorgs are rare, and this is recorded, not engineered for.
- **[Cost]** The split fee (the 135 sat floor per split of up to 100 outputs) is small next to the funding fee this change removes. → The Budget requirement keeps the rounds-left figure exact.

Bounds set before measuring, and what happens if a measurement fails one:
- **Close to announcement within the proof plus 10 s (localnet).** The time outside the proof is two funding broadcasts and three publishing broadcasts. If it fails, the log's lap times name the slow step. If the broadcasts dominate, the witness's and the round's funding are broadcast concurrently. If it still fails, the bound is revised in the spec with the measurement, not loosened silently.
- **`create` within 30 s of the funding being mined.** If it fails, the laps of `create` are measured and the split is moved after the descriptor is written. The descriptor is what `create` is for.
- **Rounds left exact to within one round.** If it fails, the cost measurement in `reconcile` (balance before plus top-ups less balance after) is extended to count split fees explicitly.

## Migration Plan

1. Release as 0.1.1 through the existing release workflow.
2. On overmedia: `apt install` the new .deb. `prerm` stops and `postinst` restarts the coordinator. At start the wallet file is migrated to format 2 and the round store reads version 1 records.
3. The first reconcile splits the existing balance (about 8.99M sat after genesis) into the store. The first round after the upgrade waits one block for the split to be mined, and none after that.
4. **Rollback:** install 0.1.0 again. It refuses a format 2 wallet file ("unknown format"), so keep the pre-upgrade `wallet.enc` from the backup, or restore it: the coins it names are still at the address, and the top-up scan finds the rest.

## Open Questions

- **The ancestor limits of GorillaPool's and TAAL's ARC.** The testnet trial measures them. The answer changes only the default of `max_unmined_rounds`.
- **Rounds per block the pool actually needs on testnet.** The answer tunes `target` and `low_water`, not the design.
