#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/jsonrpc_sse.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
COORD_AGENT="${COORD_AGENT:-team-session-local64-smoke}"
WORKER_COUNT="${WORKER_COUNT:-8}"
SESSION_DURATION_SEC="${SESSION_DURATION_SEC:-900}"
SPAWN_TIMEOUT_SEC="${SPAWN_TIMEOUT_SEC:-240}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-$((SPAWN_TIMEOUT_SEC + 120))}"
WAIT_AFTER_SPAWN_SEC="${WAIT_AFTER_SPAWN_SEC:-3}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"
MCP_SESSION_ID="${MCP_SESSION_ID:-team-session-local64-$(date +%s)-$RANDOM}"
GOAL="${GOAL:-Validate local64 swarm role coverage, runtime visibility, and operator census}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

SESSION_ID=""

jsonrpc_call() {
  local id="$1"
  local method="$2"
  local params="$3"
  local raw
  raw="$(curl -sS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $MCP_SESSION_ID" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\",\"params\":$params}")"
  jsonrpc_normalize_response "$raw" "$id"
}

call_tool() {
  local id="$1"
  local tool_name="$2"
  local args_json="$3"
  jsonrpc_call "$id" "tools/call" "{\"name\":\"$tool_name\",\"arguments\":$args_json}"
}

extract_text() {
  jq -r 'try (.result.content[0].text) catch empty'
}

extract_result() {
  jq -c 'try (.result.content[0].text | fromjson | if has("result") and .result != null then .result else . end) catch empty'
}

extract_is_error() {
  jq -r 'try (.result.isError) catch "true"'
}

require_json() {
  local payload="$1"
  if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    echo "FAIL: invalid payload"
    printf '%s\n' "$payload"
    exit 1
  fi
}

require_tool_success() {
  local payload="$1"
  require_json "$payload"
  local is_error
  is_error="$(printf '%s' "$payload" | extract_is_error)"
  if [ "$is_error" = "true" ]; then
    echo "FAIL: tool returned isError=true"
    printf '%s\n' "$payload" | extract_text
    exit 1
  fi
}

require_result_condition() {
  local payload="$1"
  local jq_expr="$2"
  local failure_message="$3"
  local result_json
  result_json="$(printf '%s' "$payload" | extract_result)"
  if ! printf '%s' "$result_json" | jq -e "$jq_expr" >/dev/null; then
    echo "FAIL: $failure_message"
    printf '%s\n' "$result_json"
    exit 1
  fi
}

cleanup() {
  if [ -n "$SESSION_ID" ]; then
    call_tool 90981 "masc_team_session_stop" \
      "{\"session_id\":\"$SESSION_ID\",\"reason\":\"local64_smoke_cleanup\",\"generate_report\":false}" \
      >/dev/null 2>&1 || true
  fi
  call_tool 90982 "masc_leave" "{\"agent_name\":\"$COORD_AGENT\"}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_spawn_batch() {
  local session_id="$1"
  local worker_count="$2"
  local model="$3"
  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/local64-smoke-batch.XXXXXX.json")"
  : >"$tmp_file"

  local idx=1
  while [ "$idx" -le "$worker_count" ]; do
    local role="executor"
    local spawn_role="executor-${idx}"
    local capsule_mode="inherit"
    case "$idx" in
      1)
        role="manager"
        spawn_role="middle-manager"
        capsule_mode="capsule"
        ;;
      2)
        role="metacog"
        spawn_role="metacog-observer"
        capsule_mode="capsule"
        ;;
      3)
        role="librarian"
        spawn_role="knowledge-librarian"
        capsule_mode="capsule"
        ;;
      4)
        role="scout"
        spawn_role="research-scout"
        capsule_mode="fresh"
        ;;
    esac

    local actor
    actor="$(printf 'local64-smoke-%02d' "$idx")"
    local prompt
    prompt="$(
      printf '%s\n' \
        "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
        "1) mcp__masc__masc_join(agent_name=\"${actor}\", capabilities=[\"swarm\",\"${role}\"])" \
        "2) mcp__masc__masc_team_session_turn(session_id=\"${session_id}\", turn_kind=\"note\", message=\"[${actor}] ${role} online for local64 smoke\")" \
        "3) mcp__masc__masc_leave(agent_name=\"${actor}\")" \
        "마지막 답변은 한 줄로 \"done:${actor}\"만 출력해라."
    )"

    if [ -n "$model" ]; then
      jq -cn \
        --arg prompt "$prompt" \
        --arg role "$spawn_role" \
        --arg worker_class "$role" \
        --arg capsule_mode "$capsule_mode" \
        --arg runtime_pool "local64" \
        --arg model "$model" \
        '{spawn_agent:"llama",spawn_prompt:$prompt,spawn_role:$role,worker_class:$worker_class,capsule_mode:$capsule_mode,runtime_pool:$runtime_pool,spawn_model:$model}' \
        >>"$tmp_file"
    else
      jq -cn \
        --arg prompt "$prompt" \
        --arg role "$spawn_role" \
        --arg worker_class "$role" \
        --arg capsule_mode "$capsule_mode" \
        --arg runtime_pool "local64" \
        '{spawn_agent:"llama",spawn_prompt:$prompt,spawn_role:$role,worker_class:$worker_class,capsule_mode:$capsule_mode,runtime_pool:$runtime_pool}' \
        >>"$tmp_file"
    fi
    idx=$((idx + 1))
  done

  jq -s . "$tmp_file"
  rm -f "$tmp_file"
}

echo "[1/8] init + join coordinator"
init_raw="$(call_tool 91001 "masc_init" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a}')")"
require_tool_success "$init_raw"
join_raw="$(call_tool 91002 "masc_join" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a,capabilities:["team-session","local64","operator"]}')")"
require_tool_success "$join_raw"

echo "[2/8] start local64 session"
start_args="$(jq -cn --arg goal "$GOAL" --argjson duration "$SESSION_DURATION_SEC" \
  '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:20,min_agents:1,orchestration_mode:"assist",communication_mode:"hybrid",scale_profile:"local64",fallback_policy:"strict_local_only",instruction_profile:"strict",alert_channel:"both",report_formats:["markdown","json"],agents:["team-session-local64-smoke"]}')"
start_raw="$(call_tool 91003 "masc_team_session_start" "$start_args")"
require_tool_success "$start_raw"
SESSION_ID="$(printf '%s' "$start_raw" | extract_result | jq -r '.session_id // empty')"
if [ -z "$SESSION_ID" ]; then
  echo "FAIL: session_id missing"
  printf '%s\n' "$start_raw"
  exit 1
fi
echo "session_id=$SESSION_ID"

echo "[3/8] inspect local llama runtime"
runtime_raw="$(call_tool 91004 "masc_llama_runtime_status" '{"include_models":true}')"
require_tool_success "$runtime_raw"
require_result_condition "$runtime_raw" '.runtime_count >= 1 and .configured_capacity >= 1' "runtime status missing pool data"

echo "[4/8] spawn local64 batch"
spawn_batch_json="$(build_spawn_batch "$SESSION_ID" "$WORKER_COUNT" "$LLAMA_SWARM_MODEL")"
step_args="$(jq -cn --arg s "$SESSION_ID" --arg a "$COORD_AGENT" --argjson batch "$spawn_batch_json" --argjson timeout "$SPAWN_TIMEOUT_SEC" \
  '{session_id:$s,actor:$a,spawn_batch:$batch,spawn_timeout_seconds:$timeout}')"
step_raw="$(call_tool 91005 "masc_team_session_step" "$step_args")"
require_tool_success "$step_raw"
require_result_condition "$step_raw" '
  if .spawn == null then false
  else
    ((.spawn.results | map(select(.success == true)) | length) >= '"$WORKER_COUNT"')
  end
' "spawn batch did not return the requested number of successful workers"

echo "[5/8] wait for events to settle"
sleep "$WAIT_AFTER_SPAWN_SEC"

echo "[6/8] verify team session status visibility"
status_raw="$(call_tool 91006 "masc_team_session_status" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s}')")"
require_tool_success "$status_raw"
require_result_condition "$status_raw" '
  .summary.scale_profile == "local64"
  and (.summary.planned_worker_count >= '"$WORKER_COUNT"')
  and ((.summary.worker_class_counts.manager // 0) >= 1)
  and ((.summary.worker_class_counts.metacog // 0) >= 1)
  and ((.summary.worker_class_counts.librarian // 0) >= 1)
  and ((.summary.worker_class_counts.scout // 0) >= 1)
  and ((.summary.runtime_pool_counts.local64 // 0) >= '"$WORKER_COUNT"')
  and (.local_runtime != null)
' "session status did not expose local64 role/runtime visibility"

echo "[7/8] verify operator room census"
digest_raw="$(call_tool 91007 "masc_operator_digest" '{"target_type":"room"}')"
require_tool_success "$digest_raw"
require_result_condition "$digest_raw" '
  ((.role_census.manager // 0) >= 1)
  and ((.role_census.metacog // 0) >= 1)
  and ((.runtime_pools.local64 // 0) >= '"$WORKER_COUNT"')
  and (.local_runtime != null)
' "operator digest did not expose local64 census/runtime visibility"

echo "[8/8] benchmark runtime pool"
bench_raw="$(call_tool 91008 "masc_llama_runtime_bench" '{"parallelism":8,"rounds":1,"runtime_pool":"local64"}')"
require_tool_success "$bench_raw"
require_result_condition "$bench_raw" '.total_requests >= 1 and .per_runtime_breakdown != null' "runtime bench did not return breakdown"

echo "PASS: local64 smoke session=${SESSION_ID} workers=${WORKER_COUNT}"
