## Purpose

The coordinator's store of confirmed coins: split ahead of time from larger coins, kept above a floor and a low-water mark, so that no funding request waits for a block.

## ADDED Requirements

### Requirement: Ready coins
The wallet SHALL count a coin as ready when all of these hold:
- the chain access reports its transaction mined;
- it pays the owner's address;
- it holds at least the configured floor;
- it is not currently offered to the library.

Funding requests SHALL be served only from ready coins. Every other coin the wallet holds SHALL be pending: a split's outputs, a funding transaction's change, a round's change, or a top-up. A pending coin SHALL become ready at the first reconcile after the chain reports it mined. The status SHALL report the number and value of the ready coins and of the pending coins.

#### Scenario: A split's outputs mature
- **WHEN** a split is broadcast on the fake chain and then mined
- **THEN** its outputs are reported pending until the next reconcile after the mining, and ready from then on

#### Scenario: A coin below the floor
- **WHEN** a round's change of less than the floor is taken in and mined
- **THEN** it is never handed to the library, and it is counted in the balance

### Requirement: Splitting
When the ready coins plus the pending outputs of splits number fewer than the configured low-water mark, the wallet SHALL split a coin:
- It spends one or more mined coins into a single transaction of at most 100 outputs, all paying the owner's address, with no change output.
- The outputs' amounts follow Benford's law for the leading digit, drawn from a cryptographically secure random source, and none is below the floor.
- The fee is paid at the configured rate and floor.

It SHALL make enough outputs to bring the ready and pending coins up to the configured target. It SHALL NOT split a coin whose value cannot give two outputs at the floor, and it SHALL NOT split while a round is being funded. The split SHALL be recorded in the wallet file before it is broadcast.

#### Scenario: Low water refills the store
- **WHEN** the wallet holds one mined coin of 10,000,000 sat, with the target at 30, the low-water mark at 12 and the floor at 10,000 sat
- **THEN** one split of 30 outputs is broadcast, every output is at least 10,000 sat, the outputs and the fee sum to the coin's value, and there is no change output

#### Scenario: The leading digits follow Benford
- **WHEN** 1,000 split outputs are made in the test
- **THEN** the share of each leading digit from 1 to 9 is within 0.05 of log10(1 + 1/d)

#### Scenario: Nothing big enough to split
- **WHEN** no mined coin is at least twice the floor plus the split's fee
- **THEN** no split is built, and the status says the wallet needs a top-up

### Requirement: Serving a request from the store
For a request of at least a value, the wallet SHALL take the smallest ready coin that covers what the request needs:
- **The round's request:** the coin must cover the value. The coin itself is handed over.
- **Y's and the witness's requests:** the coin must cover the value plus a funding transaction's fee. The wallet spends that coin alone into a transaction paying exactly the value, with the change as a pending coin. It hands over that output once the chain access has accepted the broadcast, without waiting for a block.

It SHALL NOT combine coins for a request. When no ready coin covers the request, it SHALL wait for one, up to the funding timeout, logging what it waits for. This can happen after `create`, or after a top-up, while a split is unmined. A request larger than every coin the wallet holds SHALL fail at once, naming the value and the largest coin.

#### Scenario: A round funded from three coins
- **WHEN** a round is closed with 30 ready coins
- **THEN** the library is handed the round's own coin and two exact outputs, each from a funding transaction spending one ready coin, and no funding transaction spends an unmined output

#### Scenario: Waiting for the first split
- **WHEN** a round closes while every coin is pending
- **THEN** the request waits and logs it, and it is served within one mined-poll interval of the split being mined and reconciled

### Requirement: Non-functional contract
The coin pool SHALL meet the following contract.
- **Untrusted input:** the store reads only the chain access's answers about the owner's own address and txids, as the change chain did.
- **Secrets and privacy:**
  - Every coin in the store pays the owner's address, which the pool's genesis already makes public.
  - Split amounts come from a secure random source, so they do not reveal the pool's round sizes.
  - No log line or status field carries the owner key, and the wallet file stays encrypted as `coordinator-wallet` requires.
- **Trust:** a coin counts as ready on the chain access's word that it is mined, the same word recovery already relies on.
- **Determinism:** split amounts are random by design. Given the same store, the choice of coin for a request is deterministic.
- **Compatibility:** a wallet file of format 1 is read, its coins are classed by asking the chain access whether each is mined, and it is written back as format 2. A file of an unknown format is refused, naming it.
- **Performance and resources:**
  - A split's fee is at most the configured floor per 100 outputs at 1 sat/kB.
  - The store adds at most one record per coin to the wallet file.
- **Failure behaviour:**
  - A crash after a split is recorded and before it is broadcast leaves the split recorded and unbroadcast. The next start re-broadcasts it, or the top-up scan drops it if the chain shows its source spent elsewhere.
  - A refused split leaves the source coin ready.

#### Scenario: An old wallet file
- **WHEN** the server starts on a format 1 wallet file holding one mined coin and one unmined coin
- **THEN** it reports one ready coin and one pending coin, and the file on disk is format 2

#### Scenario: A split refused
- **WHEN** the chain access refuses a split
- **THEN** the source coin is still ready, the refusal is logged with the chain's reason, and the balance is unchanged

#### Scenario: A crash before the split's broadcast
- **WHEN** the process stops after the split is written to the wallet file and before it is broadcast, and is started again
- **THEN** the split is broadcast once, and its outputs are pending
