#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"
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
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
TEAM_GOAL="${TEAM_GOAL:-Demonstrate a full llama worker team supervised over /mcp and /mcp/operator}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"
SWARM_WORKER_BATCH_JSON="${SWARM_WORKER_BATCH_JSON:-}"
SWARM_INTERVENTION_MODE="${SWARM_INTERVENTION_MODE:-default}"
TEAM_SESSION_DURATION_SECONDS="${TEAM_SESSION_DURATION_SECONDS:-180}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"

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
  LOG_FILE="$(mcp_mktemp_file "masc-supervisor-harness")"
fi

MCP_URL="http://127.0.0.1:${PORT}/mcp"
OPERATOR_URL="http://127.0.0.1:${PORT}/mcp/operator"

SERVER_PID=""

call_tool() {
  local url="$1"
  local session_id="$2"
  local token="$3"
  local id="$4"
  local tool_name="$5"
  local args_json="$6"
  mcp_call_tool "$id" "$tool_name" "$args_json" "$session_id" "$token" "$url"
}

extract_tool_text() {
  mcp_extract_text
}

extract_tool_result() {
  mcp_extract_result
}

extract_confirm_token() {
  jq -r 'try (.result.content[0].text | fromjson | .result.confirm_token) catch empty'
}

team_session_status() {
  local session_id="$1"
  local status_raw
  status_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 14 "masc_team_session_status" "$(jq -cn --arg s "$session_id" '{session_id:$s}')")"
  mcp_require_tool_ok "$status_raw"
  printf '%s' "$status_raw" | extract_tool_result | jq -r '.session.status // empty'
}

team_session_events_result() {
  local session_id="$1"
  local event_types_json="$2"
  local limit="${3:-200}"
  local raw
  raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 16 "masc_team_session_events" "$(jq -cn --arg s "$session_id" --argjson event_types "$event_types_json" --argjson limit "$limit" '{session_id:$s,event_types:$event_types,limit:$limit}')")"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | extract_tool_result
}

wait_for_spawn_completions() {
  local session_id="$1"
  local expected_count="$2"
  local deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
  while :; do
    local events_result success_count
    events_result="$(team_session_events_result "$session_id" '["team_step_spawn"]' 400)"
    success_count="$(printf '%s' "$events_result" | jq -r '[.events[]? | select(.detail.success == true)] | length')"
    if [ "$success_count" -ge "$expected_count" ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL: team_step_spawn completions did not arrive in time"
      printf '%s\n' "$events_result"
      exit 1
    fi
    sleep 1
  done
}

wait_for_turn_actor_count() {
  local session_id="$1"
  local min_actors="$2"
  local deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
  while :; do
    local events_result unique_turn_actors
    events_result="$(team_session_events_result "$session_id" '["team_turn"]' 400)"
    unique_turn_actors="$(printf '%s' "$events_result" | jq -r '[.events[]? | .detail.actor // empty | select(. != "")] | unique | length')"
    if [ "$unique_turn_actors" -ge "$min_actors" ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL: expected at least ${min_actors} unique team turn actors"
      printf '%s\n' "$events_result"
      exit 1
    fi
    sleep 1
  done
}

default_worker_batch_json() {
  jq -cn \
    --arg planner_prompt "You are the planner. Inspect the active team session and reply with exactly one concise line: [planner] decomposition and acceptance criteria." \
    --arg implementer_a_prompt "You are implementer-a. Inspect the active team session and reply with exactly one concise line: [implementer-a] backend and runtime work." \
    --arg implementer_b_prompt "You are implementer-b. Inspect the active team session and reply with exactly one concise line: [implementer-b] docs, tests, and harness work." \
    '[
      {spawn_role:"planner",spawn_prompt:$planner_prompt},
      {spawn_role:"implementer-a",spawn_prompt:$implementer_a_prompt},
      {spawn_role:"implementer-b",spawn_prompt:$implementer_b_prompt}
    ]'
}

normalized_worker_batch_json() {
  local batch_json="$1"
  printf '%s' "$batch_json" | jq -c \
    --arg model "$LLAMA_SWARM_MODEL" \
    --arg note "$MODEL_SELECTION_NOTE" \
    '
      if type != "array" or length == 0 then
        error("worker batch must be a non-empty JSON array")
      else
        map(
          if (.spawn_role | type) != "string" or (.spawn_role | gsub("^\\s+|\\s+$";"")) == "" then
            error("each worker batch item must include a non-empty spawn_role")
          elif (.spawn_prompt | type) != "string" or (.spawn_prompt | gsub("^\\s+|\\s+$";"")) == "" then
            error("each worker batch item must include a non-empty spawn_prompt")
          else
            {
              spawn_role: .spawn_role,
              worker_class: (.worker_class // "executor"),
              worker_size: (.worker_size // "lg"),
              spawn_selection_note: $note,
              spawn_prompt: .spawn_prompt,
              spawn_timeout_seconds: (.spawn_timeout_seconds // 90)
            }
          end
        )
      end
    '
}

require_success_response() {
  local payload="$1"
  local label="${2:-supervisor_execution_session response}"
  mcp_require_jsonrpc_ok "$payload" "$label"
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
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SEC ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local health_json
    health_json="$(curl -fsS --http1.1 --max-time 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
    if [ -n "$health_json" ] && printf '%s' "$health_json" | jq -e '.startup.state_ready == true' >/dev/null 2>&1; then
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
  mcp_require_tool_ok "$join_raw"
  local nickname
  nickname="$(parse_nickname_from_text "$join_raw")"
  local token_raw
  token_raw="$(call_tool "$MCP_URL" "$session_id" "" 11 "masc_auth_create_token" "$(jq -cn --arg role "$role" '{role:$role}')")"
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
  join_raw="$(call_tool "$MCP_URL" "$session_id" "$token" 20 "masc_join" "$join_payload")"
  mcp_require_tool_ok "$join_raw"
}

spawn_llama_batch() {
  local batch_json="$1"
  local raw
  raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 30 "masc_team_session_step" "$(jq -cn \
    --arg s "$TEAM_SESSION_ID" \
    --argjson batch "$batch_json" \
    '{session_id:$s,wait_mode:"background",spawn_batch:$batch}')")"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | extract_tool_result | jq -e '.spawn.mode == "batch" and .spawn.count == ($expected | length) and (.spawn.results | length) == ($expected | length) and .turn == null and (.spawn.results | all(.status == "accepted" and .runtime_actor != null and .worker_run_id != null))' --argjson expected "$batch_json" >/dev/null
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
mcp_require_tool_ok "$init_raw"

SUPERVISOR_IDENTITY="$(create_agent_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_AGENT" "admin" '["supervisor","operator"]')"
SUPERVISOR_NICKNAME="${SUPERVISOR_IDENTITY%%|*}"
SUPERVISOR_TOKEN="${SUPERVISOR_IDENTITY##*|}"

enable_auth_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "" 12 "masc_auth_enable" '{"require_token":true}')"
mcp_require_tool_ok "$enable_auth_raw"

printf '[3/10] re-join agents under bearer auth\n'
join_with_token "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" "$SUPERVISOR_NICKNAME" '["supervisor","operator"]'

printf '[4/10] inspect llama inventory and validate explicit model\n'
llama_models_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 13 "masc_llama_models" '{}')"
mcp_require_tool_ok "$llama_models_raw"
llama_models_result="$(printf '%s' "$llama_models_raw" | extract_tool_result)"
if [ -z "$LLAMA_SWARM_MODEL" ]; then
  single_model="$(printf '%s\n' "$llama_models_result" | jq -r 'if (.models | length) == 1 then .models[0] else "" end')"
  if [ -n "$single_model" ]; then
    LLAMA_SWARM_MODEL="$single_model"
    printf 'auto-selected single llama model: %s\n' "$LLAMA_SWARM_MODEL"
  else
    echo "FAIL: LLAMA_SWARM_MODEL is required; available models:"
    printf '%s\n' "$llama_models_result" | jq -r '.models[]?'
    exit 1
  fi
fi
if ! printf '%s' "$llama_models_result" | jq -e --arg model "$LLAMA_SWARM_MODEL" '.models | index($model) != null' >/dev/null; then
  echo "FAIL: LLAMA_SWARM_MODEL not present in inventory: $LLAMA_SWARM_MODEL"
  printf '%s\n' "$llama_models_result" | jq -r '.models[]?'
  exit 1
fi
MODEL_SELECTION_NOTE="[model-selection] leader selected $LLAMA_SWARM_MODEL from masc_llama_models inventory for the supervised llama worker team"
case "$SWARM_INTERVENTION_MODE" in
  default|none) ;;
  *)
    echo "FAIL: unsupported SWARM_INTERVENTION_MODE: $SWARM_INTERVENTION_MODE"
    echo "expected one of: default, none"
    exit 1
    ;;
esac

if [ -z "$SWARM_WORKER_BATCH_JSON" ]; then
  SWARM_WORKER_BATCH_JSON="$(default_worker_batch_json)"
fi
NORMALIZED_SWARM_BATCH_JSON="$(normalized_worker_batch_json "$SWARM_WORKER_BATCH_JSON")"

printf '[5/10] start supervised team session\n'
start_payload="$(jq -cn \
  --arg goal "$TEAM_GOAL" \
  --arg supervisor "$SUPERVISOR_NICKNAME" \
  --argjson duration "$TEAM_SESSION_DURATION_SECONDS" \
  '{goal:$goal, duration_seconds:$duration, checkpoint_interval_sec:15, orchestration_mode:"assist", communication_mode:"broadcast", execution_scope:"limited_code_change", fallback_policy:"cascade_then_task", instruction_profile:"strict", min_agents:4, agents:[$supervisor]}')"
start_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 3 "masc_team_session_start" "$start_payload")"
mcp_require_tool_ok "$start_raw"
TEAM_SESSION_ID="$(printf '%s' "$start_raw" | extract_tool_result | jq -r '.session_id // empty')"
if [ -z "$TEAM_SESSION_ID" ]; then
  echo "FAIL: missing session_id"
  printf '%s\n' "$start_raw"
  exit 1
fi

model_selection_turn_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 14 "masc_team_session_step" "$(jq -cn --arg s "$TEAM_SESSION_ID" --arg msg "$MODEL_SELECTION_NOTE" '{session_id:$s,turn_kind:"note",message:$msg}')")"
mcp_require_tool_ok "$model_selection_turn_raw"

printf '[6/10] spawn full llama team\n'
spawn_batch_raw="$(spawn_llama_batch "$MODEL_SELECTION_NOTE" "$NORMALIZED_SWARM_BATCH_JSON")"
EXPECTED_WORKER_COUNT="$(printf '%s' "$NORMALIZED_SWARM_BATCH_JSON" | jq -r 'length')"

printf '[7/10] inspect remote operator surface\n'
tools_raw="$(jsonrpc_call "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 4 "tools/list" '{}')"
require_success_response "$tools_raw"
tool_count="$(printf '%s' "$tools_raw" | jq -r '.result.tools | length')"
if [ "$tool_count" -ne 4 ]; then
  echo "FAIL: expected 4 operator tools, got $tool_count"
  printf '%s\n' "$tools_raw"
  exit 1
fi
printf '%s' "$tools_raw" | jq -e '.result.tools | map(.name) | sort == ["masc_operator_action","masc_operator_confirm","masc_operator_digest","masc_operator_snapshot"]' >/dev/null

snapshot_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 5 "masc_operator_snapshot" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" '{actor:$actor,view:"full"}')")"
mcp_require_tool_ok "$snapshot_raw"
printf '%s' "$snapshot_raw" | extract_tool_result | jq -e '.sessions.items | length >= 1' >/dev/null
printf '%s' "$snapshot_raw" | extract_tool_result | jq -e '.attention_summary.count >= 0 and .recommendation_summary.count >= 0' >/dev/null

digest_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 55 "masc_operator_digest" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg s "$TEAM_SESSION_ID" '{actor:$actor,target_type:"team_session",target_id:$s}')")"
mcp_require_tool_ok "$digest_raw"
printf '%s' "$digest_raw" | extract_tool_result | jq -e '.target_type == "team_session" and .target_id == $session and (.health | type == "string") and (.attention_items | type == "array") and (.recommended_actions | type == "array")' --arg session "$TEAM_SESSION_ID" >/dev/null

printf '[8/10] supervisor immediate correction via team_note\n'
if [ "$SWARM_INTERVENTION_MODE" = "default" ]; then
  TEAM_SESSION_STATUS="$(team_session_status "$TEAM_SESSION_ID")"
  if [ "$TEAM_SESSION_STATUS" = "running" ]; then
    team_note_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 6 "masc_operator_action" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg s "$TEAM_SESSION_ID" '{actor:$actor,action_type:"team_note",target_id:$s,payload:{message:"[supervisor] keep the proof focused on the MCP loop"}}')")"
    mcp_require_tool_ok "$team_note_raw"
    printf '%s' "$team_note_raw" | extract_tool_text | jq -e '.confirm_required == false' >/dev/null

    printf '[9/10] supervisor disruptive correction via preview + confirm\n'
    preview_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 7 "masc_operator_action" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg s "$TEAM_SESSION_ID" '{actor:$actor,action_type:"team_task_inject",target_id:$s,payload:{title:"Capture explicit supervisor proof",description:"Add evidence that preview-confirm changed the session trajectory.",priority:1}}')")"
    mcp_require_tool_ok "$preview_raw"
    CONFIRM_TOKEN="$(printf '%s' "$preview_raw" | extract_tool_text | jq -r '.confirm_token // empty')"
    if [ -z "$CONFIRM_TOKEN" ]; then
      echo "FAIL: missing confirm token"
      printf '%s\n' "$preview_raw"
      exit 1
    fi

    snapshot_pending_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 8 "masc_operator_snapshot" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" '{actor:$actor,view:"full"}')")"
    mcp_require_tool_ok "$snapshot_pending_raw"
    printf '%s' "$snapshot_pending_raw" | extract_tool_result | jq -e '.pending_confirms | length == 1' >/dev/null

    confirm_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 9 "masc_operator_confirm" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" --arg token "$CONFIRM_TOKEN" '{actor:$actor,confirm_token:$token}')")"
    mcp_require_tool_ok "$confirm_raw"

    snapshot_after_confirm_raw="$(call_tool "$OPERATOR_URL" "$SUPERVISOR_OP_SESSION_ID" "$SUPERVISOR_TOKEN" 12 "masc_operator_snapshot" "$(jq -cn --arg actor "$SUPERVISOR_NICKNAME" '{actor:$actor,view:"full"}')")"
    mcp_require_tool_ok "$snapshot_after_confirm_raw"
    printf '%s' "$snapshot_after_confirm_raw" | extract_tool_result | jq -e '.pending_confirms | length == 0' >/dev/null
  else
    printf '[8/10] skip supervisor correction (session status=%s)\n' "$TEAM_SESSION_STATUS"
  fi
else
  printf '[9/10] supervisor intervention skipped by policy (%s)\n' "$SWARM_INTERVENTION_MODE"
fi

printf '[10/10] stop session and prove evidence\n'
wait_for_spawn_completions "$TEAM_SESSION_ID" "$EXPECTED_WORKER_COUNT"
wait_for_turn_actor_count "$TEAM_SESSION_ID" 3
TEAM_SESSION_STATUS="$(team_session_status "$TEAM_SESSION_ID")"
if [ "$TEAM_SESSION_STATUS" = "running" ]; then
  stop_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 13 "masc_team_session_stop" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,reason:"supervisor_harness_complete",generate_report:true}')")"
  mcp_require_tool_ok "$stop_raw"
else
  echo "skip explicit stop; session already in terminal state: $TEAM_SESSION_STATUS"
fi

deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
while :; do
  status_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 14 "masc_team_session_status" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s}')")"
  mcp_require_tool_ok "$status_raw"
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
mcp_require_tool_ok "$prove_raw"
prove_result="$(printf '%s' "$prove_raw" | extract_tool_result)"
printf '%s' "$prove_result" | jq -e '.proof.verdict == "proved"' >/dev/null
printf '%s' "$prove_result" | jq -e '.proof.evidence.unique_turn_actors_count >= 3' >/dev/null
printf '%s' "$prove_result" | jq -e '.proof.evidence.spawn_success_count >= 2' >/dev/null
printf '%s' "$prove_result" | jq -e '.proof.evidence.empty_note_turn_count == 0' >/dev/null
report_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 18 "masc_team_session_report" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,force_regenerate:false}')")"
mcp_require_tool_ok "$report_raw"
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
mcp_require_tool_ok "$events_raw"
events_result="$(printf '%s' "$events_raw" | extract_tool_result)"
unique_turn_actors="$(printf '%s' "$events_result" | jq -r '[.events[]? | .detail.actor // empty | select(. != "")] | unique | length')"
spawn_events_raw="$(call_tool "$MCP_URL" "$SUPERVISOR_SESSION_ID" "$SUPERVISOR_TOKEN" 17 "masc_team_session_events" "$(jq -cn --arg s "$TEAM_SESSION_ID" '{session_id:$s,event_types:["team_step_spawn"],limit:200}')")"
mcp_require_tool_ok "$spawn_events_raw"
spawn_events_result="$(printf '%s' "$spawn_events_raw" | extract_tool_result)"
unique_spawned_llama_actors="$(printf '%s' "$spawn_events_result" | jq -r '[.events[]? | .detail.runtime_actor // empty | select(. != "")] | unique | length')"
if [ "$unique_spawned_llama_actors" -lt 3 ]; then
  echo "FAIL: expected at least 3 unique spawned llama actors, got $unique_spawned_llama_actors"
  printf '%s\n' "$spawn_events_result"
  exit 1
fi
printf '%s' "$spawn_events_result" | jq -e --arg note "$MODEL_SELECTION_NOTE" '[.events[]? | .detail.spawn_selection_note // empty] | all(startswith($note))' >/dev/null
proof_json_path="$(printf '%s' "$prove_result" | jq -r '.proof_json_path // empty')"
proof_md_path="$(printf '%s' "$prove_result" | jq -r '.proof_md_path // empty')"

printf 'session_id=%s\n' "$TEAM_SESSION_ID"
printf 'llama_swarm_model=%s\n' "$LLAMA_SWARM_MODEL"
printf 'swarm_intervention_mode=%s\n' "$SWARM_INTERVENTION_MODE"
printf 'spawned_worker_roles=%s\n' "$(printf '%s' "$spawn_batch_raw" | extract_tool_result | jq -c '[.spawn.results[] | .spawn_role]')"
printf 'spawned_runtime_actors=%s\n' "$(printf '%s' "$spawn_batch_raw" | extract_tool_result | jq -c '[.spawn.results[] | .runtime_actor]')"
printf 'unique_turn_actors=%s\n' "$unique_turn_actors"
printf 'unique_spawned_llama_actors=%s\n' "$unique_spawned_llama_actors"
printf 'proof_json_path=%s\n' "$proof_json_path"
printf 'proof_md_path=%s\n' "$proof_md_path"
echo 'PASS: supervisor team session harness'
