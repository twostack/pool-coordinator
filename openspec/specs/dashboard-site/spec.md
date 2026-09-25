## Purpose

The public landing page of the BSV Shielded Pool: rounds as they are mined, the round being worked on and its stage, and the pool's overall statistics, served as static files behind a colocated proxy that also fronts the coordinator's read-only API.

## Requirements

### Requirement: Rounds as a horizontal scroll
The page SHALL show recorded rounds as cards in a horizontal scroll, oldest to the left and newest to the right, each with its number, mined height (or "awaiting block"), published time, its three txids, its real transfer count out of capacity, and its proving time and cost when recorded. The scroll SHALL stay pinned to the newest card unless the viewer has scrolled away from it, and SHALL load older rounds as the viewer scrolls left until round 1.

#### Scenario: Two rounds render
- **WHEN** the page is rendered against a fake API holding rounds 1 and 2
- **THEN** two mined cards appear, round 2 to the right of round 1, each showing its three txids and its transfer count out of 4

#### Scenario: Paging left
- **WHEN** the fake API holds 60 rounds and the viewer scrolls to the left end
- **THEN** the page asks for the rounds before the oldest shown and prepends them without moving the cards in view

### Requirement: Live cards for the round being built and the round assembling
Right of the newest mined card the page SHALL show, when the live state names one, a card for the round being built with its number and the stages `assembling`, `proving`, `funding`, `broadcast`, `mined`, those passed marked done and the current one marked active; and a card for the next round, saying either that it is waiting for transfers, or that it is assembling and closes by the deadline the API serves, with a countdown. When a round is mined its live card SHALL become a mined card in place.

#### Scenario: A round moves through its stages
- **WHEN** the fake event stream sends live states for round 3 at `proving`, then `funding`, then `broadcast`, then a `round` event for round 3
- **THEN** round 3's card shows each stage active in turn and ends as a mined card at the right of the scroll

#### Scenario: No transfer counts while assembling
- **WHEN** a round is assembling
- **THEN** its card shows no count of pending transfers

### Requirement: Pool statistics
The page SHALL show tiles for rounds mined, lifetime transfers, median round interval, capacity, mean round cost, median proving time, the pool's balance, the pool's age, and the genesis with a link to it; and charts of rounds and transfers per bucket and the pool's balance over time, from `/api/series`.

#### Scenario: Tiles from the stats route
- **WHEN** the page is rendered against a fake API whose `/api/stats` names 2 rounds and 7 transfers
- **THEN** the tiles show 2 and 7, and a missing figure (no cost recorded yet) shows as a dash rather than zero

### Requirement: Live updates, reconnection and staleness
The page SHALL hold one event stream for all its widgets, reconnect when it drops, and refetch the rounds and stats it may have missed on reconnect. When no event or heartbeat has arrived for twice the publication interval plus 15 s, the page SHALL say its data is stale and when it was last updated.

#### Scenario: Stream drops and returns
- **WHEN** the fake event stream closes, round 4 is mined meanwhile, and the stream comes back
- **THEN** the page shows round 4 without a reload, and never shows two cards for one round

#### Scenario: Coordinator unreachable
- **WHEN** the fake API stops answering
- **THEN** within twice the publication interval plus 15 s the page shows a stale notice with the last update time, and keeps the cards it had

### Requirement: Every round is checkable on the chain
Each txid and the genesis SHALL link to WhatsOnChain for the pool's network (mainnet or testnet); on a network with no public explorer (regtest) the txids SHALL show without links. The link SHALL be built from the txid only after checking it is 64 hex characters.

#### Scenario: Testnet links
- **WHEN** the API names network `test` and the chain kind is testnet
- **THEN** every txid links to `https://test.whatsonchain.com/tx/<txid>`

#### Scenario: Malformed txid
- **WHEN** the fake API serves a txid that is not 64 hex characters
- **THEN** it is shown as text without a link

### Requirement: API data is text, never markup
Every string from the API SHALL be rendered as text; the page SHALL NOT evaluate or insert API content as HTML, script or style. The proxy SHALL send a content security policy allowing scripts, styles, fonts and connections from the page's own origin only.

#### Scenario: Markup in a field
- **WHEN** the fake API serves `<img src=x onerror=alert(1)>` as a network name and as a txid
- **THEN** it is shown as literal text and no element or script is created from it

### Requirement: Served behind a colocated proxy
The site SHALL be static files served by a reverse proxy on the coordinator's host, which SHALL terminate TLS, serve the files, forward only GET and HEAD under `/api/` to the coordinator's loopback port, rate limit `/api/` per client address, keep the event stream unbuffered, and allow caching of static files and of `/api/rounds` pages whose rounds are all mined. The coordinator's port SHALL NOT be reachable except through the proxy.

#### Scenario: Proxy configuration checks
- **WHEN** the proxy's validator is run on the shipped configuration
- **THEN** it accepts it, and the configuration forwards `/api/*` for GET and HEAD only, sets the content security policy, and rate limits `/api/`

#### Scenario: Through the proxy
- **WHEN** the proxy runs locally in front of a coordinator on the test chain
- **THEN** the page loads through it, receives live events, and a POST to `/api/pool` is refused

### Requirement: Usable on a phone and with reduced motion
The page SHALL lay out without horizontal page scroll (only the round scroll scrolls) at 360 px wide, SHALL be operable by keyboard (the round scroll focusable and scrolled by arrow keys), and SHALL not animate stage changes when the viewer prefers reduced motion.

#### Scenario: Narrow viewport
- **WHEN** the page is rendered at 360 px wide in the browser test
- **THEN** the document is no wider than the viewport and the round scroll scrolls on its own
