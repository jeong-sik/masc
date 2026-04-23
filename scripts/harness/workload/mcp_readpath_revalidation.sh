#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/harness/lib/mcp_jsonrpc.sh"
source "$REPO_ROOT/scripts/harness/lib/server_bootstrap.sh"

RUN_ID="${RUN_ID:-mcp-readpath-$(date +%Y%m%d_%H%M%S)-$$}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/mcp_readpath_revalidation/$RUN_ID}"
SUMMARY_JSON="$RUN_DIR/summary.json"
MODES="${MODES:-http_only,default}"
BASE_PATH="${BASE_PATH:-$REPO_ROOT}"
START_SERVER="${START_SERVER:-1}"
TARGET_BASE_URL="${TARGET_BASE_URL:-}"
TARGET_MCP_URL="${TARGET_MCP_URL:-}"
SERVER_EXE_INPUT="${SERVER_EXE:-}"
SERVER_WAIT_SEC="${SERVER_WAIT_SEC:-45}"
CACHE_READY_TIMEOUT_SEC="${CACHE_READY_TIMEOUT_SEC:-45}"
TOOL_TIMEOUT_SEC="${TOOL_TIMEOUT_SEC:-35}"
EXPECT_KEEPERS="${EXPECT_KEEPERS:-1}"
KEEP_SERVER="${KEEP_SERVER:-0}"
EXPECT_HEALTH_MODE="${EXPECT_HEALTH_MODE:-auto}"
KEEPER_STATUS_SAMPLE_LIMIT="${KEEPER_STATUS_SAMPLE_LIMIT:-3}"

MASC_STATUS_FIRST_MAX_SEC="${MASC_STATUS_FIRST_MAX_SEC:-5}"
MASC_STATUS_SECOND_MAX_SEC="${MASC_STATUS_SECOND_MAX_SEC:-1.5}"
MASC_KEEPER_LIST_FIRST_MAX_SEC="${MASC_KEEPER_LIST_FIRST_MAX_SEC:-5}"
MASC_KEEPER_LIST_SECOND_MAX_SEC="${MASC_KEEPER_LIST_SECOND_MAX_SEC:-1.5}"
MASC_TRANSPORT_STATUS_MAX_SEC="${MASC_TRANSPORT_STATUS_MAX_SEC:-2}"
DASHBOARD_EXECUTION_MAX_SEC="${DASHBOARD_EXECUTION_MAX_SEC:-2}"
TRANSPORT_HEALTH_MAX_SEC="${TRANSPORT_HEALTH_MAX_SEC:-2}"

SERVER_EXE="$(harness_find_server_exe "$REPO_ROOT" "$SERVER_EXE_INPUT")"
mkdir -p "$RUN_DIR"

LAST_RESPONSE=""
LAST_TEXT=""
LAST_TIME_TOTAL=""
LAST_ERROR=""

log() {
  printf '[mcp-readpath-revalidation] %s\n' "$*" >&2
}

normalize_bool() {
  case "$(printf '%s' "${1:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) printf '1' ;;
    *) printf '0' ;;
  esac
}

health_mode_enforced() {
  local expect="${1:-auto}"
  case "$(printf '%s' "$expect" | tr '[:upper:]' '[:lower:]')" in
    auto)
      if [[ "$(normalize_bool "$START_SERVER")" = "1" ]]; then
        printf '1\n'
      else
        printf '0\n'
      fi
      ;;
    1|true|yes|y|on)
      printf '1\n'
      ;;
    *)
      printf '0\n'
      ;;
  esac
}

float_le() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0.0) <= (b + 0.0)) }'
}

pick_port() {
  local port
  port="$(harness_pick_free_port 2>/dev/null || true)"
  if [[ -n "$port" ]]; then
    printf '%s\n' "$port"
    return 0
  fi

  local base="${PORT_FALLBACK_BASE:-18000}"
  local span="${PORT_FALLBACK_SPAN:-2000}"
  local attempt candidate
  for attempt in $(seq 0 49); do
    candidate="$((base + (( $$ + attempt * 37 ) % span) ))"
    if ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "failed to allocate port" >&2
  return 1
}

json_from_response_text() {
  printf '%s' "$1" | jq -c '.'
}

append_result() {
  local mode="$1"
  local result_json="$2"
  local mode_file="$RUN_DIR/${mode}.json"
  printf '%s\n' "$result_json" >"$mode_file"
}

start_mode_server() {
  local mode="$1"
  local port="$2"
  local grpc_port="$3"
  local ws_port="$4"
  local log_file="$5"

  local grpc_enabled="0"
  local ws_enabled="1"
  local webrtc_enabled="1"
  case "$mode" in
    http_only)
      ws_enabled="0"
      webrtc_enabled="0"
      ;;
    default)
      ;;
    *)
      echo "unknown mode: $mode" >&2
      return 1
      ;;
  esac

  (
    export MASC_DASHBOARD_BRIEFING_MODELS="disabled"
    export MASC_GRPC_ENABLED="$grpc_enabled"
    export MASC_GRPC_PORT="$grpc_port"
    export MASC_WS_ENABLED="$ws_enabled"
    export MASC_WS_PORT="$ws_port"
    export MASC_WEBRTC_ENABLED="$webrtc_enabled"
    exec "$SERVER_EXE" --host=127.0.0.1 --port "$port" --base-path "$BASE_PATH"
  ) >"$log_file" 2>&1 &
  printf '%s\n' "$!"
}

wait_for_cache_ready() {
  local url="$1"
  local timeout_sec="$2"
  local deadline=$(( $(date +%s) + timeout_sec ))
  local body cache_state
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if body="$(curl -fsS --max-time 3 "$url" 2>/dev/null)"; then
      cache_state="$(printf '%s' "$body" | jq -r '.projection_diagnostics.cache_state // ""' 2>/dev/null || true)"
      if [[ -z "$cache_state" || "$cache_state" != "initializing" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

init_session() {
  local mcp_url="$1"
  local headers_file body_file session_id protocol_version
  headers_file="$(harness_mktemp_file mcp-init .headers)"
  body_file="$(harness_mktemp_file mcp-init .body)"
  if ! curl -sS --max-time "$TOOL_TIMEOUT_SEC" -D "$headers_file" -o "$body_file" \
    -X POST "$mcp_url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"mcp-readpath-revalidation","version":"1.0"},"capabilities":{}}}' >/dev/null; then
    rm -f "$headers_file" "$body_file"
    return 1
  fi
  session_id="$(awk '
    tolower($0) ~ /^mcp-session-id:/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/\r$/, "", $0)
      print $0
      exit
    }' "$headers_file")"
  protocol_version="$(awk '
    tolower($0) ~ /^mcp-protocol-version:/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/\r$/, "", $0)
      print $0
      exit
    }' "$headers_file")"
  rm -f "$headers_file" "$body_file"
  if [[ -z "$session_id" ]]; then
    return 1
  fi
  printf '%s\t%s\n' "$session_id" "$protocol_version"
}

call_tool() {
  local mcp_url="$1"
  local session_id="$2"
  local protocol_version="$3"
  local request_id="$4"
  local tool_name="$5"
  local args_json="$6"

  local saved_timeout="${HTTP_TIMEOUT_SEC:-}" saved_proto="${MCP_PROTOCOL_VERSION:-}"
  HTTP_TIMEOUT_SEC="$TOOL_TIMEOUT_SEC"
  MCP_PROTOCOL_VERSION="$protocol_version"
  local response
  response="$(mcp_call_tool "$request_id" "$tool_name" "$args_json" "$session_id" "" "$mcp_url")"
  HTTP_TIMEOUT_SEC="$saved_timeout"
  MCP_PROTOCOL_VERSION="$saved_proto"

  LAST_TIME_TOTAL="$MCP_LAST_TIME_TOTAL"
  LAST_RESPONSE="$response"

  if printf '%s' "$response" | jq -e '._harness_error? != null' >/dev/null 2>&1; then
    LAST_TEXT=""
    LAST_ERROR="$(printf '%s' "$response" | jq -r '._harness_error.message // "transport error"')"
    return 1
  fi

  LAST_TEXT="$(printf '%s' "$response" | jq -r '[.result.content[]? | select(.type == "text") | .text] | join("\n")' 2>/dev/null || true)"
  LAST_ERROR="$(printf '%s' "$response" | jq -r '
    if .error?.message then .error.message
    elif (.result?.isError // false) == true then
      ([.result.content[]? | select(.type == "text") | .text] | join(" "))
    else "" end
  ' 2>/dev/null || true)"
  [[ -z "$LAST_ERROR" ]]
}

call_json_endpoint() {
  local url="$1"
  local body_file
  body_file="$(harness_mktemp_file endpoint .json)"
  LAST_TIME_TOTAL="$(
    curl -sS --max-time "$TOOL_TIMEOUT_SEC" -o "$body_file" -w '%{time_total}' "$url"
  )"
  LAST_RESPONSE="$(cat "$body_file")"
  LAST_TEXT="$LAST_RESPONSE"
  LAST_ERROR=""
  rm -f "$body_file"
}

check_tool_time() {
  local name="$1"
  local actual="$2"
  local max="$3"
  if ! float_le "$actual" "$max"; then
    echo "$name exceeded threshold: ${actual}s > ${max}s" >&2
    return 1
  fi
}

run_mode() {
  local mode="$1"
  local port grpc_port ws_port server_log server_pid
  local base_url mcp_url health_json health_file
  local session_line session_id protocol_version
  local status_first_time status_second_time keeper_first_time keeper_second_time keeper_status_time transport_time
  local execution_time transport_health_time
  local status_first_ok status_second_ok keeper_first_ok keeper_second_ok keeper_status_ok transport_ok
  local execution_cache_state transport_cache_state
  local keeper_json keeper_status_json keeper_name transport_json execution_json
  local payload_contract_ok quiet_reason_contract_ok pending_lazy_ok health_mode_ok keeper_fiber_ok
  local health_mode_check_enabled keeper_status_attempted_json
  local keeper_candidate request_id keeper_status_attempt_count
  local result_pass="true"
  local -a keeper_names=()

  if [[ "$(normalize_bool "$START_SERVER")" = "1" ]]; then
    port="$(pick_port)"
    grpc_port="$(pick_port)"
    ws_port="$(pick_port)"
    server_log="$RUN_DIR/${mode}.server.log"
    base_url="http://127.0.0.1:${port}"
    mcp_url="${base_url}/mcp"

    log "mode=${mode} starting server on port=${port}"
    server_pid="$(start_mode_server "$mode" "$port" "$grpc_port" "$ws_port" "$server_log")"

    if ! harness_wait_for_health "$port" "$SERVER_WAIT_SEC"; then
      log "mode=${mode} health wait failed"
      harness_print_log_tail "$server_log" 120
      harness_stop_server "$server_pid"
      return 1
    fi
  else
    if [[ -z "$TARGET_BASE_URL" ]]; then
      echo "TARGET_BASE_URL is required when START_SERVER=0" >&2
      return 1
    fi
    base_url="$TARGET_BASE_URL"
    mcp_url="${TARGET_MCP_URL:-${base_url%/}/mcp}"
    server_log=""
    port="${base_url##*:}"
    if ! curl -fsS --max-time 3 "${base_url%/}/health" >/dev/null 2>&1; then
      echo "external server not healthy at ${base_url%/}/health" >&2
      return 1
    fi
  fi

  if ! wait_for_cache_ready "${base_url}/api/v1/dashboard/transport-health" "$CACHE_READY_TIMEOUT_SEC"; then
    log "mode=${mode} transport-health cache did not warm"
    result_pass="false"
  fi
  if ! wait_for_cache_ready "${base_url}/api/v1/dashboard/execution" "$CACHE_READY_TIMEOUT_SEC"; then
    log "mode=${mode} execution cache did not warm"
    result_pass="false"
  fi

  health_file="$(harness_mktemp_file health .json)"
  curl -sS --max-time 5 "${base_url}/health" >"$health_file"
  health_json="$(cat "$health_file")"
  rm -f "$health_file"

  session_line="$(init_session "$mcp_url")"
  session_id="${session_line%%$'\t'*}"
  protocol_version="${session_line#*$'\t'}"
  if [[ "$protocol_version" = "$session_line" ]]; then
    protocol_version=""
  fi

  if call_tool "$mcp_url" "$session_id" "$protocol_version" 11 "masc_status" '{}'; then
    status_first_ok="0"
  else
    status_first_ok="1"
  fi
  status_first_time="$LAST_TIME_TOTAL"

  if call_tool "$mcp_url" "$session_id" "$protocol_version" 12 "masc_status" '{}'; then
    status_second_ok="0"
  else
    status_second_ok="1"
  fi
  status_second_time="$LAST_TIME_TOTAL"

  if call_tool "$mcp_url" "$session_id" "$protocol_version" 13 "masc_keeper_list" '{"detailed":false}'; then
    keeper_first_ok="0"
  else
    keeper_first_ok="1"
  fi
  keeper_first_time="$LAST_TIME_TOTAL"
  keeper_json="$(json_from_response_text "$LAST_TEXT")"

  if call_tool "$mcp_url" "$session_id" "$protocol_version" 14 "masc_keeper_list" '{"detailed":false}'; then
    keeper_second_ok="0"
  else
    keeper_second_ok="1"
  fi
  keeper_second_time="$LAST_TIME_TOTAL"
  mapfile -t keeper_names < <(printf '%s' "$keeper_json" | jq -r '.keepers[]?' 2>/dev/null || true)
  keeper_name=""
  keeper_status_attempted_json='[]'

  if [[ "$(normalize_bool "$EXPECT_KEEPERS")" = "1" ]]; then
    if [[ "${#keeper_names[@]}" -gt 0 ]]; then
      request_id=15
      keeper_status_attempt_count=0
      for keeper_candidate in "${keeper_names[@]}"; do
        if (( keeper_status_attempt_count >= KEEPER_STATUS_SAMPLE_LIMIT )); then
          break
        fi
        keeper_status_attempt_count=$((keeper_status_attempt_count + 1))
        keeper_status_attempted_json="$(
          printf '%s' "$keeper_status_attempted_json" \
            | jq -c --arg name "$keeper_candidate" '. + [$name]'
        )"
        if call_tool "$mcp_url" "$session_id" "$protocol_version" "$request_id" "masc_keeper_status" "$(jq -cn --arg name "$keeper_candidate" '{name:$name}')"; then
          keeper_name="$keeper_candidate"
          keeper_status_ok="0"
          keeper_status_time="$LAST_TIME_TOTAL"
          keeper_status_json="$(json_from_response_text "$LAST_TEXT")"
          break
        fi
        request_id=$((request_id + 1))
      done
    fi

    if [[ -n "$keeper_name" ]]; then
      :
    elif [[ "${#keeper_names[@]}" -gt 0 ]]; then
      keeper_status_ok="1"
      keeper_status_time="$LAST_TIME_TOTAL"
      keeper_status_json='{}'
    else
      keeper_status_ok="1"
      keeper_status_time="0"
      keeper_status_json='{}'
    fi
  else
    keeper_status_ok="0"
    keeper_status_time="0"
    keeper_status_json='{}'
  fi

  if call_tool "$mcp_url" "$session_id" "$protocol_version" 16 "masc_transport_status" '{}'; then
    transport_ok="0"
  else
    transport_ok="1"
  fi
  transport_time="$LAST_TIME_TOTAL"
  transport_json="$(json_from_response_text "$LAST_TEXT")"

  call_json_endpoint "${base_url}/api/v1/dashboard/execution"
  execution_time="$LAST_TIME_TOTAL"
  execution_json="$LAST_RESPONSE"
  execution_cache_state="$(printf '%s' "$execution_json" | jq -r '.projection_diagnostics.cache_state // ""')"

  call_json_endpoint "${base_url}/api/v1/dashboard/transport-health"
  transport_health_time="$LAST_TIME_TOTAL"
  transport_cache_state="$(printf '%s' "$LAST_RESPONSE" | jq -r '.projection_diagnostics.cache_state // ""')"

  payload_contract_ok="$(printf '%s' "$keeper_status_json" | jq -r --arg expect "$EXPECT_KEEPERS" '
    if $expect != "1" then
      "true"
    elif (.name // "") == "" then
      "false"
    else
      (
        ((.coordination.joined_room_ids // null) | type == "array")
        and ((.runtime.proactive_enabled // null) | type == "boolean")
      ) | tostring
    end
  ')"

  quiet_reason_contract_ok="$(printf '%s' "$execution_json" | jq -r --arg expect "$EXPECT_KEEPERS" '
    if $expect != "1" then
      "true"
    elif ((.keepers // []) | length) == 0 then
      "false"
    else
      [(.keepers // [])[] |
        if (.keepalive_running == false and .proactive_enabled == true) then
          (.diagnostic | type == "object")
          and (.diagnostic.quiet_reason != "disabled")
          and (.diagnostic.continuity_state != "desired_offline")
        else
          true
        end
      ] | all | tostring
    end
  ')"

  pending_lazy_ok="$(printf '%s' "$health_json" | jq -r '((.startup.pending_lazy_tasks // []) | length == 0) | tostring')"
  keeper_fiber_ok="$(printf '%s' "$health_json" | jq -r --arg expect "$EXPECT_KEEPERS" '
    if $expect == "1" then
      ((.keeper_fibers // 0) > 0) | tostring
    else
      "true"
    end
  ')"

  health_mode_check_enabled="$(health_mode_enforced "$EXPECT_HEALTH_MODE")"
  if [[ "$health_mode_check_enabled" = "1" ]]; then
    health_mode_ok="$(printf '%s' "$health_json" | jq -r --arg mode "$mode" '
      if $mode == "http_only" then
        ((.transport.grpc.enabled == false)
          and (.transport.websocket.enabled == false)
          and (.transport.webrtc.enabled == false)) | tostring
      else
        ((.transport.grpc.enabled == false)
          and (.transport.websocket.enabled == true)
          and (.transport.websocket.listening == true)
          and (.transport.webrtc.enabled == true)) | tostring
      end
    ')"
  else
    health_mode_ok="true"
  fi

  if [[ "$status_first_ok" != "0" || "$status_second_ok" != "0" || "$keeper_first_ok" != "0" || "$keeper_second_ok" != "0" || "$keeper_status_ok" != "0" || "$transport_ok" != "0" ]]; then
    result_pass="false"
  fi
  check_tool_time "masc_status(first)" "$status_first_time" "$MASC_STATUS_FIRST_MAX_SEC" || result_pass="false"
  check_tool_time "masc_status(second)" "$status_second_time" "$MASC_STATUS_SECOND_MAX_SEC" || result_pass="false"
  check_tool_time "masc_keeper_list(first)" "$keeper_first_time" "$MASC_KEEPER_LIST_FIRST_MAX_SEC" || result_pass="false"
  check_tool_time "masc_keeper_list(second)" "$keeper_second_time" "$MASC_KEEPER_LIST_SECOND_MAX_SEC" || result_pass="false"
  check_tool_time "masc_transport_status" "$transport_time" "$MASC_TRANSPORT_STATUS_MAX_SEC" || result_pass="false"
  check_tool_time "dashboard/execution" "$execution_time" "$DASHBOARD_EXECUTION_MAX_SEC" || result_pass="false"
  check_tool_time "dashboard/transport-health" "$transport_health_time" "$TRANSPORT_HEALTH_MAX_SEC" || result_pass="false"

  [[ "$payload_contract_ok" = "true" ]] || result_pass="false"
  [[ "$quiet_reason_contract_ok" = "true" ]] || result_pass="false"
  [[ "$pending_lazy_ok" = "true" ]] || result_pass="false"
  [[ "$keeper_fiber_ok" = "true" ]] || result_pass="false"
  [[ "$health_mode_ok" = "true" ]] || result_pass="false"
  [[ "$execution_cache_state" = "fresh" ]] || result_pass="false"
  [[ "$transport_cache_state" = "fresh" ]] || result_pass="false"

  append_result "$mode" "$(
    jq -nc \
      --arg mode "$mode" \
      --arg base_url "$base_url" \
      --arg server_log "$server_log" \
      --arg pass "$result_pass" \
      --arg backend_mode "$(printf '%s' "$health_json" | jq -r '.startup.backend_mode // ""')" \
      --arg fallback_reason "$(printf '%s' "$health_json" | jq -r '.startup.fallback_reason // ""')" \
      --arg health_json "$health_json" \
      --arg keeper_list_json "$keeper_json" \
      --arg keeper_status_json "$keeper_status_json" \
      --arg keeper_name "$keeper_name" \
      --arg keeper_status_attempted_json "$keeper_status_attempted_json" \
      --arg transport_status_json "$transport_json" \
      --arg execution_payload_json "$execution_json" \
      --arg execution_json_sample "$(printf '%s' "$execution_json" | jq -c '{projection_diagnostics, generated_at}')" \
      --arg status_first_time "$status_first_time" \
      --arg status_second_time "$status_second_time" \
      --arg keeper_first_time "$keeper_first_time" \
      --arg keeper_second_time "$keeper_second_time" \
      --arg keeper_status_time "$keeper_status_time" \
      --arg transport_time "$transport_time" \
      --arg execution_time "$execution_time" \
      --arg transport_health_time "$transport_health_time" \
      --arg payload_contract_ok "$payload_contract_ok" \
      --arg quiet_reason_contract_ok "$quiet_reason_contract_ok" \
      --arg pending_lazy_ok "$pending_lazy_ok" \
      --arg keeper_fiber_ok "$keeper_fiber_ok" \
      --arg health_mode_ok "$health_mode_ok" \
      --arg health_mode_check_enabled "$health_mode_check_enabled" \
      --arg execution_cache_state "$execution_cache_state" \
      --arg transport_cache_state "$transport_cache_state" \
      '
      def num_or_zero: if . == null or . == "" then 0 else tonumber end;
      ($health_json | try fromjson catch {}) as $health
      | ($keeper_list_json | try fromjson catch {}) as $keeper_list
      | ($keeper_status_json | try fromjson catch {}) as $keeper_status
      | ($keeper_status_attempted_json | try fromjson catch []) as $keeper_status_attempted
      | ($transport_status_json | try fromjson catch $transport_status_json) as $transport_status
      | ($execution_payload_json | try fromjson catch {}) as $execution_payload
      | ($execution_json_sample | try fromjson catch {}) as $execution
      | {
        mode: $mode,
        pass: ($pass == "true"),
        base_url: $base_url,
        server_log: $server_log,
        backend_mode: $backend_mode,
        fallback_reason: (if ($fallback_reason | length) > 0 then $fallback_reason else null end),
        thresholds: {
          masc_status_first_max_sec: ($ENV.MASC_STATUS_FIRST_MAX_SEC // "5" | tonumber),
          masc_status_second_max_sec: ($ENV.MASC_STATUS_SECOND_MAX_SEC // "1.5" | tonumber),
          masc_keeper_list_first_max_sec: ($ENV.MASC_KEEPER_LIST_FIRST_MAX_SEC // "5" | tonumber),
          masc_keeper_list_second_max_sec: ($ENV.MASC_KEEPER_LIST_SECOND_MAX_SEC // "1.5" | tonumber),
          masc_transport_status_max_sec: ($ENV.MASC_TRANSPORT_STATUS_MAX_SEC // "2" | tonumber),
          dashboard_execution_max_sec: ($ENV.DASHBOARD_EXECUTION_MAX_SEC // "2" | tonumber),
          transport_health_max_sec: ($ENV.TRANSPORT_HEALTH_MAX_SEC // "2" | tonumber)
        },
        timings: {
          masc_status_first: ($status_first_time | num_or_zero),
          masc_status_second: ($status_second_time | num_or_zero),
          masc_keeper_list_first: ($keeper_first_time | num_or_zero),
          masc_keeper_list_second: ($keeper_second_time | num_or_zero),
          masc_keeper_status: ($keeper_status_time | num_or_zero),
          masc_transport_status: ($transport_time | num_or_zero),
          dashboard_execution: ($execution_time | num_or_zero),
          dashboard_transport_health: ($transport_health_time | num_or_zero)
        },
        checks: {
          payload_contract: ($payload_contract_ok == "true"),
          quiet_reason_contract: ($quiet_reason_contract_ok == "true"),
          pending_lazy_tasks_empty: ($pending_lazy_ok == "true"),
          keeper_fibers_present: ($keeper_fiber_ok == "true"),
          health_transport_mode_enforced: ($health_mode_check_enabled == "1"),
          health_transport_mode: ($health_mode_ok == "true"),
          execution_cache_state: $execution_cache_state,
          transport_cache_state: $transport_cache_state
        },
        keeper_name: (if ($keeper_name | length) > 0 then $keeper_name else null end),
        keeper_list_names: (($keeper_list.keepers // [])[:5]),
        keeper_status_attempted_names: $keeper_status_attempted,
        keeper_status_sample: $keeper_status,
        execution_keeper_sample: (($execution_payload.keepers // [])[:2]),
        transport_status: $transport_status,
        execution: $execution,
        health: {
          startup: $health.startup,
          keeper_fibers: $health.keeper_fibers,
          transport: $health.transport
        }
      }'
  )"

  if [[ "$(normalize_bool "$START_SERVER")" = "1" && "$(normalize_bool "$KEEP_SERVER")" != "1" ]]; then
    harness_stop_server "$server_pid"
  elif [[ "$(normalize_bool "$START_SERVER")" = "1" ]]; then
    log "mode=${mode} keeping server pid=${server_pid}"
  fi

  [[ "$result_pass" = "true" ]]
}

main() {
  local mode overall_pass="true"
  local results='[]'

  IFS=',' read -r -a mode_list <<<"$MODES"
  for mode in "${mode_list[@]}"; do
    mode="$(printf '%s' "$mode" | xargs)"
    [[ -n "$mode" ]] || continue
    if run_mode "$mode"; then
      log "mode=${mode} PASS"
    else
      log "mode=${mode} FAIL"
      overall_pass="false"
    fi
    if [[ -f "$RUN_DIR/${mode}.json" ]]; then
      results="$(jq -cs '.[0] + [.[1]]' <(printf '%s' "$results") "$RUN_DIR/${mode}.json")"
    else
      results="$(
        jq -nc \
          --argjson current "$results" \
          --arg mode "$mode" \
          '$current + [{mode:$mode, pass:false, error:"mode result missing"}]'
      )"
    fi
  done

  jq -n \
    --arg run_id "$RUN_ID" \
    --arg run_dir "$RUN_DIR" \
    --arg base_path "$BASE_PATH" \
    --arg server_exe "$SERVER_EXE" \
    --arg modes "$MODES" \
    --arg overall_pass "$overall_pass" \
    --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson results "$results" \
    '{
      run_id: $run_id,
      generated_at: $generated_at,
      run_dir: $run_dir,
      base_path: $base_path,
      server_exe: $server_exe,
      modes: ($modes | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
      pass: ($overall_pass == "true"),
      results: $results
    }' >"$SUMMARY_JSON"

  printf 'summary=%s\n' "$SUMMARY_JSON"
  [[ "$overall_pass" = "true" ]]
}

main "$@"
