## 1. Prerequisites

- [x] 1.1 Archive `pool-dashboard` so `dashboard-site` exists under `openspec/specs/`. Verify `openspec validate cloudflare-site` resolves this change's MODIFIED requirements against it.
- [x] 1.2 Collect from the owner: the Cloudflare account (logged in locally, zone `shieldpool.net` active on the Free plan), the GitHub repository (`twostack/shieldpool.net`), and the mail forwards (none: the domain carries no mail). Verify the zone's intended records are written down in the site repository's `docs/DNS.md`.

## 2. pool-coordinator: embeddable elements

- [x] 2.1 Make the API base configurable: `browserDeps(base = '/api')`, and every route in `api.ts` and `feed.ts` relative to it. Verify dashboard-site "A different API base" in `web/test/feed.test.ts`, and that the existing tests pass unchanged with the default.
- [x] 2.2 Check every element for colours, fonts and sizes not taken from a `--pool-*` property, and replace them. Document the properties in `web/pool-elements/README.md`, which ships in the package, with a pointer from the repository's README. Verify dashboard-site "Themed by the host" with a Playwright page that sets other values.
- [x] 2.3 Add the library build (`web/vite.lib.config.ts`, `web/pool-elements/package.json`, an entry exporting the five elements, `PoolFeed` and `browserDeps`) and the default `theme.css`. Verify that `npm pack` gives a tarball which, installed in an empty Vite project, renders `pool-stats` against the fake API. Also verify that `npm run build` still passes the 150 KB budget.
- [x] 2.4 Verify dashboard-site "Markup through an embedded element" in the host-page Playwright test from 2.2.
- [ ] 2.5 Attach `pool-elements-X.Y.Z.tgz` in `.github/workflows/release.yml`, and add it to `SHA256SUMS`. Verify dashboard-site "The package is the release's" on a draft release of the next version.

## 3. The site repository

- [x] 3.1 Build the site in `../shieldpool.net` (the `twostack/shieldpool.net` repository): Vite multi-page (`/`, `/protocol/`, `/testnet/`), the mockups moved in with their inline styles and scripts extracted to files, `package-lock.json` committed, and a README. Verify `npm ci && npm run build` succeeds and edge-site "Reproducible build" (two builds byte-identical).
- [x] 3.2 Self-host the fonts: Bodoni Moda, Instrument Sans and IBM Plex Mono as Latin-subset woff2, with their OFL licences in `public/fonts/`. Remove every Google Fonts link. Verify edge-site "Only the site's origin" in Playwright with network logging.
- [x] 3.3 Replace the landing widget's sample data with the live pool. The ticket keeps its own markup, filled as text from one `PoolFeed` at `/api/testnet` (`feed.subscribe`), with its sparkline drawn from the feed's series. `/testnet/` is themed through the `--pool-*` mapping. `pool-elements` is pinned by version and integrity: vendored until a release carries the tarball, then by the release URL. Make `/testnet/` the full `pool-dashboard`. Verify edge-site "The landing page against a live pool" and "The API down" against a fake origin.
- [x] 3.4 Write `public/_headers` (the policy, HSTS, `nosniff`, `Referrer-Policy`, immutable caching of hashed assets) and `public/_redirects`. Verify edge-site "Headers on every page" against `wrangler pages dev`.
- [x] 3.5 Add a size budget script: `/` under 250 KB gzipped with fonts, `/testnet/` under 150 KB without. Verify it fails the build when a 300 KB file is added to `/`.

## 4. The edge route

- [x] 4.1 Write `functions/api/testnet/[[path]].ts`:
  - the method check;
  - the path check and mapping;
  - the header allowlist;
  - the 10 s timeout except for events;
  - the 502 shape;
  - the event pass-through;
  - `caches.default` for responses marked public;
  - `POOL_ORIGIN` and the Access headers from the environment.

  Verify edge-site "A read passes through", "A write refused at the edge", "A path that escapes the route" and "The origin hangs" with vitest and a fake origin.
- [x] 4.2 Verify edge-site "A mined page from the cache" and "Live state is never cached" through `wrangler pages dev` with a counting fake origin.
- [x] 4.3 Verify edge-site "Events are not buffered": a fake origin sending a comment every 15 s, through `wrangler pages dev`, held for 5 minutes, each comment received within 1 s.
- [x] 4.4 Verify the route's robustness by mutation testing: 10,000 requests with random methods, paths (encodings, dot segments, long paths), query strings and headers. Every answer is one of 200/304/400/404/405/502 with the API's JSON shape or the origin's body, and the fake origin never sees a path outside `/api/`, a header outside the allowlist, or a method other than GET or HEAD.

## 5. overmedia: the tunnel

- [x] 5.1 Create the tunnel `pool-origin` in the Cloudflare account and install `cloudflared` on overmedia as a systemd service with its token. Write `deploy/cloudflared/config.example.yml` with the single ingress and the 404 catch-all. Verify `cloudflared tunnel info` shows it connected, and that `curl` through it with the token returns `/api/pool` (once the coordinator runs).
- [x] 5.2 Create the Access application for `pool-origin.shieldpool.net` with a service-token-only policy. Store the token as Pages secrets. Verify edge-site "Direct requests are refused" from outside Cloudflare, and "The token is not in the build" by searching the repository and `dist/`.

## 6. DNS, mail and the cut-over

- [x] 6.1 The zone on Cloudflare (moved by the owner, empty) holds `testnet.shieldpool.net` DNS-only to overmedia until the cut-over. Verify with `dig` that it resolves and the Caddy dashboard answers.
- [x] 6.2 Add the records and rules:
  - `relay.testnet` A, DNS-only;
  - the tunnel's CNAME;
  - the Pages custom domains for the apex and `www`;
  - the `testnet` placeholder `AAAA 100::`, proxied;
  - Redirect Rules for `www` → apex and `testnet.` → `/testnet/`;
  - the WAF rate-limiting rule on `/api/*` (60 per 10 s per IP, block 10 s).

  Verify these with `dig @<cloudflare ns>` before the nameservers change.
- [ ] 6.3 Change the nameservers at Namecheap. Verify:
  - edge-site "The relay is not proxied";
  - "The old dashboard name";
  - "A scraper is limited";
  - the event stream held for 5 minutes from a browser on the production site.
- [x] 6.4 Stop and disable Caddy on overmedia (`supervisorctl stop caddy`, `autostart=false`). Verify edge-site "No web port on the host" with `nc -zv` on 80, 443 and 8787 from outside, and that the site still works.

## 7. Documentation and the record

- [x] 7.1 Update `docs/DEPLOYING.md`:
  - the tunnel path as the default for the public page;
  - Caddy as the alternative without Cloudflare;
  - ricochet's name as `relay.testnet.shieldpool.net`.

  Verify by following the tunnel section on overmedia.
- [ ] 7.2 Measure with `tool/scratch/edge_probe.sh` (new) against production:
  - the gzipped weight of `/` and `/testnet/`;
  - the event-stream delay (coordinator comment to browser) over 5 minutes;
  - the Function's added latency on `/api/testnet/pool` against the tunnel's `curl` time;
  - a day's Workers request count with the dashboard open.

  Record them in a dated section of `docs/DESIGN.md`.
- [ ] 7.3 Append the dated section for this change to `docs/DESIGN.md` (the decisions, the measured numbers, the DNS move and what it found) before archiving; verify it is there.
