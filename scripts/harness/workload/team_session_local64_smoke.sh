#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
COORD_AGENT="${COORD_AGENT:-team-session-local64-smoke}"
WORKER_COUNT="${WORKER_COUNT:-8}"
SESSION_DURATION_SEC="${SESSION_DURATION_SEC:-900}"
default_spawn_timeout=$((WORKER_COUNT * 45))
if [ "$default_spawn_timeout" -lt 240 ]; then
  default_spawn_timeout=240
fi
SPAWN_TIMEOUT_SEC="${SPAWN_TIMEOUT_SEC:-$default_spawn_timeout}"
default_http_timeout=$((SPAWN_TIMEOUT_SEC + 300))
min_http_timeout=$((WORKER_COUNT * 50))
if [ "$default_http_timeout" -lt "$min_http_timeout" ]; then
  default_http_timeout="$min_http_timeout"
fi
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-$default_http_timeout}"
WAIT_AFTER_SPAWN_SEC="${WAIT_AFTER_SPAWN_SEC:-3}"
WAVE_SETTLE_SEC="${WAVE_SETTLE_SEC:-15}"
WAVE_PROGRESS_TIMEOUT_SEC="${WAVE_PROGRESS_TIMEOUT_SEC:-180}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"
LOCAL64_ROUTER_MODE="${LOCAL64_ROUTER_MODE:-hybrid}"
MCP_SESSION_ID="${MCP_SESSION_ID:-team-session-local64-$(date +%s)-$RANDOM}"
GOAL="${GOAL:-Validate local64 swarm role coverage, runtime visibility, and operator census}"
default_final_turn_timeout=$((WORKER_COUNT * 30))
if [ "$default_final_turn_timeout" -lt 300 ]; then
  default_final_turn_timeout=300
fi
FINAL_TURN_TIMEOUT_SEC="${FINAL_TURN_TIMEOUT_SEC:-$default_final_turn_timeout}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

SESSION_ID=""
CALL_ID=91008
SPAWN_RESULTS_FILE="$(mcp_mktemp_file "local64-smoke-spawn-results" ".jsonl")"

next_call_id() {
  CALL_ID=$((CALL_ID + 1))
  printf '%s\n' "$CALL_ID"
}

session_status_result() {
  local raw
  raw="$(mcp_call_tool "$(next_call_id)" "masc_team_session_status" \
    "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s}')")"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | mcp_extract_result
}

session_events_result() {
  local limit="${1:-2000}"
  local raw
  raw="$(mcp_call_tool "$(next_call_id)" "masc_team_session_events" \
    "$(jq -cn --arg s "$SESSION_ID" --argjson limit "$limit" '{session_id:$s,limit:$limit}')")"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | mcp_extract_result
}

operator_digest_result() {
  local raw
  raw="$(mcp_call_tool "$(next_call_id)" "masc_operator_digest" '{"target_type":"room"}')"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | mcp_extract_result
}

append_spawn_results() {
  local payload="$1"
  printf '%s' "$payload" | mcp_extract_result | jq -c '
    if .spawn.results? then
      .spawn.results[]
    else
      .spawn
    end
  ' >>"$SPAWN_RESULTS_FILE"
}

count_step_accepts() {
  local payload="$1"
  printf '%s' "$payload" | mcp_extract_result | jq '
    if .spawn.results? then
      [.spawn.results[] | select((.status // "") == "accepted" or .success == true)] | length
    else
      (if (.spawn.status // "") == "accepted" or .spawn.success == true then 1 else 0 end)
    end
  '
}

count_event_type() {
  local events_json="$1"
  local event_type="$2"
  printf '%s' "$events_json" | jq --arg event_type "$event_type" \
    '[.events[] | select(.event_type == $event_type)] | length'
}

wait_for_session_progress() {
  local min_attached="$1"
  local min_turns="$2"
  local timeout_sec="$3"
  local deadline=$((SECONDS + timeout_sec))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local events_json attached_count turn_count
    events_json="$(session_events_result 2000)"
    attached_count="$(count_event_type "$events_json" "session_agent_attached")"
    turn_count="$(count_event_type "$events_json" "team_turn")"
    if [ "$attached_count" -ge "$min_attached" ] && [ "$turn_count" -ge "$min_turns" ]; then
      printf '%s' "$events_json"
      return 0
    fi
    sleep 5
  done
  echo "FAIL: session progress wait timed out (attached>=$min_attached turns>=$min_turns)" >&2
  session_events_result 2000 | jq .
  exit 1
}

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

require_json_condition() {
  local result_json="$1"
  local jq_expr="$2"
  local failure_message="$3"
  if ! printf '%s' "$result_json" | jq -e "$jq_expr" >/dev/null; then
    echo "FAIL: $failure_message"
    printf '%s\n' "$result_json" | jq .
    exit 1
  fi
}

cleanup() {
  if [ -n "$SESSION_ID" ]; then
    mcp_call_tool 90981 "masc_team_session_stop" \
      "{\"session_id\":\"$SESSION_ID\",\"reason\":\"local64_smoke_cleanup\",\"generate_report\":false}" \
      >/dev/null 2>&1 || true
  fi
  mcp_call_tool 90982 "masc_leave" "{\"agent_name\":\"$COORD_AGENT\"}" >/dev/null 2>&1 || true
  rm -f "$SPAWN_RESULTS_FILE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_spawn_batch() {
  local start_idx="$1"
  local end_idx="$2"
  local model="$3"
  local tmp_file
  tmp_file="$(mcp_mktemp_file "local64-smoke-batch" ".json")"
  : >"$tmp_file"

  local idx="$start_idx"
  while [ "$idx" -le "$end_idx" ]; do
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
    local task_profile=""
    if [ "$LOCAL64_ROUTER_MODE" = "hybrid" ]; then
      case "$role" in
        manager)
          task_profile="decide"
          prompt="$(
            printf '%s\n' \
              "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
              "이 작업은 session routing/decide 성격이다." \
              "worker runtime이 이미 join/leave를 처리하므로 tool 호출 없이 최종 답변만 남겨라." \
              "masc_team_session_step, masc_team_session_turn, masc_join, masc_leave를 호출하지 마라." \
              "마지막 답변은 정확히 한 줄: \"[${actor}] manager decide online for hybrid smoke\""
          )"
          ;;
        metacog)
          task_profile="verify"
          prompt="$(
            printf '%s\n' \
              "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
              "이 작업은 session verify 성격이다." \
              "worker runtime이 이미 join/leave를 처리하므로 tool 호출 없이 최종 답변만 남겨라." \
              "masc_team_session_step, masc_team_session_turn, masc_join, masc_leave를 호출하지 마라." \
              "마지막 답변은 정확히 한 줄: \"[${actor}] metacog verify online for hybrid smoke\""
          )"
          ;;
        librarian)
          task_profile="summarize"
          prompt="$(
            printf '%s\n' \
              "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
              "이 작업은 short answer summarize 성격이다." \
              "worker runtime이 이미 join/leave를 처리하므로 tool 호출 없이 최종 답변만 남겨라." \
              "masc_team_session_step, masc_team_session_turn, masc_join, masc_leave를 호출하지 마라." \
              "마지막 답변은 정확히 한 줄: \"[${actor}] librarian summarize online for hybrid smoke\""
          )"
          ;;
        scout)
          task_profile="extract"
          prompt="$(
            printf '%s\n' \
              "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
              "이 작업은 fetch and collect source extract 성격이다." \
              "worker runtime이 이미 join/leave를 처리하므로 tool 호출 없이 최종 답변만 남겨라." \
              "masc_team_session_step, masc_team_session_turn, masc_join, masc_leave를 호출하지 마라." \
              "마지막 답변은 정확히 한 줄: \"[${actor}] scout extract online for hybrid smoke\""
          )"
          ;;
        *)
          task_profile="normalize"
          prompt="$(
            printf '%s\n' \
              "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
              "이 작업은 normalize evidence into strict JSON schema 성격이다." \
              "worker runtime이 이미 join/leave를 처리하므로 tool 호출 없이 최종 답변만 남겨라." \
              "masc_team_session_step, masc_team_session_turn, masc_join, masc_leave를 호출하지 마라." \
              "마지막 답변은 정확히 한 줄: \"[${actor}] executor normalize online for hybrid smoke\""
          )"
          ;;
      esac
    else
      prompt="$(
        printf '%s\n' \
          "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
          "worker runtime이 이미 join/leave를 처리하므로 tool 호출 없이 최종 답변만 남겨라." \
          "masc_team_session_step, masc_team_session_turn, masc_join, masc_leave를 호출하지 마라." \
          "마지막 답변은 정확히 한 줄: \"[${actor}] ${role} online for local64 smoke\""
      )"
    fi

    if [ "$LOCAL64_ROUTER_MODE" = "hybrid" ]; then
      jq -cn \
        --arg prompt "$prompt" \
        --arg role "$spawn_role" \
        --arg worker_class "$role" \
        --arg capsule_mode "$capsule_mode" \
        --arg runtime_pool "local64" \
        --arg task_profile "$task_profile" \
        '{spawn_prompt:$prompt,spawn_role:$role,worker_class:$worker_class,capsule_mode:$capsule_mode,runtime_pool:$runtime_pool,task_profile:$task_profile}' \
        >>"$tmp_file"
    elif [ -n "$model" ]; then
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

run_spawn_wave() {
  local wave_name="$1"
  local start_idx="$2"
  local end_idx="$3"
  local min_attached="$4"
  local min_turns="$5"
  if [ "$start_idx" -gt "$end_idx" ]; then
    return 0
  fi

  local expected_count=$((end_idx - start_idx + 1))
  echo "[4/8] spawn ${wave_name} (${start_idx}-${end_idx}, count=${expected_count})"
  local spawn_batch_json step_args step_raw wave_success
  spawn_batch_json="$(build_spawn_batch "$start_idx" "$end_idx" "$LLAMA_SWARM_MODEL")"
  step_args="$(jq -cn --arg s "$SESSION_ID" --arg a "$COORD_AGENT" --argjson batch "$spawn_batch_json" --argjson timeout "$SPAWN_TIMEOUT_SEC" \
    '{session_id:$s,actor:$a,wait_mode:"background",spawn_batch:$batch,spawn_timeout_seconds:$timeout}')"
  step_raw="$(mcp_call_tool "$(next_call_id)" "masc_team_session_step" "$step_args")"
  mcp_require_tool_ok "$step_raw"
  append_spawn_results "$step_raw"
  wave_success="$(count_step_accepts "$step_raw")"
  if [ "$wave_success" -lt "$expected_count" ]; then
    echo "FAIL: ${wave_name} spawn accepted ${wave_success}/${expected_count}" >&2
    printf '%s\n' "$step_raw" | mcp_extract_result | jq .
    exit 1
  fi

  sleep "$WAVE_SETTLE_SEC"
  wait_for_session_progress "$min_attached" "$min_turns" "$WAVE_PROGRESS_TIMEOUT_SEC" >/dev/null
}

echo "[1/8] init + join coordinator"
init_raw="$(mcp_call_tool 91001 "masc_init" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a}')")"
mcp_require_tool_ok "$init_raw"
join_raw="$(mcp_call_tool 91002 "masc_join" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a,capabilities:["team-session","local64","operator"]}')")"
mcp_require_tool_ok "$join_raw"

echo "[2/8] start local64 session"
start_args="$(jq -cn --arg goal "$GOAL" --argjson duration "$SESSION_DURATION_SEC" \
  '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:20,min_agents:1,orchestration_mode:"assist",communication_mode:"hybrid",scale_profile:"local64",fallback_policy:"strict_local_only",instruction_profile:"strict",alert_channel:"both",report_formats:["markdown","json"],agents:["team-session-local64-smoke"]}')"
start_raw="$(mcp_call_tool 91003 "masc_team_session_start" "$start_args")"
mcp_require_tool_ok "$start_raw"
SESSION_ID="$(printf '%s' "$start_raw" | mcp_extract_result | jq -r '.session_id // empty')"
if [ -z "$SESSION_ID" ]; then
  echo "FAIL: session_id missing"
  printf '%s\n' "$start_raw"
  exit 1
fi
echo "session_id=$SESSION_ID"

echo "[3/8] inspect local llama runtime"
runtime_raw="$(mcp_call_tool 91004 "masc_local_runtime_status" '{"include_models":true}')"
mcp_require_tool_ok "$runtime_raw"
require_result_condition "$runtime_raw" '.runtime_count >= 1 and .configured_capacity >= 1' "runtime status missing pool data"

echo "[4/8] spawn local64 workers (spawn_timeout=${SPAWN_TIMEOUT_SEC}s http_timeout=${HTTP_TIMEOUT_SEC}s workers=${WORKER_COUNT})"
if [ "$LOCAL64_ROUTER_MODE" = "hybrid" ] && [ "$WORKER_COUNT" -ge 16 ]; then
  controller_count=4
  if [ "$WORKER_COUNT" -lt "$controller_count" ]; then
    controller_count="$WORKER_COUNT"
  fi
  if [ "$controller_count" -gt 0 ]; then
    run_spawn_wave "controller-wave" 1 "$controller_count" "$controller_count" "$controller_count"
  fi

  next_start=$((controller_count + 1))
  wave_size=16
  wave_index=1
  while [ "$next_start" -le "$WORKER_COUNT" ]; do
    wave_end=$((next_start + wave_size - 1))
    if [ "$wave_end" -gt "$WORKER_COUNT" ]; then
      wave_end="$WORKER_COUNT"
    fi
    run_spawn_wave "executor-wave-${wave_index}" "$next_start" "$wave_end" "$wave_end" "$controller_count"
    next_start=$((wave_end + 1))
    wave_index=$((wave_index + 1))
  done
else
  run_spawn_wave "single-wave" 1 "$WORKER_COUNT" "$WORKER_COUNT" 0
fi

echo "[5/8] wait for all worker turns"
final_events_json="$(wait_for_session_progress "$WORKER_COUNT" "$WORKER_COUNT" "$FINAL_TURN_TIMEOUT_SEC")"

echo "[6/8] verify team session status visibility"
status_json="$(session_status_result)"
status_expr='
  .summary.scale_profile == "local64"
  and (.summary.planned_worker_count >= '"$WORKER_COUNT"')
  and ((.summary.worker_class_counts.manager // 0) >= 1)
  and ((.summary.worker_class_counts.metacog // 0) >= 1)
  and ((.summary.worker_class_counts.librarian // 0) >= 1)
  and ((.summary.worker_class_counts.scout // 0) >= 1)
  and ((.summary.runtime_pool_counts.local64 // 0) >= '"$WORKER_COUNT"')
  and (.local_runtime != null)
'
if [ "$LOCAL64_ROUTER_MODE" = "hybrid" ]; then
  status_expr='
    '"$status_expr"'
    and ((.summary.task_profile_counts.decide // 0) >= 1)
    and ((.summary.task_profile_counts.verify // 0) >= 1)
    and ((.summary.task_profile_counts.extract // 0) >= 1)
    and ((.summary.task_profile_counts.summarize // 0) >= 1)
    and ((.summary.task_profile_counts.normalize // 0) >= 1)
  '
fi
require_json_condition "$status_json" "$status_expr" "session status did not expose local64 role/runtime visibility"

echo "[7/8] verify operator room census"
digest_json="$(operator_digest_result)"
digest_expr='
  ((.role_census.manager // 0) >= 1)
  and ((.role_census.metacog // 0) >= 1)
  and ((.runtime_pools.local64 // 0) >= '"$WORKER_COUNT"')
  and (.local_runtime != null)
'
if [ "$LOCAL64_ROUTER_MODE" = "hybrid" ]; then
  digest_expr='
    '"$digest_expr"'
    and ((.task_profiles.decide // 0) >= 1)
    and ((.task_profiles.normalize // 0) >= 1)
  '
fi
require_json_condition "$digest_json" "$digest_expr" "operator digest did not expose local64 census/runtime visibility"

echo "[8/8] benchmark runtime pool"
bench_raw="$(mcp_call_tool 91008 "masc_local_runtime_bench" '{"parallelism":8,"rounds":1,"runtime_pool":"local64"}')"
mcp_require_tool_ok "$bench_raw"
require_result_condition "$bench_raw" '.total_requests >= 1 and .per_runtime_breakdown != null' "runtime bench did not return breakdown"

spawn_success_count="$(printf '%s' "$final_events_json" | jq -r '[.events[] | select(.event_type == "team_step_spawn" and .detail.success == true)] | length')"
spawn_failure_count="$(printf '%s' "$final_events_json" | jq -r '[.events[] | select(.event_type == "team_step_spawn" and .detail.success != true)] | length')"
team_turn_count="$(count_event_type "$final_events_json" "team_turn")"
attached_count="$(count_event_type "$final_events_json" "session_agent_attached")"
tier_counts="$(printf '%s' "$status_json" | jq -c '.summary.tier_counts // {}')"
runtime_counts="$(printf '%s' "$final_events_json" | jq -c '
  [ .events[] | select(.event_type == "team_step_spawn" and .detail.success == true and (.detail.assigned_runtime // null) != null) | .detail.assigned_runtime ]
  | group_by(.)
  | map({ (.[0]): length })
  | add // {}
')"
zombie_reap_detected="false"
server_log_path=""
if [ -n "${MASC_LOCAL64_BASE_PATH:-}" ]; then
  server_log_path="${MASC_LOCAL64_BASE_PATH}/server.log"
  if [ -f "$server_log_path" ] && grep -q "ZeroZombie" "$server_log_path"; then
    zombie_reap_detected="true"
  fi
fi

if [ "$spawn_success_count" -lt "$WORKER_COUNT" ]; then
  echo "FAIL: final spawn success count ${spawn_success_count}/${WORKER_COUNT}" >&2
  jq -s . "$SPAWN_RESULTS_FILE"
  exit 1
fi
if [ "$team_turn_count" -lt "$WORKER_COUNT" ]; then
  echo "FAIL: final team_turn count ${team_turn_count}/${WORKER_COUNT}" >&2
  printf '%s\n' "$final_events_json" | jq .
  exit 1
fi
if [ "$zombie_reap_detected" = "true" ]; then
  echo "FAIL: ZeroZombie reaped active workers during smoke" >&2
  exit 1
fi

artifact_dir=""
session_json_path=""
events_jsonl_path=""
if [ -n "${MASC_LOCAL64_BASE_PATH:-}" ]; then
  artifact_dir="${MASC_LOCAL64_BASE_PATH}/.masc/team-sessions/${SESSION_ID}"
  session_json_path="${artifact_dir}/session.json"
  events_jsonl_path="${artifact_dir}/events.jsonl"
fi

echo "PASS: local64 smoke session=${SESSION_ID} workers=${WORKER_COUNT}"
echo "SESSION_ID=${SESSION_ID}"
echo "ARTIFACT_DIR=${artifact_dir}"
echo "SESSION_JSON_PATH=${session_json_path}"
echo "EVENTS_JSONL_PATH=${events_jsonl_path}"
echo "SERVER_LOG_PATH=${server_log_path}"
echo "SPAWN_SUCCESS_COUNT=${spawn_success_count}"
echo "SPAWN_FAILURE_COUNT=${spawn_failure_count}"
echo "ATTACHED_COUNT=${attached_count}"
echo "TEAM_TURN_COUNT=${team_turn_count}"
echo "TIER_COUNTS=${tier_counts}"
echo "RUNTIME_COUNTS=${runtime_counts}"
echo "ZOMBIE_REAP_DETECTED=${zombie_reap_detected}"
