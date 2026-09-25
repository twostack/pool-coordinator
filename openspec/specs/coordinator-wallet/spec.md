## Purpose

The coordinator's own wallet: custody of the pool's owner key and the coins that pay for rounds, and the exact-value funding outputs the library asks for, with the change chain, top-ups and budget an operator relies on.

## Requirements

### Requirement: Keys and coins at rest
The wallet file SHALL hold the pool's owner key (which signs V, the anchors, the previous witness output and each witness's PP1, and is the funding key) and the wallet's unspent outputs, encrypted under a passphrase the operator supplies at start through the environment or a named file; the file SHALL be versioned, readable by the owner only, and SHALL never be written in the clear. Losing the owner key after a round is published freezes the pool, so the wallet SHALL print, on `create`, where the file is and that it must be backed up.

#### Scenario: Wrong passphrase
- **WHEN** the server starts with a passphrase that does not open the wallet file
- **THEN** it refuses to start and names the wallet file, not the key

#### Scenario: Nothing in the clear
- **WHEN** the wallet file's bytes are searched
- **THEN** they contain no run equal to the owner key, its public key or any outpoint

### Requirement: Exact funding outputs
On the library's request for an output of at least a value, the wallet SHALL spend its current change output into a transaction paying exactly that value to the owner's address at one output and the change at another, broadcast it through the chain access, wait until the chain access reports it mined, and hand the library that output; the request SHALL fail, naming the balance, when the wallet cannot cover the value plus the funding transaction's own fee at the configured rate.

#### Scenario: Three outputs a round
- **WHEN** a round is closed
- **THEN** the wallet built three funding transactions of exactly the values the library asked, each mined before the library spent it

#### Scenario: Not enough coins
- **WHEN** the wallet's balance is below what Y needs
- **THEN** the library's funding request fails with the balance, the round is not proved, and the status says the wallet needs a top-up

### Requirement: The change chain and top-ups
The wallet SHALL track its outputs as it spends them, and SHALL, at start and after every round, ask the chain access for the owner address's unspent outputs and take in any it does not know, so an operator tops up by paying the address. It SHALL re-offer an output the library asked for but did not spend (a round that failed after Y was funded), rather than leaving it stranded.

#### Scenario: A top-up is noticed
- **WHEN** an operator sends coins to the owner's address and the server starts
- **THEN** the balance reported includes them

#### Scenario: A stranded output is reused
- **WHEN** a round fails after Y was funded
- **THEN** the next round's Y is funded from that output, and no funding transaction is built for it

### Requirement: Budget
The wallet SHALL report its balance and how many rounds it can still pay for at the last round's cost (about 4,400 sat a production round at 1 sat/kB: Y 1,784, round 396, witness 2,205, measured in the library), and the server SHALL log a warning when that is below a configured number.

#### Scenario: Rounds left
- **WHEN** the wallet holds 100,000 sat after a production round that cost 4,400 sat
- **THEN** it reports about 22 rounds left, exact to within one round

### Requirement: Creating a pool
`create` SHALL generate the owner key and the ricochet identity, write the wallet file, wait for the operator to fund the address, then issue the pool (Y_0, the issuance, witness 0) from the wallet's coins through the library's tool, write the genesis txids into the configuration and the descriptor onto the feed, and print the descriptor's peer id and txids.

#### Scenario: A pool from nothing on localnet
- **WHEN** `create` is run against localnet with the test plan and the address is funded
- **THEN** the three genesis transactions are mined, the feed's first entry is the descriptor, and `run` opens the pool at round 0

### Requirement: Failure behaviour
A funding transaction refused by the chain SHALL leave the wallet's record unchanged and the request failed with the chain's reason; a crash between building a funding transaction and recording it SHALL be recovered by the top-up scan at the next start, which finds the output on the chain.

#### Scenario: Refused funding transaction
- **WHEN** the chain access refuses a funding transaction
- **THEN** the wallet's balance is what it was, and the library's request fails with the reason
