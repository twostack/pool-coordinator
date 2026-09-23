#!/usr/bin/env bash
# The public page end to end on localnet: the coordinator with the API (the
# localnet test's run, in its dashboard mode), Caddy in front of it on
# https://localhost with a certificate from Caddy's own CA, and a browser
# test through the proxy that watches round 1 arrive live.
#
# Needs ../localnet up, a ricochet server the localnet test can start, Node
# 20 with web/'s dependencies and Playwright's Chromium, and Caddy with the
# rate-limit module (deploy/README.md), at build/caddy or $CADDY.
#
#   tool/dashboard_e2e.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
caddy=${CADDY:-$root/build/caddy}
api_port=${POOL_API_PORT:-8787}
https_port=${POOL_HTTPS_PORT:-8443}
http_port=${POOL_HTTP_PORT:-8080}
work=$(mktemp -d "${TMPDIR:-/tmp}/pool-dashboard-e2e.XXXXXX")
signals=$work/signals
mkdir -p "$signals"
pids=()

cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

say() { printf '== %s\n' "$*"; }

wait_for() { # seconds, description, command...
  local secs=$1 what=$2; shift 2
  for ((i = 0; i < secs * 5; i++)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "timed out waiting for $what" >&2
  exit 1
}

[[ -x $caddy ]] || { echo "no Caddy at $caddy; see deploy/README.md" >&2; exit 1; }
"$caddy" list-modules | grep -q '^http.handlers.rate_limit$' || { echo "$caddy has no rate_limit module" >&2; exit 1; }

export POOL_DOMAIN=localhost POOL_SITE=$root/web/dist POOL_API=127.0.0.1:$api_port
export POOL_HTTPS_PORT=$https_port POOL_HTTP_PORT=$http_port
# Caddy keeps its CA and certificates here rather than in the user's home
export XDG_DATA_HOME=$work/caddy-data XDG_CONFIG_HOME=$work/caddy-config

say "Proxy configuration checks"
"$caddy" validate --config "$root/deploy/Caddyfile" --adapter caddyfile >/dev/null 2>&1
adapted=$("$caddy" adapt --config "$root/deploy/Caddyfile" --adapter caddyfile 2>/dev/null)
for want in '"handler":"rate_limit"' 'Content-Security-Policy' '"flush_interval":-1' '"method":["GET","HEAD"]'; do
  grep -qF "$want" <<<"$adapted" || { echo "the adapted configuration lacks $want" >&2; exit 1; }
done
echo "valid; rate limit, content security policy, unbuffered events and the read-only gate present"

say "building the site"
(cd "$root/web" && npm run build --silent >/dev/null)

say "starting the coordinator on localnet (the localnet test's run)"
(cd "$root" && POOL_LOCALNET=1 POOL_DASHBOARD_E2E=$signals POOL_API_PORT=$api_port \
  dart test test/localnet_e2e_test.dart --reporter expanded >"$work/coordinator.log" 2>&1; echo $? >"$signals/exit") &
pids+=($!)
wait_for 600 "the coordinator's API" test -e "$signals/ready"
curl -sf "http://127.0.0.1:$api_port/api/pool" >/dev/null

say "starting Caddy on https://localhost:$https_port"
"$caddy" run --config "$root/deploy/Caddyfile" --adapter caddyfile >"$work/caddy.log" 2>&1 &
pids+=($!)
wait_for 60 "the proxy" curl -skf "https://localhost:$https_port/"

post=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "https://localhost:$https_port/api/pool")
[[ $post == 405 ]] || { echo "POST /api/pool through the proxy answered $post" >&2; exit 1; }
echo "curl -X POST https://localhost:$https_port/api/pool: 405"

say "the browser through the proxy"
status=0
(cd "$root/web" && POOL_SITE=https://localhost:$https_port POOL_E2E_SIGNALS=$signals \
  npx playwright test e2e/proxy.spec.ts --reporter list) || status=$?
touch "$signals/done"

say "waiting for the coordinator's run to finish"
wait_for 900 "the coordinator's run" test -e "$signals/exit"
dart_status=$(cat "$signals/exit")
tail -n 3 "$work/coordinator.log"
if [[ $status != 0 || $dart_status != 0 ]]; then
  echo "failed: browser $status, coordinator $dart_status" >&2
  echo "--- caddy.log (last 20)"; tail -n 20 "$work/caddy.log"
  echo "--- coordinator.log (last 40)"; tail -n 40 "$work/coordinator.log"
  exit 1
fi
say "Through the proxy: passed"
