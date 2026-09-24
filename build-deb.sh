#!/bin/bash
# Builds the Debian package on a Mac, inside an Ubuntu 22.04 container.
#
#   ./build-deb.sh                 amd64, at pubspec.yaml's version
#   ARCH=arm64 ./build-deb.sh      arm64 (native on Apple Silicon)
#   VERSION=0.1.1 ./build-deb.sh
#
# The package lands in build/dist/.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(sed -n 's/^version: *//p' pubspec.yaml)}"
export VERSION
export ARCH="${ARCH:-amd64}"
HOST_USER_ID="$(id -u)"
HOST_GROUP_ID="$(id -g)"
export HOST_USER_ID HOST_GROUP_ID
mkdir -p build/dist

echo "== pool-coordinator ${VERSION} (${ARCH}) in Ubuntu 22.04"
docker compose -f docker-compose.build.yml build builder
docker compose -f docker-compose.build.yml run --rm builder bash docker-build.sh

DEB="build/dist/pool-coordinator_${VERSION}_${ARCH}.deb"
ls -l "$DEB"
echo "Install on Ubuntu 22.04+ or Debian 12:  sudo apt install ./$(basename "$DEB")"
