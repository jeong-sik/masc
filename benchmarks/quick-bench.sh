#!/bin/bash
# MASC Quick Benchmark
# Session-aware MCP read/write baseline plus local runtime sample.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MASC_URL="${MASC_URL:-http://127.0.0.1:8935/mcp}"
MASC_AGENT="${MASC_AGENT:-bench}"
MASC_TOKEN="${MASC_TOKEN:-}"
BENCH_ROOM_PATH="${BENCH_ROOM_PATH:-$ROOT_DIR}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-5}"
BENCH_WARMUP_ITERATIONS="${BENCH_WARMUP_ITERATIONS:-0}"
CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-25}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-1}"
CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"
MCP_URL="$MASC_URL"
MCP_SESSION_ID="${MCP_SESSION_ID:-}"
MCP_LAST_TIME_TOTAL=""
BENCH_LAST_MS=0
BENCH_LAST_PAYLOAD=""
BENCH_RPC_ID=100

export MCP_URL
export MCP_SESSION_ID
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

curl_auth_args() {
  if [[ -n "$MASC_TOKEN" ]]; then
    printf '%s\n' "-H" "Authorization: Bearer $MASC_TOKEN"
  fi
}

bench_initialize_session() {
  local headers_file body_file init_time notify_time total_time client_name
  local -a auth_args=()
  local -a init_cmd=()
  local -a notify_cmd=()

  while IFS= read -r line; do
    auth_args+=("$line")
  done < <(curl_auth_args)

  headers_file="$(mktemp "${TMPDIR:-/tmp}/masc-quick-bench-init-header.XXXXXX")"
  body_file="$(mktemp "${TMPDIR:-/tmp}/masc-quick-bench-init-body.XXXXXX")"
  client_name="${MCP_CLIENT_NAME:-$MASC_AGENT}"

  init_cmd=(
    curl -sS --max-time "$CURL_TIMEOUT_SEC"
    -D "$headers_file"
    -o "$body_file"
    -w '%{time_total}'
    -X POST "$MCP_URL"
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream'
  )
  if ((${#auth_args[@]} > 0)); then
    init_cmd+=("${auth_args[@]}")
  fi
  init_cmd+=(
    -d "$(jq -cn --arg agent "$client_name" '{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2025-11-25",
            clientInfo: {name: $agent, version: "1.0"},
            capabilities: {}
          }
        }')"
  )
  init_time="$("${init_cmd[@]}")"

  MCP_SESSION_ID="$(
    awk '
      tolower($0) ~ /^mcp-session-id:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        sub(/\r$/, "", $0)
        print $0
        exit
      }
    ' "$headers_file"
  )"
  export MCP_SESSION_ID

  if [[ -z "$MCP_SESSION_ID" ]]; then
    cat "$body_file" >&2 || true
    rm -f "$headers_file" "$body_file"
    echo "failed to initialize MCP session" >&2
    return 1
  fi

  notify_cmd=(
    curl -sS --max-time "$CURL_TIMEOUT_SEC"
    -o /dev/null
    -w '%{time_total}'
    -X POST "$MCP_URL"
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream'
    -H "Mcp-Session-Id: $MCP_SESSION_ID"
  )
  if ((${#auth_args[@]} > 0)); then
    notify_cmd+=("${auth_args[@]}")
  fi
  notify_cmd+=(-d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}')
  notify_time="$("${notify_cmd[@]}")"

  total_time="$(awk -v init="${init_time:-0}" -v notify="${notify_time:-0}" 'BEGIN { printf "%.6f", init + notify }')"
  MCP_LAST_TIME_TOTAL="$total_time"
  BENCH_LAST_MS="$(ms_from_seconds "$total_time")"

  rm -f "$headers_file" "$body_file"
}

bench_call_tool() {
  local tool_name="$1"
  local args_json="$2"
  local payload_file

  BENCH_RPC_ID=$((BENCH_RPC_ID + 1))
  payload_file="$(mktemp "${TMPDIR:-/tmp}/masc-quick-bench-payload.XXXXXX")"
  mcp_call_tool \
    "$BENCH_RPC_ID" "$tool_name" "$args_json" "$MCP_SESSION_ID" "$MASC_TOKEN" "$MCP_URL" \
    >"$payload_file"
  BENCH_LAST_PAYLOAD="$(cat "$payload_file")"
  rm -f "$payload_file"
  mcp_require_tool_ok "$BENCH_LAST_PAYLOAD" "${tool_name}_checked"
  BENCH_LAST_MS="$(ms_from_seconds "${MCP_LAST_TIME_TOTAL:-0}")"
  printf '%s' "$BENCH_LAST_PAYLOAD"
}

bench_bootstrap_agent() {
  bench_call_tool "masc_start" "$(jq -cn --arg path "$BENCH_ROOM_PATH" '{path:$path}')" >/dev/null
}

bench_leave_agent() {
  if [[ -n "$MCP_SESSION_ID" ]]; then
    bench_call_tool "masc_leave" "$(jq -cn --arg agent "$MASC_AGENT" '{agent_name:$agent}')" >/dev/null 2>&1 || true
  fi
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

measure_lock_cycle() {
  local iterations="${1:-5}"
  local i lock_total lock_max unlock_total unlock_max
  local lock_args

  lock_total=0
  lock_max=0
  unlock_total=0
  unlock_max=0
  lock_args="$(jq -cn --arg agent "$MASC_AGENT" '{agent_name:$agent,file:"bench_quick_lock.txt"}')"

  for ((i = 0; i < BENCH_WARMUP_ITERATIONS; i += 1)); do
    bench_call_tool "masc_lock" "$lock_args" >/dev/null
    bench_call_tool "masc_unlock" "$lock_args" >/dev/null
  done
  for ((i = 0; i < iterations; i += 1)); do
    bench_call_tool "masc_lock" "$lock_args" >/dev/null
    lock_total=$((lock_total + BENCH_LAST_MS))
    if ((BENCH_LAST_MS > lock_max)); then
      lock_max=$BENCH_LAST_MS
    fi
    bench_call_tool "masc_unlock" "$lock_args" >/dev/null
    unlock_total=$((unlock_total + BENCH_LAST_MS))
    if ((BENCH_LAST_MS > unlock_max)); then
      unlock_max=$BENCH_LAST_MS
    fi
  done

  printf "%-28s %5dms avg (%d runs, max %dms)\n" \
    "masc_lock" "$((lock_total / iterations))" "$iterations" "$lock_max"
  printf "%-28s %5dms avg (%d runs, max %dms)\n" \
    "masc_unlock" "$((unlock_total / iterations))" "$iterations" "$unlock_max"
}

echo "=== MASC Quick Benchmark ==="
echo "URL: $MASC_URL"
echo "Agent: $MASC_AGENT"
echo "Room: $BENCH_ROOM_PATH"
echo "Iterations: $BENCH_ITERATIONS"
echo "Warmup iterations: $BENCH_WARMUP_ITERATIONS"
echo ""

bench_initialize_session
trap bench_leave_agent EXIT

echo "Operation                     Latency"
echo "──────────────────────────────────────────────"
printf "%-28s %5dms\n" "mcp_session_init" "$BENCH_LAST_MS"

bench_bootstrap_agent
printf "%-28s %5dms\n" "masc_start" "$BENCH_LAST_MS"

measure_avg "masc_status" "masc_status" '{}' "$BENCH_ITERATIONS"
measure_avg "masc_agents" "masc_agents" '{}' "$BENCH_ITERATIONS"
measure_avg "masc_tasks" "masc_tasks" '{}' "$BENCH_ITERATIONS"
measure_avg "masc_messages (5)" "masc_messages" '{"limit":5}' "$BENCH_ITERATIONS"
measure_avg "masc_broadcast" "masc_broadcast" "$(jq -cn --arg agent "$MASC_AGENT" '{agent_name:$agent,message:"quick-bench",format:"compact"}')" "$BENCH_ITERATIONS"
measure_lock_cycle "$BENCH_ITERATIONS"
measure_avg "masc_runtime_verify" "masc_runtime_verify" '{}' "$BENCH_ITERATIONS"

echo ""
echo "=== Benchmark Complete ==="
