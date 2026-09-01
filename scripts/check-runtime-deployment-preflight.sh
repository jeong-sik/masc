#!/usr/bin/env bash
# Read-only runtime deployment preflight.
#
# Usage:
#   scripts/check-runtime-deployment-preflight.sh --base-path /path/to/workspace
#   scripts/check-runtime-deployment-preflight.sh --base-path /path/to/new-workspace --allow-empty-workspace
#   scripts/check-runtime-deployment-preflight.sh --self-test

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-$(pwd)}"
ALLOW_EMPTY_WORKSPACE=0
RUNTIME_ABSENT_BEFORE_LEASE=0
SELF_TEST=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFLIGHT_HELPER="${MASC_DEPLOYMENT_PREFLIGHT_HELPER:-}"
# Build commit the resolved helper reports for itself; empty until resolved.
PREFLIGHT_HELPER_COMMIT=""
# The gate's own keeper-meta verdict prefix. The self-test asserts this exact
# literal, so the gate and its test cannot drift apart.
KEEPER_META_REJECTED='current keeper meta is invalid'

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

# The durable filenames belong to the OCaml side. Spelling them out here once
# left the fixtures on event-queue-v16.json after the writer moved to v17, and
# the self-test failed on a version skew this gate exists to catch.
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
  local current_owner_count=0
  local keeper_meta_count=0
  local queue_path
  local keeper_name
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

    while IFS= read -r -d '' queue_path; do
      [[ -f "$queue_path" && ! -L "$queue_path" ]] \
        || fail "current queue snapshot is not an exact regular file: $queue_path"
      keeper_name="${queue_path%/*}"
      keeper_name="${keeper_name##*/}"
      "$PREFLIGHT_HELPER" validate-current-queue \
        --base-path "$BASE_PATH" \
        --keeper-name "$keeper_name" \
        || fail "current queue snapshot or transition WAL is invalid: $queue_path"
      current_owner_count=$((current_owner_count + 1))
    done < <(find "$keepers_root" -mindepth 2 -maxdepth 2 -name "$QUEUE_SNAPSHOT_FILENAME" -print0)

    while IFS= read -r -d '' queue_path; do
      [[ -f "$queue_path" && ! -L "$queue_path" ]] \
        || fail "current transition WAL is not an exact regular file: $queue_path"
      if [[ -e "$(dirname "$queue_path")/${QUEUE_SNAPSHOT_FILENAME}" \
            || -L "$(dirname "$queue_path")/${QUEUE_SNAPSHOT_FILENAME}" ]]; then
        continue
      fi
      keeper_name="${queue_path%/*}"
      keeper_name="${keeper_name##*/}"
      "$PREFLIGHT_HELPER" validate-current-wal \
        --base-path "$BASE_PATH" \
        --keeper-name "$keeper_name" \
        || fail "current transition WAL is invalid: $queue_path"
      current_owner_count=$((current_owner_count + 1))
    done < <(find "$keepers_root" -mindepth 2 -maxdepth 2 -name "$QUEUE_WAL_FILENAME" -print0)
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

  # Board attention candidate ledgers are schema_version 4 (typed post_created
  # identity). parse_rows is fail-total per file, so one pre-v4 row silently
  # stalls that keeper's board attention after restart. There is deliberately
  # no legacy reader: retire old ledgers instead of starting on top of them.
  local candidates_root="$runtime_root/board_attention_candidates"
  if [[ -e "$candidates_root" || -L "$candidates_root" ]]; then
    [[ -d "$candidates_root" && ! -L "$candidates_root" ]] \
      || fail "board attention candidate store is not an exact directory: $candidates_root"
    reject_symlinks_below "$candidates_root" "board attention candidate store"
    local candidate_ledger_path
    local stale_row_report
    while IFS= read -r -d '' candidate_ledger_path; do
      [[ -f "$candidate_ledger_path" && ! -L "$candidate_ledger_path" ]] \
        || fail "board attention candidate ledger is not an exact regular file: $candidate_ledger_path"
      if [[ ! -s "$candidate_ledger_path" ]]; then
        continue
      fi
      # -R + fromjson: a torn or non-JSON line is reported instead of skipped —
      # the runtime reader is fail-total per file, so it would stall on it too.
      stale_row_report="$(jq -Rr \
        'first(select(test("\\S")) | try (fromjson | select(.schema_version != 4) | "schema_version=\(.schema_version)") catch "unparseable row") // empty' \
        "$candidate_ledger_path")" \
        || fail "board attention candidate ledger could not be inspected: $candidate_ledger_path"
      [[ -z "$stale_row_report" ]] \
        || fail "board attention candidate ledger has a pre-v4 or unreadable row ($stale_row_report): $candidate_ledger_path — retire the store before restart: mv $candidates_root ${runtime_root}/board_attention_candidates-retired-$(date +%Y%m%d)"
    done < <(find "$candidates_root" -name '*.jsonl' -print0)
  fi

  printf '[runtime-deployment-preflight] OK: base_path=%s schedule_ledgers=%d signal_files=%d signal_rows=%d current_owners=%d keeper_meta=%d in_progress=%d%s\n' \
    "$BASE_PATH" "$schedule_ledger_count" "$signal_file_count" \
    "$signal_row_count" "$current_owner_count" "$keeper_meta_count" \
    "$in_progress_count_total" "$(helper_identity)"
}

if [[ "$SELF_TEST" -eq 1 ]]; then
  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/runtime-deployment-preflight.XXXXXX")"
  trap 'if [[ -n "${handoff_pid:-}" ]]; then kill "$handoff_pid" 2>/dev/null || true; fi; if [[ -n "${cancel_handoff_pid:-}" ]]; then kill "$cancel_handoff_pid" 2>/dev/null || true; fi; rm -rf "$fixture_root"' EXIT

  write_schedules() {
    local target_root="$1"
    local status="$2"
    mkdir -p "$target_root/.masc"
    jq -n --arg status "$status" '
      {version: 1, updated_at: 1, schedules: [], wakes:
        (if $status == "none" then []
         else [{schedule_instance_id: "instance-fixture",
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
       occurrence_id: "ab265db772e34d79bac08002a1f19c2aef1aed4e9de6bfab9c6ffe8924ea79bb",
       schedule_id: "schedule-fixture",
       emitted_at: 1,
       due_at: 1,
       payload_digest: "a4e68d60f1990929e4c12f5d3645bbd997e62c9183cfde4f2332d5ad0361f2c4",
       payload: {kind: "consumer.note", body: {text: "fixture"}}}
      + (if $include_instance
         then {schedule_instance_id: "instance-fixture"}
         else {}
         end)
    ' >"$signal_dir/04.jsonl"
  }

  write_current_queue() {
    local target_root="$1"
    local queue_dir="$target_root/.masc/keepers/fixture"
    mkdir -p "$queue_dir"
    jq -n '
      {schema: "keeper.event_queue.state.v16", revision: 1,
       pending: [], last_transition: null,
       projected_dispositions: [], transition_outbox: [],
       accepted_transfer_projections: []}
    ' >"$queue_dir/${QUEUE_SNAPSHOT_FILENAME}"
  }

  # The full closed current keeper-meta field set. The retired-field variant
  # reproduces the 2026-08-23 incident shape: a hard cut removed fields the
  # on-disk snapshot still carried.
  keeper_meta_fixture='{
    schema: "masc.keeper_meta.v1", name: "fixture",
    instructions: "self-test fixture",
    trace_id: "trace-fixture",
    trace_history: [], last_handoff_ts: 0.0,
    created_at: "2026-08-23T00:00:00Z", updated_at: "2026-08-23T00:00:00Z",
    total_turns: 0, total_input_tokens: 0, total_output_tokens: 0,
    total_tokens: 0, total_cost_usd: 0.0, last_turn_ts: 0.0,
    last_input_tokens: 0, last_output_tokens: 0, last_total_tokens: 0,
    last_latency_ms: 0,
    proactive_count_total: 0, last_proactive_ts: 0.0,
    proactive_visible_count_total: 0, last_visible_proactive_ts: 0.0,
    last_proactive_outcome: "never_started", last_proactive_reason: "",
    last_proactive_preview: "",
    message_scope_ack_id: null, last_runtime_attempt: null, paused: false,
    latched_reason: null, current_task_id: null, keeper_id: null,
    agent_core_env: {}
  }'

  write_keeper_meta() {
    local target_root="$1"
    local variant="$2"
    mkdir -p "$target_root/.masc/keepers"
    case "$variant" in
      current)
        jq -n "$keeper_meta_fixture" \
          >"$target_root/.masc/keepers/fixture.json"
        ;;
      retired-field)
        jq -n "$keeper_meta_fixture + {generation: 1}" \
          >"$target_root/.masc/keepers/fixture.json"
        ;;
      missing-field)
        jq -n "$keeper_meta_fixture | del(.paused)" \
          >"$target_root/.masc/keepers/fixture.json"
        ;;
      non-canonical-enum)
        # The issue #28844 shape: an enumerated field with a canonical
        # default holds a value no variant spells. The runtime repairs it in
        # place on read, so the gate passes it.
        jq -n "$keeper_meta_fixture + {last_proactive_outcome: \"not-an-outcome\"}" \
          >"$target_root/.masc/keepers/fixture.json"
        ;;
      truncated-json)
        # Cut without a pipe: under pipefail, jq dying of SIGPIPE behind a
        # head would abort the self-test instead of producing the fixture.
        local full_meta
        full_meta="$(jq -n "$keeper_meta_fixture")"
        printf '%s' "${full_meta:0:64}" \
          >"$target_root/.masc/keepers/fixture.json"
        ;;
    esac
  }

  expect_failure() {
    local case_name="$1"
    local target_root="$2"
    if "$0" --base-path "$target_root" >/dev/null 2>&1; then
      fail "self-test expected failure: $case_name"
    fi
  }

  expect_failure_contains() {
    local case_name="$1"
    local target_root="$2"
    shift 2
    local expected_text
    local output
    if output="$("$0" --base-path "$target_root" 2>&1)"; then
      fail "self-test expected failure: $case_name"
    fi
    for expected_text in "$@"; do
      [[ "$output" == *"$expected_text"* ]] \
        || fail "self-test failure omitted expected detail for $case_name: $expected_text"
    done
  }

  safe_root="$fixture_root/safe"
  write_schedules "$safe_root" succeeded
  write_signal "$safe_root" true
  cp "$safe_root/.masc/schedules.json" \
    "$safe_root/.masc/schedules.json.last-good"
  write_current_queue "$safe_root"
  write_keeper_meta "$safe_root" current
  "$0" --base-path "$safe_root" >/dev/null

  # Expansion belongs to the nested shell.
  # shellcheck disable=SC2016
  "$PREFLIGHT_HELPER" \
    lease-run \
    --base-path "$safe_root" \
    -- \
    /bin/sh -c '"$1" --base-path "$2"' nested-lease-check "$0" "$safe_root" \
    >/dev/null
  if MASC_DEPLOYMENT_LEASE_OWNER_PID="$$" \
      "$0" --base-path "$safe_root" >/dev/null 2>&1
  then
    fail "self-test accepted a forged BasePath lease owner without a held lease"
  fi
  if "$PREFLIGHT_HELPER" \
      lease-run \
      --base-path "$safe_root" \
      -- \
      env -u MASC_DEPLOYMENT_LEASE_OWNER_PID \
      "$0" --base-path "$safe_root" \
      >/dev/null 2>&1
  then
    fail "self-test expected an active BasePath writer lease to block preflight"
  fi

  running_root="$fixture_root/running"
  write_schedules "$running_root" running
  write_current_queue "$running_root"
  "$0" --base-path "$running_root" >/dev/null

  current_root="$fixture_root/current"
  write_schedules "$current_root" running
  write_current_queue "$current_root"
  "$0" --base-path "$current_root" >/dev/null

  candidate_v4_root="$fixture_root/candidate-v4"
  write_schedules "$candidate_v4_root" running
  mkdir -p "$candidate_v4_root/.masc/board_attention_candidates"
  printf '{"schema_version": 4, "candidate_id": "fixture"}\n' \
    >"$candidate_v4_root/.masc/board_attention_candidates/fixture.jsonl"
  "$0" --base-path "$candidate_v4_root" >/dev/null

  stale_candidate_root="$fixture_root/candidate-pre-v4"
  write_schedules "$stale_candidate_root" running
  mkdir -p "$stale_candidate_root/.masc/board_attention_candidates"
  printf '{"schema_version": 3, "candidate_id": "fixture"}\n' \
    >"$stale_candidate_root/.masc/board_attention_candidates/fixture.jsonl"
  expect_failure stale_board_attention_candidate_ledger "$stale_candidate_root"

  many_stale_candidate_root="$fixture_root/candidate-many-pre-v4"
  write_schedules "$many_stale_candidate_root" running
  mkdir -p "$many_stale_candidate_root/.masc/board_attention_candidates"
  jq -nc 'range(0; 5000) | {schema_version: 3, candidate_id: "fixture"}' \
    >"$many_stale_candidate_root/.masc/board_attention_candidates/fixture.jsonl"
  expect_failure_contains \
    many_stale_board_attention_candidate_rows \
    "$many_stale_candidate_root" \
    "retire the store before restart"

  symlinked_candidate_root="$fixture_root/candidate-symlink"
  write_schedules "$symlinked_candidate_root" running
  mkdir -p "$symlinked_candidate_root/.masc/board_attention_candidates"
  ln -s "$stale_candidate_root/.masc/board_attention_candidates/fixture.jsonl" \
    "$symlinked_candidate_root/.masc/board_attention_candidates/fixture.jsonl"
  expect_failure_contains \
    symlinked_board_attention_candidate_ledger \
    "$symlinked_candidate_root" \
    "board attention candidate store contains a symlink"

  torn_candidate_root="$fixture_root/candidate-torn"
  write_schedules "$torn_candidate_root" running
  mkdir -p "$torn_candidate_root/.masc/board_attention_candidates"
  printf '{"schema_version": 4}\n{"schema_ver' \
    >"$torn_candidate_root/.masc/board_attention_candidates/fixture.jsonl"
  expect_failure torn_board_attention_candidate_ledger "$torn_candidate_root"

  malformed_provider_input_root="$fixture_root/malformed-provider-input"
  write_schedules "$malformed_provider_input_root" running
  mkdir -p "$malformed_provider_input_root/.masc/keepers/fixture/provider-inputs/2026-09"
  printf '%s\n' \
    '{"schema":"masc.provider-input-snapshot.v1","retired":true}' \
    >"$malformed_provider_input_root/.masc/keepers/fixture/provider-inputs/2026-09/01.jsonl"
  expect_failure_contains \
    malformed_provider_input_snapshot \
    "$malformed_provider_input_root" \
    "keeper provider-input snapshots rows=1 refused=1" \
    "durable store validation rejected current runtime state"

  malformed_board_posts_root="$fixture_root/malformed-board-posts"
  write_schedules "$malformed_board_posts_root" running
  printf '%s\n' '{not-json' \
    >"$malformed_board_posts_root/.masc/board_posts.jsonl"
  expect_failure_contains \
    malformed_board_posts \
    "$malformed_board_posts_root" \
    "board posts rows=1 refused=1" \
    "durable store validation rejected current runtime state"

  malformed_current_root="$fixture_root/malformed-current"
  write_schedules "$malformed_current_root" running
  # This case writes a corrupt snapshot with no valid one, so it cannot borrow
  # the directory from write_current_queue the way malformed-current-wal does.
  # The two malformed-wal cases below prepare it the same way.
  mkdir -p "$malformed_current_root/.masc/keepers/fixture"
  printf '{not-json\n' \
    >"$malformed_current_root/.masc/keepers/fixture/${QUEUE_SNAPSHOT_FILENAME}"
  expect_failure malformed_current_queue "$malformed_current_root"

  malformed_current_wal_root="$fixture_root/malformed-current-wal"
  write_schedules "$malformed_current_wal_root" running
  write_current_queue "$malformed_current_wal_root"
  printf '{not-json\n' \
    >"$malformed_current_wal_root/.masc/keepers/fixture/${QUEUE_WAL_FILENAME}"
  expect_failure malformed_current_wal "$malformed_current_wal_root"

  # Each keeper-meta rejection asserts the gate's own verdict prefix (printed
  # by this script, never re-wrapped) plus single tokens from the helper's
  # verdict: cmdliner wraps the helper's error text at the terminal margin, so
  # a multi-word phrase from it can be split across lines.
  retired_meta_field_root="$fixture_root/retired-meta-field"
  write_schedules "$retired_meta_field_root" running
  write_current_queue "$retired_meta_field_root"
  write_keeper_meta "$retired_meta_field_root" retired-field
  expect_failure_contains \
    retired_keeper_meta_field \
    "$retired_meta_field_root" \
    "$KEEPER_META_REJECTED" \
    "class=not_current_schema" \
    "generation"

  missing_meta_field_root="$fixture_root/missing-meta-field"
  write_schedules "$missing_meta_field_root" running
  write_current_queue "$missing_meta_field_root"
  write_keeper_meta "$missing_meta_field_root" missing-field
  expect_failure_contains \
    missing_keeper_meta_field \
    "$missing_meta_field_root" \
    "$KEEPER_META_REJECTED" \
    "class=not_current_schema" \
    "paused"

  # Not JSON at all: the boot path refuses the keeper rather than reading the
  # file as absent, so the helper names the other class.
  truncated_meta_root="$fixture_root/truncated-meta"
  write_schedules "$truncated_meta_root" running
  write_current_queue "$truncated_meta_root"
  write_keeper_meta "$truncated_meta_root" truncated-json
  expect_failure_contains \
    truncated_keeper_meta \
    "$truncated_meta_root" \
    "$KEEPER_META_REJECTED" \
    "class=unreadable_json"

  # A non-canonical enumerated value is what the runtime repairs in place on
  # read, so the gate passes it — and, being read-only, leaves the file
  # byte-identical for the runtime to repair.
  repairable_meta_root="$fixture_root/repairable-meta"
  write_schedules "$repairable_meta_root" running
  write_current_queue "$repairable_meta_root"
  write_keeper_meta "$repairable_meta_root" non-canonical-enum
  cp "$repairable_meta_root/.masc/keepers/fixture.json" \
    "$repairable_meta_root/fixture.json.before"
  "$0" --base-path "$repairable_meta_root" >/dev/null \
    || fail "self-test expected success: repairable_keeper_meta_enum"
  cmp -s "$repairable_meta_root/fixture.json.before" \
    "$repairable_meta_root/.masc/keepers/fixture.json" \
    || fail "self-test gate rewrote a keeper meta it only had to read: repairable_keeper_meta_enum"

  wal_only_root="$fixture_root/wal-only"
  write_schedules "$wal_only_root" running
  mkdir -p "$wal_only_root/.masc/keepers/fixture"
  : >"$wal_only_root/.masc/keepers/fixture/${QUEUE_WAL_FILENAME}"
  "$0" --base-path "$wal_only_root" >/dev/null

  malformed_wal_only_root="$fixture_root/malformed-wal-only"
  write_schedules "$malformed_wal_only_root" running
  mkdir -p "$malformed_wal_only_root/.masc/keepers/fixture"
  printf '{not-json\n' \
    >"$malformed_wal_only_root/.masc/keepers/fixture/${QUEUE_WAL_FILENAME}"
  expect_failure malformed_wal_without_snapshot "$malformed_wal_only_root"

  malformed_root="$fixture_root/malformed"
  mkdir -p "$malformed_root/.masc"
  printf '{not-json\n' >"$malformed_root/.masc/schedules.json"
  expect_failure malformed_ledger "$malformed_root"

  incomplete_contract_root="$fixture_root/incomplete-contract"
  mkdir -p "$incomplete_contract_root/.masc"
  jq -n '{version: 1, schedules: [], wakes: []}' \
    >"$incomplete_contract_root/.masc/schedules.json"
  expect_failure incomplete_schedule_contract "$incomplete_contract_root"

  symlinked_keepers_root="$fixture_root/symlinked-keepers"
  symlinked_keepers_target="$fixture_root/symlinked-keepers-target"
  write_schedules "$symlinked_keepers_root" none
  write_current_queue "$symlinked_keepers_target"
  ln -s "$symlinked_keepers_target/.masc/keepers" \
    "$symlinked_keepers_root/.masc/keepers"
  expect_failure symlinked_keepers_root "$symlinked_keepers_root"

  incomplete_schedule_root="$fixture_root/incomplete-schedule"
  mkdir -p "$incomplete_schedule_root/.masc"
  jq -n '
    {version: 1, updated_at: 1,
     schedules: [{schedule_id: "incomplete-schedule"}],
     wakes: []}
  ' >"$incomplete_schedule_root/.masc/schedules.json"
  expect_failure incomplete_schedule "$incomplete_schedule_root"

  incomplete_recovery_root="$fixture_root/incomplete-recovery"
  write_schedules "$incomplete_recovery_root" succeeded
  jq -n '
    {version: 1, updated_at: 1,
     schedules: [{schedule_id: "incomplete-recovery-schedule"}],
     wakes: []}
  ' >"$incomplete_recovery_root/.masc/schedules.json.last-good"
  expect_failure incomplete_recovery "$incomplete_recovery_root"

  incomplete_signal_root="$fixture_root/incomplete-signal"
  write_schedules "$incomplete_signal_root" succeeded
  write_signal "$incomplete_signal_root" false
  expect_failure incomplete_signal "$incomplete_signal_root"

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
  if "$PREFLIGHT_HELPER" \
      lease-run \
      --base-path "$leased_empty_root" \
      -- \
      env -u MASC_DEPLOYMENT_LEASE_OWNER_PID \
      "$0" \
      --base-path "$leased_empty_root" \
      --allow-empty-workspace \
      >/dev/null 2>&1
  then
    fail "self-test expected an active lease to block allow-empty-workspace"
  fi

  failed_handoff_root="$fixture_root/failed-handoff"
  mkdir -p "$failed_handoff_root"
  if "$PREFLIGHT_HELPER" \
      lease-handoff \
      --base-path "$failed_handoff_root" \
      --next-executable /usr/bin/true \
      -- \
      /usr/bin/false \
      >/dev/null 2>&1
  then
    fail "self-test expected a failed preparation to abort handoff"
  fi
  "$PREFLIGHT_HELPER" \
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
    'printf "%s\n" "$$" >"$MASC_DEPLOYMENT_CHILD_PID"' \
    'trap "exit 143" TERM INT' \
    'sleep 30 &' \
    'printf "%s\n" "$!" >"$MASC_DEPLOYMENT_GRANDCHILD_PID"' \
    'wait' \
    >"$cancel_prepare"
  chmod 700 "$cancel_prepare"
  MASC_DEPLOYMENT_CHILD_PID="$cancel_child_file" \
  MASC_DEPLOYMENT_GRANDCHILD_PID="$cancel_grandchild_file" \
    "$PREFLIGHT_HELPER" \
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
  "$PREFLIGHT_HELPER" \
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
    'printf ready >"$MASC_DEPLOYMENT_HANDOFF_READY"' \
    'sleep 10' \
    >"$handoff_next"
  chmod 700 "$handoff_next"
  MASC_DEPLOYMENT_HANDOFF_READY="$handoff_ready" \
    "$PREFLIGHT_HELPER" \
      lease-handoff \
      --base-path "$handoff_root" \
      --next-executable "$PREFLIGHT_HELPER" \
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
  if "$PREFLIGHT_HELPER" \
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

  printf '[runtime-deployment-preflight] self-test OK\n'
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
