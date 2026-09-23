## 1. Configuration and dependencies

- [x] 1.1 Add `sqlite3`, `shelf` and `shelf_router` to `pubspec.yaml`; verify `dart pub get` succeeds and `dart analyze lib bin test` is clean.
- [x] 1.2 Parse the optional `api:` section into `ApiConfig` (D10) with defaults, the 10 s minimum interval and the loopback-only bind; add a commented `api:` block to `config.example.yaml`. Verify in `test/config_test.dart`: the pre-change example loads with the API off; `bind: 0.0.0.0` fails naming `api.bind`; an interval of 5 fails naming its field.

## 2. Metrics recorder and history

- [x] 2.1 Write the witness transfer count (D2): count the non-empty bundles in a witness's input 1 unlock. Verify in a new `test/metrics_test.dart` that on both test-chain rounds it equals the non-padding count of the `ShieldedRound` the ledger applies.
- [x] 2.2 Write the SQLite history (D3): schema version 1, WAL, `rounds` and `meta`, insert, cost update, mined update, paging, stats and series queries; an unreadable file or another `user_version` is moved aside and recreated. Verify with unit tests on a temp directory, including a corrupt file and a version-2 file.
- [x] 2.3 Write the stage mapping (D1) and a pin test that runs a real round of the test chain through `ShieldedCoordinator`, collects the lapped keys, and fails if their order differs from the one the mapping expects. Verify the pin test passes, and that renaming one key in the mapping's table makes it fail.
- [x] 2.4 Write the recorder: live state (assembling plus deadline, building round plus stage), `roundPublished`, `costKnown`, `mined`, every call guarded so a failure is logged and swallowed. Verify with unit tests on a fake clock.
- [x] 2.5 Hook the recorder into `PoolServer` (D4): `_tick`, the witness branch of `_publish` after the announcement, cost after reconcile, and the mined watcher at the mined poll interval, one round at a time, queued at start for rows with no height. Verify in `test/server_test.dart` for the `pool-metrics` scenarios "Two rounds of the test chain", "A round that failed is not recorded", "Mined after publish", "Not yet mined at stop", "Stages in order", "Assembling and idle".
- [x] 2.6 Write the rebuild (D5): after ready, fill missing rows from `store.read`, the witness count and the feed's announcements, then queue the mined watcher; yield between rounds, pause while a round is building. Verify with the "Database deleted between runs" and "Same store, same history" scenarios in `test/server_test.dart`.
- [x] 2.7 Failure isolation: verify with the "Database locked" scenario (another connection holds `BEGIN EXCLUSIVE` through round 2; a chmod cannot make a file the server already holds open unwritable, so the task was amended), checking round 2 publishes and is announced, the log names the history failure, and a submission sent afterwards is answered within 2 s.
- [x] 2.8 Privacy scan: after the two-round server test with the API enabled, scan `metrics.sqlite` bytes and every live state emitted for the submission ids, sender peer ids, owner key, identity seed and wallet balance of the run. Verify the scan finds none, and that it fails when a sender id is deliberately added to a row (the mutation check).

## 3. Read-only API

- [x] 3.1 Write the `shelf` server (D7): routes `/api/pool`, `/api/rounds`, `/api/stats`, `/api/series`, the method gate, the 2 KB request-line gate, JSON errors, `"v": 1` on every body, cache headers. Started after ready, closed first in `stop`. Verify the "Paging rounds", "Writes refused" and "Version on every route" scenarios in a new `test/api_test.dart`.
- [x] 3.2 Write the publication gate (D6): times floored to the interval and the deadline ceiled; the live state emitted at most once per interval. Verify "Times are coarse" on a fake clock with round events at arbitrary seconds.
- [x] 3.3 Write `/api/events`: the snapshot on connect, `live` and `round` events, a 15 s heartbeat, the subscriber cap with 503, a bounded buffer per subscriber. Verify "A round mined reaches a subscriber" and "Subscriber cap" in `test/api_test.dart`.
- [x] 3.4 Mutation fuzz: 10,000 random and mutated paths and queries against every route while a submission is in flight. Verify every answer is 200, 400, 404, 405 or 414 with a JSON body and the submission is answered within 2 s; then remove the `limit` range check and confirm the fuzz catches it (a limit over 100 accepted).
- [x] 3.5 Secrets scan of every route during and after the two-round test. Verify it finds no owner key, identity seed, wallet balance, submission id or sender peer id, and that it fails when the wallet balance is deliberately added to `/api/pool`.
- [x] 3.6 Load while intake runs: 50 requests a second across all routes during the two-round test. Verify every submission is answered within 2 s and both rounds publish.
- [x] 3.7 Wire `ApiConfig` into `bin/pool_coordinator.dart run`; a failure to load libsqlite3 disables the API with a logged reason. Verify by running the server on localnet with `api:` enabled (`POOL_LOCALNET=1`) and fetching each route with `curl`. (Done: `run` needed no change, since the server starts the API from its configuration; the localnet end-to-end test enables `api:` and fetches every route with `curl` after both rounds are mined. The libsqlite3 failure is exercised through the same catch by a history that cannot be opened, in `test/server_test.dart`.)

## 4. Measurements

- [x] 4.1 `tool/scratch/metrics_probe.dart record`: record 1,000 rounds into a 1,000-round history, measuring the 95th percentile time to record one. Verify it is under 5 ms; record the number and the database size per round in `docs/DESIGN.md`.
- [x] 4.2 `tool/scratch/metrics_probe.dart api`: 1,000 requests each to `/api/rounds` and `/api/stats` over a 1,000-round history. Verify both 95th percentiles are under 50 ms; record them in `docs/DESIGN.md`.
- [x] 4.3 `tool/scratch/metrics_probe.dart start`: time to ready and time to a full rebuild on a store of 1,000 synthetic rounds (as `server_cost_probe.dart ready` builds one). Verify ready is within 60 s and unchanged by the rebuild; record both in `docs/DESIGN.md`.

## 5. Web site

- [x] 5.1 Scaffold `web/`: Vite, TypeScript strict, Lit, uPlot, Vitest with happy-dom, Playwright, ESLint with a rule banning `unsafeHTML` and `innerHTML`. Verify `npm ci && npm run build && npm test` succeed on Node 20 and `npm run lint` fails on a planted `unsafeHTML`.
- [x] 5.2 Write `api.ts` types for the `v: 1` shapes and `feed.ts`: one `EventSource`, fetches, reconnection with a refetch of rounds after the newest held, de-duplication by round number, staleness at twice the interval plus 15 s. Verify with Vitest on a fake stream: "Stream drops and returns" and "Coordinator unreachable".
- [x] 5.3 Write `<pool-rounds>`, `<pool-round-card>` and `<pool-live-card>`: pinned-right scroll, paging left, live stage list, mined transition in place, the assembling countdown with no pending count. Verify with Vitest: "Two rounds render", "Paging left", "A round moves through its stages", "No transfer counts while assembling".
- [x] 5.4 Write `<pool-stats>` and `<pool-chart>` from `/api/stats` and `/api/series`, with dashes for missing figures. Verify "Tiles from the stats route" with Vitest.
- [x] 5.5 WhatsOnChain links per network, with txids checked as 64 hex characters and plain text for regtest or malformed ones. Verify "Testnet links" and "Malformed txid" with Vitest.
- [x] 5.6 Markup injection: verify "Markup in a field" with Vitest (no `img` element created, text shown literally).
- [x] 5.7 Layout and accessibility: a 360 px layout, the round scroll focusable and moved by arrow keys, reduced motion respected, light and dark themes. Verify "Narrow viewport" with Playwright, and a keyboard scroll check in the same test.
- [x] 5.8 Payload budget in the build script: fail if the first load is over 150 KB gzipped. Verify it passes, and record the size in `docs/DESIGN.md`.

## 6. Proxy and end to end

- [x] 6.1 Write `deploy/Caddyfile` (D9) with the domain as a placeholder, and `deploy/README.md` with the `xcaddy` build line for the rate-limit module. Install Caddy with Homebrew and verify `caddy validate` accepts it (with the module built in) for "Proxy configuration checks".
- [x] 6.2 End to end: a script (`tool/dashboard_e2e.sh`) starts the coordinator on localnet with the API, Caddy on `localhost` with an internal certificate, and runs a Playwright test through it. Verify "Through the proxy": the page loads, a round mined on localnet appears live, and `curl -X POST https://localhost/api/pool` gets 405.

## 7. Record and wrap-up

- [ ] 7.1 Add a dated `docs/DESIGN.md` section for this change: the recorder, the stage mapping, the privacy boundary and its argument, the API, the site and proxy, and the numbers from 4.1 to 4.3 and 5.8. Update `README.md` with running the API, building the site and running the proxy. Verify both sections exist.
- [ ] 7.2 Run `dart analyze lib bin test` (clean), `dart test`, `dart test test/transport_test.dart`, `POOL_LOCALNET=1 dart test test/chain_node_test.dart test/localnet_e2e_test.dart`, and in `web/` `npm run lint && npm test && npm run build`. Verify all pass, and report the output.
