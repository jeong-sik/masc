#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
SESSION_ID="${SESSION_ID:-harness-gv-001}"

call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  curl -sS -m 20 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}"
}

echo "[1/5] experiment.start without decision.finalize => expect PRECONDITION_REQUIRED"
r1="$(call_tool 1001 "experiment.start" "{\"session_id\":\"$SESSION_ID\",\"hypothesis\":\"h\"}")"
if ! printf "%s" "$r1" | rg -q 'PRECONDITION_REQUIRED'; then
  echo "FAIL: experiment.start should return PRECONDITION_REQUIRED"
  printf "%s\n" "$r1"
  exit 1
fi

echo "[2/5] decision.create"
r2="$(call_tool 1002 "decision.create" "{\"session_id\":\"$SESSION_ID\",\"issue\":\"route\",\"options\":[\"A\",\"B\"]}")"
decision_id="$(printf "%s" "$r2" | rg -o '"decision_id"\s*:\s*"[^"]+"' | head -n1 | sed -E 's/.*"decision_id"\s*:\s*"([^"]+)".*/\1/' || true)"
if [ -z "$decision_id" ]; then
  echo "FAIL: decision_id not found"
  printf "%s\n" "$r2"
  exit 1
fi

echo "[3/5] decision.finalize"
r3="$(call_tool 1003 "decision.finalize" "{\"session_id\":\"$SESSION_ID\",\"decision_id\":\"$decision_id\",\"selected_option\":\"A\",\"rationale\":\"best\",\"verifier\":\"PASS\"}")"
if ! printf "%s" "$r3" | rg -q '"status"\s*:\s*"finalized"'; then
  echo "FAIL: decision.finalize should finalize decision"
  printf "%s\n" "$r3"
  exit 1
fi

echo "[4/5] experiment.start after finalize => expect running"
r4="$(call_tool 1004 "experiment.start" "{\"session_id\":\"$SESSION_ID\",\"hypothesis\":\"h2\",\"metrics\":[\"engagement\"]}")"
if ! printf "%s" "$r4" | rg -q '"status"\s*:\s*"running"'; then
  echo "FAIL: experiment.start should be running after finalize"
  printf "%s\n" "$r4"
  exit 1
fi

echo "[5/5] trpg.action.submit after finalize => expect result"
r5="$(call_tool 1005 "trpg.action.submit" "{\"session_id\":\"$SESSION_ID\",\"action\":\"scan area\",\"intent\":\"collect info\",\"stakes\":\"medium\"}")"
if ! printf "%s" "$r5" | rg -q '"story_log"'; then
  echo "FAIL: trpg.action.submit should return story_log"
  printf "%s\n" "$r5"
  exit 1
fi

echo "PASS: GAME-VIEW precondition harness"
