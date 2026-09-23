# pool-coordinator

The TSL1_SP shielded pool coordinator server. It runs a pool from a `ShieldedCoordinator` (tstokenlib): drains a ricochet inbox of wallet submissions, answers each, closes and funds rounds, publishes them to the chain, and announces them on a ricochet feed.

The library, the protocol and the pool's specs live in `../tstokenlib`; this repo holds the server, its wallet, its chain access and its configuration. Changes are planned under `openspec/`; the running design record is `docs/DESIGN.md`.

## Running

```
dart pub get
cp config.example.yaml config.yaml      # and edit the endpoints and paths
POOL_WALLET_PASSPHRASE=... POOL_RPC_PASSWORD=... dart run bin/pool_coordinator.dart create
POOL_WALLET_PASSPHRASE=... POOL_RPC_PASSWORD=... dart run bin/pool_coordinator.dart run
```

`create` generates the owner key and the ricochet identity, writes the wallet and identity files, waits for the printed address to be funded, issues the pool, writes the genesis txids into the configuration and puts the descriptor on the feed. `run` opens or recovers the pool and serves it until SIGINT or SIGTERM. The status is in the configured status file; the log goes to stderr.

The library's native kernels are needed at run time (the note encryption and the provers use them): build `../tstokenlib/native/stark_kernels` and set `STARK_KERNELS_LIB` to the library file. With tstokenlib checked out beside this repo a `native` symlink to `../tstokenlib/native` also works, which is what the tests here use; it is machine-local and not committed. `STARK_KERNELS_GPU=1` proves on the GPU.

## Tests

```
dart test                              # the fakes, config, chain access, wallet, store, server on the test chain
dart test test/transport_test.dart     # needs ../go-ricochet/ricochet built and localnet's PostgreSQL
POOL_LOCALNET=1 dart test test/chain_node_test.dart test/localnet_e2e_test.dart   # needs ../localnet up
```

The ricochet tests start `../go-ricochet/ricochet` themselves (`cd ../go-ricochet && GOTOOLCHAIN=go1.25.7 go build -o ricochet ./cmd/ricochet`) against a database they create on localnet's PostgreSQL (`POOL_RICOCHET_PG` overrides the admin URL) and skip with the build command when the binary is missing.
