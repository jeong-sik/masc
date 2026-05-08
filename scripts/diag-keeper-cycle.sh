#!/usr/bin/env bash
# diag-keeper-cycle.sh — keeper "active → silent → error burst → silent" cycle reproducer
#
# Reads existing on-disk evidence (~/.masc/keepers/<name>.decisions.jsonl,
# <name>.json) and emits per-keeper cycle metrics. Code change zero — this is
# strictly a measurement tool that surfaces signals already persisted by the
# server but currently invisible to operators.
#
# Usage: diag-keeper-cycle.sh [--base-path PATH] [--keeper NAME]
#                             [--window-min N] [--top-gaps N]
#                             [--tail-min N]
# Exit codes: 0 ok, 2 base path missing, 3 jq missing, 4 no files.

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-${ME_ROOT:-$HOME/me}}"
KEEPER_FILTER=""
WINDOW_MIN=60
TOP_GAPS=5
TAIL_MIN=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path) BASE_PATH="$2"; shift 2 ;;
    --keeper)    KEEPER_FILTER="$2"; shift 2 ;;
    --window-min) WINDOW_MIN="$2"; shift 2 ;;
    --top-gaps)  TOP_GAPS="$2"; shift 2 ;;
    --tail-min)  TAIL_MIN="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 64 ;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }
KEEPERS_DIR="$BASE_PATH/.masc/keepers"
[[ -d "$KEEPERS_DIR" ]] || { echo "no keepers dir at $KEEPERS_DIR" >&2; exit 2; }

NOW="$(date +%s)"
WINDOW_AGO=$((NOW - WINDOW_MIN * 60))
TAIL_SEC=$((TAIL_MIN * 60))

if [[ -n "$KEEPER_FILTER" ]]; then
  filter_file="$KEEPERS_DIR/$KEEPER_FILTER.decisions.jsonl"
  if [[ ! -f "$filter_file" ]]; then
    echo "no decision file for keeper '$KEEPER_FILTER' at $filter_file" >&2
    exit 4
  fi
  files=( "$filter_file" )
else
  files=()
  while IFS= read -r line; do files+=( "$line" ); done < <(
    find "$KEEPERS_DIR" -maxdepth 1 -name '*.decisions.jsonl' | sort
  )
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "no keeper decision files at $KEEPERS_DIR" >&2
  exit 4
fi

tail_header="R_GT_${TAIL_MIN}M"
printf '%-14s %6s %6s %6s %6s %6s %8s %8s %8s %8s %8s %8s %8s %8s %s\n' \
  KEEPER TOTAL OK ERR NULL RECENT P50_S P95_S MAX_S R_P50_S R_P95_S \
  R_MAX_S "$tail_header" SILENT_MIN TOP_GAPS_MIN
printf '%s\n' "------------------------------------------------------------------------------------------------------------------------------------------------"

for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f" .decisions.jsonl)"

  read -r total ok err nul recent p50 p95 mx recent_p50 recent_p95 recent_mx recent_tail silent gaps_csv < <(
    jq -sr \
      --argjson now "$NOW" \
      --argjson cutoff "$WINDOW_AGO" \
      --argjson topn "$TOP_GAPS" \
      --argjson tail_sec "$TAIL_SEC" \
      '
      def n: (. // 0 | tonumber? // 0);
      def safe_lat: (.latency_ms | n) / 1000;
      def ts_value: (.ts_unix | n);
      def percentile($p):
        if length == 0 then 0 else
          sort | .[(length * $p / 100 | floor) | if . >= length then length-1 else . end]
        end;
      ( . ) as $all
      | ([ .[] | ts_value ] | sort) as $ts
      | ([ $all[] | select(ts_value >= $cutoff) ]) as $recent_rows
      | ([ $all[] | safe_lat ]) as $latencies
      | ([ $recent_rows[] | safe_lat ]) as $recent_latencies
      | (
          [range(1; $ts | length) | ($ts[.] - $ts[.-1])]
          | map(select(. > 0))
        ) as $gaps
      | ($ts | last // 0) as $last_ts
      | [
          ($all | length),
          ([ .[] | select(.outcome == "success") ] | length),
          ([ .[] | select(.outcome == "error") ] | length),
          ([ .[] | select(.outcome == null) ] | length),
          ($recent_rows | length),
          ($latencies | percentile(50)),
          ($latencies | percentile(95)),
          ($latencies | max // 0),
          ($recent_latencies | percentile(50)),
          ($recent_latencies | percentile(95)),
          ($recent_latencies | max // 0),
          ([ $recent_latencies[] | select(. >= $tail_sec) ] | length),
          (if $last_ts > 0 then (($now - $last_ts) / 60) else -1 end),
          ($gaps | sort | reverse | .[0:$topn] | map(. / 60 | floor) | join(","))
        ]
      | @tsv
    ' "$f"
  )

  printf '%-14s %6s %6s %6s %6s %6s %8.1f %8.1f %8.1f %8.1f %8.1f %8.1f %8s %8.1f %s\n' \
    "$name" "$total" "$ok" "$err" "$nul" "$recent" \
    "$p50" "$p95" "$mx" "$recent_p50" "$recent_p95" "$recent_mx" \
    "$recent_tail" "$silent" "$gaps_csv"
done

echo
echo "Legend:"
echo "  TOTAL/OK/ERR/NULL  decision count by outcome"
echo "  RECENT             decisions in last ${WINDOW_MIN}m"
echo "  P50/P95/MAX_S      latency seconds across all decisions"
echo "  R_*                latency seconds inside the selected window"
echo "  R_GT_${TAIL_MIN}M          recent decisions at or above ${TAIL_MIN} minutes latency"
echo "  SILENT_MIN         minutes since last decision (-1 = no data)"
echo "  TOP_GAPS_MIN       largest gaps between decisions (minutes), top ${TOP_GAPS}"
