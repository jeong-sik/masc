#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SMOKE_SCRIPT="$ROOT_DIR/scripts/harness/workload/team_session_local64_smoke.sh"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8945/mcp}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"
COORD_AGENT="${COORD_AGENT:-team-session-local64-soak}"
WORKER_COUNT="${WORKER_COUNT:-8}"
ROUNDS="${ROUNDS:-10}"
SESSION_DURATION_SEC="${SESSION_DURATION_SEC:-900}"
SPAWN_TIMEOUT_SEC="${SPAWN_TIMEOUT_SEC:-}"
WAIT_AFTER_SPAWN_SEC="${WAIT_AFTER_SPAWN_SEC:-3}"
SETTLE_AFTER_ROUND_SEC="${SETTLE_AFTER_ROUND_SEC:-15}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-120}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-}"
LOCAL64_ROUTER_MODE="${LOCAL64_ROUTER_MODE:-hybrid}"
RSS_MAX_DELTA_KB="${LOCAL64_SOAK_RSS_MAX_DELTA_KB:-153600}"
RSS_MAX_DELTA_RATIO="${LOCAL64_SOAK_RSS_MAX_DELTA_RATIO:-1.2}"
METRICS_FILE="${LOCAL64_SOAK_METRICS_FILE:-${MASC_LOCAL64_BASE_PATH:-${TMPDIR:-/tmp}}/local64-soak-metrics.jsonl}"

if [ ! -f "$SMOKE_SCRIPT" ]; then
  echo "Missing smoke workload: $SMOKE_SCRIPT" >&2
  exit 1
fi

mkdir -p "$(dirname "$METRICS_FILE")"

sample_running_session_count() {
  local raw
  raw="$(mcp_call_tool 92001 "masc_team_session_list" '{"status":"running","limit":200}')"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | mcp_extract_result | jq -r '.count // 0'
}

sample_allocated_slots() {
  local raw
  raw="$(mcp_call_tool 92002 "masc_llama_runtime_status" '{"include_models":false}')"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | mcp_extract_result | jq -r '.allocated_slots // 0'
}

sample_zombie_cleanup_text() {
  local raw
  raw="$(mcp_call_tool 92003 "masc_cleanup_zombies" '{}')"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | mcp_extract_text
}

sample_rss_kb() {
  local pid="${MASC_LOCAL64_SERVER_PID:-}"
  if [ -z "$pid" ] || ! command -v ps >/dev/null 2>&1; then
    return 0
  fi
  if ! ps -p "$pid" >/dev/null 2>&1; then
    return 0
  fi
  ps -o rss= -p "$pid" | awk '{print $1}'
}

record_metric() {
  local payload="$1"
  printf '%s\n' "$payload" >>"$METRICS_FILE"
}

baseline_running_sessions="$(sample_running_session_count)"
baseline_allocated_slots="$(sample_allocated_slots)"
baseline_rss_kb="$(sample_rss_kb)"
peak_rss_kb="${baseline_rss_kb:-0}"

record_metric "$(jq -cn \
  --arg kind "baseline" \
  --argjson running "$baseline_running_sessions" \
  --argjson slots "$baseline_allocated_slots" \
  --argjson rss "${baseline_rss_kb:-null}" \
  '{kind:$kind,running_sessions:$running,allocated_slots:$slots,rss_kb:$rss}')"

success=0
for round in $(seq 1 "$ROUNDS"); do
  echo "[soak] round=$round/$ROUNDS"
  round_log="$(mcp_mktemp_file "local64-soak-round.${round}" ".log")"
  if MCP_URL="$MCP_URL" \
    COORD_AGENT="${COORD_AGENT}-r${round}" \
    WORKER_COUNT="$WORKER_COUNT" \
    SESSION_DURATION_SEC="$SESSION_DURATION_SEC" \
    SPAWN_TIMEOUT_SEC="$SPAWN_TIMEOUT_SEC" \
    WAIT_AFTER_SPAWN_SEC="$WAIT_AFTER_SPAWN_SEC" \
    GOAL="Repeated local64 smoke round ${round}/${ROUNDS}" \
    LLAMA_SWARM_MODEL="$LLAMA_SWARM_MODEL" \
    LOCAL64_ROUTER_MODE="$LOCAL64_ROUTER_MODE" \
    bash "$SMOKE_SCRIPT" >"$round_log" 2>&1; then
    session_id="$(rg -o 'session=[^ ]+' "$round_log" | tail -n1 | cut -d= -f2)"
    sleep "$SETTLE_AFTER_ROUND_SEC"
    running_sessions="$(sample_running_session_count)"
    allocated_slots="$(sample_allocated_slots)"
    zombie_cleanup_text="$(sample_zombie_cleanup_text)"
    rss_kb="$(sample_rss_kb)"
    if [ -n "${rss_kb:-}" ] && [ "$rss_kb" -gt "${peak_rss_kb:-0}" ]; then
      peak_rss_kb="$rss_kb"
    fi
    record_metric "$(jq -cn \
      --arg kind "round" \
      --argjson round "$round" \
      --arg session_id "${session_id:-unknown}" \
      --argjson running "$running_sessions" \
      --argjson slots "$allocated_slots" \
      --arg zombie_cleanup "$zombie_cleanup_text" \
      --argjson rss "${rss_kb:-null}" \
      '{kind:$kind,round:$round,session_id:$session_id,running_sessions:$running,allocated_slots:$slots,zombie_cleanup:$zombie_cleanup,rss_kb:$rss}')"
    if [ "$running_sessions" -ne "$baseline_running_sessions" ]; then
      echo "FAIL: local64 soak running session count drifted after round $round (baseline=$baseline_running_sessions current=$running_sessions)" >&2
      exit 1
    fi
    if [ "$allocated_slots" -ne "$baseline_allocated_slots" ]; then
      echo "FAIL: local64 soak allocated_slots drifted after round $round (baseline=$baseline_allocated_slots current=$allocated_slots)" >&2
      exit 1
    fi
    if [[ "$zombie_cleanup_text" != *"No zombie"* ]]; then
      echo "FAIL: local64 soak found zombie cleanup drift after round $round: $zombie_cleanup_text" >&2
      exit 1
    fi
    printf '[soak] round=%s pass session=%s running=%s slots=%s rss_kb=%s\n' \
      "$round" "${session_id:-unknown}" "$running_sessions" "$allocated_slots" "${rss_kb:-n/a}"
    success=$((success + 1))
  else
    cat "$round_log" >&2 || true
    echo "FAIL: local64 soak round $round/$ROUNDS failed" >&2
    exit 1
  fi
done

final_running_sessions="$(sample_running_session_count)"
final_allocated_slots="$(sample_allocated_slots)"
final_zombie_cleanup="$(sample_zombie_cleanup_text)"
final_rss_kb="$(sample_rss_kb)"

record_metric "$(jq -cn \
  --arg kind "final" \
  --argjson rounds "$ROUNDS" \
  --argjson success "$success" \
  --argjson baseline_running "$baseline_running_sessions" \
  --argjson baseline_slots "$baseline_allocated_slots" \
  --argjson final_running "$final_running_sessions" \
  --argjson final_slots "$final_allocated_slots" \
  --arg zombie_cleanup "$final_zombie_cleanup" \
  --argjson baseline_rss "${baseline_rss_kb:-null}" \
  --argjson final_rss "${final_rss_kb:-null}" \
  --argjson peak_rss "${peak_rss_kb:-null}" \
  '{kind:$kind,rounds:$rounds,success:$success,baseline_running_sessions:$baseline_running,baseline_allocated_slots:$baseline_slots,final_running_sessions:$final_running,final_allocated_slots:$final_slots,zombie_cleanup:$zombie_cleanup,baseline_rss_kb:$baseline_rss,final_rss_kb:$final_rss,peak_rss_kb:$peak_rss}')"

if [ "$final_running_sessions" -ne "$baseline_running_sessions" ]; then
  echo "FAIL: final running session count drifted (baseline=$baseline_running_sessions current=$final_running_sessions)" >&2
  exit 1
fi
if [ "$final_allocated_slots" -ne "$baseline_allocated_slots" ]; then
  echo "FAIL: final allocated_slots drifted (baseline=$baseline_allocated_slots current=$final_allocated_slots)" >&2
  exit 1
fi
if [[ "$final_zombie_cleanup" != *"No zombie"* ]]; then
  echo "FAIL: final zombie cleanup detected drift: $final_zombie_cleanup" >&2
  exit 1
fi

if [ -n "${baseline_rss_kb:-}" ] && [ -n "${final_rss_kb:-}" ] && [ "$baseline_rss_kb" -gt 0 ]; then
  rss_delta_kb=$((final_rss_kb - baseline_rss_kb))
  rss_limit_kb="$(awk -v base="$baseline_rss_kb" -v ratio="$RSS_MAX_DELTA_RATIO" 'BEGIN { printf "%.0f", base * (ratio - 1.0) }')"
  if [ "$rss_delta_kb" -gt "$RSS_MAX_DELTA_KB" ] && [ "$rss_delta_kb" -gt "$rss_limit_kb" ]; then
    echo "FAIL: RSS drift exceeded threshold (baseline=${baseline_rss_kb}KB final=${final_rss_kb}KB delta=${rss_delta_kb}KB)" >&2
    exit 1
  fi
fi

echo "PASS: local64 soak rounds=${ROUNDS} workers=${WORKER_COUNT} success=${success} metrics=${METRICS_FILE}"
