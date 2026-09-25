## ADDED Requirements

### Requirement: What wallets are told
The config MAY have an `api.wallet` section with `server` and, optionally, `peers` (at most 8, each `host:port`) and `arc_url`. The server SHALL refuse to start, naming the field, when:
- `server` is not a multiaddr of the form `/ip4|/ip6/<address>/udp/<port>/udx/p2p/<peer id>`;
- its peer id differs from the one in `ricochet.server`;
- a peer is not an IPv4 address or host name followed by `:` and a port from 1 to 65535, or there are more than 8;
- `arc_url` is not an `https` URL;
- the section is present while `api` is disabled.

#### Scenario: A server address for another relay
- **WHEN** `api.wallet.server` ends in a peer id that is not `ricochet.server`'s
- **THEN** the config is refused and the error names `api.wallet.server`

#### Scenario: A peer without a port
- **WHEN** `api.wallet.peers` holds `198.154.93.206`
- **THEN** the config is refused and the error names `api.wallet.peers`

#### Scenario: A name, not an address
- **WHEN** `api.wallet.server` begins `/dns4/`
- **THEN** the config is refused, saying that wallets dial only `/ip4` or `/ip6`
