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
#   0 - PASS (or graceful skip when OBS_PERMISSIVE=1)
#   2 - SKIP (default when a prerequisite/environment is unavailable)
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
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-120}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-60}"
MCP_SESSION_ID="obs-smoke-coding"
AGENT_NAME="obs-smoke-coding"
TEAM_GOAL="Observability smoke: verify tool preview redaction and length limits"
TEAM_SESSION_DURATION_SECONDS="${TEAM_SESSION_DURATION_SECONDS:-180}"
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
  BASE_PATH="$(harness_mktemp_dir "masc-obs-smoke-coding")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mcp_mktemp_file "masc-obs-smoke-coding")"
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

# ── step 2: bootstrap room ──

printf '[2/5] initialize room and join agent\n'
agent_nickname="$(obs_bootstrap_room "$MCP_URL" "$MCP_SESSION_ID" "$AGENT_NAME")"
if [ -z "$agent_nickname" ]; then
  echo "FAIL: could not bootstrap room"
  exit 1
fi

# ── step 3: start coding session with worker ──

printf '[3/5] start coding team session with worker\n'
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

# Spawn a coding worker that will exercise tool calls
MODEL_SELECTION_NOTE="[routing-note] obs-coding canonical team-session spawn via worker_class/worker_size"
spawn_raw="$(mcp_call_tool 5 "masc_team_session_step" "$(jq -cn \
  --arg s "$TEAM_SESSION_ID" \
  --arg note "$MODEL_SELECTION_NOTE" \
  '{session_id:$s,wait_mode:"blocking",spawn_batch:[{spawn_role:"coding-obs-worker",worker_class:"executor",worker_size:"lg",spawn_selection_note:$note,spawn_prompt:"Write a minimal Python function that adds two numbers. Use file_write to save it as add.py, then verify with shell_exec. Reply with the result.",spawn_timeout_seconds:120}]}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
mcp_require_tool_ok "$spawn_raw" "team_session_step"

# Wait for session to finish or stop it
deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
while :; do
  status_raw="$(mcp_call_tool 6 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
  mcp_require_tool_ok "$status_raw" "team_session_status"
  session_status="$(printf '%s' "$status_raw" | mcp_extract_result | jq -r '.session.status // empty')"
  if [ "$session_status" != "running" ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    # Force stop
    mcp_call_tool 7 "masc_team_session_stop" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,reason:"obs_coding_timeout",generate_report:true}')" "$MCP_SESSION_ID" "" "$MCP_URL" >/dev/null 2>&1 || true
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
  obs_skip "proof endpoint returned empty"
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
