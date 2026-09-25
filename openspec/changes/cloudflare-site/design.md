## Context

- **The dashboard (`web/`)** is Lit elements and uPlot, built by Vite into one page of 108 KB (`web/dist`), with a 150 KB gzipped budget enforced by `web/scripts/budget.mjs`.
  - Every element is fed by one `PoolFeed` (`web/src/feed.ts`), whose `browserDeps(origin)` already prefixes an origin to each route. The routes themselves are hard-coded under `/api/` in `api.ts` and `feed.ts`.
  - Colours, fonts, radius and card width are CSS custom properties (`--pool-*` in `web/src/theme.css`), which reach into the shadow roots through inheritance.
- **The API (`lib/src/api/`)** binds to loopback only.
  - It marks live routes `no-store` and settled round pages `public, max-age=31536000, immutable`.
  - It rounds every time it serves to 30 s.
  - It sends an event-stream comment every 15 s and caps subscribers at 200.
- **The mockups** (`../shieldpool.net/mockup/index.html` and `protocol.html`) are hand-written HTML with inline `<style>` and `<script>`, and fonts from Google Fonts.
- **The shieldpool.net zone is on Namecheap's nameservers.** `testnet.shieldpool.net` is an A record to overmedia (139.59.159.19), where Caddy serves the dashboard with a Let's Encrypt certificate.

## Goals / Non-Goals

**Goals:**
- Every web asset is on Cloudflare. overmedia opens no web port.
- The API is on the site's own origin, so the content security policy stays `'self'` and the Dart API needs no CORS.
- The landing page's widget is the dashboard's own elements, themed to the landing page.
- Everything stays on Cloudflare's free plan.

**Non-Goals:**
- Sharing one upstream event stream among viewers, with a Durable Object. At 200 subscribers per coordinator that is for later; the design leaves room for it behind the same route.
- A mainnet pool. The `/api/<network>/` shape leaves room for one.
- Proxying ricochet. Cloudflare does not proxy UDP outside Spectrum, so wallets reach the relay directly.
- Any change to the Dart API.

## Decisions

**A Pages Function rather than a separate Worker.** `functions/api/testnet/[[path]].ts` in the site repository is deployed with the pages, shares their origin and their preview deployments, and is a Worker underneath.
- Alternative: a Worker on the zone route `shieldpool.net/api/*`. It is equally able, but it is a second deployable whose version drifts from the site's, and preview deployments would not get it.

**The origin: a Cloudflare Tunnel, protected by Access.**
- `cloudflared` on overmedia runs as a service, installed with the tunnel's token, with ingress `pool-origin.shieldpool.net → http://127.0.0.1:8787` and `http_status:404` for everything else.
- An Access application on `pool-origin.shieldpool.net` allows only a service-token policy. The Function sends `CF-Access-Client-Id` and `CF-Access-Client-Secret` from Pages secrets.
- Alternatives:
  - Proxied DNS to an open 443 with an origin certificate: the port stays open and needs an IP allowlist.
  - A shared-secret header checked by the coordinator: a Dart change, and the host would still be exposed.
  - Workers VPC bindings to a tunnel: newer and in beta. Reconsider when they are generally available.

**The Function's behaviour:**
- **Method:** GET and HEAD only; anything else gets 405.
- **Path:**
  - decoded once;
  - refused with 400 if it holds `..`, `%2f`, `%5c` or a backslash;
  - mapped from `/api/testnet/<rest>` to `/api/<rest>`;
  - the query string passed as it came.
- **Request headers:** only `Accept`, `If-None-Match` and `Last-Event-ID` are forwarded.
- **Timeout:** `AbortSignal.timeout(10_000)` for every route except `/events`. A timeout or a network error gets 502 with the API's error shape: `{"v":1,"error":"the pool cannot be reached"}`.
- **Events:** `/events` is returned as `new Response(upstream.body, …)`, which Workers stream through. CPU time is not spent while waiting, and the coordinator's 15 s comments keep Cloudflare's 100 s idle timeout from closing the stream.
- **Caching:** through `caches.default`, keyed by the public URL. The Function stores and serves only responses whose `Cache-Control` has `public` and a `max-age`. Everything else passes through.
- **The origin URL:** the environment variable `POOL_ORIGIN` (`https://pool-origin.shieldpool.net` in production, a local fake in tests).

**Unknown paths.** This was found while applying the change. Pages serves `index.html` with status 200 for any path it has no file for, unless the site has a `404.html`, so a scanner's `/api/.env` got the landing page. It also resolves dot segments before routing, so `/api/testnet/%2e%2e/x` never reaches the route at all: it arrives as `/api/x`. So the site has:
- a `404.html`, served with status 404;
- a catch-all Function, `functions/api/[[path]].ts`, answering the API's JSON 404 for any `/api/` path outside a pool's route.

Nothing outside `/api/testnet/` can reach a coordinator either way.

**The rate limit: one WAF rate-limiting rule (the free plan's one).**
- Match: `http.request.uri.path` starts with `/api/`.
- Counted per IP, 60 requests per 10 s, blocking for 10 s.
- A page load is about six requests, and paging back one more each, so a person stays far under.
- Alternative: rate limiting inside the Function with the Workers Rate Limiting binding. It is also viable, but the WAF rule refuses before the Function runs and costs no invocations.

**How the elements reach the site: a tarball on the pool-coordinator release.**
- `web/` gains a second Vite entry in library mode (`vite build --config vite.lib.config.ts`). It emits `pool-elements/dist/index.js`, its type declarations, and `tokens.css`, the default tokens. `scripts/pack-elements.mjs` builds all three and runs `npm pack` with pool-coordinator's version.
- `npm pack` of that directory is attached to each release as `pool-elements-X.Y.Z.tgz`.
- The site depends on the tarball's URL. Its `package-lock.json` pins its integrity, so a site build is reproducible, and a coordinator release does not change the site until the site's dependency is bumped.
- Alternatives:
  - The npm registry: a scope and an account for one consumer.
  - A git submodule of pool-coordinator: the site's build would need Dart's repository and Node's toolchain together.

**The API base.** `browserDeps(base = '/api')` and every route in `api.ts` become relative to it: `base + '/pool'` in place of `'/api/pool'`. The single-page build keeps `/api`, and the site passes `/api/testnet`.

**Theming.** The `--pool-*` properties are the contract, documented in the package's README. The site's `theme.css` maps its tokens onto them:
- `--pool-surface: var(--surface)`
- `--pool-accent: var(--engrave)`
- `--pool-font: var(--body)`
- and so on.

A task checks every element for colours or fonts not taken from a `--pool-*` property.

Applying this turned up a gap, and the elements were corrected. The elements never set `--pool-font` themselves: they inherited the font from the dashboard page's `body`, which only `theme.css` styled. Embedded in another page, they took that page's body font instead of the theme. Each element's `:host` now sets `font-family: var(--pool-font)` and `color: var(--pool-text)`. The tokens moved out of `theme.css` into `tokens.css`, which the package ships and the page imports, so a host gets the defaults without the dashboard page's `html`/`body` rules. The spec's "spacing" was narrowed to what is actually a property: corner radius and card width.

**The landing widget keeps its own design.** The owner chose this on 2026-09-25, while applying the change. The mockup's ticket has its own layout: the round number and stage rail, a 3×2 grid of figures, a sparkline, and a compact list of rounds with bars. The elements would replace it with 15rem cards and a horizontal scroll. So the ticket's markup stays. `pool-elements`' `PoolFeed` feeds it through `subscribe`, and every value is written as text (`textContent`, never markup). The sparkline stays the mockup's 64 px SVG, drawn with DOM calls from `feed.series('transfers', 'day')`: `pool-chart` is a fixed 160 px figure with a caption, which does not fit the ticket. `/testnet/` uses the elements as they are. One feed, one event stream, and the text-only rule are the same as the elements'.

**The site repository** (`../shieldpool.net`, at `twostack/shieldpool.net`):
- A Vite multi-page build: `index.html`, `protocol/index.html`, `testnet/index.html`.
- The mockups' inline styles and scripts move into files, since the policy allows no inline script.
- The rosette canvas and the copy button become a module.
- Fonts are OFL-licensed woff2 files in `public/fonts/`, subset to Latin: Bodoni Moda, Instrument Sans and IBM Plex Mono.
- `public/_headers` sets the policy, HSTS, `nosniff`, `Referrer-Policy: no-referrer`, and the cache headers for assets named by content.
- `_redirects` handles `/protocol.html` → `/protocol`.
- Host redirects (`www` → apex, `testnet.` → `/testnet/`) are Redirect Rules on the zone, because `_redirects` cannot match a hostname. `testnet` needs a proxied placeholder record (`AAAA 100::`) for the rule to see its requests.

**Deploying the site.** A GitHub Actions workflow runs the tests (vitest for the Function, Playwright for the pages against `wrangler pages dev` and a fake origin), then `wrangler pages deploy`. A failing test blocks a deploy.
- Branches deploy to preview URLs, and `main` deploys to production.
- The Access token and `POOL_ORIGIN` are Pages secrets and environment variables. The workflow holds only a Cloudflare API token scoped to Pages.
- Alternative: Cloudflare's Git integration builds on push. It is simpler, but a failing test would not block the deploy.

**The DNS move.** The owner moved the nameservers to Cloudflare on 2026-09-25, before the tunnel and the site were in place, with an empty zone. Namecheap's mail forwarders went with it. The owner confirmed they were never used, so the domain now carries no mail. `testnet.shieldpool.net` was re-added DNS-only, pointing at overmedia, so the Caddy dashboard stays up until the cut-over. The steps done by hand in the dashboard (Access, the tunnel's public hostname, custom domains, the relay record, the redirect and rate-limit rules) are listed in the site repository's `docs/DNS.md`.

## Risks / Trade-offs

- **[The event stream through Cloudflare]** Cloudflare may buffer, or close idle streams at 100 s. → The coordinator's 15 s comments and the Function's pass-through. A scenario holds a stream for 5 minutes through `wrangler pages dev`, and task 6.3 re-checks it in production.
- **[The Workers free-plan limit of 100,000 requests a day]** Each open page costs one long request for events plus about one a minute of refetches (`PoolFeed` refetches when it hears nothing for a publication interval). → At the free limit that is about 70 concurrent viewers all day. The status in the Cloudflare dashboard is watched in the trial. Beyond that, the paid Workers plan ($5 a month) or a shared stream.
- **[Cloudflare as a party]** It sees visitors' addresses and every request. → The pages and the API are public by design. The site's footer says so. No wallet traffic goes through Cloudflare.
- **[One coordinator per path]** `/api/testnet` is hard-wired to one origin. → The Function reads the network from the path and the origin from a map in its environment, so a second pool is configuration.
- **[The tarball URL]** A release deleted or renamed breaks the site's `npm ci`. → Releases are immutable by the project's release process (docs/RELEASING.md), and the lockfile's integrity check fails loudly rather than silently.

Bounds set before measuring, and what happens if a measurement fails one:
- **`/` under 250 KB gzipped, fonts included.** If it fails, the fonts are subset further (weights actually used only) before anything else is cut. If still over, the widget's chart is loaded when it scrolls into view.
- **Events within 1 s of the coordinator sending them, held for 5 minutes.** If Cloudflare buffers, the Function adds `Content-Type: text/event-stream` and `Cache-Control: no-transform` explicitly and flushes. If it still fails, the widget falls back to polling `/api/pool` every publication interval, which the feed already does when it hears nothing.
- **502 within 10 s on a hung origin.** If `AbortSignal.timeout` is not honoured by the tunnel's fetch, a `Promise.race` against a timer is used.

## Migration Plan

1. Release pool-coordinator 0.1.x with `pool-elements` attached, and the Caddy path unchanged.
2. Build and deploy the site to its `*.pages.dev` address. Point `POOL_ORIGIN` at the tunnel once the tunnel is up. Check the pages there before any DNS change.
3. Install `cloudflared` on overmedia. The tunnel runs alongside Caddy, and nothing changes publicly yet.
4. Move DNS in the order above. `testnet.shieldpool.net` switches from Caddy to the redirect when the nameservers change.
5. Stop and disable Caddy. Ports 80 and 443 close.

**Rollback:** set the nameservers back to Namecheap. Namecheap's records and forwarding are unchanged, and Caddy can be started again with its certificate still on disk.
