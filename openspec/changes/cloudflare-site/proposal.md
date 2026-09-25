## Why

shieldpool.net is getting a landing page (the mockup in `../shieldpool.net/mockup`), and its "live pool" widget is shaped after the coordinator's API but shows sample data. Today the pool's dashboard is served by Caddy on the coordinator's own host, testnet.shieldpool.net on overmedia, with ports 80 and 443 open to the internet. Within a minute of the certificate being issued on 2026-09-25, scanners were asking it for `/api/.env`.

This change moves every public web asset to Cloudflare and keeps only the pool's backend on overmedia:
- the landing page, the protocol page and the full dashboard are static files on Cloudflare Pages;
- the API is reached through a same-origin Worker and a Cloudflare Tunnel;
- the coordinator's host opens no web port at all.

The landing page's widget becomes the dashboard's own elements, fed by the live pool.

## What Changes

- **The dashboard can be embedded (pool-coordinator `web/`):**
  - A second build publishes the dashboard's custom elements (`pool-live-card`, `pool-stats`, `pool-chart`, `pool-rounds`, `pool-dashboard`) and `PoolFeed` as an ES module package, `pool-elements`. It is attached to each pool-coordinator release as an npm tarball.
  - The feed takes an API base (`/api` by default, `/api/testnet` on shieldpool.net) in place of the hard-coded `/api`.
  - The elements take their colours and fonts from CSS custom properties, so a host page can theme them.
  - The existing single-page build and its budget stay as they are.
- **The site repository, `twostack/shieldpool.net`, in `../shieldpool.net`:** a static multi-page site built from the mockups.
  - `/` is the landing page, with the live widget built from `pool-elements`.
  - `/protocol` is the protocol page.
  - `/testnet/` is the full dashboard.
  - It is deployed to Cloudflare Pages, with previews for branches.
  - Fonts are self-hosted and every script is a file, so the content security policy allows the site's own origin only.
- **A same-origin API route on the edge.** A Pages Function at `/api/testnet/*`:
  - forwards GET and HEAD to the coordinator's API through the tunnel, with a Cloudflare Access service token, and answers any other method 405;
  - streams `/api/events` unbuffered;
  - caches only what the coordinator marks cacheable (pages of mined rounds, which are immutable);
  - answers 502 with the API's own error shape when the tunnel or the coordinator is down.

  A WAF rate-limiting rule on `/api/*` replaces Caddy's per-address rate limit, which behind Cloudflare would see Cloudflare's addresses rather than visitors'.
- **A Cloudflare Tunnel on overmedia.** `cloudflared` runs as a service with a single ingress: `pool-origin.shieldpool.net` to `http://127.0.0.1:8787`. Cloudflare Access refuses any request to that hostname without the Worker's service token. Caddy is stopped and ports 80 and 443 close. The Caddy path stays documented for operators who run a pool without Cloudflare.
- **DNS moves to Cloudflare.**
  - The shieldpool.net zone's nameservers move from Namecheap to Cloudflare.
  - The domain carries no mail. The Namecheap forwarders were never used (the owner, 2026-09-25), so no mail routing moves with the zone.
  - `testnet.shieldpool.net` becomes a redirect to `https://shieldpool.net/testnet/`.
  - Ricochet gets a DNS-only name, `relay.testnet.shieldpool.net` (grey cloud, UDP 55223 to overmedia), because Cloudflare does not proxy UDP.
- **Runbook:** `docs/DEPLOYING.md` gains the tunnel path and makes Caddy its alternative. The site repository has its own README for building and deploying.

What this moves, and the bounds (the specs make each a requirement):

- **Ports open on overmedia for the web:** from 80 and 443 to none. UDP 55223 for ricochet and SSH stay open.
- **Page weight:** the dashboard's gzipped budget of 150 KB still holds for `/testnet/`. The landing page with its widget stays under 250 KB gzipped, fonts included.
- **Requests to the coordinator:** a mined-round page served from the edge cache does not reach overmedia. The live routes are passed through, and each open page holds one event stream (the coordinator caps them at 200).

## Capabilities

### New Capabilities
- `edge-site`: shieldpool.net on Cloudflare. It covers:
  - the static pages and their content security policy;
  - the same-origin API route: its methods, its caching, the event stream passed through, and errors when the origin is down;
  - the origin reachable only through the tunnel and the service token;
  - the rate limit;
  - the DNS names, including the relay name.

  It also carries the non-functional contract: hostile requests, no third-party requests from the pages, what Cloudflare can see, determinism of builds, versioned element packages, page weight, and failure behaviour.

### Modified Capabilities
- `dashboard-site`:
  - "Served behind a colocated proxy" becomes "Served behind a proxy": the colocated Caddy, or the edge route of `edge-site`, with the same guarantees. The coordinator's port stays unreachable except through the proxy.
  - "API data is text, never markup" keeps its rule, and the policy now comes from whichever proxy serves the page.
  - A new requirement covers the embeddable elements: the configurable API base, the theme properties, and the package.

`dashboard-site` was introduced by `pool-dashboard`, which is not archived yet. It must be archived before this change is, so that the modified requirements exist under `openspec/specs/`.

## Impact

- **pool-coordinator:**
  - `web/src/feed.ts` (the API base), `web/src/theme.css` and the elements (themable properties), `web/vite.config.ts` (the library build), `web/package.json`;
  - `.github/workflows/release.yml` (attach `pool-elements-X.Y.Z.tgz`);
  - `deploy/cloudflared/` (new: config example and notes);
  - `docs/DEPLOYING.md`.

  No Dart code changes: the API, its loopback bind, its cache headers and its 15 s event heartbeat already fit the edge route.
- **The site repository `twostack/shieldpool.net`** (`../shieldpool.net`, created by the owner): Vite, the Pages Function, `_headers`, `_redirects`, tests and a CI workflow.
- **Cloudflare account:** the zone, Pages, one Pages Function, Access with one service token, one tunnel, and one WAF rate-limiting rule. All of these are on the free plan.
- **overmedia:** `cloudflared` installed as a service. Caddy is stopped and disabled.
- **Not affected:** tstokenlib; the transport; wallets (cloak reaches the pool over ricochet, not the web).
