#!/usr/bin/env bash
# perf-baseline.sh
#
# RFC PR-0.2 — 14-day performance baseline collector for masc-mcp.
#
# Single-shot snapshot of the metrics that future optimization PRs
# (cache, GC, WebSocket framing, MCP latency) must beat to merge. Run
# manually or under cron once per day; output is appended to a daily
# Markdown report under reports/perf-baseline-YYYY-MM-DD.md.
#
# Operating context (per RFC PR-0.2 Q&A):
#   - 12+ keepers on a single Railway instance.
#   - 50+ keepers is aspirational, not the baseline target.
#   - Prometheus scrape is local to this script (curl /metrics);
#     external Prometheus/Grafana wiring is out of scope.
#
# Sources:
#   - lib/prometheus.ml + /metrics endpoint  (counters/gauges/histograms)
#   - lib/core/masc_runtime_events.ml        (turn span events for olly)
#   - benchmarks/quick-bench.sh              (MCP latency lanes)
#
# Usage:
#   bash scripts/perf-baseline.sh                    # full snapshot
#   bash scripts/perf-baseline.sh --dry-run          # validate env, no writes
#   OLLY_TRACE=1 bash scripts/perf-baseline.sh       # opt-in olly capture
#   PERF_BASELINE_LABEL=warm bash scripts/perf-baseline.sh
#
# Exit codes:
#   0 success, 1 generic failure, 2 dependency missing,
#   3 server unreachable, 64 usage error.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '3,30p' "$0"; exit 0 ;;
    *)
      echo "perf-baseline.sh: unknown arg: $arg" >&2
      echo "usage: $0 [--dry-run]" >&2
      exit 64 ;;
  esac
done

# ---------------------------------------------------------------------------
# Paths and environment
# ---------------------------------------------------------------------------
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
TODAY="$(date -u +%Y-%m-%d)"
TIMESTAMP_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LABEL="${PERF_BASELINE_LABEL:-default}"

REPORTS_DIR="${REPO_ROOT}/reports"
TMP_DIR="${REPO_ROOT}/.tmp/perf-baseline"
REPORT_FILE="${REPORTS_DIR}/perf-baseline-${TODAY}.md"
METRICS_DUMP="${TMP_DIR}/metrics-${TODAY}-${LABEL}.txt"

MASC_HOST="${MASC_HOST:-127.0.0.1}"
MASC_PORT="${MASC_PORT:-8935}"
MASC_BASE_URL="${MASC_BASE_URL:-http://${MASC_HOST}:${MASC_PORT}}"
METRICS_URL="${MASC_BASE_URL}/metrics"
DASHBOARD_STATUS_URL="${MASC_BASE_URL}/api/v1/dashboard/status"

OLLY_TRACE="${OLLY_TRACE:-0}"
OLLY_DURATION_SEC="${OLLY_DURATION_SEC:-30}"

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "perf-baseline.sh: missing dependency: ${cmd}" >&2
    return 2
  fi
}

check_deps() {
  local missing=0
  for cmd in curl awk date mkdir tee; do
    require_cmd "$cmd" || missing=1
  done
  # jq is preferred but optional; fall back to awk if absent.
  if ! command -v jq >/dev/null 2>&1; then
    echo "perf-baseline.sh: jq not found — JSON sections will be raw text" >&2
  fi
  if [[ "$OLLY_TRACE" = "1" ]] && ! command -v olly >/dev/null 2>&1; then
    echo "perf-baseline.sh: OLLY_TRACE=1 but 'olly' not on PATH (skipping trace)" >&2
    OLLY_TRACE=0
  fi
  if (( missing == 1 )); then
    return 2
  fi
}

server_reachable() {
  curl -fsS -m 3 "$DASHBOARD_STATUS_URL" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Prometheus helpers
# ---------------------------------------------------------------------------

# fetch_metrics: dump /metrics to a file. Aborts on HTTP failure.
fetch_metrics() {
  local out="$1"
  curl -fsS -m 10 "$METRICS_URL" -o "$out"
}

# metric_value <dump-file> <metric-name> [<label-substring>]
# Returns the first matching counter/gauge value, or 0 if absent.
# Histograms are queried via metric_histogram_bucket.
metric_value() {
  local file="$1" name="$2" label_filter="${3:-}"
  if [[ -z "$label_filter" ]]; then
    awk -v n="$name" '
      $0 !~ /^#/ && index($0, n)==1 {
        # Match either "name " (no labels) or "name{...}".
        line=$0
        sub(/^[^ ]+ /,"",line)
        print line
        exit
      }
    ' "$file"
  else
    awk -v n="$name" -v lf="$label_filter" '
      $0 !~ /^#/ && index($0, n)==1 && index($0, lf)>0 {
        line=$0
        sub(/^[^ ]+ /,"",line)
        print line
        exit
      }
    ' "$file"
  fi
}

# Sum every label-permutation of a counter family.
metric_sum() {
  local file="$1" name="$2"
  awk -v n="$name" '
    $0 !~ /^#/ && index($0, n)==1 {
      line=$0
      sub(/^[^ ]+ /,"",line)
      sum += line + 0
    }
    END { printf "%g", sum+0 }
  ' "$file"
}

# Compute hit_ratio = hits / (hits + misses), or "n/a" if denom == 0.
hit_ratio() {
  local file="$1" hits_metric="$2" misses_metric="$3"
  local h m denom
  h="$(metric_sum "$file" "$hits_metric")"
  m="$(metric_sum "$file" "$misses_metric")"
  denom=$(awk -v a="$h" -v b="$m" 'BEGIN{print a+b}')
  if [[ "$denom" = "0" ]]; then
    echo "n/a"
  else
    awk -v a="$h" -v d="$denom" 'BEGIN{printf "%.4f", a/d}'
  fi
}

# ---------------------------------------------------------------------------
# Olly capture (opt-in)
# ---------------------------------------------------------------------------
# Requires the masc-mcp server process to have OCAMLRUNPARAM=e
# (Runtime_events ring buffer enabled). When OLLY_TRACE=1, we run a
# fixed-duration capture and append the summary to the report. We do
# NOT auto-attach to a running process — the operator should set
# OCAMLRUNPARAM=e at server start. If olly cannot attach, we record
# the failure rather than aborting the whole snapshot.
olly_capture() {
  local out="$1"
  if [[ "$OLLY_TRACE" != "1" ]]; then
    return 0
  fi
  local pid
  pid="$(pgrep -f 'masc_mcp_server' | head -n 1 || true)"
  if [[ -z "$pid" ]]; then
    echo "(olly) masc_mcp_server pid not found — skipping" >"$out"
    return 0
  fi
  # olly trace-format is version-dependent; we just capture stdout and
  # let the report show whatever the user's olly produces.
  if ! olly trace --pid "$pid" --duration "${OLLY_DURATION_SEC}s" >"$out" 2>&1; then
    echo "(olly) capture failed: see $out" >&2
  fi
}

# ---------------------------------------------------------------------------
# Report rendering
# ---------------------------------------------------------------------------
write_header() {
  local file="$1"
  if [[ -f "$file" ]]; then
    return 0
  fi
  cat >"$file" <<EOF
# masc-mcp performance baseline — ${TODAY}

Generated by \`scripts/perf-baseline.sh\`. One row per snapshot;
each run appends. Operating target: 12+ keepers on a single Railway
instance. 50+ keepers is aspirational, not assumed in any threshold.

| ts (UTC) | label | git sha | section |
|----------|-------|---------|---------|
EOF
}

git_sha() {
  (cd "$REPO_ROOT" && git rev-parse --short=12 HEAD 2>/dev/null) || echo "unknown"
}

render_section() {
  local title="$1"; shift
  echo
  echo "## ${title} (${TIMESTAMP_UTC}, label=${LABEL}, sha=$(git_sha))"
  echo
  cat
}

render_index_row() {
  local section="$1"
  printf "| %s | %s | %s | %s |\n" \
    "$TIMESTAMP_UTC" "$LABEL" "$(git_sha)" "$section"
}

# ---------------------------------------------------------------------------
# Metric extraction blocks
# ---------------------------------------------------------------------------

# 1. Cache hit ratio
section_cache() {
  local file="$1"
  local ws_parse_ratio ws_bytes_ratio
  ws_parse_ratio="$(hit_ratio "$file" \
    masc_ws_parse_cache_hits_total masc_ws_parse_cache_misses_total)"
  ws_bytes_ratio="$(hit_ratio "$file" \
    masc_ws_bytes_cache_hits_total masc_ws_bytes_cache_misses_total)"

  cat <<EOF
| metric | source | value |
|--------|--------|-------|
| ws_parse_cache_hit_ratio | masc_ws_parse_cache_{hits,misses}_total | ${ws_parse_ratio} |
| ws_bytes_cache_hit_ratio | masc_ws_bytes_cache_{hits,misses}_total | ${ws_bytes_ratio} |
| ws_parse_cache_hits_total  | counter (sum across labels) | $(metric_sum "$file" masc_ws_parse_cache_hits_total) |
| ws_parse_cache_misses_total| counter (sum across labels) | $(metric_sum "$file" masc_ws_parse_cache_misses_total) |
| ws_bytes_cache_hits_total  | counter (sum across labels) | $(metric_sum "$file" masc_ws_bytes_cache_hits_total) |
| ws_bytes_cache_misses_total| counter (sum across labels) | $(metric_sum "$file" masc_ws_bytes_cache_misses_total) |

Caches outside WS framing (\`lib/cache_eio.ml\`, \`lib/dashboard/dashboard_cache.ml\`)
have no exported counters yet. **Phase 0.2.A: add hit/miss counters** is a
prerequisite for the broader cache-effectiveness baseline; this report
records them as missing rather than synthesising them.
EOF
}

# 2. WebSocket framing
section_websocket() {
  local file="$1"
  cat <<EOF
| metric | source | value |
|--------|--------|-------|
| ws_sessions_total       | masc_ws_sessions_total       | $(metric_sum "$file" masc_ws_sessions_total) |
| ws_bytes_sent_total     | masc_ws_bytes_sent_total     | $(metric_sum "$file" masc_ws_bytes_sent_total) |
| ws_client_buffered_bytes| masc_ws_client_buffered_bytes (gauge) | $(metric_value "$file" masc_ws_client_buffered_bytes) |
| ws_throttled_deliveries | masc_ws_throttled_deliveries_total | $(metric_sum "$file" masc_ws_throttled_deliveries_total) |
| ws_slice_fanout_skipped | masc_ws_slice_fanout_skipped_total | $(metric_sum "$file" masc_ws_slice_fanout_skipped_total) |
| ws_delta_built_total    | masc_ws_delta_built_total    | $(metric_sum "$file" masc_ws_delta_built_total) |

P50/P95/P99 message-size and RTT distributions are **not yet
histogrammed** — \`masc_ws_bytes_sent_total\` is a counter, not a
histogram. Phase 0.2.B: introduce \`masc_ws_message_bytes\` and
\`masc_ws_rtt_seconds\` histograms before claiming size/RTT baselines.
EOF
}

# 3. MCP tool call latency
section_mcp_latency() {
  local file="$1"
  local hist_lines
  hist_lines="$(awk '
    $0 ~ /^masc_tool_call_duration_seconds_bucket/ ||
    $0 ~ /^masc_tool_call_duration_seconds_sum/   ||
    $0 ~ /^masc_tool_call_duration_seconds_count/ { print }
  ' "$file" || true)"

  cat <<EOF
| metric | source | value |
|--------|--------|-------|
| tool_call_total       | masc_tool_call_total (sum) | $(metric_sum "$file" masc_tool_call_total) |
| tool_call_duration_count | masc_tool_call_duration_seconds_count | $(metric_sum "$file" masc_tool_call_duration_seconds_count) |
| tool_call_duration_sum   | masc_tool_call_duration_seconds_sum   | $(metric_sum "$file" masc_tool_call_duration_seconds_sum) |
| keeper_tool_call_duration_count | masc_keeper_tool_call_duration_seconds_count | $(metric_sum "$file" masc_keeper_tool_call_duration_seconds_count) |

Histogram buckets (raw):

\`\`\`
${hist_lines:-(no buckets exported — verify register_histogram fired)}
\`\`\`

Cold-vs-warm split: this snapshot does not separate first-call from
steady-state. Phase 0.2.C: tag the histogram with a \`phase\` label
(cold|warm) inside the dispatcher to make the cold-path baseline
measurable.
EOF
}

# 4. GC / RSS
section_gc_rss() {
  local file="$1"
  # OCaml-level Gc.* metrics are not exported via /metrics today.
  # Capture the host view via /proc (Linux) or ps (macOS) to keep the
  # baseline self-contained, then flag the gap.
  local pid rss_kb
  pid="$(pgrep -f 'masc_mcp_server' | head -n 1 || true)"
  if [[ -n "$pid" ]]; then
    if [[ "$(uname)" = "Linux" ]] && [[ -r "/proc/$pid/status" ]]; then
      rss_kb="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")"
    else
      rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1}')"
    fi
  else
    rss_kb=""
  fi

  cat <<EOF
| metric | source | value |
|--------|--------|-------|
| process_open_fds | masc_process_open_fds (gauge) | $(metric_value "$file" masc_process_open_fds) |
| process_fd_warn_threshold | masc_process_fd_warn_threshold (gauge) | $(metric_value "$file" masc_process_fd_warn_threshold) |
| process_timeout_total | masc_process_timeout_total | $(metric_sum "$file" masc_process_timeout_total) |
| host_rss_kb (pid=${pid:-?}) | ps/proc | ${rss_kb:-unavailable} |

OCaml GC stats (minor pause P99, major pause P99, heap_words,
live_words) are **not registered** in \`lib/prometheus.ml\` today.
Phase 0.2.D: wire \`Gc.quick_stat\` into a periodic gauge sampler so
that minor/major pause distributions become first-class metrics.
Until then, treat host RSS as a coarse placeholder.
EOF
}

# 5. Eio fiber / runtime events
section_eio_runtime() {
  local file="$1"
  cat <<EOF
| metric | source | value |
|--------|--------|-------|
| active_agents | masc_active_agents (gauge) | $(metric_value "$file" masc_active_agents) |
| keeper_count (alive)| masc_keeper_alive_total (counter) | $(metric_sum "$file" masc_keeper_alive_total) |
| keeper_turns_total  | masc_keeper_turns_total | $(metric_sum "$file" masc_keeper_turns_total) |
| keeper_turn_starts  | masc_keeper_turn_starts_total | $(metric_sum "$file" masc_keeper_turn_starts_total) |

Active-fiber count and per-fiber IO-wait distribution are NOT
exported. Source for these will be \`Masc_runtime_events\` plus
olly:

  - lib/core/masc_runtime_events.ml registers a turn span event.
  - With OCAMLRUNPARAM=e and OLLY_TRACE=1, this script attaches olly
    for ${OLLY_DURATION_SEC}s and dumps the trace to .tmp/perf-baseline/.
  - Phase 0.2.E: extend masc_runtime_events to emit an io-wait span
    so the IO distribution can be aggregated without a sampling
    profiler.
EOF
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

main() {
  check_deps || exit 2

  if (( DRY_RUN == 1 )); then
    echo "perf-baseline.sh: --dry-run"
    echo "  repo_root      = ${REPO_ROOT}"
    echo "  reports_dir    = ${REPORTS_DIR}"
    echo "  metrics_url    = ${METRICS_URL}"
    echo "  status_url     = ${DASHBOARD_STATUS_URL}"
    echo "  report_file    = ${REPORT_FILE}"
    echo "  metrics_dump   = ${METRICS_DUMP}"
    echo "  olly_trace     = ${OLLY_TRACE}"
    if server_reachable; then
      echo "  server         = reachable"
    else
      echo "  server         = NOT reachable (would exit 3 on real run)"
    fi
    exit 0
  fi

  if ! server_reachable; then
    echo "perf-baseline.sh: masc-mcp not reachable at ${MASC_BASE_URL}" >&2
    echo "  start with: dune exec masc_mcp_server -- --foreground" >&2
    exit 3
  fi

  mkdir -p "$REPORTS_DIR" "$TMP_DIR"
  fetch_metrics "$METRICS_DUMP"
  write_header "$REPORT_FILE"

  {
    render_index_row "snapshot"

    section_cache "$METRICS_DUMP"     | render_section "Cache hit ratios"
    section_websocket "$METRICS_DUMP" | render_section "WebSocket framing"
    section_mcp_latency "$METRICS_DUMP" | render_section "MCP tool-call latency"
    section_gc_rss "$METRICS_DUMP"    | render_section "GC pause and RSS"
    section_eio_runtime "$METRICS_DUMP" | render_section "Eio runtime / fibers"

    if [[ "$OLLY_TRACE" = "1" ]]; then
      local olly_out="${TMP_DIR}/olly-${TODAY}-${LABEL}.txt"
      olly_capture "$olly_out"
      {
        echo "Captured for ${OLLY_DURATION_SEC}s. Raw trace at: ${olly_out}"
        echo
        echo '```'
        head -c 4096 "$olly_out" 2>/dev/null || true
        echo
        echo '```'
      } | render_section "olly trace (head)"
    fi
  } >>"$REPORT_FILE"

  echo "perf-baseline.sh: appended snapshot to ${REPORT_FILE}"
}

main "$@"
