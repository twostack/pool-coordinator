## REMOVED Requirements

### Requirement: A deposit is confirmed before it is accepted
**Reason**: A covenant no longer has to be mined before its round. The coordinator broadcasts it and admits it once the network has seen it.
**Migration**: Replaced by "A deposit is admitted once the network has seen it". A wallet that still broadcasts and waits for a block is admitted as before, since its covenant is already known.

## ADDED Requirements

### Requirement: A deposit is admitted once the network has seen it
A submission carrying a deposit transaction SHALL go through every check the library makes of a submission, the spend proof last, before the server broadcasts anything. When every check passes, the deposit SHALL hold its place in the round it targets while the server broadcasts the covenant transaction through the chain access. The server SHALL admit the deposit when the chain access reports the transaction seen by the network, already known, or mined. A covenant reported mined SHALL also be checked unspent, and SHALL be refused, naming the outpoint, when it is spent. When the broadcast is refused or the chain cannot be reached, the server SHALL refuse the deposit, naming the reason, and release its place. The server SHALL NOT broadcast the covenant of a submission refused by any check.

#### Scenario: An unmined covenant is admitted
- **WHEN** the fixture's deposit arrives with a covenant transaction the chain has not seen
- **THEN** the server broadcasts it, the reply accepts it into the round it targets, and the pending count is one higher

#### Scenario: A mined covenant, as an older wallet sends it
- **WHEN** the fixture's deposit arrives with a covenant transaction the chain has already mined, and its covenant output unspent
- **THEN** the reply accepts it

#### Scenario: A mined covenant already refunded
- **WHEN** the covenant transaction is mined and its covenant output is spent
- **THEN** the reply refuses it as a spent covenant, and nothing is pending

#### Scenario: A bad proof is never broadcast
- **WHEN** a deposit arrives whose spend proof does not verify
- **THEN** the reply refuses it for the proof, and the chain access received no broadcast

#### Scenario: The broadcast is refused
- **WHEN** the chain access refuses the covenant transaction
- **THEN** the reply refuses the deposit, naming the chain's reason, its place is released, and a later transfer can take the round's receipt slot

#### Scenario: The round cannot close without it
- **WHEN** a deposit is being broadcast and the round it targets reaches its deadline or fills
- **THEN** the round is built only once the broadcast has ended, with the deposit when it was admitted and with padding in its place when it was not

### Requirement: Deposit replies are bounded and do not hold up the inbox
A deposit SHALL be answered within 20 s of its arrival, whatever the chain access does; a broadcast still unresolved at that bound SHALL be settled by asking the chain access for the transaction's status before the deposit is refused. While a deposit is being broadcast, other submissions SHALL still be answered within the 2 s bound of "Intake from the inbox". The deposits held or admitted in one round SHALL NOT exceed the plan's receipt slots.

#### Scenario: A deposit and three transfers together
- **WHEN** a deposit and three transfers arrive in one drain on localnet, and the chain access takes 5 s to report the deposit seen
- **THEN** each transfer is answered within 2 s, and the deposit within 20 s

#### Scenario: A broadcast that does not answer
- **WHEN** the chain access does not answer the covenant's broadcast, and then reports the transaction unknown
- **THEN** the deposit is refused within 20 s and its place is released

#### Scenario: A broadcast that does not answer, but the network saw it
- **WHEN** the chain access does not answer the covenant's broadcast, and then reports the transaction seen
- **THEN** the deposit is admitted

#### Scenario: More deposits than receipt slots
- **WHEN** nine deposits for one round arrive while the first eight are still being broadcast
- **THEN** the ninth is refused for want of a receipt slot, and its covenant is not broadcast

### Requirement: The coordinator broadcasts on the depositor's behalf
The covenant transaction SHALL reach the chain from the coordinator, so the depositor's own network address is not sent to ARC or a node with its coins. The server SHALL NOT log or report a deposit's transaction beyond its txid, which the chain publishes.

#### Scenario: What the server records of a deposit
- **WHEN** a deposit is admitted
- **THEN** the log and the status name its covenant txid and nothing else of the transaction
