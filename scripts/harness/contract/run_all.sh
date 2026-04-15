#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/server_bootstrap.sh"

SERVER_EXE="$(harness_find_server_exe "$ROOT_DIR" "${SERVER_EXE:-}")"
PORT="${PORT:-$(harness_pick_free_port)}"
BASE_PATH="${BASE_PATH:-$(harness_mktemp_dir "masc-contract-room")}"
LOG_FILE="${LOG_FILE:-$(harness_mktemp_file "masc-contract-server" ".log")}"
KEEP_BASE_PATH="${KEEP_BASE_PATH:-0}"
KEEP_LOG_FILE="${KEEP_LOG_FILE:-0}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-10}"

export MCP_URL="${MCP_URL:-http://127.0.0.1:${PORT}/mcp}"
export CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
export CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"
export CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-65}"
export HARNESS_LOG_FILE="${HARNESS_LOG_FILE:-$LOG_FILE}"
export MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS="${MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS:-32}"

SERVER_PID=""

cleanup() {
  harness_stop_server "$SERVER_PID" "$STOP_WAIT_SEC"
  if [[ "$KEEP_BASE_PATH" != "1" ]]; then
    rm -rf "$BASE_PATH"
  fi
  if [[ "$KEEP_LOG_FILE" != "1" ]]; then
    rm -f "$LOG_FILE"
  fi
}
trap cleanup EXIT

wait_for_mcp_initialize_ready() {
  local mcp_url="$1"
  local timeout_sec="${2:-25}"
  local deadline=$(( $(date +%s) + timeout_sec ))
  local body='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract-bootstrap","version":"1.0"},"capabilities":{}}}'

  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    local status
    status="$(
      curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        -X POST "$mcp_url" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d "$body" 2>/dev/null || true
    )"
    if [[ "$status" == "200" ]]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

run_contract() {
  local step="$1"
  local total="$2"
  local script_name="$3"
  echo "[${step}/${total}] ${script_name}"
  if ! (cd "$ROOT_DIR" && MCP_URL="$MCP_URL" BASE_PATH="$BASE_PATH" bash "scripts/harness/contract/${script_name}"); then
    echo "FAIL: ${script_name}" >&2
    harness_print_log_tail "$LOG_FILE"
    exit 1
  fi
}

echo "[bootstrap] server_exe=${SERVER_EXE}"
echo "[bootstrap] port=${PORT}"
echo "[bootstrap] base_path=${BASE_PATH}"
echo "[bootstrap] log_file=${LOG_FILE}"
echo "[bootstrap] mcp_url=${MCP_URL}"

SERVER_PID="$(harness_start_server "$SERVER_EXE" "$PORT" "$BASE_PATH" "$LOG_FILE")"
if ! harness_wait_for_health "$PORT" 25; then
  echo "FAIL: server did not become healthy on port ${PORT}" >&2
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi
if ! wait_for_mcp_initialize_ready "$MCP_URL" 25; then
  echo "FAIL: MCP endpoint did not become initialize-ready at ${MCP_URL}" >&2
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi

run_contract 1 3 "streamable_http_contract.sh"
run_contract 2 3 "golden_path_1_contract.sh"
run_contract 3 3 "public_tool_live_sweep.sh"

echo "PASS: contract harness suite"
