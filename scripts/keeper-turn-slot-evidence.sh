#!/usr/bin/env bash
# keeper-turn-slot-evidence.sh - persisted evidence summary for #12888.
#
# This is an audit harness, not a chaos harness. It does not force a 174s
# degraded retry. It reads the active MASC keeper decision logs and reports
# whether the runtime has enough persisted evidence to close the remaining
# #12888 proof gap.
#
# Usage:
#   scripts/keeper-turn-slot-evidence.sh [--base-path PATH] [--keeper NAME]
#       [--window-min N] [--min-normal-samples N]
#
# Exit codes: 0 report emitted, 2 base path missing, 3 jq missing, 4 no files.

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-${ME_ROOT:-$HOME/me}}"
KEEPER_FILTER=""
WINDOW_MIN=1440
MIN_NORMAL_SAMPLES=5

usage() {
  sed -n '2,12p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path) BASE_PATH="$2"; shift 2 ;;
    --keeper) KEEPER_FILTER="$2"; shift 2 ;;
    --window-min) WINDOW_MIN="$2"; shift 2 ;;
    --min-normal-samples) MIN_NORMAL_SAMPLES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 64 ;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }

KEEPERS_DIR="$BASE_PATH/.masc/keepers"
[[ -d "$KEEPERS_DIR" ]] || { echo "no keepers dir at $KEEPERS_DIR" >&2; exit 2; }

NOW="$(date +%s)"
CUTOFF=$((NOW - WINDOW_MIN * 60))

if [[ -n "$KEEPER_FILTER" ]]; then
  filter_file="$KEEPERS_DIR/$KEEPER_FILTER.decisions.jsonl"
  if [[ ! -f "$filter_file" ]]; then
    echo "no decision file for keeper '$KEEPER_FILTER' at $filter_file" >&2
    exit 4
  fi
  files=("$filter_file")
else
  files=()
  while IFS= read -r line; do files+=("$line"); done < <(
    find "$KEEPERS_DIR" -maxdepth 1 -name '*.decisions.jsonl' | sort
  )
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "no keeper decision files at $KEEPERS_DIR" >&2
  exit 4
fi

echo "Keeper turn-slot evidence window"
echo "  base_path: $BASE_PATH"
echo "  keepers_dir: $KEEPERS_DIR"
echo "  window_min: $WINDOW_MIN"
echo "  min_normal_samples: $MIN_NORMAL_SAMPLES"
echo

printf '%-16s %6s %6s %6s %10s %10s %9s %9s %9s %7s %7s %7s %-36s %8s %10s %10s %s\n' \
  KEEPER TOTAL RECENT WAIT_N WAIT_P95 WAIT_MAX LAT_P50 LAT_P99 LAT_MAX LONG174 LONG600 RETRY_N PHASES_RECENT NORMAL_N NORMAL_P50 NORMAL_P99 STATUS
printf '%s\n' "-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f" .decisions.jsonl)"

  read -r total recent wait_n wait_p95 wait_max lat_p50 lat_p99 lat_max long174 long600 retry_n phases normal_n normal_p50 normal_p99 status < <(
    jq -sr --argjson cutoff "$CUTOFF" --argjson min_normal "$MIN_NORMAL_SAMPLES" '
      def n: (. // 0 | tonumber? // 0);
      def percentile($p):
        if length == 0 then 0
        else sort | .[((length - 1) * $p / 100 | floor)]
        end;
      def tool_count:
        (.tool_call_count | n) as $top
        | if $top > 0 then $top else (.tool_contract.tool_call_count | n) end;
      def turn_mode: (.turn_mode // .result_kind // "");
      def is_normal_success:
        (.outcome == "success")
        and ((tool_count > 0) or (turn_mode == "tool_use"));
      def phase_values:
        [ .. | objects | (.slot_release_at_phase? // empty)
          | select(type == "string" and length > 0) ];
      def phase_summary($values):
        if ($values | length) == 0 then "-"
        else
          ($values | sort | group_by(.)
           | map(.[0] + ":" + (length | tostring))
           | join(","))
        end;

      (.) as $all
      | ([ $all[] | select((.ts_unix // 0 | tonumber? // 0) >= $cutoff) ]) as $recent
      | ([ $recent[] | (.semaphore_wait_ms | n) | select(. > 0) ]) as $waits
      | ([ $recent[] | (.latency_ms | n) | select(. > 0) ]) as $latencies
      | ([ $recent[] | select(is_normal_success) ]) as $normal
      | ([ $normal[] | (.latency_ms | n) | select(. > 0) ]) as $normal_latencies
      | ([ $recent[] | select((.degraded_retry_applied == true) or (.degraded_retry_cascade != null)) ]) as $retries
      | ([ $recent[] | phase_values ] | add // []) as $recent_phases
      | ([ $all[] | phase_values ] | add // []) as $all_phases
      | [
          ($all | length),
          ($recent | length),
          ($waits | length),
          ($waits | percentile(95)),
          ($waits | max // 0),
          (($latencies | percentile(50)) / 1000),
          (($latencies | percentile(99)) / 1000),
          (($latencies | max // 0) / 1000),
          ([ $latencies[] | select(. >= 174000) ] | length),
          ([ $latencies[] | select(. >= 600000) ] | length),
          ($retries | length),
          phase_summary($recent_phases),
          ($normal | length),
          (($normal_latencies | percentile(50)) / 1000),
          (($normal_latencies | percentile(99)) / 1000),
          (if ($recent | length) == 0 then "NO_RECENT_DECISIONS"
           elif ($recent_phases | length) == 0 and ($all_phases | length) > 0 then "STALE:slot_release_phase_outside_window"
           elif ($recent_phases | length) == 0 then "INSUFFICIENT:no_slot_release_phase"
           elif ($normal | length) < $min_normal then "INSUFFICIENT:normal_turn_samples"
           else "EVIDENCE_AVAILABLE"
           end)
        ]
      | @tsv
    ' "$f"
  )

  printf '%-16s %6s %6s %6s %10s %10s %9.1f %9.1f %9.1f %7s %7s %7s %-36s %8s %10.1f %10.1f %s\n' \
    "$name" "$total" "$recent" "$wait_n" "$wait_p95" "$wait_max" \
    "$lat_p50" "$lat_p99" "$lat_max" "$long174" "$long600" \
    "$retry_n" "$phases" "$normal_n" "$normal_p50" "$normal_p99" "$status"
done

echo
echo "Legend:"
echo "  WAIT_*       semaphore_wait_ms in the selected window."
echo "  LAT_*        keeper turn latency seconds in the selected window."
echo "  LONG174/600  turns at or above 174s / 600s latency."
echo "  RETRY_N      decisions with degraded retry evidence."
echo "  PHASES       slot_release_at_phase values found in persisted receipts."
echo "  NORMAL_*     successful tool-use turns used for normal-turn latency evidence."
echo
echo "Closure signal:"
echo "  EVIDENCE_AVAILABLE means the selected window contains slot-release receipt"
echo "  evidence and enough normal successful turns for latency comparison."
echo "  INSUFFICIENT means #12888 still needs a live forced-retry run or newer"
echo "  persisted rows before it can be closed from runtime evidence."
