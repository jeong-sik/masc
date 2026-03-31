#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8945/mcp}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"
COORD_AGENT="${COORD_AGENT:-team-session-local64-context-chaos}"
WORKER_COUNT="${WORKER_COUNT:-4}"
PRESSURE_WORKER_COUNT="${PRESSURE_WORKER_COUNT:-2}"
PRESSURE_CONTEXT_RATIO="${PRESSURE_CONTEXT_RATIO:-0.79}"
PRESSURE_CONTEXT_LINES="${PRESSURE_CONTEXT_LINES:-4}"
SESSION_DURATION_SEC="${SESSION_DURATION_SEC:-2400}"
default_spawn_timeout=$((WORKER_COUNT * 45))
if [ "$default_spawn_timeout" -lt 240 ]; then
  default_spawn_timeout=240
fi
SPAWN_TIMEOUT_SEC="${SPAWN_TIMEOUT_SEC:-$default_spawn_timeout}"
default_http_timeout=$((SPAWN_TIMEOUT_SEC + 300))
min_http_timeout=$((WORKER_COUNT * 55))
if [ "$default_http_timeout" -lt "$min_http_timeout" ]; then
  default_http_timeout="$min_http_timeout"
fi
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-$default_http_timeout}"
WAIT_AFTER_SPAWN_SEC="${WAIT_AFTER_SPAWN_SEC:-3}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"
MCP_SESSION_ID="${MCP_SESSION_ID:-team-session-local64-context-chaos-$(date +%s)-$RANDOM}"
GOAL="${GOAL:-Validate local64 pressure workers can execute memento checks without breaking local64 visibility}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

if [ "$PRESSURE_WORKER_COUNT" -gt "$WORKER_COUNT" ]; then
  echo "FAIL: PRESSURE_WORKER_COUNT (${PRESSURE_WORKER_COUNT}) must be <= WORKER_COUNT (${WORKER_COUNT})"
  exit 1
fi

SESSION_ID=""

require_result_condition() {
  local payload="$1"
  local jq_expr="$2"
  local failure_message="$3"
  local result_json
  result_json="$(printf '%s' "$payload" | mcp_extract_result)"
  if ! printf '%s' "$result_json" | jq -e "$jq_expr" >/dev/null; then
    echo "FAIL: $failure_message"
    printf '%s\n' "$result_json"
    exit 1
  fi
}

cleanup() {
  if [ -n "$SESSION_ID" ]; then
    mcp_call_tool 93981 "masc_team_session_stop" \
      "{\"session_id\":\"$SESSION_ID\",\"reason\":\"local64_context_chaos_cleanup\",\"generate_report\":false}" \
      >/dev/null 2>&1 || true
  fi
  mcp_call_tool 93982 "masc_leave" "{\"agent_name\":\"$COORD_AGENT\"}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_pressure_context() {
  local actor="$1"
  local idx=1
  while [ "$idx" -le "$PRESSURE_CONTEXT_LINES" ]; do
    printf 'capsule[%03d] actor=%s session=%s role=pressure summary=maintain-local64-visibility repeated-context-window\n' \
      "$idx" "$actor" "$SESSION_ID"
    idx=$((idx + 1))
  done
}

build_spawn_batch() {
  local session_id="$1"
  local worker_count="$2"
  local pressure_worker_count="$3"
  local model="$4"
  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/local64-context-chaos-batch.XXXXXX.json")"
  : >"$tmp_file"

  local idx=1
  while [ "$idx" -le "$worker_count" ]; do
    local role="executor"
    local spawn_role="executor-${idx}"
    local capsule_mode="inherit"
    local actor
    actor="$(printf 'local64-context-%02d' "$idx")"

    if [ "$idx" -le "$pressure_worker_count" ]; then
      case "$idx" in
        1)
          role="manager"
          spawn_role="pressure-manager"
          ;;
        2)
          role="metacog"
          spawn_role="pressure-metacog"
          ;;
        3)
          role="librarian"
          spawn_role="pressure-librarian"
          ;;
        *)
          role="scout"
          spawn_role="pressure-scout-${idx}"
          ;;
      esac
      capsule_mode="capsule"
    fi

    local prompt
    if [ "$idx" -le "$pressure_worker_count" ]; then
      local pressure_context
      pressure_context="$(build_pressure_context "$actor")"
      prompt="$(
        printf '%s\n' \
          "너의 에이전트 이름은 ${actor} 이다. 너는 local64 context pressure worker 이다." \
          "반드시 masc_memento_mori 를 먼저 호출하고, 바로 이어서 masc_team_session_turn 를 호출해라." \
          "1) 아래 context 블록 전체를 full_context 로 사용해서 mcp__masc__masc_memento_mori 를 호출해라." \
          "2) masc_memento_mori 인자에는 context_ratio=${PRESSURE_CONTEXT_RATIO}, current_task=\"local64-context-chaos\", summary=\"${actor} pressure capsule\", full_context=\"[FULL_CONTEXT_BEGIN] 과 [FULL_CONTEXT_END] 사이 전체 문자열\" 네 개만 넣어라. target_agent 는 넣지 마라." \
          "3) 바로 mcp__masc__masc_team_session_turn(session_id=\"${session_id}\", turn_kind=\"note\", message=\"[${actor}] pressure memento-called context_ratio=${PRESSURE_CONTEXT_RATIO}\") 를 호출해라." \
          "4) 마지막 답변은 한 줄로 done:${actor}:pressure:memento-called 만 출력해라." \
          "" \
          "[FULL_CONTEXT_BEGIN]" \
          "${pressure_context}" \
          "[FULL_CONTEXT_END]"
      )"
    else
      prompt="$(
        printf '%s\n' \
          "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
          "1) mcp__masc__masc_team_session_turn(session_id=\"${session_id}\", turn_kind=\"note\", message=\"[${actor}] executor online for local64 context chaos\") 를 호출해라." \
          "2) 마지막 답변은 한 줄로 done:${actor}:executor:note-recorded 만 출력해라."
      )"
    fi

    if [ -n "$model" ]; then
      jq -cn \
        --arg prompt "$prompt" \
        --arg role "$spawn_role" \
        --arg worker_class "$role" \
        --arg capsule_mode "$capsule_mode" \
        --arg runtime_pool "local64" \
        --arg model "$model" \
        '{spawn_prompt:$prompt,spawn_role:$role,worker_class:$worker_class,capsule_mode:$capsule_mode,runtime_pool:$runtime_pool}' \
        >>"$tmp_file"
    else
      jq -cn \
        --arg prompt "$prompt" \
        --arg role "$spawn_role" \
        --arg worker_class "$role" \
        --arg capsule_mode "$capsule_mode" \
        --arg runtime_pool "local64" \
        '{spawn_prompt:$prompt,spawn_role:$role,worker_class:$worker_class,capsule_mode:$capsule_mode,runtime_pool:$runtime_pool}' \
        >>"$tmp_file"
    fi
    idx=$((idx + 1))
  done

  jq -s . "$tmp_file"
  rm -f "$tmp_file"
}

echo "[1/8] init + join coordinator"
init_raw="$(mcp_call_tool 93901 "masc_init" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a}')")"
mcp_require_tool_ok "$init_raw"
join_raw="$(mcp_call_tool 93902 "masc_join" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a,capabilities:["team-session","local64","operator","context-chaos"]}')")"
mcp_require_tool_ok "$join_raw"

echo "[2/8] start local64 context-chaos session"
start_args="$(jq -cn --arg goal "$GOAL" --argjson duration "$SESSION_DURATION_SEC" \
  '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:20,min_agents:1,orchestration_mode:"assist",communication_mode:"hybrid",scale_profile:"local64",fallback_policy:"strict_local_only",instruction_profile:"strict",alert_channel:"both",report_formats:["markdown","json"],agents:["team-session-local64-context-chaos"]}')"
start_raw="$(mcp_call_tool 93903 "masc_team_session_start" "$start_args")"
mcp_require_tool_ok "$start_raw"
SESSION_ID="$(printf '%s' "$start_raw" | mcp_extract_result | jq -r '.session_id // empty')"
if [ -z "$SESSION_ID" ]; then
  echo "FAIL: session_id missing"
  printf '%s\n' "$start_raw"
  exit 1
fi
echo "session_id=$SESSION_ID"

echo "[3/8] inspect runtime pool"
runtime_raw="$(mcp_call_tool 93904 "masc_llama_runtime_status" '{"include_models":true}')"
mcp_require_tool_ok "$runtime_raw"
require_result_condition "$runtime_raw" '.runtime_count >= 1 and .configured_capacity >= 1' "runtime status missing local64 runtime data"

echo "[4/8] spawn pressure batch (spawn_timeout=${SPAWN_TIMEOUT_SEC}s http_timeout=${HTTP_TIMEOUT_SEC}s workers=${WORKER_COUNT} pressure=${PRESSURE_WORKER_COUNT})"
spawn_batch_json="$(build_spawn_batch "$SESSION_ID" "$WORKER_COUNT" "$PRESSURE_WORKER_COUNT" "$LLAMA_SWARM_MODEL")"
step_args="$(jq -cn --arg s "$SESSION_ID" --arg a "$COORD_AGENT" --argjson batch "$spawn_batch_json" --argjson timeout "$SPAWN_TIMEOUT_SEC" \
  '{session_id:$s,actor:$a,spawn_batch:$batch,spawn_timeout_seconds:$timeout}')"
step_raw="$(mcp_call_tool 93905 "masc_team_session_step" "$step_args")"
mcp_require_tool_ok "$step_raw"
require_result_condition "$step_raw" '
  if .spawn == null then false
  else
    ((.spawn.results | map(select(.success == true)) | length) >= '"$WORKER_COUNT"')
    and
    ((.spawn.results
      | map(select(
          (.spawn_role | tostring | startswith("pressure-"))
          and (
            (.output_preview | tostring | contains("memento-called"))
            or (.output_preview | tostring | contains("masc_memento_mori"))
          )
        ))
      | length) >= '"$PRESSURE_WORKER_COUNT"')
  end
' "pressure workers did not complete memento flow"

echo "[5/8] wait for events to settle"
sleep "$WAIT_AFTER_SPAWN_SEC"

echo "[6/8] verify team session status visibility"
status_raw="$(mcp_call_tool 93906 "masc_team_session_status" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s}')")"
mcp_require_tool_ok "$status_raw"
require_result_condition "$status_raw" '
  .summary.scale_profile == "local64"
  and (.summary.planned_worker_count >= '"$WORKER_COUNT"')
  and ((.summary.worker_class_counts.manager // 0) >= 1)
  and ((.summary.worker_class_counts.metacog // 0) >= 1)
  and ((.summary.worker_class_counts.librarian // 0) >= 1)
  and ((.summary.runtime_pool_counts.local64 // 0) >= '"$WORKER_COUNT"')
  and (.local_runtime != null)
' "session status did not expose local64 pressure visibility"

echo "[7/8] verify operator digest"
digest_raw="$(mcp_call_tool 93907 "masc_operator_digest" '{"target_type":"room"}')"
mcp_require_tool_ok "$digest_raw"
require_result_condition "$digest_raw" '
  ((.role_census.manager // 0) >= 1)
  and ((.role_census.metacog // 0) >= 1)
  and ((.role_census.librarian // 0) >= 1)
  and ((.runtime_pools.local64 // 0) >= '"$WORKER_COUNT"')
  and (.local_runtime != null)
' "operator digest did not expose local64 census/runtime state"

echo "[8/8] benchmark runtime pool"
bench_raw="$(mcp_call_tool 93908 "masc_llama_runtime_bench" '{"parallelism":8,"rounds":1,"runtime_pool":"local64"}')"
mcp_require_tool_ok "$bench_raw"
require_result_condition "$bench_raw" '.total_requests >= 1 and .per_runtime_breakdown != null' "runtime bench did not return local64 breakdown"

echo "PASS: local64 context chaos session=${SESSION_ID} workers=${WORKER_COUNT} pressure_workers=${PRESSURE_WORKER_COUNT}"
