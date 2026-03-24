#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/server_bootstrap.sh"

SERVER_EXE="$(harness_find_server_exe "$ROOT_DIR" "${SERVER_EXE:-}")"
PORT="${PORT:-$(harness_pick_free_port)}"
BASE_PATH="${BASE_PATH:-$(mktemp -d "${TMPDIR:-/tmp}/masc-contract-room.XXXXXX")}"
LOG_FILE="${LOG_FILE:-$(mktemp "${TMPDIR:-/tmp}/masc-contract-server.XXXXXX.log")}"
KEEP_BASE_PATH="${KEEP_BASE_PATH:-0}"
KEEP_LOG_FILE="${KEEP_LOG_FILE:-0}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-10}"

export MCP_URL="${MCP_URL:-http://127.0.0.1:${PORT}/mcp}"
export CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
export CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"
export CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-25}"
export HARNESS_LOG_FILE="${HARNESS_LOG_FILE:-$LOG_FILE}"

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

run_contract() {
  local step="$1"
  local total="$2"
  local script_name="$3"
  echo "[${step}/${total}] ${script_name}"
  if ! (cd "$ROOT_DIR" && MCP_URL="$MCP_URL" bash "scripts/harness/contract/${script_name}"); then
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

run_contract 1 3 "streamable_http_contract.sh"
run_contract 2 3 "team_session_contract.sh"
run_contract 3 3 "golden_path_1_contract.sh"

echo "PASS: contract harness suite"
