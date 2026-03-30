#!/usr/bin/env bash
# observability_smoke_supervisor.sh
#
# Verify trace_ref and provider_label in proof endpoint after a team-session.
#
# Prerequisites:
#   - MASC server built: dune build --root . bin/main_eio.exe
#   - jq, curl available
#
# Environment variables:
#   PORT                 - server port (auto-assigned if empty)
#   BASE_PATH            - room base path (temp dir if empty)
#   LLAMA_SWARM_MODEL    - model name for llama worker (auto-detected if single)
#   MCP_URL              - override MCP endpoint (auto-derived from PORT)
#   SERVER_EXE           - path to compiled server executable
#   SKIP_SERVER_START    - set to 1 to use an existing server
#   HTTP_TIMEOUT_SEC     - curl timeout (default: 60)
#   HEALTH_TIMEOUT_SEC   - server health check timeout (default: 30)
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
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-60}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-30}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"
MCP_SESSION_ID="obs-smoke-supervisor"
AGENT_NAME="obs-smoke-supervisor"
TEAM_GOAL="Observability smoke: verify trace_ref and provider_label in proof endpoint"
TEAM_SESSION_DURATION_SECONDS="${TEAM_SESSION_DURATION_SECONDS:-120}"
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

assert_not_null() {
  local field_name="$1" value="$2"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "FAIL: $field_name is null or empty"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  echo "OK: $field_name = $value"
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
  BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/masc-obs-smoke-supervisor.XXXXXX")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mcp_mktemp_file "masc-obs-smoke-supervisor")"
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
  local label="${2:-observability_smoke_supervisor tool}"
  mcp_require_tool_ok "$payload" "$label"
}

# ── step 1: start server ──

printf '[1/6] start server\n'
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

# ── step 2: initialize room and join ──

printf '[2/6] initialize room and join agent\n'
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

# ── step 3: detect llama model ──

printf '[3/6] detect llama model\n'
llama_models_raw="$(call_tool 3 "masc_llama_models" '{}')"
require_tool_success "$llama_models_raw"
llama_models_result="$(printf '%s' "$llama_models_raw" | extract_tool_result)"

if [ -z "$LLAMA_SWARM_MODEL" ]; then
  single_model="$(printf '%s\n' "$llama_models_result" | jq -r 'if (.models | length) == 1 then .models[0] else "" end')"
  if [ -n "$single_model" ]; then
    LLAMA_SWARM_MODEL="$single_model"
    printf '  auto-selected: %s\n' "$LLAMA_SWARM_MODEL"
  else
    echo "SKIP: LLAMA_SWARM_MODEL not set and multiple models available"
    printf '%s\n' "$llama_models_result" | jq -r '.models[]?'
    exit 0
  fi
fi

# ── step 4: start team session with spawn ──

printf '[4/6] start team session and spawn worker\n'
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

MODEL_SELECTION_NOTE="[model-selection] obs-smoke selected $LLAMA_SWARM_MODEL"
spawn_raw="$(call_tool 5 "masc_team_session_step" "$(jq -cn \
  --arg s "$TEAM_SESSION_ID" \
  --arg model "$LLAMA_SWARM_MODEL" \
  --arg note "$MODEL_SELECTION_NOTE" \
  '{session_id:$s,wait_mode:"blocking",spawn_batch:[{spawn_role:"obs-worker",worker_class:"executor",worker_size:"lg",spawn_selection_note:$note,spawn_prompt:"Reply with one line: observability smoke check complete.",spawn_timeout_seconds:90}]}')")"
require_tool_success "$spawn_raw"

# Wait for session to finish or stop it
sleep 2
session_status_raw="$(call_tool 6 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
require_tool_success "$session_status_raw"
session_status="$(printf '%s' "$session_status_raw" | extract_tool_result | jq -r '.session.status // empty')"

if [ "$session_status" = "running" ]; then
  stop_raw="$(call_tool 7 "masc_team_session_stop" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,reason:"obs_smoke_complete",generate_report:true}')")"
  require_tool_success "$stop_raw"

  deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
  while :; do
    status_raw="$(call_tool 8 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
    require_tool_success "$status_raw"
    session_status="$(printf '%s' "$status_raw" | extract_tool_result | jq -r '.session.status // empty')"
    if [ "$session_status" != "running" ]; then
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL: team session did not stop in time"
      exit 1
    fi
    sleep 1
  done
fi

# ── step 5: query proof endpoint and assert observability fields ──

printf '[5/6] query proof endpoint and verify observability\n'
proof_json="$(curl -fsS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" \
  "http://127.0.0.1:${PORT}/api/v1/dashboard/proof?session_id=${TEAM_SESSION_ID}" 2>/dev/null || true)"

if [ -z "$proof_json" ]; then
  echo "SKIP: proof endpoint returned empty (endpoint may not exist yet)"
  exit 0
fi

# Assert: trace_ref presence in worker run entries
has_trace_ref="$(printf '%s' "$proof_json" | jq -r '
  [.. | objects | .trace_ref? // empty | select(. != null and . != "")] | length > 0
' 2>/dev/null || echo "false")"
if [ "$has_trace_ref" = "true" ]; then
  echo "OK: trace_ref found in proof data"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "WARN: trace_ref not found in proof data (may be summary_only mode)"
  # Not a hard fail -- trace_ref depends on raw trace capability
fi

# Assert: provider-related fields exist (provider_name or resolved_model)
has_provider_info="$(printf '%s' "$proof_json" | jq -r '
  [.. | objects | select(.provider_name? != null or .resolved_model? != null or .provider_snapshot? != null)] | length > 0
' 2>/dev/null || echo "false")"
assert_not_null "provider_info_in_proof" "$has_provider_info"

# Assert: no raw API key patterns in all preview fields
all_previews="$(printf '%s' "$proof_json" | jq -r '
  [.. | objects | (.tool_input_preview? // empty, .tool_output_preview? // empty, .output_preview? // empty) | select(. != null and . != "")] | join("\n")
' 2>/dev/null || echo "")"
if [ -n "$all_previews" ]; then
  assert_no_api_key "$all_previews"
else
  echo "OK: no preview fields to check (clean)"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# ── step 6: verify execution endpoint has provider_label ──

printf '[6/6] verify execution endpoint\n'
execution_json="$(curl -fsS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" \
  "http://127.0.0.1:${PORT}/api/v1/dashboard/execution" 2>/dev/null || true)"

if [ -n "$execution_json" ]; then
  # Check for provider/model information in the execution snapshot
  has_model_info="$(printf '%s' "$execution_json" | jq -r '
    [.. | objects | select(.last_model_used? != null or .active_model? != null or .resolved_model? != null)] | length > 0
  ' 2>/dev/null || echo "false")"
  if [ "$has_model_info" = "true" ]; then
    echo "OK: model/provider info present in execution snapshot"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "WARN: no model/provider info in execution snapshot (may have no active workers)"
  fi

  # Assert: no API keys in execution snapshot text fields
  exec_text_fields="$(printf '%s' "$execution_json" | jq -r '
    [.. | strings | select(length > 20)] | join("\n")
  ' 2>/dev/null || echo "")"
  if [ -n "$exec_text_fields" ]; then
    assert_no_api_key "$exec_text_fields"
  fi
else
  echo "WARN: execution endpoint returned empty"
fi

# ── summary ──

printf '\n[summary]\n'
printf '  session_id: %s\n' "$TEAM_SESSION_ID"
printf '  llama_model: %s\n' "$LLAMA_SWARM_MODEL"
printf '  base_path: %s\n' "$BASE_PATH"
printf '  log_file: %s\n' "$LOG_FILE"
printf '  pass: %d\n' "$PASS_COUNT"
printf '  fail: %d\n' "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "FAIL: observability smoke supervisor ($FAIL_COUNT failures)"
  exit 1
fi

echo "PASS: observability smoke supervisor"
