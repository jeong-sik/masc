#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8945/mcp}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"
COORD_AGENT="${COORD_AGENT:-team-session-local64-chaos}"
WAVE1_WORKER_COUNT="${WAVE1_WORKER_COUNT:-8}"
WAVE2_WORKER_COUNT="${WAVE2_WORKER_COUNT:-12}"
WAVE3_WORKER_COUNT="${WAVE3_WORKER_COUNT:-6}"
SESSION_DURATION_SEC="${SESSION_DURATION_SEC:-2400}"
max_wave_workers="$WAVE1_WORKER_COUNT"
if [ "$WAVE2_WORKER_COUNT" -gt "$max_wave_workers" ]; then
  max_wave_workers="$WAVE2_WORKER_COUNT"
fi
if [ "$WAVE3_WORKER_COUNT" -gt "$max_wave_workers" ]; then
  max_wave_workers="$WAVE3_WORKER_COUNT"
fi
default_spawn_timeout=$((max_wave_workers * 45))
if [ "$default_spawn_timeout" -lt 300 ]; then
  default_spawn_timeout=300
fi
SPAWN_TIMEOUT_SEC="${SPAWN_TIMEOUT_SEC:-$default_spawn_timeout}"
default_http_timeout=$((SPAWN_TIMEOUT_SEC + 300))
min_http_timeout=$((max_wave_workers * 50))
if [ "$default_http_timeout" -lt "$min_http_timeout" ]; then
  default_http_timeout="$min_http_timeout"
fi
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-$default_http_timeout}"
WAIT_AFTER_SPAWN_SEC="${WAIT_AFTER_SPAWN_SEC:-3}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"
MCP_SESSION_ID="${MCP_SESSION_ID:-team-session-local64-chaos-$(date +%s)-$RANDOM}"
GOAL="${GOAL:-Validate local64 dropout handling and reroute after one runtime disappears}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

SESSION_ID=""
VICTIM_RUNTIME_ID=""
VICTIM_PORT=""

runtime_verify_result() {
  local runtime_pool="${1:-}"
  local args
  args="$(
    jq -cn \
      --arg runtime_pool "$runtime_pool" \
      '
      {}
      | if $runtime_pool != "" then .runtime_pool = $runtime_pool else . end
      '
  )"
  local payload
  payload="$(mcp_call_tool 92898 "masc_runtime_verify" "$args")"
  mcp_require_tool_ok "$payload"
  printf '%s' "$payload" | mcp_extract_result
}

cleanup() {
  if [ -n "$SESSION_ID" ]; then
    mcp_call_tool 92981 "masc_team_session_stop" \
      "{\"session_id\":\"$SESSION_ID\",\"reason\":\"local64_chaos_cleanup\",\"generate_report\":false}" \
      >/dev/null 2>&1 || true
  fi
  mcp_call_tool 92982 "masc_leave" "{\"agent_name\":\"$COORD_AGENT\"}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_spawn_batch() {
  local session_id="$1"
  local worker_count="$2"
  local model="$3"
  local phase="$4"
  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/local64-chaos-batch.XXXXXX.json")"
  : >"$tmp_file"

  local idx=1
  while [ "$idx" -le "$worker_count" ]; do
    local role="executor"
    local spawn_role="executor-${phase}-${idx}"
    local capsule_mode="inherit"
    case "$idx" in
      1)
        role="manager"
        spawn_role="middle-manager-${phase}"
        capsule_mode="capsule"
        ;;
      2)
        role="metacog"
        spawn_role="metacog-observer-${phase}"
        capsule_mode="capsule"
        ;;
      3)
        role="librarian"
        spawn_role="knowledge-librarian-${phase}"
        capsule_mode="capsule"
        ;;
      4)
        role="scout"
        spawn_role="research-scout-${phase}"
        capsule_mode="fresh"
        ;;
    esac

    local actor
    actor="$(printf 'local64-chaos-%s-%02d' "$phase" "$idx")"
    local prompt
    prompt="$(
      printf '%s\n' \
        "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
        "1) mcp__masc__masc_join(agent_name=\"${actor}\", capabilities=[\"swarm\",\"${role}\",\"chaos\"])" \
        "2) mcp__masc__masc_team_session_turn(session_id=\"${session_id}\", turn_kind=\"note\", message=\"[${actor}] phase=${phase} ${role} online for local64 chaos\")" \
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
  local call_id="$1"
  local worker_count="$2"
  local phase="$3"
  local spawn_batch_json
  local step_args
  spawn_batch_json="$(build_spawn_batch "$SESSION_ID" "$worker_count" "$LLAMA_SWARM_MODEL" "$phase")"
  step_args="$(jq -cn --arg s "$SESSION_ID" --arg a "$COORD_AGENT" --argjson batch "$spawn_batch_json" --argjson timeout "$SPAWN_TIMEOUT_SEC" \
    '{session_id:$s,actor:$a,spawn_batch:$batch,spawn_timeout_seconds:$timeout}')"
  mcp_call_tool "$call_id" "masc_team_session_step" "$step_args"
}

wait_for_runtime_down() {
  local runtime_id="$1"
  local deadline=$((SECONDS + 20))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local runtime_json
    runtime_json="$(runtime_verify_result "$runtime_id")"
    if printf '%s' "$runtime_json" \
      | jq -e '.provider_reachable != true or .slot_reachable != true or (.runtime_blocker // "") == "provider_unreachable"' >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "[1/10] init + join coordinator"
init_raw="$(mcp_call_tool 92901 "masc_init" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a}')")"
mcp_require_tool_ok "$init_raw"
join_raw="$(mcp_call_tool 92902 "masc_join" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a,capabilities:["team-session","local64","operator","chaos"]}')")"
mcp_require_tool_ok "$join_raw"

echo "[2/10] start local64 chaos session"
start_args="$(jq -cn --arg goal "$GOAL" --argjson duration "$SESSION_DURATION_SEC" \
  '{goal:$goal,duration_seconds:$duration,checkpoint_interval_sec:20,min_agents:1,orchestration_mode:"assist",communication_mode:"hybrid",scale_profile:"local64",fallback_policy:"strict_local_only",instruction_profile:"strict",alert_channel:"both",report_formats:["markdown","json"],agents:["team-session-local64-chaos"]}')"
start_raw="$(mcp_call_tool 92903 "masc_team_session_start" "$start_args")"
mcp_require_tool_ok "$start_raw"
SESSION_ID="$(printf '%s' "$start_raw" | mcp_extract_result | jq -r '.session_id // empty')"
if [ -z "$SESSION_ID" ]; then
  echo "FAIL: session_id missing"
  printf '%s\n' "$start_raw"
  exit 1
fi
echo "session_id=$SESSION_ID"

echo "[3/10] inspect runtime pool and pick victim"
runtime_raw="$(mcp_call_tool 92904 "masc_llama_runtime_status" '{"include_models":true}')"
mcp_require_tool_ok "$runtime_raw"
runtime_result="$(printf '%s' "$runtime_raw" | mcp_extract_result)"
if ! printf '%s' "$runtime_result" | jq -e '.runtime_count >= 2' >/dev/null; then
  echo "FAIL: chaos requires at least 2 local runtimes"
  printf '%s\n' "$runtime_result"
  exit 1
fi
VICTIM_RUNTIME_ID="$(printf '%s' "$runtime_result" | jq -r '.runtimes | map(select(.port != null)) | sort_by(.port) | last.id // empty')"
VICTIM_PORT="$(printf '%s' "$runtime_result" | jq -r '.runtimes | map(select(.port != null)) | sort_by(.port) | last.port // empty')"
if [ -z "$VICTIM_RUNTIME_ID" ] || [ -z "$VICTIM_PORT" ]; then
  echo "FAIL: unable to select victim runtime"
  printf '%s\n' "$runtime_result"
  exit 1
fi
echo "victim_runtime=${VICTIM_RUNTIME_ID} port=${VICTIM_PORT}"

echo "[4/10] wave1 baseline (spawn_timeout=${SPAWN_TIMEOUT_SEC}s http_timeout=${HTTP_TIMEOUT_SEC}s max_wave_workers=${max_wave_workers})"
wave1_raw="$(run_spawn_wave 92905 "$WAVE1_WORKER_COUNT" "wave1")"
mcp_require_tool_ok "$wave1_raw"
wave1_success="$(printf '%s' "$wave1_raw" | mcp_extract_result | jq -r '.spawn.results | map(select(.success == true)) | length')"
if [ "$wave1_success" -lt "$WAVE1_WORKER_COUNT" ]; then
  echo "FAIL: baseline wave succeeded only $wave1_success/$WAVE1_WORKER_COUNT"
  printf '%s\n' "$wave1_raw" | mcp_extract_result
  exit 1
fi
sleep "$WAIT_AFTER_SPAWN_SEC"

echo "[5/10] kill one runtime"
victim_pid="$(lsof -iTCP:"$VICTIM_PORT" -sTCP:LISTEN -t | head -n1 || true)"
if [ -z "$victim_pid" ]; then
  echo "FAIL: no pid found for victim port $VICTIM_PORT"
  exit 1
fi
kill "$victim_pid"
if ! wait_for_runtime_down "$VICTIM_RUNTIME_ID"; then
  echo "FAIL: victim runtime ${VICTIM_RUNTIME_ID} did not go down"
  exit 1
fi

echo "[6/10] wave2 after dropout"
wave2_raw="$(run_spawn_wave 92906 "$WAVE2_WORKER_COUNT" "wave2")"
mcp_require_tool_ok "$wave2_raw"
wave2_result="$(printf '%s' "$wave2_raw" | mcp_extract_result)"
wave2_success="$(printf '%s' "$wave2_result" | jq -r '.spawn.results | map(select(.success == true)) | length')"
wave2_failure="$(printf '%s' "$wave2_result" | jq -r '.spawn.results | map(select(.success != true)) | length')"
wave2_victim_assignments="$(printf '%s' "$wave2_result" | jq -r --arg victim "$VICTIM_RUNTIME_ID" '.spawn.results | map(select(.assigned_runtime == $victim)) | length')"
if [ "$wave2_success" -lt 1 ] || [ "$wave2_failure" -lt 1 ] || [ "$wave2_victim_assignments" -lt 1 ]; then
  echo "FAIL: chaos dropout wave did not expose mixed success/failure on victim runtime"
  printf '%s\n' "$wave2_result"
  exit 1
fi
sleep "$WAIT_AFTER_SPAWN_SEC"

echo "[7/10] verify cooldown after failures"
post_failure_runtime_raw="$(mcp_call_tool 92907 "masc_llama_runtime_status" '{"include_models":true}')"
mcp_require_tool_ok "$post_failure_runtime_raw"
mcp_require_json "$post_failure_runtime_raw"
post_failure_runtime_result="$(printf '%s' "$post_failure_runtime_raw" | mcp_extract_result)"
if ! printf '%s' "$post_failure_runtime_result" | jq -e --arg victim "$VICTIM_RUNTIME_ID" '
  .healthy_runtime_count >= 1
  and (.runtimes | map(select(.id == $victim and (.failure_streak >= 3) and (.cooldown_until != null))) | length == 1)
' >/dev/null; then
  echo "FAIL: victim runtime did not enter cooldown after dropout wave"
  printf '%s\n' "$post_failure_runtime_result"
  exit 1
fi

echo "[8/10] wave3 reroute on surviving runtime"
wave3_raw="$(run_spawn_wave 92908 "$WAVE3_WORKER_COUNT" "wave3")"
mcp_require_tool_ok "$wave3_raw"
wave3_result="$(printf '%s' "$wave3_raw" | mcp_extract_result)"
wave3_success="$(printf '%s' "$wave3_result" | jq -r '.spawn.results | map(select(.success == true)) | length')"
wave3_victim_assignments="$(printf '%s' "$wave3_result" | jq -r --arg victim "$VICTIM_RUNTIME_ID" '.spawn.results | map(select(.assigned_runtime == $victim)) | length')"
if [ "$wave3_success" -lt "$WAVE3_WORKER_COUNT" ] || [ "$wave3_victim_assignments" -ne 0 ]; then
  echo "FAIL: reroute wave did not fully avoid victim runtime"
  printf '%s\n' "$wave3_result"
  exit 1
fi
sleep "$WAIT_AFTER_SPAWN_SEC"

echo "[9/10] verify operator digest"
digest_raw="$(mcp_call_tool 92909 "masc_operator_digest" '{"target_type":"room"}')"
mcp_require_tool_ok "$digest_raw"
if ! printf '%s' "$digest_raw" | mcp_extract_result | jq -e '.runtime_pools.local64 >= 1 and .local_runtime != null' >/dev/null; then
  echo "FAIL: operator digest did not expose local64 runtime state after chaos"
  printf '%s\n' "$digest_raw" | mcp_extract_result
  exit 1
fi

echo "[10/10] benchmark surviving runtime"
bench_raw="$(mcp_call_tool 92910 "masc_llama_runtime_bench" '{"parallelism":4,"rounds":1,"runtime_pool":"local64"}')"
mcp_require_tool_ok "$bench_raw"
if ! printf '%s' "$bench_raw" | mcp_extract_result | jq -e '.total_requests >= 1 and .success_count >= 1' >/dev/null; then
  echo "FAIL: bench did not succeed after runtime dropout"
  printf '%s\n' "$bench_raw" | mcp_extract_result
  exit 1
fi

echo "PASS: local64 chaos session=${SESSION_ID} victim=${VICTIM_RUNTIME_ID} wave2_success=${wave2_success} wave2_failure=${wave2_failure} wave3_success=${wave3_success}"
