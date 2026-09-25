## ADDED Requirements

### Requirement: Admitted covenants are stored with their round
The transactions stored beside a round for re-broadcast SHALL include the covenant transaction of every deposit the round takes in that was admitted unmined, ordered before the round transaction that spends it (a covenant already mined needs no broadcast again), so a start or a re-broadcast during a run sends a covenant the network dropped before the round that needs it. The record format SHALL NOT change for this: a covenant is stored as the funding transactions already are.

#### Scenario: A covenant the network dropped
- **WHEN** the store holds round 5, which took in a deposit, and the chain access reports the deposit's covenant unknown at start
- **THEN** the server broadcasts the covenant before round 5's round transaction, and starts once both are accepted

#### Scenario: A round with no deposit, or with a mined covenant
- **WHEN** a round takes in no deposit, or only deposits whose covenants were mined when admitted
- **THEN** its stored funding transactions are the wallet's alone, as before this change
