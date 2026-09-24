## 1. The chain and the store

- [x] 1.1 Add `ChainAccess.placeOf` with `TxPlace` (branch from a block's txids, the root a branch computes, the TSC format with `*` resolved), for the node (`getrawtransaction` verbose, then `getmerkleproof2`), WhatsOnChain (`tx/{id}/proof/tsc`) and the fake chain (real branches over its blocks). Verify with "Answered once round 1 is mined" (fake) and "Branches from the node" (localnet).
- [x] 1.2 Add `RoundStore.txidsOf` and `rawOf`, the file store reading the record and hashing the raw files. Verify through the server tests, whose answers carry the stored witness byte for byte.

## 2. The server

- [x] 2.1 Track the last mined round: find it at start, raise it from the watcher, and run the watcher with or without the API. Verify "Published, not mined" (and that pointing the source at the ledger's round fails it: done, it fails) and "After a restart".
- [x] 2.2 Route catch-up requests to a bounded queue answered by tstokenlib's responder over the server's source. Verify "Refused before round 1 is mined", "Answered once round 1 is mined" and "A flood".
- [x] 2.3 Record accepted submissions by round and sender, drop expired ones, and send each sender its notice when the round is mined, to its `pool/notices` folder (`PoolTransport.notify`; `RicochetTransport.readNotices` for a wallet), never the replies folder. Verify "Each submitter its own ids" and "A round by number later".
- [x] 2.5 Send the library's expired replies to the notices folder, never the replies folder, and build notices from the store's record and the chain's proof alone (the notice carries no transactions since tstokenlib slimmed it). Verify "An expiry" (and that sending it as a reply fails the test: done, it fails) and "Each submitter its own ids".
- [x] 2.4 Add the mined tip and the catch-up counts to the status file. Verify "Counts after answers".

## 3. End to end and records

- [x] 3.1 In the localnet end-to-end test, collect notices and catch-up replies apart from submission replies, and check notices, the head, round 1 by number and the frontier over ricochet against the node's blocks. Verify "Branches from the node" on localnet. (Found here: the test read the status file the moment a round's transactions were mined, before the server had written it; it now waits up to 10 s for the round.)
- [x] 3.2 Add a dated section to `docs/DESIGN.md` and a README note on catch-up. Verify both exist.
- [x] 3.3 Run `dart analyze lib bin test`, `dart test`, `dart test test/transport_test.dart` and the localnet suites. Verify all pass, and report the output. (2026-09-24: analyze clean; `dart test` 135 passed, 3 skipped; transport 8 passed; localnet 7 passed. The first full run failed three cases of `test/chain_fuzz_test.dart`, which fuzzes every chain call and had no sample body for the three new ones; with samples added, all 10,000 mutations of each end in a value or a named `ChainError`, and a new case checks the TSC `*` node on an odd-sized block.)
