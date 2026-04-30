#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DEFAULT_PHASES="control,search"
PHASES="${INTEGRATED_BENCH_PHASES:-$DEFAULT_PHASES}"
OUTPUT_DIR="${INTEGRATED_BENCH_OUTPUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/masc-integrated-benchmark.XXXXXX")}"
FAIL_FAST="${INTEGRATED_BENCH_FAIL_FAST:-false}"
DRY_RUN="${INTEGRATED_BENCH_DRY_RUN:-false}"
SUMMARY_JSONL="$OUTPUT_DIR/summary.jsonl"
SUMMARY_JSON="$OUTPUT_DIR/summary.json"
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
FAILED=0

require_tools() {
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required" >&2
    exit 1
  }
  command -v rg >/dev/null 2>&1 || {
    echo "rg is required" >&2
    exit 1
  }
}

phase_script() {
  case "$1" in
    control)
      printf '%s\n' "$ROOT_DIR/scripts/harness_agent_swarm_live.sh"
      ;;
    search)
      printf '%s\n' "$ROOT_DIR/scripts/harness_cp_search_fabric.sh"
      ;;
    *)
      return 1
      ;;
  esac
}

json_bool() {
  case "$1" in
    true|false)
      printf '%s\n' "$1"
      ;;
    *)
      echo "expected boolean true/false, got: $1" >&2
      exit 1
      ;;
  esac
}

build_phase_payload() {
  local phase="$1"
  local script_path="$2"
  local log_path="$3"
  local status="$4"
  local exit_code="$5"
  local started_at="$6"
  local finished_at="$7"
  local session_id="$8"
  local metrics_json="$9"

  jq -cn \
    --arg phase "$phase" \
    --arg script "$script_path" \
    --arg log_path "$log_path" \
    --arg status "$status" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --argjson exit_code "$exit_code" \
    --argjson session_id "$session_id" \
    --argjson metrics "$metrics_json" \
    '{
      phase: $phase,
      script: $script,
      log_path: $log_path,
      status: $status,
      exit_code: $exit_code,
      started_at: $started_at,
      finished_at: $finished_at,
      session_id: $session_id,
      metrics: $metrics
    }'
}

require_tools
mkdir -p "$OUTPUT_DIR"
: >"$SUMMARY_JSONL"

IFS=',' read -r -a REQUESTED_PHASES <<<"$PHASES"
if [ "${#REQUESTED_PHASES[@]}" -eq 0 ]; then
  echo "no benchmark phases requested" >&2
  exit 1
fi

phase_index=0
for raw_phase in "${REQUESTED_PHASES[@]}"; do
  phase="$(printf '%s' "$raw_phase" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$phase" ]; then
    continue
  fi
  if ! script_path="$(phase_script "$phase")"; then
    echo "unknown benchmark phase: $phase" >&2
    exit 1
  fi

  phase_index=$((phase_index + 1))
  log_path="$OUTPUT_DIR/$(printf '%02d' "$phase_index")-${phase}.log"
  phase_started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [ "$DRY_RUN" = "true" ]; then
    build_phase_payload \
      "$phase" \
      "$script_path" \
      "$log_path" \
      "planned" \
      0 \
      "$phase_started_at" \
      "$phase_started_at" \
      "null" \
      "null" >>"$SUMMARY_JSONL"
    continue
  fi

  set +e
  "$script_path" >"$log_path" 2>&1
  exit_code=$?
  set -e

  phase_finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  status="pass"
  session_id_json="null"
  metrics_json="null"

  if [ "$exit_code" -ne 0 ]; then
    status="fail"
    FAILED=1
  fi

  case "$phase" in
    search)
      search_json="$(
        awk '
          /^\{/ { start = NR }
          { lines[NR] = $0 }
          END {
            if (start == 0) {
              exit 1
            }
            for (i = start; i <= NR; i++) {
              print lines[i]
            }
          }
        ' "$log_path" 2>/dev/null || true
      )"
      if [ -n "$search_json" ] && printf '%s' "$search_json" | jq -e . >/dev/null 2>&1; then
        metrics_json="$(printf '%s' "$search_json" | jq -c .)"
      fi
      ;;
  esac

  build_phase_payload \
    "$phase" \
    "$script_path" \
    "$log_path" \
    "$status" \
    "$exit_code" \
    "$phase_started_at" \
    "$phase_finished_at" \
    "$session_id_json" \
    "$metrics_json" >>"$SUMMARY_JSONL"

  if [ "$status" = "fail" ] && [ "$FAIL_FAST" = "true" ]; then
    break
  fi
done

if [ "$phase_index" -eq 0 ]; then
  echo "no valid benchmark phases were selected" >&2
  exit 1
fi

dry_run_json="$(json_bool "$DRY_RUN")"
jq -s \
  --arg started_at "$STARTED_AT" \
  --arg finished_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg output_dir "$OUTPUT_DIR" \
  --argjson dry_run "$dry_run_json" \
  '{
    started_at: $started_at,
    finished_at: $finished_at,
    dry_run: $dry_run,
    output_dir: $output_dir,
    phases: .,
    overall: {
      phase_count: length,
      passed: (map(select(.status == "pass")) | length),
      failed: (map(select(.status == "fail")) | length),
      planned: (map(select(.status == "planned")) | length),
      ok: (all(.[]; .status != "fail"))
    }
  }' "$SUMMARY_JSONL" >"$SUMMARY_JSON"

jq . "$SUMMARY_JSON"
echo
echo "summary=$SUMMARY_JSON"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
