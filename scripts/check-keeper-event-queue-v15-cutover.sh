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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CUTOVER_HELPER="${MASC_EVENT_QUEUE_V15_CUTOVER_HELPER:-}"

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

if [[ -z "$CUTOVER_HELPER" ]]; then
  if [[ -x "$REPO_ROOT/_build/default/bin/keeper_event_queue_v15_cutover_helper.exe" ]]; then
    CUTOVER_HELPER="$REPO_ROOT/_build/default/bin/keeper_event_queue_v15_cutover_helper.exe"
  else
    fail "typed cutover helper is required (build bin/keeper_event_queue_v15_cutover_helper.exe or set MASC_EVENT_QUEUE_V15_CUTOVER_HELPER)"
  fi
fi
[[ -x "$CUTOVER_HELPER" ]] || fail "typed cutover helper is not executable: $CUTOVER_HELPER"

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
  local cutover_required=0
  local current_owner_count=0
  local legacy_wal_count=0
  local queue_count=0
  local queue_path
  local current_queue_path
  local pending_count
  local outbox_count
  local accepted_count
  local unsettled_count_total=0

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

  if [[ -e "$keepers_root" || -L "$keepers_root" ]]; then
    [[ -d "$keepers_root" && ! -L "$keepers_root" ]] \
      || fail "Keeper runtime root is not an exact directory: $keepers_root"
    reject_symlinks_below "$keepers_root" "Keeper runtime root"
    while IFS= read -r -d '' queue_path; do
      legacy_wal_count=$((legacy_wal_count + 1))
      [[ -f "$queue_path" && ! -L "$queue_path" ]] \
        || fail "v4 transition WAL is not an exact regular file: $queue_path"
      [[ ! -s "$queue_path" ]] \
        || fail "v4 transition WAL still contains committed evidence: $queue_path"
      current_queue_path="$(dirname "$queue_path")/event-queue-v15.json"
      if [[ ! -e "$current_queue_path" && ! -L "$current_queue_path" ]]; then
        cutover_required=1
      fi
    done < <(find "$keepers_root" -name 'event-queue-transitions-v4.jsonl' -print0)

    while IFS= read -r -d '' current_queue_path; do
      [[ -f "$current_queue_path" && ! -L "$current_queue_path" ]] \
        || fail "v15 queue snapshot is not an exact regular file: $current_queue_path"
      "$CUTOVER_HELPER" validate-current-queue "$current_queue_path" \
        || fail "v15 queue snapshot is invalid: $current_queue_path"
      current_owner_count=$((current_owner_count + 1))
    done < <(find "$keepers_root" -name 'event-queue-v15.json' -print0)

    while IFS= read -r -d '' queue_path; do
      current_queue_path="$(dirname "$queue_path")/event-queue-v15.json"
      if [[ ! -e "$current_queue_path" && ! -L "$current_queue_path" ]]; then
        cutover_required=1
      fi
    done < <(find "$keepers_root" -name 'event-queue-v14.json' -print0)
  fi

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
    unsettled_count_total=$((unsettled_count_total + unsettled_count))
    if [[ "$cutover_required" -eq 1 && "$unsettled_count" -ne 0 ]]; then
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
      rows_in_file="$("$CUTOVER_HELPER" validate-signals "$signal_path")" \
        || fail "schedule signal segment contains malformed or pre-cut rows: $signal_path"
      [[ "$rows_in_file" =~ ^[0-9]+$ ]] \
        || fail "typed signal validator returned an invalid row count: $rows_in_file"
      signal_row_count=$((signal_row_count + rows_in_file))
    done < <(find "$signals_root" -name '*.jsonl' -print0)
  fi

  if [[ -e "$keepers_root" || -L "$keepers_root" ]]; then
    [[ -d "$keepers_root" && ! -L "$keepers_root" ]] \
      || fail "Keeper runtime root is not an exact directory: $keepers_root"
    reject_symlinks_below "$keepers_root" "Keeper runtime root"
    while IFS= read -r -d '' queue_path; do
      current_queue_path="$(dirname "$queue_path")/event-queue-v15.json"
      if [[ -e "$current_queue_path" || -L "$current_queue_path" ]]; then
        continue
      fi
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

  printf '[event-queue-v15-cutover] OK: base_path=%s cutover_required=%d schedule_ledgers=%d signal_files=%d signal_rows=%d v14_owners=%d current_owners=%d legacy_wals=%d unsettled=%d\n' \
    "$BASE_PATH" "$cutover_required" "$schedule_ledger_count" \
    "$signal_file_count" "$signal_row_count" "$queue_count" \
    "$current_owner_count" "$legacy_wal_count" "$unsettled_count_total"
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
       occurrence_id: "bd1ec0652900d5f5d24968875fa05cb6c2386ccd1fa75ca9582eefe93a2a7906",
       schedule_id: "schedule-fixture",
       emitted_at: 1,
       due_at: 1,
       payload_digest: "d5cba4a1998d29ccaae48a7f9fef641e4fbb91b11299f8ba03005d5786ff6edc",
       payload: {kind: "consumer.note", schema_version: 1,
                 body: {text: "fixture"}}}
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

  write_current_queue() {
    local target_root="$1"
    local queue_dir="$target_root/.masc/keepers/fixture"
    mkdir -p "$queue_dir"
    jq -n '
      {schema: "keeper.event_queue.state.v15", revision: 1,
       pending: [], last_transition: null,
       projected_dispositions: [], transition_outbox: [],
       accepted_transfer_projections: []}
    ' >"$queue_dir/event-queue-v15.json"
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
  if "$CUTOVER_HELPER" \
      lease-run \
      --base-path "$safe_root" \
      -- \
      env -u MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID \
      "$0" --base-path "$safe_root" \
      >/dev/null 2>&1
  then
    fail "self-test expected an active BasePath writer lease to block cutover"
  fi

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

  legacy_wal_root="$fixture_root/legacy-wal"
  write_schedules "$legacy_wal_root" none
  write_queue "$legacy_wal_root" 0 0 0
  printf '{"committed":"transition"}\n' \
    >"$legacy_wal_root/.masc/keepers/fixture/event-queue-transitions-v4.jsonl"
  expect_failure nonempty_v4_transition_wal "$legacy_wal_root"

  current_root="$fixture_root/current"
  write_schedules "$current_root" running
  write_queue "$current_root" 1 1 1
  write_current_queue "$current_root"
  : >"$current_root/.masc/keepers/fixture/event-queue-transitions-v4.jsonl"
  "$0" --base-path "$current_root" >/dev/null

  malformed_current_root="$fixture_root/malformed-current"
  write_schedules "$malformed_current_root" running
  write_queue "$malformed_current_root" 1 1 1
  printf '{not-json\n' \
    >"$malformed_current_root/.masc/keepers/fixture/event-queue-v15.json"
  expect_failure malformed_current_queue "$malformed_current_root"

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

  stale_occurrence_signal_root="$fixture_root/stale-occurrence-signal"
  write_schedules "$stale_occurrence_signal_root" succeeded
  write_signal "$stale_occurrence_signal_root" true
  jq -c '.occurrence_id = "stale-occurrence"' \
    "$stale_occurrence_signal_root/.masc/schedules/signals/2026-08/04.jsonl" \
    >"$stale_occurrence_signal_root/.masc/schedules/signals/2026-08/04.jsonl.tmp"
  mv \
    "$stale_occurrence_signal_root/.masc/schedules/signals/2026-08/04.jsonl.tmp" \
    "$stale_occurrence_signal_root/.masc/schedules/signals/2026-08/04.jsonl"
  expect_failure stale_occurrence_signal "$stale_occurrence_signal_root"

  malformed_signal_root="$fixture_root/malformed-signal"
  write_schedules "$malformed_signal_root" succeeded
  mkdir -p "$malformed_signal_root/.masc/schedules/signals/2026-08"
  printf '{not-json\n' \
    >"$malformed_signal_root/.masc/schedules/signals/2026-08/04.jsonl"
  expect_failure malformed_signal "$malformed_signal_root"

  multiline_signal_root="$fixture_root/multiline-signal"
  write_schedules "$multiline_signal_root" succeeded
  write_signal "$multiline_signal_root" true
  jq '.' "$multiline_signal_root/.masc/schedules/signals/2026-08/04.jsonl" \
    >"$multiline_signal_root/.masc/schedules/signals/2026-08/04.jsonl.tmp"
  mv \
    "$multiline_signal_root/.masc/schedules/signals/2026-08/04.jsonl.tmp" \
    "$multiline_signal_root/.masc/schedules/signals/2026-08/04.jsonl"
  expect_failure multiline_signal "$multiline_signal_root"

  multi_value_signal_root="$fixture_root/multi-value-signal"
  write_schedules "$multi_value_signal_root" succeeded
  write_signal "$multi_value_signal_root" true
  signal_fixture="$multi_value_signal_root/.masc/schedules/signals/2026-08/04.jsonl"
  signal_row="$(cat "$signal_fixture")"
  printf '%s %s\n' "$signal_row" "$signal_row" >"$signal_fixture"
  expect_failure multiple_values_on_one_signal_line "$multi_value_signal_root"

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

if [[ "${MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID:-}" != "$PPID" ]]; then
  runtime_root="$BASE_PATH/.masc"
  if [[ ! -e "$runtime_root" && ! -L "$runtime_root" ]]; then
    if [[ "$ALLOW_EMPTY_WORKSPACE" -eq 1 ]]; then
      printf '[event-queue-v15-cutover] OK: base_path=%s empty_workspace=allowed\n' \
        "$BASE_PATH"
      exit 0
    fi
    fail "workspace runtime not found: $runtime_root (wrong --base-path? pass --allow-empty-workspace only for an intentional new workspace)"
  fi
  helper_args=(
    lease-run
    --base-path "$BASE_PATH"
    --
    "$0"
    --base-path "$BASE_PATH"
  )
  if [[ "$ALLOW_EMPTY_WORKSPACE" -eq 1 ]]; then
    helper_args+=(--allow-empty-workspace)
  fi
  exec "$CUTOVER_HELPER" "${helper_args[@]}"
fi

run_gate
