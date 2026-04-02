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
  BASE_PATH="$(harness_mktemp_dir "masc-obs-smoke-swarm")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mcp_mktemp_file "masc-obs-smoke-swarm")"
fi

if [ -z "$MCP_URL" ]; then
  MCP_URL="http://127.0.0.1:${PORT}/mcp"
fi
OPERATOR_URL="http://127.0.0.1:${PORT}/mcp/operator"

# Swarm cleanup: stop keepers before killing server
cleanup() {
  if [ -n "$SERVER_PID" ] || [ "$SKIP_SERVER_START" = "1" ]; then
    mcp_call_tool 90 "masc_keeper_down" "$(jq -cn '{name:"obs-keeper-a"}')" "$MCP_SESSION_ID" "" "$MCP_URL" >/dev/null 2>&1 || true
    mcp_call_tool 91 "masc_keeper_down" "$(jq -cn '{name:"obs-keeper-b"}')" "$MCP_SESSION_ID" "" "$MCP_URL" >/dev/null 2>&1 || true
  fi
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
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
agent_nickname="$(obs_bootstrap_room "$MCP_URL" "$MCP_SESSION_ID" "$AGENT_NAME" '["supervisor","operator"]')"
if [ -z "$agent_nickname" ]; then
  echo "FAIL: could not bootstrap room"
  exit 1
fi

# ── step 3: start two keepers with different cascades ──

printf '[3/5] start keepers with different cascade profiles\n'
printf '  keeper-a cascade: %s\n' "$KEEPER_A_CASCADE"
printf '  keeper-b cascade: %s\n' "$KEEPER_B_CASCADE"

keeper_a_raw="$(mcp_call_tool 10 "masc_keeper_up" "$(jq -cn \
  --arg name "obs-keeper-a" \
  --arg goal "Observability smoke keeper A" \
  --arg cascade "$KEEPER_A_CASCADE" \
  '{name:$name,goal:$goal,cascade_name:$cascade}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
mcp_require_tool_ok "$keeper_a_raw" "keeper_a_up"

keeper_b_raw="$(mcp_call_tool 11 "masc_keeper_up" "$(jq -cn \
  --arg name "obs-keeper-b" \
  --arg goal "Observability smoke keeper B" \
  --arg cascade "$KEEPER_B_CASCADE" \
  '{name:$name,goal:$goal,cascade_name:$cascade}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
mcp_require_tool_ok "$keeper_b_raw" "keeper_b_up"

# ── step 4: send a message to each keeper ──

printf '[4/5] send messages to keepers\n'
# Save original timeout and use keeper-specific timeout
ORIG_HTTP_TIMEOUT_SEC="$HTTP_TIMEOUT_SEC"
HTTP_TIMEOUT_SEC="$KEEPER_MSG_TIMEOUT_SEC"

msg_a_raw="$(mcp_call_tool 20 "masc_keeper_msg" "$(jq -cn \
  --arg name "obs-keeper-a" \
  --arg msg "Reply with one word: ping" \
  '{name:$name,message:$msg}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
# Keeper msg may fail if LLM is not available -- that is acceptable
msg_a_ok=0
if printf '%s' "$msg_a_raw" | jq -e '.result.isError != true' >/dev/null 2>&1; then
  msg_a_ok=1
  printf '  keeper-a replied\n'
else
  printf '  keeper-a failed to reply (LLM may be unavailable)\n'
fi

msg_b_raw="$(mcp_call_tool 21 "masc_keeper_msg" "$(jq -cn \
  --arg name "obs-keeper-b" \
  --arg msg "Reply with one word: pong" \
  '{name:$name,message:$msg}')" "$MCP_SESSION_ID" "" "$MCP_URL")"
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
snapshot_raw="$(mcp_call_tool 30 "masc_operator_snapshot" "$(jq -cn --arg actor "$agent_nickname" '{actor:$actor,view:"full"}')" "$MCP_SESSION_ID" "" "$OPERATOR_URL")"
mcp_require_tool_ok "$snapshot_raw" "operator_snapshot"

snapshot_result="$(printf '%s' "$snapshot_raw" | mcp_extract_result)"

# Extract keeper rows from snapshot
keeper_rows="$(printf '%s' "$snapshot_result" | jq -c '
  [(.keepers.items // [])[] | select(.name | startswith("obs-keeper-"))]
' 2>/dev/null || echo "[]")"

keeper_count="$(printf '%s' "$keeper_rows" | jq 'length')"
printf '  keeper rows found: %s\n' "$keeper_count"

# Assert: both keepers are visible in the snapshot
assert_gte "$keeper_count" 2 "keeper_count_in_snapshot"

# Extract cascade_name diversity
cascade_names="$(printf '%s' "$keeper_rows" | jq -r '[.[].cascade_name // empty] | unique | .[]' 2>/dev/null || true)"
cascade_count="$(printf '%s' "$keeper_rows" | jq '[.[].cascade_name // empty] | unique | length' 2>/dev/null || echo "0")"

printf '  cascade names: %s\n' "$(echo "$cascade_names" | tr '\n' ', ')"

if [ "$KEEPER_A_CASCADE" != "$KEEPER_B_CASCADE" ]; then
  assert_gte "$cascade_count" 2 "distinct_cascade_names"
else
  assert_gte "$cascade_count" 1 "distinct_cascade_names"
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
