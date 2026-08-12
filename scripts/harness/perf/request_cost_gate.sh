#!/usr/bin/env bash
# request_cost_gate.sh — Mode C: gate the resource cost of a SINGLE dashboard read.
#
# Relationship to Modes A and B
#   Mode A (scheduler_starvation_gate.sh) drives serving concurrency plus host hogs; Mode B
#   (keeper_load_gate.sh) drives real keeper turns. Both stress CONTENTION and answer "where does
#   work run, and who is it queued behind".
#   Mode C holds concurrency at ONE and asks how much a single request costs. A read whose entry
#   count scales with the store cannot be fixed by moving it to another domain or pool: the lane
#   it lands on dies instead, and the heap it allocates is process-global, so every keeper shares
#   the GC pressure. Isolation and boundedness are separate axes; this gate covers boundedness.
#
# What it measures (three axes, one request)
#   1. probe_p95_ms        trivial-endpoint p95 while ONE heavy request is in flight
#   2. rss_peak_delta_mb   peak RSS growth attributable to that one request
#   3. cancel_recovery_s   seconds for the probe to return to baseline after the client aborts
#                          (a server that does not propagate cancellation keeps computing)
#
# Gate semantics (falsifiable)
#   GREEN requires all three under threshold. On current main this is expected to FAIL — that
#   failure is the proof the gate catches the defect. A gate that passes on unfixed main is too
#   weak and must be tightened.
#
# Scaling check
#   --keepers is a seed parameter because the reader's scan cap is per-store, not per-request.
#   Running the gate at two keeper counts shows whether one request's cost tracks store count;
#   if it does, the request has no budget of its own.
#
# Exit codes
#   0  GREEN  — single-request cost bounded
#   2  RED    — cost unbounded (expected on current unfixed main)
#   1  ERROR  — harness failure (server did not boot, missing tools, bad args)
#
# Reference: docs/rfc/RFC-0204-dashboard-serving-isolation.md (isolation axis; this gate is the
# boundedness sibling). Changes no production code; measurement infrastructure only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/harness/lib/server_bootstrap.sh"

# ---- configuration (env-overridable) ----------------------------------------
PROBE_ENDPOINT="${PROBE_ENDPOINT:-/health}"      # trivial, lock-free
COST_ENDPOINT="${COST_ENDPOINT:-/api/v1/dashboard/telemetry?n=0}"
BASELINE_PROBES="${BASELINE_PROBES:-15}"
PROBE_INTERVAL_SEC="${PROBE_INTERVAL_SEC:-0.25}"
PROBE_MAX_SEC="${PROBE_MAX_SEC:-20}"             # per-probe ceiling; a timeout counts as this
COST_MAX_SEC="${COST_MAX_SEC:-120}"              # ceiling for the heavy request itself
CANCEL_AFTER_SEC="${CANCEL_AFTER_SEC:-3}"        # abort the heavy client after this long
CANCEL_WATCH_SEC="${CANCEL_WATCH_SEC:-60}"       # how long to wait for post-abort recovery
# 0.5s was too coarse: once a fix brought the heavy request under a second, the
# sampler took one or two samples and reported delta 0.0MB -- indistinguishable
# from a request that allocated nothing. A missed peak and an absent peak must
# not produce the same number, so sample fast enough that a sub-second request
# still yields a usable series, and fail the run if it does not (MIN_RSS_SAMPLES).
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-0.05}"
MIN_RSS_SAMPLES="${MIN_RSS_SAMPLES:-5}"

# Gate thresholds.
THRESHOLD_MS="${THRESHOLD_MS:-250}"              # probe p95 under one heavy request
MAX_RSS_DELTA_MB="${MAX_RSS_DELTA_MB:-512}"      # heap growth one request may cause
MAX_CANCEL_RECOVERY_SEC="${MAX_CANCEL_RECOVERY_SEC:-5}"
MAX_POST_ABORT_GROWTH_MB="${MAX_POST_ABORT_GROWTH_MB:-64}"  # heap growth after the client left

# Control that must pass before any verdict is trusted. If the trivial endpoint is already slow
# with no load on it, the host is contended and every downstream number is that contention, not
# the request under test. Such a run exits ERROR (1), never RED (2): a RED from a busy host is a
# false positive, and RFC-0204's first diagnosis was reversed for exactly this reason.
MAX_BASELINE_P95_MS="${MAX_BASELINE_P95_MS:-50}"

# Seed shape (boot mode only).
SEED_KEEPERS="${SEED_KEEPERS:-8}"
SEED_ENTRIES="${SEED_ENTRIES:-20000}"
SEED_DAYS="${SEED_DAYS:-4}"

# Attach mode: probe an already-running server instead of booting one. RSS is then read from
# the listening PID. Booting is the default and is self-contained + deterministic.
BASE_URL="${MASC_HARNESS_BASE_URL:-}"
ATTACH_PID="${MASC_HARNESS_SERVER_PID:-}"
KEEP_SERVER="${KEEP_SERVER:-0}"

RUN_ID="${RUN_ID:-request-cost-$(date +%Y%m%d_%H%M%S)-$$}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/perf-request-cost/$RUN_ID}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
  --cost-endpoint PATH   heavy endpoint under test (default: $COST_ENDPOINT)
  --probe-endpoint PATH  trivial endpoint to probe (default: $PROBE_ENDPOINT)
  --keepers N            seeded per-keeper stores (default: $SEED_KEEPERS)
  --entries N            seeded entries per store (default: $SEED_ENTRIES)
  --threshold-ms N       max probe p95 under load before RED (default: $THRESHOLD_MS)
  --max-rss-mb N         max RSS growth from one request before RED (default: $MAX_RSS_DELTA_MB)
  --max-cancel-sec N     max post-abort recovery before RED (default: $MAX_CANCEL_RECOVERY_SEC)
  --max-post-abort-mb N  max heap growth after client abort before RED (default: $MAX_POST_ABORT_GROWTH_MB)
  --max-baseline-ms N    control: abort the run as ERROR if idle p95 exceeds this
                         (default: $MAX_BASELINE_P95_MS)
  --base-url URL         attach to a running server instead of booting
  --server-pid PID       PID for RSS sampling in attach mode (default: autodetect by port)
  --keep-server          do not stop the booted server on exit
  -h|--help              this help
Environment overrides mirror the flags.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cost-endpoint) COST_ENDPOINT="$2"; shift 2 ;;
    --probe-endpoint) PROBE_ENDPOINT="$2"; shift 2 ;;
    --keepers) SEED_KEEPERS="$2"; shift 2 ;;
    --entries) SEED_ENTRIES="$2"; shift 2 ;;
    --threshold-ms) THRESHOLD_MS="$2"; shift 2 ;;
    --max-rss-mb) MAX_RSS_DELTA_MB="$2"; shift 2 ;;
    --max-cancel-sec) MAX_CANCEL_RECOVERY_SEC="$2"; shift 2 ;;
    --max-post-abort-mb) MAX_POST_ABORT_GROWTH_MB="$2"; shift 2 ;;
    --max-baseline-ms) MAX_BASELINE_P95_MS="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --server-pid) ATTACH_PID="$2"; shift 2 ;;
    --keep-server) KEEP_SERVER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

for tool in curl jq awk python3 ps; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $tool" >&2; exit 1; }
done

mkdir -p "$RUN_DIR"
PROBE_CSV="$RUN_DIR/probes.csv"
RSS_CSV="$RUN_DIR/rss.csv"
SUMMARY_FILE="$RUN_DIR/summary.json"
SERVER_LOG="$RUN_DIR/server.log"
SEED_INFO="$RUN_DIR/seed.json"
echo "phase,elapsed_s,ms" > "$PROBE_CSV"
echo "phase,elapsed_s,rss_kb" > "$RSS_CSV"

SERVER_PID=""
BASE_PATH=""
SAMPLER_PID=""
COST_PID=""

cleanup() {
  [[ -n "$SAMPLER_PID" ]] && kill "$SAMPLER_PID" 2>/dev/null || true
  [[ -n "$COST_PID" ]] && kill "$COST_PID" 2>/dev/null || true
  if [[ -n "$SERVER_PID" && "$KEEP_SERVER" != "1" ]]; then
    harness_stop_server "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---- helpers ----------------------------------------------------------------

now_s() { python3 -c 'import time; print(time.time())'; }

elapsed_since() { python3 -c "import sys; print(round(float(sys.argv[2])-float(sys.argv[1]),3))" "$1" "$(now_s)"; }

rss_kb_of() {
  local kb
  kb="$(ps -o rss= -p "$1" 2>/dev/null | tr -d ' ')"
  printf '%s\n' "${kb:-0}"
}

kb_to_mb() { python3 -c "import sys; print(round(float(sys.argv[1])/1024,1))" "$1"; }

# One probe; prints milliseconds. A timeout is recorded as the ceiling rather than dropped,
# so a hung server raises the statistic instead of silently shrinking the sample.
probe_ms() {
  local t
  t="$(curl -s -o /dev/null -w '%{time_total}' --max-time "$PROBE_MAX_SEC" \
        "${BASE_URL}${PROBE_ENDPOINT}" 2>/dev/null || echo "$PROBE_MAX_SEC")"
  python3 -c "import sys; print(round(float(sys.argv[1])*1000,1))" "$t"
}

# Percentile in python rather than awk: `asort` is a gawk extension and macOS ships BSD awk,
# where it fails at runtime. Empty input yields 0 so the caller never sees a blank field.
percentile() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, col, pct = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
values: list[float] = []
with open(path, encoding="utf-8") as handle:
    next(handle, None)
    for line in handle:
        parts = line.rstrip("\n").split(",")
        if len(parts) >= col:
            try:
                values.append(float(parts[col - 1]))
            except ValueError:
                pass
if not values:
    print(0)
    raise SystemExit(0)
values.sort()
index = max(1, min(int(pct / 100 * len(values)), len(values)))
print(values[index - 1])
PY
}

filter_phase() {
  local phase="$1" src="$2" dst="$3"
  head -1 "$src" > "$dst"
  awk -F, -v ph="$phase" 'NR>1 && $1==ph' "$src" >> "$dst"
}

# The sampler runs concurrently with the measurement, so it must stay cheap: `ps` only, no
# python per tick. Raw KB is recorded and converted once at verdict time.
start_rss_sampler() {
  local phase="$1" pid="$2"
  local started
  started="$(date +%s)"
  (
    while true; do
      printf '%s,%s,%s\n' "$phase" "$(( $(date +%s) - started ))" \
        "$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)" >> "$RSS_CSV"
      sleep "$SAMPLE_INTERVAL_SEC"
    done
  ) &
  SAMPLER_PID=$!
}

stop_rss_sampler() {
  [[ -n "$SAMPLER_PID" ]] && kill "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=""
}

# ---- server: boot or attach --------------------------------------------------

if [[ -n "$BASE_URL" ]]; then
  BASE_URL="${BASE_URL%/}"
  echo "harness: attach mode -> $BASE_URL (no seeding; store shape is whatever the server has)"
  if [[ -z "$ATTACH_PID" ]]; then
    local_port="${BASE_URL##*:}"
    ATTACH_PID="$(lsof -ti ":${local_port}" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$ATTACH_PID" ]]; then
    echo "ERROR: attach mode needs --server-pid (RSS axis cannot be measured without it)" >&2
    exit 1
  fi
  SERVER_RSS_PID="$ATTACH_PID"
  SEED_KEEPERS=0
  SEED_ENTRIES=0
  printf '{"mode":"attach"}\n' > "$SEED_INFO"
else
  SERVER_EXE="$(harness_find_server_exe "$REPO_ROOT" "${MASC_HARNESS_SERVER_EXE:-}")" || {
    echo "ERROR: server exe not found; build first (or set MASC_HARNESS_SERVER_EXE)" >&2
    exit 1
  }
  PORT="$(harness_pick_free_port)"
  BASE_PATH="$(harness_mktemp_dir "request-cost-base")"
  echo "harness: seeding store (keepers=$SEED_KEEPERS entries/store=$SEED_ENTRIES days=$SEED_DAYS)"
  python3 "$SCRIPT_DIR/seed_telemetry_store.py" \
    --root "$BASE_PATH/.masc" \
    --keepers "$SEED_KEEPERS" \
    --entries-per-store "$SEED_ENTRIES" \
    --days "$SEED_DAYS" > "$SEED_INFO"
  cat "$SEED_INFO"

  echo "harness: booting server on port $PORT (base-path $BASE_PATH)"
  SERVER_PID="$(harness_start_server "$SERVER_EXE" "$PORT" "$BASE_PATH" "$SERVER_LOG")"
  if ! harness_wait_for_health "$PORT" 60; then
    echo "ERROR: server failed health check within 60s" >&2
    harness_print_log_tail "$SERVER_LOG" || true
    exit 1
  fi
  BASE_URL="http://127.0.0.1:${PORT}"
  SERVER_RSS_PID="$SERVER_PID"
fi

# ---- phase 1: baseline -------------------------------------------------------

echo "harness: phase 1 — baseline ($BASELINE_PROBES probes, no load)"
T0="$(now_s)"
for _ in $(seq 1 "$BASELINE_PROBES"); do
  printf 'baseline,%s,%s\n' "$(elapsed_since "$T0")" "$(probe_ms)" >> "$PROBE_CSV"
done
RSS_BASELINE_KB="$(rss_kb_of "$SERVER_RSS_PID")"
RSS_BASELINE="$(kb_to_mb "$RSS_BASELINE_KB")"
printf 'baseline,%s,%s\n' "$(elapsed_since "$T0")" "$RSS_BASELINE_KB" >> "$RSS_CSV"

filter_phase baseline "$PROBE_CSV" "$RUN_DIR/_baseline.csv"
BASE_P50="$(percentile "$RUN_DIR/_baseline.csv" 3 50)"
BASE_P95="$(percentile "$RUN_DIR/_baseline.csv" 3 95)"
echo "         baseline p50=${BASE_P50}ms p95=${BASE_P95}ms rss=${RSS_BASELINE}MB"

if python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>float(sys.argv[2]) else 1)" \
     "$BASE_P95" "$MAX_BASELINE_P95_MS"; then
  echo "ERROR: baseline p95=${BASE_P95}ms exceeds the control ceiling ${MAX_BASELINE_P95_MS}ms." >&2
  echo "       The host is contended; this run cannot attribute cost to the request under test." >&2
  echo "       Quiet the host (stop builds/dev servers) and re-run, or raise MAX_BASELINE_P95_MS" >&2
  echo "       deliberately if you accept a noisier measurement." >&2
  jq -n --arg run_id "$RUN_ID" --argjson baseline_p95_ms "$BASE_P95" \
        --argjson ceiling "$MAX_BASELINE_P95_MS" \
    '{run_id:$run_id, verdict:"ERROR", reason:"baseline control failed",
      baseline_p95_ms:$baseline_p95_ms, control_ceiling_ms:$ceiling}' > "$SUMMARY_FILE"
  exit 1
fi

# ---- phase 2: one heavy request in flight ------------------------------------

echo "harness: phase 2 — ONE heavy request ($COST_ENDPOINT)"
T0="$(now_s)"
start_rss_sampler loaded "$SERVER_RSS_PID"

COST_START="$(now_s)"
curl -s -o /dev/null -H 'Accept-Encoding: zstd' --max-time "$COST_MAX_SEC" \
  "${BASE_URL}${COST_ENDPOINT}" >/dev/null 2>&1 &
COST_PID=$!

while kill -0 "$COST_PID" 2>/dev/null; do
  printf 'loaded,%s,%s\n' "$(elapsed_since "$T0")" "$(probe_ms)" >> "$PROBE_CSV"
  sleep "$PROBE_INTERVAL_SEC"
done
wait "$COST_PID" 2>/dev/null || true
COST_DURATION="$(elapsed_since "$COST_START")"
COST_PID=""
stop_rss_sampler

filter_phase loaded "$PROBE_CSV" "$RUN_DIR/_loaded.csv"
LOAD_P95="$(percentile "$RUN_DIR/_loaded.csv" 3 95)"
LOAD_MAX="$(percentile "$RUN_DIR/_loaded.csv" 3 100)"
filter_phase loaded "$RSS_CSV" "$RUN_DIR/_loaded_rss.csv"
RSS_PEAK_KB="$(percentile "$RUN_DIR/_loaded_rss.csv" 3 100)"
RSS_PEAK="$(kb_to_mb "$RSS_PEAK_KB")"
RSS_DELTA="$(python3 -c "import sys; print(round(float(sys.argv[1])-float(sys.argv[2]),1))" "$RSS_PEAK" "$RSS_BASELINE")"
RSS_SAMPLES="$(awk -F, 'NR>1 && $1=="loaded"' "$RSS_CSV" | wc -l | tr -d ' ')"
if [[ "$RSS_SAMPLES" -lt "$MIN_RSS_SAMPLES" ]]; then
  echo "ERROR: only $RSS_SAMPLES RSS samples while the request was in flight" >&2
  echo "       (need >= $MIN_RSS_SAMPLES). The peak was probably missed, and a" >&2
  echo "       missed peak reads exactly like an absent one. Lower" >&2
  echo "       SAMPLE_INTERVAL_SEC or measure a longer request." >&2
  jq -n --arg run_id "$RUN_ID" --argjson samples "$RSS_SAMPLES" \
        --argjson needed "$MIN_RSS_SAMPLES" \
    '{run_id:$run_id, verdict:"ERROR", reason:"insufficient rss samples",
      rss_samples:$samples, required:$needed}' > "$SUMMARY_FILE"
  exit 1
fi
echo "         heavy request took ${COST_DURATION}s; probe p95=${LOAD_P95}ms max=${LOAD_MAX}ms"
echo "         rss ${RSS_BASELINE}MB -> peak ${RSS_PEAK}MB (delta ${RSS_DELTA}MB)"

# ---- phase 3: cancellation propagation ---------------------------------------
# Fire the same request, abort the client mid-flight, then measure how long the probe stays
# degraded. A server that propagates cancellation recovers immediately; one that does not keeps
# computing for the full request duration with no client left to receive the result.

echo "harness: phase 3 — abort client after ${CANCEL_AFTER_SEC}s, watch recovery"
RECOVERY_CEILING="$(python3 -c "import sys; print(max(float(sys.argv[1])*3, float(sys.argv[2])))" "$BASE_P95" "$THRESHOLD_MS")"
T0="$(now_s)"
curl -s -o /dev/null -H 'Accept-Encoding: zstd' --max-time "$COST_MAX_SEC" \
  "${BASE_URL}${COST_ENDPOINT}" >/dev/null 2>&1 &
COST_PID=$!
sleep "$CANCEL_AFTER_SEC"
kill "$COST_PID" 2>/dev/null || true
wait "$COST_PID" 2>/dev/null || true
COST_PID=""
ABORT_AT="$(now_s)"
RSS_AT_ABORT_KB="$(rss_kb_of "$SERVER_RSS_PID")"
RSS_POST_ABORT_MAX_KB="$RSS_AT_ABORT_KB"

# Two signals, because latency alone is ambiguous. A single fast probe can land in a gap while
# the server is still computing, so recovery requires CONSECUTIVE_HEALTHY probes in a row.
# The unambiguous signal is heap: if RSS keeps climbing after the client is gone, the server is
# still building a result nobody will receive — cancellation did not propagate.
CONSECUTIVE_HEALTHY=3
healthy_run=0
CANCEL_RECOVERY="$CANCEL_WATCH_SEC"
while true; do
  waited="$(elapsed_since "$ABORT_AT")"
  ms="$(probe_ms)"
  printf 'cancel,%s,%s\n' "$(elapsed_since "$T0")" "$ms" >> "$PROBE_CSV"

  rss_now_kb="$(rss_kb_of "$SERVER_RSS_PID")"
  printf 'cancel,%s,%s\n' "$(elapsed_since "$T0")" "$rss_now_kb" >> "$RSS_CSV"
  if (( rss_now_kb > RSS_POST_ABORT_MAX_KB )); then
    RSS_POST_ABORT_MAX_KB="$rss_now_kb"
  fi

  if python3 -c "import sys; sys.exit(0 if float(sys.argv[1])<=float(sys.argv[2]) else 1)" "$ms" "$RECOVERY_CEILING"; then
    healthy_run=$(( healthy_run + 1 ))
  else
    healthy_run=0
  fi

  if (( healthy_run >= CONSECUTIVE_HEALTHY )); then
    CANCEL_RECOVERY="$waited"
    break
  fi
  if python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>=float(sys.argv[2]) else 1)" "$waited" "$CANCEL_WATCH_SEC"; then
    CANCEL_RECOVERY="$CANCEL_WATCH_SEC"
    break
  fi
  sleep "$PROBE_INTERVAL_SEC"
done

RSS_AT_ABORT="$(kb_to_mb "$RSS_AT_ABORT_KB")"
POST_ABORT_GROWTH="$(python3 -c "import sys; print(round((float(sys.argv[1])-float(sys.argv[2]))/1024,1))" \
  "$RSS_POST_ABORT_MAX_KB" "$RSS_AT_ABORT_KB")"
echo "         recovery after abort: ${CANCEL_RECOVERY}s (needs ${CONSECUTIVE_HEALTHY} consecutive probes <= ${RECOVERY_CEILING}ms)"
echo "         heap after abort: ${RSS_AT_ABORT}MB -> +${POST_ABORT_GROWTH}MB (growth with no client = no cancellation)"

# ---- verdict -----------------------------------------------------------------

fail_reasons=()
gt() { python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>float(sys.argv[2]) else 1)" "$1" "$2"; }

if gt "$LOAD_P95" "$THRESHOLD_MS"; then
  fail_reasons+=("probe_p95_ms=${LOAD_P95} > ${THRESHOLD_MS}")
fi
if gt "$RSS_DELTA" "$MAX_RSS_DELTA_MB"; then
  fail_reasons+=("rss_peak_delta_mb=${RSS_DELTA} > ${MAX_RSS_DELTA_MB}")
fi
if gt "$CANCEL_RECOVERY" "$MAX_CANCEL_RECOVERY_SEC"; then
  fail_reasons+=("cancel_recovery_s=${CANCEL_RECOVERY} > ${MAX_CANCEL_RECOVERY_SEC}")
fi
if gt "$POST_ABORT_GROWTH" "$MAX_POST_ABORT_GROWTH_MB"; then
  fail_reasons+=("post_abort_heap_growth_mb=${POST_ABORT_GROWTH} > ${MAX_POST_ABORT_GROWTH_MB} (cancellation not propagated)")
fi

verdict="GREEN"
exit_code=0
if [[ ${#fail_reasons[@]} -gt 0 ]]; then
  verdict="RED"
  exit_code=2
fi

jq -n \
  --arg run_id "$RUN_ID" \
  --arg verdict "$verdict" \
  --arg cost_endpoint "$COST_ENDPOINT" \
  --arg probe_endpoint "$PROBE_ENDPOINT" \
  --argjson seed "$(cat "$SEED_INFO")" \
  --argjson baseline_p50_ms "$BASE_P50" \
  --argjson baseline_p95_ms "$BASE_P95" \
  --argjson probe_p95_ms "$LOAD_P95" \
  --argjson probe_max_ms "$LOAD_MAX" \
  --argjson cost_duration_s "$COST_DURATION" \
  --argjson rss_baseline_mb "$RSS_BASELINE" \
  --argjson rss_peak_mb "$RSS_PEAK" \
  --argjson rss_peak_delta_mb "$RSS_DELTA" \
  --argjson cancel_recovery_s "$CANCEL_RECOVERY" \
  --argjson post_abort_heap_growth_mb "$POST_ABORT_GROWTH" \
  --argjson threshold_ms "$THRESHOLD_MS" \
  --argjson max_rss_delta_mb "$MAX_RSS_DELTA_MB" \
  --argjson max_cancel_recovery_s "$MAX_CANCEL_RECOVERY_SEC" \
  --argjson max_post_abort_heap_growth_mb "$MAX_POST_ABORT_GROWTH_MB" \
  --argjson reasons "$(printf '%s\n' "${fail_reasons[@]+"${fail_reasons[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{run_id:$run_id, verdict:$verdict, cost_endpoint:$cost_endpoint, probe_endpoint:$probe_endpoint,
    seed:$seed,
    measured:{baseline_p50_ms:$baseline_p50_ms, baseline_p95_ms:$baseline_p95_ms,
              probe_p95_ms:$probe_p95_ms, probe_max_ms:$probe_max_ms,
              cost_duration_s:$cost_duration_s,
              rss_baseline_mb:$rss_baseline_mb, rss_peak_mb:$rss_peak_mb,
              rss_peak_delta_mb:$rss_peak_delta_mb,
              cancel_recovery_s:$cancel_recovery_s,
              post_abort_heap_growth_mb:$post_abort_heap_growth_mb},
    thresholds:{probe_p95_ms:$threshold_ms, rss_peak_delta_mb:$max_rss_delta_mb,
                cancel_recovery_s:$max_cancel_recovery_s,
                post_abort_heap_growth_mb:$max_post_abort_heap_growth_mb},
    failures:$reasons}' > "$SUMMARY_FILE"

echo ""
echo "verdict: $verdict"
for reason in "${fail_reasons[@]+"${fail_reasons[@]}"}"; do
  echo "  FAIL: $reason"
done
echo "artifacts: $RUN_DIR"
exit "$exit_code"
