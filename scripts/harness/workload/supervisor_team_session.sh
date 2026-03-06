#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVER_EXE="${SERVER_EXE:-${ROOT_DIR}/_build/default/bin/main_eio.exe}"
PORT="${PORT:-}"
BASE_PATH="${BASE_PATH:-}"
LOG_FILE="${LOG_FILE:-}"
MCP_URL=""
OPERATOR_URL=""
TEAM_SESSION_ID=""
SUPERVISOR_SESSION_ID="supervisor-bootstrap"
SUPERVISOR_OP_SESSION_ID="supervisor-ops"
PLANNER_SESSION_ID="planner-session"
IMPLEMENTER_A_SESSION_ID="implementer-a-session"
IMPLEMENTER_B_SESSION_ID="implementer-b-session"
SUPERVISOR_AGENT="supervisor-root"
PLANNER_AGENT="planner"
IMPLEMENTER_A_AGENT="implementer-a"
IMPLEMENTER_B_AGENT="implementer-b"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-10}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-30}"
TEAM_GOAL="${TEAM_GOAL:-Demonstrate a supervised MASC team session over /mcp and /mcp/operator}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

if [ ! -x "$SERVER_EXE" ]; then
  echo "server executable not found: $SERVER_EXE"
  echo "build it first with: dune build --root . @default"
  exit 1
fi

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
  BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/masc-supervisor-room.XXXXXX")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/masc-supervisor-harness.XXXXXX")"
fi

MCP_URL="http://127.0.0.1:${PORT}/mcp"
OPERATOR_URL="http://127.0.0.1:${PORT}/mcp/operator"

SERVER_PID=""

read_file() {
  cat "$1"
}

jsonrpc_call() {
  local url="$1"
  local session_id="$2"
  local token="$3"
  local id="$4"
  local method="$5"
  local params="$6"
  local body_file
  body_file="$(mktemp "${TMPDIR:-/tmp}/masc-jsonrpc-body.XXXXXX.json")"
  printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}' "$id" "$method" "$params" >"$body_file"
  local cmd=(curl -sS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $session_id" \
    --data-binary "@$body_file")
  if [ -n "$token" ]; then
    cmd+=( -H "Authorization: Bearer $token" )
  fi
  local response
  response="$("${cmd[@]}")"
  rm -f "$body_file"
  local sse_data
  sse_data="$(printf '%s' "$response" | sed -n 's/^data: //p')"
  if [ -n "$sse_data" ]; then
    printf '%s\n' "$sse_data" | tail -n1
  else
    printf '%s' "$response"
  fi
}

call_tool() {
  local url="$1"
  local session_id="$2"
  local token="$3"
  local id="$4"
  local tool_name="$5"
  local args_json="$6"
  jsonrpc_call "$url" "$session_id" "$token" "$id" "tools/call" "{\"name\":\"$tool_name\",\"arguments\":$args_json}"
}

extract_tool_text() {
  jq -r 'try (.result.content[0].text) catch empty'
}

extract_tool_result() {
  jq -c 'try (.result.content[0].text | fromjson | if has("result") and .result != null then .result else . end) catch empty'
}

extract_confirm_token() {
  jq -r 'try (.result.content[0].text | fromjson | .result.confirm_token) catch empty'
}

extract_response_error() {
  jq -r 'if (.error | type) == "object" and (.error.message | type) == "string" then .error.message else empty end'
}

extract_is_error() {
  jq -r 'try (.result.isError) catch "false"'
}

require_json() {
  local payload="$1"
  if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    echo "FAIL: invalid JSON payload"
    printf '%s\n' "$payload"
    exit 1
  fi
}

require_success_response() {
  local payload="$1"
  require_json "$payload"
  local err
  err="$(printf '%s' "$payload" | extract_response_error)"
  if [ -n "$err" ]; then
    echo "FAIL: JSON-RPC error: $err"
    printf '%s\n' "$payload"
    exit 1
  fi
}

require_tool_success() {
  local payload="$1"
  require_success_response "$payload"
  local is_error
  is_error="$(printf '%s' "$payload" | extract_is_error)"
  if [ "$is_error" = "true" ]; then
    echo "FAIL: tool returned isError=true"
    printf '%s\n' "$payload" | extract_tool_text
    exit 1
  fi
}

parse_token_from_text() {
  local payload="$1"
  local token
  token="$(printf '%s' "$payload" | extract_tool_text | rg -o '[a-f0-9]{64}' | head -n1 || true)"
  if [ -z "$token" ]; then
    echo "FAIL: could not extract token"
    printf '%s\n' "$payload"
    exit 1
  fi
  printf '%s' "$token"
}

parse_nickname_from_text() {
  local payload="$1"
  local nickname
  nickname="$(printf '%s' "$payload" | extract_tool_text | sed -n 's/^  Nickname: //p' | head -n1)"
  if [ -z "$nickname" ]; then
    echo "FAIL: could not extract nickname"
    printf '%s\n' "$payload"
    exit 1
  fi
  printf '%s' "$nickname"
}

wait_for_health() {
  local deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

create_agent_token() {
  local session_id="$1"
  local agent_name="$2"
  local role="$3"
  local caps_json="$4"
  local join_payload
  join_payload="$(jq -cn --arg a "$agent_name" --argjson caps "$caps_json" '{agent_name:$a,capabilities:$caps}')"
  local join_raw
  join_raw="$(call_tool "$MCP_URL" "$session_id" "" 10 "masc_join" "$join_payload")"
  require_tool_success "$join_raw"
  local nickname
  nickname="$(parse_nickname_from_text "$join_raw")"
  local token_raw
  token_raw="$(call_tool "$MCP_URL" "$session_id" "" 11 "masc_auth_create_token" "$(jq -cn --arg role "$role" '{role:$role}')")"
  require_tool_success "$token_raw"
  printf '%s|%s' "$nickname" "$(parse_token_from_text "$token_raw")"
}

join_with_token() {
  local session_id="$1"
  local token="$2"
  local agent_name="$3"
  local caps_json="$4"
  local join_payload
  join_payload="$(jq -cn --arg a "$agent_name" --argjson caps "$caps_json" '{agent_name:$a,capabilities:$caps}')"
  local join_raw
  join_raw="$(call_tool "$MCP_URL" "$session_id" "$token" 20 "masc_join" "$join_payload")"
  require_tool_success "$join_raw"
}

run_team_turn() {
  local session_id="$1"
  local token="$2"
  local agent_name="$3"
  local turn_kind="$4"
  local message="$5"
  local payload
  payload="$(jq -cn --arg s "$TEAM_SESSION_ID" --arg kind "$turn_kind" --arg msg "$message" '{session_id:$s,turn_kind:$kind,message:$msg}')"
  local raw
  raw="$(call_tool "$MCP_URL" "$session_id" "$token" 30 "masc_team_session_turn" "$payload")"
  require_tool_success "$raw"
}

printf '[1/10] start server\n'
"$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH" >"$LOG_FILE" 2>&1 &
SERVER_PID="$!"
if ! wait_for_health; then
  echo "FAIL: server did not become healthy"
  read_file "$LOG_FILE"
  exit 1
fi

printf '[2/10] bootstrap room and tokens before auth\n'
init_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "" 1 "masc_init" "$(jq -cn --arg a "$SUPERVISOR_AGENT" '{agent_name:$a}')")"
require_tool_success "$init_raw"
switch_mode_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "" 2 "masc_switch_mode" '{"mode":"full"}')"
require_tool_success "$switch_mode_raw"

SUPERVISOR_IDENTITY="$(create_agent_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_AGENT" "admin" '["supervisor","operator"]')"
SUPERVISOR_NICKNAME="${SUPERVISOR_IDENTITY%%|*}"
SUPERVISOR_TOKEN="${SUPERVISOR_IDENTITY##*|}"
PLANNER_IDENTITY="$(create_agent_token "$PLANNER_SESSION_ID" "$PLANNER_AGENT" "worker" '["planner","team-session"]')"
PLANNER_NICKNAME="${PLANNER_IDENTITY%%|*}"
PLANNER_TOKEN="${PLANNER_IDENTITY##*|}"
IMPLEMENTER_A_IDENTITY="$(create_agent_token "$IMPLEMENTER_A_SESSION_ID" "$IMPLEMENTER_A_AGENT" "worker" '["backend","team-session"]')"
IMPLEMENTER_A_NICKNAME="${IMPLEMENTER_A_IDENTITY%%|*}"
IMPLEMENTER_A_TOKEN="${IMPLEMENTER_A_IDENTITY##*|}"
IMPLEMENTER_B_IDENTITY="$(create_agent_token "$IMPLEMENTER_B_SESSION_ID" "$IMPLEMENTER_B_AGENT" "worker" '["docs","tests","team-session"]')"
IMPLEMENTER_B_NICKNAME="${IMPLEMENTER_B_IDENTITY%%|*}"
IMPLEMENTER_B_TOKEN="${IMPLEMENTER_B_IDENTITY##*|}"

enable_auth_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "" 12 "masc_auth_enable" '{"require_token":true}')"
require_tool_success "$enable_auth_raw"

printf '[3/10] re-join agents under bearer auth\n'
join_with_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" "$SUPERVISOR_NICKNAME" '["supervisor","operator"]'
join_with_token "$PLANNER_SESSION_ID" "$PLANNER_TOKEN" "$PLANNER_NICKNAME" '["planner","team-session"]'
join_with_token "$IMPLEMENTER_A_SESSION_ID" "$IMPLEMENTER_A_TOKEN" "$IMPLEMENTER_A_NICKNAME" '["backend","team-session"]'
join_with_token "$IMPLEMENTER_B_SESSION_ID" "$IMPLEMENTER_B_TOKEN" "$IMPLEMENTER_B_NICKNAME" '["docs","tests","team-session"]'

printf '[4/10] start supervised team session\n'
start_payload="$(jq -cn \
  --arg goal "$TEAM_GOAL" \
  --arg supervisor "$SUPERVISOR_NICKNAME" \
  --arg planner "$PLANNER_NICKNAME" \
  --arg implementer_a "$IMPLEMENTER_A_NICKNAME" \
  --arg implementer_b "$IMPLEMENTER_B_NICKNAME" \
  '{goal:$goal, duration_seconds:180, checkpoint_interval_sec:15, orchestration_mode:"assist", communication_mode:"broadcast", execution_scope:"limited_code_change", fallback_policy:"cascade_then_task", instruction_profile:"strict", min_agents:4, agents:[$supervisor,$planner,$implementer_a,$implementer_b]}')"
start_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 3 "masc_team_session_start" "$start_payload")"
require_tool_success "$start_raw"
TEAM_SESSION_ID="$(printf '%s' "$start_raw" | extract_tool_result | jq -r '.session_id // empty')"
if [ -z "$TEAM_SESSION_ID" ]; then
  echo "FAIL: missing session_id"
  printf '%s\n' "$start_raw"
  exit 1
fi

printf '[5/10] record planner and implementer turns over /mcp\n'
run_team_turn "$PLANNER_SESSION_ID" "$PLANNER_TOKEN" "$PLANNER_AGENT" "note" "[planner] split the work into docs, harness, and e2e proof"
run_team_turn "$IMPLEMENTER_A_SESSION_ID" "$IMPLEMENTER_A_TOKEN" "$IMPLEMENTER_A_AGENT" "note" "[implementer-a] backend/e2e path will use /mcp and /mcp/operator together"
run_team_turn "$IMPLEMENTER_B_SESSION_ID" "$IMPLEMENTER_B_TOKEN" "$IMPLEMENTER_B_AGENT" "note" "[implementer-b] docs and harness will show human confirm flow"

printf '[6/10] inspect remote operator surface\n'
tools_raw="$(jsonrpc_call "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 4 "tools/list" '{}')"
require_success_response "$tools_raw"
tool_count="$(printf '%s' "$tools_raw" | jq -r '.result.tools | length')"
if [ "$tool_count" -ne 3 ]; then
  echo "FAIL: expected 3 operator tools, got $tool_count"
  printf '%s\n' "$tools_raw"
  exit 1
fi
printf '%s' "$tools_raw" | jq -e '.result.tools | map(.name) | sort == ["masc_operator_action","masc_operator_confirm","masc_operator_snapshot"]' >/dev/null

snapshot_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 5 "masc_operator_snapshot" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" '{actor:$actor,view:"full"}')")"
require_tool_success "$snapshot_raw"
printf '%s' "$snapshot_raw" | extract_tool_result | jq -e '.sessions.items | length >= 1' >/dev/null

printf '[7/10] supervisor immediate correction via team_note\n'
team_note_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 6 "masc_operator_action" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg s "$TEAM_SESSION_ID" '{actor:$actor,action_type:"team_note",target_id:$s,payload:{message:"[supervisor] keep the proof focused on the MCP loop"}}')")"
require_tool_success "$team_note_raw"
printf '%s' "$team_note_raw" | extract_tool_text | jq -e '.confirm_required == false' >/dev/null

printf '[8/10] supervisor disruptive correction via preview + confirm\n'
preview_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 7 "masc_operator_action" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg s "$TEAM_SESSION_ID" '{actor:$actor,action_type:"team_task_inject",target_id:$s,payload:{title:"Capture explicit supervisor proof",description:"Add evidence that preview-confirm changed the session trajectory.",priority:1}}')")"
require_tool_success "$preview_raw"
CONFIRM_TOKEN="$(printf '%s' "$preview_raw" | extract_tool_text | jq -r '.confirm_token // empty')"
if [ -z "$CONFIRM_TOKEN" ]; then
  echo "FAIL: missing confirm token"
  printf '%s\n' "$preview_raw"
  exit 1
fi

snapshot_pending_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 8 "masc_operator_snapshot" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" '{actor:$actor,view:"full"}')")"
require_tool_success "$snapshot_pending_raw"
printf '%s' "$snapshot_pending_raw" | extract_tool_result | jq -e '.pending_confirms | length == 1' >/dev/null

confirm_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 9 "masc_operator_confirm" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg token "$CONFIRM_TOKEN" '{actor:$actor,confirm_token:$token}')")"
require_tool_success "$confirm_raw"

snapshot_after_confirm_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 12 "masc_operator_snapshot" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" '{actor:$actor,view:"full"}')")"
require_tool_success "$snapshot_after_confirm_raw"
printf '%s' "$snapshot_after_confirm_raw" | extract_tool_result | jq -e '.pending_confirms | length == 0' >/dev/null

printf '[9/10] stop session and prove evidence\n'
stop_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 13 "masc_team_session_stop" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,reason:"supervisor_harness_complete",generate_report:true}')")"
require_tool_success "$stop_raw"

deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
while :; do
  status_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 14 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
  require_tool_success "$status_raw"
  session_status="$(printf '%s' "$status_raw" | extract_tool_result | jq -r '.session.status // empty')"
  if [ "$session_status" != "running" ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL: team session did not stop in time"
    printf '%s\n' "$status_raw"
    exit 1
  fi
  sleep 1
done

prove_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 15 "masc_team_session_prove" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,generate_report_if_missing:true}')")"
require_tool_success "$prove_raw"
prove_result="$(printf '%s' "$prove_raw" | extract_tool_result)"
printf '%s' "$prove_result" | jq -e '.proof.verdict == "proved"' >/dev/null
printf '%s' "$prove_result" | jq -e '.proof.evidence.unique_turn_actors_count >= 4' >/dev/null

printf '[10/10] summary\n'
events_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 16 "masc_team_session_events" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,event_types:["team_turn"],limit:200}')")"
require_tool_success "$events_raw"
events_result="$(printf '%s' "$events_raw" | extract_tool_result)"
unique_turn_actors="$(printf '%s' "$events_result" | jq -r '[.events[]? | .detail.actor // empty | select(. != "")] | unique | length')"
proof_json_path="$(printf '%s' "$prove_result" | jq -r '.proof_json_path // empty')"
proof_md_path="$(printf '%s' "$prove_result" | jq -r '.proof_md_path // empty')"

printf 'session_id=%s\n' "$TEAM_SESSION_ID"
printf 'unique_turn_actors=%s\n' "$unique_turn_actors"
printf 'proof_json_path=%s\n' "$proof_json_path"
printf 'proof_md_path=%s\n' "$proof_md_path"
echo 'PASS: supervisor team session harness'
