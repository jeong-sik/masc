#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/jsonrpc_sse.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
AGENT_NAME="${AGENT_NAME:-team-session-soak}"
ROUNDS="${ROUNDS:-5}"
DURATION_SEC="${DURATION_SEC:-120}"
SLEEP_SEC="${SLEEP_SEC:-1}"
MCP_SESSION_ID="${MCP_SESSION_ID:-team-session-soak-$(date +%s)-$RANDOM}"

call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local raw
  local sse_data
  local attempts=0
  local max_attempts=4
  raw=""
  while [ "$attempts" -lt "$max_attempts" ]; do
    if raw="$(curl -sS -m 25 -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "mcp-session-id: $MCP_SESSION_ID" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}" 2>/dev/null)"; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  if [ -z "$raw" ]; then
    echo "{\"error\":\"curl_failed\"}"
    return 1
  fi
  jsonrpc_normalize_response "$raw" "$id"
}

extract_result() {
  jq -c 'try (.result.content[0].text | fromjson | .result) catch empty'
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

_="$(call_tool 4201 "masc_init" "{\"agent_name\":\"$AGENT_NAME\"}")"
_="$(call_tool 4202 "masc_join" "{\"agent_name\":\"$AGENT_NAME\",\"capabilities\":[\"soak\",\"team-session\"]}")"

success=0
failure=0
for i in $(seq 1 "$ROUNDS"); do
  echo "[soak] round=$i/$ROUNDS"
  start_args="$(jq -cn --arg goal "soak-round-$i" --argjson duration "$DURATION_SEC" '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:10,min_agents:1,orchestration_mode:"assist",communication_mode:"hybrid",model_cascade:["glm:glm-5"],fallback_policy:"cascade_then_task",instruction_profile:"standard",alert_channel:"both"}')"
  start_raw="$(call_tool $((4300 + i)) "masc_team_session_start" "$start_args")"
  session_id="$(printf "%s" "$start_raw" | extract_result | jq -r '.session_id // empty')"
  if [ -z "$session_id" ]; then
    echo "[soak] FAIL start round=$i"
    failure=$((failure + 1))
    continue
  fi

  status_raw="$(call_tool $((4400 + i)) "masc_team_session_status" "{\"session_id\":\"$session_id\"}")"
  if ! printf "%s" "$status_raw" | extract_result | jq -e '.team_health and .communication_metrics and .cascade_metrics and .inference_cache_metrics' >/dev/null 2>&1; then
    echo "[soak] FAIL status round=$i session=$session_id"
    failure=$((failure + 1))
    continue
  fi

  _="$(call_tool $((4500 + i)) "masc_team_session_stop" "{\"session_id\":\"$session_id\",\"reason\":\"soak_round_done\",\"generate_report\":false}")"
  success=$((success + 1))
  sleep "$SLEEP_SEC"
done

list_raw="$(call_tool 4998 "masc_team_session_list" "{\"limit\":50}")"
count="$(printf "%s" "$list_raw" | extract_result | jq -r '.count // 0')"

_="$(call_tool 4999 "masc_leave" "{\"agent_name\":\"$AGENT_NAME\"}")"

echo "[soak] success=$success failure=$failure listed_sessions=$count"
if [ "$failure" -gt 0 ]; then
  exit 1
fi

echo "PASS: team_session soak workload"
