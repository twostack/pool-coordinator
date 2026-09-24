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

# Where the resolved tstokenlib is, from the package config: its kernel crate
# ships in the package as source.
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

# Builds the kernels into build/kernels (outside the pub cache) and prints
# the library's path. Extra cargo arguments (--features metal) pass through.
build_kernels() {
    local crate
    crate="$(tstokenlib_root)/native/stark_kernels"
    cargo build --release --locked --manifest-path "$crate/Cargo.toml" --target-dir build/kernels "$@" >&2
    local lib
    for lib in build/kernels/release/libstark_kernels.so build/kernels/release/libstark_kernels.dylib; do
        if [ -f "$lib" ]; then echo "$lib"; return; fi
    done
    echo "ERROR: the kernel build produced no library" >&2
    exit 1
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

# Compiles the coordinator with its version built in.
compile_binary() {
    local out="$1"
    mkdir -p "$(dirname "$out")"
    dart compile exe -DPOOL_VERSION="$VERSION" bin/pool_coordinator.dart -o "$out" >&2
}
