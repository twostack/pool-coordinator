## Purpose

The coordinator as a running process: how it starts, recovers, takes submissions from its inbox, closes and publishes rounds, announces them, snapshots, reports itself to an operator, and stops, and the configuration it runs from.

## Requirements

### Requirement: Start and recovery
On `run` the server SHALL rebuild the coordinator's ledger from its round store's last snapshot and the chain, through the library's recovery, and SHALL refuse to start, naming what disagreed, when the chain does not extend the store's last round; when the store is empty it SHALL open the pool from the configured genesis txids fetched from the chain. It SHALL be taking submissions within 60 s of start on a history of 1,000 rounds (the library's recovery of such a history measured 11.4 s).

#### Scenario: Restart after two rounds
- **WHEN** the server is stopped after publishing round 2 on localnet and started again
- **THEN** its ledger equals the one it stopped with, its status reports round 2 as the tip, and it accepts a new submission

#### Scenario: A stored round the chain does not show
- **WHEN** the store holds round 3 and the chain access reports round 3's txid as unknown
- **THEN** the server re-broadcasts round 3's three transactions in order, and starts only once the chain reports them mined; if the chain refuses one, it stops and names it

#### Scenario: Ready within the bound
- **WHEN** the server starts on a store whose snapshot holds 1,000 production rounds (the library's synthetic snapshot)
- **THEN** it reports ready within 60 s

### Requirement: Intake from the inbox
The server SHALL drain the submissions folder of its mailbox continuously, hand each payload to the library's intake as bytes, send the reply to the sender's mailbox, and mark the message delivered whether it was accepted, refused or dropped, so the mailbox never fills. A payload that is not a submission SHALL be marked delivered without a reply. A submission SHALL be answered within 2 s of its arrival at test parameters on localnet.

#### Scenario: A submission is answered
- **WHEN** a wallet sends a valid submission to the server's submissions folder
- **THEN** within 2 s its mailbox holds an accepted reply naming the round, and the server's pending count is one higher

#### Scenario: Garbage in the inbox
- **WHEN** a message whose payload is not a submission, or that carries no readable id, arrives in the folder
- **THEN** it is marked delivered, no reply is sent, and the next valid submission is answered as before

#### Scenario: The folder is not left to fill
- **WHEN** 1,100 messages are sent to the folder faster than they are answered
- **THEN** every one is eventually consumed and answered or dropped, since delivered messages leave the folder

### Requirement: A deposit is confirmed before it is accepted
Before a submission carrying a deposit transaction reaches the library's intake, the server SHALL ask the chain access whether that transaction is mined and its covenant output unspent, and SHALL refuse the submission, naming the reason, when it is not. The library then checks the covenant's terms.

#### Scenario: A covenant not yet mined
- **WHEN** a submission carries a deposit transaction the chain has not mined
- **THEN** the reply refuses it as a deposit whose covenant is not mined, and nothing is pending

### Requirement: Rounds, publishing and announcing
The server SHALL close rounds on the library's schedule (full or deadline), let the library fund, build, apply and store each round, publish the three transactions through the chain access in the order Y, round, witness, and append the round's announcement to the pool's feed within 5 s of the witness being broadcast. It SHALL NOT announce a round whose witness the chain access refused.

#### Scenario: Both rounds of the test chain through the server
- **WHEN** the fixture's round-1 transfers and deposit, then its round-2 transfers, are submitted through ricochet to a server on localnet
- **THEN** both rounds are mined, the feed holds two announcements after the descriptor, and a reader opened from the descriptor reaches the header the server's status reports

#### Scenario: A broadcast refused
- **WHEN** the chain access refuses the witness of a round
- **THEN** the round is not announced, the store still holds it, the failure is in the status, and the server keeps taking submissions

### Requirement: Configuration
The server SHALL run from one configuration file naming the plan (by name: `test` or `production`), the network, the chain access and its endpoints, the ricochet server address, the paths of the identity file, the wallet file and the store directory, the pool's genesis txids, the fee rate and floor, the round deadline, the padding stock and the deposit margin; SHALL refuse to start on a missing or unknown field, naming it; and SHALL take secrets (the wallet passphrase, an RPC password) from the environment or a file named in the configuration, never from the configuration itself.

#### Scenario: A field missing
- **WHEN** the configuration names no chain access
- **THEN** the server refuses to start and names the field

#### Scenario: Secrets not in the file
- **WHEN** the example configuration is read
- **THEN** it holds no key, seed, passphrase or password, only where each is found

### Requirement: Status and logs
The server SHALL write a status file after every change of state (tip round, pending count, in-flight, padding stock, wallet balance and rounds left, last failure, last announcement) and log each submission's outcome by id and reason, and SHALL write no key, seed, passphrase, transfer bytes or note anywhere.

#### Scenario: Status after a round
- **WHEN** a round is published
- **THEN** the status file names the round, its three txids and the wallet's balance after paying it

#### Scenario: Nothing secret in the output
- **WHEN** a server has run the two localnet rounds
- **THEN** its log and status contain no run of bytes equal to the owner key, the ricochet seed or any submitted transfer

### Requirement: Shutdown
On a stop signal the server SHALL finish the publish in progress, if any, take no further submissions, and exit; a round being proved SHALL be abandoned, its transfers being lost as `coordinator-service` (Restart) allows.

#### Scenario: Stop during a publish
- **WHEN** the server is stopped after the round is broadcast and before the witness is
- **THEN** the witness is broadcast before exit, or the store holds it for the next start to re-broadcast

### Requirement: Untrusted inbox
The server SHALL treat every inbox message as hostile: the sender's peer id is anyone's to mint, so it SHALL rely on nothing but the library's checks, SHALL bound the time it spends per message by the library's intake bound plus one deposit lookup, and SHALL keep serving after any message.

#### Scenario: Mutated submissions through the inbox
- **WHEN** 1,000 single-byte mutations of a valid submission are sent to the folder
- **THEN** each is answered or dropped, the server's pending round holds only the accepted ones, and the server is still answering afterwards
