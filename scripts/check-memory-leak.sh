#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/harness/lib/server_bootstrap.sh"

usage() {
  cat <<'EOF'
Usage: scripts/check-memory-leak.sh [options]

Build the main Eio server, run it under Valgrind memcheck, exercise a small
HTTP/MCP smoke flow, and fail if definite/indirect/possible leaks are reported.

Options:
  --skip-build          Use an existing built executable
  --port PORT           Fixed port instead of auto-picking a free loopback port
  --base-path PATH      Runtime base path (default: temp dir)
  --timeout-sec SEC     Health/shutdown timeout in seconds (default: 20)
  --keep-artifacts      Keep temporary runtime directory and log files
  --help                Show this help

Environment overrides:
  VALGRIND_BIN                        Valgrind executable (default: valgrind)
  MASC_MAIN_EIO_EXE                   Explicit server executable path
  MASC_MEMORY_LEAK_PORT               Same as --port
  MASC_MEMORY_LEAK_BASE_PATH          Same as --base-path
  MASC_MEMORY_LEAK_TIMEOUT_SEC        Same as --timeout-sec
  MASC_MEMORY_LEAK_SERVER_LOG         Server stdout/stderr log path
  MASC_MEMORY_LEAK_VALGRIND_LOG       Valgrind log path
EOF
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "missing required command: $name" >&2
    exit 1
  fi
}

maybe_cleanup_path() {
  local path="$1"
  if [[ -n "$path" && -e "$path" ]]; then
    rm -rf "$path"
  fi
}

print_logs() {
  echo "server log: ${SERVER_LOG_FILE}" >&2
  echo "valgrind log: ${VALGRIND_LOG_FILE}" >&2
  harness_print_log_tail "${SERVER_LOG_FILE}" 80
  harness_print_log_tail "${VALGRIND_LOG_FILE}" 120
}

graceful_stop() {
  local pid="${1:-}"
  local wait_sec="${2:-20}"
  if [[ -z "${pid}" ]]; then
    return 0
  fi

  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill -INT "${pid}" >/dev/null 2>&1 || true
    local deadline=$(( $(date +%s) + wait_sec ))
    while kill -0 "${pid}" >/dev/null 2>&1; do
      if [[ "$(date +%s)" -ge "${deadline}" ]]; then
        kill -TERM "${pid}" >/dev/null 2>&1 || true
        break
      fi
      sleep 1
    done
  fi

  if kill -0 "${pid}" >/dev/null 2>&1; then
    harness_stop_server "${pid}" 5
  fi
}

run_mcp_smoke() {
  local port="$1"
  local headers_file init_body tools_body mcp_session_id
  headers_file="$(harness_mktemp_file masc-memory-leak-init .headers)"
  init_body="$(harness_mktemp_file masc-memory-leak-init-body .json)"
  tools_body="$(harness_mktemp_file masc-memory-leak-tools-body .json)"

  curl -fsS -D "${headers_file}" "http://127.0.0.1:${port}/mcp" \
    -H "Accept: application/json, text/event-stream" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"memory-leak-check","version":"0.1"}}}' \
    > "${init_body}"

  mcp_session_id="$(awk -F': ' 'tolower($1)=="mcp-session-id"{gsub("\r", "", $2); print $2}' "${headers_file}" | tail -n 1)"
  if [[ -z "${mcp_session_id}" ]]; then
    echo "failed to capture Mcp-Session-Id from initialize response" >&2
    rm -f "${headers_file}" "${init_body}" "${tools_body}"
    return 1
  fi

  curl -fsS "http://127.0.0.1:${port}/mcp" \
    -H "Accept: application/json, text/event-stream" \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: ${mcp_session_id}" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    > "${tools_body}"

  rm -f "${headers_file}" "${init_body}" "${tools_body}"
}

BUILD_FIRST=1
KEEP_ARTIFACTS=0
TIMEOUT_SEC="${MASC_MEMORY_LEAK_TIMEOUT_SEC:-20}"
PORT="${MASC_MEMORY_LEAK_PORT:-}"
BASE_PATH="${MASC_MEMORY_LEAK_BASE_PATH:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      BUILD_FIRST=0
      ;;
    --port)
      shift
      PORT="${1:-}"
      ;;
    --base-path)
      shift
      BASE_PATH="${1:-}"
      ;;
    --timeout-sec)
      shift
      TIMEOUT_SEC="${1:-}"
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "${PORT}" ]]; then
  PORT="$(harness_pick_free_port)"
fi
if [[ -z "${BASE_PATH}" ]]; then
  BASE_PATH="$(harness_mktemp_dir masc-memory-leak-root)"
fi

VALGRIND_BIN="${VALGRIND_BIN:-valgrind}"
SERVER_LOG_FILE="${MASC_MEMORY_LEAK_SERVER_LOG:-$(harness_mktemp_file masc-memory-leak-server .log)}"
VALGRIND_LOG_FILE="${MASC_MEMORY_LEAK_VALGRIND_LOG:-$(harness_mktemp_file masc-memory-leak-valgrind .log)}"

TEMP_BASE_PATH_CREATED=0
if [[ ${BASE_PATH} == /tmp/masc-memory-leak-root.* ]]; then
  TEMP_BASE_PATH_CREATED=1
fi

cleanup() {
  local status=$?
  graceful_stop "${SERVER_PID:-}" "${TIMEOUT_SEC}"
  if [[ -n "${SERVER_PID:-}" ]]; then
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ "${status}" -ne 0 ]]; then
    print_logs
  elif [[ "${KEEP_ARTIFACTS}" -eq 0 && "${TEMP_BASE_PATH_CREATED}" -eq 1 ]]; then
    maybe_cleanup_path "${BASE_PATH}"
  fi
}
trap cleanup EXIT

require_cmd curl
require_cmd python3
require_cmd "${VALGRIND_BIN}"

if [[ "${BUILD_FIRST}" -eq 1 ]]; then
  require_cmd "${REPO_ROOT}/scripts/dune-local.sh"
  echo "[memory-leak] building bin/main_eio.exe" >&2
  "${REPO_ROOT}/scripts/dune-local.sh" build bin/main_eio.exe
fi

SERVER_EXE="$(harness_find_server_exe "${REPO_ROOT}" "${MASC_MAIN_EIO_EXE:-}")"

mkdir -p "${BASE_PATH}"
echo "[memory-leak] executable=${SERVER_EXE}" >&2
echo "[memory-leak] port=${PORT}" >&2
echo "[memory-leak] base_path=${BASE_PATH}" >&2

(
  export MASC_BASE_PATH="${BASE_PATH}"
  export MASC_STORAGE_TYPE="filesystem"
  export MASC_AUTONOMY_ENABLED="0"
  export MASC_ORCHESTRATOR_ENABLED="0"
  export MASC_ALLOW_LEGACY_ACCEPT="1"
  export MASC_KEEPER_BOOTSTRAP_ENABLED="false"
  export MASC_TRANSPORT_AUTOSTART="0"
  export MASC_TOOL_TIMEOUT_DEFAULT_SEC="${MASC_TOOL_TIMEOUT_DEFAULT_SEC:-90}"
  export GRAPHQL_API_KEY=""
  # Force any optional GraphQL path to fail fast locally instead of drifting
  # to a real service during the leak-check smoke run.
  export GRAPHQL_URL="http://127.0.0.1:9/graphql"
  exec "${VALGRIND_BIN}" \
    --tool=memcheck \
    --leak-check=full \
    --show-leak-kinds=definite,indirect,possible \
    # Keep "possible" in the failure set so startup/MCP smoke regressions do
    # not get hidden behind a narrower default leak threshold.
    --errors-for-leak-kinds=definite,indirect,possible \
    --error-exitcode=101 \
    --log-file="${VALGRIND_LOG_FILE}" \
    "${SERVER_EXE}" --host 127.0.0.1 --port "${PORT}" --base-path "${BASE_PATH}"
) >"${SERVER_LOG_FILE}" 2>&1 &
SERVER_PID="$!"

if ! harness_wait_for_health "${PORT}" "${TIMEOUT_SEC}"; then
  echo "[memory-leak] server did not become healthy within ${TIMEOUT_SEC}s" >&2
  exit 1
fi

echo "[memory-leak] health check passed; exercising MCP initialize/tools/list" >&2
run_mcp_smoke "${PORT}"

graceful_stop "${SERVER_PID}" "${TIMEOUT_SEC}"
wait "${SERVER_PID}" >/dev/null 2>&1 || true
SERVER_PID=""

if [[ ! -s "${VALGRIND_LOG_FILE}" ]]; then
  echo "[memory-leak] valgrind log is empty: ${VALGRIND_LOG_FILE}" >&2
  exit 1
fi

if ! grep -Eq 'definitely lost: +0 bytes in +0 blocks' "${VALGRIND_LOG_FILE}"; then
  echo "[memory-leak] definite leak detected" >&2
  exit 1
fi
if ! grep -Eq 'indirectly lost: +0 bytes in +0 blocks' "${VALGRIND_LOG_FILE}"; then
  echo "[memory-leak] indirect leak detected" >&2
  exit 1
fi
if ! grep -Eq 'possibly lost: +0 bytes in +0 blocks' "${VALGRIND_LOG_FILE}"; then
  echo "[memory-leak] possible leak detected" >&2
  exit 1
fi

echo "[memory-leak] PASS" >&2
echo "server log: ${SERVER_LOG_FILE}"
echo "valgrind log: ${VALGRIND_LOG_FILE}"
