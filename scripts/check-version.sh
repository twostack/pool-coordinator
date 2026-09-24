#!/bin/bash
# Refuses a release tag whose version is not pubspec.yaml's, naming both, so
# a release never ships a binary that reports another version.
#
#   scripts/check-version.sh v0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh

tag="${1:?usage: check-version.sh <tag>}"
want="$(pubspec_version)"
if [ "$tag" != "v$want" ]; then
    echo "ERROR: the tag $tag does not match pubspec.yaml's version $want (expected v$want)" >&2
    exit 1
fi
echo "tag $tag matches pubspec.yaml's version $want"
