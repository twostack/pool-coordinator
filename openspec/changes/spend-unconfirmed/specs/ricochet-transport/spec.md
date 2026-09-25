## ADDED Requirements

### Requirement: Recovering the server's connection
The transport's host SHALL run no service that closes or dials connections on its own: no AutoNAT, no hole punching, no relay. When a stream to the ricochet server cannot be opened for any reason, the transport SHALL register the server's configured address with the host again and dial it, and SHALL then try the stream once more in the same call, so that one lost connection costs at most one call's retry and never outlasts the next call.

#### Scenario: The connection and the address both lost
- **WHEN** the connection to the server is closed and the server's address is gone from the host's peerstore, with a submission waiting in the folder
- **THEN** the next single drain returns that submission

#### Scenario: A send after the same loss
- **WHEN** the connection and the address are lost and a reply is then sent
- **THEN** the reply reaches the wallet's replies folder

#### Scenario: No dial-back service
- **WHEN** the transport has connected
- **THEN** its host runs no AutoNAT service
