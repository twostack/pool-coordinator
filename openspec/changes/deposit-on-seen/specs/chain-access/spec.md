## MODIFIED Requirements

### Requirement: Broadcast is confirmed, not assumed
A broadcast SHALL be reported as accepted only when the chain access has the transaction's acceptance from the node, or ARC's status of seen-on-network or better. A response of stored, announced or any error SHALL be a refusal with the response's text. A refusal that says the chain already has the transaction SHALL be reported as accepted, and the report SHALL say whether the transaction is mined, so a caller can tell an unmined transaction from one whose outputs it must still check unspent.

#### Scenario: ARC without peers
- **WHEN** ARC answers STORED
- **THEN** the broadcast is reported refused with that status

#### Scenario: A transaction already mined
- **WHEN** a transaction the chain has mined is broadcast again, through ARC or the node
- **THEN** the broadcast is reported accepted and mined

#### Scenario: A transaction already in the mempool
- **WHEN** a transaction the node already holds unmined is broadcast again
- **THEN** the broadcast is reported accepted and not mined

## ADDED Requirements

### Requirement: A transaction's status by txid
The chain access SHALL report, for a txid, whether the network has seen it, has mined it, or does not know it, from ARC's transaction status on testnet and from the node on localnet, within the call bound of "Resources". A status that does not parse SHALL be an error naming the endpoint.

#### Scenario: After a broadcast that timed out
- **WHEN** a broadcast times out and the transaction reached the network
- **THEN** the status by its txid reports it seen

#### Scenario: A transaction never sent
- **WHEN** the status of a txid no one broadcast is asked
- **THEN** it reports the transaction unknown
