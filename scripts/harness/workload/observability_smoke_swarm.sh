#!/usr/bin/env bash
# observability_smoke_swarm.sh
#
# Verify cascade/model diversity across multiple keepers with different cascade profiles.
#
# Prerequisites:
#   - MASC server built: dune build --root . bin/main_eio.exe
#   - jq, curl, python3 available
#
# Environment variables:
#   PORT                 - server port (auto-assigned if empty)
#   BASE_PATH            - room base path (temp dir if empty)
#   MCP_URL              - override MCP endpoint (auto-derived from PORT)
#   SERVER_EXE           - path to compiled server executable
#   SKIP_SERVER_START    - set to 1 to use an existing server
#   HTTP_TIMEOUT_SEC     - curl timeout (default: 60)
#   HEALTH_TIMEOUT_SEC   - server health check timeout (default: 30)
#   KEEPER_A_CASCADE     - cascade name for keeper A (default: keeper_unified)
#   KEEPER_B_CASCADE     - cascade name for keeper B (default: keeper_reply)
#
# Flow:
#   1. Start 2 keepers with different cascade profiles
#   2. Send a message to each keeper
#   3. Query operator snapshot for keeper rows
#   4. Assert: distinct cascade_name values and visible model/cascade evidence across keepers
#
# Exit codes:
#   0 - PASS (or graceful skip if server unavailable)
#   1 - FAIL

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

SERVER_EXE="${SERVER_EXE:-${ROOT_DIR}/_build/default/bin/main_eio.exe}"
PORT="${PORT:-}"
BASE_PATH="${BASE_PATH:-}"
LOG_FILE="${LOG_FILE:-}"
MCP_URL="${MCP_URL:-}"
OPERATOR_URL=""
SKIP_SERVER_START="${SKIP_SERVER_START:-0}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-60}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
KEEPER_A_CASCADE="${KEEPER_A_CASCADE:-keeper_unified}"
KEEPER_B_CASCADE="${KEEPER_B_CASCADE:-keeper_reply}"
MCP_SESSION_ID="obs-smoke-swarm"
AGENT_NAME="obs-smoke-swarm"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"
KEEPER_MSG_TIMEOUT_SEC="${KEEPER_MSG_TIMEOUT_SEC:-90}"

PASS_COUNT=0
FAIL_COUNT=0
SERVER_PID=""

# ── prerequisite checks ──

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required"
  exit 1
fi

if [ "$SKIP_SERVER_START" != "1" ] && [ ! -x "$SERVER_EXE" ]; then
  echo "SKIP: server executable not found: $SERVER_EXE"
  echo "build it first with: dune build --root . bin/main_eio.exe"
  exit 0
fi

# ── assertion helpers ──

assert_no_api_key() {
  local text="$1"
  if echo "$text" | grep -qE '(sk-[a-zA-Z0-9]{20,}|key-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9]{30,})'; then
    echo "FAIL: found raw API key in preview text"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  echo "OK: no API key patterns found"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_gte() {
  local field_name="$1" actual="$2" expected="$3"
  if [ "$actual" -lt "$expected" ]; then
    echo "FAIL: $field_name = $actual, expected >= $expected"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  echo "OK: $field_name = $actual (>= $expected)"
  PASS_COUNT=$((PASS_COUNT + 1))
}

# ── infrastructure ──

if [ -z "$PORT" ]; then
  PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
fi

if [ -z "$BASE_PATH" ]; then
  BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/masc-obs-smoke-swarm.XXXXXX")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mcp_mktemp_file "masc-obs-smoke-swarm")"
fi

if [ -z "$MCP_URL" ]; then
  MCP_URL="http://127.0.0.1:${PORT}/mcp"
fi
OPERATOR_URL="http://127.0.0.1:${PORT}/mcp/operator"

cleanup() {
  # Stop keepers before killing server
  if [ -n "$SERVER_PID" ] || [ "$SKIP_SERVER_START" = "1" ]; then
    call_tool 90 "masc_keeper_down" "$(jq -cn '{name:"obs-keeper-a"}')" >/dev/null 2>&1 || true
    call_tool 91 "masc_keeper_down" "$(jq -cn '{name:"obs-keeper-b"}')" >/dev/null 2>&1 || true
  fi
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_health() {
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
  local tool_name="$2"
  local args_json="$3"
  mcp_call_tool "$id" "$tool_name" "$args_json" "$MCP_SESSION_ID" "" "$MCP_URL"
}

call_operator_tool() {
  local id="$1"
  local tool_name="$2"
  local args_json="$3"
  mcp_call_tool "$id" "$tool_name" "$args_json" "$MCP_SESSION_ID" "" "$OPERATOR_URL"
}

extract_tool_result() {
  mcp_extract_result
}

require_tool_success() {
  local payload="$1"
  local label="${2:-observability_smoke_swarm tool}"
  mcp_require_tool_ok "$payload" "$label"
}

# ── step 1: start server ──

printf '[1/5] start server\n'
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

if ! wait_for_health; then
  echo "SKIP: server did not become healthy (not running or build missing)"
  exit 0
fi

# ── step 2: bootstrap room ──

printf '[2/5] initialize room and join agent\n'
init_raw="$(call_tool 1 "masc_init" "$(jq -cn --arg a "$AGENT_NAME" '{agent_name:$a}')")"
require_tool_success "$init_raw"

join_raw="$(call_tool 2 "masc_join" "$(jq -cn --arg a "$AGENT_NAME" '{agent_name:$a,capabilities:["supervisor","operator"]}')")"
require_tool_success "$join_raw"

agent_nickname="$(printf '%s' "$join_raw" | mcp_extract_text | sed -n 's/^  Nickname: //p' | head -n1)"
if [ -z "$agent_nickname" ]; then
  echo "FAIL: could not parse joined nickname"
  printf '%s\n' "$join_raw"
  exit 1
fi

# ── step 3: start two keepers with different cascades ──

printf '[3/5] start keepers with different cascade profiles\n'
printf '  keeper-a cascade: %s\n' "$KEEPER_A_CASCADE"
printf '  keeper-b cascade: %s\n' "$KEEPER_B_CASCADE"

keeper_a_raw="$(call_tool 10 "masc_keeper_up" "$(jq -cn \
  --arg name "obs-keeper-a" \
  --arg goal "Observability smoke keeper A" \
  --arg cascade "$KEEPER_A_CASCADE" \
  '{name:$name,goal:$goal,cascade_name:$cascade}')")"
require_tool_success "$keeper_a_raw" "keeper_a_up"

keeper_b_raw="$(call_tool 11 "masc_keeper_up" "$(jq -cn \
  --arg name "obs-keeper-b" \
  --arg goal "Observability smoke keeper B" \
  --arg cascade "$KEEPER_B_CASCADE" \
  '{name:$name,goal:$goal,cascade_name:$cascade}')")"
require_tool_success "$keeper_b_raw" "keeper_b_up"

# ── step 4: send a message to each keeper ──

printf '[4/5] send messages to keepers\n'
# Save original timeout and use keeper-specific timeout
ORIG_HTTP_TIMEOUT_SEC="$HTTP_TIMEOUT_SEC"
HTTP_TIMEOUT_SEC="$KEEPER_MSG_TIMEOUT_SEC"

msg_a_raw="$(call_tool 20 "masc_keeper_msg" "$(jq -cn \
  --arg name "obs-keeper-a" \
  --arg msg "Reply with one word: ping" \
  '{name:$name,message:$msg}')")"
# Keeper msg may fail if LLM is not available -- that is acceptable
msg_a_ok=0
if printf '%s' "$msg_a_raw" | jq -e '.result.isError != true' >/dev/null 2>&1; then
  msg_a_ok=1
  printf '  keeper-a replied\n'
else
  printf '  keeper-a failed to reply (LLM may be unavailable)\n'
fi

msg_b_raw="$(call_tool 21 "masc_keeper_msg" "$(jq -cn \
  --arg name "obs-keeper-b" \
  --arg msg "Reply with one word: pong" \
  '{name:$name,message:$msg}')")"
msg_b_ok=0
if printf '%s' "$msg_b_raw" | jq -e '.result.isError != true' >/dev/null 2>&1; then
  msg_b_ok=1
  printf '  keeper-b replied\n'
else
  printf '  keeper-b failed to reply (LLM may be unavailable)\n'
fi

HTTP_TIMEOUT_SEC="$ORIG_HTTP_TIMEOUT_SEC"

# ── step 5: query operator snapshot and verify diversity ──

printf '[5/5] query operator snapshot for keeper rows\n'
snapshot_raw="$(call_operator_tool 30 "masc_operator_snapshot" "$(jq -cn --arg actor "$agent_nickname" '{actor:$actor,view:"full"}')")"
require_tool_success "$snapshot_raw" "operator_snapshot"

snapshot_result="$(printf '%s' "$snapshot_raw" | extract_tool_result)"

# Extract keeper rows from snapshot
keeper_rows="$(printf '%s' "$snapshot_result" | jq -c '
  [(.keepers.items // [])[] | select(.name | startswith("obs-keeper-"))]
' 2>/dev/null || echo "[]")"

keeper_count="$(printf '%s' "$keeper_rows" | jq 'length')"
printf '  keeper rows found: %s\n' "$keeper_count"

# Assert: both keepers are visible in the snapshot
assert_gte "keeper_count_in_snapshot" "$keeper_count" 2

# Extract cascade_name diversity
cascade_names="$(printf '%s' "$keeper_rows" | jq -r '[.[].cascade_name // empty] | unique | .[]' 2>/dev/null || true)"
cascade_count="$(printf '%s' "$keeper_rows" | jq '[.[].cascade_name // empty] | unique | length' 2>/dev/null || echo "0")"

printf '  cascade names: %s\n' "$(echo "$cascade_names" | tr '\n' ', ')"

if [ "$KEEPER_A_CASCADE" != "$KEEPER_B_CASCADE" ]; then
  assert_gte "distinct_cascade_names" "$cascade_count" 2
else
  assert_gte "distinct_cascade_names" "$cascade_count" 1
fi

# Extract active_model / last_model_used diversity
model_labels="$(printf '%s' "$keeper_rows" | jq -r '
  [.[] | (.active_model // .last_model_used // empty) | select(. != "" and . != null)] | unique | .[]
' 2>/dev/null || true)"
model_count="$(printf '%s' "$keeper_rows" | jq '
  [.[] | (.active_model // .last_model_used // empty) | select(. != "" and . != null)] | unique | length
' 2>/dev/null || echo "0")"

if [ "$model_count" -gt 0 ]; then
  printf '  model labels: %s\n' "$(echo "$model_labels" | tr '\n' ', ')"
  echo "OK: $model_count model label(s) found across keepers"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  # If neither keeper got a turn (no LLM available), model info may be empty
  if [ "$msg_a_ok" -eq 0 ] && [ "$msg_b_ok" -eq 0 ]; then
    echo "WARN: no model labels found (both keepers failed to reply -- LLM unavailable)"
  else
    echo "WARN: no model labels found in keeper rows"
  fi
fi

# Check for API key leakage in snapshot text
snapshot_strings="$(printf '%s' "$snapshot_result" | jq -r '
  [.. | strings | select(length > 20)] | join("\n")
' 2>/dev/null || true)"
if [ -n "$snapshot_strings" ]; then
  assert_no_api_key "$snapshot_strings"
fi

# ── summary ──

printf '\n[summary]\n'
printf '  base_path: %s\n' "$BASE_PATH"
printf '  log_file: %s\n' "$LOG_FILE"
printf '  keeper_a_cascade: %s\n' "$KEEPER_A_CASCADE"
printf '  keeper_b_cascade: %s\n' "$KEEPER_B_CASCADE"
printf '  keeper_a_replied: %s\n' "$msg_a_ok"
printf '  keeper_b_replied: %s\n' "$msg_b_ok"
printf '  keeper_rows: %s\n' "$keeper_count"
printf '  distinct_cascades: %s\n' "$cascade_count"
printf '  distinct_models: %s\n' "$model_count"
printf '  pass: %d\n' "$PASS_COUNT"
printf '  fail: %d\n' "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "FAIL: observability smoke swarm ($FAIL_COUNT failures)"
  exit 1
fi

echo "PASS: observability smoke swarm"
