## Why

The coordinator installs today only the way a developer runs it: check out five sibling repositories, install the Dart SDK and Rust, build tstokenlib's native kernels, and `dart run` from the source tree, with the kernels found by walking up from the working directory. An operator who wants to run a pool on a Linux server or a Mac should be able to install a versioned release instead, the way go-ricochet's `.deb` is installed, and upgrade it in place. The install instructions that replace the developer ones come in the next change; this one makes the packages they will point at.

## What Changes

- **Versioned releases on GitHub.** Pushing a tag `vX.Y.Z` builds and publishes a GitHub release of `twostack/pool-coordinator` with:
  - `pool-coordinator_X.Y.Z_amd64.deb` and `pool-coordinator_X.Y.Z_arm64.deb`
  - `pool-coordinator-X.Y.Z-macos-arm64.tar.gz`
  - `SHA256SUMS`
  
  Each artifact is built on a native runner for its platform and smoke-tested before it is attached.
- **A self-contained binary.** The coordinator is compiled ahead of time (`dart compile exe`) and reports its version (`pool-coordinator --version`). A new `pool-coordinator check` reports what an installed copy can do: its version, the native kernels it loaded (and whether the Metal GPU path is available on a Mac), and the SQLite library the API would use. The smoke tests and an operator's first look run it.
- **The native kernels ship with it.** tstokenlib's `stark_kernels` library is built for each target (with the Metal feature on the Mac) and installed beside the binary. tstokenlib's loader gains one more place to look: beside the running executable, and in `../lib` from it. That is a small change in `../tstokenlib`, which today finds the library only from the working directory or its own source checkout.
- **The Debian package** follows go-ricochet's:
  - **Layout:** `/opt/pool-coordinator` holds the binary, kernels, a `run.sh` wrapper, the built web site and an example Caddyfile, with `/usr/bin/pool-coordinator` linked to it.
  - **Config and secrets:** `/etc/pool-coordinator/config.yaml` is copied from an example on first install, since `create` writes the genesis into it. `/etc/pool-coordinator/env` holds `POOL_WALLET_PASSPHRASE` and `POOL_RPC_PASSWORD`, root-owned, group-readable only by the service user, mode 640.
  - **Service:** a `pool-coordinator` system user owns `/var/lib/pool-coordinator` (wallet, identity, store, status, history) and `/var/log/pool-coordinator`, and a supervisor program runs it.
  - **Install and upgrade:** a first install leaves the service stopped, because the pool must be created first. An upgrade restarts it only if it was running. Purge removes the data.
  - **Dependencies:** `supervisor`, `libsqlite3-0` and `ca-certificates`; Caddy is suggested.
- **The macOS tarball** holds the same tree under `pool-coordinator-X.Y.Z/`:
  - `bin/pool-coordinator`
  - `lib/libstark_kernels.dylib`
  - `web/`, `config.example.yaml` and `Caddyfile`
  
  It is unsigned (a Homebrew tap is the next change).
- **Local builds** mirror the release:
  - `scripts/package-deb.sh` builds the `.deb` on Linux.
  - `build-deb.sh` runs it inside an Ubuntu 22.04 container from a Mac, as go-ricochet's does.
  - `scripts/package-macos.sh` builds the tarball on a Mac.
- **Dependencies from GitHub, not the disk.** `pubspec.yaml` names tstokenlib and ricochet-dart-client as git dependencies pinned to a commit, and pins ricochet-dart-client's two absolute-path dependencies (dart-libp2p-merkle-crdt and merkledag) as git overrides. Development keeps its sibling checkouts through a gitignored `pubspec_overrides.yaml`, which Dart applies on top. `pubspec.lock` is committed, as an application's should be, so every release resolves the same versions.
- **SQLite by its runtime name.** On Linux the coordinator opens `libsqlite3.so.0`, which the runtime package provides, rather than the bare `libsqlite3.so`, which only the `-dev` package does. It does so in the server's isolate and in the API's isolate. Without this, an installed coordinator would turn its API off at start.

Numbers held:
- **Measured on this Mac:** the compiled binary is 14 MB and compiles in 7 s.
- **Bound on a package's size:** a package is under 40 MB. A task measures it, and the spec makes it a requirement, because operators download it.
- **The existing bounds are unchanged:** the 60 s start bound and the 2 s submission reply are unchanged by packaging. The smoke test checks that an installed coordinator starts and answers `check`.

Non-functional contract:
- **Untrusted input:** the packages read nothing from the network at install. Downloads are checked against `SHA256SUMS`.
- **Secrets and privacy:** secrets live only in the 640 env file, and reach the process through the environment, never argv or logs. Package scripts never print or copy them. Purge deletes them.
- **Trust:** the macOS tarball is unsigned. Checksums and the GitHub release are the provenance until signing is taken on.
- **Determinism:** the dependencies and toolchains are pinned and the lockfile is committed, so a tag rebuilds the same dependency set.
- **Compatibility:**
  - Ubuntu 22.04 and later, and Debian 12, on amd64 and arm64.
  - macOS 14 and later on Apple Silicon.
  - An existing configuration and data directory keep working, and an upgrade keeps both.
- **Performance and resources:** a package is under 40 MB, and the service runs as an unprivileged user.
- **Failure:** a missing or mismatched kernel library, or a missing SQLite, is reported by name by `check` and at start. A failed build or smoke test publishes nothing.

## Capabilities

### New Capabilities
- `release-packages`: what a release is and what an installed copy guarantees: the artifacts and their names, versions, checksums, the installed layout, the service's user, secrets and lifecycle across install, upgrade and purge, the bundled kernels and SQLite, the `--version` and `check` commands, and the platforms supported.

### Modified Capabilities
None in `openspec/specs/`, which is still empty. `server-process` in the unarchived `coordinator-server` change covers running from a source tree; this adds an installed way to run it without changing its requirements.

tstokenlib specs this builds on: `native-kernels` (the kernels' ABI check and the byte-identity of native and Dart kernels, which is what makes shipping a prebuilt library safe). What this repo adds that the library leaves to its users: building and shipping that library for each platform, and finding it beside an installed binary.

## Impact

- **Code:**
  - `bin/pool_coordinator.dart` (`--version`, `check`, kernel and SQLite setup).
  - `lib/src/api/api_host.dart` and the history (the SQLite library name).
  - `pubspec.yaml` and `pubspec.lock`, `.gitignore`.
- **Packaging, new:**
  - `deploy/debian/`: control, postinst, prerm, postrm, the supervisor program, `run.sh`, the config and env examples.
  - `scripts/package-deb.sh`, `scripts/package-macos.sh`.
  - `build-deb.sh`, `docker-build.sh`, `Dockerfile.build`, `docker-compose.build.yml`.
  - `.github/workflows/release.yml`.
- **tstokenlib:** the kernel loader looks beside the executable (`lib/src/crypto/stark_kernels.dart`), with a test.
- **CI:** GitHub Actions runners `ubuntu-22.04`, `ubuntu-22.04-arm` and `macos-14`, with Dart 3.11, Rust 1.84 and Node 20 pinned.
- **Out of scope:** the Mac and Linux install instructions, and a Homebrew tap (the next change); signing and notarization; Intel Macs.
