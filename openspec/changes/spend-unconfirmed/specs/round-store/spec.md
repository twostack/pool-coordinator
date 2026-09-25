## MODIFIED Requirements

### Requirement: Format and versioning
Each round's directory SHALL hold the raw transactions and the library's snapshot bytes, plus a small versioned record. The record holds the round number, the three txids and the txids of the funding transactions Y and the witness spend. The raw funding transactions SHALL be stored beside the round's, so they can be broadcast again before it. The store SHALL read the previous record version, whose rounds have no funding transactions, and SHALL refuse a record of an unknown version.

#### Scenario: Unknown version
- **WHEN** a round record's version byte is not one this server reads
- **THEN** the start refuses it, naming the round and the version

#### Scenario: A round stored before this change
- **WHEN** the server starts on a store whose last round has a record of the previous version
- **THEN** it starts, treating that round as having no funding transactions to re-broadcast

### Requirement: What start does with it
At start the server SHALL:
1. read the last round's record and snapshot;
2. restore the ledger from that snapshot (the library checks it against the header);
3. ask the chain access whether the round's transactions and its funding transactions are known, broadcast in order any that is not, and wait for each to be accepted;
4. read from the chain any round after it.

A store whose last round the chain contradicts SHALL stop the server, naming both.

#### Scenario: Snapshot restored
- **WHEN** the server starts on a store of two rounds
- **THEN** the ledger is at round 2 without reading round 1 or 2 from the chain

#### Scenario: The witness was never broadcast
- **WHEN** the store holds round 2 and the chain has Y_2 and round 2 but not witness 2
- **THEN** the server broadcasts witness 2, starts once it is accepted, and does not wait for it to be mined
