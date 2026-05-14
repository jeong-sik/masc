#!/usr/bin/env bash
# Phase B baseline harness for OAS dispatch hot path measurement.
#
# Plan reference: ~/me/planning/claude-plans/wise-nibbling-lerdorf.md §"Phase B"
#
# Scope: scrape the running masc-mcp server's /metrics endpoint and emit a
# CSV row per OAS hot path histogram. Workload driving is the operator's
# responsibility — run scripts/harness_tool_call_quality.sh --live or
# whatever workload matches the comparison you want, then invoke this
# script to capture the histogram values.
#
# Caveat: masc-mcp's [Prometheus.observe_histogram] currently tracks the
# cumulative sum and _count only (no buckets). Quantiles (p50/p95/p99)
# therefore require either an external Prometheus scraper with proper
# bucketing or a raw-sample collection mode (out of scope for Phase B
# baseline). The CSV emitted here records sum, count, and arithmetic
# mean, which is sufficient for the Phase B decision gate (>= 2% turn
# budget threshold from the plan).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CMD="${1:-scrape}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/harness_oas_dispatch.sh scrape [--port PORT] [--out PATH] [--label LABEL]
  scripts/harness_oas_dispatch.sh diff   <baseline.csv> <current.csv>

Modes:
  scrape (default)
      Reads /metrics from the running masc-mcp server and writes a CSV row
      per OAS dispatch histogram (sum, count, avg).
      Defaults: --port 8935 --out benchmarks/results/oas-baseline-<ts>.csv
      Optional --label TAG annotates the CSV row (e.g. "memo-off", "memo-on",
      "hist-disabled") so multi-run diffs stay legible.

  diff <baseline.csv> <current.csv>
      Prints a row-by-row delta (sum / count / avg) between two scrape CSVs
      so the wise-nibbling-lerdorf Phase B decision gate can be evaluated
      without spinning up an external Prometheus stack.

Environment:
  MASC_DISABLE_HOTPATH_HIST=1 on the server side disables the Phase B
  histogram observation entirely — pair "scrape --label hist-on" with a
  rerun under "--label hist-off" to quantify observation overhead.
EOF
}

if [[ "${CMD}" == "-h" || "${CMD}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

scrape_mode() {
  local port="8935"
  local out=""
  local label=""

  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    esac
  done

  require_cmd curl
  require_cmd awk

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  if [[ -z "${out}" ]]; then
    out="${ROOT_DIR}/benchmarks/results/oas-baseline-${ts}.csv"
  fi
  mkdir -p "$(dirname "${out}")"

  local body
  body="$(curl -sS --fail "http://127.0.0.1:${port}/metrics")" || {
    echo "scrape failed: http://127.0.0.1:${port}/metrics is unreachable" >&2
    exit 1
  }

  extract() {
    local name="$1"
    printf '%s\n' "${body}" \
      | awk -v n="${name}" '$1 == n { print $2; exit }'
  }

  local p_sum p_cnt b_sum b_cnt
  p_sum="$(extract masc_oas_params_of_schema_sec)"
  p_cnt="$(extract masc_oas_params_of_schema_sec_count)"
  b_sum="$(extract masc_oas_make_tool_bundle_sec)"
  b_cnt="$(extract masc_oas_make_tool_bundle_sec_count)"

  avg() {
    local s="${1:-0}" c="${2:-0}"
    awk -v s="${s}" -v c="${c}" \
      'BEGIN { if (c > 0) printf "%.6f", s/c; else printf "0" }'
  }

  {
    printf 'timestamp,label,metric,sum_sec,count,avg_sec\n'
    printf '%s,%s,%s,%s,%s,%s\n' \
      "${ts}" "${label}" \
      masc_oas_params_of_schema_sec \
      "${p_sum:-0}" "${p_cnt:-0}" "$(avg "${p_sum:-0}" "${p_cnt:-0}")"
    printf '%s,%s,%s,%s,%s,%s\n' \
      "${ts}" "${label}" \
      masc_oas_make_tool_bundle_sec \
      "${b_sum:-0}" "${b_cnt:-0}" "$(avg "${b_sum:-0}" "${b_cnt:-0}")"
  } > "${out}"

  echo "wrote: ${out}" >&2
  cat "${out}"
}

diff_mode() {
  shift || true
  local base="${1:-}"
  local cur="${2:-}"
  if [[ -z "${base}" || -z "${cur}" ]]; then
    usage
    exit 2
  fi
  require_cmd awk
  if [[ ! -f "${base}" ]]; then
    echo "baseline not found: ${base}" >&2; exit 1
  fi
  if [[ ! -f "${cur}" ]]; then
    echo "current not found: ${cur}" >&2; exit 1
  fi
  awk -F, '
    NR == FNR && FNR > 1 { base_sum[$3] = $4; base_cnt[$3] = $5; base_avg[$3] = $6; next }
    FNR > 1 {
      ds = $4 - base_sum[$3]
      dc = $5 - base_cnt[$3]
      da = $6 - base_avg[$3]
      printf "%s\tsum_d=%s\tcount_d=%s\tavg_d=%s\n", $3, ds, dc, da
    }
  ' "${base}" "${cur}"
}

case "${CMD}" in
  scrape) scrape_mode "$@" ;;
  diff) diff_mode "$@" ;;
  -h|--help) usage ;;
  *) usage; exit 2 ;;
esac
