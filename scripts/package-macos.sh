#!/bin/bash
# Builds pool-coordinator-${VERSION}-macos-arm64.tar.gz on an Apple Silicon
# Mac: the binary, the kernels with their Metal GPU path, the web site and
# the example configuration, in one directory that runs where it is
# unpacked. Run from the repository root; the tarball lands in build/dist/.
#
#   VERSION   defaults to pubspec.yaml's
#   WEB_DIST  a built site to use instead of web/dist
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh

if [ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]; then
    echo "ERROR: the macOS package is built on an Apple Silicon Mac" >&2
    exit 1
fi

VERSION="${VERSION:-$(pubspec_version)}"
DIR="pool-coordinator-${VERSION}"
STAGE="build/macos/${DIR}"
OUT="build/dist/${DIR}-macos-arm64.tar.gz"

echo "== pool-coordinator ${VERSION} (macOS arm64)"
resolve_dependencies
KERNELS="$(build_kernels --features metal)"
SITE="$(web_dist)"

umask 022
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib"
compile_binary "$STAGE/bin/pool-coordinator"
install -m 644 "$KERNELS" "$STAGE/lib/"
cp -R "$SITE" "$STAGE/web"
install -m 644 config.example.yaml deploy/Caddyfile "$STAGE/"

mkdir -p build/dist
# no extended attributes or resource forks in the archive
COPYFILE_DISABLE=1 tar -C build/macos --no-xattrs -czf "$OUT" "$DIR"
ls -l "$OUT"
