#!/bin/bash
# Turns a release's macOS tarball into a signed, notarized and stapled disk
# image, on a Mac that holds the Developer ID certificate, and publishes the
# release. The same approach as cloak-cli's tool/release/macos.sh.
#
# The release workflow builds, tests and smoke-tests the tarball on a clean
# runner from the tag, and leaves the release a draft. This:
#   - takes that tarball and checks it against the draft's SHA256SUMS;
#   - signs the kernel library and the binary (hardened runtime, timestamped,
#     the one entitlement on the binary);
#   - packs the directory into a disk image, signs it, has Apple notarize it
#     and staples the ticket to it. A bare binary cannot hold a ticket, and a
#     Mac that cannot look one up online then refuses it; the image carries
#     its own.
#   - checks it as a downloader gets it: the image quarantined, the directory
#     copied out, the program run. spctl only judges app bundles, so running
#     it is the check.
#   - replaces the tarball with the image in the release, rewrites
#     SHA256SUMS, and publishes the release if it is a draft.
#
#   NOTARY_PROFILE=<keychain profile> scripts/sign-macos-release.sh v0.1.0
#
#   NOTARY_PROFILE  a profile made with `xcrun notarytool store-credentials`
#   SIGN_IDENTITY   defaults to the Werkswinkel Developer ID Application
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?usage: sign-macos-release.sh <tag>}"
version="${tag#v}"
profile="${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
identity="${SIGN_IDENTITY:-Developer ID Application: Werkswinkel Pte Ltd (32XLPKQ5TF)}"
entitlements="$PWD/deploy/macos/pool-coordinator.entitlements"
name="pool-coordinator-${version}"
tarball="${name}-macos-arm64.tar.gz"
image="${name}-macos-arm64.dmg"

work=$(mktemp -d "${TMPDIR:-/tmp}/sign-macos.XXXXXX")
cleanup() {
    hdiutil detach -quiet "$work/check/mnt" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 ||
    die "no notarytool keychain profile named $profile"

step "the release's tarball and checksums"
gh release download "$tag" --pattern "$tarball" --pattern SHA256SUMS --dir "$work"
(cd "$work" && grep " ${tarball}\$" SHA256SUMS | shasum -a 256 -c -)
mkdir -p "$work/volume"
tar -xzf "$work/$tarball" -C "$work/volume"
dir="$work/volume/$name"
[ "$(ls "$work/volume")" = "$name" ] || die "the tarball should hold only $name/"

step "sign the program and the kernel library"
codesign --force --timestamp --options runtime --sign "$identity" "$dir/lib/libstark_kernels.dylib"
codesign --force --timestamp --options runtime --entitlements "$entitlements" \
    --identifier com.twostack.pool-coordinator --sign "$identity" "$dir/bin/pool-coordinator"
for f in "$dir/lib/libstark_kernels.dylib" "$dir/bin/pool-coordinator"; do
    codesign --verify --strict --verbose=1 "$f"
    details=$(codesign -d --verbose=2 "$f" 2>&1)
    case "$details" in *"flags="*"(runtime)"*) ;; *) die "$f is not under the hardened runtime" ;; esac
    case "$details" in *"Timestamp="*) ;; *) die "$f has no secure timestamp" ;; esac
done
(cd / && env -u STARK_KERNELS_LIB "$dir/bin/pool-coordinator" check)

step "the disk image"
hdiutil create -quiet -volname "pool-coordinator $version" -srcfolder "$work/volume" -fs HFS+ -format UDZO -ov "$work/$image"
codesign --force --timestamp --sign "$identity" "$work/$image"
codesign --verify --strict "$work/$image"

step "notarize and staple"
result=$(xcrun notarytool submit "$work/$image" --keychain-profile "$profile" --wait --output-format json) ||
    die "the submission failed: $result"
id=$(printf '%s' "$result" | plutil -extract id raw -o - -)
status=$(printf '%s' "$result" | plutil -extract status raw -o - -)
echo "notarization $id: $status"
if [ "$status" != Accepted ]; then
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    die "not accepted"
fi
xcrun stapler staple "$work/$image"
xcrun stapler validate "$work/$image"

step "as a downloader gets it"
# the image quarantined as a browser marks it, the directory copied out
# carrying the mark, the program run from elsewhere: macOS kills a
# quarantined program it cannot vouch for
mkdir -p "$work/check/mnt"
cp "$work/$image" "$work/check/"
mark="0081;$(printf '%x' "$(date +%s)");Safari;"
xattr -w com.apple.quarantine "$mark" "$work/check/$image"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/check/mnt" "$work/check/$image"
listed=$(cd "$work/check/mnt" && find . -mindepth 1 -not -path './.fseventsd*' | sort)
expected=$(cd "$work/volume" && find . -mindepth 1 | sort)
[ "$listed" = "$expected" ] || die "the image does not hold exactly the tarball's files"
ditto "$work/check/mnt/$name" "$work/check/$name"
hdiutil detach -quiet "$work/check/mnt"
find "$work/check/$name" -type f -exec xattr -w com.apple.quarantine "$mark" {} \;
ran=$(cd / && "$work/check/$name/bin/pool-coordinator" --version 2>&1) || die "macOS does not run the quarantined program: ${ran:-killed}"
[ "$ran" = "pool-coordinator $version" ] || die "--version says $ran"
(cd / && "$work/check/$name/bin/pool-coordinator" check)

step "into $tag: the image in place of the tarball, and SHA256SUMS"
(cd "$work" && { grep -v " ${tarball}\$" SHA256SUMS; shasum -a 256 "$image"; } | sort -k2 > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS)
[ "$(wc -l < "$work/SHA256SUMS" | tr -d ' ')" -eq 4 ] || die "SHA256SUMS should list four files: $(cat "$work/SHA256SUMS")"
(cd "$work" && grep " ${image}\$" SHA256SUMS | shasum -a 256 -c -)
cat "$work/SHA256SUMS"
gh release upload "$tag" "$work/$image" "$work/SHA256SUMS" --clobber
gh release delete-asset "$tag" "$tarball" --yes

if [ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = true ]; then
    gh release edit "$tag" --draft=false
    echo "published $tag"
fi
gh release view "$tag" --json url,assets --jq '.url, (.assets[] | "  \(.name) \(.size)")'
