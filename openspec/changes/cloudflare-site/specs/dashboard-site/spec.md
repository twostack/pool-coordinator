## RENAMED Requirements

- FROM: `### Requirement: Served behind a colocated proxy`
- TO: `### Requirement: Served behind a proxy`

## MODIFIED Requirements

### Requirement: API data is text, never markup
Every string from the API SHALL be rendered as text. The page and the embeddable elements SHALL NOT evaluate or insert API content as HTML, script or style. Whichever proxy serves the page SHALL send a content security policy allowing scripts, styles, fonts and connections from the page's own origin only: the colocated proxy, or the edge site of `edge-site`.

#### Scenario: Markup in a field
- **WHEN** the fake API serves `<img src=x onerror=alert(1)>` as a network name and as a txid
- **THEN** it is shown as literal text and no element or script is created from it

#### Scenario: Markup through an embedded element
- **WHEN** a host page embeds `pool-live-card` and `pool-stats` fed by the fake API serving the same markup
- **THEN** it is shown as literal text in the host page too

### Requirement: Served behind a proxy
The site SHALL be static files served by a proxy that forwards only GET and HEAD under the API base to the coordinator's loopback port, rate limits the API per client address, keeps the event stream unbuffered, and allows caching of static files and of `/api/rounds` pages whose rounds are all mined. The coordinator's port SHALL NOT be reachable except through the proxy. Two proxies meet this:
- **Colocated:** Caddy on the coordinator's host, which terminates TLS and serves the files, with the API base `/api`.
- **Edge:** the edge site of `edge-site`, reaching the coordinator through a tunnel, with the API base `/api/testnet`.

#### Scenario: Proxy configuration checks
- **WHEN** the colocated proxy's validator is run on the shipped configuration
- **THEN** it accepts it, and the configuration forwards `/api/*` for GET and HEAD only, sets the content security policy, and rate limits `/api/`

#### Scenario: Through the proxy
- **WHEN** either proxy runs locally in front of a coordinator on the test chain
- **THEN** the page loads through it, receives live events, and a POST to the API's pool route is refused

## ADDED Requirements

### Requirement: Embeddable elements
The dashboard's elements SHALL be published, with each pool-coordinator release, as a versioned ES module package: `pool-live-card`, `pool-stats`, `pool-chart`, `pool-rounds`, `pool-dashboard`, and the feed that drives them.
- The feed SHALL take an API base path (default `/api`) and ask for every route under it.
- The elements SHALL take their colours, fonts, corner radius and card width from documented CSS custom properties, so a host page can theme them without reaching into their shadow roots. Padding and type sizes inside a card are the elements' own.
- The package SHALL make no request of its own beyond the API base, and SHALL work under a content security policy of the host's origin only.
- The single-page build SHALL stay within its 150 KB gzipped budget.

#### Scenario: A different API base
- **WHEN** a feed made with the base `/api/testnet` starts against the fake API
- **THEN** every request it makes, the event stream included, is under `/api/testnet/`

#### Scenario: Themed by the host
- **WHEN** a host page sets the documented properties to other colours and fonts and embeds `pool-stats`
- **THEN** the element's rendered colours, fonts and corner radius are the host's

#### Scenario: The package is the release's
- **WHEN** a release is built
- **THEN** it carries `pool-elements-X.Y.Z.tgz` with the release's version, and installing it in an empty project gives the five elements and the feed
