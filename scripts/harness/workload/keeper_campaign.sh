#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/harness/lib/mcp_jsonrpc.sh"
source "$REPO_ROOT/scripts/harness/lib/server_bootstrap.sh"

RUN_ID="${RUN_ID:-keeper-campaign-$(date +%Y%m%d_%H%M%S)-$$}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/keeper_campaign/$RUN_ID}"
SNAP_DIR="$RUN_DIR/snapshots"
RAW_DIR="$RUN_DIR/raw"
CAMPAIGN_EVENTS_FILE="$RUN_DIR/campaign-events.jsonl"
CAMPAIGN_STATE_FILE="$RUN_DIR/campaign-state.json"
mkdir -p "$RUN_DIR" "$SNAP_DIR" "$RAW_DIR"

DRY_RUN="${DRY_RUN:-0}"
START_SERVER="${START_SERVER:-1}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"
KEEP_SERVER="${KEEP_SERVER:-0}"
PORT="${PORT:-}"
BASE_PATH="${BASE_PATH:-}"
SERVER_EXE="${SERVER_EXE:-}"
MCP_URL="${MCP_URL:-}"
KEEPER_MODELS="${KEEPER_MODELS:-}"
KEEPER_NAME="${KEEPER_NAME:-campaign-${RUN_ID}}"
HARNESS_AGENT_NAME="${HARNESS_AGENT_NAME:-campaign-harness}"
TARGET_PHASES="${TARGET_PHASES:-bootstrap,task_bind,autoresearch,compaction,handoff,continuity}"
TURN_TIMEOUT_SEC="${TURN_TIMEOUT_SEC:-90}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-20}"
BOOTSTRAP_WAIT_SEC="${BOOTSTRAP_WAIT_SEC:-20}"
TASK_WAIT_SEC="${TASK_WAIT_SEC:-20}"
AUTORESEARCH_WAIT_SEC="${AUTORESEARCH_WAIT_SEC:-45}"
PRESSURE_PAUSE_SEC="${PRESSURE_PAUSE_SEC:-1}"
MAX_PRESSURE_TURNS="${MAX_PRESSURE_TURNS:-4}"
PRESSURE_BYTES="${PRESSURE_BYTES:-18000}"
KEEPER_PRESENCE_KEEPALIVE_SEC="${KEEPER_PRESENCE_KEEPALIVE_SEC:-5}"
KEEPER_COMPACTION_RATIO_GATE="${KEEPER_COMPACTION_RATIO_GATE:-0.10}"
KEEPER_COMPACTION_MESSAGE_GATE="${KEEPER_COMPACTION_MESSAGE_GATE:-2}"
KEEPER_CONTINUITY_COOLDOWN_SEC="${KEEPER_CONTINUITY_COOLDOWN_SEC:-0}"
KEEPER_HANDOFF_THRESHOLD="${KEEPER_HANDOFF_THRESHOLD:-0.01}"
KEEPER_CONTEXT_BUDGET="${KEEPER_CONTEXT_BUDGET:-0.60}"
CAMPAIGN_TASK_TITLE="${CAMPAIGN_TASK_TITLE:-Keeper campaign goal reachability validation}"
CAMPAIGN_GOAL="${CAMPAIGN_GOAL:-Reach the fixture target score through keeper-driven autoresearch, then preserve goal/task lineage across compaction or handoff.}"

SERVER_PID=""
SERVER_LOG="$RUN_DIR/server.log"
TEMP_BASE_PATH=""
FIXTURE_REPO=""
KEEPER_CREATED=0
KEEPER_STOPPED=0
ROOM_JOINED=0
VALIDATION_EXIT_CODE=1

BOOTSTRAP_PASS=0
TASK_BIND_PASS=0
AUTORESEARCH_PASS=0
COMPACTION_PASS=0
HANDOFF_PASS=0
CONTINUITY_PASS=0

TASK_ID=""
LOOP_ID=""
CURRENT_TASK_ID=""
BASELINE_TASK_ID=""
BASELINE_GOAL=""
BASELINE_TRACE_ID=""
BASELINE_GENERATION="0"
BASELINE_COMPACTIONS="0"
BASELINE_HANDOFFS="0"
LATEST_TRACE_ID=""
LATEST_GENERATION=""
LATEST_COMPACTIONS=""
LATEST_HANDOFFS=""
LATEST_HEALTH=""
LATEST_INPUT_PREVIEW=""
LATEST_OUTPUT_PREVIEW=""
LATEST_LOOP_STATUS=""
LATEST_TARGET_REACHED="false"
LATEST_TARGET_SCORE=""
LAST_TOOL_RAW=""
LAST_TOOL_ERROR=""

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

normalize_bool() {
  local raw="${1:-0}"
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) printf '1' ;;
    *) printf '0' ;;
  esac
}

trim_preview() {
  local raw="${1:-}"
  python3 - "$raw" <<'PY'
import sys
text = sys.argv[1].strip().replace("\n", " ")
limit = 220
print(text if len(text) <= limit else text[:limit-1] + "…")
PY
}

phase_enabled() {
  case ",$TARGET_PHASES," in
    *,"$1",*) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

write_json_pretty() {
  local path="$1"
  local payload="$2"
  printf '%s' "$payload" | jq '.' >"$path"
}

write_text() {
  local path="$1"
  local payload="$2"
  printf '%s\n' "$payload" >"$path"
}

append_phase() {
  local phase="$1"
  local status="$2"
  local summary="$3"
  local snapshot_file="$4"
  local aux_file="$5"
  jq -nc \
    --arg ts "$(iso_now)" \
    --arg phase "$phase" \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg snapshot_file "$snapshot_file" \
    --arg aux_file "$aux_file" \
    '{
      timestamp: $ts,
      phase: $phase,
      status: $status,
      summary: $summary,
      snapshot_file: ($snapshot_file | select(length > 0)),
      aux_file: ($aux_file | select(length > 0))
    }' >>"$RUN_DIR/phases.jsonl"
}

record_campaign_event() {
  local payload="$1"
  printf '%s' "$payload" \
    | jq -c --arg timestamp "$(iso_now)" '. + {timestamp:$timestamp}' \
    >>"$CAMPAIGN_EVENTS_FILE"
}

replay_campaign_fsm() {
  local events_file="$1"
  local output_file="$2"
  local explicit="${KEEPER_CAMPAIGN_FSM_EXE:-}"
  local dune_build_dir="${DUNE_BUILD_DIR:-_build}"
  local repo_build_dir="$REPO_ROOT/$dune_build_dir"
  if [[ "$dune_build_dir" = /* ]]; then
    repo_build_dir="$dune_build_dir"
  fi

  local -a candidates=()
  if [[ -n "$explicit" ]]; then
    candidates+=("$explicit")
  fi
  candidates+=(
    "$repo_build_dir/default/bin/keeper_campaign_fsm.exe"
    "$REPO_ROOT/_build/default/bin/keeper_campaign_fsm.exe"
    "$REPO_ROOT/bin/keeper_campaign_fsm.exe"
  )

  local bin_path
  for bin_path in "${candidates[@]}"; do
    if [[ -x "$bin_path" ]]; then
      "$bin_path" replay "$events_file" "$output_file" >/dev/null
      return 0
    fi
  done

  if [[ "$(normalize_bool "${MASC_HARNESS_ALLOW_DUNE_EXEC_FALLBACK:-1}")" != "1" ]]; then
    echo "keeper_campaign_fsm executable not found; build with: dune build --root . ./bin/keeper_campaign_fsm.exe" >&2
    return 1
  fi

  dune exec --root "$REPO_ROOT" ./bin/keeper_campaign_fsm.exe -- \
    replay "$events_file" "$output_file" >/dev/null
}

models_json() {
  jq -cn --arg csv "$KEEPER_MODELS" '
    $csv
    | split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
  '
}

call_mcp_tool() {
  local req_id="$1"
  local tool_name="$2"
  local args_json="$3"
  local timeout_sec="${4:-$TURN_TIMEOUT_SEC}"

  local saved_timeout="${HTTP_TIMEOUT_SEC:-}"
  HTTP_TIMEOUT_SEC="$timeout_sec"
  LAST_TOOL_RAW="$(mcp_call_tool "$req_id" "$tool_name" "$args_json")"
  HTTP_TIMEOUT_SEC="$saved_timeout"

  if printf '%s' "$LAST_TOOL_RAW" | jq -e '._harness_error? != null' >/dev/null 2>&1; then
    LAST_TOOL_ERROR="$(printf '%s' "$LAST_TOOL_RAW" | jq -r '._harness_error.message // "transport error"')"
    return 1
  fi

  LAST_TOOL_ERROR="$(printf '%s' "$LAST_TOOL_RAW" | jq -r '
    if .error?.message then .error.message
    elif (.result?.isError // false) == true then
      ([.result.content[]? | select(.type == "text") | .text] | join(" "))
    else empty end
  ' 2>/dev/null | awk 'NF { print; exit }')"

  if [[ -n "$LAST_TOOL_ERROR" ]]; then
    return 1
  fi
  return 0
}

tool_text() {
  printf '%s' "$LAST_TOOL_RAW" | jq -r '.result.content[0].text // ""'
}

tool_json() {
  local text
  text="$(tool_text)"
  printf '%s' "$text" | jq -c '.'
}

refresh_latest_evidence_from_status() {
  local status_json="$1"
  [[ -z "$status_json" ]] && return 0
  LATEST_TRACE_ID="$(printf '%s' "$status_json" | jq -r '.meta.trace_id // ""')"
  LATEST_GENERATION="$(printf '%s' "$status_json" | jq -r '.generation // .meta.generation // ""')"
  LATEST_COMPACTIONS="$(printf '%s' "$status_json" | jq -r '.compaction_count // ""')"
  LATEST_HANDOFFS="$(printf '%s' "$status_json" | jq -r '.handoff_count_total // ""')"
  LATEST_HEALTH="$(printf '%s' "$status_json" | jq -r '.diagnostic.health_state // .agent.status // ""')"
  CURRENT_TASK_ID="$(printf '%s' "$status_json" | jq -r '.meta.current_task_id // ""')"
}

refresh_latest_loop_state() {
  local loop_json="$1"
  [[ -z "$loop_json" ]] && return 0
  LATEST_LOOP_STATUS="$(printf '%s' "$loop_json" | jq -r '.status // ""')"
  LATEST_TARGET_REACHED="$(printf '%s' "$loop_json" | jq -r 'if (.target_reached // false) then "true" else "false" end')"
  LATEST_TARGET_SCORE="$(printf '%s' "$loop_json" | jq -r '.target_score // ""')"
  if [[ -z "$LOOP_ID" ]]; then
    LOOP_ID="$(printf '%s' "$loop_json" | jq -r '.loop_id // ""')"
  fi
}

join_room() {
  local args
  args="$(jq -cn \
    --arg agent_name "$HARNESS_AGENT_NAME" \
    '{agent_name:$agent_name,capabilities:["harness","campaign"]}')"
  call_mcp_tool 100 "masc_join" "$args" 20 || return 1
  ROOM_JOINED=1
}

leave_room() {
  local args
  args="$(jq -cn --arg agent_name "$HARNESS_AGENT_NAME" '{agent_name:$agent_name}')"
  call_mcp_tool 101 "masc_leave" "$args" 20 || true
  ROOM_JOINED=0
}

create_keeper() {
  local models_json_payload="$1"
  local args
  args="$(jq -cn \
    --arg name "$KEEPER_NAME" \
    --arg goal "$CAMPAIGN_GOAL" \
    --arg short_goal "Claim the campaign task and start autoresearch on the fixture repo." \
    --arg mid_goal "Reach the target score, then preserve goal/task lineage through pressure." \
    --arg long_goal "Prove keeper-only goal-reaching continuity without team_session." \
    --arg instructions "모든 응답은 한국어로 짧게 작성하세요. 목표와 current_task를 잃지 말고, 필요한 경우 masc_claim_next, masc_plan_set_task, masc_autoresearch_* 도구를 사용하세요." \
    --argjson models "$models_json_payload" \
    --argjson presence_keepalive_sec "$KEEPER_PRESENCE_KEEPALIVE_SEC" \
    --argjson compaction_ratio_gate "$KEEPER_COMPACTION_RATIO_GATE" \
    --argjson compaction_message_gate "$KEEPER_COMPACTION_MESSAGE_GATE" \
    --argjson continuity_compaction_cooldown_sec "$KEEPER_CONTINUITY_COOLDOWN_SEC" \
    --argjson handoff_threshold "$KEEPER_HANDOFF_THRESHOLD" \
    --argjson context_budget "$KEEPER_CONTEXT_BUDGET" \
    '{
      name:$name,
      goal:$goal,
      short_goal:$short_goal,
      mid_goal:$mid_goal,
      long_goal:$long_goal,
      instructions:$instructions,
      models:$models,
      tool_preset:"coding",
      presence_keepalive:true,
      presence_keepalive_sec:$presence_keepalive_sec,
      proactive_enabled:false,
      auto_handoff:true,
      compaction_profile:"custom",
      compaction_ratio_gate:$compaction_ratio_gate,
      compaction_message_gate:$compaction_message_gate,
      compaction_token_gate:0,
      continuity_compaction_cooldown_sec:$continuity_compaction_cooldown_sec,
      handoff_threshold:$handoff_threshold,
      handoff_cooldown_sec:30,
      context_budget:$context_budget,
      drift_enabled:false
    }')"
  call_mcp_tool 110 "masc_keeper_up" "$args" 60 || return 1
  KEEPER_CREATED=1
}

stop_keeper() {
  local args
  args="$(jq -cn --arg name "$KEEPER_NAME" '{name:$name,remove_meta:false,remove_session:false}')"
  if call_mcp_tool 111 "masc_keeper_down" "$args" 30; then
    KEEPER_STOPPED=1
    return 0
  fi
  return 1
}

keeper_status_json() {
  local raw_args
  raw_args="$(jq -cn --arg name "$KEEPER_NAME" '{
    name:$name,
    fast:false,
    include_context:true,
    include_metrics_overview:true,
    include_memory_bank:true,
    include_history_tail:true,
    include_compaction_history:true,
    tail_messages:5,
    tail_turns:3
  }')"
  call_mcp_tool 120 "masc_keeper_status" "$raw_args" 60
  tool_json
}

autoresearch_status_json() {
  local raw_args
  if [[ -n "$LOOP_ID" ]]; then
    raw_args="$(jq -cn --arg loop_id "$LOOP_ID" '{loop_id:$loop_id}')"
  else
    raw_args='{}'
  fi
  if call_mcp_tool 121 "masc_autoresearch_status" "$raw_args" 30; then
    tool_json
  else
    jq -nc --arg error "$LAST_TOOL_ERROR" '{error:$error}'
  fi
}

capture_snapshot() {
  local phase="$1"
  local keeper_file="$SNAP_DIR/${phase}-keeper-status.json"
  local loop_file="$SNAP_DIR/${phase}-autoresearch-status.json"
  local keeper_json loop_json
  keeper_json="$(keeper_status_json)"
  write_json_pretty "$keeper_file" "$keeper_json"
  refresh_latest_evidence_from_status "$keeper_json"
  loop_json="$(autoresearch_status_json)"
  write_json_pretty "$loop_file" "$loop_json"
  refresh_latest_loop_state "$loop_json"
  printf '%s\n%s\n' "$keeper_file" "$loop_file"
}

wait_for_bootstrap() {
  local deadline=$(( $(date +%s) + BOOTSTRAP_WAIT_SEC ))
  local status_json
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    status_json="$(keeper_status_json)"
    if [[ "$(printf '%s' "$status_json" | jq -r '.keepalive_running // false')" == "true" ]] \
      && [[ "$(printf '%s' "$status_json" | jq -r '.agent.exists // false')" == "true" ]]; then
      refresh_latest_evidence_from_status "$status_json"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_task_binding() {
  local expected_task_id="$1"
  local deadline=$(( $(date +%s) + TASK_WAIT_SEC ))
  local status_json
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    status_json="$(keeper_status_json)"
    refresh_latest_evidence_from_status "$status_json"
    if [[ "$CURRENT_TASK_ID" == "$expected_task_id" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_target_reached() {
  local deadline=$(( $(date +%s) + AUTORESEARCH_WAIT_SEC ))
  local loop_json
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    loop_json="$(autoresearch_status_json)"
    refresh_latest_loop_state "$loop_json"
    if [[ "$LATEST_TARGET_REACHED" == "true" ]]; then
      return 0
    fi
    if [[ "$(printf '%s' "$loop_json" | jq -r '.status // ""')" == "error" ]]; then
      return 1
    fi
    sleep 1
  done
  return 1
}

fixture_metric_py() {
  cat <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
print(1.0 if "GOAL_REACHED" in text else 0.0)
PY
}

create_fixture_repo() {
  FIXTURE_REPO="${BASE_PATH}/keeper-campaign-fixture"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "harness@example.com"
  git -C "$FIXTURE_REPO" config user.name "Harness User"
  printf 'TODO\n' >"$FIXTURE_REPO/campaign.txt"
  fixture_metric_py >"$FIXTURE_REPO/metric.py"
  git -C "$FIXTURE_REPO" add campaign.txt metric.py
  git -C "$FIXTURE_REPO" commit -q -m init
}

create_task() {
  local description
  description="$(cat <<EOF
Claim this task, keep it as current_task, and use keeper-driven autoresearch against:
- workdir: $FIXTURE_REPO
- target_file: campaign.txt
- metric_fn: python3 metric.py campaign.txt
- success condition: target_score = 1.0
- required change: replace TODO with GOAL_REACHED
EOF
)"
  local args
  args="$(jq -cn \
    --arg title "$CAMPAIGN_TASK_TITLE" \
    --arg description "$description" \
    '{title:$title,priority:1,description:$description}')"
  call_mcp_tool 130 "masc_add_task" "$args" 20 || return 1
  local output
  output="$(tool_text)"
  TASK_ID="$(printf '%s' "$output" | sed -n 's/.*Added \(task-[0-9][0-9][0-9]\):.*/\1/p' | head -n1)"
  [[ -n "$TASK_ID" ]]
}

short_prompt() {
  local label="$1"
  printf 'Campaign step: %s\n현재 goal과 current_task를 잃지 말고, 상태를 한국어로 2문장 이하로 요약하세요.\n' "$label"
}

pressure_prompt() {
  local turn="$1"
  python3 - "$RUN_ID" "$turn" "$PRESSURE_BYTES" <<'PY'
import sys
run_id, turn, target_bytes = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
anchor = f"CAMPAIGN-{run_id}-TURN-{turn}"
line = (
    f"Campaign continuity payload {anchor}. "
    "Keep the same goal and current_task_id. "
    "Do not start a new task or a new loop. "
)
buf = []
size = 0
while size < target_bytes:
    buf.append(line)
    size += len(line.encode())
body = "".join(buf)
print(
    f"Campaign pressure turn {turn}.\n"
    f"Current anchor: {anchor}\n"
    f"{body}\n"
    "답변은 짧게 하고 마지막 문장에 current_task를 다시 적어주세요."
)
PY
}

send_keeper_message() {
  local request_id="$1"
  local message="$2"
  local raw_args output_json output_text
  raw_args="$(jq -cn \
    --arg name "$KEEPER_NAME" \
    --arg message "$message" \
    --argjson timeout "$TURN_TIMEOUT_SEC" \
    '{name:$name,message:$message,timeout_sec:$timeout,require_existing:true}')"

  call_mcp_tool "$request_id" "masc_keeper_msg" "$raw_args" "$((TURN_TIMEOUT_SEC + 30))"
  output_text="$(tool_text)"
  output_json="$(jq -nc \
    --arg timestamp "$(iso_now)" \
    --arg input_preview "$(trim_preview "$message")" \
    --arg output_preview "$(trim_preview "$output_text")" \
    '{timestamp:$timestamp,input_preview:$input_preview,output_preview:$output_preview}')"
  write_json_pretty "$RAW_DIR/msg-${request_id}.json" "$output_json"
  LATEST_INPUT_PREVIEW="$(trim_preview "$message")"
  LATEST_OUTPUT_PREVIEW="$(trim_preview "$output_text")"
}

claim_and_bind_prompt() {
  cat <<EOF
Campaign kickoff.
1. Use masc_claim_next to claim the highest-priority task.
2. Keep that task as current_task. If current_task_id is still empty after claim, call masc_plan_set_task with the claimed task id.
3. Respond with the claimed task id and one short Korean sentence about the next step.
EOF
}

start_autoresearch_prompt() {
  cat <<EOF
Start keeper-only autoresearch for the claimed campaign task.

Required tool plan:
1. Use masc_autoresearch_start with:
   - goal: "Replace TODO with GOAL_REACHED and reach target score 1.0"
   - workdir: "$FIXTURE_REPO"
   - target_file: "campaign.txt"
   - metric_fn: "python3 metric.py campaign.txt"
   - baseline: 0.0
   - target_score: 1.0
   - max_cycles: 4
   - cycle_timeout_s: 30
2. Use masc_autoresearch_inject with hypothesis: "Replace TODO with GOAL_REACHED in campaign.txt"
3. Run masc_autoresearch_cycle until target_reached becomes true or you hit 4 cycles.

Respond with loop_id, current_task_id, and whether target_reached is true.
EOF
}

phase_status_string() {
  local value="$1"
  case "$value" in
    1) printf 'pass' ;;
    2) printf 'simulated' ;;
    *) printf 'fail' ;;
  esac
}

run_dry_run() {
  local phase keeper_file loop_file
  write_text "$SERVER_LOG" "dry-run mode: no live MCP calls executed"
  for phase in bootstrap task_bind autoresearch compaction handoff continuity; do
    [[ -n "$TARGET_PHASES" ]] && ! phase_enabled "$phase" && continue
    keeper_file="$SNAP_DIR/${phase}-keeper-status.json"
    loop_file="$SNAP_DIR/${phase}-autoresearch-status.json"
    write_json_pretty "$keeper_file" "$(jq -nc --arg phase "$phase" --arg run_id "$RUN_ID" '{
      simulated:true,
      dry_run:true,
      phase:$phase,
      run_id:$run_id,
      goal:"dry-run campaign goal",
      generation:1,
      compaction_count:1,
      handoff_count_total:1,
      keepalive_running:true,
      agent:{exists:true,status:"alive"},
      meta:{trace_id:"trace-dry-run",current_task_id:"task-001"}
    }')"
    write_json_pretty "$loop_file" "$(jq -nc --arg phase "$phase" --arg run_id "$RUN_ID" '{
      simulated:true,
      dry_run:true,
      phase:$phase,
      run_id:$run_id,
      loop_id:"ar-dry-run",
      status:"completed",
      target_score:1.0,
      target_reached:true
    }')"
    append_phase "$phase" "simulated" "dry-run synthetic (not runtime proof)" "$keeper_file" "$loop_file"
  done
  BOOTSTRAP_PASS=2
  TASK_BIND_PASS=2
  AUTORESEARCH_PASS=2
  COMPACTION_PASS=2
  HANDOFF_PASS=2
  CONTINUITY_PASS=2
  TASK_ID="task-001"
  LOOP_ID="ar-dry-run"
  CURRENT_TASK_ID="task-001"
  BASELINE_TASK_ID="task-001"
  BASELINE_GOAL="dry-run campaign goal"
  LATEST_TRACE_ID="trace-dry-run"
  LATEST_GENERATION="1"
  LATEST_COMPACTIONS="1"
  LATEST_HANDOFFS="1"
  LATEST_HEALTH="simulated"
  LATEST_LOOP_STATUS="completed"
  LATEST_TARGET_REACHED="true"
  LATEST_TARGET_SCORE="1"
  LATEST_INPUT_PREVIEW="[simulated] dry-run campaign input"
  LATEST_OUTPUT_PREVIEW="[simulated] dry-run campaign output"
  record_campaign_event "$(jq -nc --arg goal "$BASELINE_GOAL" '{event:"bootstrap_ok",goal:$goal}')"
  record_campaign_event "$(jq -nc --arg task_id "$TASK_ID" '{event:"task_bound_observed",task_id:$task_id,current_task_id:$task_id}')"
  record_campaign_event "$(jq -nc --arg loop_id "$LOOP_ID" '{event:"autoresearch_started",loop_id:$loop_id,target_score:1.0}')"
  record_campaign_event "$(jq -nc '{event:"target_reached"}')"
  record_campaign_event "$(jq -nc '{event:"pressure_started"}')"
  record_campaign_event "$(jq -nc '{event:"compaction_observed",count:1}')"
  record_campaign_event "$(jq -nc '{event:"handoff_observed",count:1,generation:2,trace_id:"trace-dry-run-2"}')"
  record_campaign_event "$(jq -nc --arg task_id "$TASK_ID" '{event:"continuity_observed",goal_matches:true,current_task_id:$task_id}')"
}

cleanup() {
  if [[ "$(normalize_bool "$DRY_RUN")" != "1" && "$KEEPER_CREATED" == "1" && "$KEEPER_STOPPED" != "1" && -n "${MCP_URL:-}" ]]; then
    stop_keeper >/dev/null 2>&1 || true
  fi
  if [[ "$(normalize_bool "$DRY_RUN")" != "1" && "$ROOM_JOINED" == "1" && -n "${MCP_URL:-}" ]]; then
    leave_room >/dev/null 2>&1 || true
  fi
  if [[ "$(normalize_bool "$KEEP_SERVER")" != "1" ]]; then
    harness_stop_server "$SERVER_PID" 10
  fi
  if [[ "$(normalize_bool "$KEEP_ARTIFACTS")" != "1" && -n "$TEMP_BASE_PATH" && -d "$TEMP_BASE_PATH" ]]; then
    rm -rf "$TEMP_BASE_PATH"
  fi
}
trap cleanup EXIT

finalize_report() {
  local verdict="escalated"
  local campaign_phase="escalated"
  local classification="FAIL"

  local bootstrap_ok="$BOOTSTRAP_PASS"
  local task_ok="$TASK_BIND_PASS"
  local search_ok="$AUTORESEARCH_PASS"
  local compaction_ok="$COMPACTION_PASS"
  local handoff_ok="$HANDOFF_PASS"
  local continuity_ok="$CONTINUITY_PASS"

  if ! phase_enabled bootstrap; then bootstrap_ok=1; fi
  if ! phase_enabled task_bind; then task_ok=1; fi
  if ! phase_enabled autoresearch; then search_ok=1; fi
  if ! phase_enabled compaction; then compaction_ok=1; fi
  if ! phase_enabled handoff; then handoff_ok=1; fi
  if ! phase_enabled continuity; then continuity_ok=1; fi

  if [[ -s "$CAMPAIGN_EVENTS_FILE" ]] && replay_campaign_fsm "$CAMPAIGN_EVENTS_FILE" "$CAMPAIGN_STATE_FILE"; then
    campaign_phase="$(jq -r '.phase // "escalated"' "$CAMPAIGN_STATE_FILE")"
    verdict="$(jq -r '.verdict // "escalated"' "$CAMPAIGN_STATE_FILE")"
  else
    write_json_pretty "$CAMPAIGN_STATE_FILE" "$(jq -nc \
      --arg phase "escalated" \
      --arg verdict "escalated" \
      --arg reason "campaign FSM replay failed or event log was empty" \
      '{phase:$phase,verdict:$verdict,reason:$reason}')"
  fi

  if [[ "$(normalize_bool "$DRY_RUN")" == "1" ]]; then
    classification="DRY_RUN"
    VALIDATION_EXIT_CODE=2
  elif [[ "$verdict" == "reached" ]]; then
    classification="PASS"
    VALIDATION_EXIT_CODE=0
  elif [[ "$verdict" == "stalled" ]]; then
    classification="PARTIAL"
    VALIDATION_EXIT_CODE=1
  else
    classification="FAIL"
    VALIDATION_EXIT_CODE=1
  fi

  local continuity_preserved=false
  if [[ "$CURRENT_TASK_ID" == "$BASELINE_TASK_ID" && -n "$CURRENT_TASK_ID" ]]; then
    continuity_preserved=true
  fi

  local summary_json
  summary_json="$(jq -nc \
    --arg run_id "$RUN_ID" \
    --arg run_dir "$RUN_DIR" \
    --arg classification "$classification" \
    --arg verdict "$verdict" \
    --arg campaign_phase "$campaign_phase" \
    --arg keeper "$KEEPER_NAME" \
    --arg task_id "$TASK_ID" \
    --arg current_task_id "$CURRENT_TASK_ID" \
    --arg loop_id "$LOOP_ID" \
    --arg trace_id "$LATEST_TRACE_ID" \
    --arg generation "$LATEST_GENERATION" \
    --arg compactions "$LATEST_COMPACTIONS" \
    --arg handoffs "$LATEST_HANDOFFS" \
    --arg goal "$BASELINE_GOAL" \
    --arg latest_health "$LATEST_HEALTH" \
    --arg latest_loop_status "$LATEST_LOOP_STATUS" \
    --arg latest_target_score "$LATEST_TARGET_SCORE" \
    --arg latest_input_preview "$LATEST_INPUT_PREVIEW" \
    --arg latest_output_preview "$LATEST_OUTPUT_PREVIEW" \
    --argjson bootstrap_pass "$( [[ "$BOOTSTRAP_PASS" != "0" ]] && echo true || echo false )" \
    --argjson task_bind_pass "$( [[ "$TASK_BIND_PASS" != "0" ]] && echo true || echo false )" \
    --argjson autoresearch_pass "$( [[ "$AUTORESEARCH_PASS" != "0" ]] && echo true || echo false )" \
    --argjson compaction_pass "$( [[ "$COMPACTION_PASS" != "0" ]] && echo true || echo false )" \
    --argjson handoff_pass "$( [[ "$HANDOFF_PASS" != "0" ]] && echo true || echo false )" \
    --argjson continuity_pass "$( [[ "$CONTINUITY_PASS" != "0" ]] && echo true || echo false )" \
    --argjson target_reached "$( [[ "$LATEST_TARGET_REACHED" == "true" ]] && echo true || echo false )" \
    --argjson continuity_preserved "$continuity_preserved" \
    --argjson dry_run "$( [[ "$(normalize_bool "$DRY_RUN")" == "1" ]] && echo true || echo false )" \
    '{
      run_id:$run_id,
      run_dir:$run_dir,
      classification:$classification,
      verdict:$verdict,
      campaign_phase:$campaign_phase,
      dry_run:$dry_run,
      keeper:$keeper,
      goal:$goal,
      task_id:$task_id,
      current_task_id:$current_task_id,
      loop_id:$loop_id,
      trace_id:$trace_id,
      generation:$generation,
      compaction_count:$compactions,
      handoff_count_total:$handoffs,
      latest_health:$latest_health,
      latest_loop_status:$latest_loop_status,
      target_score: (if $latest_target_score == "" then null else ($latest_target_score | tonumber?) end),
      target_reached:$target_reached,
      continuity_preserved:$continuity_preserved,
      latest_input_preview:$latest_input_preview,
      latest_output_preview:$latest_output_preview,
      phases:{
        bootstrap:{pass:$bootstrap_pass},
        task_bind:{pass:$task_bind_pass},
        autoresearch:{pass:$autoresearch_pass},
        compaction:{pass:$compaction_pass},
        handoff:{pass:$handoff_pass},
        continuity:{pass:$continuity_pass}
      }
    }')"
  write_json_pretty "$RUN_DIR/summary.json" "$summary_json"

  cat >"$RUN_DIR/summary.md" <<EOF
# Keeper Campaign Harness

- Run ID: \`$RUN_ID\`
- Classification: **$classification**
- Verdict: **$verdict**
- Campaign phase: \`$campaign_phase\`
- Dry run: $( [[ "$(normalize_bool "$DRY_RUN")" == "1" ]] && echo "yes" || echo "no" )
- Keeper: \`$KEEPER_NAME\`
- Models: \`$KEEPER_MODELS\`
- Goal: $BASELINE_GOAL

## Result

| Phase | Result |
|---|---|
| bootstrap | $(phase_status_string "$BOOTSTRAP_PASS") |
| task_bind | $(phase_status_string "$TASK_BIND_PASS") |
| autoresearch | $(phase_status_string "$AUTORESEARCH_PASS") |
| compaction | $(phase_status_string "$COMPACTION_PASS") |
| handoff | $(phase_status_string "$HANDOFF_PASS") |
| continuity | $(phase_status_string "$CONTINUITY_PASS") |

## Evidence

- Task ID: \`$TASK_ID\`
- Current task ID: \`$CURRENT_TASK_ID\`
- Loop ID: \`$LOOP_ID\`
- Latest loop status: \`$LATEST_LOOP_STATUS\`
- Target reached: \`$LATEST_TARGET_REACHED\`
- Trace ID: \`$LATEST_TRACE_ID\`
- Generation: \`$LATEST_GENERATION\`
- Compactions: \`$LATEST_COMPACTIONS\`
- Handoffs: \`$LATEST_HANDOFFS\`
- Latest health: \`$LATEST_HEALTH\`
- Recent input preview: $LATEST_INPUT_PREVIEW
- Recent output preview: $LATEST_OUTPUT_PREVIEW

## Interpretation
EOF

  if [[ "$(normalize_bool "$DRY_RUN")" == "1" ]]; then
    cat >>"$RUN_DIR/summary.md" <<'EOF'
- **reached**: dry-run synthetic campaign succeeded. This proves the harness contract only.
- **stalled**: not used in dry-run mode.
- **escalated**: dry-run harness plumbing failed.
EOF
  else
    cat >>"$RUN_DIR/summary.md" <<'EOF'
- **reached**: keeper claimed the task, reached target_score through autoresearch, and preserved goal/task lineage after compaction or handoff pressure.
- **stalled**: the keeper stayed mostly coherent, but target or continuity proof did not finish inside the validation window.
- **escalated**: the keeper never established a viable goal-reaching lane or surfaced a blocking/error state.
EOF
  fi

  cat >>"$RUN_DIR/summary.md" <<EOF

## Artifacts

- Summary JSON: \`$RUN_DIR/summary.json\`
- Campaign FSM state: \`$CAMPAIGN_STATE_FILE\`
- Campaign event log: \`$CAMPAIGN_EVENTS_FILE\`
- Phase log: \`$RUN_DIR/phases.jsonl\`
- Snapshots: \`$SNAP_DIR\`
- Raw keeper turns: \`$RAW_DIR\`
- Server log: \`$SERVER_LOG\`
EOF

  local manifest_json
  manifest_json="$(jq -nc \
    --arg run_id "$RUN_ID" \
    --arg run_dir "$RUN_DIR" \
    --arg summary_json "$RUN_DIR/summary.json" \
    --arg summary_md "$RUN_DIR/summary.md" \
    --arg campaign_state "$CAMPAIGN_STATE_FILE" \
    --arg campaign_events "$CAMPAIGN_EVENTS_FILE" \
    --arg phases "$RUN_DIR/phases.jsonl" \
    --arg snapshots "$SNAP_DIR" \
    --arg raw "$RAW_DIR" \
    '{run_id:$run_id,run_dir:$run_dir,summary_json:$summary_json,summary_md:$summary_md,campaign_state:$campaign_state,campaign_events:$campaign_events,phases:$phases,snapshots:$snapshots,raw:$raw}')"
  write_json_pretty "$RUN_DIR/manifest.json" "$manifest_json"
}

real_run() {
  local models_json_payload snapshot_info keeper_file loop_file keeper_json loop_json
  local pressure_turn

  require_cmd jq || { echo "jq is required" >&2; return 1; }
  require_cmd curl || { echo "curl is required" >&2; return 1; }
  require_cmd python3 || { echo "python3 is required" >&2; return 1; }
  require_cmd git || { echo "git is required" >&2; return 1; }

  if [[ -z "$KEEPER_MODELS" ]]; then
    echo "KEEPER_MODELS is required (example: KEEPER_MODELS='glm:auto')" >&2
    return 1
  fi

  if [[ "$(normalize_bool "$START_SERVER")" == "1" ]]; then
    TEMP_BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/keeper-campaign.${RUN_ID}.XXXXXX")"
    BASE_PATH="${BASE_PATH:-$TEMP_BASE_PATH}"
    PORT="${PORT:-$(harness_pick_free_port)}"
    MCP_URL="http://127.0.0.1:${PORT}/mcp"
    local server_exe
    server_exe="$(harness_find_server_exe "$REPO_ROOT" "$SERVER_EXE")"
    SERVER_PID="$(harness_start_server "$server_exe" "$PORT" "$BASE_PATH" "$SERVER_LOG")"
    if ! harness_wait_for_health "$PORT" "$HEALTH_TIMEOUT_SEC"; then
      echo "failed to start isolated server on port $PORT" >&2
      harness_print_log_tail "$SERVER_LOG" 120
      return 1
    fi
  elif [[ -z "$MCP_URL" ]]; then
    echo "MCP_URL is required when START_SERVER=0" >&2
    return 1
  fi

  join_room
  create_fixture_repo
  models_json_payload="$(models_json)"
  create_keeper "$models_json_payload"

  if ! wait_for_bootstrap; then
    record_campaign_event "$(jq -nc '{event:"error_observed",reason:"keeper bootstrap timeout"}')"
    snapshot_info="$(capture_snapshot bootstrap)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "bootstrap" "fail" "keepalive or room presence did not appear in time" "$keeper_file" "$loop_file"
    return 1
  fi

  record_campaign_event "$(jq -nc --arg goal "$CAMPAIGN_GOAL" '{event:"bootstrap_ok",goal:$goal}')"
  if phase_enabled bootstrap; then
    snapshot_info="$(capture_snapshot bootstrap)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    BOOTSTRAP_PASS=1
    append_phase "bootstrap" "pass" "keeper started with active keepalive and status surface" "$keeper_file" "$loop_file"
  fi

  if ! create_task; then
    record_campaign_event "$(jq -nc --arg reason "task creation failed: $LAST_TOOL_ERROR" '{event:"error_observed",reason:$reason}')"
    snapshot_info="$(capture_snapshot task-create)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "task_bind" "fail" "task creation failed: $LAST_TOOL_ERROR" "$keeper_file" "$loop_file"
    return 1
  fi

  if ! send_keeper_message 200 "$(claim_and_bind_prompt)"; then
    record_campaign_event "$(jq -nc --arg reason "keeper claim turn failed: $LAST_TOOL_ERROR" '{event:"error_observed",reason:$reason}')"
    snapshot_info="$(capture_snapshot task-bind)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "task_bind" "fail" "keeper claim turn failed: $LAST_TOOL_ERROR" "$keeper_file" "$loop_file"
    return 1
  fi

  if ! wait_for_task_binding "$TASK_ID"; then
    record_campaign_event "$(jq -nc '{event:"window_exhausted",reason:"task binding timeout"}')"
    snapshot_info="$(capture_snapshot task-bind)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "task_bind" "fail" "keeper did not bind current_task_id=$TASK_ID" "$keeper_file" "$loop_file"
    return 1
  fi

  BASELINE_TASK_ID="$CURRENT_TASK_ID"
  keeper_json="$(keeper_status_json)"
  BASELINE_GOAL="$(printf '%s' "$keeper_json" | jq -r '.goal // ""')"
  BASELINE_TRACE_ID="$(printf '%s' "$keeper_json" | jq -r '.meta.trace_id // ""')"
  BASELINE_GENERATION="$(printf '%s' "$keeper_json" | jq -r '(.generation | tonumber?) // 0')"
  BASELINE_COMPACTIONS="$(printf '%s' "$keeper_json" | jq -r '(.compaction_count | tonumber?) // 0')"
  BASELINE_HANDOFFS="$(printf '%s' "$keeper_json" | jq -r '(.handoff_count_total | tonumber?) // 0')"
  record_campaign_event "$(jq -nc --arg task_id "$TASK_ID" --arg current_task_id "$CURRENT_TASK_ID" '{event:"task_bound_observed",task_id:$task_id,current_task_id:$current_task_id}')"
  if phase_enabled task_bind; then
    snapshot_info="$(capture_snapshot task-bind)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    TASK_BIND_PASS=1
    append_phase "task_bind" "pass" "keeper claimed the task and current_task_id is bound" "$keeper_file" "$loop_file"
  fi

  if ! send_keeper_message 210 "$(start_autoresearch_prompt)"; then
    record_campaign_event "$(jq -nc --arg reason "keeper autoresearch turn failed: $LAST_TOOL_ERROR" '{event:"error_observed",reason:$reason}')"
    snapshot_info="$(capture_snapshot autoresearch)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "autoresearch" "fail" "keeper autoresearch turn failed: $LAST_TOOL_ERROR" "$keeper_file" "$loop_file"
    return 1
  fi

  if ! wait_for_target_reached; then
    record_campaign_event "$(jq -nc '{event:"window_exhausted",reason:"autoresearch target timeout"}')"
    snapshot_info="$(capture_snapshot autoresearch)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "autoresearch" "fail" "autoresearch did not reach target_score within the validation window" "$keeper_file" "$loop_file"
    return 1
  fi

  record_campaign_event "$(jq -nc --arg loop_id "$LOOP_ID" --argjson target_score 1.0 '{event:"autoresearch_started",loop_id:$loop_id,target_score:$target_score}')"
  record_campaign_event "$(jq -nc '{event:"target_reached"}')"
  record_campaign_event "$(jq -nc '{event:"pressure_started"}')"
  if phase_enabled autoresearch; then
    snapshot_info="$(capture_snapshot autoresearch)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    AUTORESEARCH_PASS=1
    append_phase "autoresearch" "pass" "keeper-driven autoresearch reached target_score" "$keeper_file" "$loop_file"
  fi

  for pressure_turn in $(seq 1 "$MAX_PRESSURE_TURNS"); do
    if ! phase_enabled compaction && ! phase_enabled handoff; then
      break
    fi
    if ! send_keeper_message "$((300 + pressure_turn))" "$(pressure_prompt "$pressure_turn")"; then
      break
    fi
    sleep "$PRESSURE_PAUSE_SEC"
    snapshot_info="$(capture_snapshot "pressure-${pressure_turn}")"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    keeper_json="$(cat "$keeper_file")"
    if [[ $COMPACTION_PASS -eq 0 ]] \
      && [[ "$(printf '%s' "$keeper_json" | jq -r '(((.compaction_count | tonumber?) // 0) > (($old | tonumber?) // 0))' --arg old "$BASELINE_COMPACTIONS")" == "true" ]]; then
      COMPACTION_PASS=1
      BASELINE_COMPACTIONS="$(printf '%s' "$keeper_json" | jq -r '(.compaction_count | tonumber?) // 0')"
      record_campaign_event "$(jq -nc --argjson count "$BASELINE_COMPACTIONS" '{event:"compaction_observed",count:$count}')"
      append_phase "compaction" "pass" "compaction counter increased under campaign pressure" "$keeper_file" "$loop_file"
    fi
    if [[ $HANDOFF_PASS -eq 0 ]] \
      && { [[ "$(printf '%s' "$keeper_json" | jq -r '(((.generation | tonumber?) // 0) > (($old | tonumber?) // 0))' --arg old "$BASELINE_GENERATION")" == "true" ]] \
        || [[ "$(printf '%s' "$keeper_json" | jq -r '(((.handoff_count_total | tonumber?) // 0) > (($old | tonumber?) // 0))' --arg old "$BASELINE_HANDOFFS")" == "true" ]] \
        || [[ "$(printf '%s' "$keeper_json" | jq -r '.meta.trace_id != $old' --arg old "$BASELINE_TRACE_ID")" == "true" ]]; }; then
      HANDOFF_PASS=1
      BASELINE_GENERATION="$(printf '%s' "$keeper_json" | jq -r '(.generation | tonumber?) // 0')"
      BASELINE_HANDOFFS="$(printf '%s' "$keeper_json" | jq -r '(.handoff_count_total | tonumber?) // 0')"
      BASELINE_TRACE_ID="$(printf '%s' "$keeper_json" | jq -r '.meta.trace_id // ""')"
      record_campaign_event "$(jq -nc --argjson count "$BASELINE_HANDOFFS" --argjson generation "$BASELINE_GENERATION" --arg trace_id "$BASELINE_TRACE_ID" '{event:"handoff_observed",count:$count,generation:$generation,trace_id:$trace_id}')"
      append_phase "handoff" "pass" "generation or trace evidence changed under campaign pressure" "$keeper_file" "$loop_file"
    fi
    if [[ $COMPACTION_PASS -eq 1 || $HANDOFF_PASS -eq 1 ]]; then
      break
    fi
  done

  if phase_enabled compaction && [[ $COMPACTION_PASS -eq 0 ]]; then
    snapshot_info="$(capture_snapshot compaction-miss)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "compaction" "fail" "compaction evidence did not appear within the validation window" "$keeper_file" "$loop_file"
  fi

  if phase_enabled handoff && [[ $HANDOFF_PASS -eq 0 ]]; then
    snapshot_info="$(capture_snapshot handoff-miss)"
    keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "handoff" "fail" "handoff evidence did not appear within the validation window" "$keeper_file" "$loop_file"
  fi

  snapshot_info="$(capture_snapshot continuity)"
  keeper_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
  loop_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
  keeper_json="$(cat "$keeper_file")"
  loop_json="$(cat "$loop_file")"
  if [[ "$(printf '%s' "$keeper_json" | jq -r '.goal // ""')" == "$BASELINE_GOAL" ]] \
    && [[ "$(printf '%s' "$keeper_json" | jq -r '.meta.current_task_id // ""')" == "$BASELINE_TASK_ID" ]] \
    && [[ "$(printf '%s' "$loop_json" | jq -r 'if (.target_reached // false) then "true" else "false" end')" == "true" ]] \
    && [[ $COMPACTION_PASS -eq 1 || $HANDOFF_PASS -eq 1 ]]; then
    CONTINUITY_PASS=1
    record_campaign_event "$(jq -nc --arg task_id "$BASELINE_TASK_ID" '{event:"continuity_observed",goal_matches:true,current_task_id:$task_id}')"
    append_phase "continuity" "pass" "goal/current_task lineage survived campaign pressure after target reach" "$keeper_file" "$loop_file"
  else
    if [[ $COMPACTION_PASS -eq 1 || $HANDOFF_PASS -eq 1 ]]; then
      record_campaign_event "$(jq -nc \
        --arg current_task_id "$(printf '%s' "$keeper_json" | jq -r '.meta.current_task_id // empty')" \
        --argjson goal_matches "$( [[ "$(printf '%s' "$keeper_json" | jq -r '.goal // ""')" == "$BASELINE_GOAL" ]] && echo true || echo false )" \
        '{event:"continuity_observed",goal_matches:$goal_matches,current_task_id:(if $current_task_id == "" then null else $current_task_id end)}')"
    else
      record_campaign_event "$(jq -nc '{event:"window_exhausted",reason:"continuity proof missing lifecycle evidence"}')"
    fi
    append_phase "continuity" "fail" "goal/current_task lineage was not preserved after pressure or no lifecycle event occurred" "$keeper_file" "$loop_file"
  fi
}

main() {
  if [[ "$(normalize_bool "$DRY_RUN")" == "1" ]]; then
    run_dry_run
    finalize_report
    printf '%s\n' "$RUN_DIR/summary.json"
    exit 0
  fi

  if real_run; then
    finalize_report
    printf '%s\n' "$RUN_DIR/summary.json"
    exit "$VALIDATION_EXIT_CODE"
  else
    finalize_report
    printf '%s\n' "$RUN_DIR/summary.json"
    exit 1
  fi
}

main "$@"
