# pool-coordinator design record

The running record of this repo, appended in dated sections. The pool
itself (the transfer, the ledger, the coordinator and the protocol) is
designed in `../tstokenlib/docs/ZK_SHIELDED_POOL_TSL1_DESIGN.md`, sections 14
and 15; this file records only what the server adds around it.

## 2026-09-22: the coordinator server (change `coordinator-server`)

### The process

`bin/pool_coordinator.dart` has two commands. `create` generates the owner
key and the ricochet identity, writes the wallet file and the identity
file, prints the address and what it needs, waits for the operator to fund
it, builds Y_0, the issuance and witness 0 through the library's tool
(sized as the localnet harness sizes them: Y at its size plus two satoshis,
witness 0 at three times the verifier body plus a megabyte, the issuance
from a 1,000,000 satoshi output with the change back), mines each before
the next, writes the genesis txids into the configuration and puts the
descriptor on the feed as entry 1. `run` opens or recovers the pool and
serves it until SIGINT or SIGTERM.

`PoolServer` (`lib/src/server.dart`) is one loop around the library's
`ShieldedCoordinator`. Start: the genesis is fetched from the chain; the
store's last round, if any, is checked against the chain (each of its
three transactions mined, else re-broadcast in order and waited for) and
its snapshot restored through the library's recovery; the tip's PP3 must
be unspent, or the chain has a round this server did not build and the
start is refused naming it; the wallet takes in what the chain shows at
its address; the coordinator is built; the feed's first entry is checked
to be this pool's descriptor (or written, on an empty feed) and a round
published but not announced is announced. A timer then drains the inbox
every poll interval. Each message is routed by its first two bytes, a
deposit's covenant is confirmed mined and unspent on the chain before the
library sees the bytes, the library's intake answers, the reply goes to
the sender, and the batch is marked delivered whatever became of it. The
library closes rounds; its publish callback broadcasts Y, the round and
the witness through the chain access and, after the witness, appends the
announcement and reconciles the wallet. A refused broadcast is the
library's round failure, the store keeps the round, and the next start
re-broadcasts it. A stop takes no further submissions, waits for a
publish in progress, writes the status and closes the transport; a round
being proved is abandoned.

The status file names the tip round and its three txids, the pending,
in-flight and padding counts, the wallet's balance, last round cost and
rounds left, whether it needs a top-up, the last failure and the last
twenty, the last announcement, and the submission counts. The log names
every submission's outcome by id and reason. Neither holds a key, a seed,
a passphrase or a transfer's bytes; the tests search both.

The library proves in the isolate that runs it. The reply to the
submission that fills a round goes out before the proving starts, because
the build first awaits the wallet's funding (chain I/O); a submission that
arrives during the proving is answered when it ends (seconds at test
parameters, minutes at production). Proving in a worker isolate is a
library change; the bound below is measured on submissions outside a build.

### Ricochet

One libp2p host of the identity (UDX, Noise, yamux, no relay or DHT),
connected to the one configured server and protected from the connection
manager, and an `SFClient` over it with the identity's payload encryptor.
Folders: `pool/submissions` under the coordinator's peer id for
submissions, `pool/replies` under the sender's for replies, both
persistent and sealed to the recipient. Feed: `pool/rounds` under the
coordinator's peer id, the descriptor at sequence 1 and one announcement
a round after it. The identity is a 32-byte Ed25519 seed in an owner-only
file, written by `create` and read by `run`, so the peer id and the
payload key are the same across restarts.

Two things the client library made the transport do itself: the mailbox
calls (retrieve, submit, mark delivered, delete) open their own streams
and close them, because the client leaves a submission's stream open; and
a consumed message is deleted after it is marked delivered, because the Go
server keeps a persistent message that is marked delivered. A third,
closing and redialling the connection every 200 streams, is gone: it was
there because `dart_libp2p` 1.0.3's yamux never dropped a closed stream
from its table, which ended a connection at its 256th stream. That is
fixed in 2.0.0, which this server now takes, so a connection lives as
long as it works; a connection that does refuse a new stream is still
redialled once rather than failing the round. A payload that
does not open with the identity's key is handed to the server as it is,
so a hostile sender cannot stall a batch. Everything runs in a zone that
logs the errors the transport stack throws on futures nobody awaits when
a connection dies mid-dial.

### The chain access

`ChainAccess`: fetch, height, broadcast, mined height, output unspent,
address unspent. `NodeChain` is the node's JSON-RPC (`getrawtransaction`,
`getblockcount`, `sendrawtransaction`, `gettxout`, `listunspent` on the
address imported watch-only). `TestnetChain` is ARC for broadcast, in the
extended format built from parents fetched from WhatsOnChain, and
WhatsOnChain's `tx/{txid}/hex`, `chain/info`, `tx/hash/{txid}`,
`tx/{txid}/{vout}/spent` and `address/{addr}/unspent/all` for the rest; a
scriptSig over 1,636,802 bytes is refused before anything is sent. ARC's
STORED and ANNOUNCED_TO_NETWORK are refusals. Every answer is decoded in
one function per endpoint that a test fuzzes with 10,000 random and
mutated bodies each; a fetched transaction is checked against the txid
asked for. Calls time out (30 s) and retry (3) on network failure.

### The wallet

`FileWallet` over `WalletFile`: the owner key (also the funding key) and
the coins, JSON inside XChaCha20-Poly1305 under a key Argon2id derives
from the passphrase (64 MiB, 3 passes, about half a second in pure Dart),
with the header (magic, version, KDF parameters, salt) as associated data,
written to a temporary name and renamed, owner-only. A funding request
spends the wallet's coins (largest first) into a transaction paying exactly
the value asked, with the change before it at output 0 when there is any
(the issuance must spend output 1 of its funding transaction), records it,
waits for it to be mined, and hands it over. At start and after every
round the wallet reconciles: an offered output the chain still shows
unspent comes back to be offered again (a round that failed after Y was
funded), coins the chain no longer shows are dropped, and outputs at the
address it does not know are taken in (a top-up, or the round's change,
which the server names so the round's cost is measured as the balance
before plus top-ups less the balance after). Rounds left is the balance
over the last round's cost.

### The store

A directory per round under `store/rounds/000123/`: `y.tx`, `round.tx`,
`witness.tx` raw, `snapshot.bin`, and `round.json` (version 1, number,
three txids), each written to a temporary name and renamed, the record
last. Reading checks each transaction against the recorded txid and its
length, so a file cut short is refused naming the round and the file. The
snapshots of rounds more than `keep_snapshots` behind are deleted; every
transaction stays.

### The configuration

One YAML file (`config.example.yaml`): plan by name (`test`, `production`),
network, the chain access and its endpoints, the ricochet server address,
the identity, wallet and store paths, the genesis txids (written by
`create`), the fee rate and floor, the deadline, padding stock and deposit
margin, the poll and mining intervals and the status file. A missing or
unknown field is named. The wallet passphrase and an RPC password come
from `POOL_WALLET_PASSPHRASE` and `POOL_RPC_PASSWORD` or files the
configuration names.

### Measured

On an Apple M3 Pro (12 cores, 36 GB), the ricochet server on localhost
(`../go-ricochet` against localnet's PostgreSQL), localnet's node over
RPC, 2026-09-22.

End to end on localnet at test parameters (`test/localnet_e2e_test.dart`,
POOL_LOCALNET=1): `create` 9.7 s from the funding landing to the
descriptor on the feed; start at round 0 1.3 s, restart on a store of two
rounds 1.8 s. The eight submissions of the two rounds were answered
(inbox to reply readable by the wallet) in 164 to 434 ms, mean 233 ms,
against the 2 s bound; the announcement was on the feed 137 ms and 123 ms
after the witness's broadcast, against the 5 s bound. 1,100 messages sent
in 21.4 s were all consumed 0.5 s after the last was sent. A round cost
the wallet 1,541 sat and 1,615 sat (at 1 sat/kB, test-parameter Y 416 sat,
witness 2,240 sat offered, the round's change back); the wallet reported
708 and 674 rounds left on 1.09 M sat.

`tool/scratch/server_cost_probe.dart roundtrip` (the same on a fake chain
and wallet whose funding takes half a second, the real ricochet):
submission round trip mean 239 ms, worst 379 ms over the eight; the
announcement appended 109 ms and 133 ms after the witness's broadcast, and
seen by the wallet's 200 ms poll within 360 ms.

`tool/scratch/server_cost_probe.dart ready` on a store whose one round
holds the library's synthetic snapshot of 1,000 production rounds
(512,000 leaves, 37 MB): start to ready 44.4 s against the 60 s bound, of
which compiling the production plan 15.1 s, restoring the snapshot 12.1 s,
opening the coordinator (generating the verifier body and sizing Y)
16.2 s, the transport's connect 0.15 s and the feed check 0.4 s. Building
the synthetic snapshot took 7 minutes and is not counted.

The production chain through the server on localnet via node RPC
(`tool/scratch/production_run.dart`, STARK_KERNELS_GPU=1, the library's
cached 256 production transfers a round):
`create` 37.6 s from funding to the descriptor on the feed (Y_0 funded at
1,786 sat, witness 0 at 6,349, the issuance from 1,000,000 with its change
back; the genesis cost the wallet 15,297 sat, which the wallet reports as
its first "last round" until round 1 replaces it). Start 24.8 s at round
0, of which the production plan's compile and the coordinator's open are
nearly all. Both rounds went through the server: 256 submissions a round
sent over ricochet in 14 s and all accepted and answered within 19 s of
the first send; each round announced about 290 s after its last
acceptance, of which the GPU aggregation was 264 s and 260 s, the three
fundings 4.5 s and 4.7 s (three transactions mined one after another, the
test mining a block every 2 s), the publish 10.3 s and 10.8 s, and
everything else under 12 s.

The wallet built three funding transactions a round, paying exactly what
the library asked: round 1 Y 1,786 sat, witness 2,204 sat, round 446 sat;
round 2 Y 1,786 sat, witness 2,531 sat, round 446 sat, each with a 135 sat
fee (the floor at 1 sat/kB). A round cost the wallet 4,790 sat and
5,117 sat, the library's fee figures plus the three funding fees less the
round's change; round 2's witness is larger because round 2 carries a
withdrawal and a real transfer's bundles. The wallet reported 415 and 387
rounds left on 1.99 M sat, which at 100,000 sat is 20 or 19 rounds, one to
two fewer than the proposal's 22 at the library's 4,400 sat, the gap being
the funding fees the library's figure leaves out.

One fault this run found and the code now avoids: the chain access shared
one HTTP client, and when proving released the isolate after four minutes
a backlog of calls timed out together, each closing the client under the
others, so the witness's funding failed every retry. Each attempt now has
its own client.

### Testnet

Testnet runs at test parameters: production witnesses carry 1.9 to 3.1 MB
unlocks, over ARC's 1,636,802-byte parse limit measured on localnet, and
TAAL's testnet ARC is assumed to share it until measured. The testnet
chain access is tested against a fake HTTP server replaying WhatsOnChain's
and ARC's recorded answers (testnet block 1's coinbase and its address;
localnet ARC's error shapes; ARC's documented acceptance). Unmeasured on
testnet: the block wait per funding output (about ten minutes each, three
a round, since funding waits for a block), WhatsOnChain's rate limits at
the server's call volume, and TAAL's actual scriptSig limit.

## 2026-09-24: the pool's public view (change `pool-dashboard`)

A landing page shows the pool's rounds as they are mined, the round being
worked on, and the pool's figures. The coordinator keeps the history and
serves it read-only; a static site behind a colocated proxy reads it.

Before any of it, the server was brought up to tstokenlib's block roots
(`sp-block-roots`): announcements now carry the round's block root, which
the server takes from the library's own announcement of the round, and
ledgers and readers name the pool's token id and genesis header. The
tests build their chain from the library's exported test chain
(`package:tstokenlib/testing.dart`) instead of a copy of it.

### The history

`MetricsRecorder` (`lib/src/metrics/`) is the one place the public view is
written, and so the privacy boundary. Per round it keeps the three txids,
the number of real transfers, the capacity, the header's balance, the
wallet's cost, the build and proving times, when it was published and the
height it was mined at, in one SQLite file beside the store. It keeps
nothing per submission: no ids, senders, arrival times, pending count or
submission counts, and nothing of the wallet but a round's cost. The real
transfer count is read from the witness the way any chain reader can
(padding carries an empty ciphertext bundle), so the page shows nothing
the chain does not.

The round's stage comes from the library's `RoundTiming` as it laps,
mapped to proving, funding and broadcast; a pin test fails if the library
renames or reorders a lap. A round is recorded from the library's
announcement and its witness after the announcement is appended, watched
until its witness is mined (one round at a time, oldest first), and a
history that is missing or unreadable is moved aside and rebuilt from the
store and the feed after ready. A rebuilt row has no times, durations or
cost, since the store keeps none. Every recorder call is guarded: with the
history locked by another connection, round 2 of the test chain published
and announced as without it, and a submission sent afterwards was answered
within 2 s.

### The API

The API (`lib/src/api/`) answers GET and HEAD on five routes from the
history and the live state only, never the chain, the store or the ledger.
Every time it serves is rounded to the publication interval (30 s by
default), and the live state and mined-round events pass a gate that ticks
on that interval, so no time it serves is finer than 30 s and none derives
from one submission's arrival more finely than the chain's own timing does.

It runs in an isolate of its own. The library proves on the server's
isolate, which the load test measured holding it 3.7 to 5.1 s a round at
test parameters; with the API on that isolate, 115 of 828 requests at 50 a
second were reset during a round. From its own isolate, reading the
history over its own connection, 886 requests at 50 a second through two
rounds all answered while the server's isolate stalled 4 s, and every
submission was answered within 2 s. A 10,000-request mutation fuzz found
two answers that were not the API's JSON: `shelf` answered a target that
is not a path with its own 500 (now the API's 400), and `dart:io` answers
a request line it cannot parse with a plain 400 before any route sees it,
which the spec now allows.

### The site

The page (`web/`) is static files: Lit elements in TypeScript, built by
Vite, with uPlot for the charts. Node runs at build time only. One feed
(`web/src/feed.ts`) holds everything the elements show, so they never
disagree: the summary, the statistics, the rounds held (one per number,
oldest first) and the live state. It holds one event stream for the whole
page. When the stream drops, it reads the rounds mined meanwhile from the
history on reconnect, and a round event past a gap fills the gap the same
way.

A browser's `EventSource` never passes the stream's heartbeat comments
to the page, and an idle pool sends no events for hours, so the stream
alone cannot say whether the coordinator is alive. The feed asks for
`/api/pool` whenever it has heard nothing for a publication interval.
Silence for twice the interval plus 15 s shows a stale notice with the
last update, and the page keeps its cards. At the 200-subscriber cap that
is under 7 requests a second, and only while the pool is quiet.

The rounds scroll sideways, oldest to newest, then the round being built
with its stages, then the next round. The next round's card says it is
waiting for transfers, or that it is assembling, with a countdown to the
deadline. It never shows a pending count. A round's live card becomes its
mined card in place. The scroll stays pinned to the newest card unless
the viewer has scrolled away, and pages older rounds in at the left end
without moving the cards in view.

API data is text, never markup. Lit escapes what it interpolates, and
the lint bans `unsafeHTML` and the other unsafe directives, the DOM's HTML
setters and `eval`. A test serves `<img src=x onerror=alert(1)>` as the
network name and as a txid, and finds it shown literally with no element
made from it. Links go only to WhatsOnChain, and only for a txid of
exactly 64 hex characters. The coordinator names the explorer (`main`,
`test`, or none for regtest, which reports network `test` like testnet),
and the page picks the origin from a fixed table, so no served string
becomes a URL.

The page fits 360 px without sideways page scroll. The round scroll takes
focus and moves with the arrow keys, Page Up and Down, Home and End. The
stage animation stops under reduced motion, and the page follows the
system's light or dark theme.

### The proxy

`deploy/Caddyfile` puts the site and the API behind one public name.
Caddy terminates TLS with automatic certificates and serves `web/dist`.
Vite names each asset by its content, so assets are cached as immutable
and the page itself is revalidated. Under `/api/`, anything but GET or
HEAD gets 405 at the proxy and never reaches the coordinator. The
coordinator's own cache headers pass through, which lets a browser or CDN
keep a page of mined rounds for good. The event stream is flushed as
written and left uncompressed, since compression would buffer it. The
proxy also sets a content security policy that allows the page's own
origin only, HSTS, `nosniff` and no referrer, and drops the Server
header.

The rate limit is 120 requests a minute per client address on `/api/`.
A page load is about six requests and each page of older rounds one, so
a viewer never meets it, but a scraper does. It is the `caddy-ratelimit`
module, which the standard Caddy build, Homebrew's included, lacks. The
standard build refuses the file with "rate_limit is not a registered
directive" rather than running without a limit. `deploy/README.md` has
the `xcaddy` build line.

`tool/dashboard_e2e.sh` checks it all together on localnet:
- It validates the configuration and checks the adapted configuration
  for the rate limit, the policy, the unbuffered events and the
  read-only gate.
- It runs the localnet end-to-end test in a mode where the test waits for
  the browser before round 1.
- It puts Caddy on `https://localhost:8443` with a certificate from
  Caddy's own CA, kept in a temporary folder and never added to the
  system trust store.
- It runs a browser test through the proxy.

The page loaded with the policy, and the browser blocked nothing under
it. Round 1 appeared live, first as a card being built, then as a mined
card with its txids as text (regtest). POST, PUT, DELETE and PATCH got
405, and a burst of 150 requests met 429s at the proxy.

### Measured

`tool/scratch/metrics_probe.dart`, on the M3 Pro:

- `record`: recording a round on the publish path, into a history of
  1,000 to 2,000 rounds, with a witness inflated to the largest production
  witness measured (2,529,395 B): 0.51 ms median, 3.39 ms at the 95th
  percentile against the 5 ms bound, nearly all of it the witness's bundle
  count. Taking the txids from the transactions instead of the
  announcement measured 264 ms median and 614 ms at the 95th percentile,
  since a transaction's id hashes its serialization; the recorder takes
  them from the announcement. The history is 268 B a round.
- `api`: 1,000 requests each over a 1,000-round history, through the API's
  isolate: `/api/rounds` 0.26 ms median and 0.34 ms at the 95th
  percentile, `/api/stats` 0.28 ms and 0.37 ms, against the 50 ms bound; a
  full 100-round page 0.59 ms and a day series 0.42 ms at the 95th.
- `start`: start to ready on the test chain's two-round store, five runs
  each: API off 1,184 ms median, API on with its history 1,221 ms, API on
  with its history deleted 1,215 ms, the two rounds rebuilt about 630 ms
  after ready. The API adds about 40 ms to start, and the rebuild does not
  delay ready. Production's start to ready on a 1,000-round store measured
  44.4 s above, against the 60 s bound.
- The rebuild of 1,000 stored rounds with production-size witnesses:
  937 s, 0.94 s a round, nearly all of it the store's parse and txid check
  of each 2.5 MB witness. Run on the server's isolate it held that isolate
  1.15 s a round, which would hold intake as long; each round's read now
  runs in a short-lived worker isolate, and the server's isolate went at
  most 60 ms without running through the whole rebuild.
- The site's first load, every file `vite build` writes to `web/dist/`
  gzipped: 38.4 KB (36.7 KB of it the script, Lit and uPlot included)
  against the 150 KB budget, which `npm run build` enforces.

## 2026-09-24: answering wallets (change `wallet-catch-up`)

The cloak wallet needs more from the coordinator than submission replies: to join a running pool without reading its whole feed, to prove a payment after later rounds are mined, and to learn where its change and deposits landed. tstokenlib's change `wallet-rounds` moved the protocol to version 3 for this: catch-up requests carry a random id their replies echo, a reply can be a refusal, a mined round can be asked for by number, and a pool sends its submitters a notice. The server's half is below.

**Answers stand at the last mined round.** The ledger counts the rounds the server has published, which may not be mined yet. So the server keeps its own count of the last round whose witness it has seen mined, and every answer stands there:
- At start it walks down from the stored tip to the first mined witness. A mined witness means every earlier round is mined, since each round spends the witness before it.
- The mined watcher, which used to run only for the dashboard's history, now always runs and raises the count.

A head and a frontier asked for back to back therefore agree, unless a round is mined between the two. A test that points the answers at the ledger's round instead fails.

**Catch-up never waits in front of a submission.** Anyone can send catch-up requests, and a round answer reads megabytes. So requests leave the inbox at once for a queue of at most 64, answered one at a time by their own loop.

**Where a witness sits comes from the chain.** It is the verbose `getrawtransaction` for the block, then the node's `getmerkleproof2`; on testnet it is WhatsOnChain's `proof/tsc`. The TSC format's `*` node is resolved as it is read. The round's two transactions come from the store as stored, checked by hashing their bytes against the record's txids, because parsing a production witness holds the server's isolate for about a second. The last four mined rounds are cached.

**Submitters are told.** Each accepted submission is held by round and peer until that round is mined, then the peer is sent one notice naming its own ids, in a folder of its own (`pool/notices`). libcloak's review found the first version's notices in the replies folder, where a wallet waiting on an answer took a notice for it. The expired reply for a transfer accepted and then dropped at close was unasked in the same way, and now goes there too. A notice carries no transactions, only the txids and the witness's place in its block: 141 bytes, where carrying both transactions was 2.6 MB at production, once per submitter per round. The server builds it from the store's record and the chain's proof, reading no transaction file. This is the private path to a wallet's round. Asking for a round by number tells the pool which round the asker cares about, so that is left to recovery after a restart, since the record is held in memory.

Measured:

| What | Result |
|---|---|
| Flood test: 300 round requests from one peer, each answer 20 ms to send | 67 answered, 233 dropped at the bound |
| Submission sent after the flood | answered in 689 ms, against the 2 s bound |
| Every branch received over ricochet on localnet (two notices, the head, round 1 by number) | computes the merkle root the node's `getblock` states for its block |

## 2026-09-25: versioned releases (change `release-packages`)

The coordinator used to install only as a developer runs it: five sibling repositories, the Dart SDK, Rust, and `dart run` from the source tree. A tag `vX.Y.Z` now publishes a GitHub release with a Debian package for amd64 and for arm64, a signed and notarized disk image for Apple Silicon, and `SHA256SUMS`. An install needs no toolchain, and `pool-coordinator check` says what it can do. The first was v0.1.0.

**Everything comes from pub.dev.** A git dependency on ricochet-dart-client failed: pub refuses an absolute path in any pubspec it fetches, even for a dependency the root overrides, and ricochet-dart-client, dart-libp2p-merkle-crdt and merkledag all named their siblings that way. They were published instead (merkledag 1.0.1, dart_libp2p_merkle_crdt 1.0.0, ricochet 0.1.0), and so was tstokenlib 2.0.1, whose kernel loader now also looks beside the running program and in `../lib` from it. `pubspec.lock` is committed and the release resolves it with `--enforce-lockfile`. A gitignored `pubspec_overrides.yaml` points development at the sibling checkouts, and a lock written with it in place names local paths, so it must not be committed.

**The kernels are built from the pinned tstokenlib.** Its crate ships in the pub.dev package as source, found through the package config and built outside the pub cache. The build comes before the test suite, since ML-KEM exists only in the native crate. Each release job also runs tstokenlib's byte-identity test of the native kernels against the Dart ones on that platform, which is what makes shipping a prebuilt library safe.

**SQLite by its runtime name.** On Linux the `sqlite3` package asks for `libsqlite3.so`, which only `libsqlite3-dev` installs. Wherever the history is opened, in whichever isolate, the coordinator first points the package at `libsqlite3.so.0`, and the package depends on `libsqlite3-0`.

**The Debian package follows go-ricochet's.**
- **The service:** a `pool-coordinator` system user without a login shell, and a supervisor program that runs `run.sh` as that user.
- **The secrets:** `run.sh` exports them from `/etc/pool-coordinator/env` (root-owned, group-readable, 640), never on the command line. `create` goes through the same wrapper, since it needs the passphrase too.
- **The config directory:** `create` writes the genesis by renaming a temporary file over `config.yaml`, so `/etc/pool-coordinator` is group-writable with the sticky bit (1770). The service can replace its own config but not the root-owned env file.
- **Install and upgrade:** a first install is left stopped, and an upgrade restarts only a running service. Purge deletes the data, the wallet included, and the installer says to back it up.

`tool/deb_e2e.sh` checks all of this in a clean Ubuntu 22.04 container on localnet: a pool created and run under supervisor, `/api/pool` served without `libsqlite3-dev`, no secret in `/proc/<pid>/cmdline` or the logs (with a mutation that puts one there), both upgrades, removal and purge.

**The first run on Linux found two test faults.** The release was retagged twice before it published; a failed run publishes nothing.
- `wallet_test` read a file mode with BSD `stat -f %Lp`, which on Linux reports the filesystem instead. It now reads the mode through Dart's `FileStat`.
- A metrics test that proves a real round had the default 30 s timeout, which the amd64 runner exceeded. It now allows 2 minutes, like its neighbours.

Measured on the v0.1.0 release run (hosted runners):

| Artifact | Size |
|---|---|
| `pool-coordinator_0.1.0_amd64.deb` | 4.6 MB |
| `pool-coordinator_0.1.0_arm64.deb` | 4.2 MB |
| `pool-coordinator-0.1.0-macos-arm64.tar.gz` (as built; replaced by the image below) | 5.7 MB |
| `pool-coordinator-0.1.0-macos-arm64.dmg` (signed, notarized, stapled) | 6.2 MB |

All three are well under the 40 MB bound; the binary is 14.7 MB and the kernels 0.8 MB uncompressed.

| Job | Total | Kernels | Suite | Byte-identity | Compile and package | Smoke test |
|---|---|---|---|---|---|---|
| Linux amd64 (`ubuntu-22.04`) | 17 min 7 s | 12 s | 14 min 17 s | 84 s | 23 s | 16 s |
| Linux arm64 (`ubuntu-22.04-arm`) | 11 min 11 s | 16 s | 8 min 40 s | 68 s | 18 s | 17 s |
| macOS arm64 (`macos-14`) | 13 min 18 s | 19 s | 10 min 54 s | 74 s | 15 s | under 1 s |

The suite dominates each job. The site builds once in 19 s and publishing takes 9 s. The hosted macOS runner has Metal, and `check` reports it available there.

**The macOS artifact is a signed, notarized and stapled disk image.** v0.1.0's first macOS artifact was an unsigned tarball, and a browser download of it was killed at start: Gatekeeper refuses quarantined code it cannot vouch for (exit 137).
- **Signing and notarizing the bare files was not enough.** Signing the binary and library with the Werkswinkel Developer ID under the hardened runtime, and notarizing them, still left Gatekeeper on this Mac calling them "Unnotarized Developer ID". A bare Mach-O cannot hold a ticket, so it depends on an online lookup, and syspolicyd here could not reach its notarization daemon.
- **The stapled image works.** It carries its ticket, which macOS reads when the quarantined image is opened, and the quarantined program copied out of it runs; cloak-cli had already found this.
- **One entitlement.** The binary needs `allow-unsigned-executable-memory`: the Dart AOT runtime maps its snapshot as executable memory without MAP_JIT, and it is killed at start with no entitlement and with `allow-jit` alone.
- **The flow.** The workflow now leaves the release a draft. `scripts/sign-macos-release.sh` makes the image from the tarball built on the runner, notarizes and staples it, checks it as a downloader gets it, and swaps it in with a rewritten `SHA256SUMS`. v0.1.0's tarball was replaced this way; notarization took about a minute, and the `.deb` checksums are unchanged.

