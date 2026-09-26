#!/bin/bash
# Steps both packaging scripts share: resolve the pinned dependencies, build
# the web site and the native kernels, and compile the binary. Sourced, not
# run; the caller sets VERSION and runs from the repository root.

# The version in pubspec.yaml, which a release tag must equal.
pubspec_version() {
    sed -n 's/^version: *//p' pubspec.yaml | tr -d '"'"'"
}

# Resolves the dependencies from pub.dev as the committed lockfile pins them.
# A pubspec_overrides.yaml would swap in sibling checkouts, so it is refused.
# LOCKFILE=resolve lets a local build re-resolve a lock that development
# rewrote; a release never sets it.
resolve_dependencies() {
    if [ -f pubspec_overrides.yaml ]; then
        echo "ERROR: pubspec_overrides.yaml is present; a release builds from pub.dev." >&2
        echo "       Move it aside and restore the committed pubspec.lock." >&2
        exit 1
    fi
    if [ "${LOCKFILE:-enforce}" = resolve ]; then
        dart pub get
    else
        dart pub get --enforce-lockfile
    fi
}

# Where the resolved tstokenlib is, from the package config.
tstokenlib_root() {
    python3 - <<'PY'
import json
d = json.load(open('.dart_tool/package_config.json'))
root = [p['rootUri'] for p in d['packages'] if p['name'] == 'tstokenlib'][0]
if root.startswith('file://'):
    root = root[len('file://'):]
else:
    import os
    root = os.path.normpath(os.path.join('.dart_tool', root))
print(root.rstrip('/'))
PY
}

# Builds the program with `dart build cli` into build/cli/bundle: bin/pool_coordinator,
# and in lib/ the kernels library tstokenlib's build hook provides (the
# prebuilt one the locked tstokenlib pins by SHA-256, or one built from its
# crate when none is listed; the Mac's carries the Metal GPU path). VERSION is
# written into lib/src/build_version.dart for the build, since `dart build cli`
# takes no --define, and the committed file is put back before anything else,
# the build's failure included.
BUNDLE=build/cli/bundle
build_bundle() {
    local version_file=lib/src/build_version.dart status=0
    cp "$version_file" "$version_file.committed"
    printf "// Written by scripts/common.sh for a release build; see the committed file.\nconst buildVersion = '%s';\n" "$VERSION" > "$version_file"
    rm -rf build/cli
    dart build cli --target bin/pool_coordinator.dart -o build/cli >&2 || status=$?
    mv -f "$version_file.committed" "$version_file"
    if [ "$status" -ne 0 ]; then
        echo "ERROR: dart build cli failed ($status)" >&2
        exit "$status"
    fi
}

# The built web site: WEB_DIST if given (the release workflow builds it
# once), web/dist if present, or a fresh build.
web_dist() {
    if [ -n "${WEB_DIST:-}" ]; then echo "$WEB_DIST"; return; fi
    if [ ! -f web/dist/index.html ]; then
        (cd web && npm ci && npm run build) >&2
    fi
    echo web/dist
}
