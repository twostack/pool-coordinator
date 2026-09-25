## Purpose

The on-disk record of every round the coordinator built: the three transactions and the ledger snapshot, written before the first publish so a crash never leaves a round mined without its witness, and read at start to recover.

## Requirements

### Requirement: Written before published
The store SHALL write round N's Y, round and witness transactions and the snapshot after them, under the round's number, before the server publishes any of them, as `pool-coordinator` (Publishing order) requires, and SHALL write each atomically (to a temporary name, then renamed), so a file is either whole or absent.

#### Scenario: Files before the first broadcast
- **WHEN** a round is closed on localnet
- **THEN** the round's four files exist before the chain access receives Y

#### Scenario: A file cut short
- **WHEN** a stored transaction file is truncated
- **THEN** the next start refuses it, naming the round and the file

### Requirement: Format and versioning
Each round's directory SHALL hold the raw transactions and the library's snapshot bytes, plus a small versioned record of the round number and the three txids; the store SHALL refuse a record of an unknown version.

#### Scenario: Unknown version
- **WHEN** a round record's version byte is not the one this server writes
- **THEN** the start refuses it, naming the round and the version

### Requirement: What start does with it
At start the server SHALL read the last round's record and snapshot, restore the ledger from that snapshot (the library checks it against the header), ask the chain access whether the round's three txids are mined, re-broadcast any that is not, and then read from the chain any round after it; a store whose last round the chain contradicts SHALL stop the server, naming both.

#### Scenario: Snapshot restored
- **WHEN** the server starts on a store of two rounds
- **THEN** the ledger is at round 2 without reading round 1 or 2 from the chain

#### Scenario: The witness was never broadcast
- **WHEN** the store holds round 2 and the chain has Y_2 and round 2 mined but not witness 2
- **THEN** the server broadcasts witness 2, waits for it to be mined, and then starts

### Requirement: Determinism
Two servers that built the same rounds SHALL write byte-identical transaction and snapshot files (the library's snapshot is canonical; the transactions are the ones broadcast).

#### Scenario: A copied store
- **WHEN** a store is copied to another machine and the server started there with the same wallet
- **THEN** it starts at the same round with the same ledger

### Requirement: Retention
The store SHALL keep every round; the snapshot of round N supersedes earlier ones for recovery, and the server MAY delete snapshots older than a configured count while keeping every transaction, since a reader may still ask for them.

#### Scenario: Old snapshots pruned
- **WHEN** the configured count is 2 and round 5 is stored
- **THEN** snapshots of rounds 1 to 3 are gone and every round's transactions remain
