## Purpose

A read-only HTTP view of the pool's history and live state, served by the coordinator to a colocated proxy, so a public page can show the pool without any path back into the coordinator's intake, keys or wallet.

## ADDED Requirements

### Requirement: Off unless configured, and on loopback only
The API SHALL run only when the configuration has an `api:` section with `enabled: true`. It SHALL bind only to a loopback address (127.0.0.1 by default, or ::1); a configuration naming any other address SHALL be refused at load, naming the field. A configuration without an `api:` section SHALL load and run as before this change.

#### Scenario: Existing configuration
- **WHEN** `config.example.yaml` from before this change is loaded and the server runs its two test rounds
- **THEN** no port is opened and the server behaves as before

#### Scenario: Public bind refused
- **WHEN** a configuration sets `api.bind: 0.0.0.0`
- **THEN** loading it fails with an error naming `api.bind`

### Requirement: Read-only routes
The API SHALL answer GET and HEAD only; any other method SHALL get 405. It SHALL serve exactly these routes, each a JSON object carrying `"v": 1`:
- `/api/pool`: the network, the plan name, the capacity, the genesis txids, the tip round number, the pool's balance, the round deadline in seconds, the publication interval, and the live state.
- `/api/rounds?before=N&limit=L`: recorded rounds numbered below N (the newest when absent), newest first, at most L (default 20, at most 100), each with the fields `pool-metrics` records, and the number to ask for next.
- `/api/stats`: rounds mined, the lifetime real transfer total, the median interval between mined rounds and the median proving time over the last 50 rounds, the mean cost over the last 50 rounds that have one, the pool's age since its first round, and the tip.
- `/api/series?metric=M&bucket=B&from=T&to=T`: for M one of `rounds`, `transfers`, `balance`, `cost`, `proving`, and B one of `hour` or `day`, at most 1,000 points.
- `/api/events`: the event stream.
Any other path SHALL get 404 with a JSON error.

#### Scenario: Paging rounds
- **WHEN** the history holds rounds 1 and 2 and a client asks `/api/rounds?limit=1`, then `/api/rounds?before=2&limit=1`
- **THEN** the first answer holds round 2 and names 2 as the next `before`, the second holds round 1 and names none

#### Scenario: Writes refused
- **WHEN** a client sends POST, PUT, DELETE or PATCH to any route
- **THEN** the answer is 405 and nothing in the history or the server changes

### Requirement: Hostile requests are answered, bounded, and harmless
Every request the HTTP layer can parse SHALL end in a JSON answer; one it cannot parse (a request line that is not HTTP, a fragment or a space in the target) SHALL end in the layer's own plain 400 or a closed connection, never reaching a route. A query parameter that is not of its type or range SHALL get 400 naming the parameter; a request line over 2 KB SHALL get 414; a request body SHALL be ignored. No request SHALL read more than 100 rounds or return more than 1,000 series points.

#### Scenario: Mutated queries
- **WHEN** 10,000 random and mutated query strings and paths are sent to every route
- **THEN** every answer is 200, 400, 404, 405 or 414 with a JSON body, or the HTTP layer's plain 400 for a request line it cannot parse, the server keeps answering, and a submission sent during the run is answered within 2 s

### Requirement: Nothing private and no fine timing is served
The API SHALL serve only what `pool-metrics` records and the pool's public configuration (network, plan, capacity, genesis, deadline). Every time it serves (published, mined observation, the assembling round's deadline, the live state's stage change) SHALL be rounded to the publication interval (default 30 s, at least 10 s), with the deadline rounded up. The live state on the event stream SHALL change at most once per publication interval.

#### Scenario: Times are coarse
- **WHEN** the API runs with a 30 s publication interval on a fake clock and a round is closed, built and published at arbitrary seconds
- **THEN** every time in every response and event is a multiple of 30 s, and no two live events are less than 30 s apart

#### Scenario: Secrets scan
- **WHEN** every route is fetched during and after the two-round server test
- **THEN** no response holds an owner key, identity seed, wallet balance, submission id or sender peer id from the run

### Requirement: Live state as a server-sent event stream
`/api/events` SHALL send the current live state on connect, a `live` event when the live state changes (at most once per publication interval), a `round` event carrying the round's record when a round is mined, and a comment at least every 15 s. It SHALL hold at most the configured number of subscribers (default 200); one more SHALL get 503.

#### Scenario: A round mined reaches a subscriber
- **WHEN** a client is subscribed and a round of the test chain is mined
- **THEN** the client receives a `round` event naming that round within the publication interval plus 2 s, and a `live` event in which that round is no longer being built

#### Scenario: Subscriber cap
- **WHEN** the cap is 2 and a third client subscribes
- **THEN** the third gets 503 and the first two keep receiving events

### Requirement: The API never slows a round or a reply
The API SHALL serve from the history and the live state only, never from the chain, the store or the ledger on a request. With the API under 50 requests a second, a submission SHALL still be answered within 2 s. `/api/rounds` and `/api/stats` SHALL answer in under 50 ms at the 95th percentile over a 1,000-round history.

#### Scenario: Load while intake runs
- **WHEN** a client sends 50 requests a second across all routes while the two-round server test runs
- **THEN** every submission is answered within 2 s and both rounds publish

#### Scenario: Latency over a large history
- **WHEN** the API probe queries `/api/rounds` and `/api/stats` 1,000 times each over a history of 1,000 rounds
- **THEN** the 95th percentile of each is under 50 ms

### Requirement: Versioned responses
Every response SHALL carry `"v": 1`. Within version 1, fields SHALL only be added, never removed or changed in meaning; a change that removes or redefines a field SHALL bump the version.

#### Scenario: Version on every route
- **WHEN** every route is fetched
- **THEN** each JSON body has `"v": 1`
