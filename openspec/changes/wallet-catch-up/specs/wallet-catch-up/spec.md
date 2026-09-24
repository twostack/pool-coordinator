## Purpose

What the coordinator answers a wallet beyond submission replies, so a wallet can join a running pool, prove a payment it made, and take on its change and deposits: catch-up answers at the last mined round, refusals, the mined-round notice, and where a round's witness sits in a block.

## ADDED Requirements

### Requirement: Catch-up requests are answered or refused
The server SHALL answer every catch-up request it can decode: block roots over a published range, the frontier, the head, or a mined round by number. It SHALL answer through tstokenlib's responder, echoing the request's id, or with a refusal naming why. A request that does not decode SHALL be dropped, since it has no id to answer. A message that is neither a submission nor a catch-up request SHALL be dropped as before.

#### Scenario: Refused before round 1 is mined
- **WHEN** a fresh server is asked for the head, the frontier and block roots 1 to 1,024
- **THEN** each is refused as not yet mined, echoing its id

#### Scenario: Answered once round 1 is mined
- **WHEN** round 1 of the test chain is published and mined, and the head, the frontier and block roots 1 to 1,024 are asked for
- **THEN** the head carries round 1 and its witness as stored, and its branch reaches the merkle root of the fake chain's block holding the witness; the frontier stands at round 1 with round 1's announced block root; the roots are round 1's; and a request for rounds 2 to 1,025 is refused as unpublished

### Requirement: Answers stand at the last mined round
The server SHALL answer only at or below the last round whose witness it has seen mined, never at a round published and not yet mined. It SHALL find that round at start from the store and the chain. A restarted server SHALL answer at the round it finds.

#### Scenario: Published, not mined
- **WHEN** round 1 is published on a chain that does not mine it, and the head and the frontier are asked for
- **THEN** both are refused as not yet mined; once a block mines it, the head carries round 1

#### Scenario: After a restart
- **WHEN** a server that saw round 1 mined is restarted on its store
- **THEN** its status names round 1 as the mined tip and the head carries round 1

### Requirement: A submitter is sent its mined round
When a round is mined, the server SHALL send each peer whose accepted submissions it took in one mined-round notice naming exactly that peer's submission ids, and SHALL send it to no one else. A notice SHALL go to the peer's notices folder (`pool/notices`), never its replies folder, which holds only answers to what the peer sent: a wallet waiting on an answer takes whatever the replies folder holds next as that answer. A submission the library expires SHALL be removed from the notice. After a restart the record is gone and a wallet asks for its round by number.

#### Scenario: Each submitter its own ids
- **WHEN** four peers each submit one transfer of round 1 and the round is mined
- **THEN** each peer is sent one notice for round 1, to its notices folder, naming only its own submission id and the stored round's and witness's txids, with a branch that reaches the block's merkle root and no transactions (under 4,096 bytes); its replies folder holds only its acceptance

#### Scenario: A round by number later
- **WHEN** rounds 1 and 2 are mined and a peer that submitted nothing asks for round 1, then round 3
- **THEN** round 1 is answered with its stored witness, and its leaves read from the answer alone reach round 1's announced block root; round 3 is refused as not yet mined

### Requirement: Nothing unasked goes to the replies folder
A peer's replies folder SHALL hold only answers to what the peer sent, one per submission or catch-up request. Anything the server sends unasked SHALL go to the peer's notices folder: the mined-round notice, and the expired reply the library gives for a transfer accepted earlier and dropped at close, which is a second message for a submission already answered.

#### Scenario: An expiry
- **WHEN** a peer's submission is accepted and the library then expires it
- **THEN** the expired reply goes to the peer's notices folder, and its replies folder holds only the acceptance

### Requirement: Catch-up never delays a submission
Catch-up requests SHALL wait in a queue apart from the inbox, answered one at a time, holding at most 64. A request past the bound SHALL be dropped and counted. A submission's reply SHALL still be sent within the 2 s bound while catch-up requests are queued.

#### Scenario: A flood
- **WHEN** 300 round requests and one unreadable request arrive from one peer whose replies take 20 ms each to send, followed by a submission
- **THEN** the submission is answered within 2 s, fewer than 300 requests are answered and at least 64 are, and the rest are counted as dropped

### Requirement: Where a mined transaction sits
The chain access SHALL give a mined transaction's block hash, its index in the block and its merkle branch, or nothing when it is not mined. A proof whose nodes are not hashes, or that names another transaction or block, SHALL be a named chain error. The node's `*` (the working hash itself) SHALL be resolved into a plain hash.

#### Scenario: Branches from the node
- **WHEN** on localnet the submitter's notices for rounds 1 and 2, the head and round 1 by number are received over ricochet
- **THEN** each branch computes the merkle root the node's `getblock` states for the block named

### Requirement: The operator sees catch-up
The status file SHALL carry the last mined round and counts of catch-up answers, refusals, drops and notices sent, and nothing per request.

#### Scenario: Counts after answers
- **WHEN** a server has refused four catch-up requests and answered three
- **THEN** its status counts four refused and three answered
