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
export MCP_TOKEN="${MCP_TOKEN:-}"
HARNESS_ADMIN_AGENT="${MASC_HARNESS_ADMIN_AGENT:-contract-harness-admin}"
export MCP_AGENT_NAME="${MCP_AGENT_NAME:-$HARNESS_ADMIN_AGENT}"
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
# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
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
  local last_status="000"
  local auth_token
  auth_token="$(mcp_default_auth_token)"
  if [[ -z "$auth_token" ]]; then
    echo "FAIL: MCP initialize readiness requires a workspace-local auth token" >&2
    return 1
  fi
  local auth_header_file=""
  if [[ -n "$auth_token" ]]; then
    auth_header_file="$(_mcp_auth_header_file "$auth_token")" || auth_header_file=""
  fi

  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    local status raw normalized
    local body_file stderr_file
    body_file="$(mcp_mktemp_file "masc-contract-init-ready-${RANDOM:-0}-$$" ".json")"
    stderr_file="$(mcp_mktemp_file "masc-contract-ready-stderr" ".log")"
    local -a headers=(
      -H 'Content-Type: application/json'
      -H 'Accept: application/json, text/event-stream'
    )
    if [[ -n "$auth_header_file" ]]; then
      headers+=( -H "@$auth_header_file" )
    fi
    status="$(
      curl -sS -o "$body_file" -w '%{http_code}' --max-time 2 \
        -X POST "$mcp_url" \
        "${headers[@]}" \
        -d "$body" 2>"$stderr_file" || true
    )"
    last_status="$status"
    if [[ "$status" == "200" ]]; then
      raw="$(cat "$body_file" 2>/dev/null || true)"
      normalized="$(jsonrpc_normalize_response "$raw" 0 2>/dev/null || true)"
      if printf '%s' "$normalized" | jq -e '.result != null and .error == null' >/dev/null 2>&1; then
        rm -f "$body_file" "$stderr_file" "$auth_header_file"
        return 0
      fi
      last_status="200-jsonrpc-error"
    fi
    rm -f "$body_file" "$stderr_file"
    sleep 1
  done

  rm -f "$auth_header_file"
  echo "MCP initialize readiness failed; last_http_status=${last_status}" >&2
  return 1
}

run_contract() {
  local step="$1"
  local total="$2"
  local script_name="$3"
  echo "[${step}/${total}] ${script_name}"
  if ! (
    cd "$ROOT_DIR"
    MCP_URL="$MCP_URL" \
      MCP_TOKEN="${MCP_TOKEN:-}" \
      MCP_AGENT_NAME="$MCP_AGENT_NAME" \
      BASE_PATH="$BASE_PATH" \
      bash "scripts/harness/contract/${script_name}"
  ); then
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
harness_seed_server_config "$ROOT_DIR" "$BASE_PATH"

if ! MCP_TOKEN="$(
  harness_mint_admin_token "$SERVER_EXE" "$PORT" "$BASE_PATH" \
    "$HARNESS_ADMIN_AGENT"
)"; then
  echo "FAIL: failed to mint contract harness admin token" >&2
  exit 1
fi
if [[ -z "$MCP_TOKEN" ]]; then
  echo "FAIL: contract harness admin token is empty" >&2
  exit 1
fi
export MCP_TOKEN
unset MCP_AUTH_TOKEN
unset MASC_ADMIN_TOKEN
echo "[bootstrap] auth_token=workspace-local admin token minted"

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

run_contract 1 4 "streamable_http_contract.sh"
run_contract 2 4 "golden_path_1_contract.sh"
run_contract 3 4 "public_tool_live_sweep.sh"
run_contract 4 4 "scheduler_live_supported_contract.sh"

echo "PASS: contract harness suite"
