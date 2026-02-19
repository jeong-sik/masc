#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
SESSION_ID="${SESSION_ID:-harness-gv-$(date +%s)-$$}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"

curl_post_mcp() {
  local body="$1"
  local attempt=1
  while [ "$attempt" -le "$CURL_RETRY_COUNT" ]; do
    local raw
    if raw="$(curl -sS -m 20 -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d "$body")"; then
      printf "%s" "$raw"
      return 0
    fi
    if [ "$attempt" -lt "$CURL_RETRY_COUNT" ]; then
      sleep "$CURL_RETRY_DELAY_SEC"
    fi
    attempt=$((attempt + 1))
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
