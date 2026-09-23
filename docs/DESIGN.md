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
