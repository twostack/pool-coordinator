#!/bin/bash
# Runs the coordinator with its secrets, as the pool-coordinator user:
# `run` (the default) under supervisor, or `create` once, by the operator:
#   sudo -u pool-coordinator /opt/pool-coordinator/run.sh create
#
# The secrets travel in the environment, never on the command line: a running
# process's command line is readable by every local user. Nothing here
# prints them.
set -e

ENV_FILE=/etc/pool-coordinator/env
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

COMMAND="${1:-run}"
case "$COMMAND" in
    run|create) ;;
    *) echo "usage: run.sh [run|create]" >&2; exit 64 ;;
esac

exec /opt/pool-coordinator/bin/pool-coordinator -c /etc/pool-coordinator/config.yaml "$COMMAND"
