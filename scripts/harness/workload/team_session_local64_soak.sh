#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SMOKE_SCRIPT="$ROOT_DIR/scripts/harness/workload/team_session_local64_smoke.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8945/mcp}"
COORD_AGENT="${COORD_AGENT:-team-session-local64-soak}"
WORKER_COUNT="${WORKER_COUNT:-24}"
ROUNDS="${ROUNDS:-2}"
SESSION_DURATION_SEC="${SESSION_DURATION_SEC:-2400}"
SPAWN_TIMEOUT_SEC="${SPAWN_TIMEOUT_SEC:-900}"
WAIT_AFTER_SPAWN_SEC="${WAIT_AFTER_SPAWN_SEC:-3}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"

if [ ! -f "$SMOKE_SCRIPT" ]; then
  echo "Missing smoke workload: $SMOKE_SCRIPT" >&2
  exit 1
fi

success=0
for round in $(seq 1 "$ROUNDS"); do
  echo "[soak] round=$round/$ROUNDS"
  round_log="$(mktemp -t "local64-soak-round.${round}")"
  if MCP_URL="$MCP_URL" \
    COORD_AGENT="${COORD_AGENT}-r${round}" \
    WORKER_COUNT="$WORKER_COUNT" \
    SESSION_DURATION_SEC="$SESSION_DURATION_SEC" \
    SPAWN_TIMEOUT_SEC="$SPAWN_TIMEOUT_SEC" \
    WAIT_AFTER_SPAWN_SEC="$WAIT_AFTER_SPAWN_SEC" \
    GOAL="Repeated local64 smoke round ${round}/${ROUNDS}" \
    LLAMA_SWARM_MODEL="$LLAMA_SWARM_MODEL" \
    bash "$SMOKE_SCRIPT" >"$round_log" 2>&1; then
    session_id="$(rg -o 'session=[^ ]+' "$round_log" | tail -n1 | cut -d= -f2)"
    printf '[soak] round=%s pass session=%s\n' "$round" "${session_id:-unknown}"
    success=$((success + 1))
  else
    cat "$round_log" >&2 || true
    echo "FAIL: local64 soak round $round/$ROUNDS failed" >&2
    exit 1
  fi
done

echo "PASS: local64 soak rounds=${ROUNDS} workers=${WORKER_COUNT} success=${success}"
