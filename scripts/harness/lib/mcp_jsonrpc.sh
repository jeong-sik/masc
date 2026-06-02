#!/usr/bin/env bash

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${CURL_RETRY_COUNT:=4}"
: "${CURL_RETRY_DELAY_SEC:=1}"
: "${CURL_TIMEOUT_SEC:=25}"
: "${HTTP_TIMEOUT_SEC:=$CURL_TIMEOUT_SEC}"
: "${MCP_SESSION_ID:=}"
: "${HARNESS_LOG_FILE:=}"
: "${HARNESS_LOG_TAIL_LINES:=120}"
: "${MCP_CURL_EXTRA_ARGS:=}"
: "${MCP_PROTOCOL_VERSION:=}"
MCP_LAST_TIME_TOTAL=""

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/harness/jsonrpc_sse.sh
source "${_HARNESS_DIR}/jsonrpc_sse.sh"

mcp_mktemp_file() {
  local prefix="$1"
  local suffix="${2:-}"
  local tmp_root="${TMPDIR:-/tmp}"
  local path
  path="$(mktemp "${tmp_root%/}/${prefix}.XXXXXX")" || return 1
  if [[ -n "$suffix" ]]; then
    local target="${path}${suffix}"
    mv "$path" "$target"
    path="$target"
  fi
  printf '%s\n' "$path"
}

mcp_print_log_tail() {
  local log_file="${1:-${HARNESS_LOG_FILE:-}}"
  local lines="${2:-${HARNESS_LOG_TAIL_LINES:-120}}"
  if [[ -n "$log_file" && -f "$log_file" ]]; then
    echo "---- tail -n ${lines} ${log_file} ----" >&2
    tail -n "$lines" "$log_file" >&2 || true
  fi
}

mcp_fail_with_context() {
  local message="$1"
  local payload="${2:-}"
  echo "FAIL: ${message}" >&2
  if [[ -n "$payload" ]]; then
    if printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$payload" | jq . >&2 || printf '%s\n' "$payload" >&2
    else
      printf '%s\n' "$payload" >&2
    fi
  fi
  mcp_print_log_tail
  return 1
}

mcp_extract_text() {
  jq -r 'if ._harness_error? then empty else try (.result.content[0].text) catch empty end'
}

mcp_extract_result() {
  jq -c '
    if ._harness_error? then
      empty
    else
      try (
        .result.content[0].text
        | fromjson
        | if has("result") and .result != null then .result else . end
      ) catch empty
    end
  '
}

mcp_extract_is_error() {
  jq -r 'try (.result.isError) catch "true"'
}

mcp_extract_error() {
  jq -r '
    if ._harness_error? then
      ._harness_error.message // ""
    elif (.error | type) == "object" and (.error.message | type) == "string" then
      .error.message
    else
      try (.result.content[0].text | fromjson | .message) catch ""
    end
  '
}

mcp_require_json() {
  local payload="$1"
  local label="${2:-response}"
  if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    mcp_fail_with_context "${label}: invalid JSON payload" "$payload"
    return 1
  fi
}

mcp_require_jsonrpc_ok() {
  local payload="$1"
  local label="${2:-response}"
  mcp_require_json "$payload" "$label" || return 1

  if printf '%s' "$payload" | jq -e '._harness_error? != null' >/dev/null 2>&1; then
    local details
    details="$(printf '%s' "$payload" | jq -r '
      ._harness_error as $e
      | [
          ($e.category // "transport"),
          ("endpoint=" + ($e.endpoint // "")),
          ("curl_exit=" + ($e.curl_exit // "")),
          (if ($e.stderr // "") = "" then empty else "stderr=" + $e.stderr end)
        ]
      | join(", ")
    ')"
    mcp_fail_with_context "${label}: ${details}" "$payload"
    return 1
  fi

  if ! printf '%s' "$payload" | jq -e '.error == null' >/dev/null 2>&1; then
    local err
    err="$(printf '%s' "$payload" | jq -c '.error')"
    mcp_fail_with_context "${label}: JSON-RPC error" "$err"
    return 1
  fi
}

mcp_require_tool_ok() {
  local payload="$1"
  local label="${2:-tool call}"
  mcp_require_jsonrpc_ok "$payload" "$label" || return 1

  if printf '%s' "$payload" | jq -e '.result.isError == true' >/dev/null 2>&1; then
    local text
    text="$(printf '%s' "$payload" | mcp_extract_text)"
    if [[ -n "$text" ]]; then
      mcp_fail_with_context "${label}: tool returned isError=true" "$text"
    else
      mcp_fail_with_context "${label}: tool returned isError=true" "$payload"
    fi
    return 1
  fi
}

_mcp_build_transport_error() {
  local message="$1"
  local endpoint="$2"
  local curl_exit="$3"
  local stderr_text="$4"
  local timeout_sec="$5"
  jq -cn \
    --arg message "$message" \
    --arg endpoint "$endpoint" \
    --arg curl_exit "$curl_exit" \
    --arg stderr_text "$stderr_text" \
    --arg timeout_sec "$timeout_sec" \
    '{
      _harness_error: {
        category: "transport",
        message: $message,
        endpoint: $endpoint,
        curl_exit: $curl_exit,
        stderr: $stderr_text,
        timeout_sec: $timeout_sec
      }
    }'
}

_mcp_build_request_body() {
  local id="$1"
  local method="$2"
  local params_json="$3"
  jq -cn \
    --argjson id "$id" \
    --arg method "$method" \
    --argjson params "$params_json" \
    '{jsonrpc:"2.0", id:$id, method:$method, params:$params}'
}

mcp_jsonrpc_call() {
  local id="$1"
  local method="$2"
  local params_json="$3"
  local session_id="${4:-${MCP_SESSION_ID:-}}"
  local token="${5:-}"
  local endpoint="${6:-${MCP_URL:-}}"
  local timeout_sec="${HTTP_TIMEOUT_SEC:-${CURL_TIMEOUT_SEC:-25}}"

  local request_body
  if ! request_body="$(_mcp_build_request_body "$id" "$method" "$params_json" 2>/dev/null)"; then
    MCP_LAST_TIME_TOTAL=""
    _mcp_build_transport_error \
      "failed to build JSON-RPC request" \
      "$endpoint" \
      "local" \
      "invalid id or params JSON" \
      "$timeout_sec"
    return 0
  fi

  local attempt=1
  local max_attempts="${CURL_RETRY_COUNT:-1}"
  local retry_delay="${CURL_RETRY_DELAY_SEC:-1}"
  local raw=""
  local status=0
  local stderr_text=""
  local cumulative_time="0"
  local -a extra_args=()
  if [[ -n "${MCP_CURL_EXTRA_ARGS:-}" ]]; then
    read -r -a extra_args <<< "${MCP_CURL_EXTRA_ARGS}"
  fi

  while :; do
    local body_file stderr_file resp_file
    body_file="$(mcp_mktemp_file "masc-jsonrpc-body" ".json")"
    stderr_file="$(mcp_mktemp_file "masc-jsonrpc-stderr" ".log")"
    resp_file="$(mcp_mktemp_file "masc-jsonrpc-resp" ".json")"
    printf '%s' "$request_body" >"$body_file"

    local -a cmd=(
      curl -sS --max-time "$timeout_sec"
      -X POST "$endpoint"
      -o "$resp_file"
      -w '%{time_total}'
      -H 'Content-Type: application/json'
      -H 'Accept: application/json, text/event-stream'
    )
    if [[ -n "$session_id" ]]; then
      cmd+=( -H "Mcp-Session-Id: $session_id" )
    fi
    if [[ -n "${MCP_PROTOCOL_VERSION:-}" ]]; then
      cmd+=( -H "Mcp-Protocol-Version: $MCP_PROTOCOL_VERSION" )
    fi
    if [[ -n "$token" ]]; then
      cmd+=( -H "Authorization: Bearer $token" )
    fi
    if [[ "${#extra_args[@]}" -gt 0 ]]; then
      cmd+=( "${extra_args[@]}" )
    fi
    cmd+=( --data-binary "@$body_file" )

    set +e
    local attempt_time
    attempt_time="$("${cmd[@]}" 2>"$stderr_file")"
    status=$?
    set -e
    # Accumulate wall-clock time across retries (including sleep delays via awk).
    cumulative_time="$(awk -v c="$cumulative_time" -v a="${attempt_time:-0}" 'BEGIN{printf "%.6f", c + a}')"
    MCP_LAST_TIME_TOTAL="$cumulative_time"
    stderr_text="$(cat "$stderr_file" 2>/dev/null || true)"
    raw="$(cat "$resp_file" 2>/dev/null || true)"
    rm -f "$body_file" "$stderr_file" "$resp_file"

    if [[ "$status" -eq 0 ]]; then
      local normalized
      normalized="$(jsonrpc_normalize_response "$raw" "$id")"
      if printf '%s' "$normalized" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$normalized"
        return 0
      fi

      if printf '%s' "$raw" | grep -Eq '^(retry:|id:|event:|data:)'; then
        stderr_text="MCP SSE response did not contain JSON-RPC data"
        status=28
      else
        printf '%s' "$normalized"
        return 0
      fi
    fi

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      break
    fi
    case "$status" in
      7|28)
        sleep "$retry_delay"
        # Include retry sleep in cumulative time.
        cumulative_time="$(awk -v c="$cumulative_time" -v d="$retry_delay" 'BEGIN{printf "%.6f", c + d}')"
        MCP_LAST_TIME_TOTAL="$cumulative_time"
        attempt=$((attempt + 1))
        ;;
      *)
        break
        ;;
    esac
  done

  _mcp_build_transport_error \
    "curl failed after ${attempt}/${max_attempts} attempts" \
    "$endpoint" \
    "$status" \
    "$stderr_text" \
    "$timeout_sec"
}

mcp_call_tool() {
  local id="$1"
  local tool_name="$2"
  local args_json="$3"
  local session_id="${4:-${MCP_SESSION_ID:-}}"
  local token="${5:-}"
  local endpoint="${6:-${MCP_URL:-}}"

  local params_json
  if ! params_json="$(jq -cn --arg name "$tool_name" --argjson arguments "$args_json" '{name:$name, arguments:$arguments}' 2>/dev/null)"; then
    _mcp_build_transport_error \
      "failed to build tools/call params" \
      "$endpoint" \
      "local" \
      "invalid tool args JSON" \
      "${HTTP_TIMEOUT_SEC:-${CURL_TIMEOUT_SEC:-25}}"
    return 0
  fi

  mcp_jsonrpc_call "$id" "tools/call" "$params_json" "$session_id" "$token" "$endpoint"
}

# Call tool and assert success. Returns the full payload on success.
# Usage: payload="$(mcp_call_tool_checked <id> <tool> <args_json> [session_id] [token] [endpoint])"
mcp_call_tool_checked() {
  local payload
  payload="$(mcp_call_tool "$@")"
  mcp_require_tool_ok "$payload" "${2:-tool}_checked"
  printf '%s' "$payload"
}

# Call tool, assert success, extract .result. Returns the parsed result object.
# Usage: result="$(mcp_call_tool_result <id> <tool> <args_json> [session_id] [token] [endpoint])"
mcp_call_tool_result() {
  local payload
  payload="$(mcp_call_tool_checked "$@")"
  printf '%s' "$payload" | mcp_extract_result
}
