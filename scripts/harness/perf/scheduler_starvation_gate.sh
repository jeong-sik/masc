#!/usr/bin/env bash
# scheduler_starvation_gate.sh — Mode A: reproduce and gate main-Eio-domain scheduler starvation.
#
# What it measures
#   MASC serves HTTP from a single main Eio domain that also carries every keeper fiber and the
#   refresh loops. Under host CPU contention the OS deschedules that one thread, so trivial
#   endpoints spike to 0.5-18s while the process itself sits at 12-27% CPU (waiting, not computing).
#   The existing evidence for this was observational (latency happened to track host load across
#   ad-hoc runs). This harness makes it deterministic: it injects a known number of CPU hogs and
#   measures trivial-endpoint TTFB as a function of that load.
#
# Gate semantics (falsifiable, CLAUDE.md TLA+ bug-model discipline)
#   The gate asserts the trivial endpoint stays responsive under load:
#     trivial p95 under max load <= THRESHOLD_MS   AND   amplification <= MAX_AMP
#   On UNFIXED main this is expected to FAIL (exit 2 = STARVED) — that failure is the proof the
#   gate catches the defect. After a fix (launchd QoS ProcessType=Interactive, or domain_pool
#   core-budget recommended-2 to reserve a core for the scheduler domain) re-run; it should PASS.
#   A gate that passes on current main is too weak and must be tightened.
#
# Exit codes
#   0  GREEN  — no starvation detected (desired post-fix state)
#   2  RED    — starvation detected (expected on current unfixed main)
#   1  ERROR  — harness failure (server did not boot, missing tools, bad args)
#
# Root-cause reference: docs/rfc/RFC-0204-dashboard-serving-isolation.md + adversarial diagnosis.
# This script changes no production code; it is measurement infrastructure only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/harness/lib/server_bootstrap.sh"

# ---- configuration (env-overridable) ----------------------------------------
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
PROBE_ENDPOINT="${PROBE_ENDPOINT:-/health}"   # trivial, lock-free, no keeper/provider work
PROBES="${PROBES:-40}"                         # probes per load level
WARMUP_PROBES="${WARMUP_PROBES:-10}"           # discarded warmup probes at level 0
PROBE_MAX_SEC="${PROBE_MAX_SEC:-20}"           # per-probe ceiling; a timeout counts as this value
LOAD_SETTLE_SEC="${LOAD_SETTLE_SEC:-2}"        # let injected load ramp before probing
THRESHOLD_MS="${THRESHOLD_MS:-250}"            # max acceptable trivial p95 under load
MAX_AMP="${MAX_AMP:-8}"                         # max acceptable p95(loaded)/p95(baseline)
# Hog levels to sweep. Default: idle, half, ncpu-1 (1 free core), ncpu (no free core).
DEFAULT_LEVELS="0 $((NCPU/2)) $((NCPU-1)) ${NCPU}"
HOG_LEVELS="${HOG_LEVELS:-$DEFAULT_LEVELS}"

# In-process load: background request loops that keep the single main Eio domain BUSY
# during the loaded levels. An idle server is not starvation-sensitive to host hogs alone
# (the main thread has nothing queued, so it is scheduled promptly). Production red arises
# when the main domain is busy (keepers + dashboard) AND host-contended. INPROC_LOAD>0
# approximates the "busy" axis without a live keeper fleet.
INPROC_LOAD="${INPROC_LOAD:-0}"
LOAD_ENDPOINT="${LOAD_ENDPOINT:-/api/v1/dashboard/execution}"
# Production browsers send Accept-Encoding, so the server runs its serialize+compress
# path (Response.json -> compress_body). Bare curl sends no Accept-Encoding, so
# compress_body short-circuits (accepts_zstd_header=false) and the harness underweights
# the main-domain response-finalisation cost this gate exists to measure. Send it by
# default to match production; set LOAD_ACCEPT_ENCODING="" to restore the bare-curl path.
LOAD_ACCEPT_ENCODING="${LOAD_ACCEPT_ENCODING:-zstd}"

# Attach mode: if BASE_URL is given, probe an already-running server (e.g. the live runtime)
# instead of booting an ephemeral one. Booting is the default and is fully self-contained.
BASE_URL="${MASC_HARNESS_BASE_URL:-}"
KEEP_SERVER="${KEEP_SERVER:-0}"

RUN_ID="${RUN_ID:-starvation-$(date +%Y%m%d_%H%M%S)-$$}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/perf-starvation/$RUN_ID}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
  --endpoint PATH      trivial endpoint to probe (default: $PROBE_ENDPOINT)
  --probes N           probes per load level (default: $PROBES)
  --levels "0 8 15 16" hog counts to sweep (default: "$HOG_LEVELS")
  --threshold-ms N     max trivial p95 under load before RED (default: $THRESHOLD_MS)
  --max-amp N          max p95 amplification before RED (default: $MAX_AMP)
  --base-url URL       probe an existing server instead of booting one
  --keep-server        do not stop the booted server on exit
  -h|--help            this help
Environment overrides mirror the flags (PROBE_ENDPOINT, PROBES, HOG_LEVELS, THRESHOLD_MS, ...).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) PROBE_ENDPOINT="$2"; shift 2 ;;
    --probes) PROBES="$2"; shift 2 ;;
    --levels) HOG_LEVELS="$2"; shift 2 ;;
    --threshold-ms) THRESHOLD_MS="$2"; shift 2 ;;
    --max-amp) MAX_AMP="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --inproc-load) INPROC_LOAD="$2"; shift 2 ;;
    --load-endpoint) LOAD_ENDPOINT="$2"; shift 2 ;;
    --keep-server) KEEP_SERVER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

for tool in curl jq awk sort sysctl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $tool" >&2; exit 1; }
done

mkdir -p "$RUN_DIR"
CSV_FILE="$RUN_DIR/levels.csv"
SUMMARY_FILE="$RUN_DIR/summary.json"
SERVER_LOG="$RUN_DIR/server.log"
CURL_ERROR_FILE="$RUN_DIR/curl_errors.log"
echo "level_hogs,probes,p50_ms,p95_ms,max_ms,timeouts" > "$CSV_FILE"

HOG_PIDS=()
INPROC_PIDS=()
SERVER_PID=""

cleanup() {
  kill_inproc_load
  kill_hogs
  if [[ -n "$SERVER_PID" && "$KEEP_SERVER" != "1" ]]; then
    harness_stop_server "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

spawn_hogs() {
  local n="$1" i
  HOG_PIDS=()
  for ((i = 0; i < n; i++)); do
    yes > /dev/null 2>&1 &
    HOG_PIDS+=("$!")
  done
}

kill_hogs() {
  if [[ ${#HOG_PIDS[@]} -gt 0 ]]; then
    kill "${HOG_PIDS[@]}" 2>/dev/null || true
    wait "${HOG_PIDS[@]}" 2>/dev/null || true
  fi
  HOG_PIDS=()
}

spawn_inproc_load() {
  local n="$1" url="$2" i
  INPROC_PIDS=()
  for ((i = 0; i < n; i++)); do
    ( while true; do curl -sS -o /dev/null ${LOAD_ACCEPT_ENCODING:+-H Accept-Encoding:$LOAD_ACCEPT_ENCODING} --max-time 5 "$url" 2>/dev/null || true; done ) &
    INPROC_PIDS+=("$!")
    disown 2>/dev/null || true   # stop job-control tracking so kill is quiet
  done
}

kill_inproc_load() {
  if [[ ${#INPROC_PIDS[@]} -gt 0 ]]; then
    # Kill the loop subshells and any curl children they spawned. Disowned, so no wait.
    local pid
    for pid in "${INPROC_PIDS[@]}"; do
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    done
  fi
  INPROC_PIDS=()
}

# One probe -> prints TTFB in seconds (a timeout/failure prints PROBE_MAX_SEC).
probe_once() {
  local url="$1" t
  if ! t="$(curl -sS -o /dev/null -w '%{time_starttransfer}' --max-time "$PROBE_MAX_SEC" "$url" 2>>"$CURL_ERROR_FILE")"; then
    printf '%s\n' "$PROBE_MAX_SEC"
    return
  fi
  awk -v v="$t" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/) }' \
    || t="$PROBE_MAX_SEC"
  printf '%s\n' "$t"
}

# Run $PROBES probes, write per-probe seconds to $1, echo "p50_ms p95_ms max_ms timeouts".
measure_level() {
  local out_file="$1" url="$2" i t timeouts=0
  : > "$out_file"
  for ((i = 0; i < PROBES; i++)); do
    t="$(probe_once "$url")"
    awk -v v="$t" -v m="$PROBE_MAX_SEC" 'BEGIN{ exit !(v+0 >= m+0) }' && timeouts=$((timeouts + 1))
    printf '%s\n' "$t" >> "$out_file"
  done
  local stats
  stats="$(sort -n "$out_file" | awk '
    { v[NR] = $1 }
    END {
      n = NR
      if (n == 0) { print "0.000 0.000 0.000"; exit }
      i50 = int((n - 1) * 0.50) + 1
      i95 = int((n - 1) * 0.95) + 1
      printf "%.3f %.3f %.3f", v[i50] * 1000, v[i95] * 1000, v[n] * 1000
    }')"
  printf '%s %s\n' "$stats" "$timeouts"
}

# ---- server -----------------------------------------------------------------
if [[ -z "$BASE_URL" ]]; then
  # MASC_HARNESS_SERVER_EXE pins a specific binary (e.g. an A/B-saved exe) so two
  # builds can be compared without overwriting _build between runs.
  SERVER_EXE="$(harness_find_server_exe "$REPO_ROOT" "${MASC_HARNESS_SERVER_EXE:-}")" || {
    echo "ERROR: no server executable; build ./bin/main_eio.exe first" >&2; exit 1; }
  PORT="${PORT:-$(harness_pick_free_port)}"
  BASE_PATH="$(harness_mktemp_dir "masc-starvation-base")"
  # Pre-seed the canonical runtime.toml so the strict OAS capability gate
  # (Runtime.init_default_strict, server_runtime_bootstrap.ml:641) accepts boot.
  # harness_seed_server_config writes runtime.toml only when absent, so seeding it
  # here overrides the lib's placeholder "smoke" model (which is not in the catalog).
  if [[ -f "$REPO_ROOT/config/runtime.toml" ]]; then
    mkdir -p "$BASE_PATH/.masc/config"
    cp "$REPO_ROOT/config/runtime.toml" "$BASE_PATH/.masc/config/runtime.toml"
  fi
  echo "[harness] booting server exe=$SERVER_EXE port=$PORT base=$BASE_PATH" >&2
  SERVER_PID="$(harness_start_server "$SERVER_EXE" "$PORT" "$BASE_PATH" "$SERVER_LOG")"
  if ! harness_wait_for_health "$PORT" 45; then
    echo "ERROR: server failed health check within 45s" >&2
    harness_print_log_tail "$SERVER_LOG"
    exit 1
  fi
  BASE_URL="http://127.0.0.1:${PORT}"
  echo "[harness] server ready pid=$SERVER_PID" >&2
else
  echo "[harness] attach mode, probing existing server at $BASE_URL" >&2
fi

PROBE_URL="${BASE_URL%/}${PROBE_ENDPOINT}"

# Warm caches so the baseline reflects steady-state, not cold-start.
for ((i = 0; i < WARMUP_PROBES; i++)); do probe_once "$PROBE_URL" >/dev/null; done

# ---- sweep ------------------------------------------------------------------
printf '\n%-10s %-8s %-10s %-10s %-10s %-9s\n' "hogs" "probes" "p50_ms" "p95_ms" "max_ms" "timeouts" >&2
printf '%s\n' "------------------------------------------------------------------" >&2

baseline_p95=""
loaded_p95=""
declare -a LEVELS_DONE=()
for level in $HOG_LEVELS; do
  kill_inproc_load
  kill_hogs
  if [[ "$level" -gt 0 ]]; then
    spawn_hogs "$level"
    if [[ "$INPROC_LOAD" -gt 0 ]]; then
      spawn_inproc_load "$INPROC_LOAD" "${BASE_URL%/}${LOAD_ENDPOINT}"
    fi
    sleep "$LOAD_SETTLE_SEC"
  fi
  vals_file="$RUN_DIR/level_${level}.txt"
  read -r p50 p95 mx timeouts <<<"$(measure_level "$vals_file" "$PROBE_URL")"
  kill_inproc_load
  kill_hogs
  printf '%-10s %-8s %-10s %-10s %-10s %-9s\n' "$level" "$PROBES" "$p50" "$p95" "$mx" "$timeouts" >&2
  printf '%s,%s,%s,%s,%s,%s\n' "$level" "$PROBES" "$p50" "$p95" "$mx" "$timeouts" >> "$CSV_FILE"
  LEVELS_DONE+=("{\"hogs\":$level,\"p50_ms\":$p50,\"p95_ms\":$p95,\"max_ms\":$mx,\"timeouts\":$timeouts}")
  [[ "$level" == "0" ]] && baseline_p95="$p95"
  loaded_p95="$p95"
done

# ---- verdict ----------------------------------------------------------------
[[ -n "$baseline_p95" ]] || baseline_p95="$loaded_p95"
verdict="$(awk -v base="$baseline_p95" -v loaded="$loaded_p95" -v thr="$THRESHOLD_MS" -v maxamp="$MAX_AMP" '
  BEGIN {
    amp = (base > 0) ? loaded / base : 0
    starved = (loaded > thr) || (amp > maxamp)
    printf "%.2f %d", amp, starved
  }')"
read -r amplification starved <<<"$verdict"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg endpoint "$PROBE_ENDPOINT" \
  --arg base_url "$BASE_URL" \
  --argjson ncpu "$NCPU" \
  --argjson probes "$PROBES" \
  --argjson threshold_ms "$THRESHOLD_MS" \
  --argjson max_amp "$MAX_AMP" \
  --argjson baseline_p95_ms "$baseline_p95" \
  --argjson loaded_p95_ms "$loaded_p95" \
  --argjson amplification "$amplification" \
  --argjson starved "$starved" \
  --argjson levels "[$(IFS=,; echo "${LEVELS_DONE[*]}")]" \
  '{run_id:$run_id, endpoint:$endpoint, base_url:$base_url, ncpu:$ncpu, probes_per_level:$probes,
    threshold_ms:$threshold_ms, max_amplification:$max_amp,
    baseline_p95_ms:$baseline_p95_ms, loaded_p95_ms:$loaded_p95_ms, amplification:$amplification,
    starved:($starved==1), levels:$levels}' > "$SUMMARY_FILE"

echo >&2
echo "[harness] baseline p95=${baseline_p95}ms  loaded p95=${loaded_p95}ms  amplification=${amplification}x" >&2
echo "[harness] artifacts: $RUN_DIR" >&2

if [[ "$starved" == "1" ]]; then
  echo "RED (STARVED): trivial p95 ${loaded_p95}ms under load (threshold ${THRESHOLD_MS}ms, amp ${amplification}x > ${MAX_AMP}x)" >&2
  echo "  -> Expected on unfixed main. Apply QoS/core-budget fix and re-run; gate should turn GREEN." >&2
  exit 2
fi
echo "GREEN: trivial p95 ${loaded_p95}ms under load stays within ${THRESHOLD_MS}ms (amp ${amplification}x <= ${MAX_AMP}x)" >&2
exit 0
