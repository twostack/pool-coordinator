## Why

The pool runs, but only its operator can see it: the status file and the log are on the coordinator's host, and a wallet user or a prospective one has no view of whether rounds are being mined, how often, or what the pool holds. A public landing page that shows rounds as they are mined, the round being worked on and the pool's overall numbers makes the pool legible without anyone reading a feed or a block explorer. It needs data the coordinator does not keep today (a history of rounds beyond the store's transactions, and a way to read it over HTTP), so the coordinator grows a small time-series record and a read-only API, and a static site of live widgets reads them.

## What Changes

- **The coordinator records a history of its rounds** in a local database beside the store: for each round its number, its three txids, the real transfer count and capacity, the pool's balance after it, what it cost the wallet, how long it took to build and to prove, when it was published and at which height it was mined. The server now watches each published round until its witness is mined. The history is rebuilt from the store and the feed at start when it is missing, so it is disposable and lifetime totals survive restarts.
- **A read-only HTTP API** on the coordinator, bound to localhost: the pool summary, pages of mined rounds, aggregate statistics, per-metric time series, and a server-sent event stream of the live state (the round being built and its stage, whether a round is assembling, a round mined). Only GET, no auth, no write path; nothing it serves derives from a single submission.
- **A static landing site** in `web/`: a horizontal scroll of round cards (mined rounds, the round being proved with its stage, the round assembling), pool statistics tiles, and small time-series charts, as web components fed by one shared event stream. It is served by a colocated reverse proxy that also fronts the API for the public.
- **A new `api:` section in the configuration** (enabled, bind address, port, the publication interval, the event-stream subscriber cap, the metrics database path). Absent means disabled, so existing configurations run unchanged.

Changed from the sketch agreed in conversation, for privacy: the live pending count, and any count of submissions accepted, refused or dropped, are not published. Each pending increment is one submission's arrival time, which nothing on the chain reveals. The per-round real transfer count is published, because the chain already shows it (padding transfers carry empty ciphertext bundles, so the witness reveals how many are real; measured in tstokenlib's design record, section on the production chain with real notes). The lifetime transfer total is the sum of those.

Not in this change: an operator dashboard (wallet balance, rounds left, failures, submission counts stay in the status file), authentication, a hosted deployment, and any tstokenlib change. The round's current stage is read from the library's `RoundTiming` as it laps, with no new hook.

Numbers to hold, each a bound a task measures (nothing here is measured yet): recording a round adds under 5 ms to the publish path; the submission-to-reply bound of 2 s from `server-process` still holds with the API under 50 requests a second; `/api/rounds` and `/api/stats` answer in under 50 ms at the 95th percentile over a 1,000-round history; the history costs under 1 KB a round on disk; the server is ready within the existing 60 s start bound on a 1,000-round store, with any rebuild of the history running after ready; the live state reaches a browser within the publication interval (default 30 s) plus 2 s; the site's first load is under 150 KB gzipped. The specs make the latency, start, staleness and privacy bounds requirements; the disk and payload sizes steer the design.

Non-functional contract, capability by capability in the specs: untrusted input (query strings and headers from anyone on the internet), secrets and privacy (no key, wallet state or per-submission datum; times coarsened to the publication interval), trust (every round links to the chain so a reader can check it), determinism (the same store and feed give the same history), compatibility (versioned responses and database; absent `api:` is off), performance and resources (latency, subscriber cap, disk), failure (the API or the history failing never stops or delays a round).

## Capabilities

### New Capabilities
- `pool-metrics`: the coordinator's history of rounds and the live state it derives: what is recorded per round, when, what is never recorded, the rebuild from the store and the feed, mined tracking, and that its failure never touches a round.
- `dashboard-api`: the read-only HTTP endpoints and the event stream: routes, response shapes and versioning, input limits, localhost binding, the publication interval, the subscriber cap, latency.
- `dashboard-site`: the landing page: the round scroll with live cards, the statistics tiles and charts, live update and reconnection, staleness, chain links, payload budget, and its deployment behind the colocated proxy (TLS, caching, rate limit, content security policy).

### Modified Capabilities
None in `openspec/specs/`, which is still empty: `server-process` and `round-store` are in the unarchived `coordinator-server` change. This change adds to the server without changing any of their requirements (the round store's format is untouched; the status file is unchanged). Archiving `coordinator-server` first is advisable so these specs land beside it. The library specs this reads through (`pool-coordinator` for the round's stages and status, `pool-protocol` for the announcements on the feed, `pool-ledger` for the round's transfers) are unchanged.

## Impact

- Coordinator (`lib/src/`): a metrics recorder and database, an HTTP server, hooks in `PoolServer` at intake, close, publish and mined, a mined watcher, config parsing for `api:`, `bin/` wiring. New dependencies: `sqlite3` (the system's libsqlite3 at run time), `shelf`, `shelf_router`.
- New `web/` directory: TypeScript, Lit, uPlot, built by Vite into `web/dist/` (Node 20 at build time only). Node never runs in production.
- New `deploy/Caddyfile` for the colocated proxy, and a docs section on running it.
- Tests: Dart tests for the recorder, rebuild and API on the existing fakes and test chain; web unit tests with Vitest; one end-to-end check of the site against a coordinator on the test chain.
- `docs/DESIGN.md` gains a dated section with the measurements.
