## 1. Dependencies from GitHub

- [x] 1.1 Take tstokenlib and ricochet from pub.dev (first planned as git pins ; see D1 for why the merkle packages were published instead of overridden). Move the path dependencies into a gitignored `pubspec_overrides.yaml`, and commit `pubspec.lock` (remove it from `.gitignore`). Verify:
  - In a clean clone with no siblings (`git clone` into a scratch directory), `dart pub get --enforce-lockfile`, `dart analyze lib bin test` and `dart test` (with kernels built from the pinned tstokenlib) pass. If merkledag's pushed commit fails, stop and report rather than pinning an unpushed tree.
  - In the working tree, `dart pub get` still resolves them from the sibling checkouts.
- [x] 1.2 Add `pubspec_overrides.yaml.example` naming the sibling paths. Verify that copying it to `pubspec_overrides.yaml` restores the development setup.

## 2. The program

- [x] 2.1 tstokenlib (released as 2.0.1): add the executable's directory and `../lib` from it to the kernel loader's candidates, after `$STARK_KERNELS_LIB`. Verify with a test in `test/stark_kernels_test.dart`: a compiled test binary with the library copied beside it loads it with the variable unset, and the variable, when set, still wins.
- [x] 2.2 Open SQLite as `libsqlite3.so.0` on Linux, falling back to the bare name, in every isolate that opens the history (D3). Verify:
  - A test (`test/sqlite_library_test.dart`) checks the override is set in the isolate that opens the history and in a fresh one that attaches to it.
  - The smoke test in 4.2 serves `/api/pool` on a runner without `libsqlite3-dev`.
- [x] 2.3 Add `--version` (from `-DPOOL_VERSION`, default `dev`) and `check` (version, kernels path and ABI, Metal availability on a Mac, SQLite version; non-zero exit naming what is missing). Verify with tests in `test/cli_test.dart`:
  - `--version` of a `dev` build says `dev`.
  - `check` exits 0 on the development machine.
  - Pointing `STARK_KERNELS_LIB` at a file that is not the library, from a directory where the search finds nothing else, exits non-zero naming it (the mutation check of the "Kernels missing" scenario).

## 3. Packaging scripts

- [x] 3.1 `deploy/debian/`: control (`@VERSION@`, `@ARCH@`, `Depends: supervisor, libsqlite3-0, ca-certificates`, `Suggests: caddy`), postinst, prerm, postrm, the supervisor program (`autostart=false`), `run.sh`, `config.example.yaml` with the installed paths and `env.example`, following D5. Verify with `shellcheck` on the scripts, and by reading them against the spec's lifecycle requirements.
- [x] 3.2 `scripts/package-deb.sh`: build the web site if absent, the kernels from the pinned tstokenlib, and the binary with `-DPOOL_VERSION`; lay out the tree; build `pool-coordinator_${VERSION}_${ARCH}.deb` with `dpkg-deb --root-owner-group`. Verify on a Linux machine: `dpkg-deb -c` lists the layout in the spec, and `dpkg-deb -f` shows the dependencies.
- [x] 3.3 `Dockerfile.build` (Ubuntu 22.04, Dart 3.11.5, Rust 1.84.0, Node 20, `dpkg-dev`, checksums pinned), `docker-compose.build.yml`, `docker-build.sh` and `build-deb.sh`, as go-ricochet's. Verify that `./build-deb.sh` on this Mac produces the amd64 `.deb`.
- [x] 3.4 `scripts/package-macos.sh`: build the kernels with `--features metal` and the binary, lay out `pool-coordinator-${VERSION}/`, and pack the tarball. Verify on this Mac: unpack it in a scratch directory and run `bin/pool-coordinator check` from `/`, which exits 0 and reports Metal available.

## 4. The installed package, end to end

- [x] 4.1 In an Ubuntu 22.04 container (`docker run --rm -it ubuntu:22.04` with the built `.deb`), verify "A first install":
  - `apt install ./pool-coordinator_*.deb` pulls its dependencies;
  - the files, user, owners and modes are as specified;
  - `pool-coordinator check` exits 0;
  - the supervisor program exists and is stopped.
- [x] 4.2 On localnet from the container (host networking), with the env file set, create a pool as the service user and start it under supervisor. Verify:
  - It reaches ready.
  - `/api/pool` answers with `api:` enabled.
  - "Not on the command line": the passphrase and RPC password appear in neither `/proc/<pid>/cmdline` nor the log. The check fails when `run.sh` is changed to pass the passphrase as an argument (the mutation check).
- [x] 4.3 Build a second package at a higher version and install it over the first. Verify:
  - "Upgrading a running service" and "Upgrading a stopped service".
  - "An upgrade keeps the pool": the configuration, genesis, wallet, identity, store and history are unchanged, the pool resumes at its round, and `--version` says the new one.
- [x] 4.4 Remove the package, then purge it. Verify that removal keeps the data and configuration, and purge removes the user, the data, the logs, the configuration and the env file.

## 5. The release workflow

- [x] 5.1 Write `.github/workflows/release.yml` per D7, with a first job refusing a tag that disagrees with `pubspec.yaml`. Verify "A tag whose version disagrees" by running the version check script locally with a mismatched tag (it exits non-zero naming both). Also verify that the workflow with the check removed would have gone on (the mutation check).
- [ ] 5.2 The build jobs run analyze, the suite, tstokenlib's native byte-identity test against the built kernels, the packaging and the smoke test. The publish job writes `SHA256SUMS`, fails an artifact over 40 MB, and creates the release. Verify by pushing the first release tag `v0.1.0` (the user chose this over a release candidate, since a failed run publishes nothing): all three builds and the release succeed; the artifacts download and `sha256sum -c SHA256SUMS` passes, and each package's `check` passes.
- [ ] 5.3 Record in `docs/DESIGN.md`, in a dated section for this change, what the pre-release measured:
  - each artifact's size, against the 40 MB bound;
  - each build job's time;
  - the binary's compile time.
  
  Record them with the scratch script `tool/scratch/release_sizes.sh`, which reads the release's asset sizes with `gh`. Verify the section exists.

## 6. Records and the first release

- [x] 6.1 Add a short "Releases" note to `README.md` (where artifacts are, and that the install instructions follow), and add `pubspec_overrides.yaml` to the development steps. Verify both exist.
- [x] 6.2 Run `dart analyze lib bin test`, `dart test`, the transport suite and the localnet suites on the pinned dependencies, and the web lint, test and build. Verify all pass, and report the output.
