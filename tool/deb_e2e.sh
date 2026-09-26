#!/usr/bin/env bash
# The Debian package end to end, in a clean Ubuntu 22.04 container: a first
# install, a pool created and run under supervisor on localnet, the secrets
# kept off the command line and out of the logs, an upgrade while running
# and one while stopped, then removal and purge.
#
# Needs ../localnet up (the node on 18332 and the ricochet PostgreSQL), the
# ricochet server binary (see README.md), Docker, and two packages of the
# same architecture, the second at a higher version:
#
#   VERSION=0.1.0 ./build-deb.sh && VERSION=0.1.1 ./build-deb.sh
#   tool/deb_e2e.sh build/dist/pool-coordinator_0.1.0_amd64.deb build/dist/pool-coordinator_0.1.1_amd64.deb
#
# Each check reads `condition && ok ... || fail ...`; ok only prints, so
# fail runs exactly when the condition does not hold.
# shellcheck disable=SC2015
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
deb1=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
deb2=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
arch=$(basename "$deb1" .deb | sed 's/.*_//')
v2=$(basename "$deb2" .deb | cut -d_ -f2)
name=pool-deb-e2e
rpc=http://localhost:18332
work=$(mktemp -d "${TMPDIR:-/tmp}/pool-deb-e2e.XXXXXX")
pids=()
# made here for this run only, never printed
passphrase=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')

cleanup() {
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
ok() { printf '   ok  %s\n' "$*"; }
fail() { printf '   FAIL %s\n' "$*"; exit 1; }
inside() { docker exec "$name" bash -c "$1"; }
node() { curl -fsS --user bitcoin:bitcoin -H 'content-type: text/plain' -d "{\"method\":\"$1\",\"params\":$2}" "$rpc"; }
# waits up to $1 seconds for the command in $2 (run in the container) to succeed
until_in() {
  local i
  for ((i = 0; i < $1; i++)); do inside "$2" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
status_of() { inside "supervisorctl status pool-coordinator 2>&1 | awk '{print \$2}'" || true; }
tip_round() { inside "grep -A1 '\"tip\"' /var/lib/pool-coordinator/status.json | sed -n 's/.*\"round\": *\\([0-9]*\\).*/\\1/p'"; }
# the pool's tip as the status file shows it: its round and its Y
tip() { inside "sed -n '/\"tip\"/,/}/p' /var/lib/pool-coordinator/status.json"; }

# The coordinator's command line and its logs must hold neither secret.
# Prints what leaked, and fails, if either does.
secrets_kept() {
  local pid
  pid=$(inside "pgrep -f '[/]opt/pool-coordinator/bin/pool-coordinator -c' | head -1")
  [ -n "$pid" ] || { echo "no coordinator process"; return 1; }
  local cmdline
  cmdline=$(inside "tr '\\0' ' ' < /proc/$pid/cmdline")
  local leaked=0
  if grep -qF "$passphrase" <<<"$cmdline"; then echo "the passphrase is on the command line"; leaked=1; fi
  if grep -qF "POOL_RPC_PASSWORD" <<<"$cmdline"; then echo "the RPC password's variable is on the command line"; leaked=1; fi
  if inside "grep -rqF '$passphrase' /var/log/pool-coordinator"; then echo "the passphrase is in a log"; leaked=1; fi
  return $leaked
}

step "4.1 a first install ($(basename "$deb1"))"
docker run -d --name "$name" --platform "linux/$arch" --add-host=host.docker.internal:host-gateway \
  -v "$(dirname "$deb1"):/debs1:ro" -v "$(dirname "$deb2"):/debs2:ro" ubuntu:22.04 sleep infinity >/dev/null
inside "apt-get update -qq" >/dev/null
inside "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /debs1/$(basename "$deb1")" >"$work/install1.log" 2>&1 ||
  { cat "$work/install1.log"; fail "apt install"; }
grep -q "pool-coordinator is installed and stopped" "$work/install1.log" && ok "the installer printed the next steps" || fail "the installer printed the next steps"
inside "service supervisor start" >/dev/null 2>&1 || true
until_in 10 "supervisorctl pid >/dev/null" || fail "supervisord did not start"
inside "supervisorctl reread && supervisorctl update" >/dev/null
inside "! dpkg -s libsqlite3-dev >/dev/null 2>&1" && ok "no libsqlite3-dev" || fail "no libsqlite3-dev"
expected="root:root 755 /opt/pool-coordinator/bin/pool-coordinator
root:root 644 /opt/pool-coordinator/lib/libstark_kernels.so
root:root 755 /opt/pool-coordinator/run.sh
root:root 644 /opt/pool-coordinator/web/index.html
root:root 644 /opt/pool-coordinator/share/Caddyfile
root:root 644 /etc/supervisor/conf.d/pool-coordinator.conf
root:pool-coordinator 1770 /etc/pool-coordinator
root:pool-coordinator 640 /etc/pool-coordinator/env
pool-coordinator:pool-coordinator 640 /etc/pool-coordinator/config.yaml
pool-coordinator:pool-coordinator 750 /var/lib/pool-coordinator
pool-coordinator:pool-coordinator 750 /var/log/pool-coordinator"
actual=$(inside "stat -c '%U:%G %a %n' $(awk '{print $3}' <<<"$expected" | tr '\n' ' ')")
[ "$actual" = "$expected" ] || { diff <(echo "$expected") <(echo "$actual"); fail "owners and modes"; }
ok "files, owners and modes"
[ "$(inside "readlink /usr/bin/pool-coordinator")" = /opt/pool-coordinator/bin/pool-coordinator ] && ok "pool-coordinator on the path" || fail "pool-coordinator on the path"
[ "$(inside "getent passwd pool-coordinator | cut -d: -f7")" = /usr/sbin/nologin ] && ok "the service user has no login shell" || fail "the service user has no login shell"
inside "cd / && pool-coordinator check" >"$work/check.txt" || { cat "$work/check.txt"; fail "check"; }
grep -q "kernels: /opt/pool-coordinator/lib/libstark_kernels.so" "$work/check.txt" &&
  grep -q "sqlite: libsqlite3.so.0" "$work/check.txt" || { cat "$work/check.txt"; fail "check names the bundled kernels and libsqlite3.so.0"; }
ok "check: $(tr '\n' ';' <"$work/check.txt")"
[ "$(status_of)" = STOPPED ] && ok "the supervisor program exists and is stopped" || fail "the supervisor program exists and is stopped"

step "4.2 create and run a pool on localnet"
inside "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl" >/dev/null
(cd "$root" && exec dart run tool/ricochet_up.dart) >"$work/ricochet.out" 2>&1 &
pids+=($!)
# dart run prints its hook progress without a newline, so the line may not
# start the output
for ((i = 0; i < 60; i++)); do grep -qE 'ricochet [0-9]+ ' "$work/ricochet.out" && break; sleep 1; done
read -r _ rport rpeer < <(grep -oE 'ricochet [0-9]+ [[:alnum:]]+' "$work/ricochet.out") || { cat "$work/ricochet.out"; fail "ricochet server"; }
hostip=$(inside "getent ahostsv4 host.docker.internal | awk 'NR==1{print \$1}'")
inside "sed -i -e 's#rpc_url: .*#rpc_url: http://host.docker.internal:18332#' \
  -e 's#server: /ip4/.*#server: /ip4/$hostip/udp/$rport/udx/p2p/$rpeer#' /etc/pool-coordinator/config.yaml"
inside "printf 'POOL_WALLET_PASSPHRASE=%s\nPOOL_RPC_PASSWORD=bitcoin\n' '$passphrase' > /etc/pool-coordinator/env"
# blocks throughout, as localnet_pool.dart mines them
(while true; do node generate '[1]' >/dev/null 2>&1 || true; sleep 2; done) &
pids+=($!)
inside "cd /var/lib/pool-coordinator && runuser -u pool-coordinator -- /opt/pool-coordinator/run.sh create >/tmp/create.log 2>&1; echo \$? >/tmp/create.exit" &
pids+=($!)
funded=
for ((i = 0; i < 600; i++)); do
  if [ -z "$funded" ] && m=$(inside "grep -oE 'fund [^ ]* with (one payment of )?at least [0-9]*' /tmp/create.log" 2>/dev/null); then
    addr=$(awk '{print $2}' <<<"$m"); need=$(awk '{print $NF}' <<<"$m")
    node sendtoaddress "[\"$addr\", $(awk -v n="$need" 'BEGIN{printf "%.8f", 2*n/1e8}')]" >/dev/null
    funded=1; ok "funded the pool's address"
  fi
  inside "test -f /tmp/create.exit" 2>/dev/null && break
  sleep 1
done
[ "$(inside "cat /tmp/create.exit")" = 0 ] || { inside "cat /tmp/create.log"; fail "create"; }
inside "grep -q '^genesis:' /etc/pool-coordinator/config.yaml" && ok "create wrote the genesis into config.yaml" || fail "create wrote the genesis into config.yaml"
inside "supervisorctl start pool-coordinator" >/dev/null
until_in 120 "grep -q '\"ready\": true' /var/lib/pool-coordinator/status.json" ||
  { inside "tail -30 /var/log/pool-coordinator/stderr.log"; fail "not ready"; }
ok "running under supervisor and ready"
until_in 30 "curl -fsS http://127.0.0.1:8787/api/pool >/tmp/pool.json" || fail "/api/pool"
ok "/api/pool answers: $(inside "head -c 120 /tmp/pool.json")"
inside "! grep -iE 'sqlite.*(fail|error|unable)' /var/log/pool-coordinator/stderr.log" && ok "the log names no SQLite failure" || fail "the log names no SQLite failure"
secrets_kept && ok "neither secret on the command line or in the logs" || fail "neither secret on the command line or in the logs"
# the check must see a leak: pass the passphrase as an argument
inside "cp /opt/pool-coordinator/run.sh /tmp/run.sh.good && sed -i 's#\"\$COMMAND\"\$#\"\$COMMAND\" \"\$POOL_WALLET_PASSPHRASE\"#' /opt/pool-coordinator/run.sh"
inside "supervisorctl restart pool-coordinator" >/dev/null
sleep 3
if secrets_kept >/dev/null; then fail "the check missed a passphrase on the command line"; fi
ok "the check catches a passphrase on the command line (mutation)"
inside "cp /tmp/run.sh.good /opt/pool-coordinator/run.sh && supervisorctl restart pool-coordinator" >/dev/null
until_in 120 "grep -q '\"ready\": true' /var/lib/pool-coordinator/status.json" || fail "not ready after restoring run.sh"

step "4.3 upgrade to $v2 while running, then while stopped"
# nothing submits here, so the pool may still be at genesis (round 0)
before_round=$(tip_round)
before_tip=$(tip)
# what the pool keeps (its store appears with its first round)
before_files=$(inside "cd /var/lib/pool-coordinator && ls -d wallet.enc identity.seed metrics.sqlite store 2>/dev/null; true")
before_sums=$(inside "cd /var/lib/pool-coordinator && sha256sum /etc/pool-coordinator/config.yaml identity.seed")
inside "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /debs2/$(basename "$deb2")" >"$work/install2.log" 2>&1 ||
  { cat "$work/install2.log"; fail "upgrade"; }
[ "$(status_of)" = RUNNING ] && ok "running after upgrading a running service" || fail "running after upgrading a running service"
[ "$(inside "pool-coordinator --version")" = "pool-coordinator $v2" ] && ok "--version says $v2" || fail "--version says $v2"
[ "$(inside "cd /var/lib/pool-coordinator && sha256sum /etc/pool-coordinator/config.yaml identity.seed")" = "$before_sums" ] &&
  ok "the configuration (with its genesis) and the identity are unchanged" || fail "the configuration (with its genesis) and the identity are unchanged"
[ "$(inside "cd /var/lib/pool-coordinator && ls -d wallet.enc identity.seed metrics.sqlite store 2>/dev/null; true")" = "$before_files" ] &&
  ok "the wallet, identity, history and store kept: $(tr '\n' ' ' <<<"$before_files")" ||
  { inside "ls -la /var/lib/pool-coordinator"; fail "the wallet, identity, history and store kept"; }
until_in 120 "grep -q '\"ready\": true' /var/lib/pool-coordinator/status.json" || fail "not ready after the upgrade"
after_round=$(tip_round)
{ [ "$after_round" -gt "$before_round" ] || [ "$(tip)" = "$before_tip" ]; } &&
  ok "resumed at its tip, round $after_round (was $before_round)" || { tip; fail "resumed at its tip"; }
inside "supervisorctl stop pool-coordinator" >/dev/null
inside "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall /debs2/$(basename "$deb2")" >/dev/null 2>&1 || fail "reinstall"
[ "$(status_of)" = STOPPED ] && ok "still stopped after upgrading a stopped service" || fail "still stopped after upgrading a stopped service"

step "4.4 remove, then purge"
inside "DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq pool-coordinator" >/dev/null 2>&1 || fail "remove"
inside "test -f /var/lib/pool-coordinator/wallet.enc && test -f /etc/pool-coordinator/config.yaml && test -f /etc/pool-coordinator/env && id pool-coordinator" >/dev/null &&
  ok "removal kept the data, the configuration, the env file and the user" || fail "removal kept the data, the configuration, the env file and the user"
inside "! pgrep -f '[/]opt/pool-coordinator/bin/pool-coordinator -c'" && ok "the service is stopped" || fail "the service is stopped"
inside "DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq pool-coordinator" >/dev/null 2>&1 || fail "purge"
inside "! id pool-coordinator 2>/dev/null && ! test -e /var/lib/pool-coordinator && ! test -e /var/log/pool-coordinator && ! test -e /etc/pool-coordinator" &&
  ok "purge removed the user, the data, the logs, the configuration and the env file" || fail "purge removed the user, the data, the logs, the configuration and the env file"

printf '\nall checks passed\n'
