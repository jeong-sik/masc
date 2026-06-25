#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/server_bootstrap.sh"

SERVER_EXE_HINT="${SERVER_EXE:-}"
if ! SERVER_EXE="$(harness_find_server_exe "$ROOT_DIR" "${SERVER_EXE_HINT}")"; then
  SERVER_EXE=""
fi
PORT="${PORT:-$(harness_pick_free_port)}"
BASE_PATH="${BASE_PATH:-$(harness_mktemp_dir "masc-contract-workspace")}"
LOG_FILE="${LOG_FILE:-$(harness_mktemp_file "masc-contract-server" ".log")}"
KEEP_BASE_PATH="${KEEP_BASE_PATH:-0}"
KEEP_LOG_FILE="${KEEP_LOG_FILE:-0}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-10}"

export MCP_URL="${MCP_URL:-http://127.0.0.1:${PORT}/mcp}"
export MCP_TOKEN="${MCP_TOKEN:-${MASC_TOKEN:-}}"
export MCP_AGENT_NAME="${MCP_AGENT_NAME:-contract-harness-admin-${RANDOM:-0}-$$}"
export CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
export CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"
export CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-80}"
if (( CURL_TIMEOUT_SEC > 5 )); then
  export MASC_TOOL_TIMEOUT_DEFAULT_SEC="${MASC_TOOL_TIMEOUT_DEFAULT_SEC:-$((CURL_TIMEOUT_SEC - 5))}"
else
  export MASC_TOOL_TIMEOUT_DEFAULT_SEC="${MASC_TOOL_TIMEOUT_DEFAULT_SEC:-$CURL_TIMEOUT_SEC}"
fi
export HARNESS_LOG_FILE="${HARNESS_LOG_FILE:-$LOG_FILE}"
export MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS="${MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS:-32}"

source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

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

build_server_exe() {
  if [[ -x "$SERVER_EXE" ]]; then
    return 0
  fi
  echo "[bootstrap] server executable missing; building"
  (
    cd "$ROOT_DIR"
    if command -v opam >/dev/null 2>&1; then
      opam exec -- dune build --root . ./bin/main_eio.exe
    elif [[ -x "$ROOT_DIR/scripts/dune-local.sh" ]]; then
      "$ROOT_DIR/scripts/dune-local.sh" build ./bin/main_eio.exe
    else
      dune build --root . ./bin/main_eio.exe
    fi
  )
  if ! SERVER_EXE="$(harness_find_server_exe "$ROOT_DIR" "${SERVER_EXE_HINT}")"; then
    echo "FAIL: server executable still not found after build step" >&2
    return 1
  fi
  return 0
}

wait_for_mcp_initialize_ready() {
  local mcp_url="$1"
  local timeout_sec="${2:-25}"
  local deadline=$(( $(date +%s) + timeout_sec ))
  local body='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract-bootstrap","version":"1.0"},"capabilities":{}}}'
  local last_http_status=""

  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    local status raw normalized
    local body_file stderr_file
    body_file="$(mcp_mktemp_file "masc-contract-ready-body" ".json")"
    stderr_file="$(mcp_mktemp_file "masc-contract-ready-stderr" ".log")"
    local -a cmd=(
      curl -sS -o "$body_file" -w '%{http_code}' --max-time 2
      -X POST "$mcp_url"
      -H 'Content-Type: application/json'
      -H 'Accept: application/json, text/event-stream'
    )
    if [[ -n "${MCP_TOKEN:-}" ]]; then
      cmd+=( -H "Authorization: Bearer ${MCP_TOKEN}" )
    fi
    cmd+=( -d "$body" )
    status="$(
      "${cmd[@]}" 2>"$stderr_file" || true
    )"
    last_http_status="$status"
    if [[ "$status" == "200" ]]; then
      raw="$(cat "$body_file" 2>/dev/null || true)"
      normalized="$(jsonrpc_normalize_response "$raw" 0)"
      if printf '%s' "$normalized" | jq -e '.result != null and .error == null' >/dev/null 2>&1; then
        rm -f "$body_file" "$stderr_file"
        return 0
      fi
    fi
    rm -f "$body_file" "$stderr_file"
    sleep 1
  done

  echo "MCP initialize readiness failed; last_http_status=${last_http_status:-unknown}" >&2
  return 1
}

run_contract() {
  local step="$1"
  local total="$2"
  local script_name="$3"
  echo "[${step}/${total}] ${script_name}"
  if ! (cd "$ROOT_DIR" && MCP_URL="$MCP_URL" MCP_TOKEN="${MCP_TOKEN:-}" MCP_AGENT_NAME="$MCP_AGENT_NAME" BASE_PATH="$BASE_PATH" bash "scripts/harness/contract/${script_name}"); then
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

if ! build_server_exe; then
  exit 1
fi
echo "[bootstrap] server_exe=${SERVER_EXE}"

SERVER_PID="$(harness_start_server "$SERVER_EXE" "$PORT" "$BASE_PATH" "$LOG_FILE")"
if ! harness_wait_for_health "$PORT" 25; then
  echo "FAIL: server did not become healthy on port ${PORT}" >&2
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi
if [[ -z "${MCP_TOKEN:-}" ]]; then
  if ! MCP_TOKEN="$(harness_mint_mcp_token "$SERVER_EXE" "127.0.0.1" "$PORT" "$BASE_PATH")"; then
    echo "FAIL: could not mint MCP harness token; aborting before an unauthenticated contract run" >&2
    exit 1
  fi
fi
export MCP_TOKEN
if [[ -z "${MCP_TOKEN:-}" ]]; then
  echo "FAIL: MCP_TOKEN is empty; refusing to run contract probes unauthenticated" >&2
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
