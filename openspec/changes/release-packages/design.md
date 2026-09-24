## Context

The coordinator runs today from a source tree: `dart run bin/pool_coordinator.dart`, with tstokenlib and ricochet-dart-client as relative path dependencies. ricochet-dart-client itself names dart-libp2p-merkle-crdt and merkledag by absolute paths on the developer's Mac. The native kernels are a Rust `cdylib` in `tstokenlib/native/stark_kernels`. The loader looks for them in this order:
- a path it is given;
- `$STARK_KERNELS_LIB`;
- `native/stark_kernels/target/release/` under the working directory and three of its parents;
- tstokenlib's own checkout.

It caches only a search it made itself. The server refuses to start without them. The history uses the `sqlite3` package (2.9.4), which on Linux opens the bare `libsqlite3.so`.

go-ricochet's committed `.deb` is the model: an Ubuntu 22.04 Docker build environment, a package with `/opt/ricochet`, `/etc/ricochet/{config.yaml,env}`, a system user, a supervisor program, and postinst/prerm/postrm that leave a first install stopped and restart an upgrade only if it was running. Its uncommitted rework moves toward a shared `scripts/package-deb.sh` and a tag-driven release workflow for amd64 and arm64, which this follows.

Measured here: `dart compile exe bin/pool_coordinator.dart` builds a 14 MB binary in 7 s on the M3 Pro. No dependency has a build hook, so nothing stops an AOT build. All five repositories are public on GitHub.

## Goals / Non-Goals

**Goals:** one tag builds, tests and publishes every artifact; an installed copy needs no toolchain; the Debian package operates like ricochet's; development keeps its sibling checkouts.

**Non-Goals:**
- Cross-compiling. Each artifact is built on its own platform, since the kernels are native code.
- Signing, notarization, a Homebrew formula, apt repository hosting and install documentation. That is the next change.
- Windows and Intel Macs.

## Decisions

### D1. Dependencies from pub.dev, sibling checkouts through `pubspec_overrides.yaml`
`pubspec.yaml` names tstokenlib `^2.0.1` and ricochet `^0.1.0` from pub.dev. The first plan pinned both as git commits; by the time task 2.1 needed a tstokenlib release, tstokenlib 2.0.0 (the shielded pool) was on pub.dev, so the loader change went out as 2.0.1 and nothing comes from git.

A gitignored `pubspec_overrides.yaml` (copied from `pubspec_overrides.yaml.example`) points both at the sibling checkouts for development. Dart applies it on top of `pubspec.yaml` without flags. `pubspec.lock` is committed, removing it from `.gitignore`, as Dart advises for an application, so a tag rebuilds the same versions.

Alternatives:
- **Keep the path dependencies and build locally:** chosen against by the user, since nothing could be built by CI.
- **Git submodules:** heavier for development, and they solve nothing a pinned ref does not.
- **ricochet and its two merkle packages as git dependencies with root overrides:** the first plan. It failed (below).

Found in task 1.1 (2026-09-24): pub rejects an absolute path in any pubspec it fetches from git, even for a dependency the root overrides ("is an absolute path, it can't be referenced from a git pubspec"). The pushed merkledag named `dart_cid`, dart-libp2p-merkle-crdt named merkledag, and ricochet-dart-client named both by absolute paths on one machine. With the user's approval each moved to hosted dependencies and was published: merkledag 1.0.1 (tag v1.0.1), dart_libp2p_merkle_crdt 1.0.0 (v1.0.0) and ricochet 0.1.0 (v0.1.0). The root then needs no overrides.

The release build finds the kernel crate in the pub.dev package (`native/stark_kernels` ships as source; its `target/` does not) through `.dart_tool/package_config.json`, and builds it with `--target-dir` outside the pub cache.

With a `pubspec_overrides.yaml` present, `dart pub get` writes path sources into `pubspec.lock`. The committed lock is therefore the one resolved without the file, and the release build runs `dart pub get --enforce-lockfile`, so a path-resolved lock committed by mistake fails the build instead of being silently re-resolved.

### D2. The kernels beside the executable, found by tstokenlib
tstokenlib's loader gains two candidates after `$STARK_KERNELS_LIB`: the executable's own directory, and `../lib` from it, from `Platform.resolvedExecutable`. It applies to any program built on tstokenlib, cloak included, and keeps the no-path search that the prover's `ProverKernels.best` uses.

Alternatives:
- **A wrapper script that sets `STARK_KERNELS_LIB`:** it breaks when the binary is run directly or linked, and every tool built on tstokenlib would need its own.
- **The coordinator passing an explicit path:** the explicit path is not cached, so the prover's own search would still miss it.

A binary run under `dart run` in development has the Dart VM as its executable, so the new candidates find nothing there and the existing ones still apply.

### D3. SQLite by its runtime name, wherever the history is opened
Before any history is opened, the coordinator tells the `sqlite3` package to open `libsqlite3.so.0` on Linux, falling back to the bare name for a system that only has that. Each isolate has its own copy of the package's state, so the override is made in `MetricsHistory.open` and `attach` themselves (`useRuntimeSqlite`, idempotent per isolate) rather than at the top of the server's and the API's isolates: any isolate that opens the history sets it first, including one added later. The loader records which library it opened, which `check` reports. A test opens the history in one isolate and attaches in a fresh one, and checks both loaded the runtime library.

### D4. `--version` from the build, `check` for the install
The version is compiled in (`dart compile exe -DPOOL_VERSION=X.Y.Z`, read with `String.fromEnvironment`, default `dev`). `check` loads the kernels and SQLite the way `run` does, prints what it found, and exits 0 only when both load. It needs no configuration, so the smoke tests and an operator can run it right after installing.

### D5. The Debian package
The layout and scripts follow ricochet's, with these differences:
- **The configuration is not a conffile.** `create` writes the genesis into it, and dpkg would then ask about it on every upgrade. The package ships `config.example.yaml` with the installed paths (`/var/lib/pool-coordinator/...`), and postinst copies it to `config.yaml` when none exists. It is owned by the service user so `create` can write it.
- **`run.sh` reads the env file** (`POOL_WALLET_PASSPHRASE`, `POOL_RPC_PASSWORD`, exported, never on argv) and execs `/opt/pool-coordinator/bin/pool-coordinator -c /etc/pool-coordinator/config.yaml <run|create>`. `create` needs the same secrets (it encrypts the new wallet), so it goes through the same wrapper rather than the operator exporting them in a shell.
- **The supervisor program has `autostart=false`.** A first install is stopped until the operator has created the pool. It then runs `create` as the service user (`sudo -u pool-coordinator /opt/pool-coordinator/run.sh create`) and starts it.
- **`Depends: supervisor, libsqlite3-0, ca-certificates`; `Suggests: caddy`.** The web site and the example Caddyfile ship under `/opt/pool-coordinator/web` and `/opt/pool-coordinator/share/Caddyfile`. The proxy's rate-limit build stays the operator's step, as in `deploy/README.md`.
- **The layout:** `/opt/pool-coordinator/bin/pool-coordinator`, `/opt/pool-coordinator/lib/libstark_kernels.so` (found as `../lib` from the binary, D2), `/opt/pool-coordinator/run.sh`, `/opt/pool-coordinator/web/`, and `/opt/pool-coordinator/share/{Caddyfile,config.example.yaml,env.example}`; `/usr/bin/pool-coordinator` links to the binary (`Platform.resolvedExecutable` resolves the link, so the kernels are still found). The supervisor program is `/etc/supervisor/conf.d/pool-coordinator.conf`, the only conffile.
- **`/etc/pool-coordinator` is `root:pool-coordinator`, mode 1770.** Found in task 3.1: `create` writes the genesis by writing `config.yaml.tmp` and renaming it, so the service must be able to write the directory. The sticky bit keeps that to its own files: it can replace `config.yaml`, which it owns, but cannot rename over or delete the root-owned `env`.
- **Purge deletes the wallet.** The spec's purge removes the data directory, which holds the pool's owner key and coins. postinst's first-install message says to back up `wallet.enc` and the passphrase.
- **The same `scripts/package-deb.sh` builds it** on a Linux runner and inside the Docker environment (`build-deb.sh` on a Mac).

### D6. The macOS tarball
`scripts/package-macos.sh` builds `pool-coordinator-X.Y.Z/`, holding `bin/pool-coordinator`, `lib/libstark_kernels.dylib` (built with `--features metal`), `web/`, `config.example.yaml` and `Caddyfile`, and packs it as `pool-coordinator-X.Y.Z-macos-arm64.tar.gz`.

It is unsigned. A file fetched by `curl` or Homebrew carries no quarantine attribute, and one fetched by a browser needs `xattr -d com.apple.quarantine`, which the next change's instructions give.

### D7. One workflow, native runners
`.github/workflows/release.yml` runs on `v*` tags:
1. **Check** that the tag matches `pubspec.yaml`.
2. **Build the web site once** on Node 20, as an artifact every package takes.
3. **Build per platform:** `ubuntu-22.04` (amd64), `ubuntu-22.04-arm` (arm64) and `macos-14` (arm64), each with Dart 3.11.5 and Rust 1.84.0 pinned. Each job:
   - builds the kernels from the pinned tstokenlib (located through `.dart_tool/package_config.json`), before the suite, since the suite needs them: ML-KEM exists only in the native crate;
   - runs `dart analyze lib bin test` and `dart test` with `STARK_KERNELS_LIB` pointing at them (the suite skips localnet and the ricochet binary by itself);
   - runs tstokenlib's native byte-identity test against them;
   - compiles the binary and packages it;
   - smoke-tests it: installs the `.deb` with `apt` and runs `check`, or unpacks the tarball and runs `check` from elsewhere.
4. **Publish:** once every build passes, write `SHA256SUMS`, check each artifact is under 40 MB, and create the release with `gh`.

Ubuntu 22.04 is the build baseline, so its glibc (2.35) is the oldest the packages run on.

Alternatives:
- **Building everything in Docker with QEMU for arm64:** slow, and native arm64 runners are free for public repositories.
- **Cross-compiling Dart for Linux from the Mac:** the kernels would still need a Linux toolchain.

### Found in groups 3 and 4 (2026-09-24)
- **Measured locally:**

  | Artifact | Size | Notes |
  |---|---|---|
  | amd64 `.deb` | 4.8 MB | Binary 14.7 MB and kernels 0.8 MB, uncompressed |
  | macOS tarball | 5.9 MB | Metal build of the kernels |

  Both are far under the 40 MB bound, so no stripping is needed. The amd64 package builds in Docker under emulation on the M3 Pro, with the kernels in 22 s.
- **`tool/deb_e2e.sh`** runs group 4 in a clean Ubuntu 22.04 container against localnet: install, create, run, upgrade, remove and purge. It uses `tool/ricochet_up.dart` for a throwaway ricochet server on the host. Under emulation, a process's `/proc/<pid>/cmdline` begins with the emulator's path, so the harness finds the coordinator by its path anywhere in the command line.
- **The store directory appears with the pool's first round.** A pool at genesis has none, so the upgrade check compares what the data directory held before and after rather than naming the store.

## Risks / Trade-offs

- **A package over the 40 MB bound:** 14 MB of binary plus a kernel library of a few MB is well under it. If the measurement fails the bound, strip the binary's symbols (`strip`) and the library's (`lto` is already on) before raising the bound.
- **The pinned merkledag commit behaving differently from the local working copy:** task 1.1 runs the full suite against the pinned versions. If it fails, the fix lands in merkledag's repository and the pin moves; nothing is built on an unpushed tree.
- **GitHub's arm64 Linux runners change or become paid:** the Docker build takes `ARCHES=arm64` under QEMU as a slower fallback.
- **A macOS 14 build not running on older macOS:** stated as the floor. The Metal backend needs Apple Silicon anyway.
- **An operator editing `config.yaml` by hand and `create` rewriting it:** unchanged from today. `create` writes only the genesis section.

## Migration Plan

Nothing is migrated: an existing source-tree install keeps working. An operator moving to the package:
1. Copies their `config.yaml` into `/etc/pool-coordinator/`, with the paths changed to `/var/lib/pool-coordinator`.
2. Copies the wallet, identity and store directory into `/var/lib/pool-coordinator`, owned by the service user.
3. Puts the secrets in the env file.

The next change's instructions carry this. Rollback: remove the package; the data stays until a purge.
