#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
AGENT_NAME="${AGENT_NAME:-team-session-harness}"
DURATION_SEC="${DURATION_SEC:-120}"

curl_post_mcp() {
  local body="$1"
  local attempts=0
  local max_attempts=4
  local output=""
  while [ "$attempts" -lt "$max_attempts" ]; do
    if output="$(curl -sS -m 25 -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d "$body" 2>/dev/null)"; then
      printf "%s" "$output"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  return 1
}

call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local raw
  local sse_data

  raw="$(curl_post_mcp "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}")"

  sse_data="$(printf "%s" "$raw" | sed -n 's/^data: //p' | tail -n1)"
  if [ -n "$sse_data" ]; then
    printf "%s" "$sse_data"
  else
    printf "%s" "$raw"
  fi
}

extract_result() {
  jq -c 'try (.result.content[0].text | fromjson | .result) catch empty'
}

extract_error() {
  jq -r 'try (.result.content[0].text | fromjson | .message) catch (.error.message // "")'
}

require_ok() {
  local payload="$1"
  if ! printf "%s" "$payload" | jq -e . >/dev/null 2>&1; then
    echo "FAIL: invalid json payload"
    printf "%s\n" "$payload"
    exit 1
  fi
}

echo "[1/9] masc_init"
r1="$(call_tool 4101 "masc_init" "{\"agent_name\":\"$AGENT_NAME\"}")"
require_ok "$r1"

echo "[2/9] masc_join"
r2="$(call_tool 4102 "masc_join" "{\"agent_name\":\"$AGENT_NAME\",\"capabilities\":[\"qa\",\"team-session\"]}")"
require_ok "$r2"

echo "[3/9] masc_team_session_start (base)"
start_args_base="$(jq -cn --arg goal "contract-base" --argjson duration "$DURATION_SEC" '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:10,min_agents:1,orchestration_mode:"assist",communication_mode:"hybrid",model_cascade:["glm:glm-5"],fallback_policy:"cascade_then_task",instruction_profile:"strict",alert_channel:"both",report_formats:["markdown","json"]}')"
r3="$(call_tool 4103 "masc_team_session_start" "$start_args_base")"
require_ok "$r3"
s1="$(printf "%s" "$r3" | extract_result | jq -r '.session_id // empty')"
if [ -z "$s1" ]; then
  echo "FAIL: base session_id missing"
  printf "%s\n" "$r3"
  exit 1
fi

echo "[4/9] masc_team_session_status"
r4="$(call_tool 4104 "masc_team_session_status" "{\"session_id\":\"$s1\"}")"
require_ok "$r4"
if ! printf "%s" "$r4" | extract_result | jq -e '.team_health and .communication_metrics and .orchestration_state and .cascade_metrics' >/dev/null; then
  echo "FAIL: status missing required sections"
  printf "%s\n" "$r4"
  exit 1
fi

echo "[5/9] masc_team_session_start (target)"
start_args_target="$(jq -cn --arg goal "contract-target" --argjson duration "$DURATION_SEC" '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:10,min_agents:1,orchestration_mode:"manual",communication_mode:"broadcast",model_cascade:[],fallback_policy:"task_only",instruction_profile:"standard",alert_channel:"broadcast"}')"
r5="$(call_tool 4105 "masc_team_session_start" "$start_args_target")"
require_ok "$r5"
s2="$(printf "%s" "$r5" | extract_result | jq -r '.session_id // empty')"
if [ -z "$s2" ]; then
  echo "FAIL: target session_id missing"
  printf "%s\n" "$r5"
  exit 1
fi

echo "[6/9] masc_team_session_list"
r6="$(call_tool 4106 "masc_team_session_list" "{\"limit\":10}")"
require_ok "$r6"
if ! printf "%s" "$r6" | extract_result | jq -e --arg s1 "$s1" --arg s2 "$s2" '.sessions | map(.session_id) | index($s1) != null and index($s2) != null' >/dev/null; then
  echo "FAIL: list does not include both sessions"
  printf "%s\n" "$r6"
  exit 1
fi

echo "[7/9] masc_team_session_compare"
r7="$(call_tool 4107 "masc_team_session_compare" "{\"base_session_id\":\"$s1\",\"target_session_id\":\"$s2\"}")"
require_ok "$r7"
if ! printf "%s" "$r7" | extract_result | jq -e --arg s1 "$s1" --arg s2 "$s2" '.base_session_id == $s1 and .target_session_id == $s2 and .summary and .communication and .policy' >/dev/null; then
  echo "FAIL: compare payload invalid"
  printf "%s\n" "$r7"
  exit 1
fi

echo "[8/9] masc_team_session_stop (base) + report"
_="$(call_tool 4108 "masc_team_session_stop" "{\"session_id\":\"$s1\",\"reason\":\"contract_done\",\"generate_report\":true}")"
r8_report="$(call_tool 4109 "masc_team_session_report" "{\"session_id\":\"$s1\",\"force_regenerate\":true}")"
require_ok "$r8_report"
if ! printf "%s" "$r8_report" | extract_result | jq -e '.markdown_path and .json_path' >/dev/null; then
  echo "FAIL: report paths missing"
  printf "%s\n" "$r8_report"
  exit 1
fi

echo "[9/9] cleanup stop target + leave"
_="$(call_tool 4110 "masc_team_session_stop" "{\"session_id\":\"$s2\",\"reason\":\"contract_done\",\"generate_report\":false}")"
_="$(call_tool 4111 "masc_leave" "{\"agent_name\":\"$AGENT_NAME\"}")"

echo "PASS: team_session contract harness"
