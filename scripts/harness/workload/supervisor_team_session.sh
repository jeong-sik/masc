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
SUPERVISOR_AGENT="supervisor-root"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-60}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-30}"
TEAM_GOAL="${TEAM_GOAL:-Demonstrate a full llama worker team supervised over /mcp and /mcp/operator}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"

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

spawn_llama_batch() {
  local selection_note="$1"
  local planner_prompt="$2"
  local implementer_a_prompt="$3"
  local implementer_b_prompt="$4"
  local raw
  raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 30 "masc_team_session_step" "$(jq -cn \
    --arg s "$TEAM_SESSION_ID" \
    --arg model "$LLAMA_SWARM_MODEL" \
    --arg note "$selection_note" \
    --arg planner_prompt "$planner_prompt" \
    --arg implementer_a_prompt "$implementer_a_prompt" \
    --arg implementer_b_prompt "$implementer_b_prompt" \
    '{session_id:$s,spawn_batch:[
      {spawn_agent:"llama",spawn_model:$model,spawn_role:"planner",spawn_selection_note:$note,spawn_prompt:$planner_prompt,spawn_timeout_seconds:90},
      {spawn_agent:"llama",spawn_model:$model,spawn_role:"implementer-a",spawn_selection_note:$note,spawn_prompt:$implementer_a_prompt,spawn_timeout_seconds:90},
      {spawn_agent:"llama",spawn_model:$model,spawn_role:"implementer-b",spawn_selection_note:$note,spawn_prompt:$implementer_b_prompt,spawn_timeout_seconds:90}
    ]}')")"
  require_tool_success "$raw"
  printf '%s' "$raw"
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

enable_auth_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "" 12 "masc_auth_enable" '{"require_token":true}')"
require_tool_success "$enable_auth_raw"

printf '[3/10] re-join agents under bearer auth\n'
join_with_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" "$SUPERVISOR_NICKNAME" '["supervisor","operator"]'

printf '[4/10] inspect llama inventory and validate explicit model\n'
llama_models_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 13 "masc_llama_models" '{}')"
require_tool_success "$llama_models_raw"
llama_models_result="$(printf '%s' "$llama_models_raw" | extract_tool_result)"
if [ -z "$LLAMA_SWARM_MODEL" ]; then
  echo "FAIL: LLAMA_SWARM_MODEL is required; available models:"
  printf '%s\n' "$llama_models_result" | jq -r '.models[]?'
  exit 1
fi
if ! printf '%s' "$llama_models_result" | jq -e --arg model "$LLAMA_SWARM_MODEL" '.models | index($model) != null' >/dev/null; then
  echo "FAIL: LLAMA_SWARM_MODEL not present in inventory: $LLAMA_SWARM_MODEL"
  printf '%s\n' "$llama_models_result" | jq -r '.models[]?'
  exit 1
fi
MODEL_SELECTION_NOTE="[model-selection] leader selected $LLAMA_SWARM_MODEL from masc_llama_models inventory for the supervised llama worker team"

printf '[5/10] start supervised team session\n'
start_payload="$(jq -cn \
  --arg goal "$TEAM_GOAL" \
  --arg supervisor "$SUPERVISOR_NICKNAME" \
  '{goal:$goal, duration_seconds:180, checkpoint_interval_sec:15, orchestration_mode:"assist", communication_mode:"broadcast", execution_scope:"limited_code_change", fallback_policy:"cascade_then_task", instruction_profile:"strict", min_agents:4, agents:[$supervisor]}')"
start_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 3 "masc_team_session_start" "$start_payload")"
require_tool_success "$start_raw"
TEAM_SESSION_ID="$(printf '%s' "$start_raw" | extract_tool_result | jq -r '.session_id // empty')"
if [ -z "$TEAM_SESSION_ID" ]; then
  echo "FAIL: missing session_id"
  printf '%s\n' "$start_raw"
  exit 1
fi

model_selection_turn_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 14 "masc_team_session_turn" "$(jq -cn --arg s "$TEAM_SESSION_ID" --arg msg "$MODEL_SELECTION_NOTE" '{session_id:$s,turn_kind:"note",message:$msg}')")"
require_tool_success "$model_selection_turn_raw"

printf '[6/10] spawn full llama team\n'
planner_prompt="You are the planner. Inspect the active team session, then record exactly one concise planning turn with masc_team_session_turn describing task decomposition and acceptance criteria."
implementer_a_prompt="You are implementer-a. Inspect the active team session, then record exactly one concise implementation turn with masc_team_session_turn describing backend/runtime work."
implementer_b_prompt="You are implementer-b. Inspect the active team session, then record exactly one concise implementation turn with masc_team_session_turn describing docs/tests/harness work."
spawn_batch_raw="$(spawn_llama_batch "$MODEL_SELECTION_NOTE" "$planner_prompt" "$implementer_a_prompt" "$implementer_b_prompt")"
printf '%s' "$spawn_batch_raw" | extract_tool_result | jq -e '.spawn.mode == "batch" and .spawn.count == 3 and (.spawn.results | length) == 3 and .turn == null' >/dev/null
printf '%s' "$spawn_batch_raw" | extract_tool_result | jq -e '.spawn.results | all(.runtime_actor != null)' >/dev/null
printf '%s' "$spawn_batch_raw" | extract_tool_result | jq -e --arg note "$MODEL_SELECTION_NOTE" '.spawn.results | all(.spawn_selection_note == $note)' >/dev/null

printf '[7/10] inspect remote operator surface\n'
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

printf '[8/10] supervisor immediate correction via team_note\n'
team_note_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 6 "masc_operator_action" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg s "$TEAM_SESSION_ID" '{actor:$actor,action_type:"team_note",target_id:$s,payload:{message:"[supervisor] keep the proof focused on the MCP loop"}}')")"
require_tool_success "$team_note_raw"
printf '%s' "$team_note_raw" | extract_tool_text | jq -e '.confirm_required == false' >/dev/null

printf '[9/10] supervisor disruptive correction via preview + confirm\n'
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

printf '[10/10] stop session and prove evidence\n'
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
printf '%s' "$prove_result" | jq -e '.proof.evidence.empty_note_turn_count == 0' >/dev/null
report_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 18 "masc_team_session_report" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,force_regenerate:false}')")"
require_tool_success "$report_raw"
report_result="$(printf '%s' "$report_raw" | extract_tool_result)"
report_json_path="$(printf '%s' "$report_result" | jq -r '.json_path // empty')"
if [ -z "$report_json_path" ]; then
  echo "FAIL: missing report json path"
  printf '%s\n' "$report_result"
  exit 1
fi
if ! jq -e '.incidents.empty_note_turn_count == 0' "$report_json_path" >/dev/null; then
  echo "FAIL: report json recorded empty note turns"
  cat "$report_json_path"
  exit 1
fi

printf '[summary]\n'
events_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 16 "masc_team_session_events" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,event_types:["team_turn"],limit:200}')")"
require_tool_success "$events_raw"
events_result="$(printf '%s' "$events_raw" | extract_tool_result)"
unique_turn_actors="$(printf '%s' "$events_result" | jq -r '[.events[]? | .detail.actor // empty | select(. != "")] | unique | length')"
spawn_events_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 17 "masc_team_session_events" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,event_types:["team_step_spawn"],limit:200}')")"
require_tool_success "$spawn_events_raw"
spawn_events_result="$(printf '%s' "$spawn_events_raw" | extract_tool_result)"
unique_spawned_llama_actors="$(printf '%s' "$spawn_events_result" | jq -r '[.events[]? | .detail.runtime_actor // empty | select(. != "")] | unique | length')"
if [ "$unique_spawned_llama_actors" -lt 3 ]; then
  echo "FAIL: expected at least 3 unique spawned llama actors, got $unique_spawned_llama_actors"
  printf '%s\n' "$spawn_events_result"
  exit 1
fi
printf '%s' "$spawn_events_result" | jq -e --arg note "$MODEL_SELECTION_NOTE" '[.events[]? | .detail.spawn_selection_note // empty] | all(. == $note)' >/dev/null
proof_json_path="$(printf '%s' "$prove_result" | jq -r '.proof_json_path // empty')"
proof_md_path="$(printf '%s' "$prove_result" | jq -r '.proof_md_path // empty')"

printf 'session_id=%s\n' "$TEAM_SESSION_ID"
printf 'llama_swarm_model=%s\n' "$LLAMA_SWARM_MODEL"
printf 'unique_turn_actors=%s\n' "$unique_turn_actors"
printf 'unique_spawned_llama_actors=%s\n' "$unique_spawned_llama_actors"
printf 'proof_json_path=%s\n' "$proof_json_path"
printf 'proof_md_path=%s\n' "$proof_md_path"
echo 'PASS: supervisor team session harness'
