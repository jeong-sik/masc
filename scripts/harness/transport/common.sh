#!/usr/bin/env bash
# Common helpers for transport E2E harness scripts.
# Source this from each verify_*.sh script.

set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${COMMON_DIR}/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/server_bootstrap.sh"

MASC_HTTP_PORT="${MASC_HTTP_PORT:-$(harness_pick_free_port)}"
MASC_GRPC_PORT="${MASC_GRPC_PORT:-$(harness_pick_free_port)}"
MASC_WS_PORT="${MASC_WS_PORT:-$(harness_pick_free_port)}"
# Issue #8423: `MASC_HTTP_BASE_URL` is the documented name the OCaml
# server reads (server_bootstrap_http.ml, env_config_core.ml). The
# harness historically only exported `MASC_BASE_URL`, so an operator
# setting `MASC_HTTP_BASE_URL` saw the real service while `verify_*.sh`
# kept probing the free-port default. Honour the documented name first,
# keep `MASC_BASE_URL` as a legacy alias so the 7 in-tree `verify_*.sh`
# callers keep working until a follow-up PR migrates them.
MASC_HTTP_BASE_URL="${MASC_HTTP_BASE_URL:-http://127.0.0.1:${MASC_HTTP_PORT}}"
MASC_BASE_URL="${MASC_HTTP_BASE_URL}"
MASC_GRPC_ADDR="127.0.0.1:${MASC_GRPC_PORT}"
MASC_WS_URL="ws://127.0.0.1:${MASC_WS_PORT}"

export ROOT_DIR
export MASC_HTTP_PORT
export MASC_GRPC_PORT
export MASC_WS_PORT
export MASC_HTTP_BASE_URL
export MASC_BASE_URL
export MASC_GRPC_ADDR
export MASC_WS_URL

PASS=0
FAIL=0
SKIP=0
AUTH_BLOCKED=0

TRANSPORT_SERVER_PID=""
TRANSPORT_SERVER_BASE_PATH=""
TRANSPORT_SERVER_LOG_FILE=""

pass() {
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s: %s\n' "$1" "${2:-}"
}

skip() {
  SKIP=$((SKIP + 1))
  printf '  \033[33mSKIP\033[0m %s: %s\n' "$1" "${2:-}"
}

auth_blocked() {
  AUTH_BLOCKED=$((AUTH_BLOCKED + 1))
  printf '  \033[36mAUTH-BLOCKED\033[0m %s: %s\n' "$1" "${2:-}"
}

summary() {
  echo ""
  printf '=== %s: %d passed, %d failed, %d skipped, %d auth-blocked ===\n' \
    "${HARNESS_NAME:-transport}" "$PASS" "$FAIL" "$SKIP" "$AUTH_BLOCKED"
  [ "$FAIL" -eq 0 ]
}

cleanup_transport_server() {
  harness_stop_server "$TRANSPORT_SERVER_PID" "${STOP_WAIT_SEC:-10}"
  if [[ -n "$TRANSPORT_SERVER_BASE_PATH" ]]; then
    rm -rf "$TRANSPORT_SERVER_BASE_PATH"
  fi
  if [[ -n "$TRANSPORT_SERVER_LOG_FILE" ]]; then
    rm -f "$TRANSPORT_SERVER_LOG_FILE"
  fi
}

ensure_server() {
  if curl -fsS --max-time 2 "${MASC_BASE_URL}/health" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${MASC_TRANSPORT_AUTOSTART:-1}" != "1" ]]; then
    echo "ERROR: MASC server not running on ${MASC_BASE_URL}" >&2
    echo "Set MASC_TRANSPORT_AUTOSTART=1 or start a server manually." >&2
    exit 2
  fi

  local server_exe
  server_exe="$(harness_find_server_exe "$ROOT_DIR" "${SERVER_EXE:-}")"
  TRANSPORT_SERVER_BASE_PATH="$(harness_mktemp_dir "masc-transport-room")"
  TRANSPORT_SERVER_LOG_FILE="$(harness_mktemp_file "masc-transport-server" ".log")"

  # shellcheck disable=SC2031
  export MASC_BASE_PATH="${TRANSPORT_SERVER_BASE_PATH}"
  export MASC_GRPC_ENABLED="${MASC_GRPC_ENABLED:-1}"
  export MASC_GRPC_PORT
  export MASC_WS_ENABLED="${MASC_WS_ENABLED:-1}"
  export MASC_WS_PORT
  export MASC_WEBRTC_ENABLED="${MASC_WEBRTC_ENABLED:-1}"
  export MASC_HOST="${MASC_HOST:-127.0.0.1}"
  export MASC_HTTP_PORT

  TRANSPORT_SERVER_PID="$(
    harness_start_server \
      "$server_exe" \
      "$MASC_HTTP_PORT" \
      "$TRANSPORT_SERVER_BASE_PATH" \
      "$TRANSPORT_SERVER_LOG_FILE"
  )"
  trap cleanup_transport_server EXIT

  if ! harness_wait_for_health "$MASC_HTTP_PORT" 25; then
    echo "ERROR: transport harness server failed to become healthy on ${MASC_BASE_URL}" >&2
    harness_print_log_tail "$TRANSPORT_SERVER_LOG_FILE"
    exit 1
  fi
}

require_server() {
  ensure_server
}

# Check if a CLI tool is available.
require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "WARN: $tool not found, some tests will be skipped"
    return 1
  fi
  return 0
}

mcp_initialize_session() {
  local headers body payload session_id
  headers="$(harness_mktemp_file "masc-transport-init-header")"
  body="$(harness_mktemp_file "masc-transport-init-body")"
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"transport-harness","version":"1.0"}}}'
  if ! curl -fsS -D "$headers" -o "$body" -X POST "${MASC_BASE_URL}/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "$payload" >/dev/null; then
    echo "ERROR: MCP initialize failed" >&2
    cat "$body" >&2 || true
    rm -f "$headers" "$body"
    return 1
  fi
  session_id="$(
    awk 'tolower($1)=="mcp-session-id:" { gsub("\r", "", $2); print $2; exit }' \
      "$headers"
  )"
  rm -f "$headers" "$body"
  if [[ -z "$session_id" ]]; then
    echo "ERROR: MCP initialize did not return Mcp-Session-Id" >&2
    return 1
  fi
  printf '%s\n' "$session_id"
}

mcp_call_tool() {
  local session_id="$1"
  local tool_name="$2"
  local arguments_json="$3"
  local request_id="${4:-1}"
  local payload
  payload="$(printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' \
    "$request_id" "$tool_name" "$arguments_json")"
  curl -fsS -X POST "${MASC_BASE_URL}/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: ${session_id}" \
    -d "$payload"
}

mcp_join_agent() {
  local session_id="$1"
  local agent_name="$2"
  mcp_call_tool \
    "$session_id" \
    "masc_join" \
    "$(printf '{"agent_name":"%s","capabilities":[]}' "$agent_name")" \
    2
}

mcp_broadcast() {
  local session_id="$1"
  local agent_name="$2"
  local message="$3"
  mcp_call_tool \
    "$session_id" \
    "masc_broadcast" \
    "$(printf '{"agent_name":"%s","message":"%s"}' "$agent_name" "$message")" \
    3
}
