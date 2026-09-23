## Context

`PoolServer` (`lib/src/server.dart`) is a single-isolate loop: a poll timer drains the inbox, the library's `ShieldedCoordinator` closes rounds on its own deadline, and `_publish` is called with Y, the round and the witness in turn, announcing after the witness. The server keeps a `ServerStatus` it writes to a file; nothing else is exported. The round store (`FileRoundStore`) holds each round's three raw transactions and a record of their txids; snapshots are pruned.

What the library exposes that this change reads, without changing it:
- `co.building`: the future of the round being built; `co.status`: pending, capacity, in flight, rounds, header balance, and the pending round's `deadline`.
- `co.lastTiming`: the `RoundTiming` of the current or last close, created at the start of `_buildAndPublish` and lapped as it goes, in this order: `expiry`, `funding` (Y), `padding`, `trees`, `aggregation`, `root unlock`, `Y`, `dry builds`, `funding` (again, the lap adds to the same key), `round`, `witness`, `apply`, `store`, `publish`.
- `co.ledger.header` after a round, and `PoolAnnouncement.header` on the feed.
- A witness's input 1 unlock carries every transfer's ciphertext bundle; padding carries an empty one (tstokenlib design record, production chain with real notes). `ShieldedRound.padding` is the ledger's view of the same.
- `wallet.lastRoundCost` after `reconcile`.

See proposal.md for why; the specs for what.

## Goals / Non-Goals

**Goals:**
- One recorder that the server calls at a handful of points, and that owns every datum the API may serve, so the privacy boundary is one class.
- The API isolated from the loop's critical path: requests read memory or SQLite, never the chain, the store or the ledger.
- A site with no server-side runtime: static files plus the proxy.

**Non-Goals:**
- Precise block times. The chain access has no block-time call; "mined" carries a height, and the time the coordinator observed it, rounded. Adding `blockTime` to `ChainAccess` is a later change.
- Historical data from before this change beyond what the store and feed hold (durations and costs of old rounds are not reconstructed).
- Multiple coordinators or pools on one page.

## Decisions

### D1. Stage from `RoundTiming`, no library hook
The recorder polls `co.lastTiming` on every server tick (2 s) and on each publish call, and maps the last lapped key to the public stage: nothing lapped, or up to `root unlock` → `proving`; `root unlock` through `store` → `funding`; after `publish` begins (the server's `_publish` sees Y) → `broadcast`; the witness mined → leaves the live state. The alternative, an `onStage` callback in tstokenlib, is cleaner but is a change in another repo on a feature branch for a dashboard nicety. The risk is that the library renames a stage; a test pins the sequence the mapping expects against the real coordinator on the test chain, so a rename fails here rather than silently mislabelling. If the pin breaks more than once, the hook moves into tstokenlib.

### D2. Real transfer count from the ledger's reading, recomputed from the witness in a rebuild
At publish, the count is `capacity - padding`, taken from the round the coordinator's ledger applied. The server cannot reach that `ShieldedRound` today (the library returns only the announcement), so the recorder reads the witness it is handed: `PP1SpUnlockBuilder.readRound` on input 1, `PoolOutHash.decodeBundles`, and counts the non-empty bundles. This is the same computation the rebuild uses on stored witnesses, so both paths agree by construction, and it is exactly what any chain reader can compute, which is the privacy argument. A test checks the count equals the fixture's non-padding transfers on both test rounds. Both are exported by `package:tstokenlib/tstokenlib.dart`.

### D3. SQLite via `sqlite3`, one file, schema-versioned
One `metrics.sqlite` beside the store (path configurable), `PRAGMA user_version = 1`, WAL mode, one table, `rounds` (one row per round, the columns in the `pool-metrics` spec, integer times in ms since epoch, nullable durations, cost and times), indexed on the published time. (A `meta` table for the pool's start and the last mined poll was planned and dropped in the implementation: the start is the first published time, and the mined watcher needs no state beyond the rows without a height.) Series are aggregated with SQL over `rounds`; there is no separate samples table because every public series is a per-round quantity. A different `user_version` or an unreadable file is renamed aside and rebuilt. Alternatives: an append-only JSONL file (no indexed range queries; the series and paging would scan), PostgreSQL (localnet has one, but the coordinator would grow a service dependency for a disposable cache). Writes are synchronous `sqlite3` calls of well under a millisecond on the same isolate; the bound is 5 ms, and if the probe fails it, writes move to a background isolate with a queue, which the recorder's interface already allows.

### D4. Recording points in `PoolServer`
- `_tick`: poll the stage (D1) and the assembling state from `co.status`.
- `_publish` on the witness, after the announcement: record the round from the library's announcement (its txids and header) and the witness (count from D2), with durations from `co.lastTiming` and the published time. (Changed in the implementation: taking the txids from the transactions meant hashing them, and `tool/scratch/metrics_probe.dart record` measured that at 614 ms at the 95th percentile for a 2.5 MB production witness against the 5 ms bound; from the announcement it is 3.4 ms, nearly all of it the bundle count.) Cost is filled after `wallet.reconcile` in the same block; a separate update keeps the reconcile's failure from losing the row.
- A mined watcher: after recording, a timer at `server.mined_poll_ms` asks `chain.minedHeight(witness)` until mined or the funding timeout; at start, every row without a height is queued. Rounds are watched one at a time, oldest first, so a thousand unmined rows after an outage never burst WhatsOnChain's rate limit.
Every recorder call is wrapped so an exception is logged and swallowed (`pool-metrics`, recording never touches a round).

### D5. Rebuild after ready
If rows are missing at start, a background task reads stored rounds by number (`store.read`), counts transfers from each witness (D2), takes the header from the feed's announcement of the same number (the feed is read in pages of 100 from entry 2), and inserts rows with null durations, cost and times. The store keeps no times and the chain access has no block time, so a rebuilt round sits in no series bucket and in no interval; the mined watcher fills its height but not an observation time. Found in the implementation; the spec was amended to match. It runs after `ready` and yields between rounds. Each round's read, txid check against the announcement and count run in a short-lived worker isolate (`Isolate.run`): on the server's isolate a production-size round measured 1.15 s of parsing and hashing, which would hold intake that long for every round rebuilt; from the worker the server's isolate went at most 30 ms without running. (Found by the start probe; the design first had it on the server's isolate.) The measured target is 10 s for the two test rounds; at production a stored round is about 2.6 MB to read and parse, so a 1,000-round rebuild is minutes, which is acceptable because it is off the start path and the page shows the rows as they land.

### D6. Coarse time
The live state is held in memory at full precision and published through a gate: every `api.publish_interval_seconds` (default 30, minimum 10), the gate compares the current live state to the last published one and emits if it differs. Every time the API serves is floored to the interval, and the deadline ceiled. A round published at 12:00:07 shows as 12:00:00; one mined observed at 12:01:41 as 12:01:30. Why this and not dropping times: the page needs a countdown and a sense of recency, and a 30 s quantum is coarser than the chain's own mempool timing for the round broadcast, so the page reveals nothing about a submission's arrival that watching the chain does not. The first-transfer time of an assembling round is the one arrival-derived datum served, and only to the interval.

### D7. HTTP on `shelf` and `shelf_router`
A `shelf` handler on the server's isolate, bound to the configured loopback address, with a middleware stack: method gate (GET and HEAD), request-line length gate, JSON error mapping, and a `Cache-Control` per route (`no-store` for live routes, `max-age=31536000, immutable` for a rounds page whose rows are all mined). The event stream is a `shelf` streamed response with `Content-Type: text/event-stream`, a heartbeat comment every 15 s, and a subscriber set capped by `api.max_subscribers`. Alternatives: `dart:io` `HttpServer` directly (fewer dependencies, but routing, middleware and streaming responses are rewritten by hand), a separate process reading the database (the live stage lives in the coordinator's memory, so it would need its own IPC). The API is started after `ready` and closed first in `stop`. (Implemented without `shelf_router`: five fixed paths are one `switch` on the path, which also keeps HEAD and the method gate in one place, and saves a dependency. The mined-round events wait for the publication gate's tick like the live state, inside the spec's interval-plus-2 s bound.)

### D8. Front-end: Lit web components, Vite, uPlot, TypeScript
`web/` holds `index.html`, `src/feed.ts` (the one `EventSource`, REST fetches, reconnection, staleness, a typed store widgets subscribe to), `src/api.ts` (response types mirroring the `v: 1` shapes), and elements `<pool-rounds>`, `<pool-round-card>`, `<pool-live-card>`, `<pool-stats>`, `<pool-chart>`. Lit's templates escape interpolated strings, which is the "text, never markup" requirement; no `unsafeHTML` anywhere, checked by a lint rule. uPlot draws the charts at about 45 KB. The budget of 150 KB gzipped for the first load is checked by the build script; if it fails, charts load lazily after the scroll. Alternatives: React or Svelte (more than a handful of widgets need, and no custom elements for embedding), plain JS without a build (workable, but the response types are the contract with the API and are worth checking). Tests: Vitest with happy-dom for the widgets against a fake feed; Playwright for the narrow-viewport and end-to-end checks. (Added in the implementation: `/api/pool` serves `explorer`, one of `main`, `test` or null, because the network alone cannot tell testnet from the regtest localnet, which both run as `test`. The coordinator derives it from the network and the chain kind (a `test` pool on a node is regtest), and the page builds the WhatsOnChain URL from this name through a fixed table, never from a URL the API serves. Additive within `v: 1`.) (Also found in the implementation: a browser's `EventSource` never surfaces comments, so the stream's heartbeat cannot tell the page the coordinator is alive, and an idle pool sends no events for hours. The feed asks for `/api/pool` whenever it has heard nothing for a publication interval, and any answer or event counts; silence for twice the interval plus 15 s is stale. At the 200-subscriber cap that is under 7 requests a second, and only while the pool is quiet.)

### D9. Proxy: Caddy
`deploy/Caddyfile`: automatic TLS for the configured domain, `file_server` on `web/dist`, `reverse_proxy /api/* 127.0.0.1:<port>` with `flush_interval -1` for the event stream, a `@write not method GET HEAD` matcher answering 405, `header` setting the content security policy (`default-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'`), HSTS, and `rate_limit` on `/api/*` (the `caddy-ratelimit` module; the standard build does not include it, so the docs name the `xcaddy` build line). Alternative: nginx (equally able, but TLS is manual and the config longer). Caddy is not installed here; the tasks install it with Homebrew to validate and run it.

### D10. Configuration
```yaml
api:
  enabled: true
  bind: 127.0.0.1
  port: 8787
  metrics_file: metrics.sqlite
  publish_interval_seconds: 30
  max_subscribers: 200
```
Parsed by `PoolConfig` into an optional `ApiConfig`; a non-loopback `bind` is a `ConfigError` on `api.bind`.

## Risks / Trade-offs

- [The library renames or reorders `RoundTiming` laps] → the pin test fails; move to a library hook (D1).
- [Stage flips faster than the interval, so a stage is never published] → accepted: the page moves from `proving` to `broadcast` directly. At production `funding` lasts seconds and the round's proving minutes, so only short stages are skipped.
- [Rate limit module needs a custom Caddy build] → documented build line; without it the proxy still works, and the coordinator's subscriber cap and cheap reads bound the damage.
- [SQLite native library missing on the host] → `sqlite3` loads the system's libsqlite3 (present on macOS and Debian/Ubuntu); a load failure disables the API with a logged reason and the server runs as before.
- [The witness-bundle count differs from the ledger's padding view on some future round shape] → the D2 test compares both on the fixture; a disagreement fails the build.
- [A 1,000-round rebuild competes with proving for CPU] → it yields between rounds and pauses while `co.building` is non-null.
- [A client that disconnects keeps its subscriber place until the server next writes to it] → the 15 s heartbeat is such a write, so a dead place is reclaimed within 15 s; found in the implementation (dart:io reports a closed connection only on a write).
- [An SSE subscriber that never reads fills memory] → each subscriber's buffer is bounded (drop to latest live state), and the cap limits their number.

## Migration Plan

No migration: without an `api:` section the server is unchanged. Enabling it creates `metrics.sqlite` and rebuilds it from the store and feed on first start. Rollback is removing the section; the database can be deleted at any time. The site deploys as files; the proxy is new.

## Open Questions

- The public domain name and whether mainnet and testnet pools get separate hostnames. This only fills in the Caddyfile.
- Whether to show withdrawals and deposits per round (both are public outputs of the round). Additive within `v: 1` if wanted later.
