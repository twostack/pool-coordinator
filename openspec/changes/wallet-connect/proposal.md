## Why

A new cloak wallet starts with `pool.server: ~`, `pool.coordinator: ~`, `chain.peers: []` and `arc.url: ~`, and nothing a user can reach tells them what to put there. shieldpool.net shows the pool's rounds but not how to join it. The values are awkward to type or guess:
- The server is a multiaddr: `/ip4/<address>/udp/55223/udx/p2p/<peer id>`. It must be an IP address, because dart_libp2p's UDX transport dials only `/ip4` and `/ip6`, not `/dns4`.
- The coordinator is a 52-character peer id.
- The chain peers are needed because cloak's testnet default, the DNS seed name `testnet-seed.bitcoinsv.io:18333`, accepted no connection from cloak 0.1.0 on 2026-09-25, so `cloak sync` stopped at "chain" before it read the pool. With overnode's peers (`198.154.93.206`, `51.79.25.225`, `3.123.101.88`, port 18333) the same wallet synced headers and reached the pool.
- The ARC endpoint is needed because cloak's testnet default, TAAL's `arc-test.taal.com`, answers 401 without a key (seen from the coordinator on 2026-09-25). A testnet wallet with `arc: url: ~` therefore cannot broadcast a transparent transaction.

The coordinator is the one place that knows its own peer id and network, and its operator knows the public address of the ricochet server. The site already reads the coordinator's API, so it can show the values it is given, ready to copy.

## What Changes

- **The operator names what wallets use.** A new optional `api.wallet` section in the coordinator's config:
  - `server`: the ricochet server as wallets reach it. It is a public `/ip4` or `/ip6` multiaddr, which is not the loopback address the coordinator itself dials.
  - `peers`: chain peers a wallet's header sync can use, as `host:port`. It is optional, with at most 8.
  - `arc_url`: an ARC endpoint a wallet on this network can use without a key. It is optional.

  The config is refused if `server` is not a UDX multiaddr with an IP address and a `/p2p` peer id, or if that peer id is not the one in `ricochet.server`. It is also refused if `arc_url` is not an `https` URL, or if a peer is not an IPv4 address or host name with a port.
- **`/api/pool` carries them.** A new `wallet` field holds `server`, `coordinator` (the coordinator's own peer id), `network` (cloak's name for it: `testnet`, `mainnet` or `regtest`) `peers` (a list, empty when none are named) and `arcUrl`. The field is `null` when the section is absent. The response version stays 1, because the field is additive.
- **`<pool-connect>`, a new element in pool-elements.** Under "Connect a wallet", it shows two things, each with a copy button:
  - the `cloak init --network … --server … --pool …` command;
  - the complete `config.yaml` a new wallet should have, in cloak's config version 1 with cloak's defaults, naming the pool, the peers and the ARC endpoint. It replaces the file `cloak init` wrote. Separate lines to paste would give `chain:` twice, because the file `cloak init` writes already has a `chain:` section.

  It renders nothing unless every value matches a strict pattern (multiaddr, base58 peer id, `host:port`, https URL). Its output is pasted into a shell, and a compromised origin must not be able to put anything else there.
- **Where it appears.** `<pool-dashboard>` includes it, so the coordinator's own page shows it. shieldpool.net's `/testnet/` shows it at `#connect`, and its landing page links there.

What this moves:
- **What a new user has to find for themselves: from four values to none.** A requirement: the command and the lines on the page are exactly what cloak reads.
- **What the page weighs, which has a bound.** `/testnet/` must stay within its 150 KB budget, and the site's budget script enforces that.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `dashboard-api`: "Read-only routes" gains `/api/pool`'s `wallet` field. "Nothing private and no fine timing is served" is unchanged: the coordinator's own peer id and the relay's public address are what every wallet must be told, and no sender's peer id is served.
- `dashboard-site`: a new requirement, "Connecting a wallet", covers the element, its strict patterns, the copy buttons, and hiding the section when `wallet` is null.
- `server-process`: the config's `api.wallet` section and its checks. The server-process capability comes from `coordinator-server`, which must be archived first; `spend-unconfirmed` task 1.1 does that.

## Impact

- **pool-coordinator:**
  - `lib/src/config.dart` (the section and its checks), `lib/src/api/pool_api.dart` (the field), `lib/src/server.dart` (passing it through);
  - both config examples;
  - `web/src/elements/pool-connect.ts` (new), `pool-dashboard.ts`, `lib.ts`;
  - `docs/DEPLOYING.md`.
- **shieldpool.net:** the vendored pool-elements tarball, `testnet/index.html` (the anchor), the landing page's link.
- **overmedia:** after the release, `api.wallet.server: /ip4/139.59.159.19/udp/55223/udx/p2p/12D3KooWFuA6F9bBybjmQ6ZWUd9hKK4GXHXGTnyY11zAXA1gbeu7` `peers: [198.154.93.206:18333, 51.79.25.225:18333, 3.123.101.88:18333]` and `arc_url: https://testnet.arc.gorillapool.io/v1`.
- **tstokenlib:** no change. The pool-protocol descriptor (`pool-protocol`) names the genesis, not how a wallet reaches the pool. This repo adds the reaching, which the library leaves to the transport's user.
- **cloak-cli, a follow-up outside this change:** its testnet chain default (the seed name) did not connect, and its testnet ARC default needs a key. It could default to working peers and to GorillaPool, or learn `cloak init --from <url>` to read this field directly.
- **Release:** it ships in 0.1.1 with `spend-unconfirmed`.
