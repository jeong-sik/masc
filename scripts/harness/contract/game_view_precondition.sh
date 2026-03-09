#!/usr/bin/env bash
set -euo pipefail

SESSION_ID="${SESSION_ID:-harness-gv-$(date +%s)-$$}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
export CURL_RETRY_COUNT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/test_framework.sh"

echo "[1/5] experiment.start without decision.finalize => expect PRECONDITION_REQUIRED"
r1="$(call_tool 1001 "experiment.start" "{\"session_id\":\"$SESSION_ID\",\"hypothesis\":\"h\"}")"
if ! printf "%s" "$r1" | jq -er 'try (.result.content[0].text | fromjson | tostring | contains("PRECONDITION_REQUIRED")) catch false' >/dev/null; then
  echo "FAIL: experiment.start should return PRECONDITION_REQUIRED"
  printf "%s\n" "$r1"
  exit 1
fi

echo "[2/5] decision.create"
r2="$(call_tool 1002 "decision.create" "{\"session_id\":\"$SESSION_ID\",\"issue\":\"route\",\"options\":[\"A\",\"B\"]}")"
decision_id="$(printf "%s" "$r2" | jq -r 'try (.result.content[0].text | fromjson | .payload.decision_id // empty) catch empty')"
if [ -z "$decision_id" ]; then
  echo "FAIL: decision_id not found"
  printf "%s\n" "$r2"
  exit 1
fi

echo "[3/5] decision.finalize"
r3="$(call_tool 1003 "decision.finalize" "{\"session_id\":\"$SESSION_ID\",\"decision_id\":\"$decision_id\",\"selected_option\":\"A\",\"rationale\":\"best\",\"verifier\":\"PASS\"}")"
status3="$(printf "%s" "$r3" | jq -r 'try (.result.content[0].text | fromjson | .payload.status // empty) catch empty')"
if [ "$status3" != "finalized" ]; then
  echo "FAIL: decision.finalize should finalize decision"
  printf "%s\n" "$r3"
  exit 1
fi

echo "[4/5] experiment.start after finalize => expect running"
r4="$(call_tool 1004 "experiment.start" "{\"session_id\":\"$SESSION_ID\",\"hypothesis\":\"h2\",\"metrics\":[\"engagement\"]}")"
status4="$(printf "%s" "$r4" | jq -r 'try (.result.content[0].text | fromjson | .payload.status // empty) catch empty')"
if [ "$status4" != "running" ]; then
  echo "FAIL: experiment.start should be running after finalize"
  printf "%s\n" "$r4"
  exit 1
fi

echo "[5/5] trpg.action.submit after finalize => expect result"
r5="$(call_tool 1005 "trpg.action.submit" "{\"session_id\":\"$SESSION_ID\",\"action\":\"scan area\",\"intent\":\"collect info\",\"stakes\":\"medium\"}")"
story_len="$(printf "%s" "$r5" | jq -r 'try (.result.content[0].text | fromjson | (.payload.story_log | length)) catch 0')"
if [ "${story_len:-0}" -lt 1 ]; then
  echo "FAIL: trpg.action.submit should return story_log"
  printf "%s\n" "$r5"
  exit 1
fi

echo "PASS: GAME-VIEW precondition harness"
