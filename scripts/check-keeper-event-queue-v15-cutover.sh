#!/usr/bin/env bash
# Read-only deployment gate for the event-queue v14 -> v15 hard cut.
#
# Usage:
#   scripts/check-keeper-event-queue-v15-cutover.sh --base-path /path/to/workspace
#   scripts/check-keeper-event-queue-v15-cutover.sh --base-path /path/to/new-workspace --allow-empty-workspace
#   scripts/check-keeper-event-queue-v15-cutover.sh --self-test

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-$(pwd)}"
ALLOW_EMPTY_WORKSPACE=0
SELF_TEST=0

usage() {
  sed -n '2,/^$/p' "$0"
}

fail() {
  printf '[event-queue-v15-cutover] FAIL: %s\n' "$*" >&2
  exit 1
}

reject_symlinks_below() {
  local root="$1"
  local label="$2"
  local symlink_path
  symlink_path="$(find "$root" -type l -print -quit)"
  [[ -z "$symlink_path" ]] \
    || fail "$label contains a symlink: $symlink_path"
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
    --allow-empty-workspace)
      ALLOW_EMPTY_WORKSPACE=1
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
  local keepers_root="$runtime_root/keepers"
  local signals_root="$runtime_root/schedules/signals"
  local schedule_ledger_count=0
  local schedules_path
  local signal_file_count=0
  local signal_row_count=0
  local signal_path
  local rows_in_file
  local queue_count=0
  local queue_path
  local pending_count
  local outbox_count
  local accepted_count

  [[ -d "$BASE_PATH" && ! -L "$BASE_PATH" ]] \
    || fail "base path is not an exact directory: $BASE_PATH"
  if [[ ! -e "$runtime_root" && ! -L "$runtime_root" ]]; then
    if [[ "$ALLOW_EMPTY_WORKSPACE" -eq 1 ]]; then
      printf '[event-queue-v15-cutover] OK: base_path=%s empty_workspace=allowed\n' \
        "$BASE_PATH"
      return
    fi
    fail "workspace runtime not found: $runtime_root (wrong --base-path? pass --allow-empty-workspace only for an intentional new workspace)"
  fi
  [[ -d "$runtime_root" && ! -L "$runtime_root" ]] \
    || fail "workspace runtime is not an exact directory: $runtime_root"

  for schedules_path in \
    "$runtime_root/schedules.json" \
    "$runtime_root/schedules.json.last-good"; do
    if [[ ! -e "$schedules_path" && ! -L "$schedules_path" ]]; then
      continue
    fi
    schedule_ledger_count=$((schedule_ledger_count + 1))
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
    local unsettled_count
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
  done

  if [[ -e "$signals_root" || -L "$signals_root" ]]; then
    [[ -d "$signals_root" && ! -L "$signals_root" ]] \
      || fail "schedule signal store is not an exact directory: $signals_root"
    reject_symlinks_below "$signals_root" "schedule signal store"
    while IFS= read -r -d '' signal_path; do
      signal_file_count=$((signal_file_count + 1))
      [[ -f "$signal_path" && ! -L "$signal_path" ]] \
        || fail "schedule signal segment is not an exact regular file: $signal_path"
      rows_in_file="$(
        jq -c '
          if type == "object"
             and .event_type == "schedule.due_candidate"
             and (.occurrence_id | type == "string" and length > 0)
             and (.schedule_instance_id | type == "string" and length > 0)
             and (.schedule_id | type == "string" and length > 0)
             and (.emitted_at | type == "number")
             and (.due_at | type == "number")
             and (.payload_digest | type == "string" and length > 0)
             and (.payload | type == "object")
          then .
          else error("schedule signal row does not satisfy the current contract")
          end
        ' "$signal_path" | wc -l | tr -d ' '
      )" || fail "schedule signal segment contains malformed or pre-cut rows: $signal_path"
      signal_row_count=$((signal_row_count + rows_in_file))
    done < <(find "$signals_root" -name '*.jsonl' -print0)
  fi

  if [[ -e "$keepers_root" || -L "$keepers_root" ]]; then
    [[ -d "$keepers_root" && ! -L "$keepers_root" ]] \
      || fail "Keeper runtime root is not an exact directory: $keepers_root"
    reject_symlinks_below "$keepers_root" "Keeper runtime root"
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

  printf '[event-queue-v15-cutover] OK: base_path=%s schedule_ledgers=%d signal_files=%d signal_rows=%d v14_owners=%d unsettled=0\n' \
    "$BASE_PATH" "$schedule_ledger_count" "$signal_file_count" \
    "$signal_row_count" "$queue_count"
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

  write_signal() {
    local target_root="$1"
    local include_instance="$2"
    local signal_dir="$target_root/.masc/schedules/signals/2026-08"
    mkdir -p "$signal_dir"
    jq -cn --argjson include_instance "$include_instance" '
      {event_type: "schedule.due_candidate",
       occurrence_id: "occurrence-fixture",
       schedule_id: "schedule-fixture",
       emitted_at: 1,
       due_at: 1,
       payload_digest: "payload-fixture",
       payload: {kind: "fixture"}}
      + (if $include_instance
         then {schedule_instance_id: "instance-fixture"}
         else {}
         end)
    ' >"$signal_dir/04.jsonl"
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
  write_signal "$safe_root" true
  cp "$safe_root/.masc/schedules.json" \
    "$safe_root/.masc/schedules.json.last-good"
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

  symlinked_keepers_root="$fixture_root/symlinked-keepers"
  symlinked_keepers_target="$fixture_root/symlinked-keepers-target"
  write_schedules "$symlinked_keepers_root" none
  write_queue "$symlinked_keepers_target" 1 0 0
  ln -s "$symlinked_keepers_target/.masc/keepers" \
    "$symlinked_keepers_root/.masc/keepers"
  expect_failure symlinked_keepers_root "$symlinked_keepers_root"

  pre_cut_root="$fixture_root/pre-cut-schedule"
  mkdir -p "$pre_cut_root/.masc"
  jq -n '
    {version: 1,
     schedules: [{schedule_id: "legacy-schedule"}],
     executions: []}
  ' >"$pre_cut_root/.masc/schedules.json"
  expect_failure pre_cut_schedule "$pre_cut_root"

  pre_cut_recovery_root="$fixture_root/pre-cut-recovery"
  write_schedules "$pre_cut_recovery_root" succeeded
  jq -n '
    {version: 1,
     schedules: [{schedule_id: "pre-cut-schedule"}],
     executions: []}
  ' >"$pre_cut_recovery_root/.masc/schedules.json.last-good"
  expect_failure pre_cut_recovery "$pre_cut_recovery_root"

  pre_cut_signal_root="$fixture_root/pre-cut-signal"
  write_schedules "$pre_cut_signal_root" succeeded
  write_signal "$pre_cut_signal_root" false
  expect_failure pre_cut_signal "$pre_cut_signal_root"

  malformed_signal_root="$fixture_root/malformed-signal"
  write_schedules "$malformed_signal_root" succeeded
  mkdir -p "$malformed_signal_root/.masc/schedules/signals/2026-08"
  printf '{not-json\n' \
    >"$malformed_signal_root/.masc/schedules/signals/2026-08/04.jsonl"
  expect_failure malformed_signal "$malformed_signal_root"

  missing_runtime_root="$fixture_root/missing-runtime"
  mkdir -p "$missing_runtime_root"
  expect_failure missing_runtime "$missing_runtime_root"
  "$0" \
    --base-path "$missing_runtime_root" \
    --allow-empty-workspace \
    >/dev/null

  printf '[event-queue-v15-cutover] self-test OK\n'
  exit 0
fi

run_gate
