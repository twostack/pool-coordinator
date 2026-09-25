# Releasing pool-coordinator

A release is five files on a GitHub release of `twostack/pool-coordinator`:

| File | Built by | Where |
|---|---|---|
| `pool-coordinator_X.Y.Z_amd64.deb` | the release workflow | GitHub's `ubuntu-22.04` runner |
| `pool-coordinator_X.Y.Z_arm64.deb` | the release workflow | GitHub's `ubuntu-22.04-arm` runner |
| `pool-coordinator-X.Y.Z-macos-arm64.dmg` | `scripts/sign-macos-release.sh` | your Mac, from the tarball the `macos-14` runner built |
| `pool-elements-X.Y.Z.tgz` | the release workflow (`web/scripts/pack-elements.mjs`) | GitHub's `ubuntu-22.04` runner, after the host-page checks |
| `SHA256SUMS` | both, rewritten by the script | |

The workflow builds, tests and smoke-tests every package from the tag, then leaves the release as a draft. The macOS disk image is made on a Mac that holds the Developer ID certificate, because signing secrets are never stored on GitHub. The script that makes it also publishes the draft.

## One-time setup on the Mac

1. **An Apple Silicon Mac with Xcode.** You need `xcrun notarytool` and `xcrun stapler`. Check with `xcode-select -p`.
2. **The Developer ID Application certificate in the login keychain.** Check it is there:

   ```
   security find-identity -v -p codesigning
   ```

   The list must include `Developer ID Application: Werkswinkel Pte Ltd (32XLPKQ5TF)`, which is the identity the script signs with. To sign with another, set `SIGN_IDENTITY` to its name. If it is missing, create it in Xcode: Settings, Accounts, the team, Manage Certificates, +, Developer ID Application.
3. **A notarytool keychain profile.** This Mac already has `cloak-notary`, which cloak-cli uses too; it works for any software the team signs. To make one:

   ```
   xcrun notarytool store-credentials cloak-notary --apple-id <Apple ID> --team-id 32XLPKQ5TF
   ```

   It asks for an app-specific password (made at account.apple.com) and keeps it in the keychain. It is never put on a command line or in a file. Check the profile works with `xcrun notarytool history --keychain-profile cloak-notary`.
4. **The GitHub CLI, logged in with `repo` scope** (`gh auth status`), so the script can download from the draft, upload to it and publish it.

## Making a release

### 1. Set the version and commit

Set `version:` in `pubspec.yaml` to `X.Y.Z`. The workflow refuses a tag that does not match it.

The committed `pubspec.lock` must be resolved without `pubspec_overrides.yaml`, because the release build runs `dart pub get --enforce-lockfile` and fails on a lock that names local paths. So before committing:

```
mv pubspec_overrides.yaml /tmp/     # if you have one
dart pub get
grep -c 'source: path' pubspec.lock  # must print 0
```

Commit on `main`, and put the overrides file back afterwards if you use it.

### 2. Tag and push

```
git tag -a vX.Y.Z -m "pool-coordinator X.Y.Z"
git push origin main
git push origin vX.Y.Z
gh run watch                          # or: gh run list --limit 1
```

The run takes about 20 minutes, mostly the test suite on each runner. If any job fails, nothing is attached and no release is created. In that case, fix the fault on `main`, then move the tag and push again:

```
git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z
git tag -a vX.Y.Z -m "pool-coordinator X.Y.Z" && git push origin main vX.Y.Z
```

When the run succeeds there is a **draft** release `vX.Y.Z`, holding the two `.deb` files, the macOS tarball `pool-coordinator-X.Y.Z-macos-arm64.tar.gz` and `SHA256SUMS`. Nobody but the repository's maintainers can see it yet.

### 3. Build the signed disk image and publish (on the Mac)

From a checkout of this repository (any branch; the script only reads `deploy/macos/pool-coordinator.entitlements` from it):

```
NOTARY_PROFILE=cloak-notary scripts/sign-macos-release.sh vX.Y.Z
```

It takes a couple of minutes. Most of that is waiting for Apple's notary service. The first time, macOS may ask to let `codesign` use the signing key; choose Always Allow. In order, the script:

1. **Downloads the tarball** from the draft and checks it against the draft's `SHA256SUMS`.
2. **Signs** `lib/libstark_kernels.dylib`, then `bin/pool-coordinator`. Both are signed with the Developer ID, under the hardened runtime, with a secure timestamp. It then checks each signature. The binary carries one entitlement, `allow-unsigned-executable-memory`, from `deploy/macos/pool-coordinator.entitlements`. Without it the Dart runtime is killed at start.
3. **Runs `pool-coordinator check`** from the signed files.
4. **Packs the directory** into `pool-coordinator-X.Y.Z-macos-arm64.dmg` (volume name `pool-coordinator X.Y.Z`) and signs the image.
5. **Sends the image to Apple's notary service** and waits for the answer. If Apple accepts it, the script staples the ticket to the image and validates it. A stapled image carries its own ticket, so a Mac that cannot reach Apple's ticket service still runs the program; a bare binary cannot carry one.
6. **Checks the image as a downloader gets it.** It marks a copy with the quarantine attribute a browser sets, mounts it, and checks that it holds exactly the tarball's files. Then it copies the directory out and runs `--version` and `check` from the quarantined copy. macOS kills a quarantined program it cannot vouch for, so a program that runs here is one a user can run.
7. **Updates the draft.** It uploads the image, rewrites `SHA256SUMS` (the `.deb` lines unchanged, the image's line in place of the tarball's), and deletes the tarball from the release.
8. **Publishes the draft** and prints the release's URL and files.

If anything fails, the script stops before step 7 and the draft is untouched. Fix the cause and run it again.

The script also works on a release that is already published. It then replaces the tarball or image in place, which is how v0.1.0's unsigned tarball was replaced.

### 4. Check the published release

As a user would get it, in an empty directory:

```
gh release download vX.Y.Z --repo twostack/pool-coordinator
shasum -a 256 -c SHA256SUMS

# the image, as a browser download
xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;$(uuidgen)" pool-coordinator-X.Y.Z-macos-arm64.dmg
xcrun stapler validate pool-coordinator-X.Y.Z-macos-arm64.dmg
spctl -a -vv -t open --context context:primary-signature pool-coordinator-X.Y.Z-macos-arm64.dmg   # accepted, Notarized Developer ID
mkdir mnt && hdiutil attach -nobrowse -readonly -mountpoint mnt pool-coordinator-X.Y.Z-macos-arm64.dmg
ditto mnt/pool-coordinator-X.Y.Z pool-coordinator-X.Y.Z && hdiutil detach mnt
(cd / && "$OLDPWD/pool-coordinator-X.Y.Z/bin/pool-coordinator" check)                         # exit 0, Metal available

# a Debian package, in a clean container (either arch)
docker run --rm --platform linux/amd64 -v "$PWD:/d:ro" ubuntu:22.04 bash -c \
  'apt-get update -qq && apt-get install -y -qq /d/pool-coordinator_X.Y.Z_amd64.deb >/dev/null && cd / && pool-coordinator check'
```

## Building locally without releasing

- **Debian package:** `./build-deb.sh` builds `build/dist/pool-coordinator_<version>_amd64.deb` in an Ubuntu 22.04 container. Use `ARCH=arm64 ./build-deb.sh` for arm64. `tool/deb_e2e.sh <deb> <newer deb>` checks two of them end to end against localnet (install, a pool, upgrade, purge).
- **macOS tarball:** `scripts/package-macos.sh` builds `build/dist/pool-coordinator-<version>-macos-arm64.tar.gz`. It runs where it is unpacked on this Mac. Its files are not Developer ID signed, so a copy downloaded on another Mac will not run. Only `scripts/sign-macos-release.sh` makes the signed image, and it takes its tarball from a GitHub release.

A package builds from the pub.dev dependencies. `scripts/package-macos.sh` and `scripts/package-deb.sh` refuse to run while `pubspec_overrides.yaml` is present. `./build-deb.sh` leaves it out of the copy it builds in the container, and resolves afresh if the lock names local paths.

## When something goes wrong

- **Notarization is not accepted.** The script prints Apple's log for the submission. It usually names a file with a bad or missing signature. You can fetch the log again with `xcrun notarytool log <submission id> --keychain-profile cloak-notary`.
- **The quarantined program is killed (exit 137).** Check the signatures with `codesign -dvvv --entitlements - <file>`. You should see:
  - `flags=0x10000(runtime)` and a `Timestamp=` on both files;
  - `allow-unsigned-executable-memory` on the binary.

  Also check that the image validated with `xcrun stapler validate`. `spctl -t exec` cannot judge a command-line program, so run the program rather than trust `spctl`. macOS's reason is in `/usr/bin/log show --last 5m --predicate 'process == "syspolicyd"'` (use the full path: zsh's own `log` command shadows it).
- **A Rust build in the Docker build image reports `E0786` (invalid metadata).** A cached image layer is corrupt, which happened after the disk filled once. Rebuild it without the cache: `ARCH=<arch> docker compose -f docker-compose.build.yml build --no-cache builder`.
