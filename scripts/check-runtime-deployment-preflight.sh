#!/usr/bin/env bash
# Read-only runtime deployment preflight.
#
# Usage:
#   scripts/check-runtime-deployment-preflight.sh --base-path /path/to/workspace
#   scripts/check-runtime-deployment-preflight.sh --base-path /path/to/new-workspace --allow-empty-workspace
#   scripts/check-runtime-deployment-preflight.sh --base-path /path/to/workspace --runtime-config-only

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-$(pwd)}"
ALLOW_EMPTY_WORKSPACE=0
RUNTIME_ABSENT_BEFORE_LEASE=0
RUNTIME_CONFIG_ONLY=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFLIGHT_HELPER="${MASC_DEPLOYMENT_PREFLIGHT_HELPER:-}"
# Build commit the resolved helper reports for itself; empty until resolved.
PREFLIGHT_HELPER_COMMIT=""
# The keeper-meta rejection message shown to the operator.
KEEPER_META_REJECTED='current keeper meta is invalid'
# Same contract for the runtime.toml verdict, and for what the operator can do
# next from each place the check runs.
RUNTIME_CONFIG_REJECTED='runtime.toml is not one this build accepts'
RUNTIME_CONFIG_NEXT_BEFORE_STOP='nothing was stopped or installed: change the value (through the runtime config editor while a server runs on this workspace, in the file otherwise), then deploy again'
RUNTIME_CONFIG_NEXT_UNDER_LEASE='no server runs on this workspace while this gate holds its writer lease (scripts/deploy.sh stopped the previous prod and does not restart it), and nothing was installed: change the value in the file, then deploy again'
# Keep aligned with Keeper_board_attention_candidate.schema_version.
BOARD_ATTENTION_SCHEMA_VERSION=7

usage() {
  sed -n '2,/^$/p' "$0"
}

# Every verdict names the helper that produced it: the fallback below can pick
# an older installed helper, and a verdict from the wrong binary is worthless.
helper_identity() {
  if [[ -n "$PREFLIGHT_HELPER_COMMIT" ]]; then
    printf ' helper=%s helper_commit=%s' "$PREFLIGHT_HELPER" "$PREFLIGHT_HELPER_COMMIT"
  fi
}

fail() {
  printf '[runtime-deployment-preflight] FAIL: %s%s\n' "$*" "$(helper_identity)" >&2
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
    --allow-empty-workspace)
      ALLOW_EMPTY_WORKSPACE=1
      shift
      ;;
    --runtime-config-only)
      RUNTIME_CONFIG_ONLY=1
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

if [[ -z "$PREFLIGHT_HELPER" ]]; then
  if [[ -x "$SCRIPT_DIR/masc-deployment-preflight-helper" ]]; then
    PREFLIGHT_HELPER="$SCRIPT_DIR/masc-deployment-preflight-helper"
  elif [[ "${BASH_SOURCE[0]##*/}" == masc-check-runtime-deployment-preflight-* ]]; then
    release_suffix="${BASH_SOURCE[0]##*/}"
    release_suffix="${release_suffix#masc-check-runtime-deployment-preflight-}"
    release_helper="$SCRIPT_DIR/masc-deployment-preflight-helper-$release_suffix"
    [[ -x "$release_helper" ]] \
      || fail "paired release preflight helper is missing or not executable: $release_helper"
    PREFLIGHT_HELPER="$release_helper"
  elif [[ -x "$REPO_ROOT/_build/default/bin/deployment_preflight_helper.exe" ]]; then
    PREFLIGHT_HELPER="$REPO_ROOT/_build/default/bin/deployment_preflight_helper.exe"
  else
    fail "typed deployment preflight helper is required beside this gate, in the build tree, or via MASC_DEPLOYMENT_PREFLIGHT_HELPER"
  fi
fi
[[ -x "$PREFLIGHT_HELPER" ]] || fail "typed deployment preflight helper is not executable: $PREFLIGHT_HELPER"
PREFLIGHT_HELPER_COMMIT="$("$PREFLIGHT_HELPER" build-commit)" \
  || fail "typed deployment preflight helper did not report its build commit: $PREFLIGHT_HELPER"
[[ -n "$PREFLIGHT_HELPER_COMMIT" ]] \
  || fail "typed deployment preflight helper reported an empty build commit: $PREFLIGHT_HELPER"

# Read the durable event-queue filenames from the OCaml owner.
QUEUE_SNAPSHOT_FILENAME=""
QUEUE_WAL_FILENAME=""
while IFS='=' read -r key value; do
  case "$key" in
    snapshot) QUEUE_SNAPSHOT_FILENAME="$value" ;;
    wal) QUEUE_WAL_FILENAME="$value" ;;
  esac
done < <("$PREFLIGHT_HELPER" durable-filenames)
[[ -n "$QUEUE_SNAPSHOT_FILENAME" && -n "$QUEUE_WAL_FILENAME" ]] \
  || fail "preflight helper did not report both durable event-queue filenames"

# A build that narrows a runtime.toml key refuses the live file on boot, and
# the part that key belongs to goes empty: #39040 left every Keeper without
# Skills (#39311). The helper judges the file this workspace's server reads
# the way a raw save and boot do; its verdict above the FAIL line names the
# key and the file. [$1] is what the operator can do next from where it ran.
check_runtime_config() {
  local next_step="$1"
  local args=(validate-runtime-config --base-path "$BASE_PATH")
  if [[ "$ALLOW_EMPTY_WORKSPACE" -eq 1 ]]; then
    args+=(--allow-empty-workspace)
  fi
  "$PREFLIGHT_HELPER" "${args[@]}" \
    || fail "$RUNTIME_CONFIG_REJECTED (the helper verdict above names the key and the file); $next_step"
}

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
  local keeper_meta_count=0
  local in_progress_count_total=0

  [[ -d "$BASE_PATH" && ! -L "$BASE_PATH" ]] \
    || fail "base path is not an exact directory: $BASE_PATH"
  if [[ "$RUNTIME_ABSENT_BEFORE_LEASE" -eq 1 \
        && "$ALLOW_EMPTY_WORKSPACE" -ne 1 ]]; then
    fail "workspace runtime was absent before lease acquisition: $runtime_root (wrong --base-path? pass --allow-empty-workspace only for an intentional new workspace)"
  fi
  if [[ ! -e "$runtime_root" && ! -L "$runtime_root" ]]; then
    if [[ "$ALLOW_EMPTY_WORKSPACE" -eq 1 ]]; then
      printf '[runtime-deployment-preflight] OK: base_path=%s empty_workspace=allowed\n' \
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
    # Keeper meta is a closed current schema. A field the incoming binary
    # stopped writing (2026-08-23 hard cuts) makes the file undecodable on
    # boot: the runtime reads it as absent and re-materialises the keeper from
    # its declaration, and the accumulated counters and the task binding are
    # gone (#29610). This gate runs between the stop of the previous runtime
    # and the start of the next one (scripts/deploy.sh stops prod in step 3
    # and runs this under the deployment lease in step 4; the runbook needs
    # the writer lease free), so a rejection here leaves the plane down until
    # the operator repairs the file and redeploys. That downtime is the price
    # of keeping the counters the boot-time fail-open would lose. The helper
    # verdict printed above the FAIL line names the class and the fix.
    while IFS= read -r -d '' meta_path; do
      [[ -f "$meta_path" && ! -L "$meta_path" ]] \
        || fail "keeper meta is not an exact regular file: $meta_path"
      "$PREFLIGHT_HELPER" validate-current-meta "$meta_path" \
        || fail "$KEEPER_META_REJECTED (the helper verdict above names the class and the fix): $meta_path"
      keeper_meta_count=$((keeper_meta_count + 1))
    done < <(find "$keepers_root" -mindepth 1 -maxdepth 1 -name '*.json' -print0)
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
    schedule_report="$("$PREFLIGHT_HELPER" validate-schedule-ledger "$schedules_path")" \
      || fail "schedule ledger contract is invalid: $schedules_path"
    local in_progress_count
    in_progress_count="$(jq -er '.in_progress_count' <<<"$schedule_report")" \
      || fail "typed schedule validator returned an invalid result: $schedules_path"
    in_progress_count_total=$((in_progress_count_total + in_progress_count))
  done

  if [[ -e "$signals_root" || -L "$signals_root" ]]; then
    [[ -d "$signals_root" && ! -L "$signals_root" ]] \
      || fail "schedule signal store is not an exact directory: $signals_root"
    reject_symlinks_below "$signals_root" "schedule signal store"
    while IFS= read -r -d '' signal_path; do
      signal_file_count=$((signal_file_count + 1))
      [[ -f "$signal_path" && ! -L "$signal_path" ]] \
        || fail "schedule signal segment is not an exact regular file: $signal_path"
      rows_in_file="$("$PREFLIGHT_HELPER" validate-signals "$signal_path")" \
        || fail "schedule signal segment violates the current contract: $signal_path"
      [[ "$rows_in_file" =~ ^[0-9]+$ ]] \
        || fail "typed signal validator returned an invalid row count: $rows_in_file"
      signal_row_count=$((signal_row_count + rows_in_file))
    done < <(find "$signals_root" -name '*.jsonl' -print0)
  fi

  if ! "$PREFLIGHT_HELPER" validate-stores --base-path "$BASE_PATH"; then
    fail "durable store validation rejected current runtime state"
  fi

  check_runtime_config "$RUNTIME_CONFIG_NEXT_UNDER_LEASE"

  # The runtime reader rejects a whole ledger on an unsupported schema or torn
  # row. Check the current version before restart without changing runtime data.
  local candidates_root="$runtime_root/board_attention_candidates"
  if [[ -e "$candidates_root" || -L "$candidates_root" ]]; then
    [[ -d "$candidates_root" && ! -L "$candidates_root" ]] \
      || fail "board attention candidate store is not an exact directory: $candidates_root"
    reject_symlinks_below "$candidates_root" "board attention candidate store"
    local candidate_ledger_path
    local stale_row_report
    local unattributed_requeue_rows
    while IFS= read -r -d '' candidate_ledger_path; do
      [[ -f "$candidate_ledger_path" && ! -L "$candidate_ledger_path" ]] \
        || fail "board attention candidate ledger is not an exact regular file: $candidate_ledger_path"
      if [[ ! -s "$candidate_ledger_path" ]]; then
        continue
      fi
      # -R + fromjson: a torn or non-JSON line is reported instead of skipped —
      # the runtime reader is fail-total per file, so it would stall on it too.
      stale_row_report="$(jq -Rr --argjson version "$BOARD_ATTENTION_SCHEMA_VERSION" \
        'first(select(test("\\S")) | try (fromjson | select(.schema_version != $version) | "schema_version=\(.schema_version)") catch "unparseable row") // empty' \
        "$candidate_ledger_path")" \
        || fail "board attention candidate ledger could not be inspected: $candidate_ledger_path"
      [[ -z "$stale_row_report" ]] \
        || fail "board attention candidate ledger requires schema_version=$BOARD_ATTENTION_SCHEMA_VERSION; incompatible or unreadable row ($stale_row_report): $candidate_ledger_path"
      # A requeue row must name its requester. The runtime reader rejects one
      # without [requested_by]; the candidate then reads as its earlier row
      # while the partition is already Ready, and no command can finish it.
      unattributed_requeue_rows="$(jq -Rn \
        '[inputs | select(test("\\S")) | (try fromjson catch null)
          | select(type == "object") | .status
          | select(type == "object"
                   and (.kind == "requeue_requested" or .kind == "requeued"))
          | select((.requested_by | type) != "string"
                   or ((.requested_by | test("\\S")) | not))] | length' \
        "$candidate_ledger_path")" \
        || fail "board attention candidate ledger could not be inspected: $candidate_ledger_path"
      [[ "$unattributed_requeue_rows" == "0" ]] \
        || fail "board attention candidate ledger has $unattributed_requeue_rows requeue_requested/requeued row(s) without requested_by: $candidate_ledger_path"
    done < <(find "$candidates_root" -name '*.jsonl' -print0)
  fi

  # For this one-version bridge, complete/cancel are read and written without
  # the legacy field. The production decoder retains duplicate JSON members,
  # so unsupported/duplicate intents cannot be hidden by jq's last value.
  # Inspect both primary and recovery before replacing the executable.
  local backlog_path
  for backlog_path in "$runtime_root/tasks/backlog.json" "$runtime_root/tasks/backlog.json.last-good"; do
    [[ -e "$backlog_path" || -L "$backlog_path" ]] || continue
    [[ -f "$backlog_path" && ! -L "$backlog_path" ]] \
      || fail "task backlog is not an exact regular file: $backlog_path"
    "$PREFLIGHT_HELPER" validate-task-backlog "$backlog_path" \
      || fail "task backlog contract is invalid: $backlog_path"
  done

  printf '[runtime-deployment-preflight] OK: base_path=%s schedule_ledgers=%d signal_files=%d signal_rows=%d keeper_meta=%d in_progress=%d%s\n' \
    "$BASE_PATH" "$schedule_ledger_count" "$signal_file_count" \
    "$signal_row_count" "$keeper_meta_count" \
    "$in_progress_count_total" "$(helper_identity)"
}

# Before the stop step the previous server still holds the writer lease, so
# this reads runtime.toml alone and takes no lease. A refusal here stops
# nothing. The full gate checks the file again under the lease, because it can
# change in between.
if [[ "$RUNTIME_CONFIG_ONLY" -eq 1 ]]; then
  [[ -d "$BASE_PATH" && ! -L "$BASE_PATH" ]] \
    || fail "base path is not an exact directory: $BASE_PATH"
  check_runtime_config "$RUNTIME_CONFIG_NEXT_BEFORE_STOP"
  printf '[runtime-deployment-preflight] OK: base_path=%s runtime_config_only=1%s\n' \
    "$BASE_PATH" "$(helper_identity)"
  exit 0
fi

if [[ -n "${MASC_DEPLOYMENT_LEASE_OWNER_PID:-}" ]]; then
  "$PREFLIGHT_HELPER" \
    verify-lease-owner \
    --base-path "$BASE_PATH" \
    --owner-pid "$MASC_DEPLOYMENT_LEASE_OWNER_PID" \
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
  exec "$PREFLIGHT_HELPER" "${helper_args[@]}"
fi

run_gate
