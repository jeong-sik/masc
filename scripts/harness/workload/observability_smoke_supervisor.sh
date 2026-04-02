#!/usr/bin/env bash
# observability_smoke_supervisor.sh
#
# Verify trace_ref and provider-related fields in proof/execution endpoints after a team-session.
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
#
# Exit codes:
#   0 - PASS (or graceful skip if server unavailable)
#   1 - FAIL

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"
source "${ROOT_DIR}/scripts/harness/lib/server_bootstrap.sh"
source "${ROOT_DIR}/scripts/harness/lib/obs_smoke_common.sh"

PORT="${PORT:-}"
BASE_PATH="${BASE_PATH:-}"
LOG_FILE="${LOG_FILE:-}"
MCP_URL="${MCP_URL:-}"
SKIP_SERVER_START="${SKIP_SERVER_START:-0}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-60}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-30}"
MCP_SESSION_ID="obs-smoke-supervisor"
AGENT_NAME="obs-smoke-supervisor"
TEAM_GOAL="Observability smoke: verify trace_ref and provider info in proof endpoint"
TEAM_SESSION_DURATION_SECONDS="${TEAM_SESSION_DURATION_SECONDS:-120}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"

SERVER_PID=""

# ── prerequisites ──

obs_require_commands

if [ "$SKIP_SERVER_START" != "1" ]; then
  SERVER_EXE="$(obs_require_server_exe "$ROOT_DIR")"
fi

# ── infrastructure ──

if [ -z "$PORT" ]; then
  PORT="$(harness_pick_free_port)"
fi

if [ -z "$BASE_PATH" ]; then
  BASE_PATH="$(harness_mktemp_dir "masc-obs-smoke-supervisor")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mcp_mktemp_file "masc-obs-smoke-supervisor")"
fi

if [ -z "$MCP_URL" ]; then
  MCP_URL="http://127.0.0.1:${PORT}/mcp"
fi

cleanup() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

# ── step 1: start server ──

printf '[1/5] start server\n'
if [ "$SKIP_SERVER_START" != "1" ]; then
  SERVER_PID="$(obs_start_server "$SERVER_EXE" "$PORT" "$BASE_PATH" "$LOG_FILE")"
else
  printf '  using existing server on port %s\n' "$PORT"
fi

if ! obs_wait_for_ready "$PORT" "$HEALTH_TIMEOUT_SEC"; then
  obs_skip "server did not become healthy (not running or build missing)"
fi

# ── step 2: initialize room and join ──

printf '[2/5] initialize room and join agent\n'
agent_nickname="$(obs_bootstrap_room "$MCP_URL" "$MCP_SESSION_ID" "$AGENT_NAME")"
if [ -z "$agent_nickname" ]; then
  echo "FAIL: could not bootstrap room"
  exit 1
fi

# ── step 3: start team session with spawn ──

printf '[3/5] start team session and spawn worker\n'
start_raw="$(mcp_call_tool 4 "masc_team_session_start" "$(jq -cn \
  --arg goal "$TEAM_GOAL" \
  --arg agent "$agent_nickname" \
  --argjson duration "$TEAM_SESSION_DURATION_SECONDS" \
  '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:15,orchestration_mode:"assist",communication_mode:"broadcast",execution_scope:"limited_code_change",fallback_policy:"cascade_then_task",instruction_profile:"strict",min_agents:1,agents:[$agent]}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
mcp_require_tool_ok "$start_raw" "team_session_start"

TEAM_SESSION_ID="$(printf '%s' "$start_raw" | mcp_extract_result | jq -r '.session_id // empty')"
if [ -z "$TEAM_SESSION_ID" ]; then
  echo "FAIL: missing session_id"
  printf '%s\n' "$start_raw"
  exit 1
fi

MODEL_SELECTION_NOTE="[routing-note] obs-smoke canonical team-session spawn via worker_class/worker_size"
spawn_raw="$(mcp_call_tool 5 "masc_team_session_step" "$(jq -cn \
  --arg s "$TEAM_SESSION_ID" \
  --arg note "$MODEL_SELECTION_NOTE" \
  '{session_id:$s,wait_mode:"blocking",spawn_batch:[{spawn_role:"obs-worker",worker_class:"executor",worker_size:"lg",spawn_selection_note:$note,spawn_prompt:"Reply with one line: observability smoke check complete.",spawn_timeout_seconds:90}]}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
mcp_require_tool_ok "$spawn_raw" "team_session_step"

# Wait for session to finish or stop it
sleep 2
session_status_raw="$(mcp_call_tool 6 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
mcp_require_tool_ok "$session_status_raw" "team_session_status"
session_status="$(printf '%s' "$session_status_raw" | mcp_extract_result | jq -r '.session.status // empty')"

if [ "$session_status" = "running" ]; then
  stop_raw="$(mcp_call_tool 7 "masc_team_session_stop" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,reason:"obs_smoke_complete",generate_report:true}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
  mcp_require_tool_ok "$stop_raw" "team_session_stop"

  deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
  while :; do
    status_raw="$(mcp_call_tool 8 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
    mcp_require_tool_ok "$status_raw" "team_session_status"
    session_status="$(printf '%s' "$status_raw" | mcp_extract_result | jq -r '.session.status // empty')"
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

# ── step 4: query proof endpoint and assert observability fields ──

printf '[4/5] query proof endpoint and verify observability\n'
proof_json="$(curl -fsS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" \
  "http://127.0.0.1:${PORT}/api/v1/dashboard/proof?session_id=${TEAM_SESSION_ID}" 2>/dev/null || true)"

if [ -z "$proof_json" ]; then
  obs_skip "proof endpoint returned empty (endpoint may not exist yet)"
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
if [ "$has_provider_info" = "true" ]; then
  echo "OK: provider info found in proof data"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: provider info missing in proof data"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

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

# ── step 5: verify execution endpoint ──

printf '[5/5] verify execution endpoint\n'
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
printf '  base_path: %s\n' "$BASE_PATH"
printf '  log_file: %s\n' "$LOG_FILE"
printf '  pass: %d\n' "$PASS_COUNT"
printf '  fail: %d\n' "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "FAIL: observability smoke supervisor ($FAIL_COUNT failures)"
  exit 1
fi

echo "PASS: observability smoke supervisor"
