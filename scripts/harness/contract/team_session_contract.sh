#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-team-session-harness}"
DURATION_SEC="${DURATION_SEC:-120}"
MCP_SESSION_ID="${MCP_SESSION_ID:-team-session-contract-$(date +%s)-$RANDOM}"
export MCP_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/test_framework.sh"

echo "[1/12] masc_init"
r1="$(call_tool 4101 "masc_init" "{\"agent_name\":\"$AGENT_NAME\"}")"
require_ok "$r1"

echo "[2/12] masc_join"
r2="$(call_tool 4102 "masc_join" "{\"agent_name\":\"$AGENT_NAME\",\"capabilities\":[\"qa\",\"team-session\"]}")"
require_ok "$r2"

echo "[3/12] masc_team_session_start (base)"
start_args_base="$(jq -cn --arg goal "contract-base" --argjson duration "$DURATION_SEC" '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:10,min_agents:1,orchestration_mode:"assist",communication_mode:"hybrid",model_cascade:["glm:auto"],fallback_policy:"cascade_then_task",instruction_profile:"strict",alert_channel:"both",report_formats:["markdown","json"]}')"
r3="$(call_tool 4103 "masc_team_session_start" "$start_args_base")"
require_ok "$r3"
s1="$(printf "%s" "$r3" | extract_result | jq -r '.session_id // empty')"
if [ -z "$s1" ]; then
  echo "FAIL: base session_id missing"
  printf "%s\n" "$r3"
  exit 1
fi

echo "[4/12] masc_team_session_status"
r4="$(call_tool 4104 "masc_team_session_status" "{\"session_id\":\"$s1\"}")"
require_ok "$r4"
if ! printf "%s" "$r4" | extract_result | jq -e '.team_health and .communication_metrics and .orchestration_state and .cascade_metrics' >/dev/null; then
  echo "FAIL: status missing required sections"
  printf "%s\n" "$r4"
  exit 1
fi

echo "[5/12] masc_team_session_start (target)"
start_args_target="$(jq -cn --arg goal "contract-target" --argjson duration "$DURATION_SEC" '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:10,min_agents:1,orchestration_mode:"manual",communication_mode:"broadcast",model_cascade:[],fallback_policy:"task_only",instruction_profile:"standard",alert_channel:"broadcast"}')"
r5="$(call_tool 4105 "masc_team_session_start" "$start_args_target")"
require_ok "$r5"
s2="$(printf "%s" "$r5" | extract_result | jq -r '.session_id // empty')"
if [ -z "$s2" ]; then
  echo "FAIL: target session_id missing"
  printf "%s\n" "$r5"
  exit 1
fi

echo "[5.5/12] verify base session still running before step"
r5b="$(call_tool 4106 "masc_team_session_status" "{\"session_id\":\"$s1\"}")"
require_ok "$r5b"

echo "[6/12] masc_team_session_step + events"
r6_turn="$(call_tool 4107 "masc_team_session_step" "{\"session_id\":\"$s1\",\"turn_kind\":\"broadcast\",\"message\":\"contract turn broadcast\"}")"
require_ok "$r6_turn"
r6_events="$(call_tool 4108 "masc_team_session_events" "{\"session_id\":\"$s1\",\"event_types\":[\"team_turn\"],\"limit\":20}")"
require_ok "$r6_events"
if ! printf "%s" "$r6_events" | extract_result | jq -e '.count >= 1' >/dev/null; then
  echo "FAIL: team_turn events not found"
  printf "%s\n" "$r6_events"
  exit 1
fi

echo "[7/12] masc_team_session_list"
r6="$(call_tool 4109 "masc_team_session_list" "{\"limit\":10}")"
require_ok "$r6"
if ! printf "%s" "$r6" | extract_result | jq -e --arg s1 "$s1" --arg s2 "$s2" '.sessions | map(.session_id) | index($s1) != null and index($s2) != null' >/dev/null; then
  echo "FAIL: list does not include both sessions"
  printf "%s\n" "$r6"
  exit 1
fi

echo "[8/12] masc_team_session_compare"
r7="$(call_tool 4110 "masc_team_session_compare" "{\"base_session_id\":\"$s1\",\"target_session_id\":\"$s2\"}")"
require_ok "$r7"
if ! printf "%s" "$r7" | extract_result | jq -e --arg s1 "$s1" --arg s2 "$s2" '.base_session_id == $s1 and .target_session_id == $s2 and .summary and .communication and .policy' >/dev/null; then
  echo "FAIL: compare payload invalid"
  printf "%s\n" "$r7"
  exit 1
fi

echo "[9/12] masc_team_session_stop (base) + report"
_="$(call_tool 4111 "masc_team_session_stop" "{\"session_id\":\"$s1\",\"reason\":\"contract_done\",\"generate_report\":true}")"
r8_report="$(call_tool 4112 "masc_team_session_report" "{\"session_id\":\"$s1\",\"force_regenerate\":true}")"
require_ok "$r8_report"
if ! printf "%s" "$r8_report" | extract_result | jq -e '.markdown_path and .json_path' >/dev/null; then
  echo "FAIL: report paths missing"
  printf "%s\n" "$r8_report"
  exit 1
fi

echo "[10/12] masc_team_session_prove"
r10_prove="$(call_tool 4113 "masc_team_session_prove" "{\"session_id\":\"$s1\",\"generate_report_if_missing\":true}")"
require_ok "$r10_prove"
if ! printf "%s" "$r10_prove" | extract_result | jq -e '.proof.verdict and .proof_json_path and .proof_md_path' >/dev/null; then
  echo "FAIL: prove payload invalid"
  printf "%s\n" "$r10_prove"
  exit 1
fi

echo "[11/12] cleanup stop target"
_="$(call_tool 4114 "masc_team_session_stop" "{\"session_id\":\"$s2\",\"reason\":\"contract_done\",\"generate_report\":false}")"

echo "[12/12] leave"
_="$(call_tool 4115 "masc_leave" "{\"agent_name\":\"$AGENT_NAME\"}")"

echo "PASS: team_session contract harness"
