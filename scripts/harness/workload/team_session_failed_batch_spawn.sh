#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"
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
PORT_WAS_EXPLICIT="false"
BASE_PATH_WAS_EXPLICIT="false"
LOG_FILE_WAS_EXPLICIT="false"

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
else
  PORT_WAS_EXPLICIT="true"
fi

if [ -z "$BASE_PATH" ]; then
  BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/masc-failed-batch-spawn.XXXXXX")"
else
  BASE_PATH_WAS_EXPLICIT="true"
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$(mcp_mktemp_file "masc-failed-batch-spawn" ".log")"
else
  LOG_FILE_WAS_EXPLICIT="true"
fi
HARNESS_LOG_FILE="${HARNESS_LOG_FILE:-$LOG_FILE}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"

MCP_URL="http://127.0.0.1:${PORT}/mcp"
SERVER_PID=""

read_file() {
  cat "$1"
}

allocate_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

call_tool() {
  local session_id="$1"
  local token="$2"
  local id="$3"
  local tool_name="$4"
  local args_json="$5"
  local endpoint="${6:-$MCP_URL}"
  mcp_call_tool "$id" "$tool_name" "$args_json" "$session_id" "$token" "$endpoint"
}

extract_tool_text() {
  mcp_extract_text
}

extract_tool_result() {
  mcp_extract_result
}

require_success_response() {
  local payload="$1"
  local label="${2:-team_session_failed_batch_spawn response}"
  mcp_require_jsonrpc_ok "$payload" "$label"
}

require_json_condition() {
  local payload="$1"
  local jq_expr="$2"
  local failure_message="$3"
  if ! printf '%s' "$payload" | jq -e "$jq_expr" >/dev/null; then
    echo "FAIL: $failure_message"
    printf '%s\n' "$payload"
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
    if curl -fsS --http1.1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
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
  if [ "$BASE_PATH_WAS_EXPLICIT" != "true" ] && [ -n "$BASE_PATH" ]; then
    rm -rf "$BASE_PATH" >/dev/null 2>&1 || true
  fi
  if [ "$LOG_FILE_WAS_EXPLICIT" != "true" ] && [ -n "$LOG_FILE" ]; then
    rm -f "$LOG_FILE" >/dev/null 2>&1 || true
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
  mcp_require_tool_ok "$join_raw"
  local nickname
  nickname="$(parse_nickname_from_text "$join_raw")"
  local token_raw
  token_raw="$(call_tool "$session_id" "" 11 "masc_auth_create_token" "$(jq -cn --arg role "$role" '{role:$role}')")"
  mcp_require_tool_ok "$token_raw"
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
  mcp_require_tool_ok "$join_raw"
}

printf '[1/8] start server with deterministic llama failure endpoint\n'
server_started="false"
for attempt in 1 2 3 4 5; do
  if [ "$PORT_WAS_EXPLICIT" != "true" ]; then
    PORT="$(allocate_port)"
  fi
  MCP_URL="http://127.0.0.1:${PORT}/mcp"
  : >"$LOG_FILE"
  env LLAMA_SERVER_URL="$FAIL_LLAMA_SERVER_URL" "$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH" >"$LOG_FILE" 2>&1 &
  SERVER_PID="$!"
  if wait_for_health; then
    server_started="true"
    break
  fi
  if [ "$PORT_WAS_EXPLICIT" != "true" ] && rg -q 'Address already in use|EADDRINUSE' "$LOG_FILE"; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
    SERVER_PID=""
    sleep 1
    continue
  fi
  break
done
if [ "$server_started" != "true" ]; then
  echo "FAIL: server did not become healthy"
  read_file "$LOG_FILE"
  exit 1
fi

printf '[2/9] bootstrap room and auth\n'
init_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "" 1 "masc_init" "$(jq -cn --arg a "$SUPERVISOR_AGENT" '{agent_name:$a}')")"
mcp_require_tool_ok "$init_raw"
switch_mode_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "" 2 "masc_switch_mode" '{"mode":"full"}')"
mcp_require_tool_ok "$switch_mode_raw"
SUPERVISOR_IDENTITY="$(create_agent_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_AGENT" "admin" '["supervisor","failure-replay"]')"
SUPERVISOR_NICKNAME="${SUPERVISOR_IDENTITY%%|*}"
SUPERVISOR_TOKEN="${SUPERVISOR_IDENTITY##*|}"
enable_auth_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "" 12 "masc_auth_enable" '{"require_token":true}')"
mcp_require_tool_ok "$enable_auth_raw"
join_with_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" "$SUPERVISOR_NICKNAME" '["supervisor","failure-replay"]'

printf '[3/9] start team session\n'
start_payload="$(jq -cn \
  --arg goal "$TEAM_GOAL" \
  --arg supervisor "$SUPERVISOR_NICKNAME" \
  '{goal:$goal,duration_seconds:180,checkpoint_interval_sec:15,orchestration_mode:"assist",communication_mode:"broadcast",execution_scope:"limited_code_change",fallback_policy:"none",instruction_profile:"strict",min_agents:1,agents:[$supervisor]}')"
start_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 3 "masc_team_session_start" "$start_payload")"
mcp_require_tool_ok "$start_raw"
TEAM_SESSION_ID="$(printf '%s' "$start_raw" | extract_tool_result | jq -r '.session_id // empty')"
if [ -z "$TEAM_SESSION_ID" ]; then
  echo "FAIL: missing session_id"
  printf '%s\n' "$start_raw"
  exit 1
fi

FAILURE_NOTE="[failure-replay] explicit model=${LLAMA_SWARM_MODEL}; llama endpoint intentionally unreachable at ${FAIL_LLAMA_SERVER_URL}"
note_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 4 "masc_team_session_turn" "$(jq -cn --arg s "$TEAM_SESSION_ID" --arg msg "$FAILURE_NOTE" '{session_id:$s,turn_kind:"note",message:$msg}')")"
mcp_require_tool_ok "$note_raw"

printf '[4/9] replay deterministic failed batch spawn\n'
spawn_batch_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 5 "masc_team_session_step" "$(jq -cn \
  --arg s "$TEAM_SESSION_ID" \
  --arg model "$LLAMA_SWARM_MODEL" \
  --arg note "$FAILURE_NOTE" \
  '{session_id:$s,spawn_batch:[
    {spawn_role:"planner",worker_class:"manager",worker_size:"xlg",spawn_selection_note:$note,spawn_prompt:"planner failure replay worker",spawn_timeout_seconds:30},
    {spawn_role:"implementer-a",worker_class:"executor",worker_size:"lg",spawn_selection_note:$note,spawn_prompt:"implementer failure replay worker",spawn_timeout_seconds:30}
  ]}')")"
mcp_require_tool_ok "$spawn_batch_raw"
spawn_result="$(printf '%s' "$spawn_batch_raw" | extract_tool_result)"
require_json_condition "$spawn_result" '.spawn.mode == "batch" and .spawn.count == 2 and (.spawn.results | length) == 2' "spawn batch result shape is wrong"
require_json_condition "$spawn_result" '.spawn.results | all(.success == false)' "spawn batch unexpectedly succeeded"
require_json_condition "$spawn_result" '.spawn.results | all(.runtime_actor != null)' "spawn batch results are missing runtime_actor"
FAILED_RUNTIME_ACTOR_1="$(printf '%s' "$spawn_result" | jq -r '.spawn.results[0].runtime_actor')"
FAILED_RUNTIME_ACTOR_2="$(printf '%s' "$spawn_result" | jq -r '.spawn.results[1].runtime_actor')"

printf '[5/9] verify detach + participant accounting\n'
spawn_events_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 6 "masc_team_session_events" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,event_types:["team_step_spawn"],limit:100}')")"
mcp_require_tool_ok "$spawn_events_raw"
spawn_events_result="$(printf '%s' "$spawn_events_raw" | extract_tool_result)"
spawn_event_count="$(printf '%s' "$spawn_events_result" | jq -r '.count // 0')"
if [ "$spawn_event_count" -gt 0 ]; then
  require_json_condition "$spawn_events_result" '.count == 2' "unexpected number of team_step_spawn events"
  require_json_condition "$spawn_events_result" '[.events[] | .detail.success] | all(. == false)' "spawn events should all be failed"
else
  printf 'note: no team_step_spawn events were persisted; falling back to step result + detach/status evidence\n'
fi

detached_events_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 7 "masc_team_session_events" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,event_types:["session_agent_detached"],limit:100}')")"
mcp_require_tool_ok "$detached_events_raw"
detached_events_result="$(printf '%s' "$detached_events_raw" | extract_tool_result)"
require_json_condition "$detached_events_result" '.count == 2' "unexpected number of detached-agent events"

status_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 8 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
mcp_require_tool_ok "$status_raw"
status_result="$(printf '%s' "$status_raw" | extract_tool_result)"
require_json_condition "$status_result" '.summary.active_agents | length == 1' "active_agents accounting is wrong after failed spawn replay"
require_json_condition "$status_result" '.summary.planned_workers | length == 2' "planned_workers accounting is wrong after failed spawn replay"

replay_note_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 9 "masc_team_session_turn" "$(jq -cn --arg s "$TEAM_SESSION_ID" --arg msg "[failure-replay] observed 2 failed spawns and 2 detached actors" '{session_id:$s,turn_kind:"note",message:$msg}')")"
mcp_require_tool_ok "$replay_note_raw"

printf '[6/9] verify operator digest signals\n'
digest_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 92 "masc_operator_digest" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg s "$TEAM_SESSION_ID" '{actor:$actor,target_type:"team_session",target_id:$s}')")"
mcp_require_tool_ok "$digest_raw"
digest_result="$(printf '%s' "$digest_raw" | extract_tool_result)"
require_json_condition "$digest_result" '.target_type == "team_session"' "digest target_type mismatch"
require_json_condition "$digest_result" '[.attention_items[]?.kind] | index("spawn_failure_present") != null' "digest missing spawn_failure_present"
require_json_condition "$digest_result" '[.attention_items[]?.kind] | index("detached_actor_present") != null' "digest missing detached_actor_present"

printf '[7/9] stop session and generate artifacts\n'
stop_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 10 "masc_team_session_stop" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,reason:"failed_batch_spawn_replay_complete",generate_report:true}')")"
mcp_require_tool_ok "$stop_raw"

deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
while :; do
  stop_status_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 11 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
  mcp_require_tool_ok "$stop_status_raw"
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
mcp_require_tool_ok "$report_raw"
report_result="$(printf '%s' "$report_raw" | extract_tool_result)"
report_json_path="$(printf '%s' "$report_result" | jq -r '.json_path // empty')"
report_md_path="$(printf '%s' "$report_result" | jq -r '.markdown_path // empty')"
if [ -z "$report_json_path" ] || [ -z "$report_md_path" ]; then
  echo "FAIL: missing report artifact paths"
  printf '%s\n' "$report_result"
  exit 1
fi

prove_raw="$(call_tool "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 13 "masc_team_session_prove" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,generate_report_if_missing:true}')")"
mcp_require_tool_ok "$prove_raw"
prove_result="$(printf '%s' "$prove_raw" | extract_tool_result)"
require_json_condition "$prove_result" '.proof.evidence.spawn_failure_count == 2' "proof evidence is missing spawn_failure_count=2"
require_json_condition "$prove_result" '.proof.evidence.detached_agent_count == 2' "proof evidence is missing detached_agent_count=2"
require_json_condition "$prove_result" '.proof.evidence.empty_note_turn_count == 0' "proof evidence recorded unexpected empty note turns"
require_json_condition "$prove_result" '.proof.evidence.failed_spawn_roster | length == 2' "proof evidence is missing failed spawn roster"
require_json_condition "$prove_result" '.proof.evidence.detached_actor_roster | length == 2' "proof evidence is missing detached actor roster"
proof_md_path="$(printf '%s' "$prove_result" | jq -r '.proof_md_path')"
proof_json_path="$(printf '%s' "$prove_result" | jq -r '.proof_json_path')"

printf '[8/9] verify report/proof text\n'
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
if ! jq -e '.incidents.failed_spawn_roster | length == 2' "$report_json_path" >/dev/null; then
  echo "FAIL: report json missing failed_spawn_roster"
  cat "$report_json_path"
  exit 1
fi
if ! jq -e '.incidents.detached_actor_roster | length == 2' "$report_json_path" >/dev/null; then
  echo "FAIL: report json missing detached_actor_roster"
  cat "$report_json_path"
  exit 1
fi
if ! jq -e '.incidents.empty_note_turn_count == 0' "$report_json_path" >/dev/null; then
  echo "FAIL: report json recorded unexpected empty note turns"
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
if ! rg -q "$FAILED_RUNTIME_ACTOR_1" "$proof_md_path"; then
  echo "FAIL: proof markdown missing failed runtime actor $FAILED_RUNTIME_ACTOR_1"
  cat "$proof_md_path"
  exit 1
fi
if ! rg -q "spawn_failed_without_turn" "$proof_md_path"; then
  echo "FAIL: proof markdown missing detached reason"
  cat "$proof_md_path"
  exit 1
fi
if ! rg -q "$FAILED_RUNTIME_ACTOR_2" "$report_md_path"; then
  echo "FAIL: report markdown missing failed runtime actor $FAILED_RUNTIME_ACTOR_2"
  cat "$report_md_path"
  exit 1
fi

printf '[9/9] summary\n'
printf 'session_id=%s\n' "$TEAM_SESSION_ID"
printf 'llama_swarm_model=%s\n' "$LLAMA_SWARM_MODEL"
printf 'fail_llama_server_url=%s\n' "$FAIL_LLAMA_SERVER_URL"
printf 'report_json_path=%s\n' "$report_json_path"
printf 'report_md_path=%s\n' "$report_md_path"
printf 'proof_json_path=%s\n' "$proof_json_path"
printf 'proof_md_path=%s\n' "$proof_md_path"
echo 'PASS: deterministic failed batch spawn replay harness'
