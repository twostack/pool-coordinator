## Context

`PoolServer._handle` routes by message kind and drops everything that is not a submission. The server knows its ledger (every block root and, with `frontierAt`, the frontier at any round), its store (every round's transactions) and its chain. It watched published witnesses until mined only when the API was on, for the history. tstokenlib's `PoolCatchUpResponder` holds the answering rules, behind a `CatchUpSource`.

## Decisions

### D1. The server is a `CatchUpSource`
- **Block roots and frontiers:** from the ledger.
- **Mined rounds:** from the store and the chain.
- **The tip:** `minedTip` is the server's own count of the last mined round. The ledger's round counts the last *published* round, which may not be mined.

A test mutating the source to answer at the ledger's round fails "A round published and not yet mined is not answered from".

### D2. The mined tip
- **At start:** walk down from the stored tip to the first round whose witness is mined. A round's witness being mined means every round before it is, since each round spends the witness before it. Then watch the tip until it is mined.
- **As the pool runs:** the watcher, now always on, raises the tip as each published witness is mined.
- **A chain that cannot be asked at start:** the tip is left at 0, and catch-up is refused as not yet mined until the next round.

### D3. A separate, bounded catch-up queue
Catch-up requests leave the inbox at once into a queue of at most 64, answered one at a time by their own loop. Anyone can send them, and a round answer reads megabytes. Answering inline would put a submission behind every catch-up request before it. Past the bound a request is dropped, which the wallet sees as a timeout, the same as a lost message. Measured: 300 requests with a 20 ms send each, 67 answered and 233 dropped, while a submission sent after them was answered in 689 ms.

### D4. Raw bytes, checked by hash
The store's `read` parses each transaction. That is about a second for a production witness, and dartsv's `id` re-serializes and hashes it. `rawOf` reads the files as they are, and checks each by hashing the bytes against the txid the record names, which catches a file cut short as `read` does. The last 4 mined rounds are cached, since wallets ask for the head and their own round again and again.

### D5. Where a witness sits, from the chain
`placeOf` is the verbose `getrawtransaction` (the block hash), then `getmerkleproof2` for that block. WhatsOnChain answers the same TSC format at `tx/{id}/proof/tsc`. The TSC `*` node (the working hash itself, for the last transaction of an odd level) is resolved while reading, so a branch is always plain hashes.

The branch is untrusted by the wallet, which checks it against its own headers. On localnet the end-to-end test checks every branch it is sent against the node's `getblock` merkle root.

### D6. Notices from memory, in a folder of their own
Accepted submissions are held by round and sender until that round is mined, then sent as one notice per sender, to the peer's `pool/notices` folder. (Changed after libcloak's review: the notices first went to the replies folder, and libcloak's transport takes the next message there as the answer to whatever it asked, so a notice arriving during a submission was read as its reply, refused as 719,563 bytes over a reply's 4,096, and the payment reported unanswered. The replies folder now holds only answers. The expired reply the library gives for a transfer accepted and then dropped at close is unasked too, a second message for an answered submission, so it goes to the notices folder as well.) A notice carries no transactions, so the server builds it from the store's record and the chain's proof alone (`CatchUpSource.placed`), reading nothing from the store's transaction files. They are dropped from the record if the library expires them at close. The record is not persisted. After a restart, a wallet whose notice was lost asks for its round by number, which costs it the privacy the notice saves only in that case.

## Risks / Trade-offs

- **A round mined between a wallet's head and frontier requests:** the two disagree and the wallet asks again.
- **A reorg moving a witness to another block:** the cache may serve the old block's branch until evicted. The wallet refuses a branch that does not match its headers and asks again. Accepted on regtest and testnet; worth revisiting with a real reorg rule for mainnet.
