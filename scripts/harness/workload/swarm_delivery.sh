#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-120}"
export STOP_WAIT_SEC="${STOP_WAIT_SEC:-45}"

if [ -n "${SWARM_SESSION_GOAL:-}" ]; then
  export TEAM_GOAL="$SWARM_SESSION_GOAL"
fi

if [ -n "${SWARM_WORKER_BATCH_FILE:-}" ] && [ -z "${SWARM_WORKER_BATCH_JSON:-}" ]; then
  if [ ! -f "$SWARM_WORKER_BATCH_FILE" ]; then
    echo "FAIL: SWARM_WORKER_BATCH_FILE not found: $SWARM_WORKER_BATCH_FILE"
    exit 1
  fi
  export SWARM_WORKER_BATCH_JSON
  SWARM_WORKER_BATCH_JSON="$(cat "$SWARM_WORKER_BATCH_FILE")"
fi

exec "${SCRIPT_DIR}/supervisor_execution_session.sh" "$@"
