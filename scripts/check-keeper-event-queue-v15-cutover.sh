#!/usr/bin/env bash
# Read-only deployment gate for the event-queue v14 -> v15 hard cut.
#
# Usage:
#   scripts/check-keeper-event-queue-v15-cutover.sh --base-path /path/to/workspace
#   scripts/check-keeper-event-queue-v15-cutover.sh --self-test

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-$(pwd)}"
SELF_TEST=0

usage() {
  sed -n '2,/^$/p' "$0"
}

fail() {
  printf '[event-queue-v15-cutover] FAIL: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path)
      [[ $# -ge 2 ]] || fail "--base-path requires a value"
      BASE_PATH="$2"
      shift 2
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown flag: $1"
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"

run_gate() {
  local runtime_root="$BASE_PATH/.masc"
  local schedules_path="$runtime_root/schedules.json"
  local keepers_root="$runtime_root/keepers"
  local unsettled_count=0
  local queue_count=0
  local queue_path
  local pending_count
  local outbox_count
  local accepted_count

  if [[ -e "$schedules_path" || -L "$schedules_path" ]]; then
    [[ -f "$schedules_path" && ! -L "$schedules_path" ]] \
      || fail "schedule ledger is not an exact regular file: $schedules_path"
    jq -e '
      type == "object"
      and (.schedules | type == "array")
      and (.executions | type == "array")
      and all(.executions[];
        type == "object"
        and (.status == "running"
          or .status == "dispatched"
          or .status == "succeeded"
          or .status == "failed"))
    ' "$schedules_path" >/dev/null \
      || fail "schedule ledger shape is invalid: $schedules_path"
    unsettled_count="$(jq '[.executions[] | select(.status == "running" or .status == "dispatched")] | length' "$schedules_path")"
    if [[ "$unsettled_count" -ne 0 ]]; then
      jq -r '
        .executions[]
        | select(.status == "running" or .status == "dispatched")
        | "  execution_id=\(.execution_id // "<missing>") schedule_id=\(.schedule_id // "<missing>") status=\(.status)"
      ' "$schedules_path" >&2
      fail "schedule ledger still has $unsettled_count unsettled execution(s)"
    fi
    jq -e '
      all(.schedules[];
        type == "object"
        and (.schedule_instance_id | type == "string" and length > 0))
      and all(.executions[];
        type == "object"
        and (.schedule_instance_id | type == "string" and length > 0))
    ' "$schedules_path" >/dev/null \
      || fail "schedule ledger contains pre-cut rows without a current schedule instance id: $schedules_path"
  fi

  if [[ -d "$keepers_root" ]]; then
    while IFS= read -r -d '' queue_path; do
      queue_count=$((queue_count + 1))
      [[ -f "$queue_path" && ! -L "$queue_path" ]] \
        || fail "v14 queue snapshot is not an exact regular file: $queue_path"
      jq -e '
        type == "object"
        and .schema == "keeper.event_queue.state.v14"
        and (.pending | type == "array")
        and (.transition_outbox | type == "array")
        and (.accepted_transfer_projections | type == "array")
        and (.projected_dispositions | type == "array")
      ' "$queue_path" >/dev/null \
        || fail "v14 queue snapshot shape is invalid: $queue_path"
      pending_count="$(jq '.pending | length' "$queue_path")"
      outbox_count="$(jq '.transition_outbox | length' "$queue_path")"
      accepted_count="$(jq '.accepted_transfer_projections | length' "$queue_path")"
      if [[ "$pending_count" -ne 0 || "$outbox_count" -ne 0 || "$accepted_count" -ne 0 ]]; then
        fail "v14 queue is not drained: $queue_path pending=$pending_count transition_outbox=$outbox_count accepted_transfer_projections=$accepted_count"
      fi
    done < <(find "$keepers_root" -name 'event-queue-v14.json' -print0)
  fi

  printf '[event-queue-v15-cutover] OK: base_path=%s v14_owners=%d unsettled=0\n' \
    "$BASE_PATH" "$queue_count"
}

if [[ "$SELF_TEST" -eq 1 ]]; then
  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/event-queue-v15-cutover.XXXXXX")"
  trap 'rm -rf "$fixture_root"' EXIT

  write_schedules() {
    local target_root="$1"
    local status="$2"
    mkdir -p "$target_root/.masc"
    jq -n --arg status "$status" '
      {version: 1, schedules: [], executions:
        (if $status == "none" then []
         else [{execution_id: "exec-fixture", schedule_instance_id: "instance-fixture",
                schedule_id: "schedule-fixture", status: $status}]
         end)}
    ' >"$target_root/.masc/schedules.json"
  }

  write_queue() {
    local target_root="$1"
    local pending="$2"
    local outbox="$3"
    local accepted="$4"
    local queue_dir="$target_root/.masc/keepers/fixture"
    mkdir -p "$queue_dir"
    jq -n \
      --argjson pending "$pending" \
      --argjson outbox "$outbox" \
      --argjson accepted "$accepted" '
      {schema: "keeper.event_queue.state.v14", revision: 1,
       pending: (if $pending == 0 then [] else [{}] end),
       last_transition: {operation_id: "terminal-evidence"},
       projected_dispositions: [{operation_id: "terminal-evidence"}],
       transition_outbox: (if $outbox == 0 then [] else [{}] end),
       accepted_transfer_projections: (if $accepted == 0 then [] else [{}] end)}
    ' >"$queue_dir/event-queue-v14.json"
  }

  expect_failure() {
    local case_name="$1"
    local target_root="$2"
    if "$0" --base-path "$target_root" >/dev/null 2>&1; then
      fail "self-test expected failure: $case_name"
    fi
  }

  safe_root="$fixture_root/safe"
  write_schedules "$safe_root" succeeded
  write_queue "$safe_root" 0 0 0
  "$0" --base-path "$safe_root" >/dev/null

  dispatched_root="$fixture_root/dispatched"
  write_schedules "$dispatched_root" dispatched
  write_queue "$dispatched_root" 0 0 0
  expect_failure dispatched_execution "$dispatched_root"

  running_root="$fixture_root/running"
  write_schedules "$running_root" running
  write_queue "$running_root" 0 0 0
  expect_failure running_execution "$running_root"

  pending_root="$fixture_root/pending"
  write_schedules "$pending_root" none
  write_queue "$pending_root" 1 0 0
  expect_failure pending_work "$pending_root"

  outbox_root="$fixture_root/outbox"
  write_schedules "$outbox_root" none
  write_queue "$outbox_root" 0 1 0
  expect_failure transition_outbox "$outbox_root"

  accepted_root="$fixture_root/accepted"
  write_schedules "$accepted_root" none
  write_queue "$accepted_root" 0 0 1
  expect_failure accepted_transfer "$accepted_root"

  malformed_root="$fixture_root/malformed"
  mkdir -p "$malformed_root/.masc"
  printf '{not-json\n' >"$malformed_root/.masc/schedules.json"
  expect_failure malformed_ledger "$malformed_root"

  malformed_queue_root="$fixture_root/malformed-queue"
  write_schedules "$malformed_queue_root" none
  mkdir -p "$malformed_queue_root/.masc/keepers/fixture"
  printf '{not-json\n' \
    >"$malformed_queue_root/.masc/keepers/fixture/event-queue-v14.json"
  expect_failure malformed_queue "$malformed_queue_root"

  pre_cut_root="$fixture_root/pre-cut-schedule"
  mkdir -p "$pre_cut_root/.masc"
  jq -n '
    {version: 1,
     schedules: [{schedule_id: "legacy-schedule"}],
     executions: []}
  ' >"$pre_cut_root/.masc/schedules.json"
  expect_failure pre_cut_schedule "$pre_cut_root"

  printf '[event-queue-v15-cutover] self-test OK\n'
  exit 0
fi

run_gate
