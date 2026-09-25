## MODIFIED Requirements

### Requirement: Exact funding outputs
The wallet SHALL serve each of the library's requests for an output of at least a value from one ready coin in its store (`coin-pool`). It SHALL NOT wait for a block before handing an output over.
- **The round's request:** the coin is handed over itself. The round returns the surplus as change.
- **Y's and the witness's requests:** the wallet spends the coin into a transaction paying exactly the value to the owner's address at one output and the change at another, broadcasts it through the chain access, and hands the library that output once the broadcast is accepted.

A request SHALL fail, naming the balance, when no coin the wallet holds covers the value plus a funding transaction's fee at the configured rate.

#### Scenario: Three outputs a round
- **WHEN** a round is closed on the fake chain with ready coins
- **THEN** the library was handed exactly the values it asked for Y and the witness and a whole ready coin for the round; it was handed each within one second of asking, with no block mined meanwhile; and every funding transaction spends a mined coin

#### Scenario: Not enough coins
- **WHEN** the wallet's balance is below what Y needs
- **THEN** the library's funding request fails with the balance, the round is not proved, and the status says the wallet needs a top-up

#### Scenario: From close to announcement
- **WHEN** a round closes on localnet at test parameters with ready coins, and no block is mined until it is announced
- **THEN** the announcement is on the feed within the round's proof time plus 10 s

### Requirement: The change chain and top-ups
The wallet SHALL track its outputs as it spends them. At start and after every round it SHALL ask the chain access for the owner address's unspent outputs and take in any it does not know as pending coins. A pending coin becomes ready once it is mined (`coin-pool`). An operator therefore tops up by paying the address. The wallet SHALL re-offer an output the library asked for and did not spend (a round that failed after Y was funded), rather than leaving it stranded, whether or not that output is mined.

#### Scenario: A top-up is noticed
- **WHEN** an operator sends coins to the owner's address and the server starts
- **THEN** the balance reported includes them, as pending until they are mined and ready after

#### Scenario: A stranded output is reused
- **WHEN** a round fails after Y was funded
- **THEN** the next round's Y is funded from that output, and no funding transaction is built for it

### Requirement: Budget
The wallet SHALL report its balance and how many rounds it can still pay for at the last round's cost. The server SHALL log a warning when that is below a configured number. A round's cost SHALL include its two funding fees, and each split's fee spread over the outputs that split made. The number reported SHALL be exact to within one round.

#### Scenario: Rounds left
- **WHEN** the wallet has run 20 rounds on localnet at test parameters through at least one split
- **THEN** the rounds-left figure reported before the 20 rounds, times the measured average cost, is within one round's cost of what the 20 rounds spent

### Requirement: Creating a pool
`create` SHALL:
1. generate the owner key and the ricochet identity, and write the wallet file;
2. wait for the operator to fund the address, and for that funding to be mined;
3. issue the pool (Y_0, the issuance, witness 0) through the library's tool, each funded from the mined funding without waiting for any genesis or funding transaction to be mined;
4. split the rest of the funding into the store;
5. write the genesis txids into the configuration and the descriptor onto the feed;
6. print the descriptor's peer id and txids.

From the operator's funding being mined to the descriptor on the feed SHALL take at most 30 s at test parameters.

#### Scenario: A pool from nothing on localnet
- **WHEN** `create` is run against localnet with the test plan and the address is funded and mined, and no further block is mined until it finishes
- **THEN** within 30 s the feed's first entry is the descriptor and the genesis and the split are in the node's mempool; once a block is mined, `run` opens the pool at round 0 with ready coins
