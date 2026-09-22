# pool-coordinator

The TSL1_SP shielded pool coordinator server. It runs a pool from a `ShieldedCoordinator` (tstokenlib): drains a ricochet inbox of wallet submissions, answers each, closes and funds rounds, publishes them to the chain, and announces them on a ricochet feed.

The library, the protocol and the pool's specs live in `../tstokenlib`; this repo holds the server, its wallet, its chain access and its configuration. Changes are planned under `openspec/`.
