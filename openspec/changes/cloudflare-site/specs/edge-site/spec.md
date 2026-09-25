## Purpose

shieldpool.net on Cloudflare: the static pages, a same-origin route to the coordinator's read-only API through a tunnel, and the DNS names, with no web port open on the coordinator's host.

## ADDED Requirements

### Requirement: The pages
The site SHALL serve these pages from Cloudflare Pages:
- `/`: the landing page. Its live widget keeps the landing page's own design and is fed by `pool-elements`' feed over one event stream, with every API string rendered as text. Its sparkline is drawn from the feed's series;
- `/protocol`: the protocol page;
- `/testnet/`: the full dashboard of the testnet pool.

Each page SHALL render its content without the API, and SHALL show the widget's or the dashboard's own stale or unavailable state when the API does not answer. No page SHALL show sample figures.

#### Scenario: The landing page against a live pool
- **WHEN** `/` is loaded in the browser test with the edge route pointed at a coordinator serving the test chain
- **THEN** the widget shows the pool's current round and statistics from `/api/testnet/pool`, and updates when the event stream sends a `live` event

#### Scenario: The API down
- **WHEN** `/` and `/testnet/` are loaded while the edge route answers 502
- **THEN** both pages render their static content, and the widget and the dashboard say the pool cannot be reached

### Requirement: The same-origin API route
Requests to `/api/testnet/<path>` SHALL be forwarded as `/api/<path>`, with the query string, to the coordinator's API through the tunnel. The route SHALL:
- forward only GET and HEAD, answering any other method 405 with `Allow: GET, HEAD` and the API's JSON error shape;
- pass the coordinator's status, body and `Cache-Control` through unchanged;
- stream `/api/events` to the client as it arrives, with no buffering and no timeout of its own;
- answer 502 with the API's JSON error shape, naming neither the origin nor the tunnel, when the tunnel or the coordinator does not answer.

#### Scenario: A read passes through
- **WHEN** a client asks `/api/testnet/rounds?before=10` and the coordinator answers
- **THEN** the client receives the coordinator's body and status for `/api/rounds?before=10`

#### Scenario: A write refused at the edge
- **WHEN** a client sends POST, PUT or DELETE to `/api/testnet/pool`
- **THEN** it gets 405 with `Allow: GET, HEAD`, and no request reaches the coordinator

#### Scenario: Events are not buffered
- **WHEN** a client subscribes to `/api/testnet/events` through the local Pages runtime, and the coordinator sends a comment every 15 s
- **THEN** the client receives each comment within 1 s of the coordinator sending it, and the stream stays open for 5 minutes

### Requirement: Edge caching
The route SHALL cache at the edge only responses whose `Cache-Control` the coordinator marks public: today, pages of mined rounds, marked `public, max-age=31536000, immutable`. It SHALL serve those from the cache for their marked lifetime. It SHALL NOT cache a response marked `no-store`, an error, or the event stream.

#### Scenario: A mined page from the cache
- **WHEN** a page of mined rounds is asked for twice
- **THEN** the coordinator receives one request, and both clients get the same body

#### Scenario: Live state is never cached
- **WHEN** `/api/testnet/pool` is asked for twice, 1 s apart
- **THEN** the coordinator receives two requests

### Requirement: The origin is reachable only through the edge route
The coordinator's host SHALL open no TCP port for the web.
- The tunnel SHALL connect outbound from the host and route exactly one public hostname, `pool-origin.shieldpool.net`, to the API's loopback port.
- Every other hostname and path SHALL get 404 from the tunnel itself.
- Cloudflare Access SHALL refuse any request to `pool-origin.shieldpool.net` that does not carry the edge route's service token.
- The token SHALL be held only as secrets of the Pages project and never appear in the site's repository or its built files.

#### Scenario: Direct requests are refused
- **WHEN** a client outside Cloudflare asks `https://pool-origin.shieldpool.net/api/pool` without the token
- **THEN** it is refused by Access, and the coordinator receives nothing

#### Scenario: No web port on the host
- **WHEN** the coordinator's host is scanned from outside on TCP 80, 443 and 8787
- **THEN** none of them accepts a connection

#### Scenario: The token is not in the build
- **WHEN** the site's repository and its built output are searched for the service token's id and secret
- **THEN** neither is found

### Requirement: Rate limit
Requests to `/api/*` SHALL be rate limited per client address at the edge. A client over the limit SHALL get 429 without reaching the route or the coordinator. A page load, including paging back through rounds, SHALL stay under the limit.

#### Scenario: A scraper is limited
- **WHEN** one address sends 200 requests to `/api/testnet/rounds` within the rule's window
- **THEN** requests beyond the limit get 429, and a browser test of a page load from another address is unaffected

### Requirement: Content security and third parties
Every page SHALL be served with a content security policy allowing scripts, styles, fonts, images and connections from the site's own origin only, with no inline script, and with `frame-ancestors 'none'`, HSTS and `nosniff`. Pages SHALL make no request to any other origin. Fonts SHALL be self-hosted, with no analytics beacon and no CDN.

#### Scenario: Only the site's origin
- **WHEN** each page is loaded in the browser test with network logging
- **THEN** every request goes to the site's own origin, and the console reports no policy violation

#### Scenario: Headers on every page
- **WHEN** `/`, `/protocol` and `/testnet/` are fetched
- **THEN** each carries the content security policy, HSTS, `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`

### Requirement: Names
The zone SHALL hold:
- `shieldpool.net` and `www.shieldpool.net` on the Pages project, with `www` redirected to the apex;
- `testnet.shieldpool.net` redirected permanently to `https://shieldpool.net/testnet/`;
- `pool-origin.shieldpool.net` as the tunnel's hostname;
- `relay.testnet.shieldpool.net` as a DNS-only A record for the ricochet relay's address.

The domain receives no mail. The zone SHALL publish no MX record for it.

#### Scenario: The relay is not proxied
- **WHEN** `relay.testnet.shieldpool.net` is resolved
- **THEN** it returns the relay host's own address, not a Cloudflare address

#### Scenario: The old dashboard name
- **WHEN** `https://testnet.shieldpool.net/` is requested
- **THEN** it answers 301 to `https://shieldpool.net/testnet/`

### Requirement: Non-functional contract
The site SHALL meet the following contract.
- **Untrusted input:**
  - the route forwards only the path under `/api/testnet/` and the query string;
  - it rejects a path containing `..` or an encoded slash with 400, and any other path under `/api/` gets the API's JSON 404;
  - it forwards no client header but `Accept`, `If-None-Match` and `Last-Event-ID`.
- **Secrets and privacy:**
  - the service token lives only in Pages secrets;
  - the pages send no data to any third party;
  - Cloudflare sees visitors' addresses and requests to public pages and to the public API, and the site's privacy note says so;
  - the API itself serves nothing about a single submission, as `dashboard-api` requires.
- **Trust:** the pages trust only the API's documented fields and render them as text, as `dashboard-site` requires.
- **Determinism:** the site's build from a locked dependency tree is reproducible. Two builds of the same commit produce identical files.
- **Compatibility:** the site pins an exact `pool-elements` version. The API's version 1 contract is additive, so a newer coordinator does not break an older site.
- **Performance and resources:**
  - `/` stays under 250 KB gzipped, fonts included;
  - `/testnet/` stays within the dashboard's 150 KB budget, fonts excluded;
  - everything runs on the Cloudflare free plan.
- **Failure behaviour:** the tunnel, the coordinator or the relay being down leaves every page loading and says so. The route never hangs a non-event request longer than 10 s.

#### Scenario: A path that escapes the route
- **WHEN** a client asks `/api/testnet/..%2F..%2Fadmin` or `/api/testnet/%2e%2e/x`
- **THEN** the first gets 400 from the route. The runtime resolves the second's dot segments before routing, out of `/api/testnet/`, so it gets the API's JSON 404. No request reaches the tunnel.

#### Scenario: Unknown paths
- **WHEN** a client asks `/api/.env` or `/no-such-page`
- **THEN** the first gets the API's JSON 404, and the second gets the site's 404 page with status 404, never the landing page

#### Scenario: Reproducible build
- **WHEN** the site is built twice from the same commit with `npm ci`
- **THEN** the two output directories are byte-identical

#### Scenario: The origin hangs
- **WHEN** the coordinator accepts a connection for `/api/pool` and never answers
- **THEN** the client gets 502 within 10 s
