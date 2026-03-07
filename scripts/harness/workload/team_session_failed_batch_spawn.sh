#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVER_EXE="${SERVER_EXE:-${ROOT_DIR}/_build/default/bin/main_eio.exe}"
PORT="${PORT:-}"
BASE_PATH="${BASE_PATH:-}"
LOG_FILE="${LOG_FILE:-}"
MCP_URL=""
TEAM_SESSION_ID=""
SUPERVISOR_SESSION_ID="failed-spawn-replay"
SUPERVISOR_AGENT="failure-replay-supervisor"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-45}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-30}"
TEAM_GOAL="${TEAM_GOAL:-Replay a deterministic llama batch-spawn failure and verify detach + proof accounting}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"
FAIL_LLAMA_SERVER_URL="${FAIL_LLAMA_SERVER_URL:-http://127.0.0.1:1}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "rg is required"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required"
  exit 1
fi

if [ ! -x "$SERVER_EXE" ]; then
  echo "server executable not found: $SERVER_EXE"
  echo "build it first with: dune build --root . @default"
  exit 1
fi

if [ -z "$LLAMA_SWARM_MODEL" ]; then
  echo "LLAMA_SWARM_MODEL is required"
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
  BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/masc-failed-batch-spawn.XXXXXX")"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/masc-failed-batch-spawn.XXXXXX").log"
fi

MCP_URL="http://127.0.0.1:${PORT}/mcp"
SERVER_PID=""

read_file() {
  cat "$1"
}

jsonrpc_call() {
  local session_id="$1"
  local token="$2"
  local id="$3"
  local method="$4"
  local params="$5"
  local body_file
  body_file="$(mktemp "${TMPDIR:-/tmp}/masc-jsonrpc-body.XXXXXX.json")"
  printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}' "$id" "$method" "$params" >"$body_file"
  local cmd=(curl -sS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" -X POST "$MCP_URL" \
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
  local session_id="$1"
  local token="$2"
  local id="$3"
  local tool_name="$4"
  local args_json="$5"
  jsonrpc_call "$session_id" "$token" "$id" "tools/call" "{\"name\":\"$tool_name\",\"arguments\":$args_json}"
}

extract_tool_text() {
  jq -r 'try (.result.content[0].text) catch empty'
}

extract_tool_result() {
  jq -c 'try (.result.content[0].text | fromjson | if has("result") and .result != null then .result else . end) catch empty'
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
  join_raw="$(call_tool "$session_id" "" 10 "masc_join" "$join_payload")"
  require_tool_success "$join_raw"
  local nickname
  nickname="$(parse_nickname_from_text "$join_raw")"
  local token_raw
  token_raw="$(call_tool "$session_id" "" 11 "masc_auth_create_token" "$(jq -cn --arg role "$role" '{role:$role}')")"
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
  join_raw="$(call_tool "$session_id" "$token" 20 "masc_join" "$join_payload")"
  require_tool_success "$join_raw"
}

printf '[1/8] start server with deterministic llama failure endpoint\n'
env LLAMA_SERVER_URL="$FAIL_LLAMA_SERVER_URL" "$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH" >"$LOG_FILE" 2>&1 &
SERVER_PID="$!"
if ! wait_for_health; then
  echo "FAIL: server did not become healthy"
  read_file "$LOG_FILE"
  exit 1
fi

printf '[2/8] bootstrap room and auth\n'
init_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "" 1 "masc_init" "$(jq -cn --arg a "$SUPERVISOR_AGENT" '{agent_name:$a}')")"
require_tool_success "$init_raw"
switch_mode_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "" 2 "masc_switch_mode" '{"mode":"full"}')"
require_tool_success "$switch_mode_raw"
SUPERVISOR_IDENTITY="$(create_agent_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_AGENT" "admin" '["supervisor","failure-replay"]')"
SUPERVISOR_NICKNAME="${SUPERVISOR_IDENTITY%%|*}"
SUPERVISOR_TOKEN="${SUPERVISOR_IDENTITY##*|}"
enable_auth_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "" 12 "masc_auth_enable" '{"require_token":true}')"
require_tool_success "$enable_auth_raw"
join_with_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" "$SUPERVISOR_NICKNAME" '["supervisor","failure-replay"]'

printf '[3/8] start team session\n'
start_payload="$(jq -cn \
  --arg goal "$TEAM_GOAL" \
  --arg supervisor "$SUPERVISOR_NICKNAME" \
  '{goal:$goal,duration_seconds:180,checkpoint_interval_sec:15,orchestration_mode:"assist",communication_mode:"broadcast",execution_scope:"limited_code_change",fallback_policy:"none",instruction_profile:"strict",min_agents:1,agents:[$supervisor]}')"
start_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 3 "masc_team_session_start" "$start_payload")"
require_tool_success "$start_raw"
TEAM_SESSION_ID="$(printf '%s' "$start_raw" | extract_tool_result | jq -r '.session_id // empty')"
if [ -z "$TEAM_SESSION_ID" ]; then
  echo "FAIL: missing session_id"
  printf '%s\n' "$start_raw"
  exit 1
fi

FAILURE_NOTE="[failure-replay] explicit model=${LLAMA_SWARM_MODEL}; llama endpoint intentionally unreachable at ${FAIL_LLAMA_SERVER_URL}"
note_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 4 "masc_team_session_turn" "$(jq -cn --arg s "$TEAM_SESSION_ID" --arg msg "$FAILURE_NOTE" '{session_id:$s,turn_kind:"note",message:$msg}')")"
require_tool_success "$note_raw"

printf '[4/8] replay deterministic failed batch spawn\n'
spawn_batch_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 5 "masc_team_session_step" "$(jq -cn \
  --arg s "$TEAM_SESSION_ID" \
  --arg model "$LLAMA_SWARM_MODEL" \
  --arg note "$FAILURE_NOTE" \
  '{session_id:$s,spawn_batch:[
    {spawn_agent:"llama",spawn_model:$model,spawn_role:"planner",spawn_selection_note:$note,spawn_prompt:"planner failure replay worker",spawn_timeout_seconds:30},
    {spawn_agent:"llama",spawn_model:$model,spawn_role:"implementer-a",spawn_selection_note:$note,spawn_prompt:"implementer failure replay worker",spawn_timeout_seconds:30}
  ]}')")"
require_tool_success "$spawn_batch_raw"
spawn_result="$(printf '%s' "$spawn_batch_raw" | extract_tool_result)"
printf '%s' "$spawn_result" | jq -e '.spawn.mode == "batch" and .spawn.count == 2 and (.spawn.results | length) == 2' >/dev/null
printf '%s' "$spawn_result" | jq -e '.spawn.results | all(.success == false)' >/dev/null
printf '%s' "$spawn_result" | jq -e '.spawn.results | all(.runtime_actor != null)' >/dev/null

printf '[5/8] verify detach + participant accounting\n'
spawn_events_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 6 "masc_team_session_events" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,event_types:["team_step_spawn"],limit:100}')")"
require_tool_success "$spawn_events_raw"
spawn_events_result="$(printf '%s' "$spawn_events_raw" | extract_tool_result)"
printf '%s' "$spawn_events_result" | jq -e '.count == 2' >/dev/null
printf '%s' "$spawn_events_result" | jq -e '[.events[] | .detail.success] | all(. == false)' >/dev/null

detached_events_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 7 "masc_team_session_events" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,event_types:["session_agent_detached"],limit:100}')")"
require_tool_success "$detached_events_raw"
detached_events_result="$(printf '%s' "$detached_events_raw" | extract_tool_result)"
printf '%s' "$detached_events_result" | jq -e '.count == 2' >/dev/null

status_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 8 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
require_tool_success "$status_raw"
status_result="$(printf '%s' "$status_raw" | extract_tool_result)"
printf '%s' "$status_result" | jq -e '.summary.active_agents | length == 1' >/dev/null
printf '%s' "$status_result" | jq -e '.summary.planned_workers | length == 2' >/dev/null

replay_note_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 9 "masc_team_session_turn" "$(jq -cn --arg s "$TEAM_SESSION_ID" --arg msg "[failure-replay] observed 2 failed spawns and 2 detached actors" '{session_id:$s,turn_kind:"note",message:$msg}')")"
require_tool_success "$replay_note_raw"

printf '[6/8] stop session and generate artifacts\n'
stop_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 10 "masc_team_session_stop" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,reason:"failed_batch_spawn_replay_complete",generate_report:true}')")"
require_tool_success "$stop_raw"

deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
while :; do
  stop_status_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 11 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
  require_tool_success "$stop_status_raw"
  stop_status_result="$(printf '%s' "$stop_status_raw" | extract_tool_result)"
  stop_status="$(printf '%s' "$stop_status_result" | jq -r '.session.status // empty')"
  if [ "$stop_status" != "running" ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL: session did not stop within ${STOP_WAIT_SEC}s"
    printf '%s\n' "$stop_status_result"
    exit 1
  fi
  sleep 1
done

report_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 12 "masc_team_session_report" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,force_regenerate:false}')")"
require_tool_success "$report_raw"
report_result="$(printf '%s' "$report_raw" | extract_tool_result)"
report_json_path="$(printf '%s' "$report_result" | jq -r '.json_path // empty')"
report_md_path="$(printf '%s' "$report_result" | jq -r '.markdown_path // empty')"
if [ -z "$report_json_path" ] || [ -z "$report_md_path" ]; then
  echo "FAIL: missing report artifact paths"
  printf '%s\n' "$report_result"
  exit 1
fi

prove_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 13 "masc_team_session_prove" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,generate_report_if_missing:true}')")"
require_tool_success "$prove_raw"
prove_result="$(printf '%s' "$prove_raw" | extract_tool_result)"
printf '%s' "$prove_result" | jq -e '.proof.evidence.spawn_failure_count == 2' >/dev/null
printf '%s' "$prove_result" | jq -e '.proof.evidence.detached_agent_count == 2' >/dev/null
proof_md_path="$(printf '%s' "$prove_result" | jq -r '.proof_md_path')"
proof_json_path="$(printf '%s' "$prove_result" | jq -r '.proof_json_path')"

printf '[7/8] verify report/proof text\n'
if ! jq -e '.summary.active_agents | length == 1' "$report_json_path" >/dev/null; then
  echo "FAIL: report json active_agents accounting is wrong"
  cat "$report_json_path"
  exit 1
fi
if ! jq -e '.summary.planned_workers | length == 2' "$report_json_path" >/dev/null; then
  echo "FAIL: report json planned_workers accounting is wrong"
  cat "$report_json_path"
  exit 1
fi
if ! rg -q "Failed spawn events: 2" "$proof_md_path"; then
  echo "FAIL: proof markdown missing failed spawn count"
  cat "$proof_md_path"
  exit 1
fi
if ! rg -q "Detached failed actors: 2" "$proof_md_path"; then
  echo "FAIL: proof markdown missing detached actor count"
  cat "$proof_md_path"
  exit 1
fi
if ! jq -e '.agent_turn_metrics != null' "$report_json_path" >/dev/null; then
  echo "FAIL: report json missing agent_turn_metrics"
  cat "$report_json_path"
  exit 1
fi

printf '[8/8] summary\n'
printf 'session_id=%s\n' "$TEAM_SESSION_ID"
printf 'llama_swarm_model=%s\n' "$LLAMA_SWARM_MODEL"
printf 'fail_llama_server_url=%s\n' "$FAIL_LLAMA_SERVER_URL"
printf 'report_json_path=%s\n' "$report_json_path"
printf 'report_md_path=%s\n' "$report_md_path"
printf 'proof_json_path=%s\n' "$proof_json_path"
printf 'proof_md_path=%s\n' "$proof_md_path"
echo 'PASS: deterministic failed batch spawn replay harness'
