## Purpose

What the server needs from the chain, behind one interface with a localnet node implementation and a testnet implementation: fetch a transaction, read the height, broadcast, and learn whether a transaction is mined and an output unspent.

## ADDED Requirements

### Requirement: One interface, two chains
The chain access SHALL offer: fetch a transaction by txid (or report it unknown), the current height, broadcast a transaction (returning acceptance or the chain's refusal with its reason), whether a txid is mined and at what height, and whether an outpoint is unspent. The localnet implementation SHALL use the node's RPC; the testnet implementation SHALL use ARC for broadcast and WhatsOnChain for the rest. The server SHALL depend on the interface alone.

#### Scenario: The localnet node
- **WHEN** the server is configured for localnet
- **THEN** a broadcast is `sendrawtransaction`, a fetch is `getrawtransaction`, and the height is `getblockcount`

#### Scenario: Testnet
- **WHEN** the server is configured for testnet
- **THEN** a broadcast goes to the configured ARC endpoint and a fetch, the height and mined-ness to WhatsOnChain's testnet API

### Requirement: Broadcast is confirmed, not assumed
A broadcast SHALL be reported as accepted only when the chain access has the transaction's acceptance from the node or ARC's status of seen-on-network or better; a response of stored, announced or any error SHALL be a refusal with the response's text.

#### Scenario: ARC without peers
- **WHEN** ARC answers STORED
- **THEN** the broadcast is reported refused with that status

### Requirement: Size limits are known before sending
The chain access SHALL refuse, before sending, a transaction whose any scriptSig exceeds the configured ARC limit (1,636,802 bytes, ARC's parse limit measured on localnet), naming the input, when broadcasting through ARC; the node implementation has no such limit.

#### Scenario: A production witness through ARC
- **WHEN** a witness with a 1.9 MB unlock is given to the ARC implementation
- **THEN** it is refused before any request, naming the input and the limit

### Requirement: Outside input
Every response from the node, ARC or WhatsOnChain SHALL be treated as untrusted: a transaction fetched SHALL be parsed as `pool-ledger` parses one and its txid checked against the one asked for; a height or a status that does not parse SHALL be an error naming the endpoint, never a crash.

#### Scenario: A wrong transaction returned
- **WHEN** the endpoint returns bytes whose txid is not the one asked for
- **THEN** the fetch fails naming both txids

### Requirement: Resources
A fetch or a status call SHALL time out at a configured bound (default 30 s) and SHALL be retried a configured number of times on a network error before it is an error to the caller; the server never blocks on the chain without a bound.

#### Scenario: The endpoint is down
- **WHEN** the endpoint does not answer
- **THEN** the call fails after the configured retries and the timeout, with the endpoint named
