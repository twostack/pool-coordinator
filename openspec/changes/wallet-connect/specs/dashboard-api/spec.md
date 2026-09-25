## MODIFIED Requirements

### Requirement: Read-only routes
The API SHALL answer GET and HEAD only; any other method SHALL get 405. It SHALL serve exactly these routes, each a JSON object carrying `"v": 1`:
- `/api/pool`: the network, the plan name, the capacity, the genesis txids, the tip round number, the pool's balance, the round deadline in seconds, the publication interval, the live state, and `wallet`: what a wallet needs to join the pool (the ricochet server's public multiaddr, the coordinator's peer id, the network under cloak's name, the chain peers as a list, and an ARC URL or null), or null when the operator has not named them.
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

#### Scenario: What a wallet needs
- **WHEN** the config's `api.wallet` names a server, two peers and an ARC URL, and a client asks `/api/pool`
- **THEN** `wallet.server`, `wallet.peers` and `wallet.arcUrl` are those values, `wallet.coordinator` is the coordinator's own peer id, and `wallet.network` is `testnet` for a test pool

#### Scenario: Not named
- **WHEN** the config has no `api.wallet` section
- **THEN** `/api/pool`'s `wallet` is null and every other field is as before
