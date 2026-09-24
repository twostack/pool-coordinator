## Why

The cloak wallet cannot join a running pool, prove a payment it made, or take on its change and deposits against this server. The server drops every message that is not a submission, so libcloak's catch-up requests go unanswered and each costs the wallet a 30 s timeout. There is also no way for a payer to get its round after later rounds are mined, and no word to a submitter when its round is mined. Those are cloak's asks R1 to R5 ("Rounds for Wallets", 2026-09-24). tstokenlib's change `wallet-rounds` supplies the protocol (version 3: catch-up ids and refusals, a round by number, the mined-round notice) and one shared responder. This change is the server's half.

## What Changes

- The server **answers catch-up requests**:
  - **Kinds:** block roots over a published range, the frontier, the head, and a mined round by number.
  - **Refusals:** anything it cannot answer gets a refusal naming why: not mined yet, an unpublished range, or unavailable.
  - **Queue:** requests wait in their own queue of at most 64, so a flood of them never delays a submission's reply; past the bound they are dropped.
- Every answer stands at the **last mined round**, which the server now tracks itself. It is found at start from the store and the chain, and moved up as each published witness is mined. A round published but not yet mined is never answered from.
- A submitter is **sent its mined round**. When the round that took in a peer's accepted submissions is mined, the server sends that peer a mined-round notice naming its submission ids, the round's and witness's txids and the witness's place in its block, but no transactions. The record is held in memory only; after a restart the wallet asks for the round by number.
- **Nothing unasked goes to the replies folder.** Notices, and the expired replies the library gives for a transfer accepted and then dropped at close, go to the peer's `pool/notices` folder. The replies folder holds only answers to what the peer sent. (After libcloak's review.)
- `ChainAccess.placeOf(txid)`: where a mined transaction sits (block hash, index, merkle branch).
  - From the node, via the verbose `getrawtransaction` and `getmerkleproof2`.
  - From WhatsOnChain, via `tx/{id}/proof/tsc`.
  - From the fake chain, with real branches over its blocks.
- `RoundStore.txidsOf` and `rawOf`: a round's txids from its record, and its two transactions as stored, checked by hashing instead of parsing. A production witness is megabytes, and parsing one holds the server's isolate for about a second.
- The mined-round watcher runs whether or not the API is enabled.
- The status file gains the mined tip and the catch-up counters (answered, refused, dropped, notices sent).

Not in this change: the wallet's checking (libcloak), and persisting who submitted what across a restart.

Numbers held, each measured by a test:
- A submission is still answered within 2 s under a flood of 300 catch-up requests: 689 ms measured, with 233 of them dropped at the queue's bound.
- Answers come from a cache of the last 4 mined rounds, and from hashing, not parsing, the stored transactions.

Non-functional contract:
- **Untrusted input:** a request that does not decode has no id to answer and is dropped. Everything decoded is answered or refused. The queue is bounded.
- **Secrets and privacy:** answers carry nothing about who asked beyond the request's own random id. A notice goes only to the peer that submitted the ids it names. Logs record catch-up at fine level.
- **Trust:** nothing the server serves is trusted by the wallet. Branches are checked against the node's own block merkle roots on localnet.
- **Determinism:** the same request gets the same answer until a new round is mined.
- **Compatibility:** protocol version 3, as tstokenlib moves, and a configuration change is not needed.
- **Performance:** catch-up never waits on or delays intake.
- **Failure:** a chain that cannot be asked is an `unavailable` refusal. A notice that cannot be sent is logged, and the wallet can ask.

## Capabilities

### New Capabilities
- `wallet-catch-up`: what the server answers wallets beyond submission replies: catch-up at the last mined round, refusals, the bounded queue, the mined-round notice, and where a round's witness sits in a block.

### Modified Capabilities
None in `openspec/specs/`, which is still empty. `chain-access`, `round-store` and `server-process` live in the unarchived `coordinator-server` change. This change adds to them without changing their requirements, and its spec states the additions.

## Impact

- `lib/src/chain_access.dart` (`TxPlace`, `placeOf`), `node_chain.dart`, `testnet_chain.dart`, `round_store.dart`, `file_round_store.dart`, `server.dart`, `status.dart`.
- Tests:
  - `test/server_test.dart`, a new "catch-up and notices" group.
  - `test/fakes.dart`, real blocks in the fake chain and slow peers in the fake transport.
  - `test/localnet_e2e_test.dart`, notices, head, a round by number and the frontier over ricochet, checked against the node's blocks.
- Depends on tstokenlib's `wallet-rounds` (protocol version 3).
