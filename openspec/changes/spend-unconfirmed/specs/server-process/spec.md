## MODIFIED Requirements

### Requirement: Start and recovery
On `run` the server SHALL rebuild the coordinator's ledger from its round store's last snapshot and the chain, through the library's recovery, and SHALL refuse to start, naming what disagreed, when the chain does not extend the store's last round. When the store is empty, it SHALL open the pool from the configured genesis txids fetched from the chain.

The chain access may not yet report a stored round's transactions. In that case the server SHALL broadcast the round's funding transactions, then Y, the round and the witness, in that order. It SHALL start once the chain access has accepted each of them, without waiting for a block.

It SHALL be taking submissions within 60 s of start on a history of 1,000 rounds (the library's recovery of such a history measured 11.4 s).

#### Scenario: Restart after two rounds
- **WHEN** the server is stopped after publishing round 2 on localnet and started again
- **THEN** its ledger equals the one it stopped with, its status reports round 2 as the tip, and it accepts a new submission

#### Scenario: A stored round the chain does not show
- **WHEN** the store holds round 3, and the chain access reports round 3's transactions and their funding transactions as unknown
- **THEN** the server broadcasts the funding transactions, then round 3's three transactions, in that order, and starts once each is accepted; if the chain refuses one, it stops and names it

#### Scenario: Ready within the bound
- **WHEN** the server starts on a store whose snapshot holds 1,000 production rounds (the library's synthetic snapshot)
- **THEN** it reports ready within 60 s

## ADDED Requirements

### Requirement: A bound on unmined rounds
The server SHALL NOT fund or prove a closed round while the number of rounds it has published and the chain access has not reported mined is at the configured limit. The round's funding request waits, and the status names the limit as the reason. The round goes on to be funded and proved once an earlier round is mined. This keeps the pool's chain of unconfirmed transactions inside the ancestor limits of the chain it publishes to. Submissions are still taken and answered meanwhile.

#### Scenario: The limit holds a round
- **WHEN** the limit is 2, rounds 1 and 2 are published and unmined on the fake chain, and round 3 closes
- **THEN** no funding transaction is built for round 3 and nothing is proved, the status says it waits for a round to be mined, and round 3's funding starts within one mined-poll interval of round 1 being mined

### Requirement: Re-broadcast during a run
When a published round is still unmined after the configured number of blocks past its publication, the server SHALL broadcast its funding transactions, then Y, the round and the witness, again and in that order. It SHALL log each answer. The re-broadcast SHALL NOT stop the server. A refusal SHALL be recorded as the last failure, naming the round and the transaction.

#### Scenario: A round dropped from the mempool
- **WHEN** the fake chain drops round 1's transactions and their funding transactions after they are published, and three blocks pass
- **THEN** the server broadcasts all five again, the funding first, and round 1 is mined at the next block
