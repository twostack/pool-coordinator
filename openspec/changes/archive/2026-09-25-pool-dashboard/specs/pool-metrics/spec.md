## Purpose

The coordinator's own history of the rounds it built and the live state of the round it is working on, kept so a public page can show the pool's progress without reading the chain or the feed itself, and without publishing anything a single submission reveals.

## ADDED Requirements

### Requirement: Every published round is recorded
When a round's witness has been broadcast and announced, the coordinator SHALL record that round in its history with: its number; the Y, round and witness txids; the number of real transfers it carries (those the ledger's reading of the round does not mark as padding); the plan's capacity; the pool's balance in the round's header; the round's cost to the wallet when the wallet reports one; the milliseconds from close to stored and the milliseconds of proving (the library's trees, aggregation and root unlock stages together); and the time it was published. The txids and header SHALL be those the store and the feed hold for that round.

#### Scenario: Two rounds of the test chain
- **WHEN** the server runs the two rounds of tstokenlib's test chain on the fakes with the API enabled
- **THEN** the history holds rounds 1 and 2, each with the three txids the store holds for it, a transfer count equal to the non-padding transfers the ledger reports for it, capacity 4, the balance of the header announced for it, and a proving time greater than zero

#### Scenario: A round that failed is not recorded
- **WHEN** a round's broadcast is refused by the chain
- **THEN** the history holds no row for that round number until a later start re-broadcasts and announces it, and then holds exactly one

### Requirement: Mined rounds are tracked
After recording a round, the coordinator SHALL ask the chain at the mined poll interval whether the round's witness is mined, and SHALL record the height once it is. A round whose witness is not mined within the funding timeout SHALL stay recorded as published but not mined, and SHALL be asked about again at the next start.

#### Scenario: Mined after publish
- **WHEN** the fake chain does not mine on broadcast, a round is published, and the test then mines a block
- **THEN** within two mined poll intervals the history names the height the fake chain reports for the witness

#### Scenario: Not yet mined at stop
- **WHEN** the server stops with a published round whose witness is not mined, and starts again after the chain mines it
- **THEN** the history names that round's mined height after the start

### Requirement: Live state names the round being worked on
The coordinator SHALL keep a live state holding: whether a round is assembling (pending transfers exist) and, if so, its deadline; and for the round being built, its number and its stage, one of `proving` (from close through the library's expiry, funding for Y, padding, trees, aggregation and root unlock), `funding` (Y through the witness, apply and store), and `broadcast` (from the first publish until the witness is mined). The stage SHALL be derived from what the library reports, polled no less often than the server's poll interval.

#### Scenario: Stages in order
- **WHEN** a round of the test chain is closed and built with the fakes
- **THEN** the live states observed for it go through `proving`, `funding` and `broadcast` in that order, never backwards, and it leaves the live state once the history names its mined height

#### Scenario: Assembling and idle
- **WHEN** one transfer is accepted into an empty pending round
- **THEN** the live state says a round is assembling with the deadline the library reports; and after that round closes with nothing else pending, it says none is

### Requirement: Nothing a single submission reveals is recorded
The history and the live state SHALL NOT hold submission ids, senders, per-submission times, the pending count, counts of submissions accepted, refused or dropped, the wallet's balance, coins or rounds left, failure texts, or any key or seed. Every per-round datum SHALL be one the chain or the feed already shows, or a duration of the coordinator's own work.

#### Scenario: Scan of the history after the server tests
- **WHEN** the two-round server test finishes with the API enabled
- **THEN** a scan of the database file and of every live state emitted finds no submission id, peer id of a sender, owner key, identity seed, or wallet balance from the run

### Requirement: The history is rebuilt from the store and the feed
At start, when the history is missing, of another version, or lacks rounds the store holds, the coordinator SHALL rebuild the missing rows from the stored transactions and the feed's announcements, and SHALL then fill mined heights from the chain. The rebuild SHALL run after the server is ready and SHALL NOT delay intake. Rows rebuilt this way SHALL carry no durations, cost or times, which the store does not hold; a time invented at the rebuild would place old rounds at the rebuild's hour.

#### Scenario: Database deleted between runs
- **WHEN** the server runs two rounds, stops, the history database is deleted, and the server starts again
- **THEN** the server is ready, and within 10 s the history holds rounds 1 and 2 with the same txids, transfer counts, balances and mined heights as before, and no durations, cost or times

#### Scenario: Same store, same history
- **WHEN** two rebuilds run from the same store, feed and chain
- **THEN** they produce identical rows

### Requirement: Recording never touches a round
A failure to write or read the history (a full disk, a locked or corrupt database) SHALL be logged and SHALL NOT fail, delay or reorder a round's publish, announcement, or any reply. Recording a round SHALL add under 5 ms to the publish path, measured at test parameters.

#### Scenario: Database locked
- **WHEN** another connection holds the history database's write lock while a round is published
- **THEN** the round is published and announced as without the API, the log names the history failure, and the next submission is still answered within 2 s

#### Scenario: Recording cost
- **WHEN** the recording probe records 1,000 rounds into a history of 1,000 rounds
- **THEN** the 95th percentile time to record one is under 5 ms
