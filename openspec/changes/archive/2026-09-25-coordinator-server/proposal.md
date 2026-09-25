## Why

tstokenlib now has everything a TSL1_SP coordinator does (`coordinator-service`, `pool-coordinator`, `pool-protocol` in its specs) and deliberately nothing about where it runs: no transport, no chain access, no wallet, no keys, no run loop. That was the right seam for a library, and it leaves the pool unrunnable. A wallet cannot be tested end to end until a coordinator is listening somewhere, and the coordinator's own deployment questions (which ricochet, how the descriptor is published, what pays the fees, what happens on a crash between publishes) are the ones the wallet inherits. This change builds the process around the library: a headless server that runs one pool over a ricochet inbox and feed, on localnet first and BSV testnet next.

## What Changes

- **A server process** that opens or recovers a pool from its store and the chain, drains a ricochet inbox of submissions, answers each through the library's intake, closes rounds on the library's schedule, publishes the three transactions through the chain access, announces each round on a public feed, and snapshots after every round. It exposes its status as a log and a status file an operator can read, and stops cleanly with nothing half-published.
- **The ricochet mapping of the protocol.** One private mailbox folder for submissions, one reply to the sender's mailbox per submission, one public feed for the pool: its first entry the descriptor, every entry after it an announcement. Every inbox payload is `pool-protocol` bytes and is treated as hostile; a payload that is not a submission is deleted without a reply. Messages are marked delivered as they are consumed so the mailbox never fills.
- **Chain access** behind one interface with two implementations: the localnet node's RPC, and ARC plus WhatsOnChain for testnet. It fetches a transaction by txid, reports the height, broadcasts, and tells the server whether a txid is mined, which is what recovery uses to decide whether a stored round is on the chain, and what intake uses to confirm a deposit covenant before the library sees it.
- **The coordinator's wallet.** The pool's owner key and the funding coins, on disk, encrypted with a passphrase the operator supplies at start. It implements the library's funding interface by spending its own change chain into one output of exactly the value asked, mines nothing itself, notices top-ups by asking the chain access for the key's outputs, re-offers an output a failed round did not spend, and reports its balance and the rounds it can still pay for.
- **A round store on disk**: each round's Y, round, witness and snapshot written before the first publish, as `pool-coordinator` requires; on start, the last stored round is checked against the chain and an unmined transaction is re-broadcast, which the library's design left to the server.
- **Configuration as a file**, with secrets in separate files or the environment: the plan by name, the network, the ricochet server address and the identity file, the pool's genesis txids (or a `create` command that issues a new pool and writes them), the fee rate and floor, the round deadline, the padding stock, the deposit margin, the provers.
- **Two commands:** `create`, which issues a pool from the wallet's coins and writes the descriptor, and `run`.

Not in this change: the CLI wallet (the next change, in its own repo), a prover member transport (level-1 provers stay in-process), fee income for the operator, and any change to tstokenlib beyond what testing reveals, which would be its own change there.

Numbers to hold, each a requirement with a scenario that measures it: a submission is answered within 2 s of arriving in the inbox at test parameters on localnet (the library's intake is 18 ms at production, so the bound is the transport's); an announcement is on the feed within 5 s of the witness being broadcast; the server is taking submissions within 60 s of start on a 1,000-round history (the library recovers in 11.4 s); a round costs the wallet what the library prices, about 4,400 sat at production and 1 sat/kB, so a wallet report of rounds-left is exact to within one round. Testnet runs at test parameters: production witnesses are over ARC's 1,636,802-byte parse limit, and TAAL's testnet ARC is assumed to share it until measured.

The specs also carry the non-functional contract: an inbox anyone can write to; the owner key and ricochet identity never in a log, a config example or a reply; nothing on the feed a wallet cannot check against the chain; the same rounds and the same config giving the same descriptor and feed; a versioned store and config; what a crash leaves behind at every point of a round.

## Capabilities

### New Capabilities
- `server-process`: the run loop from start to stop: recovery, intake from the inbox, closing, publishing, announcing, snapshots, status, shutdown, and the configuration it runs from.
- `ricochet-transport`: how the protocol's four messages ride ricochet: folders, replies, the feed, delivery marking, identity, limits, and hostile senders.
- `chain-access`: fetching, height, broadcast and mined-ness behind one interface, on the localnet node and on testnet through ARC and WhatsOnChain.
- `coordinator-wallet`: custody of the owner key and the funding coins, exact-value funding outputs, the change chain, top-ups, re-offers, budget reporting, and the encryption at rest.
- `round-store`: the on-disk record of every built round and snapshot, written before publishing, and what the server does with it on start.

### Modified Capabilities
None in this repo. The library specs this builds on (`coordinator-service`, `pool-coordinator`, `pool-protocol`, `pool-ledger`, `pool-transfer` in ../tstokenlib) are unchanged; anything testing turns up there becomes a change there.

## Impact

- New Dart package in this repo: `lib/` (server, transport, chain access, wallet, store, config), `bin/pool_coordinator.dart` (`create`, `run`), `test/` against tstokenlib's test chain, localnet and a local ricochet server.
- Dependencies: tstokenlib and ricochet-dart-client as path dependencies, dartsv, http, yaml, args.
- Localnet gains a ricochet server for the end-to-end test (the Go binary against localnet's PostgreSQL, or a compose service if ../localnet takes one); which is a task, not an assumption.
- tstokenlib: no code change expected. If the funding interface or the descriptor needs something the server finds missing, that is a change in tstokenlib.
- The CLI wallet change reads this change's feed layout and folder names as its contract.
