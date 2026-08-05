#!/bin/bash
# MASC Quick Benchmark
# Stateless MCP read/write baseline plus local runtime sample.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MASC_URL="${MASC_URL:-http://127.0.0.1:8935/mcp}"
MASC_AGENT="${MASC_AGENT:-bench}"
MASC_TOKEN="${MASC_TOKEN:-}"
BENCH_WORKSPACE_PATH="${BENCH_WORKSPACE_PATH:-$ROOT_DIR}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-5}"
BENCH_WARMUP_ITERATIONS="${BENCH_WARMUP_ITERATIONS:-0}"
CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-25}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-1}"
CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"
MCP_URL="$MASC_URL"
MCP_LAST_TIME_TOTAL=""
BENCH_LAST_MS=0
BENCH_LAST_PAYLOAD=""
BENCH_RPC_ID=100

export MCP_URL
export CURL_TIMEOUT_SEC
export CURL_RETRY_COUNT
export CURL_RETRY_DELAY_SEC

# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

require_nonnegative_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] ${name} must be a non-negative integer: ${value}" >&2
    exit 1
  fi
}

require_positive_int() {
  local name="$1"
  local value="$2"
  require_nonnegative_int "$name" "$value"
  if (( value < 1 )); then
    echo "[ERROR] ${name} must be >= 1: ${value}" >&2
    exit 1
  fi
}

require_positive_int "BENCH_ITERATIONS" "$BENCH_ITERATIONS"
require_nonnegative_int "BENCH_WARMUP_ITERATIONS" "$BENCH_WARMUP_ITERATIONS"

ms_from_seconds() {
  awk -v seconds="${1:-0}" 'BEGIN { printf "%.0f", seconds * 1000 }'
}

bench_discover() {
  local payload_file
  payload_file="$(mktemp "${TMPDIR:-/tmp}/masc-quick-bench-discover.XXXXXX")"
  mcp_jsonrpc_call 1 "server/discover" '{}' "$MASC_TOKEN" "$MCP_URL" >"$payload_file"
  BENCH_LAST_PAYLOAD="$(cat "$payload_file")"
  rm -f "$payload_file"
  mcp_require_jsonrpc_ok "$BENCH_LAST_PAYLOAD" "server/discover"
  printf '%s' "$BENCH_LAST_PAYLOAD" | jq -e '.result.resultType == "complete"' >/dev/null
  BENCH_LAST_MS="$(ms_from_seconds "${MCP_LAST_TIME_TOTAL:-0}")"
}

bench_call_tool() {
  local tool_name="$1"
  local args_json="$2"
  local payload_file

  BENCH_RPC_ID=$((BENCH_RPC_ID + 1))
  payload_file="$(mktemp "${TMPDIR:-/tmp}/masc-quick-bench-payload.XXXXXX")"
  mcp_call_tool \
    "$BENCH_RPC_ID" "$tool_name" "$args_json" "$MASC_TOKEN" "$MCP_URL" \
    >"$payload_file"
  BENCH_LAST_PAYLOAD="$(cat "$payload_file")"
  rm -f "$payload_file"
  mcp_require_tool_ok "$BENCH_LAST_PAYLOAD" "${tool_name}_checked"
  BENCH_LAST_MS="$(ms_from_seconds "${MCP_LAST_TIME_TOTAL:-0}")"
  printf '%s' "$BENCH_LAST_PAYLOAD"
}

bench_bootstrap_agent() {
  bench_call_tool "masc_start" "$(jq -cn --arg path "$BENCH_WORKSPACE_PATH" '{path:$path}')" >/dev/null
}

measure_avg() {
  local label="$1"
  local tool_name="$2"
  local args_json="$3"
  local iterations="${4:-5}"
  local i total max

  total=0
  max=0
  for ((i = 0; i < BENCH_WARMUP_ITERATIONS; i += 1)); do
    bench_call_tool "$tool_name" "$args_json" >/dev/null
  done
  for ((i = 0; i < iterations; i += 1)); do
    bench_call_tool "$tool_name" "$args_json" >/dev/null
    total=$((total + BENCH_LAST_MS))
    if ((BENCH_LAST_MS > max)); then
      max=$BENCH_LAST_MS
    fi
  done

  printf "%-28s %5dms avg (%d runs, max %dms)\n" \
    "$label" "$((total / iterations))" "$iterations" "$max"
}

echo "=== MASC Quick Benchmark ==="
echo "URL: $MASC_URL"
echo "Agent: $MASC_AGENT"
echo "Workspace: $BENCH_WORKSPACE_PATH"
echo "Iterations: $BENCH_ITERATIONS"
echo "Warmup iterations: $BENCH_WARMUP_ITERATIONS"
echo ""

bench_discover

echo "Operation                     Latency"
echo "──────────────────────────────────────────────"
printf "%-28s %5dms\n" "mcp_server_discover" "$BENCH_LAST_MS"

bench_bootstrap_agent
printf "%-28s %5dms\n" "masc_start" "$BENCH_LAST_MS"

measure_avg "masc_status" "masc_status" '{}' "$BENCH_ITERATIONS"
measure_avg "masc_agents" "masc_agents" '{}' "$BENCH_ITERATIONS"
measure_avg "masc_tasks" "masc_tasks" '{}' "$BENCH_ITERATIONS"
measure_avg "masc_messages (5)" "masc_messages" '{"limit":5}' "$BENCH_ITERATIONS"
measure_avg "masc_broadcast" "masc_broadcast" "$(jq -cn --arg agent "$MASC_AGENT" '{agent_name:$agent,message:"quick-bench",format:"compact"}')" "$BENCH_ITERATIONS"
measure_avg "masc_runtime_verify" "masc_runtime_verify" '{}' "$BENCH_ITERATIONS"

echo ""
echo "=== Benchmark Complete ==="
