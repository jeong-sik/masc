#!/bin/bash
# MASC Benchmark Framework
# Usage: ./benchmark.sh [session|read|coordination|runtime|a2a|lock|all] [iterations]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MASC_URL="${MASC_URL:-http://127.0.0.1:8935/mcp}"
MASC_AGENT="${MASC_AGENT:-bench}"
MASC_TOKEN="${MASC_TOKEN:-}"
BENCH_ROOM_PATH="${BENCH_ROOM_PATH:-$ROOT_DIR}"
PATTERN="${1:-all}"
ITERATIONS="${2:-3}"
RESULTS_DIR="${SCRIPT_DIR}/results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BENCH_WARMUP_ITERATIONS="${BENCH_WARMUP_ITERATIONS:-1}"
BENCH_SESSION_WARMUP_ITERATIONS="${BENCH_SESSION_WARMUP_ITERATIONS:-0}"
BENCH_COMPARE_TO="${BENCH_COMPARE_TO:-latest}"
BENCH_COMPARE_MAX_ROWS="${BENCH_COMPARE_MAX_ROWS:-12}"

CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-25}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-1}"
CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"
MCP_URL="$MASC_URL"
MCP_SESSION_ID="${MCP_SESSION_ID:-}"
MCP_LAST_TIME_TOTAL=""
BENCH_LAST_MS=0
BENCH_LAST_PAYLOAD=""
BENCH_RPC_ID=100
RESULT_FILE="${RESULTS_DIR}/results_${TIMESTAMP}.csv"
META_FILE="${RESULTS_DIR}/results_${TIMESTAMP}.meta.json"
DIFF_FILE="${RESULTS_DIR}/results_${TIMESTAMP}.diff.txt"
COMPARE_BASELINE_FILE=""

export MCP_URL
export MCP_SESSION_ID
export CURL_TIMEOUT_SEC
export CURL_RETRY_COUNT
export CURL_RETRY_DELAY_SEC

# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

mkdir -p "$RESULTS_DIR"

log() { printf '[BENCH] %s\n' "$1"; }
error() { printf '[ERROR] %s\n' "$1" >&2; }

require_nonnegative_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    error "${name} must be a non-negative integer: ${value}"
    exit 1
  fi
}

require_positive_int() {
  local name="$1"
  local value="$2"
  require_nonnegative_int "$name" "$value"
  if (( value < 1 )); then
    error "${name} must be >= 1: ${value}"
    exit 1
  fi
}

require_positive_int "ITERATIONS" "$ITERATIONS"
require_nonnegative_int "BENCH_WARMUP_ITERATIONS" "$BENCH_WARMUP_ITERATIONS"
require_nonnegative_int "BENCH_SESSION_WARMUP_ITERATIONS" "$BENCH_SESSION_WARMUP_ITERATIONS"
require_positive_int "BENCH_COMPARE_MAX_ROWS" "$BENCH_COMPARE_MAX_ROWS"

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

  headers_file="$(mktemp "${TMPDIR:-/tmp}/masc-benchmark-init-header.XXXXXX")"
  body_file="$(mktemp "${TMPDIR:-/tmp}/masc-benchmark-init-body.XXXXXX")"
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
    error "failed to initialize MCP session"
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
  payload_file="$(mktemp "${TMPDIR:-/tmp}/masc-benchmark-payload.XXXXXX")"
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

stats_csv() {
  python3 - "$@" <<'PY'
import math, sys
values = [int(v) for v in sys.argv[1:]]
if not values:
    print("0,0,0,0")
    raise SystemExit(0)
values.sort()
def pct(p):
    idx = int(math.floor(p * max(0, len(values) - 1)))
    return values[idx]
avg = int(round(sum(values) / len(values)))
print(f"{avg},{pct(0.50)},{pct(0.95)},{values[-1]}")
PY
}

append_row() {
  local benchmark="$1"
  local notes="$2"
  shift 2
  local stats
  stats="$(stats_csv "$@")"
  IFS=',' read -r avg p50 p95 max <<< "$stats"
  printf '%s,%s,%s,%s,%s,%s\n' "$benchmark" "$avg" "$p50" "$p95" "$max" "$notes" >>"$RESULT_FILE"
  log "${benchmark}: avg=${avg}ms p50=${p50}ms p95=${p95}ms max=${max}ms ${notes}"
}

warmup_initialize() {
  local count="${1:-0}"
  local i
  for ((i = 0; i < count; i += 1)); do
    bench_initialize_session
    MCP_SESSION_ID=""
    export MCP_SESSION_ID
  done
}

warmup_tool_calls() {
  local tool_name="$1"
  local args_json="$2"
  local count="${3:-0}"
  local i
  for ((i = 0; i < count; i += 1)); do
    bench_call_tool "$tool_name" "$args_json" >/dev/null
  done
}

find_compare_baseline() {
  local candidate
  case "$BENCH_COMPARE_TO" in
    ""|none)
      return 1
      ;;
    latest)
      while IFS= read -r candidate; do
        if [[ "$candidate" != "$RESULT_FILE" ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done < <(ls -1t "${RESULTS_DIR}"/results_*.csv 2>/dev/null || true)
      return 1
      ;;
    *)
      if [[ -f "$BENCH_COMPARE_TO" ]]; then
        printf '%s\n' "$BENCH_COMPARE_TO"
        return 0
      fi
      error "compare baseline not found: $BENCH_COMPARE_TO"
      return 1
      ;;
  esac
}

write_metadata() {
  jq -n \
    --arg benchmark_pattern "$PATTERN" \
    --arg timestamp "$TIMESTAMP" \
    --arg started_at "$RUN_STARTED_AT" \
    --arg endpoint_url "$MASC_URL" \
    --arg bench_room_path "$BENCH_ROOM_PATH" \
    --arg compare_to "$BENCH_COMPARE_TO" \
    --arg compare_baseline_file "$COMPARE_BASELINE_FILE" \
    --arg result_file "$RESULT_FILE" \
    --arg diff_file "$DIFF_FILE" \
    --argjson iterations "$ITERATIONS" \
    --argjson warmup_iterations "$BENCH_WARMUP_ITERATIONS" \
    --argjson session_warmup_iterations "$BENCH_SESSION_WARMUP_ITERATIONS" \
    '{
      pattern: $benchmark_pattern,
      timestamp: $timestamp,
      started_at: $started_at,
      endpoint_url: $endpoint_url,
      room_path: $bench_room_path,
      iterations: $iterations,
      warmup_iterations: $warmup_iterations,
      session_warmup_iterations: $session_warmup_iterations,
      result_file: $result_file,
      compare_to: $compare_to,
      compare_baseline_file: (if $compare_baseline_file == "" then null else $compare_baseline_file end),
      diff_file: (if $compare_baseline_file == "" then null else $diff_file end)
    }' >"$META_FILE"
}

write_compare_report() {
  local baseline_file="$1"
  python3 - "$baseline_file" "$RESULT_FILE" "$BENCH_COMPARE_MAX_ROWS" >"$DIFF_FILE" <<'PY'
import csv
import math
import pathlib
import sys

baseline_path = pathlib.Path(sys.argv[1])
current_path = pathlib.Path(sys.argv[2])
max_rows = int(sys.argv[3])

def read_csv(path):
    with path.open() as f:
        rows = list(csv.DictReader(f))
    by_name = {}
    for row in rows:
        by_name[row["benchmark"]] = row
    return by_name

baseline = read_csv(baseline_path)
current = read_csv(current_path)

metrics = ["avg_ms", "p50_ms", "p95_ms", "max_ms"]

def pct(delta, old):
    if old == 0:
        return None
    return (delta / old) * 100.0

def verdict(avg_delta, p95_delta):
    if (avg_delta > 0 and p95_delta < 0) or (avg_delta < 0 and p95_delta > 0):
        if abs(avg_delta) >= 50 or abs(p95_delta) >= 50:
            return "mixed"
    if avg_delta >= 50 and p95_delta >= 0:
        return "regressed"
    if p95_delta >= 50 and avg_delta >= 0:
        return "regressed"
    if avg_delta <= -50 and p95_delta <= 0:
        return "improved"
    if p95_delta <= -50 and avg_delta <= 0:
        return "improved"
    return "stable"

shared = []
for name in sorted(set(current) & set(baseline)):
    row_now = current[name]
    row_old = baseline[name]
    avg_now = int(row_now["avg_ms"])
    avg_old = int(row_old["avg_ms"])
    p95_now = int(row_now["p95_ms"])
    p95_old = int(row_old["p95_ms"])
    max_now = int(row_now["max_ms"])
    max_old = int(row_old["max_ms"])
    shared.append({
        "benchmark": name,
        "avg_delta": avg_now - avg_old,
        "avg_pct": pct(avg_now - avg_old, avg_old),
        "p95_delta": p95_now - p95_old,
        "p95_pct": pct(p95_now - p95_old, p95_old),
        "max_delta": max_now - max_old,
        "verdict": verdict(avg_now - avg_old, p95_now - p95_old),
    })

shared.sort(key=lambda row: (abs(row["p95_delta"]), abs(row["avg_delta"])), reverse=True)

def fmt_pct(value):
    if value is None:
        return "n/a"
    return f"{value:+.1f}%"

print(f"baseline={baseline_path}")
print(f"current={current_path}")
print("")
print("benchmark\tavg_delta_ms\tavg_delta_pct\tp95_delta_ms\tp95_delta_pct\tmax_delta_ms\tverdict")
for row in shared[:max_rows]:
    print(
        f'{row["benchmark"]}\t{row["avg_delta"]:+d}\t{fmt_pct(row["avg_pct"])}\t'
        f'{row["p95_delta"]:+d}\t{fmt_pct(row["p95_pct"])}\t{row["max_delta"]:+d}\t{row["verdict"]}'
    )

added = sorted(set(current) - set(baseline))
removed = sorted(set(baseline) - set(current))
if added:
    print("")
    print("added=" + ",".join(added))
if removed:
    print("removed=" + ",".join(removed))
PY
}

collect_initialize_samples() {
  local iterations="$1"
  local samples=()
  local i
  warmup_initialize "$BENCH_SESSION_WARMUP_ITERATIONS"
  for ((i = 0; i < iterations; i += 1)); do
    bench_initialize_session
    samples+=("$BENCH_LAST_MS")
    MCP_SESSION_ID=""
    export MCP_SESSION_ID
  done
  append_row "mcp_session_init" "initialize+initialized" "${samples[@]}"
}

collect_tool_samples() {
  local benchmark="$1"
  local tool_name="$2"
  local args_json="$3"
  local iterations="$4"
  local notes="${5:-}"
  local samples=()
  local i
  warmup_tool_calls "$tool_name" "$args_json" "$BENCH_WARMUP_ITERATIONS"
  for ((i = 0; i < iterations; i += 1)); do
    bench_call_tool "$tool_name" "$args_json" >/dev/null
    samples+=("$BENCH_LAST_MS")
  done
  append_row "$benchmark" "$notes" "${samples[@]}"
}

bench_read_path() {
  collect_tool_samples "mcp_read_status" "masc_status" '{}' "$ITERATIONS" "room status"
  collect_tool_samples "mcp_read_agents" "masc_agents" '{}' "$ITERATIONS" "agent details"
  collect_tool_samples "mcp_read_tasks" "masc_tasks" '{}' "$ITERATIONS" "active backlog"
  collect_tool_samples "mcp_read_messages" "masc_messages" '{"limit":5}' "$ITERATIONS" "recent room messages"
}

bench_coordination() {
  collect_tool_samples "mcp_coord_broadcast" "masc_broadcast" \
    "$(jq -cn --arg agent "$MASC_AGENT" '{agent_name:$agent,message:"benchmark",format:"compact"}')" \
    "$ITERATIONS" "joined agent write path"
}

bench_locking() {
  local lock_args
  local lock_samples=()
  local unlock_samples=()
  local i

  lock_args="$(jq -cn --arg agent "$MASC_AGENT" '{agent_name:$agent,file:"bench_lock.txt"}')"
  for ((i = 0; i < BENCH_WARMUP_ITERATIONS; i += 1)); do
    bench_call_tool "masc_lock" "$lock_args" >/dev/null
    bench_call_tool "masc_unlock" "$lock_args" >/dev/null
  done
  for ((i = 0; i < ITERATIONS; i += 1)); do
    bench_call_tool "masc_lock" "$lock_args" >/dev/null
    lock_samples+=("$BENCH_LAST_MS")
    bench_call_tool "masc_unlock" "$lock_args" >/dev/null
    unlock_samples+=("$BENCH_LAST_MS")
  done
  append_row "mcp_lock" "file lock acquire" "${lock_samples[@]}"
  append_row "mcp_unlock" "file lock release" "${unlock_samples[@]}"
}

bench_a2a() {
  :
}

bench_runtime() {
  local i
  local runtime_status_samples=()

  warmup_tool_calls "masc_runtime_verify" '{}' "$BENCH_WARMUP_ITERATIONS"
  for ((i = 0; i < ITERATIONS; i += 1)); do
    bench_call_tool "masc_runtime_verify" '{}' >/dev/null
    runtime_status_samples+=("$BENCH_LAST_MS")
  done
  append_row "oas_runtime_status" "runtime_verify" "${runtime_status_samples[@]}"
}

ensure_session_ready() {
  bench_initialize_session
  bench_bootstrap_agent
}

run_pattern() {
  case "$PATTERN" in
    all)
      collect_initialize_samples "$ITERATIONS"
      ensure_session_ready
      bench_read_path
      bench_coordination
      bench_locking
      bench_a2a
      bench_runtime
      ;;
    session)
      collect_initialize_samples "$ITERATIONS"
      ;;
    read)
      ensure_session_ready
      bench_read_path
      ;;
    coordination)
      ensure_session_ready
      bench_coordination
      ;;
    runtime)
      ensure_session_ready
      bench_runtime
      ;;
    a2a)
      ensure_session_ready
      bench_a2a
      ;;
    lock)
      ensure_session_ready
      bench_locking
      ;;
    *)
      error "Unknown pattern: $PATTERN"
      echo "Available: session, read, coordination, runtime, a2a, lock, all" >&2
      exit 1
      ;;
  esac
}

log "MASC Benchmark Suite"
log "URL: $MASC_URL"
log "Agent: $MASC_AGENT"
log "Room: $BENCH_ROOM_PATH"
log "Pattern: $PATTERN"
log "Iterations: $ITERATIONS"
log "Warmup iterations: $BENCH_WARMUP_ITERATIONS"
log "Session warmup iterations: $BENCH_SESSION_WARMUP_ITERATIONS"
log "Results: $RESULT_FILE"

printf 'benchmark,avg_ms,p50_ms,p95_ms,max_ms,notes\n' >"$RESULT_FILE"
trap bench_leave_agent EXIT

run_pattern
COMPARE_BASELINE_FILE="$(find_compare_baseline || true)"
write_metadata
if [[ -n "$COMPARE_BASELINE_FILE" ]]; then
  write_compare_report "$COMPARE_BASELINE_FILE"
fi

echo ""
log "Benchmark complete! Results saved to $RESULT_FILE"
log "Metadata saved to $META_FILE"
if [[ -n "$COMPARE_BASELINE_FILE" ]]; then
  log "Compared against $COMPARE_BASELINE_FILE"
  log "Diff report saved to $DIFF_FILE"
fi
echo ""
echo "=== Summary ==="
column -t -s ',' "$RESULT_FILE"
if [[ -n "$COMPARE_BASELINE_FILE" ]]; then
  echo ""
  echo "=== Diff vs Baseline ==="
  cat "$DIFF_FILE"
fi
