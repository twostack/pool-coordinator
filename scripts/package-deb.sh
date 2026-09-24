#!/bin/bash
# Builds pool-coordinator_${VERSION}_${ARCH}.deb on Linux (a release runner,
# or the Ubuntu 22.04 container build-deb.sh starts on a Mac). Run from the
# repository root. The package lands in build/dist/.
#
#   VERSION   defaults to pubspec.yaml's
#   ARCH      defaults to this machine's (dpkg --print-architecture)
#   WEB_DIST  a built site to use instead of web/dist
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh

VERSION="${VERSION:-$(pubspec_version)}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
# Debian orders 0.1.0~rc.1 before 0.1.0, and 0.1.0-rc.1 after it.
DEB_VERSION="${VERSION/-/\~}"
NAME=pool-coordinator
ROOT="build/deb/${NAME}_${VERSION}_${ARCH}"
OUT="build/dist/${NAME}_${VERSION}_${ARCH}.deb"

echo "== ${NAME} ${VERSION} (${ARCH})"
resolve_dependencies
# shellcheck disable=SC2119  # no extra cargo arguments on Linux
KERNELS="$(build_kernels)"
SITE="$(web_dist)"

umask 022
rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" "$ROOT/opt/$NAME/bin" "$ROOT/opt/$NAME/lib" "$ROOT/opt/$NAME/share" \
    "$ROOT/usr/bin" "$ROOT/etc/supervisor/conf.d"

compile_binary "$ROOT/opt/$NAME/bin/$NAME"
install -m 644 "$KERNELS" "$ROOT/opt/$NAME/lib/"
install -m 755 deploy/debian/run.sh "$ROOT/opt/$NAME/run.sh"
cp -R "$SITE" "$ROOT/opt/$NAME/web"
install -m 644 deploy/Caddyfile deploy/debian/config.example.yaml deploy/debian/env.example "$ROOT/opt/$NAME/share/"
install -m 644 deploy/debian/pool-coordinator.conf "$ROOT/etc/supervisor/conf.d/"
ln -s "/opt/$NAME/bin/$NAME" "$ROOT/usr/bin/$NAME"

sed -e "s/@VERSION@/${DEB_VERSION}/" -e "s/@ARCH@/${ARCH}/" deploy/debian/control > "$ROOT/DEBIAN/control"
echo "Installed-Size: $(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)" >> "$ROOT/DEBIAN/control"
install -m 644 deploy/debian/conffiles "$ROOT/DEBIAN/"
install -m 755 deploy/debian/postinst deploy/debian/prerm deploy/debian/postrm "$ROOT/DEBIAN/"
chmod -R u+rwX,go+rX,go-w "$ROOT"

mkdir -p build/dist
dpkg-deb --build --root-owner-group -Zxz "$ROOT" "$OUT"
ls -l "$OUT"
