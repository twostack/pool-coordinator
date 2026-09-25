## Context

See proposal.md for why. What exists, read on 2026-09-22:

- **The library** (`../tstokenlib`, feature/shielded-pool, commits ee419ca and bd71835): `ShieldedCoordinator.open(...)` and `recover(...)`, `submitBytes(bytes)` returning a reply or null, `closeRound()` on the library's own deadline through a `CoordinatorClock`, `CoordinatorFunding.output(minValue)` returning a `FundingOutput` (tx, vout, signer, pubkey), `CoordinatorStore.roundBuilt(number, y, round, witness, snapshot)` called after the library's own apply and before the first publish, a `publish(tx)` callback, `notify(reply)` for expired replies, `chainHeight` the server sets, `lastTiming`, `status`, `descriptor(network, issuance, witness0, slot0)`. The messages are `PoolSubmission`, `PoolReply`, `PoolDescriptor`, `PoolAnnouncement`, each with `encode`/`decode`. `ShieldedPoolTool` builds the genesis (Y_0, issuance, witness 0) and needs the funding outputs sized like the localnet harness's. The localnet harness (`test/pool_localnet_test.dart`, `POOL_COORDINATOR=1`) already runs the coordinator against the node with a node-backed funding source that mints exact outputs and mines them; that class is the model for the wallet's funding path.
- **Ricochet** (`../ricochet-dart-client`): `SFClient(host, config, encryptor:)` over a `dart_libp2p` host the application builds (`bin/store_interop_test.dart` `createHost` shows the UDX transport, Noise security and yamux setup; `../overnode_v2/lib/.../ricochet_actor.dart` shows connecting to a server and protecting the connection). `sendMessage({recipient, payload, folderPath, persistent, encrypt})`, `retrieveMessages({folderPath, ...})`, `markMessagesDelivered(ids, folderPath:)`, `appendFeedEntry({path, content, entryType})`, `getFeedEntries({ownerPeerId, path, fromSequence, limit})`, `createFeed`. `PayloadEncryptor.fromEd25519Seed(seed)` seals and opens payloads. Errors come back as null or empty lists. The Go server (`../go-ricochet`) is a binary plus PostgreSQL 14+; localnet's compose has PostgreSQL 16 on 5433 but no ricochet service.
- **Chain**: localnet's node RPC (18332, bitcoin:bitcoin) with `sendrawtransaction`, `getrawtransaction`, `getblockcount`; the harness's `Localnet` class does all of it over HTTP. Testnet: ARC at `https://arc-test.taal.com/v1` (libspiffy names it) and WhatsOnChain's `v1/bsv/test` API (`tx/{txid}/hex`, `tx/hash/{txid}`, `address/{addr}/unspent/all`, `chain/info`).
- **Limits**: ARC parses scriptSigs up to 1,636,802 bytes (measured on localnet, patch drafted upstream), so production witnesses go through node RPC only; test-parameter transactions (Y 413 KB, witness up to 651 KB) fit.

## Goals / Non-Goals

**Goals:**
- One process that runs a pool unattended on localnet and on testnet at test parameters, from a config file and two secret inputs.
- The wallet, chain access and store as interfaces the tests can fake, with real implementations for the node, ARC plus WhatsOnChain, ricochet and the file system.
- Nothing in this repo that belongs in the library: no intake rule, no round logic, no message format.

**Non-Goals:**
- The CLI wallet, and any wallet-side logic (scanning, proving).
- A prover member transport; `provers` stays empty and level 1 proves in-process.
- Running more than one pool per process.
- Fee income, rate limiting by sender, or any reputation for peer ids.

## Decisions

**A single-threaded loop around the library, with the ricochet retrieval as the one timer besides the library's deadline.** The library already serialises rounds and keeps intake open during a build; the server adds a retrieval loop (poll `retrieveMessages` on an interval, since ricochet has no push for a server-side reader that is not subscribed) and an announcement step after each publish. Alternative: `subscribeToMailbox` with notifications. Rejected for the first version: polling every few seconds costs nothing at these volumes and has no reconnection edge cases; notifications can be added later without changing the specs.

**Replies go to `pool/replies` on the sender's peer id, encrypted with the coordinator's identity.** The library's reply carries the submission id, so the wallet matches it; the folder is fixed so the wallet change knows where to read. Encryption uses the client's `PayloadEncryptor`, which needs the identity seed at both ends, which is why the identity is a stored seed and not a generated key.

**The descriptor is the feed's first entry, not a document.** A wallet then needs one address (the coordinator's peer id) and one path (`pool/rounds`) to read everything, and reading from sequence 1 gives the descriptor before any announcement. Alternative: a document at a well-known path. Rejected: two things to fetch and two to keep consistent; the feed is append-only, which is what a descriptor should be.

**The deposit covenant is confirmed by the server, before the library sees the submission.** `pool-coordinator` says a deposit reaches a round "together with the mined transaction holding the depositor's covenant"; the library checks the covenant's terms from the bytes and cannot know whether it is mined. The server asks the chain access for the txid's mined-ness and the outpoint's unspent-ness first, and refuses with the library's `depositCovenant` reason and its own sentence. Cost: one or two chain calls per deposit submission, bounded by the chain access's timeout; deposits are at most 8 a round.

**The wallet is the localnet harness's funding class made persistent, not libspiffy.** It needs one key, one address, a change chain, a top-up scan and exact outputs; libspiffy would bring Isar, eventador and an actor system into a headless process for an import-based UTXO model the wallet does not want. The owner key is the funding key, as in the harness, so one signature scheme covers everything the library signs; a second key would only be worth it once fee income exists. Coins are recorded as the outputs the wallet made plus what the top-up scan finds at the address, so a crash after broadcasting a funding transaction loses nothing: the scan finds the output.

**Funding waits for the funding transaction to be mined.** ARC and the node both accept chains of unconfirmed parents, but the library's round spends three funding outputs and Y's anchor in one transaction, and a witness at production is 2.5 MB; keeping every parent mined keeps the failure modes to one (a refused broadcast) and costs a block time per funding output on localnet and about ten minutes on testnet for the first of a round's three. Alternative: spend unconfirmed. Deferred until testnet shows the wait matters.

**The store is a directory per round with raw files and a small record.** Round N's directory holds `y.tx`, `round.tx`, `witness.tx`, `snapshot.bin` and `round.json` (version, number, three txids), each written to a temporary name and renamed. Alternative: one SQLite or Isar database. Rejected: five files a round that an operator can inspect and copy beat a dependency, and the library's snapshot is already the canonical state.

**Recovery is the library's, plus the chain check.** Start restores the last snapshot, asks the chain access whether the three txids are mined, re-broadcasts what is not (the library's design left re-publishing to the server), then reads any later round from the chain by fetching Y_{N+1} from PP3_N's pin and the round from the anchor's spend, which WhatsOnChain and the node can both answer by outpoint spend lookup; if neither can, the server treats the store's round as the tip and says so. That last path is an open question below.

**Configuration is YAML with secrets elsewhere.** The plan is named (`test` or `production`) because the plan's parameters are the library's; a wrong plan is refused by the library's own check against the pool's PP1. Secrets come from `POOL_WALLET_PASSPHRASE` and `POOL_RPC_PASSWORD` or files the config names, so the config can be committed as an example.

**Two commands, `create` and `run`, in one binary.** `create` is the only time the owner key is generated; it refuses to run when the wallet file exists. It funds the genesis from the wallet after the operator has paid the address, which means `create` polls the top-up scan until the balance covers the genesis (Y_0 at test parameters 414 sat plus the issuance and witness 0).

**Bounds set before measuring, and what happens if they fail.** Submission answered within 2 s at test parameters on localnet: the library's intake is under 50 ms; if the transport's round trip pushes it over, the retrieval interval is the knob, not the bound. Announcement on the feed within 5 s of the witness broadcast: one `appendFeedEntry`; a miss means ricochet is slow or down, and the announcement is retried, not dropped. Ready within 60 s on 1,000 rounds: the library recovers in 11.4 s; a miss means the chain check or the ricochet connection is slow, both of which are measured separately by the tasks. Rounds-left exact to one round: the cost per round varies only with the number of deposits and withdrawals, a few hundred satoshis; a miss means the estimate ignores something it should not.

**Tests.** Unit tests fake the chain access, the wallet's chain and ricochet. The end-to-end test runs on localnet with a ricochet server started by the test (the Go binary against localnet's PostgreSQL, a database the test creates and drops) and drives the server with tstokenlib's fixture transfers sent through a second ricochet client that plays the wallet. Production parameters run only through node RPC, as in the library's harness.

## What implementation changed (2026-09-22)

Decisions above that the code could not keep as written, and what replaced them:

- **Marking delivered does not empty the folder.** The Go server keeps a persistent message after it is marked delivered (it gains the seen flag and stays), and `pool-protocol` on ricochet sends submissions persistent. The transport marks a consumed message delivered and then deletes it; both are on the server's access protocol, so the wire contract in the spec holds and the folder still empties.
- **The ricochet client's streams are not closed.** `SFClient.sendMessage` leaves its submission stream open and `dart_libp2p` 1.0.3's yamux session never takes a closed stream out of its table, so a connection dies at its 256th stream however the streams are handled. The transport opens its own streams for the mailbox calls (retrieve, submit, mark delivered, delete) and closes them, and keeps the client for the feed calls (which close theirs). A stray error the transport stack throws on a future nobody awaits (a session closed mid-dial) is logged in the transport's own zone rather than reaching the caller of an unrelated call.

- **Both yamux defects are fixed upstream (2026-09-23).** They were reported and fixed in `dart_libp2p`, released as 2.0.0, which this server now depends on: a finished stream releases its slot, and the completer that failed with no listener while a SYN was still being written is marked handled. The connection recycling this design added (closing and redialling every 200 streams) is removed; the transport keeps a single redial as the fallback when a connection does refuse a stream. The zone stays, because the ricochet client's own unawaited futures still reach it. Verified before the upgrade by running the transport tests against the fix with recycling disabled: the thousand-submission test passes with no stream-limit error and no stray errors.
- **Reading a round the store lacks from the chain is not attempted.** Neither chain access can say which transaction spent an outpoint; the server asks instead whether the tip's PP3 is unspent, and refuses to start, naming the round, when it is not, since the chain then has a round this server did not build. The open question about WhatsOnChain's spend lookup is closed on that side: the spec's "refuses to build on a tip the chain contradicts" is what the code does.
- **The funding output's index.** The pool's issuance must spend output 1 of its funding transaction (a PP1_SP rule), so the wallet puts the change first and the payment after it, as the localnet harness does; a funding transaction with no change pays at 0, which the library's funding interface takes either way.
- **Intake during a build.** The library proves in the isolate that runs it, so once a round's proving starts no submission is answered until it ends (at test parameters a few seconds, at production minutes). The round-filling submission itself is answered before the proving starts, because the build first awaits the wallet's funding, which is chain I/O. The 2 s bound is measured on submissions that do not arrive during a build; a submission that does is answered when the build ends. Proving in a worker isolate is a library change.
- **The status file and a publish.** The status is written before a publish is released, so a stop that waited for the publish, and a test that saw it end, read a file that already names the round.

## Risks / Trade-offs

- **The Go ricochet server has to be built and run for the end-to-end test.** → The test starts it from `../go-ricochet` if built, and skips with a message naming the build command otherwise; adding it to ../localnet's compose is a task, not an assumption.
- **WhatsOnChain rate limits on testnet.** → The server makes a handful of calls a round; the top-up scan runs at start and after each round only.
- **A wallet that spends unconfirmed nothing, waits for blocks.** → On localnet the test mines; on testnet a round costs three block waits before proving starts, about 30 minutes. Acceptable for a testnet trial; noted as the first thing to relax.
- **The owner key on one disk.** → `create` prints the backup instruction and the wallet file is passphrase-encrypted; custody beyond that is the operator's.
- **Peer ids are free, so the inbox can be flooded.** → Each message costs at most the library's intake plus one chain lookup, and delivered messages leave the folder; a rate limit is not in scope.

## Migration Plan

New repo, nothing to migrate. Rollback is not running it.

## Open Questions

- ~~Whether WhatsOnChain can answer "which transaction spent this outpoint"~~: not needed; the server refuses on a spent PP3 (see above). WhatsOnChain's `tx/{txid}/{vout}/spent` does return the spending txid, so a later change could read the missing round from it.
- Whether ../localnet takes a ricochet compose service, or the test keeps starting the binary: the tests start the binary (`../go-ricochet/ricochet`) against localnet's PostgreSQL on 5433, in a database they create and drop.
