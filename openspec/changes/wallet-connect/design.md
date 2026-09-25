## Context

cloak reads four values that only the pool's operator knows, or that cloak's defaults get wrong: `pool.server`, `pool.coordinator`, `chain.peers` and `arc.url`. cloak's testnet chain default, the seed name `testnet-seed.bitcoinsv.io:18333`, did not connect on 2026-09-25. overnode's three peers did: 105,464 headers in 3 minutes, about 580 a second, so a first sync to the testnet tip (about 1.76 million) takes around 50 minutes. The coordinator dials ricochet over loopback on overmedia (`/ip4/127.0.0.1/udp/55223/…`), so its own `ricochet.server` is not what a wallet dials. shieldpool.net reads the coordinator's API through a Pages Function, the tunnel and Access (`cloudflare-site`). `/testnet/` renders `<pool-dashboard>` from the vendored pool-elements tarball.

## Goals / Non-Goals

**Goals:**
- One source for the values, the coordinator's config, shown wherever the dashboard is shown.
- Output a user can paste into a shell without reading it first, which means strict checks in the element, not only in the config.

**Non-Goals:**
- Changes to cloak-cli (`cloak init --from`, a GorillaPool testnet default). These are named as follow-ups.
- DNS names in the multiaddr, since the transport does not resolve them.
- A separate route. The field rides on `/api/pool`, which the page already reads.

## Decisions

- **Configured, not derived.** The public address cannot be derived: the host sees loopback, and ricochet's `EXTERNAL_IP` lives in another process. The operator writes it once. The config check ties its peer id to `ricochet.server`'s, which catches pasting the wrong relay. The alternative was the site hard-coding the values. That means two sources that drift after a re-create, and the coordinator's own page would show nothing.
- **`network` in cloak's vocabulary** (`testnet`, `mainnet`, `regtest`). The API's existing `network` field is `test` or `main`, which is not what `cloak init --network` takes, and the element should not translate.
- **The whole file, not lines to merge.** The file `cloak init` writes already has `chain:` (with `confirmations`) and `arc:`. Lines to paste would give duplicate keys, which YAML parsers reject or resolve silently. The element shows the complete version 1 file, with cloak's defaults (timeout 30, confirmations 6 on testnet and mainnet and 1 on regtest, refund margin 144, refund minimum 100), for a new wallet to replace its `config.yaml` with, and says so above it. The alternative, a `--peers` and `--arc` flag on `cloak init`, belongs to cloak-cli and is a follow-up.
- **Checks in the element as well as the config.** The API is read through the edge, and the element's output ends up in a terminal. The element accepts only a closed grammar: IP multiaddr, base58 peer id, `https` URL without shell metacharacters. If any value fails, the whole section is hidden, not just that line: a half-filled command would still be pasted. The patterns are anchored and bounded:
  - peer id `^[1-9A-HJ-NP-Za-km-z]{46,60}$`;
  - ip4 dotted quad with each part 0 to 255;
  - ip6 `[0-9a-fA-F:.]{2,45}`;
  - port 1 to 65535;
  - URL `^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$`;
  - peer: an ip4 dotted quad or a host name of labels `[A-Za-z0-9-]{1,63}` joined by dots (at most 253 characters), then `:` and a port 1 to 65535, with at most 8 peers.
- **Rendered as text.** It uses Lit bindings only, as the other elements do. Copying uses `navigator.clipboard.writeText` with the block's exact string, and falls back to selecting the text when the clipboard API is refused (the site's CSP and permissions allow writeText on a user gesture).
- **Beside `<pool-dashboard>`, not inside it** (changed while applying). A URL fragment does not reach an id inside a shadow root, so `/testnet/#connect` could never scroll to a section inside the dashboard. Each page places `<pool-connect id="connect">` after the dashboard in its own light DOM and hands it the same feed. The element renders its own heading and sets `hidden` on its host when there is nothing valid to show, so the anchor has no empty target.

## Risks / Trade-offs

- **The relay's IP changes** (for example, the droplet is rebuilt) → the operator updates `api.wallet.server`; `relay.testnet` DNS doesn't help wallets until the transport resolves names. DEPLOYING.md says so.
- **The file follows cloak's config version 1.** If cloak moves to version 2, the element's file is refused by the new cloak, with a clear message that names the version. The element states the version it writes, and a new version needs a new element release.
- **Peers go stale.** They are the operator's, updated in the config like the relay's address. A wallet with none reachable stops at "chain" as it does today.
- **Advertising GorillaPool as the ARC** → it is the operator's choice and only a suggestion; the wallet can change it. It is optional, and null leaves cloak's default in place.
- **Cached `/api/pool` at the edge** → the edge caches only what the origin marks public with a max-age. `/api/pool` carries the live state, so it is short-lived either way, and a config change shows within one publication interval.

## Migration Plan

Ship in 0.1.1. A config without `api.wallet` behaves as before, and the section is hidden. On overmedia, add the section after the upgrade and restart. Rebuild the elements tarball and re-vendor it in shieldpool.net, then deploy the site. Rollback: remove the section.

## Open Questions

None.
