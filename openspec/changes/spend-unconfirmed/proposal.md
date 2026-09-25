## Why

A round's time is set by blocks, not by the CPU. The wallet builds each of a round's three funding transactions on the previous one's change and waits for each to be mined before handing it over (`coordinator-wallet`, "Exact funding outputs"). So a round waits for three blocks, one after another: about 30 minutes on testnet before and around a proof that takes seconds at test parameters (3.7 to 5.1 s, DESIGN.md) and 264 s on the GPU at production. Rounds are built one at a time, so the pool can never do more than about two rounds an hour, however fast the machine. `create` waits for six blocks. The first live testnet `create`, on 2026-09-25, took 5.5 and 13 minutes for two of them.

Two things couple rounds to blocks: the wallet keeps no store of coins that are already mined, and it spends each coin only after it is mined. Publishing already trusts unconfirmed chains: Y, the round and the witness are broadcast back to back, and the announcement goes out when the witness is broadcast. The waits sit on the three cheapest transactions, which only the coordinator's key can spend.

## What Changes

- **A coin pool.** The wallet keeps a store of confirmed coins at the owner's address. It fills the store by splitting larger coins into many outputs whose amounts follow Benford's law. It uses libspiffy's `BenfordDistribution`, the same splitter overnode_v2 uses for this purpose, with a floor so that every coin in the store can pay for any single funding request. It refills the store when it runs low, and a split's outputs become usable once the split is mined.
- **Funding without waits (BREAKING in `coordinator-wallet`).** Each request is served from one confirmed coin in the store, and the result is handed over as soon as the network accepts it, with no wait for a block:
  - **The round's request:** served by the confirmed coin itself. The round has a change output, so nothing is lost.
  - **Y's and the witness's requests:** served by an exact-value output of a funding transaction that spends one confirmed coin. That output is unconfirmed and one transaction deep. Y and the witness have no change output, so a whole coin would lose its surplus as fee.

  A round's funding therefore never builds on another unconfirmed funding transaction, and no funding request waits for a block.
- **`create` publishes the genesis without waits.** It waits once, for the operator's funding to be mined. It then publishes the three funding transactions, Y_0, the issuance and witness 0 without waiting for any of them, and splits the rest of the funding into the store. Six block waits become one.
- **A limit on unmined rounds.** A round does not close while the number of published but unmined rounds is at a configured limit. This keeps the pool's chain of unconfirmed transactions under the ancestor limits of ARC and the node.
- **Re-broadcast during a run.** A published round still unmined after a configured number of blocks has its funding transactions, then Y, the round and the witness broadcast again in order. At start, the funding parents of a stored round are re-broadcast before the round itself, and the server starts once the network has accepted them, instead of once they are mined.
- **The transport recovers its connection.** The live testnet pool lost its only connection to ricochet at 02:36:58Z on 2026-09-25, when an ambient AutoNAT v2 dial-back closed it, and the host forgot the server's address with it. The transport redialled only on a "Maximum streams" error, so every drain failed with "No addresses found in peerstore" for hours and no submission arrived. The host is now built without AutoNAT or hole punching (dart_libp2p 1.0.3's defaults switch AutoNAT on after the options, so `Libp2p.autoNAT(false)` does nothing), and any failure to open a stream re-adds the address, dials and tries once more. It ships with the coin pool, in 0.1.1.
- **Unchanged:** a deposit's covenant must still be mined before intake. The notices to submitters and the catch-up answers still stand at the last mined round.

What this moves, and the bounds it must stay inside:

- **From a round closing to its announcement: at most the proof time plus 10 s** (a requirement). Today it is three block waits plus the proof.
- **`create`, from the operator's funding being mined to the descriptor on the feed: at most 30 s at test parameters** (a requirement). Today it is six block waits.
- **What a round costs the wallet.** Today it is three funding fees plus the library's figures (4,790 and 5,117 sat measured at production, DESIGN.md). After this change it is two funding fees plus the library's figures plus the split fee spread over the coins a split makes. The rounds-left figure must stay exact to within one round (a requirement, as today).

## Capabilities

### New Capabilities
- `coin-pool`: the coordinator's store of confirmed coins. This covers the Benford split and its floor, refilling at a low-water mark, when a coin counts as ready, and what the status reports about the store. It also covers the non-functional contract: amounts drawn from a secure random source, coins only ever at the owner's address, what a crash during a split leaves behind, and the memory and fees a split costs.

### Modified Capabilities
- `coordinator-wallet`: "Exact funding outputs" changes. A funding request is served from a confirmed coin in the store and handed over once the network accepts it: an exact output for Y and the witness, the coin itself for the round. "Creating a pool" changes to one wait, for the operator's funding. "The change chain and top-ups" changes: change and top-ups go into the store once they are mined.
- `server-process`: gains the limit on unmined rounds and re-broadcast during a run. Start waits for the network to accept a stored round's transactions and their funding parents, not for them to be mined.
- `round-store`: the record of a round names its funding transactions, so they can be re-broadcast before the round.
- `ricochet-transport`: gains recovering the server's connection, and a host with no dial-back service.

These capabilities were introduced by `coordinator-server`, which is not archived yet. It must be archived before this change is, so that the modified requirements exist under `openspec/specs/`.

## Impact

- **Code:** `lib/src/file_wallet.dart` (the store, split, handover), `lib/src/wallet_file.dart` (whether each coin is mined, the split record, file format 2 reading format 1), `lib/src/create.dart`, `lib/src/server.dart` (limit on unmined rounds, re-broadcast, start), `lib/src/file_round_store.dart` (funding txids), `lib/src/config.dart` (the store's settings, the unmined limit), `lib/src/status.dart`. A new `lib/src/benford.dart`, vendored from libspiffy (MIT, same author, with its source commit named in the header).
- **tstokenlib:** no change. The library's `CoordinatorFunding.output(minValue)` stays as it is (`pool-coordinator`, "Funding and fees": each of Y, the round and the witness spends one funding output it is given). What this repo adds is where those outputs come from and when they are handed over. The library deliberately leaves that to the server ("the library stays wallet-free").
- **Dependencies:** none added. libspiffy itself is not a dependency, because it would bring Isar, eventador, spiffynode and the actor stack into the server package.
- **Operations:** the wallet file moves to format 2. An old file is read and rewritten, so an upgrade needs no action. A pool created before this change keeps running. Its first rounds after the upgrade wait for the first split to be mined, one block.
- **Transport:** `lib/src/ricochet_transport.dart` builds its host config by hand (`newConfig`, `apply`, `applyDefaults`, then AutoNAT and hole punching off, `newNode`) and reconnects on any stream-open failure.
- **Non-functional areas not affected:** untrusted input (nothing new is read from the network; deposits keep their mined check), and the API.
