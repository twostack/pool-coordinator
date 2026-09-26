# pool-coordinator

The TSL1_SP shielded pool coordinator server. It runs a pool from a `ShieldedCoordinator` (tstokenlib): drains a ricochet inbox of wallet submissions, answers each, closes and funds rounds, publishes them to the chain, and announces them on a ricochet feed.

The library, the protocol and the pool's specs live in `../tstokenlib`; this repo holds the server, its wallet, its chain access and its configuration. Changes are planned under `openspec/`; the running design record is `docs/DESIGN.md`.

## Releases

Each tag `vX.Y.Z` publishes a GitHub release of this repository with a Debian package for amd64 and for arm64 (`pool-coordinator_X.Y.Z_<arch>.deb`, Ubuntu 22.04 and later, Debian 12), a disk image for Apple Silicon Macs (`pool-coordinator-X.Y.Z-macos-arm64.dmg`, macOS 14 and later, signed with the Werkswinkel Developer ID and notarized), and `SHA256SUMS`. They need no Dart, Rust or Node: the kernels and the web site are inside. `pool-coordinator check` says what an install can do. Install instructions follow in a later change; the packaging is `deploy/debian/`, `scripts/` and `.github/workflows/release.yml`, and `./build-deb.sh` and `scripts/package-macos.sh` build the same packages locally. The workflow leaves each release a draft until the signed macOS disk image is built on a Mac with the Developer ID certificate; [docs/RELEASING.md](docs/RELEASING.md) has the steps. [docs/DEPLOYING.md](docs/DEPLOYING.md) runs a dev pool on testnet from these packages, on one DigitalOcean droplet.

## Running from source

The dependencies come from pub.dev. To build against sibling checkouts of tstokenlib and ricochet-dart-client instead, copy `pubspec_overrides.yaml.example` to `pubspec_overrides.yaml` (gitignored). With it in place `dart pub get` writes the local paths into `pubspec.lock`; commit a lock resolved without it, since the release build refuses anything else (`dart pub get --enforce-lockfile`).

```
dart pub get
cp config.example.yaml config.yaml      # and edit the endpoints and paths
POOL_WALLET_PASSPHRASE=... POOL_RPC_PASSWORD=... dart run bin/pool_coordinator.dart create
POOL_WALLET_PASSPHRASE=... POOL_RPC_PASSWORD=... dart run bin/pool_coordinator.dart run
```

`create` generates the owner key and the ricochet identity, writes the wallet and identity files, waits for the printed address to be funded, issues the pool, writes the genesis txids into the configuration and puts the descriptor on the feed. `run` opens or recovers the pool and serves it until SIGINT or SIGTERM. The status is in the configured status file; the log goes to stderr.

The library's native kernels are needed at run time (the note encryption and the provers use them). tstokenlib's build hook provides them to `dart run`, `dart test` and `dart build cli`: the prebuilt library its version pins, or one built with cargo when the crate has been edited, so a development checkout needs nothing set. `STARK_KERNELS_LIB` still points the program at another library file. `STARK_KERNELS_GPU=1` proves on the GPU.

Wallets are also answered beyond submission replies: catch-up requests (the head, the frontier, block roots, a mined round by number) at the last mined round, and each submitter is sent its round when it is mined. Protocol version 3, from tstokenlib; the status file counts them under `catchUp`.

## The public page

The pool's landing page shows its rounds as they are mined, the round being built and its stage, and the pool's figures. It has three parts, all optional for running the pool:

- **The API.** Add an `api:` section to the configuration (see `config.example.yaml`) and `run` records a history of the pool's rounds in `api.metrics_file` (`metrics.sqlite` beside the configuration by default) and serves it read-only on a loopback port (8787 by default): `/api/pool`, `/api/rounds`, `/api/stats`, `/api/series` and the event stream `/api/events`. It serves nothing per submission and nothing of the wallet, and rounds every time to the publication interval (30 s). A missing history is rebuilt from the store and the feed after start; the file can be deleted at any time. It needs the system's libsqlite3; without it the API stays off and the pool runs as before.

  ```yaml
  api:
    enabled: true
  ```

- **The site.** Static files built from `web/` (Node 20, at build time only):

  ```
  cd web && npm ci && npm run build      # writes web/dist; fails over the 150 KB gzipped budget
  npm run dev                            # a dev server that proxies /api to 127.0.0.1:8787 (POOL_API overrides)
  ```

  The same elements ship as a package for other pages, `pool-elements` (`npm run pack:elements` in `web/`, attached to each release); `web/pool-elements/README.md` documents the elements, the API base and the `--pool-*` theme properties.

- **The proxy.** Caddy serves `web/dist` and forwards reads of `/api/` with TLS, a rate limit and the content security policy. It needs a Caddy built with the rate-limit module; `deploy/README.md` has the build line and how to run it:

  ```
  POOL_DOMAIN=pool.example.org POOL_SITE=/srv/pool-dashboard/dist POOL_API=127.0.0.1:8787 \
    build/caddy run --config deploy/Caddyfile --adapter caddyfile
  ```

To watch it on localnet, `tool/localnet_pool.dart` starts a disposable pool in one command: a ricochet server, a pool created and funded from the node's wallet, the coordinator running it with the API on port 8787, and a block mined every 2 s. With `--sim` it also runs the wallet simulator, so rounds keep coming. Ctrl-C stops everything and removes what it made (`--keep` keeps the folder, with the coordinator's log and the history):

```
dart run tool/localnet_pool.dart --sim   # from the repository's root; needs ../localnet up and the ricochet server built
cd web && npm run dev                     # the page, at http://localhost:5173
```

The simulator, `tool/wallet_sim.dart`, also runs on its own against any pool `run` is serving on localnet. Each round it proves deposits funded from the node's wallet (the round's real transfers), fills the rest with padding so the round closes at once, submits them, and waits for the round's announcement. It never spends the notes it makes, so it is load for the coordinator, not a wallet (that is cloak):

```
POOL_RPC_PASSWORD=bitcoin dart run tool/wallet_sim.dart -c config.yaml --mine-every 2    # a round every 30 s until Ctrl-C
```

`--deposits` sets the real transfers a round (up to the plan's receipt slots, 2 on the test plan; 0 sends padding only and needs no node), `--every` the seconds between rounds, `--rounds` a count to stop after, and `--mine-every` mines a block that often so rounds do not wait on localnet's ten-minute autominer. The coordinator's peer id is read from its status file unless `--coordinator` names it.

## Tests

```
dart test                              # the fakes, config, chain access, wallet, store, server on the test chain
dart test test/transport_test.dart     # needs ../go-ricochet/ricochet built and localnet's PostgreSQL
POOL_LOCALNET=1 dart test test/chain_node_test.dart test/localnet_e2e_test.dart   # needs ../localnet up
cd web && npm run lint && npm test     # the site's elements and feed against a fake API
cd web && npx playwright install chromium && npm run test:browser   # the 360 px layout, keyboard, themes
tool/dashboard_e2e.sh                  # the page through Caddy against the coordinator on localnet
tool/deb_e2e.sh <deb> <newer deb>      # the .deb in Ubuntu 22.04: install, a pool on localnet, upgrade, purge
```

The ricochet tests start `../go-ricochet/ricochet` themselves (`cd ../go-ricochet && GOTOOLCHAIN=go1.25.7 go build -o ricochet ./cmd/ricochet`) against a database they create on localnet's PostgreSQL (`POOL_RICOCHET_PG` overrides the admin URL) and skip with the build command when the binary is missing.
