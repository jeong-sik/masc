#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVER_EXE="${SERVER_EXE:-${ROOT_DIR}/_build/default/bin/main_eio.exe}"
PORT="${PORT:-}"
BASE_PATH="${BASE_PATH:-}"
LOG_FILE="${LOG_FILE:-}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-45}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-30}"
CLEANUP_BASE_PATH="${CLEANUP_BASE_PATH:-0}"
SKIP_SERVER_START="${SKIP_SERVER_START:-0}"
MCP_SESSION_ID="${MCP_SESSION_ID:-dashboard-collab-smoke}"
AGENT_NAME="${AGENT_NAME:-dashboard-collab-smoke}"
GOAL="${GOAL:-Validate dashboard collaboration evidence and surface readiness endpoints}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

if [ ! -x "$SERVER_EXE" ]; then
  echo "server executable not found: $SERVER_EXE"
  echo "build it first with: dune build --root . bin/main_eio.exe"
  exit 1
fi

if [ -z "$PORT" ]; then
  for candidate in $(seq 8946 8960); do
    if ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then
      PORT="$candidate"
      break
    fi
  done
fi

if [ -z "$PORT" ]; then
  echo "could not find a free port in 8946-8960"
  exit 1
fi

if [ -z "$BASE_PATH" ]; then
  BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/masc-dashboard-collab.XXXXXX")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/masc-dashboard-collab-log.XXXXXX")"
fi

SERVER_PID=""
SESSION_ID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ "$CLEANUP_BASE_PATH" = "1" ] && [ -n "$BASE_PATH" ] && [ -d "$BASE_PATH" ]; then
    rm -rf "$BASE_PATH"
  fi
}
trap cleanup EXIT

wait_for_ready() {
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SEC ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local health_json
    health_json="$(curl -fsS --http1.1 --max-time 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
    if [ -n "$health_json" ] && printf '%s' "$health_json" | jq -e '.startup.state_ready == true' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local response
  response="$(curl -sS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" -X POST "http://127.0.0.1:${PORT}/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $MCP_SESSION_ID" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}")"
  printf '%s' "$response" | sed -n 's/^data: //p' | tail -n1
}

extract_tool_text() {
  jq -r 'try (.result.content[0].text) catch empty'
}

extract_tool_json() {
  jq -c '
    if (.result.structuredContent | type) == "object" then
      .result.structuredContent
    else
      (.result.content[0].text | fromjson)
    end
  '
}

require_tool_success() {
  local payload="$1"
  if ! printf '%s' "$payload" | jq -e '.result.isError == false' >/dev/null 2>&1; then
    echo "FAIL: tool returned isError=true"
    printf '%s\n' "$payload" | extract_tool_text
    exit 1
  fi
}

printf '[1/6] start local server\n'
if [ "$SKIP_SERVER_START" != "1" ]; then
  env \
    MASC_AUTONOMY_ENABLED=0 \
    GRAPHQL_API_KEY= \
    GRAPHQL_URL=http://127.0.0.1:9/graphql \
    MASC_POSTGRES_URL= \
    DATABASE_URL= \
    SUPABASE_DB_URL= \
    SB_PG_URL= \
    MASC_BOARD_BACKEND=jsonl \
    MASC_GRPC_ENABLED=0 \
    MASC_WS_ENABLED=0 \
    MASC_WEBRTC_ENABLED=0 \
    "$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH" >"$LOG_FILE" 2>&1 &
  SERVER_PID="$!"
else
  printf '  using existing server on port %s\n' "$PORT"
fi
if ! wait_for_ready; then
  echo "FAIL: server did not reach startup.state_ready=true"
  if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
  fi
  exit 1
fi

printf '[2/6] initialize room and join agent\n'
init_raw="$(call_tool 1 "masc_init" "$(jq -cn --arg a "$AGENT_NAME" '{agent_name:$a}')")"
require_tool_success "$init_raw"
join_raw="$(call_tool 2 "masc_join" "$(jq -cn --arg a "$AGENT_NAME" '{agent_name:$a,capabilities:["operator","team-session"]}')")"
require_tool_success "$join_raw"
agent_nickname="$(printf '%s' "$join_raw" | jq -r '.result.content[0].text' | sed -n 's/^  Nickname: //p' | head -n1)"
if [ -z "$agent_nickname" ]; then
  echo "FAIL: could not parse joined nickname"
  printf '%s\n' "$join_raw"
  exit 1
fi

printf '[3/6] start team session\n'
start_raw="$(call_tool 3 "masc_team_session_start" "$(jq -cn \
  --arg goal "$GOAL" \
  --arg agent "$agent_nickname" \
  '{goal:$goal,duration_seconds:120,checkpoint_interval_sec:15,orchestration_mode:"assist",communication_mode:"broadcast",execution_scope:"limited_code_change",fallback_policy:"cascade_then_task",instruction_profile:"strict",min_agents:1,agents:[$agent]}')")"
require_tool_success "$start_raw"
SESSION_ID="$(printf '%s' "$start_raw" | extract_tool_json | jq -r '.result.session_id')"
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  echo "FAIL: could not parse session_id"
  printf '%s\n' "$start_raw"
  exit 1
fi

printf '[4/6] record collaboration turn\n'
step_raw="$(call_tool 4 "masc_team_session_step" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s,turn_kind:"broadcast",message:"[smoke] collaboration evidence broadcast"}')")"
require_tool_success "$step_raw"

printf '[5/6] verify surface readiness projection\n'
readiness_json="$(curl -fsS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" "http://127.0.0.1:${PORT}/api/v1/dashboard/surface-readiness")"
if ! printf '%s' "$readiness_json" | jq -e '
  .proof_bar == "fixture+live_spotcheck"
  and any(.surfaces[]; .id == "command.namespace" and .exposure_status == "lab" and .hidden_from_nav == true and .meets_main_gate == false)
' >/dev/null 2>&1; then
  echo "FAIL: surface readiness projection mismatch"
  printf '%s\n' "$readiness_json" | jq .
  exit 1
fi

printf '[6/6] verify collaboration evidence projection\n'
evidence_json="$(curl -fsS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" "http://127.0.0.1:${PORT}/api/v1/dashboard/collaboration-evidence?session_id=${SESSION_ID}")"
if ! printf '%s' "$evidence_json" | jq -e '
  .evidence_status == "strong"
  and .counts.team_turn_count >= 1
  and .counts.session_broadcast_count >= 1
  and .proof.available == true
' >/dev/null 2>&1; then
  echo "FAIL: collaboration evidence projection mismatch"
  printf '%s\n' "$evidence_json" | jq .
  exit 1
fi

printf '\nPASS dashboard collaboration evidence smoke\n'
printf '  session_id: %s\n' "$SESSION_ID"
printf '  base_path: %s\n' "$BASE_PATH"
printf '  log_file: %s\n' "$LOG_FILE"
printf '  readiness: %s\n' "$(printf '%s' "$readiness_json" | jq -c '.surfaces[] | select(.id == "command.namespace") | {id, exposure_status, hidden_from_nav, meets_main_gate}')"
printf '  evidence: %s\n' "$(printf '%s' "$evidence_json" | jq -c '{evidence_status, counts, proof}')"
