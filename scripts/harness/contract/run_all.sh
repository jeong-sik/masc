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
VERIFIER_PORT="${VERIFIER_PORT:-$(harness_pick_free_port)}"
VERIFIER_LOG="${VERIFIER_LOG:-$(harness_mktemp_file "masc-contract-verifier" ".jsonl")}"
VERIFIER_ERR="${VERIFIER_ERR:-$(harness_mktemp_file "masc-contract-verifier" ".log")}"
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
# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

SERVER_PID=""
VERIFIER_PID=""

cleanup() {
  harness_stop_server "$SERVER_PID" "$STOP_WAIT_SEC"
  harness_stop_server "$VERIFIER_PID" "$STOP_WAIT_SEC"
  if [[ "$KEEP_BASE_PATH" != "1" ]]; then
    rm -rf "$BASE_PATH"
  fi
  if [[ "$KEEP_LOG_FILE" != "1" ]]; then
    rm -f "$LOG_FILE"
    rm -f "$VERIFIER_LOG" "$VERIFIER_ERR"
  fi
}
trap cleanup EXIT

seed_contract_verifier_config() {
  local config_dir="${BASE_PATH%/}/.masc/config"
  local provider_base_url="http://127.0.0.1:${VERIFIER_PORT}/v1"
  mkdir -p \
    "$config_dir" \
    "$config_dir/keepers" \
    "$config_dir/personas" \
    "$config_dir/prompts"

  cat >"$config_dir/runtime.toml" <<EOF
[runtime]
default = "contract_verifier.smoke"

[providers.contract_verifier]
display-name = "Contract Completion Verifier"
protocol = "openai-compatible-http"
endpoint = "$provider_base_url"

[models.smoke]
api-name = "contract-verifier"
max-context = 32768
tools-support = true
streaming = false

[contract_verifier.smoke]
is-default = true
max-concurrent = 1
EOF

  cat >"$config_dir/oas-models.toml" <<EOF
[[providers]]
id = "contract_verifier"
kind = "openai_compat"
base_url = "$provider_base_url"
request_path = "/chat/completions"
api_key_env = "MASC_CONTRACT_VERIFIER_API_KEY"
default_model = "contract-verifier"
capabilities_base = "openai_chat"

[[models]]
# Pinned OAS (v0.212.x) lookup identity: provider-scoped rows key on
# (provider_name, bare id_prefix) with exact equality; the old
# "provider/model" qualified id_prefix is not a lookup key.
id_prefix = "contract-verifier"
base = "openai_chat"
provider_name = "contract_verifier"
max_context_tokens = 32768
max_output_tokens = 1024
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_response_format_json = true
supports_structured_output = true
supports_native_streaming = false
EOF
}

start_contract_verifier() {
  python3 \
    "$ROOT_DIR/scripts/harness/contract/openai_verifier_provider.py" \
    --port "$VERIFIER_PORT" \
    --log "$VERIFIER_LOG" \
    >"$VERIFIER_ERR" 2>&1 &
  VERIFIER_PID="$!"
  if ! harness_wait_for_health "$VERIFIER_PORT" 10; then
    echo "FAIL: contract verifier did not become healthy on port ${VERIFIER_PORT}" >&2
    harness_print_log_tail "$VERIFIER_ERR"
    return 1
  fi
}

verify_completion_verdict_round_trip() {
  if jq -s -e '
    ([.[] | select(.status == "accepted" and .phase == "verdict_call")] | length) == 1
    and
    ([.[] | select(.status == "accepted" and .phase == "tool_result")] | length) == 1
  ' "$VERIFIER_LOG" >/dev/null; then
    echo "  PASS: configured-LLM verdict tool-call round trip"
    return 0
  fi
  echo "FAIL: completion verifier did not observe exactly one verdict call and tool result" >&2
  harness_print_log_tail "$VERIFIER_LOG"
  return 1
}

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
    harness_print_log_tail "$VERIFIER_LOG"
    harness_print_log_tail "$VERIFIER_ERR"
    exit 1
  fi
}

echo "[bootstrap] server_exe=${SERVER_EXE}"
echo "[bootstrap] port=${PORT}"
echo "[bootstrap] base_path=${BASE_PATH}"
echo "[bootstrap] log_file=${LOG_FILE}"
echo "[bootstrap] mcp_url=${MCP_URL}"
echo "[bootstrap] verifier_url=http://127.0.0.1:${VERIFIER_PORT}/v1"

if ! build_server_exe; then
  exit 1
fi
echo "[bootstrap] server_exe=${SERVER_EXE}"
seed_contract_verifier_config
if ! start_contract_verifier; then
  exit 1
fi

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
verify_completion_verdict_round_trip
run_contract 3 4 "public_tool_live_sweep.sh"
run_contract 4 4 "scheduler_live_supported_contract.sh"

echo "PASS: contract harness suite"
