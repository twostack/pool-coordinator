## 1. The coordinator

- [x] 1.1 Add `api.wallet` (`server`, `peers`, `arc_url`) to `lib/src/config.dart` with the checks in server-process "What wallets are told", and to both config examples, commented out. Verify in `test/config_test.dart`: a good section is read; another relay's peer id, a `/dns4` address, a peer without a port, nine peers, an `http` ARC URL, and the section under a disabled `api` are each refused, naming the field.
- [x] 1.2 Add `wallet` to `PoolFacts` and to `/api/pool`, with `network` as cloak names it. Verify dashboard-api "What a wallet needs" and "Not named" in `test/api_test.dart`.

## 2. The element

- [x] 2.1 Write `web/src/elements/pool-connect.ts`: the patterns from design.md, the command and the complete config file (version 1, cloak's defaults), copy buttons with a fallback, rendering nothing unless every value passes. Export it from `lib.ts`. Verify in vitest: dashboard-site "The command a user pastes" (the file parsed as YAML with no duplicate key; and, done by hand on 2026-09-25, the generated file was byte-identical to the one cloak 0.1.0's `init` writes with the same values, and the installed cloak 0.1.0 loaded it), and "A value that is not what it claims" over a table of at least 30 hostile values (shell metacharacters, newlines in a peer or URL, YAML injection, `/dns4`, bad ports, over-long ids, `http:`, `javascript:`, unicode look-alikes), each hiding the section.
- [x] 2.2 Put `<pool-connect id="connect">` beside `<pool-dashboard>` in the page's light DOM, fed the same feed (a fragment cannot reach an id inside the dashboard's shadow root), with its own "Connect a wallet" heading and its host hidden when there is nothing to show. Verify dashboard-site "Copying" and "Not named" in Playwright with the fake API (`web/e2e/fake-api.ts` gains a `wallet` field, null by default), and that the layout checks still pass.

## 3. The site

- [x] 3.1 Pack the elements, re-vendor the tarball in `../shieldpool.net`, and add a "Connect a wallet" link from the landing page to `/testnet/#connect`. Verify with the site's vitest, Playwright (the fake origin serving a `wallet`), and the budget script (`/testnet/` ≤ 150 KB).

## 4. Deploying

- [ ] 4.1 Document `api.wallet` in `docs/DEPLOYING.md`: the public IP multiaddr, why not a DNS name, and the ARC choice. After 0.1.1 is on overmedia, set it and deploy the site; verify that `https://shieldpool.net/api/testnet/pool` carries the values, and that the command and the file from `/testnet/#connect`, used on a fresh install, give a wallet whose `cloak sync` gets past "chain" and reaches the pool.
