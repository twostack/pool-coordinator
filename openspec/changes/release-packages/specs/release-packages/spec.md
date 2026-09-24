## Purpose

What a release of the coordinator is and what an installed copy guarantees, so an operator can install, run, upgrade and remove a pool coordinator on Linux or a Mac without a Dart, Rust or Node toolchain or the source repositories.

## ADDED Requirements

### Requirement: A release is a tagged set of artifacts with checksums
A tag `vX.Y.Z` on the repository SHALL produce a GitHub release named for it, carrying exactly:
- `pool-coordinator_X.Y.Z_amd64.deb`
- `pool-coordinator_X.Y.Z_arm64.deb`
- `pool-coordinator-X.Y.Z-macos-arm64.tar.gz`
- `SHA256SUMS`, listing each artifact's SHA-256

The version in `pubspec.yaml` SHALL equal the tag's, or nothing SHALL be published. An artifact SHALL be attached only after it has been built on its own platform and has passed its smoke test. A failure in any build or test SHALL publish no release.

#### Scenario: A tag whose version disagrees
- **WHEN** the tag `v0.2.0` is pushed while `pubspec.yaml` says `0.1.0`
- **THEN** the release workflow fails before building, naming both versions, and no release is created

#### Scenario: Checksums match
- **WHEN** a release's artifacts are downloaded and checked with `sha256sum -c SHA256SUMS`
- **THEN** every artifact checks out

### Requirement: The installed program reports what it is and what it can do
An installed coordinator SHALL answer `pool-coordinator --version` with its release version. `pool-coordinator check` SHALL report, without a configuration:
- the version;
- the native kernel library it loaded, with its path and ABI version;
- on a Mac, whether the Metal GPU path is available;
- the SQLite library the API would use, with its version.

It SHALL exit non-zero, naming what is missing, when the kernels or SQLite cannot be loaded. A build from source that sets no version SHALL report `dev`.

#### Scenario: A healthy install
- **WHEN** `pool-coordinator check` runs on a fresh install of any release artifact
- **THEN** it exits 0 and names the bundled kernel library, its ABI version and the SQLite version

#### Scenario: Kernels missing
- **WHEN** the bundled kernel library is removed and `pool-coordinator check` runs
- **THEN** it exits non-zero naming the library it looked for and where, and `pool-coordinator run` refuses to start saying the same

### Requirement: The native kernels are bundled and found beside the binary
Each artifact SHALL carry the native kernel library built for its platform (the Mac's with its Metal GPU path), and the installed program SHALL find it without any environment variable. A library whose ABI version differs from the program's SHALL NOT be used. An explicit `STARK_KERNELS_LIB` SHALL still take precedence, so an operator can point at another build. Proofs made with the bundled library SHALL be byte-identical to the Dart kernels', as tstokenlib's `native-kernels` spec requires of any build.

#### Scenario: Found with no environment
- **WHEN** the installed program runs from any working directory with `STARK_KERNELS_LIB` unset
- **THEN** `check` reports the bundled library, and the proof byte-identity test of tstokenlib's native kernels passes against it on that platform in the release build

### Requirement: SQLite from the system's runtime package
On Linux the program SHALL use the SQLite runtime library the distribution's runtime package installs, `libsqlite3.so.0`, in every part that opens the history, with no development package installed. The Debian package SHALL depend on that runtime package.

#### Scenario: No development package
- **WHEN** the `.deb` is installed on a system without `libsqlite3-dev` and the coordinator runs with `api:` enabled
- **THEN** the API starts and serves `/api/pool`, and the log names no SQLite failure

### Requirement: The Debian package's layout and service
The `.deb` SHALL install:
- the program, its kernels, a start wrapper, the built web site and an example proxy configuration under `/opt/pool-coordinator`, with `pool-coordinator` on the path;
- a `pool-coordinator` system user without a login shell, which owns `/var/lib/pool-coordinator` (the pool's wallet, identity, store, status and history) and `/var/log/pool-coordinator`;
- a supervisor program that runs the coordinator as that user with `/etc/pool-coordinator/config.yaml`.

The package SHALL depend on `supervisor`, `libsqlite3-0` and `ca-certificates`, and SHALL NOT start the service on first install, since a pool must be created first.

#### Scenario: A first install
- **WHEN** the `.deb` is installed on a clean Ubuntu 22.04
- **THEN** the files, user and directories above exist with their owners, `pool-coordinator check` exits 0, the supervisor program exists and is stopped, and the installer prints the next steps (configure, set the secrets, create the pool, start)

### Requirement: Secrets stay in one file, readable only by the service
The wallet passphrase and the RPC password SHALL be read from `/etc/pool-coordinator/env`, created on first install owned by root and the service's group with mode 640, and re-tightened to that on every upgrade. They SHALL reach the program only through its environment, never its command line, a log, the status file or anything the package scripts print. A purge SHALL delete the file.

#### Scenario: Not on the command line
- **WHEN** the service is running and every local user's view of its command line (`/proc/<pid>/cmdline`) and its log are read
- **THEN** neither holds the passphrase or the RPC password set in the env file

### Requirement: Configuration the operator and `create` both edit
The package SHALL install an example configuration with the installed paths, and SHALL create `/etc/pool-coordinator/config.yaml` from it only when none exists. `create` writes the genesis into that file, so it SHALL be writable by the service user, and an upgrade SHALL never replace it or prompt about it.

#### Scenario: An upgrade keeps the pool
- **WHEN** a pool is created and run on version N, and version N+1 is installed over it
- **THEN** the configuration (with its genesis), the wallet, the identity, the store and the history are unchanged, and the pool starts at the round it stopped at

### Requirement: Upgrade and removal keep the service honest
An upgrade SHALL stop the running service before replacing its files and SHALL start the new version only if the old one was running. Removing the package SHALL stop the service and keep the data and configuration. A purge SHALL also remove the user, the data directory, the logs, the configuration and the env file.

#### Scenario: Upgrading a running service
- **WHEN** version N+1 is installed while version N is running
- **THEN** version N+1 is running afterwards and `--version` says N+1

#### Scenario: Upgrading a stopped service
- **WHEN** version N+1 is installed while the service is stopped
- **THEN** it is still stopped afterwards

### Requirement: The macOS tarball runs where it is unpacked
The macOS artifact SHALL unpack to one directory named for its version, holding the program, the kernels, the web site, an example configuration and an example proxy configuration. The program SHALL run from that directory, or through a link to it, on macOS 14 or later on Apple Silicon, with no other installation.

#### Scenario: Unpack and check
- **WHEN** the tarball is unpacked on a macOS 14 runner and `pool-coordinator-X.Y.Z/bin/pool-coordinator check` runs from another directory
- **THEN** it exits 0, naming the bundled kernel library and reporting the Metal GPU path available

### Requirement: Artifacts stay small
Each release artifact SHALL be under 40 MB, since an operator downloads it to a server.

#### Scenario: Sizes of a release
- **WHEN** a release is built
- **THEN** each of the three artifacts is under 40 MB, and the workflow fails otherwise

### Requirement: A release builds from published sources only
A release SHALL build from sources anyone can fetch: every dependency pinned in the committed lockfile to a published version or a commit of a public repository, and every toolchain (Dart, Rust, Node) pinned to a version. It SHALL NOT depend on anything on a developer's disk.

#### Scenario: A clean checkout
- **WHEN** the repository is cloned alone on a runner with no sibling checkouts and the release build runs
- **THEN** it resolves every dependency from pub.dev or GitHub, passes `dart analyze` and the test suite, and builds the artifact
