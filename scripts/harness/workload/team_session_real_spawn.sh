#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
COORD_AGENT="${COORD_AGENT:-team-session-real-spawn}"
SPAWN_RUNTIME_AGENT="${SPAWN_RUNTIME_AGENT:-codex}"
WORKING_DIR="${WORKING_DIR:-$(pwd)}"
SESSION_DURATION_SEC="${SESSION_DURATION_SEC:-600}"
SPAWN_TIMEOUT_SEC="${SPAWN_TIMEOUT_SEC:-240}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-$((SPAWN_TIMEOUT_SEC + 120))}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-45}"
ASSERT_CACHE_HIT="${ASSERT_CACHE_HIT:-0}"
GOAL="${GOAL:-4 spawned agents must discuss and produce a shared ADK plan artifact}"
MCP_SESSION_ID="${MCP_SESSION_ID:-team-session-harness-$(date +%s)-$RANDOM}"
RUN_TAG="${RUN_TAG:-$(date +%s)-$RANDOM}"
DEFAULT_PARTICIPANTS_CSV="proof-a-${RUN_TAG},proof-b-${RUN_TAG},proof-c-${RUN_TAG},proof-d-${RUN_TAG}"
PARTICIPANTS_CSV="${PARTICIPANTS_CSV:-$DEFAULT_PARTICIPANTS_CSV}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http2-prior-knowledge}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

SESSION_ID=""

split_csv() {
  local raw="$1"
  awk -v csv="$raw" 'BEGIN{
    n=split(csv,a,",");
    for(i=1;i<=n;i++){
      gsub(/^[ \t]+|[ \t]+$/,"",a[i]);
      if(a[i]!="") print a[i];
    }
  }'
}

PARTICIPANTS=()
while IFS= read -r participant; do
  PARTICIPANTS+=("$participant")
done < <(split_csv "$PARTICIPANTS_CSV")
if [ "${#PARTICIPANTS[@]}" -lt 4 ]; then
  echo "need at least 4 participants, got ${#PARTICIPANTS[@]}"
  exit 1
fi

required_duration_sec=$(( (${#PARTICIPANTS[@]} * SPAWN_TIMEOUT_SEC) + 180 ))
EFFECTIVE_SESSION_DURATION_SEC="$SESSION_DURATION_SEC"
if [ "$EFFECTIVE_SESSION_DURATION_SEC" -lt "$required_duration_sec" ]; then
  EFFECTIVE_SESSION_DURATION_SEC="$required_duration_sec"
fi

cleanup() {
  if [ -n "$SESSION_ID" ]; then
    mcp_call_tool 90981 "masc_team_session_stop" \
      "{\"session_id\":\"$SESSION_ID\",\"reason\":\"harness_cleanup\",\"generate_report\":false}" \
      >/dev/null 2>&1 || true
  fi
  mcp_call_tool 90982 "masc_leave" "{\"agent_name\":\"$COORD_AGENT\"}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[1/9] init + join coordinator"
r1="$(mcp_call_tool 90001 "masc_init" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a}')")"
mcp_require_tool_ok "$r1" "masc_init"
r2="$(mcp_call_tool 90002 "masc_join" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a,capabilities:["team-session","proof-harness"]}')")"
mcp_require_tool_ok "$r2" "masc_join"

echo "[2/9] preflight cleanup"
mcp_call_tool 90011 "masc_cleanup_zombies" "{}" >/dev/null 2>&1 || true

echo "[3/9] start team session (min_agents=${#PARTICIPANTS[@]}, duration=${EFFECTIVE_SESSION_DURATION_SEC}s)"
participants_json="$(printf '%s\n' "${PARTICIPANTS[@]}" | jq -R . | jq -s .)"
start_args="$(jq -cn \
  --arg goal "$GOAL" \
  --argjson duration "$EFFECTIVE_SESSION_DURATION_SEC" \
  --argjson min_agents "${#PARTICIPANTS[@]}" \
  --argjson participants "$participants_json" \
  '{
     goal:$goal,
     duration_seconds:$duration,
     checkpoint_interval_sec:15,
     min_agents:$min_agents,
     orchestration_mode:"assist",
     communication_mode:"hybrid",
     model_cascade:["glm:auto","gemini:gemini-2.5-pro"],
     fallback_policy:"cascade_then_task",
     instruction_profile:"strict",
     alert_channel:"both",
     report_formats:["markdown","json"],
     agents:$participants
   }')"
start_raw="$(mcp_call_tool 90003 "masc_team_session_start" "$start_args")"
mcp_require_tool_ok "$start_raw" "masc_team_session_start"
SESSION_ID="$(printf "%s" "$start_raw" | mcp_extract_result | jq -r '.session_id // empty')"
if [ -z "$SESSION_ID" ]; then
  echo "FAIL: session_id missing"
  printf "%s\n" "$start_raw"
  exit 1
fi
echo "session_id=$SESSION_ID"

echo "[4/9] spawn 4 real agents and force multi-turn actions"
for i in "${!PARTICIPANTS[@]}"; do
  actor="${PARTICIPANTS[$i]}"
  next_idx=$(( (i + 1) % ${#PARTICIPANTS[@]} ))
  target="${PARTICIPANTS[$next_idx]}"
  spawn_prompt="$(
    printf '%s\n' \
      "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
      "1) mcp__masc__masc_join(agent_name=\"${actor}\", capabilities=[\"planning\",\"discussion\",\"adk\"])" \
      "2) mcp__masc__masc_team_session_turn(session_id=\"${SESSION_ID}\", turn_kind=\"note\", message=\"[${actor}] 관점 제안: ADK 환경 우선순위 정리\")" \
      "3) mcp__masc__masc_team_session_turn(session_id=\"${SESSION_ID}\", turn_kind=\"broadcast\", message=\"[${actor}] 팀 공유: 핵심 리스크와 선택지\")" \
      "4) mcp__masc__masc_portal_open(agent_name=\"${actor}\", target_agent=\"${target}\", initial_message=\"[${actor}] -> ${target} 의견 동기화\")" \
      "5) mcp__masc__masc_portal_send(agent_name=\"${actor}\", message=\"[${actor}] 합의안 후보: CI 하네스 + streamable first\")" \
      "6) mcp__masc__masc_team_session_turn(session_id=\"${SESSION_ID}\", turn_kind=\"portal\", target_agent=\"${target}\", message=\"[${actor}] portal 교신 완료\")" \
      "7) mcp__masc__masc_team_session_turn(session_id=\"${SESSION_ID}\", turn_kind=\"task\", task_title=\"adk-plan-${actor}\", task_description=\"${actor} 담당 계획 초안\", task_priority=2)" \
      "8) mcp__masc__masc_leave(agent_name=\"${actor}\")" \
      "마지막 답변은 한 줄로 \"done:${actor}\"만 출력해라."
  )"
  spawn_args="$(jq -cn \
    --arg runtime "$SPAWN_RUNTIME_AGENT" \
    --arg prompt "$spawn_prompt" \
    --arg wd "$WORKING_DIR" \
    --argjson timeout "$SPAWN_TIMEOUT_SEC" \
    '{agent_name:$runtime,prompt:$prompt,timeout_seconds:$timeout,working_dir:$wd}')"
  spawn_raw="$(mcp_call_tool $((90100 + i)) "masc_spawn" "$spawn_args")"
  mcp_require_tool_ok "$spawn_raw" "masc_spawn(${actor})"
  spawn_text="$(printf "%s" "$spawn_raw" | mcp_extract_text)"
  if ! printf "%s" "$spawn_text" | rg -q "✅ Agent completed|done:${actor}"; then
    echo "WARN: spawned agent ${actor} completion text did not match strict pattern"
  fi
done

echo "[5/9] restore coordinator identity"
restore_raw="$(mcp_call_tool 90012 "masc_join" "$(jq -cn --arg a "$COORD_AGENT" '{agent_name:$a,capabilities:["team-session","proof-harness"]}')")"
mcp_require_tool_ok "$restore_raw" "restore masc_join"

echo "[6/9] verify team_turn actor diversity"
events_raw="$(mcp_call_tool 90004 "masc_team_session_events" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s,event_types:["team_turn"],limit:400}')")"
mcp_require_tool_ok "$events_raw" "masc_team_session_events"
events_result="$(printf "%s" "$events_raw" | mcp_extract_result)"
team_turn_count="$(printf "%s" "$events_result" | jq -r '.count // 0')"
unique_turn_actors="$(printf "%s" "$events_result" | jq -r '[.events[]? | .detail.actor // empty | select(. != "")] | unique | length')"
if [ "$unique_turn_actors" -lt "${#PARTICIPANTS[@]}" ]; then
  observed_actors_json="$(printf "%s" "$events_result" | jq -c '[.events[]? | .detail.actor // empty | select(. != "")] | unique')"
  missing_participants=()
  for actor in "${PARTICIPANTS[@]}"; do
    if ! printf "%s" "$observed_actors_json" | jq -e --arg a "$actor" 'index($a) != null' >/dev/null; then
      missing_participants+=("$actor")
    fi
  done

  if [ "${#missing_participants[@]}" -gt 0 ]; then
    echo "[6b/9] recovery spawn for missing actors: ${missing_participants[*]}"
    recovery_idx=0
    for actor in "${missing_participants[@]}"; do
      target="${PARTICIPANTS[0]}"
      if [ "$target" = "$actor" ] && [ "${#PARTICIPANTS[@]}" -gt 1 ]; then
        target="${PARTICIPANTS[1]}"
      fi
      recovery_prompt="$(
        printf '%s\n' \
          "너의 에이전트 이름은 ${actor} 이다. 아래를 순서대로 실행해라." \
          "1) mcp__masc__masc_join(agent_name=\"${actor}\", capabilities=[\"planning\",\"discussion\",\"adk\"])" \
          "2) mcp__masc__masc_team_session_turn(session_id=\"${SESSION_ID}\", turn_kind=\"note\", message=\"[${actor}] recovery: 설계안 핵심 한 줄\")" \
          "3) mcp__masc__masc_team_session_turn(session_id=\"${SESSION_ID}\", turn_kind=\"portal\", target_agent=\"${target}\", message=\"[${actor}] recovery portal sync\")" \
          "4) mcp__masc__masc_leave(agent_name=\"${actor}\")" \
          "마지막 답변은 한 줄로 \"done:${actor}\"만 출력해라."
      )"
      recovery_args="$(jq -cn \
        --arg runtime "$SPAWN_RUNTIME_AGENT" \
        --arg prompt "$recovery_prompt" \
        --arg wd "$WORKING_DIR" \
        --argjson timeout "$SPAWN_TIMEOUT_SEC" \
        '{agent_name:$runtime,prompt:$prompt,timeout_seconds:$timeout,working_dir:$wd}')"
      recovery_raw="$(mcp_call_tool $((90200 + recovery_idx)) "masc_spawn" "$recovery_args")"
      mcp_require_tool_ok "$recovery_raw" "recovery masc_spawn(${actor})"
      recovery_idx=$((recovery_idx + 1))
    done

    events_raw="$(mcp_call_tool 90013 "masc_team_session_events" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s,event_types:["team_turn"],limit:600}')")"
    mcp_require_tool_ok "$events_raw" "recovery masc_team_session_events"
    events_result="$(printf "%s" "$events_raw" | mcp_extract_result)"
    team_turn_count="$(printf "%s" "$events_result" | jq -r '.count // 0')"
    unique_turn_actors="$(printf "%s" "$events_result" | jq -r '[.events[]? | .detail.actor // empty | select(. != "")] | unique | length')"
  fi
fi
if [ "$team_turn_count" -lt "${#PARTICIPANTS[@]}" ]; then
  echo "FAIL: insufficient team_turn events (count=$team_turn_count)"
  exit 1
fi
if [ "$unique_turn_actors" -lt "${#PARTICIPANTS[@]}" ]; then
  echo "FAIL: unique turn actors too low ($unique_turn_actors < ${#PARTICIPANTS[@]})"
  exit 1
fi

echo "[7/9] stop session + report"
stop_raw="$(mcp_call_tool 90005 "masc_team_session_stop" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s,reason:"real_spawn_harness_done",generate_report:true}')")"
mcp_require_tool_ok "$stop_raw" "masc_team_session_stop"
stop_result="$(printf "%s" "$stop_raw" | mcp_extract_result)"
if [ -z "$stop_result" ]; then
  echo "FAIL: stop_session did not return result payload"
  printf "%s\n" "$stop_raw"
  exit 1
fi
stop_deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
while :; do
  stop_status_raw="$(mcp_call_tool 90008 "masc_team_session_status" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s}')")"
  mcp_require_tool_ok "$stop_status_raw" "stop poll masc_team_session_status"
  stop_status_result="$(printf "%s" "$stop_status_raw" | mcp_extract_result)"
  stop_status="$(printf "%s" "$stop_status_result" | jq -r '.session.status // empty')"
  if [ "$stop_status" != "running" ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$stop_deadline" ]; then
    echo "FAIL: session did not stop within ${STOP_WAIT_SEC}s"
    printf "%s\n" "$stop_status_result"
    exit 1
  fi
  sleep 2
done

echo "[8/9] generate proof"
prove_raw="$(mcp_call_tool 90006 "masc_team_session_prove" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s,generate_report_if_missing:true}')")"
mcp_require_tool_ok "$prove_raw" "masc_team_session_prove"
prove_result="$(printf "%s" "$prove_raw" | mcp_extract_result)"
verdict="$(printf "%s" "$prove_result" | jq -r '.proof.verdict // empty')"
required_turn_actors="$(printf "%s" "$prove_result" | jq -r '.proof.evidence.required_turn_actors // 0')"
proof_unique_turn_actors="$(printf "%s" "$prove_result" | jq -r '.proof.evidence.unique_turn_actors_count // 0')"
proof_json_path="$(printf "%s" "$prove_result" | jq -r '.proof_json_path // empty')"
proof_md_path="$(printf "%s" "$prove_result" | jq -r '.proof_md_path // empty')"

if [ "$verdict" != "proved" ]; then
  echo "FAIL: proof verdict=$verdict"
  printf "%s\n" "$prove_result"
  exit 1
fi
if [ "$proof_unique_turn_actors" -lt "$required_turn_actors" ]; then
  echo "FAIL: proof unique actor evidence insufficient ($proof_unique_turn_actors < $required_turn_actors)"
  exit 1
fi

echo "[9/9] final status snapshot"
status_raw="$(mcp_call_tool 90007 "masc_team_session_status" "$(jq -cn --arg s "$SESSION_ID" '{session_id:$s}')")"
mcp_require_tool_ok "$status_raw" "final masc_team_session_status"
status_result="$(printf "%s" "$status_raw" | mcp_extract_result)"
session_status="$(printf "%s" "$status_result" | jq -r '.session.status // empty')"
if [ "$session_status" = "running" ]; then
  echo "FAIL: session still running after stop"
  printf "%s\n" "$status_result"
  exit 1
fi

echo "[10/10] summary"
printf "session_id=%s\n" "$SESSION_ID"
printf "participants_csv=%s\n" "$PARTICIPANTS_CSV"
printf "team_turn_count=%s\n" "$team_turn_count"
printf "unique_turn_actors=%s\n" "$unique_turn_actors"
printf "proof_required_turn_actors=%s\n" "$required_turn_actors"
printf "proof_unique_turn_actors=%s\n" "$proof_unique_turn_actors"
printf "proof_json_path=%s\n" "$proof_json_path"
printf "proof_md_path=%s\n" "$proof_md_path"
printf "session_status=%s\n" "$session_status"
printf "model_cache_hits=%s\n" "$model_cache_hits"
printf "model_cache_misses=%s\n" "$model_cache_misses"

echo "[11/11] PASS"
echo "PASS: real spawned 4-agent team session proof harness"
