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
RUNTIME_ABSENT_BEFORE_LEASE=0
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
    --runtime-absent-before-lease)
      RUNTIME_ABSENT_BEFORE_LEASE=1
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
  local schedule_report
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
  local keeper_name
  local pending_count
  local outbox_count
  local accepted_count
  local unsettled_count_total=0

  [[ -d "$BASE_PATH" && ! -L "$BASE_PATH" ]] \
    || fail "base path is not an exact directory: $BASE_PATH"
  if [[ "$RUNTIME_ABSENT_BEFORE_LEASE" -eq 1 \
        && "$ALLOW_EMPTY_WORKSPACE" -ne 1 ]]; then
    fail "workspace runtime was absent before lease acquisition: $runtime_root (wrong --base-path? pass --allow-empty-workspace only for an intentional new workspace)"
  fi
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
    done < <(find "$keepers_root" -mindepth 2 -maxdepth 2 -name 'event-queue-transitions-v4.jsonl' -print0)

    while IFS= read -r -d '' current_queue_path; do
      [[ -f "$current_queue_path" && ! -L "$current_queue_path" ]] \
        || fail "v15 queue snapshot is not an exact regular file: $current_queue_path"
      keeper_name="${current_queue_path%/*}"
      keeper_name="${keeper_name##*/}"
      "$CUTOVER_HELPER" validate-current-queue \
        --base-path "$BASE_PATH" \
        --keeper-name "$keeper_name" \
        || fail "v15 queue snapshot or v5 transition WAL is invalid: $current_queue_path"
      current_owner_count=$((current_owner_count + 1))
    done < <(find "$keepers_root" -mindepth 2 -maxdepth 2 -name 'event-queue-v15.json' -print0)

    while IFS= read -r -d '' queue_path; do
      [[ -f "$queue_path" && ! -L "$queue_path" ]] \
        || fail "v5 transition WAL is not an exact regular file: $queue_path"
      current_queue_path="$(dirname "$queue_path")/event-queue-v15.json"
      if [[ -e "$current_queue_path" || -L "$current_queue_path" ]]; then
        continue
      fi
      keeper_name="${queue_path%/*}"
      keeper_name="${keeper_name##*/}"
      "$CUTOVER_HELPER" validate-current-wal \
        --base-path "$BASE_PATH" \
        --keeper-name "$keeper_name" \
        || fail "v5 transition WAL is invalid: $queue_path"
      current_owner_count=$((current_owner_count + 1))
    done < <(find "$keepers_root" -mindepth 2 -maxdepth 2 -name 'event-queue-transitions-v5.jsonl' -print0)

    while IFS= read -r -d '' queue_path; do
      current_queue_path="$(dirname "$queue_path")/event-queue-v15.json"
      if [[ ! -e "$current_queue_path" && ! -L "$current_queue_path" ]]; then
        cutover_required=1
      fi
    done < <(find "$keepers_root" -mindepth 2 -maxdepth 2 -name 'event-queue-v14.json' -print0)
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
    schedule_report="$("$CUTOVER_HELPER" validate-schedule-ledger "$schedules_path")" \
      || fail "schedule ledger contract is invalid: $schedules_path"
    local unsettled_count
    unsettled_count="$(jq -er '.unsettled_count' <<<"$schedule_report")" \
      || fail "typed schedule validator returned an invalid result: $schedules_path"
    unsettled_count_total=$((unsettled_count_total + unsettled_count))
    if [[ "$cutover_required" -eq 1 && "$unsettled_count" -ne 0 ]]; then
      jq -r '
        .unsettled[]
        | "  execution_id=\(.execution_id) schedule_id=\(.schedule_id) status=\(.status)"
      ' <<<"$schedule_report" >&2
      fail "schedule ledger still has $unsettled_count unsettled execution(s)"
    fi
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
    done < <(find "$keepers_root" -mindepth 2 -maxdepth 2 -name 'event-queue-v14.json' -print0)
  fi

  printf '[event-queue-v15-cutover] OK: base_path=%s cutover_required=%d schedule_ledgers=%d signal_files=%d signal_rows=%d v14_owners=%d current_owners=%d legacy_wals=%d unsettled=%d\n' \
    "$BASE_PATH" "$cutover_required" "$schedule_ledger_count" \
    "$signal_file_count" "$signal_row_count" "$queue_count" \
    "$current_owner_count" "$legacy_wal_count" "$unsettled_count_total"
}

if [[ "$SELF_TEST" -eq 1 ]]; then
  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/event-queue-v15-cutover.XXXXXX")"
  trap 'if [[ -n "${handoff_pid:-}" ]]; then kill "$handoff_pid" 2>/dev/null || true; fi; if [[ -n "${cancel_handoff_pid:-}" ]]; then kill "$cancel_handoff_pid" 2>/dev/null || true; fi; rm -rf "$fixture_root"' EXIT

  write_schedules() {
    local target_root="$1"
    local status="$2"
    mkdir -p "$target_root/.masc"
    jq -n --arg status "$status" '
      {version: 1, updated_at: 1, schedules: [], executions:
        (if $status == "none" then []
         else [{execution_id: "exec-fixture", schedule_instance_id: "instance-fixture",
                schedule_id: "schedule-fixture", started_at: 1, finished_at: null,
                due_at: 1, payload_digest: "digest-fixture", status: $status,
                detail: null, error: null}]
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
  # Expansion belongs to the nested shell.
  # shellcheck disable=SC2016
  "$CUTOVER_HELPER" \
    lease-run \
    --base-path "$safe_root" \
    -- \
    /bin/sh -c '"$1" --base-path "$2"' nested-lease-check "$0" "$safe_root" \
    >/dev/null
  if MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID="$$" \
      "$0" --base-path "$safe_root" >/dev/null 2>&1
  then
    fail "self-test accepted a forged BasePath lease owner without a held lease"
  fi
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

  malformed_current_wal_root="$fixture_root/malformed-current-wal"
  write_schedules "$malformed_current_wal_root" running
  write_current_queue "$malformed_current_wal_root"
  printf '{not-json\n' \
    >"$malformed_current_wal_root/.masc/keepers/fixture/event-queue-transitions-v5.jsonl"
  expect_failure malformed_current_wal "$malformed_current_wal_root"

  wal_only_root="$fixture_root/wal-only"
  write_schedules "$wal_only_root" running
  mkdir -p "$wal_only_root/.masc/keepers/fixture"
  : >"$wal_only_root/.masc/keepers/fixture/event-queue-transitions-v5.jsonl"
  "$0" --base-path "$wal_only_root" >/dev/null

  malformed_wal_only_root="$fixture_root/malformed-wal-only"
  write_schedules "$malformed_wal_only_root" running
  mkdir -p "$malformed_wal_only_root/.masc/keepers/fixture"
  printf '{not-json\n' \
    >"$malformed_wal_only_root/.masc/keepers/fixture/event-queue-transitions-v5.jsonl"
  expect_failure malformed_wal_without_snapshot "$malformed_wal_only_root"

  malformed_root="$fixture_root/malformed"
  mkdir -p "$malformed_root/.masc"
  printf '{not-json\n' >"$malformed_root/.masc/schedules.json"
  expect_failure malformed_ledger "$malformed_root"

  incomplete_contract_root="$fixture_root/incomplete-contract"
  mkdir -p "$incomplete_contract_root/.masc"
  jq -n '{version: 1, schedules: [], executions: []}' \
    >"$incomplete_contract_root/.masc/schedules.json"
  expect_failure incomplete_schedule_contract "$incomplete_contract_root"

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
    {version: 1, updated_at: 1,
     schedules: [{schedule_id: "legacy-schedule"}],
     executions: []}
  ' >"$pre_cut_root/.masc/schedules.json"
  expect_failure pre_cut_schedule "$pre_cut_root"

  pre_cut_recovery_root="$fixture_root/pre-cut-recovery"
  write_schedules "$pre_cut_recovery_root" succeeded
  jq -n '
    {version: 1, updated_at: 1,
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

  leased_empty_root="$fixture_root/leased-empty"
  mkdir -p "$leased_empty_root"
  if "$CUTOVER_HELPER" \
      lease-run \
      --base-path "$leased_empty_root" \
      -- \
      env -u MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID \
      "$0" \
      --base-path "$leased_empty_root" \
      --allow-empty-workspace \
      >/dev/null 2>&1
  then
    fail "self-test expected an active lease to block allow-empty-workspace"
  fi

  failed_handoff_root="$fixture_root/failed-handoff"
  mkdir -p "$failed_handoff_root"
  if "$CUTOVER_HELPER" \
      lease-handoff \
      --base-path "$failed_handoff_root" \
      --next-executable /usr/bin/true \
      -- \
      /usr/bin/false \
      >/dev/null 2>&1
  then
    fail "self-test expected a failed preparation to abort handoff"
  fi
  "$CUTOVER_HELPER" \
    lease-run \
    --base-path "$failed_handoff_root" \
    -- \
    /usr/bin/true \
    >/dev/null

  cancel_handoff_root="$fixture_root/cancel-handoff"
  cancel_child_file="$fixture_root/cancel-child-pid"
  cancel_grandchild_file="$fixture_root/cancel-grandchild-pid"
  cancel_prepare="$fixture_root/cancel-prepare.sh"
  mkdir -p "$cancel_handoff_root"
  # Expansion belongs to the generated script.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$$" >"$MASC_CUTOVER_CHILD_PID"' \
    'trap "exit 143" TERM INT' \
    'sleep 30 &' \
    'printf "%s\n" "$!" >"$MASC_CUTOVER_GRANDCHILD_PID"' \
    'wait' \
    >"$cancel_prepare"
  chmod 700 "$cancel_prepare"
  MASC_CUTOVER_CHILD_PID="$cancel_child_file" \
  MASC_CUTOVER_GRANDCHILD_PID="$cancel_grandchild_file" \
    "$CUTOVER_HELPER" \
      lease-handoff \
      --base-path "$cancel_handoff_root" \
      --next-executable /usr/bin/true \
      -- \
      "$cancel_prepare" \
      >/dev/null 2>&1 &
  cancel_handoff_pid=$!
  for _ in $(seq 1 50); do
    [[ -e "$cancel_child_file" && -e "$cancel_grandchild_file" ]] && break
    kill -0 "$cancel_handoff_pid" 2>/dev/null \
      || fail "self-test cancellable preparation exited before starting"
    sleep 0.02
  done
  [[ -e "$cancel_child_file" && -e "$cancel_grandchild_file" ]] \
    || fail "self-test cancellable preparation did not start"
  cancel_child_pid="$(cat "$cancel_child_file")"
  cancel_grandchild_pid="$(cat "$cancel_grandchild_file")"
  kill "$cancel_handoff_pid"
  wait "$cancel_handoff_pid" 2>/dev/null || true
  cancel_handoff_pid=""
  for _ in $(seq 1 50); do
    if ! kill -0 "$cancel_child_pid" 2>/dev/null \
        && ! kill -0 "$cancel_grandchild_pid" 2>/dev/null; then
      break
    fi
    sleep 0.02
  done
  if kill -0 "$cancel_child_pid" 2>/dev/null; then
    fail "self-test preparation child survived lease-helper termination"
  fi
  if kill -0 "$cancel_grandchild_pid" 2>/dev/null; then
    fail "self-test preparation grandchild survived lease-helper termination"
  fi
  "$CUTOVER_HELPER" \
    lease-run \
    --base-path "$cancel_handoff_root" \
    -- \
    /usr/bin/true \
    >/dev/null

  handoff_root="$fixture_root/handoff"
  handoff_ready="$fixture_root/handoff-ready"
  handoff_prepared="$fixture_root/handoff-prepared"
  handoff_next="$fixture_root/handoff-next.sh"
  mkdir -p "$handoff_root"
  # Expansion belongs to the generated script.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/sh' \
    'printf ready >"$MASC_CUTOVER_HANDOFF_READY"' \
    'sleep 10' \
    >"$handoff_next"
  chmod 700 "$handoff_next"
  MASC_CUTOVER_HANDOFF_READY="$handoff_ready" \
    "$CUTOVER_HELPER" \
      lease-handoff \
      --base-path "$handoff_root" \
      --next-executable "$CUTOVER_HELPER" \
      --next-argument=lease-run \
      --next-argument=--base-path \
      --next-argument="$handoff_root" \
      --next-argument=-- \
      --next-argument="$handoff_next" \
      --prepared-file "$handoff_prepared" \
      -- \
      /usr/bin/true \
      >/dev/null 2>&1 &
  handoff_pid=$!
  for _ in $(seq 1 50); do
    [[ -e "$handoff_prepared" && -e "$handoff_ready" ]] && break
    kill -0 "$handoff_pid" 2>/dev/null \
      || fail "self-test handoff runtime exited before becoming ready"
    sleep 0.02
  done
  [[ -e "$handoff_ready" ]] \
    || fail "self-test handoff runtime did not become ready"
  [[ -e "$handoff_prepared" ]] \
    || fail "self-test handoff did not publish preparation completion"
  if "$CUTOVER_HELPER" \
      lease-run \
      --base-path "$handoff_root" \
      -- \
      /usr/bin/true \
      >/dev/null 2>&1
  then
    fail "self-test expected the exec handoff runtime to retain the lease"
  fi
  kill "$handoff_pid"
  wait "$handoff_pid" 2>/dev/null || true
  handoff_pid=""

  printf '[event-queue-v15-cutover] self-test OK\n'
  exit 0
fi

if [[ -n "${MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID:-}" ]]; then
  "$CUTOVER_HELPER" \
    verify-lease-owner \
    --base-path "$BASE_PATH" \
    --owner-pid "$MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID" \
    || fail "inherited BasePath lease proof is invalid"
else
  runtime_root="$BASE_PATH/.masc"
  runtime_absent_before_lease=0
  if [[ ! -e "$runtime_root" && ! -L "$runtime_root" ]]; then
    runtime_absent_before_lease=1
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
  if [[ "$runtime_absent_before_lease" -eq 1 ]]; then
    helper_args+=(--runtime-absent-before-lease)
  fi
  exec "$CUTOVER_HELPER" "${helper_args[@]}"
fi

run_gate
