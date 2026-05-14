#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/harness/lib/mcp_jsonrpc.sh"
source "$REPO_ROOT/scripts/harness/lib/server_bootstrap.sh"

RUN_ID="${RUN_ID:-keeper-continuity-$(date +%Y%m%d_%H%M%S)-$$}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/keeper_continuity/$RUN_ID}"
SNAP_DIR="$RUN_DIR/snapshots"
RAW_DIR="$RUN_DIR/raw"
mkdir -p "$RUN_DIR" "$SNAP_DIR" "$RAW_DIR"

DRY_RUN="${DRY_RUN:-0}"
START_SERVER="${START_SERVER:-1}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"
KEEP_SERVER="${KEEP_SERVER:-0}"
PORT="${PORT:-}"
BASE_PATH="${BASE_PATH:-}"
SERVER_EXE="${SERVER_EXE:-}"
MCP_URL="${MCP_URL:-}"
MCP_TOKEN="${MASC_MCP_TOKEN:-}"
KEEPER_CASCADE_NAME="${KEEPER_CASCADE_NAME:-}"
KEEPER_NAME="${KEEPER_NAME:-continuity-${RUN_ID}}"
TARGET_PHASES="${TARGET_PHASES:-bootstrap,liveness,continuity,compaction,handoff,recovery}"
MAX_TURNS="${MAX_TURNS:-4}"
TURN_TIMEOUT_SEC="${TURN_TIMEOUT_SEC:-90}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-20}"
HEARTBEAT_WAIT_SEC="${HEARTBEAT_WAIT_SEC:-15}"
PRESSURE_BYTES="${PRESSURE_BYTES:-20000}"
PRESSURE_PAUSE_SEC="${PRESSURE_PAUSE_SEC:-1}"
KEEPER_COMPACTION_RATIO_GATE="${KEEPER_COMPACTION_RATIO_GATE:-0.10}"
KEEPER_COMPACTION_MESSAGE_GATE="${KEEPER_COMPACTION_MESSAGE_GATE:-2}"
KEEPER_CONTINUITY_COOLDOWN_SEC="${KEEPER_CONTINUITY_COOLDOWN_SEC:-0}"
KEEPER_HANDOFF_THRESHOLD="${KEEPER_HANDOFF_THRESHOLD:-0.01}"

SERVER_PID=""
SERVER_LOG="$RUN_DIR/server.log"
TEMP_BASE_PATH=""
VALIDATION_EXIT_CODE=1
KEEPER_CREATED=0
KEEPER_STOPPED=0

BOOTSTRAP_PASS=0
LIVENESS_PASS=0
CONTINUITY_PASS=0
COMPACTION_PASS=0
HANDOFF_PASS=0
RECOVERY_PASS=0
LATEST_INPUT_PREVIEW=""
LATEST_OUTPUT_PREVIEW=""
LATEST_TRACE_ID=""
LATEST_GENERATION=""
LATEST_COMPACTIONS=""
LATEST_HANDOFFS=""
LATEST_HEALTH=""
LATEST_HEARTBEAT=""
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
  local heartbeat_file="$5"
  jq -nc \
    --arg ts "$(iso_now)" \
    --arg phase "$phase" \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg snapshot_file "$snapshot_file" \
    --arg heartbeat_file "$heartbeat_file" \
    '{
      timestamp: $ts,
      phase: $phase,
      status: $status,
      summary: $summary,
      snapshot_file: (if ($snapshot_file | length) > 0 then $snapshot_file else null end),
      heartbeat_file: (if ($heartbeat_file | length) > 0 then $heartbeat_file else null end)
    }' >>"$RUN_DIR/phases.jsonl"
}

call_mcp_tool() {
  local req_id="$1"
  local tool_name="$2"
  local args_json="$3"
  local timeout_sec="${4:-$TURN_TIMEOUT_SEC}"

  local saved_timeout="${HTTP_TIMEOUT_SEC:-}"
  HTTP_TIMEOUT_SEC="$timeout_sec"
  set +e
  LAST_TOOL_RAW="$(mcp_call_tool "$req_id" "$tool_name" "$args_json" "${MCP_SESSION_ID:-}" "$MCP_TOKEN" "$MCP_URL")"
  local call_status=$?
  set -e
  HTTP_TIMEOUT_SEC="$saved_timeout"

  if [[ "$call_status" -ne 0 ]]; then
    LAST_TOOL_ERROR="MCP helper failed with status $call_status"
    return 1
  fi

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

load_mcp_token() {
  local prefer_file="${1:-0}"
  local token_file="$BASE_PATH/.masc/auth/codex-mcp-client.token"
  if [[ "$prefer_file" == "1" ]]; then
    local attempt
    for attempt in $(seq 1 20); do
      if [[ -f "$token_file" ]]; then
        MCP_TOKEN="$(tr -d '\n' <"$token_file")"
        return 0
      fi
      sleep 0.2
    done
    MCP_TOKEN=""
    return 0
  fi
  if [[ -n "$MCP_TOKEN" ]]; then
    return 0
  fi
  if [[ -f "$token_file" ]]; then
    MCP_TOKEN="$(tr -d '\n' <"$token_file")"
  fi
}

init_mcp_session() {
  if [[ -n "${MCP_SESSION_ID:-}" ]]; then
    return 0
  fi

  local headers_file body_file init_body session_id protocol_version
  headers_file="$(mcp_mktemp_file "keeper-continuity-init" ".headers")"
  body_file="$(mcp_mktemp_file "keeper-continuity-init" ".body")"
  init_body="$(
    jq -cn '{
      jsonrpc:"2.0",
      id:1,
      method:"initialize",
      params:{
        protocolVersion:"2025-11-25",
        clientInfo:{name:"keeper-continuity-validation", version:"1.0"},
        capabilities:{}
      }
    }'
  )"

  local -a cmd=(
    curl -sS --max-time 20
    -D "$headers_file"
    -o "$body_file"
    -X POST "$MCP_URL"
    -H "Content-Type: application/json"
    -H "Accept: application/json, text/event-stream"
  )
  if [[ -n "$MCP_TOKEN" ]]; then
    cmd+=( -H "Authorization: Bearer $MCP_TOKEN" )
  fi
  cmd+=( --data-binary "$init_body" )

  if ! "${cmd[@]}" >/dev/null 2>"$RAW_DIR/mcp-initialize.stderr"; then
    LAST_TOOL_ERROR="MCP initialize transport failed"
    rm -f "$headers_file" "$body_file"
    return 1
  fi

  session_id="$(
    awk '
      tolower($0) ~ /^mcp-session-id:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        sub(/\r$/, "", $0)
        print $0
        exit
      }' "$headers_file"
  )"
  protocol_version="$(
    awk '
      tolower($0) ~ /^mcp-protocol-version:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        sub(/\r$/, "", $0)
        print $0
        exit
      }' "$headers_file"
  )"

  if [[ -z "$session_id" ]]; then
    LAST_TOOL_ERROR="MCP initialize did not return Mcp-Session-Id"
    cp "$body_file" "$RAW_DIR/mcp-initialize.body" 2>/dev/null || true
    rm -f "$headers_file" "$body_file"
    return 1
  fi

  MCP_SESSION_ID="$session_id"
  export MCP_SESSION_ID
  if [[ -n "$protocol_version" ]]; then
    MCP_PROTOCOL_VERSION="$protocol_version"
    export MCP_PROTOCOL_VERSION
  fi
  rm -f "$headers_file" "$body_file"
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
  LATEST_HEALTH="$(printf '%s' "$status_json" | jq -r '.diagnostic.health_state // ""')"
  if [[ "$(printf '%s' "$status_json" | jq -r '.keepalive_running // false')" == "true" ]] \
    && [[ "$(printf '%s' "$status_json" | jq -r '.agent.exists // false')" == "true" ]]; then
    LATEST_HEARTBEAT="room-keepalive-active"
  else
    LATEST_HEARTBEAT="room-keepalive-missing"
  fi
}

heartbeat_contains_agent() {
  local heartbeat_text="$1"
  local agent_name="$2"
  printf '%s' "$heartbeat_text" | grep -F "agent=$agent_name" >/dev/null 2>&1
}

keeper_status_json() {
  local raw_args
  raw_args="$(jq -cn --arg name "$KEEPER_NAME" '{
    name: $name,
    fast: false,
    include_context: true,
    include_metrics_overview: true,
    include_memory_bank: true,
    include_history_tail: true,
    include_compaction_history: true,
    tail_messages: 5,
    tail_turns: 3
  }')"
  if call_mcp_tool 1001 "masc_keeper_status" "$raw_args" 60; then
    if ! tool_json; then
      jq -nc '{keepalive_running:false, agent:{exists:false}, harness_error:"invalid keeper status JSON"}'
    fi
  else
    jq -nc --arg error "$LAST_TOOL_ERROR" \
      '{keepalive_running:false, agent:{exists:false}, harness_error:$error}'
  fi
}

wait_for_keeper_status_condition() {
  local jq_filter="$1"
  local timeout_sec="$2"
  local deadline=$(( $(date +%s) + timeout_sec ))
  local status_json=""
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    status_json="$(keeper_status_json)"
    if printf '%s' "$status_json" | jq -e "$jq_filter" >/dev/null 2>&1; then
      printf '%s' "$status_json"
      return 0
    fi
    sleep 1
  done
  printf '%s' "$status_json"
  return 1
}

heartbeat_text() {
  if call_mcp_tool 1002 "masc_heartbeat_list" '{}' 20; then
    tool_text
  else
    printf 'harness_error: %s\n' "$LAST_TOOL_ERROR"
  fi
}

room_status_text() {
  if call_mcp_tool 1003 "masc_status" '{}' 20; then
    tool_text
  else
    printf 'harness_error: %s\n' "$LAST_TOOL_ERROR"
  fi
}

capture_snapshot() {
  local phase="$1"
  local snapshot_file="$SNAP_DIR/${phase}-keeper-status.json"
  local heartbeat_file="$SNAP_DIR/${phase}-heartbeat.txt"
  local room_file="$SNAP_DIR/${phase}-room-status.txt"
  local status_json heartbeat_output room_output

  status_json="$(keeper_status_json)"
  write_json_pretty "$snapshot_file" "$status_json"
  heartbeat_output="$(heartbeat_text)"
  write_text "$heartbeat_file" "$heartbeat_output"
  room_output="$(room_status_text)"
  write_text "$room_file" "$room_output"

  printf '%s\n%s\n%s\n' "$snapshot_file" "$heartbeat_file" "$room_file"
}

runtime_terminal_summary() {
  local status_json="$1"
  local expected_turn="$2"
  local trace_id manifest_path summary
  trace_id="$(printf '%s' "$status_json" | jq -r '.meta.trace_id // ""' 2>/dev/null || true)"
  [[ -n "$trace_id" && "$trace_id" != "null" ]] || return 0
  manifest_path="$BASE_PATH/.masc/keepers/$KEEPER_NAME/runtime-manifests/${trace_id}.jsonl"
  [[ -f "$manifest_path" ]] || return 0
  summary="$(jq -sr --argjson turn "$expected_turn" '
    [ .[] | select(.keeper_turn_id == $turn or (.keeper_turn_id == null and .event == "turn_finished")) ] as $rows
    | if (($rows | length) == 0) then ""
      else
        {
          turn_status: (([ $rows[] | select(.event == "turn_finished") | .status // empty ] | last) // ""),
          terminal_reason: (([ $rows[] | select(.event == "turn_finished") | .decision.terminal_reason_code // empty ] | last) // ""),
          provider_status: (([ $rows[] | select(.event == "provider_attempt_finished") | .status // empty ] | last) // ""),
          provider_error: (([ $rows[] | select(.event == "provider_attempt_finished") | .decision.error // empty ] | last) // "")
        }
        | if ([.turn_status,.terminal_reason,.provider_status,.provider_error] | map(select(length > 0)) | length) == 0 then ""
          else "runtime_terminal turn_status=\(.turn_status) terminal_reason=\(.terminal_reason) provider_status=\(.provider_status) provider_error=\(.provider_error)"
          end
      end
  ' "$manifest_path" 2>/dev/null || true)"
  [[ -n "$summary" ]] || return 0
  trim_preview "$summary"
}

wait_for_bootstrap() {
  local deadline=$(( $(date +%s) + HEARTBEAT_WAIT_SEC ))
  local status_json
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    status_json="$(keeper_status_json)"
    if [[ "$(printf '%s' "$status_json" | jq -r '.keepalive_running')" == "true" ]] \
      && [[ "$(printf '%s' "$status_json" | jq -r '.agent.exists')" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_restarted_heartbeat() {
  local _agent_name="$1"
  local deadline=$(( $(date +%s) + HEARTBEAT_WAIT_SEC ))
  local status_json
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    status_json="$(keeper_status_json)"
    if [[ "$(printf '%s' "$status_json" | jq -r '.keepalive_running')" == "true" ]] \
      && [[ "$(printf '%s' "$status_json" | jq -r '.agent.exists')" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

pressure_prompt() {
  local turn="$1"
  python3 - "$RUN_ID" "$turn" "$PRESSURE_BYTES" <<'PY'
import sys
run_id, turn, target_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3])
anchor = f"ANCHOR-{run_id}-TURN-{turn}"
line = (
    f"Validation continuity payload {anchor}. "
    "Summarize current state in 2 short Korean sentences and mention the current anchor once. "
)
buf = []
size = 0
while size < target_bytes:
    buf.append(line)
    size += len(line.encode())
body = "".join(buf)
print(
    f"Validation turn {turn}.\n"
    f"Current anchor: {anchor}\n"
    f"{body}\n"
    "답변은 짧게 하고, 마지막 문장에 현재 anchor를 다시 한 번 적어주세요."
)
PY
}

short_prompt() {
  local label="$1"
  printf 'Validation step: %s\n현재 상태를 한국어로 짧게 요약하고 next step 1개만 말해 주세요.\n' "$label"
}

send_keeper_message() {
  local request_id="$1"
  local message="$2"
  local raw_args output_json output_text
  raw_args="$(jq -cn \
    --arg name "$KEEPER_NAME" \
    --arg message "$message" \
    --argjson timeout "$TURN_TIMEOUT_SEC" \
    '{name:$name,message:$message,timeout_sec:$timeout}')"

  if ! call_mcp_tool "$request_id" "masc_keeper_msg" "$raw_args" "$((TURN_TIMEOUT_SEC + 30))"; then
    return 1
  fi
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

create_keeper() {
  local args
  args="$(jq -cn \
    --arg name "$KEEPER_NAME" \
    --arg goal "Validate real keeper continuity under isolated load." \
    --arg instructions "모든 응답은 한국어로 작성하세요. 짧고 구조적으로 답하세요." \
    --arg cascade_name "$KEEPER_CASCADE_NAME" \
    --argjson compaction_ratio_gate "$KEEPER_COMPACTION_RATIO_GATE" \
    --argjson compaction_message_gate "$KEEPER_COMPACTION_MESSAGE_GATE" \
    --argjson continuity_compaction_cooldown_sec "$KEEPER_CONTINUITY_COOLDOWN_SEC" \
    --argjson handoff_threshold "$KEEPER_HANDOFF_THRESHOLD" \
    '{
      name:$name,
      goal:$goal,
      instructions:$instructions,
      proactive_enabled:false,
      auto_handoff:true,
      compaction_profile:"custom",
      compaction_ratio_gate:$compaction_ratio_gate,
      compaction_message_gate:$compaction_message_gate,
      compaction_token_gate:0,
      continuity_compaction_cooldown_sec:$continuity_compaction_cooldown_sec,
      handoff_threshold:$handoff_threshold,
      handoff_cooldown_sec:30,
      drift_enabled:false
    } + (if ($cascade_name | length) > 0 then {cascade_name:$cascade_name} else {} end)')"
  call_mcp_tool 1100 "masc_keeper_up" "$args" 60
}

stop_keeper() {
  local remove_meta="${1:-false}"
  local remove_session="${2:-false}"
  local args
  args="$(jq -cn --arg name "$KEEPER_NAME" --argjson remove_meta "$remove_meta" --argjson remove_session "$remove_session" \
    '{name:$name,remove_meta:$remove_meta,remove_session:$remove_session}')"
  if call_mcp_tool 1101 "masc_keeper_down" "$args" 30; then
    KEEPER_STOPPED=1
    return 0
  fi
  return 1
}

phase_status_string() {
  local value="$1"
  if [[ "$value" == "1" ]]; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

phase_report_string() {
  local phase="$1"
  local value="$2"
  if ! phase_enabled "$phase"; then
    printf 'skipped'
  elif [[ "$value" == "2" ]]; then
    printf 'simulated'
  elif [[ "$value" == "1" ]]; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

run_dry_run() {
  local phase snapshot_file heartbeat_file
  write_text "$SERVER_LOG" "dry-run mode: no live MCP calls executed"
  for phase in bootstrap liveness continuity compaction handoff recovery; do
    [[ -n "$TARGET_PHASES" ]] && ! phase_enabled "$phase" && continue
    snapshot_file="$SNAP_DIR/${phase}-keeper-status.json"
    heartbeat_file="$SNAP_DIR/${phase}-heartbeat.txt"
    write_json_pretty "$snapshot_file" "$(jq -nc --arg phase "$phase" --arg run_id "$RUN_ID" '{simulated:true,dry_run:true,phase:$phase,run_id:$run_id}')"
    write_text "$heartbeat_file" "[simulated] Active heartbeats:\n  • dry-run: agent=keeper-dry-run-agent interval=5s message=\"dry-run\" uptime=1s"
    append_phase "$phase" "simulated" "dry-run synthetic (not runtime proof)" "$snapshot_file" "$heartbeat_file"
  done
  BOOTSTRAP_PASS=2
  LIVENESS_PASS=2
  CONTINUITY_PASS=2
  COMPACTION_PASS=2
  HANDOFF_PASS=2
  RECOVERY_PASS=2
  LATEST_INPUT_PREVIEW="[simulated] dry-run validation input"
  LATEST_OUTPUT_PREVIEW="[simulated] dry-run validation output"
  LATEST_TRACE_ID="trace-dry-run-simulated"
  LATEST_GENERATION="0"
  LATEST_COMPACTIONS="0"
  LATEST_HANDOFFS="0"
  LATEST_HEALTH="simulated"
  LATEST_HEARTBEAT="simulated"
}

cleanup() {
  if [[ "$(normalize_bool "$DRY_RUN")" != "1" && "$KEEPER_CREATED" == "1" && "$KEEPER_STOPPED" != "1" && -n "${MCP_URL:-}" ]]; then
    stop_keeper false false >/dev/null 2>&1 || true
  fi
  if [[ "$(normalize_bool "$KEEP_SERVER")" != "1" ]]; then
    harness_stop_server "$SERVER_PID" 10
  fi
  if [[ "$(normalize_bool "$KEEP_ARTIFACTS")" != "1" && -n "$TEMP_BASE_PATH" && -d "$TEMP_BASE_PATH" ]]; then
    rm -rf "$TEMP_BASE_PATH"
  fi
}

record_unexpected_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]:-unknown}"
  if [[ "$(normalize_bool "$DRY_RUN")" != "1" && ! -s "$RUN_DIR/phases.jsonl" ]]; then
    append_phase "harness" "fail" "unexpected harness error at line ${line_no} (exit=${exit_code})" "" "" || true
  fi
  return "$exit_code"
}
trap record_unexpected_error ERR
trap cleanup EXIT

finalize_report() {
  local classification="FAIL"
  local bootstrap_ok="$BOOTSTRAP_PASS"
  local liveness_ok="$LIVENESS_PASS"
  local continuity_ok="$CONTINUITY_PASS"
  local compaction_ok="$COMPACTION_PASS"
  local handoff_ok="$HANDOFF_PASS"
  local recovery_ok="$RECOVERY_PASS"
  if ! phase_enabled bootstrap; then bootstrap_ok=1; fi
  if ! phase_enabled liveness; then liveness_ok=1; fi
  if ! phase_enabled continuity; then continuity_ok=1; fi
  if ! phase_enabled compaction; then compaction_ok=1; fi
  if ! phase_enabled handoff; then handoff_ok=1; fi
  if ! phase_enabled recovery; then recovery_ok=1; fi

  if [[ "$(normalize_bool "$DRY_RUN")" == "1" ]]; then
    classification="DRY_RUN"
    VALIDATION_EXIT_CODE=2
  elif [[ $bootstrap_ok -eq 1 && $liveness_ok -eq 1 && $continuity_ok -eq 1 ]]; then
    if [[ $compaction_ok -eq 1 && $handoff_ok -eq 1 && $recovery_ok -eq 1 ]]; then
      classification="PASS"
      VALIDATION_EXIT_CODE=0
    else
      classification="PARTIAL"
      VALIDATION_EXIT_CODE=1
    fi
  else
    classification="FAIL"
    VALIDATION_EXIT_CODE=1
  fi

  local summary_json
  summary_json="$(jq -nc \
    --arg run_id "$RUN_ID" \
    --arg generated_at "$(iso_now)" \
    --arg classification "$classification" \
    --arg mcp_url "${MCP_URL:-}" \
    --arg server_log "$SERVER_LOG" \
    --arg base_path "${BASE_PATH:-$TEMP_BASE_PATH}" \
    --arg keeper_name "$KEEPER_NAME" \
    --arg cascade_name "$KEEPER_CASCADE_NAME" \
    --arg latest_input_preview "$LATEST_INPUT_PREVIEW" \
    --arg latest_output_preview "$LATEST_OUTPUT_PREVIEW" \
    --arg latest_trace_id "$LATEST_TRACE_ID" \
    --arg latest_generation "$LATEST_GENERATION" \
    --arg latest_compactions "$LATEST_COMPACTIONS" \
    --arg latest_handoffs "$LATEST_HANDOFFS" \
    --arg latest_health "$LATEST_HEALTH" \
    --arg latest_heartbeat "$LATEST_HEARTBEAT" \
    --arg target_phases "$TARGET_PHASES" \
    --argjson dry_run "$( [[ "$(normalize_bool "$DRY_RUN")" == "1" ]] && echo true || echo false )" \
    --argjson bootstrap_pass "$( [[ $BOOTSTRAP_PASS -eq 1 ]] && echo true || echo false )" \
    --argjson liveness_pass "$( [[ $LIVENESS_PASS -eq 1 ]] && echo true || echo false )" \
    --argjson continuity_pass "$( [[ $CONTINUITY_PASS -eq 1 ]] && echo true || echo false )" \
    --argjson compaction_pass "$( [[ $COMPACTION_PASS -eq 1 ]] && echo true || echo false )" \
    --argjson handoff_pass "$( [[ $HANDOFF_PASS -eq 1 ]] && echo true || echo false )" \
    --argjson recovery_pass "$( [[ $RECOVERY_PASS -eq 1 ]] && echo true || echo false )" \
    --argjson target_bootstrap "$( phase_enabled bootstrap && echo true || echo false )" \
    --argjson target_liveness "$( phase_enabled liveness && echo true || echo false )" \
    --argjson target_continuity "$( phase_enabled continuity && echo true || echo false )" \
    --argjson target_compaction "$( phase_enabled compaction && echo true || echo false )" \
    --argjson target_handoff "$( phase_enabled handoff && echo true || echo false )" \
    --argjson target_recovery "$( phase_enabled recovery && echo true || echo false )" \
    '{
      run_id:$run_id,
      generated_at:$generated_at,
      classification:$classification,
      dry_run:$dry_run,
      environment:{
        mcp_url:$mcp_url,
        base_path:$base_path,
        server_log:$server_log,
        keeper_name:$keeper_name,
        cascade_name:$cascade_name,
        target_phases:$target_phases
      },
      evidence:{
        latest_input_preview:$latest_input_preview,
        latest_output_preview:$latest_output_preview,
        latest_trace_id:$latest_trace_id,
        latest_generation:$latest_generation,
        latest_compactions:$latest_compactions,
        latest_handoffs:$latest_handoffs,
        latest_health:$latest_health,
        latest_heartbeat:$latest_heartbeat
      },
      phases:{
        bootstrap:{selected:$target_bootstrap,pass:$bootstrap_pass},
        liveness:{selected:$target_liveness,pass:$liveness_pass},
        continuity:{selected:$target_continuity,pass:$continuity_pass},
        compaction:{selected:$target_compaction,pass:$compaction_pass},
        handoff:{selected:$target_handoff,pass:$handoff_pass},
        recovery:{selected:$target_recovery,pass:$recovery_pass}
      },
      runtime_truth_proven: ($classification == "PASS" and ( $dry_run | not ))
    }')"
  write_json_pretty "$RUN_DIR/summary.json" "$summary_json"

  cat >"$RUN_DIR/summary.md" <<EOF
# Keeper Continuity Validation

- Run ID: \`$RUN_ID\`
- Classification: **$classification**
- Dry run: $( [[ "$(normalize_bool "$DRY_RUN")" == "1" ]] && echo "yes" || echo "no" )
- Keeper: \`$KEEPER_NAME\`
- Cascade: \`$KEEPER_CASCADE_NAME\`
- MCP URL: \`${MCP_URL:-n/a}\`

## Result

| Phase | Result |
|---|---|
| bootstrap | $(phase_report_string bootstrap "$BOOTSTRAP_PASS") |
| liveness | $(phase_report_string liveness "$LIVENESS_PASS") |
| continuity | $(phase_report_string continuity "$CONTINUITY_PASS") |
| compaction | $(phase_report_string compaction "$COMPACTION_PASS") |
| handoff | $(phase_report_string handoff "$HANDOFF_PASS") |
| recovery | $(phase_report_string recovery "$RECOVERY_PASS") |

## Evidence

- Latest health: \`$LATEST_HEALTH\`
- Latest liveness signal: \`$LATEST_HEARTBEAT\`
- Latest trace: \`$LATEST_TRACE_ID\`
- Generation: \`$LATEST_GENERATION\`
- Compactions: \`$LATEST_COMPACTIONS\`
- Handoffs: \`$LATEST_HANDOFFS\`
- Recent input preview: $LATEST_INPUT_PREVIEW
- Recent output preview: $LATEST_OUTPUT_PREVIEW

## Interpretation
EOF

  if [[ "$(normalize_bool "$DRY_RUN")" == "1" ]]; then
    cat >>"$RUN_DIR/summary.md" <<'EOF'
- **PASS**: synthetic dry-run phases succeeded. This proves the harness and reporting contract only.
- **PARTIAL**: not used in dry-run mode.
- **FAIL**: dry-run harness plumbing did not complete.
EOF
  else
    cat >>"$RUN_DIR/summary.md" <<'EOF'
- **PASS**: real live keeper continuity proven. Heartbeat, live turns, continuity updates, compaction, handoff, and restart recovery all produced runtime evidence.
- **PARTIAL**: keeper was live and continuity updated, but one or more lifecycle transitions did not happen within the validation window.
- **FAIL**: only stale metadata or heuristic summaries were observed; a live continuity lifecycle was not proven.
EOF
  fi

  cat >>"$RUN_DIR/summary.md" <<EOF

## Artifacts

- Summary JSON: \`$RUN_DIR/summary.json\`
- Phase log: \`$RUN_DIR/phases.jsonl\`
- Snapshots: \`$SNAP_DIR\`
- Server log: \`$SERVER_LOG\`
EOF

  if [[ "$(normalize_bool "$DRY_RUN")" == "1" ]]; then
    cat >>"$RUN_DIR/summary.md" <<'EOF'

## Dry-run caveat

This run validated harness plumbing and report generation only.
It does **not** prove runtime truth, live heartbeat behavior, or real keeper continuity.
EOF
  fi

  local manifest_json
  manifest_json="$(jq -nc \
    --arg run_id "$RUN_ID" \
    --arg run_dir "$RUN_DIR" \
    --arg summary_json "$RUN_DIR/summary.json" \
    --arg summary_md "$RUN_DIR/summary.md" \
    --arg phases "$RUN_DIR/phases.jsonl" \
    --arg snapshots "$SNAP_DIR" \
    --arg raw "$RAW_DIR" \
    '{run_id:$run_id,run_dir:$run_dir,summary_json:$summary_json,summary_md:$summary_md,phases:$phases,snapshots:$snapshots,raw:$raw}')"
  write_json_pretty "$RUN_DIR/manifest.json" "$manifest_json"
}

real_run() {
  local status_json heartbeat_output snapshot_info snapshot_file heartbeat_file room_file
  local baseline_continuity_ts baseline_compactions baseline_generation baseline_handoffs baseline_trace
  local turn status_after heartbeat_after agent_name compaction_done handoff_done

  require_cmd jq || { echo "jq is required" >&2; return 1; }
  require_cmd curl || { echo "curl is required" >&2; return 1; }
  require_cmd python3 || { echo "python3 is required" >&2; return 1; }

  if [[ "$(normalize_bool "$START_SERVER")" == "1" ]]; then
    TEMP_BASE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/keeper-continuity.${RUN_ID}.XXXXXX")"
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
    load_mcp_token 1
  elif [[ -z "$MCP_URL" ]]; then
    echo "MCP_URL is required when START_SERVER=0" >&2
    return 1
  else
    load_mcp_token 0
  fi
  if ! init_mcp_session; then
    append_phase "bootstrap" "fail" "MCP initialize failed: $LAST_TOOL_ERROR" "" ""
    return 1
  fi

  if ! create_keeper; then
    append_phase "bootstrap" "fail" "keeper creation failed: $LAST_TOOL_ERROR" "" ""
    return 1
  fi
  KEEPER_CREATED=1
  if ! wait_for_bootstrap; then
    snapshot_info="$(capture_snapshot bootstrap)"
    snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "bootstrap" "fail" "keepalive/heartbeat did not appear in time" "$snapshot_file" "$heartbeat_file"
    return 1
  fi
  if phase_enabled bootstrap; then
    snapshot_info="$(capture_snapshot bootstrap)"
    snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    status_json="$(cat "$snapshot_file")"
    refresh_latest_evidence_from_status "$status_json"
    heartbeat_output="$(cat "$heartbeat_file")"
    agent_name="$(printf '%s' "$status_json" | jq -r '.meta.agent_name')"
    if [[ "$(printf '%s' "$status_json" | jq -r '.keepalive_running')" == "true" ]] \
      && [[ "$(printf '%s' "$status_json" | jq -r '.agent.exists')" == "true" ]]; then
      BOOTSTRAP_PASS=1
      append_phase "bootstrap" "pass" "isolated keeper started with active keepalive and room presence" "$snapshot_file" "$heartbeat_file"
    else
      append_phase "bootstrap" "fail" "keeper started but room presence/keepalive were not observed" "$snapshot_file" "$heartbeat_file"
      return 1
    fi
  fi

  if phase_enabled liveness; then
    local baseline_turns
    status_json="$(keeper_status_json)"
    baseline_turns="$(printf '%s' "$status_json" | jq -r '(.meta.total_turns | tonumber?) // 0')"
    if ! send_keeper_message 1200 "$(short_prompt liveness)"; then
      snapshot_info="$(capture_snapshot liveness)"
      snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
      heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
      append_phase "liveness" "fail" "keeper turn failed: $LAST_TOOL_ERROR" "$snapshot_file" "$heartbeat_file"
      return 1
    fi
	    if ! wait_for_keeper_status_condition "((.meta.total_turns | tonumber?) // 0) > $baseline_turns" "$((TURN_TIMEOUT_SEC + 30))" >/dev/null; then
	      snapshot_info="$(capture_snapshot liveness)"
	      snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
	      heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
	      status_json="$(cat "$snapshot_file")"
	      runtime_summary="$(runtime_terminal_summary "$status_json" "$((baseline_turns + 1))")"
	      if [[ -n "$runtime_summary" ]]; then
	        append_phase "liveness" "fail" "keeper message was queued but no completed turn was observed before timeout; $runtime_summary" "$snapshot_file" "$heartbeat_file"
	      else
	        append_phase "liveness" "fail" "keeper message was queued but no completed turn was observed before timeout" "$snapshot_file" "$heartbeat_file"
	      fi
	      return 1
	    fi
    snapshot_info="$(capture_snapshot liveness)"
    snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    status_json="$(cat "$snapshot_file")"
    refresh_latest_evidence_from_status "$status_json"
    heartbeat_output="$(cat "$heartbeat_file")"
    agent_name="$(printf '%s' "$status_json" | jq -r '.meta.agent_name')"
    if [[ "$(printf '%s' "$status_json" | jq -r '.agent.exists')" == "true" ]] \
      && [[ "$(printf '%s' "$status_json" | jq -r "(((.meta.total_turns | tonumber?) // 0) > ($baseline_turns | tonumber))")" == "true" ]] \
      && [[ "$(printf '%s' "$status_json" | jq -r '.last_turn_ago_s < 120')" == "true" ]] \
      && [[ "$(printf '%s' "$status_json" | jq -r '.keepalive_running')" == "true" ]]; then
      LIVENESS_PASS=1
      append_phase "liveness" "pass" "live keeper turn observed with room presence and recent output" "$snapshot_file" "$heartbeat_file"
    else
      append_phase "liveness" "fail" "keeper metadata exists but no fresh live turn was proven" "$snapshot_file" "$heartbeat_file"
      return 1
    fi
  fi

  snapshot_info="$(capture_snapshot baseline)"
  snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
  status_json="$(cat "$snapshot_file")"
  baseline_continuity_ts="$(printf '%s' "$status_json" | jq -r '(.meta.last_continuity_update_ts | tonumber?) // 0')"
  baseline_compactions="$(printf '%s' "$status_json" | jq -r '(.compaction_count | tonumber?) // 0')"
  baseline_generation="$(printf '%s' "$status_json" | jq -r '(.generation | tonumber?) // 0')"
  baseline_handoffs="$(printf '%s' "$status_json" | jq -r '(.handoff_count_total | tonumber?) // 0')"
  baseline_trace="$(printf '%s' "$status_json" | jq -r '.meta.trace_id')"
  compaction_done=0
  handoff_done=0

  if phase_enabled continuity; then
    local continuity_baseline_turns
    status_json="$(keeper_status_json)"
    continuity_baseline_turns="$(printf '%s' "$status_json" | jq -r '(.meta.total_turns | tonumber?) // 0')"
    if ! send_keeper_message 1300 "$(pressure_prompt 1)"; then
      snapshot_info="$(capture_snapshot continuity)"
      snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
      heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
      append_phase "continuity" "fail" "continuity turn failed: $LAST_TOOL_ERROR" "$snapshot_file" "$heartbeat_file"
      return 1
    fi
	    if ! wait_for_keeper_status_condition "(((.meta.total_turns | tonumber?) // 0) > $continuity_baseline_turns) and ((((.meta.last_continuity_update_ts | tonumber?) // 0) > (($baseline_continuity_ts | tonumber))) and (((.continuity_summary // \"\") | length) > 0))" "$((TURN_TIMEOUT_SEC + 30))" >/dev/null; then
	      snapshot_info="$(capture_snapshot continuity)"
	      snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
	      heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
	      status_json="$(cat "$snapshot_file")"
	      runtime_summary="$(runtime_terminal_summary "$status_json" "$((continuity_baseline_turns + 1))")"
	      if [[ -n "$runtime_summary" ]]; then
	        append_phase "continuity" "fail" "keeper message was queued but continuity did not update before timeout; $runtime_summary" "$snapshot_file" "$heartbeat_file"
	      else
	        append_phase "continuity" "fail" "keeper message was queued but continuity did not update before timeout" "$snapshot_file" "$heartbeat_file"
	      fi
	      return 1
	    fi
    snapshot_info="$(capture_snapshot continuity)"
    snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    status_json="$(cat "$snapshot_file")"
    refresh_latest_evidence_from_status "$status_json"
    if [[ "$(printf '%s' "$status_json" | jq -r '(((.meta.last_continuity_update_ts | tonumber?) // 0) > (($old | tonumber?) // 0))' --arg old "$baseline_continuity_ts")" == "true" ]] \
      && [[ "$(printf '%s' "$status_json" | jq -r '(.continuity_summary // "") | length > 0')" == "true" ]]; then
      CONTINUITY_PASS=1
      append_phase "continuity" "pass" "continuity summary and timestamp advanced after a real turn" "$snapshot_file" "$heartbeat_file"
      baseline_continuity_ts="$(printf '%s' "$status_json" | jq -r '(.meta.last_continuity_update_ts | tonumber?) // 0')"
    else
      append_phase "continuity" "fail" "continuity summary did not advance after a real turn" "$snapshot_file" "$heartbeat_file"
      return 1
    fi
  fi

  for turn in $(seq 2 "$MAX_TURNS"); do
    if ! phase_enabled compaction && ! phase_enabled handoff; then
      break
    fi
    if ! send_keeper_message "$((1400 + turn))" "$(pressure_prompt "$turn")"; then
      break
    fi
    sleep "$PRESSURE_PAUSE_SEC"
    snapshot_info="$(capture_snapshot "pressure-${turn}")"
    snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    status_after="$(cat "$snapshot_file")"
    refresh_latest_evidence_from_status "$status_after"

    if [[ $compaction_done -eq 0 ]] \
      && [[ "$(printf '%s' "$status_after" | jq -r '(((.compaction_count | tonumber?) // 0) > (($old | tonumber?) // 0))' --arg old "$baseline_compactions")" == "true" ]]; then
      COMPACTION_PASS=1
      compaction_done=1
      append_phase "compaction" "pass" "compaction counter increased under isolated pressure" "$snapshot_file" "$heartbeat_file"
      baseline_compactions="$(printf '%s' "$status_after" | jq -r '(.compaction_count | tonumber?) // 0')"
    fi

    if [[ $handoff_done -eq 0 ]] \
      && { [[ "$(printf '%s' "$status_after" | jq -r '(((.generation | tonumber?) // 0) > (($old | tonumber?) // 0))' --arg old "$baseline_generation")" == "true" ]] \
        || [[ "$(printf '%s' "$status_after" | jq -r '(((.handoff_count_total | tonumber?) // 0) > (($old | tonumber?) // 0))' --arg old "$baseline_handoffs")" == "true" ]] \
        || [[ "$(printf '%s' "$status_after" | jq -r '.meta.trace_id != $old' --arg old "$baseline_trace")" == "true" ]]; }; then
      HANDOFF_PASS=1
      handoff_done=1
      append_phase "handoff" "pass" "handoff/generation evidence changed under isolated pressure" "$snapshot_file" "$heartbeat_file"
      baseline_generation="$(printf '%s' "$status_after" | jq -r '(.generation | tonumber?) // 0')"
      baseline_handoffs="$(printf '%s' "$status_after" | jq -r '(.handoff_count_total | tonumber?) // 0')"
      baseline_trace="$(printf '%s' "$status_after" | jq -r '.meta.trace_id')"
    fi

    if [[ $compaction_done -eq 1 && $handoff_done -eq 1 ]]; then
      break
    fi
  done

  if phase_enabled compaction && [[ $COMPACTION_PASS -eq 0 ]]; then
    snapshot_info="$(capture_snapshot compaction-miss)"
    snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "compaction" "fail" "compaction evidence did not appear within the validation window" "$snapshot_file" "$heartbeat_file"
  fi

  if phase_enabled handoff && [[ $HANDOFF_PASS -eq 0 ]]; then
    snapshot_info="$(capture_snapshot handoff-miss)"
    snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
    heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
    append_phase "handoff" "fail" "handoff evidence did not appear within the validation window" "$snapshot_file" "$heartbeat_file"
  fi

  if phase_enabled recovery; then
    status_json="$(keeper_status_json)"
    agent_name="$(printf '%s' "$status_json" | jq -r '.meta.agent_name')"
    LATEST_TRACE_ID="$(printf '%s' "$status_json" | jq -r '.meta.trace_id')"
    LATEST_GENERATION="$(printf '%s' "$status_json" | jq -r '.generation')"
    if ! stop_keeper false false; then
      snapshot_info="$(capture_snapshot recovery-down)"
      snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
      heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
      append_phase "recovery" "fail" "keeper_down failed: $LAST_TOOL_ERROR" "$snapshot_file" "$heartbeat_file"
    else
      sleep 1
      if ! call_mcp_tool 1500 "masc_keeper_up" "$(jq -cn --arg name "$KEEPER_NAME" --arg cascade_name "$KEEPER_CASCADE_NAME" '{name:$name} + (if ($cascade_name | length) > 0 then {cascade_name:$cascade_name} else {} end)')" 30; then
        snapshot_info="$(capture_snapshot recovery-up)"
        snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
        heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
        append_phase "recovery" "fail" "keeper_up restart failed: $LAST_TOOL_ERROR" "$snapshot_file" "$heartbeat_file"
      else
        KEEPER_STOPPED=0
        if ! wait_for_restarted_heartbeat "$agent_name"; then
          snapshot_info="$(capture_snapshot recovery-restart)"
          snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
          heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
          append_phase "recovery" "fail" "heartbeat did not return after keeper restart" "$snapshot_file" "$heartbeat_file"
        elif ! send_keeper_message 1501 "$(short_prompt recovery)"; then
          snapshot_info="$(capture_snapshot recovery-turn)"
          snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
          heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
          append_phase "recovery" "fail" "keeper did not accept a post-restart turn: $LAST_TOOL_ERROR" "$snapshot_file" "$heartbeat_file"
        else
          sleep "$PRESSURE_PAUSE_SEC"
          snapshot_info="$(capture_snapshot recovery)"
          snapshot_file="$(printf '%s' "$snapshot_info" | sed -n '1p')"
          heartbeat_file="$(printf '%s' "$snapshot_info" | sed -n '2p')"
          status_after="$(cat "$snapshot_file")"
          refresh_latest_evidence_from_status "$status_after"
          if [[ "$(printf '%s' "$status_after" | jq -r '.keepalive_running')" == "true" ]] \
            && [[ "$(printf '%s' "$status_after" | jq -r '.last_turn_ago_s < 120')" == "true" ]] \
            && [[ "$(printf '%s' "$status_after" | jq -r '(.continuity_summary // "") | length > 0')" == "true" ]] \
            && [[ "$(printf '%s' "$status_after" | jq -r '.agent.exists')" == "true" ]]; then
            # OAS #467 regression guard: verify checkpoint messages > 0
            recovery_trace_id="$(printf '%s' "$status_after" | jq -r '.meta.trace_id // empty')"
            if [[ -z "$recovery_trace_id" ]]; then
              append_phase "checkpoint_truth" "skip" "trace_id missing from status — cannot locate checkpoint" "$snapshot_file" "$heartbeat_file"
            else
              ckpt_dir="${BASE_PATH}/.masc/keepers/${KEEPER_NAME}/${recovery_trace_id}"
              ckpt_file="${ckpt_dir}/${recovery_trace_id}.json"
              if [[ -f "$ckpt_file" ]]; then
                if ckpt_msg_count="$(jq '.messages | length' "$ckpt_file")"; then
                  if [[ "$ckpt_msg_count" -gt 0 ]]; then
                    append_phase "checkpoint_truth" "pass" "load_oas checkpoint contains ${ckpt_msg_count} messages (OAS #467 regression guard)" "$snapshot_file" "$heartbeat_file"
                  else
                    append_phase "checkpoint_truth" "fail" "load_oas checkpoint has 0 messages — OAS #467 regression" "$snapshot_file" "$heartbeat_file"
                  fi
                else
                  append_phase "checkpoint_truth" "error" "checkpoint JSON parse failed at ${ckpt_file} — possible file corruption" "$snapshot_file" "$heartbeat_file"
                fi
              else
                append_phase "checkpoint_truth" "skip" "checkpoint file not found at ${ckpt_file}" "$snapshot_file" "$heartbeat_file"
              fi
            fi
            RECOVERY_PASS=1
            append_phase "recovery" "pass" "keeper restarted on the same name and resumed live turns with continuity intact" "$snapshot_file" "$heartbeat_file"
          else
            append_phase "recovery" "fail" "keeper restarted but continuity/liveness did not fully recover" "$snapshot_file" "$heartbeat_file"
          fi
        fi
      fi
    fi
  fi

  status_json="$(keeper_status_json)"
  refresh_latest_evidence_from_status "$status_json"
}

main() {
  if [[ "$(normalize_bool "$DRY_RUN")" == "1" ]]; then
    run_dry_run
    finalize_report
    exit 0
  fi

  if real_run; then
    finalize_report
    exit "$VALIDATION_EXIT_CODE"
  else
    finalize_report
    exit 1
  fi
}

main "$@"
