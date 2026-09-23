## 1. The package and its fakes

- [x] 1.1 Make `pool_coordinator` a Dart package with `lib/`, `bin/pool_coordinator.dart` (`create`, `run`), `test/`, path dependencies on tstokenlib and ricochet, and `docs/DESIGN.md` started with a dated section for this change; verify `dart pub get` and `dart analyze lib bin test` clean.
- [x] 1.2 Define the interfaces in `lib/src/chain_access.dart` (fetch, height, broadcast, mined, unspent), `lib/src/wallet.dart` (the library's `CoordinatorFunding` plus balance, rounds left, top-up scan, owner signer), `lib/src/round_store.dart` (the library's `CoordinatorStore` plus read-back) and `lib/src/transport.dart` (drain, reply, announce, feed read), each with an in-memory fake in `test/fakes.dart`; verify the fakes with `test/fakes_test.dart`.

## 2. Configuration

- [x] 2.1 Write `lib/src/config.dart`: the YAML file (plan name, network, chain access and endpoints, ricochet address, identity file, wallet file, store directory, genesis txids, fee rate and floor, deadline, padding stock, deposit margin, retry counts, timeouts), secrets from `POOL_WALLET_PASSPHRASE` / `POOL_RPC_PASSWORD` or named files, and `config.example.yaml`; verify server-process "A field missing" (each required field removed in turn is named) and "Secrets not in the file" (the example holds no key, seed, passphrase or password) in `test/config_test.dart`.

## 3. Chain access

- [x] 3.1 Implement the node implementation over RPC (`sendrawtransaction`, `getrawtransaction`, `getblockcount`, `gettxout`) with timeouts and retries; verify chain-access "The localnet node" and "Resources" against localnet (`POOL_LOCALNET=1`) and against a fake HTTP server that hangs.
- [x] 3.2 Implement the testnet implementation (ARC broadcast with the extended format, WhatsOnChain fetch, height, tx status, address unspent) with the scriptSig limit check; verify chain-access "Testnet" and "Size limits are known before sending" with a fake HTTP server replaying recorded WhatsOnChain and ARC responses, and "ARC without peers" (STORED is a refusal).
- [x] 3.3 Verify chain-access "A wrong transaction returned" and that every malformed response (10,000 random and mutated bodies per endpoint) ends in a named error.

## 4. The wallet

- [x] 4.1 Implement `lib/src/wallet_file.dart`: a versioned file holding the owner key and the outputs, encrypted under a passphrase (a memory-hard KDF and an AEAD from `package:cryptography`), owner-only permissions; verify coordinator-wallet "Wrong passphrase" and "Nothing in the clear" (the file's bytes hold no run equal to the key, its public key or an outpoint).
- [x] 4.2 Implement funding: the change chain, exact-value outputs at the configured rate, wait-for-mined through the chain access, the top-up scan at start and after each round, re-offering an unspent output; verify "Three outputs a round" and "A stranded output is reused" with the fake chain access, "Not enough coins" and "Refused funding transaction" for the failure paths, and "A top-up is noticed".
- [x] 4.3 Implement the budget report; verify "Rounds left" (100,000 sat after a 4,400 sat round reports 22, within one).

## 5. The round store

- [x] 5.1 Implement the directory-per-round store with atomic writes, the versioned record, read-back and snapshot pruning; verify round-store "Files before the first broadcast" (with the fake chain access recording the order), "A file cut short", "Unknown version", "A copied store" and "Old snapshots pruned".

## 6. Ricochet transport

- [x] 6.1 Implement the host and client setup (identity seed file, UDX, Noise, yamux, connect and protect the configured server), the drain of `pool/submissions` with delivered marks, replies to `pool/replies` encrypted, the `pool/rounds` feed with the descriptor first, and send retries; verify ricochet-transport "A submission arrives where the server reads", "A reply arrives where the wallet reads", "Descriptor first", "Announcements in order", "Reading from a sequence" and "The same peer id across restarts" against a local Go ricochet server started by the test (skipped with the build command when `../go-ricochet` has no binary).
- [x] 6.2 Verify "A thousand submissions", "A reply that cannot be sent" (the ricochet server stopped between drain and reply), "A fresh sender per submission" and "Random bytes in a message" (100 random payloads).

## 7. The server

- [x] 7.1 Implement `lib/src/server.dart`: start (config, wallet, store, chain access, transport, recovery through the library with the chain check and re-broadcast), the drain loop, the deposit confirmation before intake, the library's publish and notify callbacks, the announcement after the witness, the status file and log, shutdown on SIGINT/SIGTERM; verify server-process "Restart after two rounds", "A stored round the chain does not show", "Snapshot restored", "The witness was never broadcast", "A covenant not yet mined", "A broadcast refused", "Status after a round" and "Stop during a publish" with the fakes and tstokenlib's test chain.
- [x] 7.2 Implement `create`: keys, wallet file, waiting for funding, the genesis through the library's tool sized like the localnet harness, the config's genesis txids written, the descriptor appended; verify coordinator-wallet "A pool from nothing on localnet".
- [x] 7.3 Verify server-process "Mutated submissions through the inbox" (1,000 mutations through the fake transport) and "Nothing secret in the output" (log and status searched for the owner key, the seed and every submitted transfer's bytes).

## 8. End to end and measurements

- [x] 8.1 Run the end-to-end test on localnet at test parameters: `create`, then a second ricochet client plays the wallet and submits the fixture's round-1 transfers with the deposit and then its round-2 transfers; verify server-process "Both rounds of the test chain through the server" (both mined, two announcements after the descriptor, a reader from the descriptor reaches the status's header), "A submission is answered" (under 2 s), "The folder is not left to fill" (1,100 messages), and ricochet-transport's feed scenarios on the real feed.
- [x] 8.2 Measure in `tool/scratch/server_cost_probe.dart` the submission round trip (inbox to reply, bound 2 s), the announcement delay (witness broadcast to feed entry, bound 5 s), and start-to-ready on a store whose snapshot is the library's 1,000-round synthetic one (bound 60 s); record them, with the machine and the ricochet server's location, in `docs/DESIGN.md`.
- [x] 8.3 Run the production chain through the server on localnet via node RPC (`POOL_PRODUCTION=1`, GPU on) once, to show the wallet's three funding transactions and the round's cost; record the cost and the rounds-left figure in `docs/DESIGN.md`.

## 9. Docs and the suite

- [x] 9.1 Write the dated section in `docs/DESIGN.md`: the process, the ricochet layout (folders, feed, identity), the chain access, the wallet, the store, the config, with the numbers from 8.2 and 8.3, and the testnet plan (test parameters, ARC limit, what is unmeasured).
- [x] 9.2 Run `dart analyze lib bin test` (0 errors) and the full suite (`dart test`), and report the counts.
