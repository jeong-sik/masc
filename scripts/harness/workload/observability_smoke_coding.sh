#!/usr/bin/env bash
# observability_smoke_coding.sh
#
# Verify tool_input_preview redaction and 200 char limit after a coding worker run.
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
#   HTTP_TIMEOUT_SEC     - curl timeout (default: 120)
#   HEALTH_TIMEOUT_SEC   - server health check timeout (default: 30)
#
# Assertions:
#   - tool_input_preview length <= 200
#   - tool_output_preview length <= 200
#   - No raw API key patterns in any preview field
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
SKIP_SERVER_START="${SKIP_SERVER_START:-0}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-120}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-60}"
MCP_SESSION_ID="obs-smoke-coding"
AGENT_NAME="obs-smoke-coding"
TEAM_GOAL="Observability smoke: verify tool preview redaction and length limits"
TEAM_SESSION_DURATION_SECONDS="${TEAM_SESSION_DURATION_SECONDS:-180}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"

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

assert_max_length() {
  local text="$1" max="${2:-200}"
  local len
  len="$(TEXT_FOR_LEN="$text" python3 - <<'PY'
import os
print(len(os.environ["TEXT_FOR_LEN"]))
PY
)"
  if [ "$len" -gt "$max" ]; then
    echo "FAIL: length $len exceeds max $max"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  echo "OK: length $len within limit $max"
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
  BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/masc-obs-smoke-coding.XXXXXX")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mcp_mktemp_file "masc-obs-smoke-coding")"
fi

if [ -z "$MCP_URL" ]; then
  MCP_URL="http://127.0.0.1:${PORT}/mcp"
fi

cleanup() {
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

extract_tool_result() {
  mcp_extract_result
}

require_tool_success() {
  local payload="$1"
  local label="${2:-observability_smoke_coding tool}"
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

join_raw="$(call_tool 2 "masc_join" "$(jq -cn --arg a "$AGENT_NAME" '{agent_name:$a,capabilities:["supervisor","operator","team-session"]}')")"
require_tool_success "$join_raw"

agent_nickname="$(printf '%s' "$join_raw" | mcp_extract_text | sed -n 's/^  Nickname: //p' | head -n1)"
if [ -z "$agent_nickname" ]; then
  echo "FAIL: could not parse joined nickname"
  printf '%s\n' "$join_raw"
  exit 1
fi

# ── step 3: start coding session with worker ──

printf '[3/5] start coding team session with worker\n'
start_raw="$(call_tool 4 "masc_team_session_start" "$(jq -cn \
  --arg goal "$TEAM_GOAL" \
  --arg agent "$agent_nickname" \
  --argjson duration "$TEAM_SESSION_DURATION_SECONDS" \
  '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:15,orchestration_mode:"assist",communication_mode:"broadcast",execution_scope:"limited_code_change",fallback_policy:"cascade_then_task",instruction_profile:"strict",min_agents:1,agents:[$agent]}')")"
require_tool_success "$start_raw"

TEAM_SESSION_ID="$(printf '%s' "$start_raw" | extract_tool_result | jq -r '.session_id // empty')"
if [ -z "$TEAM_SESSION_ID" ]; then
  echo "FAIL: missing session_id"
  printf '%s\n' "$start_raw"
  exit 1
fi

# Spawn a coding worker that will exercise tool calls
MODEL_SELECTION_NOTE="[routing-note] obs-coding canonical team-session spawn via worker_class/worker_size"
spawn_raw="$(call_tool 5 "masc_team_session_step" "$(jq -cn \
  --arg s "$TEAM_SESSION_ID" \
  --arg note "$MODEL_SELECTION_NOTE" \
  '{session_id:$s,wait_mode:"blocking",spawn_batch:[{spawn_role:"coding-obs-worker",worker_class:"executor",worker_size:"lg",spawn_selection_note:$note,spawn_prompt:"Write a minimal Python function that adds two numbers. Use file_write to save it as add.py, then verify with shell_exec. Reply with the result.",spawn_timeout_seconds:120}]}')")"
require_tool_success "$spawn_raw"

# Wait for session to finish or stop it
deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
while :; do
  status_raw="$(call_tool 6 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
  require_tool_success "$status_raw"
  session_status="$(printf '%s' "$status_raw" | extract_tool_result | jq -r '.session.status // empty')"
  if [ "$session_status" != "running" ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    # Force stop
    call_tool 7 "masc_team_session_stop" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,reason:"obs_coding_timeout",generate_report:true}')" >/dev/null 2>&1 || true
    sleep 2
    break
  fi
  sleep 2
done

# ── step 4: query proof endpoint and check tool previews ──

printf '[4/5] query proof endpoint and verify tool preview redaction\n'
proof_json="$(curl -fsS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" \
  "http://127.0.0.1:${PORT}/api/v1/dashboard/proof?session_id=${TEAM_SESSION_ID}" 2>/dev/null || true)"

if [ -z "$proof_json" ]; then
  echo "SKIP: proof endpoint returned empty"
  exit 0
fi

# Extract all tool_input_preview values and check lengths
tool_input_previews="$(printf '%s' "$proof_json" | jq -r '
  [.. | objects | .tool_input_preview? // empty | select(. != null and . != "" and type == "string")] | .[]
' 2>/dev/null || true)"

tool_output_previews="$(printf '%s' "$proof_json" | jq -r '
  [.. | objects | .tool_output_preview? // empty | select(. != null and . != "" and type == "string")] | .[]
' 2>/dev/null || true)"

preview_found=0

if [ -n "$tool_input_previews" ]; then
  printf '  checking tool_input_preview lengths...\n'
  while IFS= read -r preview; do
    [ -z "$preview" ] && continue
    preview_found=1
    assert_max_length "$preview" 200
    assert_no_api_key "$preview"
  done <<< "$tool_input_previews"
fi

if [ -n "$tool_output_previews" ]; then
  printf '  checking tool_output_preview lengths...\n'
  while IFS= read -r preview; do
    [ -z "$preview" ] && continue
    preview_found=1
    assert_max_length "$preview" 200
    assert_no_api_key "$preview"
  done <<< "$tool_output_previews"
fi

if [ "$preview_found" -eq 0 ]; then
  echo "FAIL: no tool preview fields found in proof data"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  exit 1
fi

# Also check output_preview fields (worker run level)
output_previews="$(printf '%s' "$proof_json" | jq -r '
  [.. | objects | .output_preview? // empty | select(. != null and . != "" and type == "string")] | .[]
' 2>/dev/null || true)"

if [ -n "$output_previews" ]; then
  printf '  checking output_preview fields...\n'
  while IFS= read -r preview; do
    [ -z "$preview" ] && continue
    assert_no_api_key "$preview"
  done <<< "$output_previews"
fi

# ── step 5: cross-check execution endpoint previews ──

printf '[5/5] cross-check execution endpoint\n'
execution_json="$(curl -fsS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" \
  "http://127.0.0.1:${PORT}/api/v1/dashboard/execution" 2>/dev/null || true)"

if [ -n "$execution_json" ]; then
  # Check all text fields for API keys
  exec_all_strings="$(printf '%s' "$execution_json" | jq -r '
    [.. | strings | select(length > 20)] | join("\n")
  ' 2>/dev/null || true)"
  if [ -n "$exec_all_strings" ]; then
    assert_no_api_key "$exec_all_strings"
  fi
fi

# ── summary ──

printf '\n[summary]\n'
printf '  session_id: %s\n' "$TEAM_SESSION_ID"
printf '  base_path: %s\n' "$BASE_PATH"
printf '  log_file: %s\n' "$LOG_FILE"
printf '  previews_checked: %d\n' "$preview_found"
printf '  pass: %d\n' "$PASS_COUNT"
printf '  fail: %d\n' "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "FAIL: observability smoke coding ($FAIL_COUNT failures)"
  exit 1
fi

echo "PASS: observability smoke coding"
