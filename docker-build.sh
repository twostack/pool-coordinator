#!/bin/bash
# Runs inside the build container: copies the read-only source into a
# writable workspace and builds the package there with scripts/package-deb.sh.
set -euo pipefail

sudo chown -R builder:builder /home/builder/.pub-cache /home/builder/.cargo/registry /home/builder/.npm /out

WORK=/home/builder/work
rm -rf "$WORK"
mkdir -p "$WORK"
# Development files stay behind: the overrides and the tool caches are this
# Mac's, and web/node_modules holds macOS binaries.
rsync -a --exclude=.git --exclude=build --exclude=.dart_tool --exclude=native \
      --exclude=pubspec_overrides.yaml --exclude=web/node_modules --exclude=tool/scratch \
      --exclude=.claude /src/ "$WORK/"
cd "$WORK"

# A lock that development rewrote names sibling paths; a local build then
# resolves afresh. The release workflow always uses the committed lock.
if grep -q 'source: path' pubspec.lock 2>/dev/null; then
    echo "NOTE: pubspec.lock names local paths (a development lock); resolving from pub.dev instead."
    export LOCKFILE=resolve
fi

scripts/package-deb.sh
cp build/dist/*.deb /out/
if [ -n "${HOST_USER_ID:-}" ] && [ -n "${HOST_GROUP_ID:-}" ]; then
    sudo chown "$HOST_USER_ID:$HOST_GROUP_ID" /out/*.deb
fi
