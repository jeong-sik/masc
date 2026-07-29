#!/usr/bin/env bash
#
# One-shot, offline migration for the Event Queue v12 hard cut.
#
# The current fleet writes v8 snapshots with four fields. The v12 runtime
# reuses event-queue.json but requires three additional current-only ledgers.
# This script preserves revision and pending stimuli, refuses any unprojected
# v8 transition, backs up the original bytes, and atomically installs v12 JSON.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
SOURCE_SCHEMA="keeper.event_queue.state.v8"
TARGET_SCHEMA="keeper.event_queue.state.v12"

MODE="dry-run"
BASE_PATH="${MASC_BASE_PATH:-$REPO_DIR}"
CONFIRM_STOPPED=false
RESTORE_DIR=""
SELF_TEST_FIXTURE=""

usage() {
    cat <<'EOF'
Usage:
  scripts/migrate-event-queue-v8-to-v12.sh [--base-path PATH]
  scripts/migrate-event-queue-v8-to-v12.sh --apply --confirm-stopped [--base-path PATH]
  scripts/migrate-event-queue-v8-to-v12.sh --restore BACKUP_DIR --confirm-stopped [--base-path PATH]
  scripts/migrate-event-queue-v8-to-v12.sh --self-test

The default mode is a read-only dry run. --apply requires an explicit
--confirm-stopped acknowledgement and also refuses a live prod PID or a
listener on port 8945.
EOF
}

die() {
    echo "event-queue migration: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup_self_test() {
    if [[ -n "$SELF_TEST_FIXTURE" && -d "$SELF_TEST_FIXTURE" ]]; then
        rm -rf "$SELF_TEST_FIXTURE"
    fi
}

canonical_directory() {
    local directory="$1"
    [[ -d "$directory" ]] || die "directory does not exist: $directory"
    (cd "$directory" && pwd -P)
}

ensure_stopped() {
    local runtime_root="$1"
    [[ "$CONFIRM_STOPPED" == true ]] \
        || die "--apply/--restore requires --confirm-stopped"

    if [[ "${MASC_EVENT_QUEUE_MIGRATION_SELF_TEST:-}" == "1" ]]; then
        return
    fi

    local pid_file="${runtime_root}/masc-prod.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid="$(tr -d '[:space:]' < "$pid_file")"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            die "prod PID $pid is still running; stop it before migration"
        fi
    fi

    if command -v lsof >/dev/null 2>&1 \
        && lsof -iTCP:8945 -sTCP:LISTEN -t >/dev/null 2>&1
    then
        die "port 8945 still has a listener; stop prod before migration"
    fi
}

validate_v8_snapshot() {
    local file="$1"
    jq -e \
        --arg schema "$SOURCE_SCHEMA" \
        '
        type == "object"
        and .schema == $schema
        and (keys | sort) == (["pending", "revision", "schema", "transition_outbox"] | sort)
        and (.revision | type == "number" and floor == . and . >= 0)
        and (.pending | type == "object")
        and (.pending.schema == "keeper.event_queue.v2")
        and ((.pending | keys | sort) == (["items", "length", "schema"] | sort))
        and (.pending.length | type == "number" and floor == . and . >= 0)
        and (.pending.items | type == "array")
        and (.pending.length == (.pending.items | length))
        and (.transition_outbox | type == "array")
        ' \
        "$file" >/dev/null \
        || die "invalid or unsupported v8 snapshot: $file"

    local outbox_count
    outbox_count="$(jq -er '.transition_outbox | length' "$file")"
    [[ "$outbox_count" == "0" ]] \
        || die "v8 snapshot has an unprojected transition; refusing lossy migration: $file"
}

validate_v12_snapshot() {
    local file="$1"
    jq -e \
        --arg schema "$TARGET_SCHEMA" \
        '
        type == "object"
        and .schema == $schema
        and (keys | sort) ==
          ([
            "accepted_transfer_projections",
            "last_transition",
            "pending",
            "projected_dispositions",
            "revision",
            "schema",
            "transition_outbox"
          ] | sort)
        and (.revision | type == "number" and floor == . and . >= 0)
        and (.pending | type == "object")
        and (.pending.schema == "keeper.event_queue.v2")
        and ((.pending | keys | sort) == (["items", "length", "schema"] | sort))
        and (.pending.length | type == "number" and floor == . and . >= 0)
        and (.pending.items | type == "array")
        and (.pending.length == (.pending.items | length))
        and (.last_transition == null or (.last_transition | type == "object"))
        and (.projected_dispositions | type == "array")
        and (.transition_outbox | type == "array")
        and (.accepted_transfer_projections | type == "array")
        ' \
        "$file" >/dev/null \
        || die "invalid v12 snapshot: $file"
}

render_v12_snapshot() {
    local source="$1"
    local target="$2"
    python3 - "$source" "$target" "$TARGET_SCHEMA" <<'PY'
import json
import sys

source_path, target_path, target_schema = sys.argv[1:]
with open(source_path, encoding="utf-8") as source_file:
    source = json.load(source_file)

target = {
    "schema": target_schema,
    "revision": source["revision"],
    "pending": source["pending"],
    "last_transition": None,
    "projected_dispositions": [],
    "transition_outbox": [],
    "accepted_transfer_projections": [],
}
if target["revision"] != source["revision"] or target["pending"] != source["pending"]:
    raise SystemExit("revision or pending queue changed during migration")

with open(target_path, "w", encoding="utf-8") as target_file:
    json.dump(target, target_file, ensure_ascii=False, indent=2)
    target_file.write("\n")
PY
    validate_v12_snapshot "$target"
}

atomic_copy() {
    local source="$1"
    local target="$2"
    local temporary
    temporary="$(mktemp "${target}.migration.XXXXXX")"
    cp -p "$source" "$temporary"
    mv "$temporary" "$target"
}

collect_snapshots() {
    local keepers_dir="$1"
    SNAPSHOTS=()
    local file
    for file in "$keepers_dir"/*/event-queue.json; do
        [[ -f "$file" ]] || continue
        SNAPSHOTS+=("$file")
    done
    [[ "${#SNAPSHOTS[@]}" -gt 0 ]] \
        || die "no Keeper event-queue.json snapshots found under $keepers_dir"
}

restore_backup() {
    local runtime_root="$1"
    local backup_dir
    backup_dir="$(canonical_directory "$RESTORE_DIR")"
    local manifest="${backup_dir}/manifest.json"
    local checksums="${backup_dir}/checksums.sha256"

    [[ -f "$manifest" ]] || die "backup manifest not found: $manifest"
    [[ -f "$checksums" ]] || die "backup checksums not found: $checksums"
    (cd "$backup_dir" && shasum -a 256 -c checksums.sha256 >/dev/null) \
        || die "backup checksum verification failed: $backup_dir"
    local manifest_base
    manifest_base="$(jq -er '.base_path' "$manifest")"
    [[ "$manifest_base" == "$BASE_PATH" ]] \
        || die "backup base path mismatch: manifest=$manifest_base requested=$BASE_PATH"

    local current_file current_keeper current_backup
    for current_file in "$runtime_root"/keepers/*/event-queue.json; do
        [[ -f "$current_file" ]] || continue
        current_keeper="$(basename "$(dirname "$current_file")")"
        current_backup="${backup_dir}/keepers/${current_keeper}/event-queue.json"
        if [[ ! -f "$current_backup" ]]; then
            local current_schema
            current_schema="$(jq -er '.schema | select(type == "string")' "$current_file")" \
                || die "unbacked snapshot has no string schema: $current_file"
            if [[ "$current_schema" == "$SOURCE_SCHEMA" ]]; then
                validate_v8_snapshot "$current_file"
            else
                die "unbacked non-v8 snapshot blocks rollback: $current_file"
            fi
        fi
    done

    local restored=0
    local backup_file
    for backup_file in "$backup_dir"/keepers/*/event-queue.json; do
        [[ -f "$backup_file" ]] || continue
        validate_v8_snapshot "$backup_file"
        local keeper_name target
        keeper_name="$(basename "$(dirname "$backup_file")")"
        target="${runtime_root}/keepers/${keeper_name}/event-queue.json"
        [[ -d "$(dirname "$target")" ]] \
            || die "target Keeper directory is missing: $(dirname "$target")"
        atomic_copy "$backup_file" "$target"
        restored=$((restored + 1))
    done

    [[ "$restored" -gt 0 ]] || die "backup contains no snapshots: $backup_dir"
    echo "Restored $restored Event Queue snapshot(s) from $backup_dir"
}

run_migration() {
    require_command jq
    require_command python3
    require_command shasum
    BASE_PATH="$(canonical_directory "$BASE_PATH")"
    local runtime_root="${BASE_PATH}/.masc"
    local keepers_dir="${runtime_root}/keepers"
    [[ -d "$keepers_dir" ]] || die "Keeper runtime directory not found: $keepers_dir"

    if [[ -n "$RESTORE_DIR" ]]; then
        ensure_stopped "$runtime_root"
        restore_backup "$runtime_root"
        return
    fi

    collect_snapshots "$keepers_dir"
    V8_SNAPSHOTS=()
    local v12_count=0
    local file schema
    for file in "${SNAPSHOTS[@]}"; do
        schema="$(jq -er '.schema | select(type == "string")' "$file")" \
            || die "snapshot has no string schema: $file"
        case "$schema" in
            "$SOURCE_SCHEMA")
                validate_v8_snapshot "$file"
                V8_SNAPSHOTS+=("$file")
                ;;
            "$TARGET_SCHEMA")
                validate_v12_snapshot "$file"
                v12_count=$((v12_count + 1))
                ;;
            *)
                die "unsupported snapshot schema $schema: $file"
                ;;
        esac
    done
    if [[ "${#V8_SNAPSHOTS[@]}" -gt 0 && "$v12_count" -gt 0 ]]; then
        die "mixed v8/v12 fleet detected; restore one complete prior backup before retrying"
    fi

    local pending_count=0
    if [[ "${#V8_SNAPSHOTS[@]}" -gt 0 ]]; then
        for file in "${V8_SNAPSHOTS[@]}"; do
            pending_count=$((pending_count + $(jq -er '.pending.length' "$file")))
        done
    fi

    echo "Validated ${#SNAPSHOTS[@]} snapshot(s): ${#V8_SNAPSHOTS[@]} v8, $v12_count v12"
    echo "Pending stimuli preserved by this migration: $pending_count"

    if [[ "$MODE" == "dry-run" ]]; then
        echo "Dry run only. Re-run with --apply --confirm-stopped to migrate."
        return
    fi

    ensure_stopped "$runtime_root"
    if [[ "${#V8_SNAPSHOTS[@]}" -eq 0 ]]; then
        echo "All snapshots are already v12; no changes made."
        return
    fi

    umask 077
    local backup_dir
    backup_dir="${runtime_root}/migrations/event-queue-v8-to-v12/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "${backup_dir}/keepers" "${backup_dir}/rendered"

    local keeper_name backup_file rendered_file
    for file in "${V8_SNAPSHOTS[@]}"; do
        keeper_name="$(basename "$(dirname "$file")")"
        mkdir -p "${backup_dir}/keepers/${keeper_name}"
        backup_file="${backup_dir}/keepers/${keeper_name}/event-queue.json"
        cp -p "$file" "$backup_file"
        rendered_file="${backup_dir}/rendered/${keeper_name}.json"
        render_v12_snapshot "$file" "$rendered_file"
    done
    (
        cd "$backup_dir"
        shasum -a 256 keepers/*/event-queue.json > checksums.sha256
    )

    jq -n \
        --arg base_path "$BASE_PATH" \
        --arg source_schema "$SOURCE_SCHEMA" \
        --arg target_schema "$TARGET_SCHEMA" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson snapshot_count "${#V8_SNAPSHOTS[@]}" \
        --argjson pending_count "$pending_count" \
        '{
          base_path: $base_path,
          source_schema: $source_schema,
          target_schema: $target_schema,
          created_at: $created_at,
          snapshot_count: $snapshot_count,
          pending_count: $pending_count
        }' > "${backup_dir}/manifest.json"

    local migration_active=true
    rollback_and_exit() {
        local exit_code="$1"
        trap - ERR INT TERM HUP
        if [[ "$migration_active" == true ]]; then
            echo "Migration failed; restoring original snapshot bytes..." >&2
            RESTORE_DIR="$backup_dir"
            restore_backup "$runtime_root" >&2 || true
        fi
        exit "$exit_code"
    }
    trap 'rollback_and_exit $?' ERR
    trap 'rollback_and_exit 130' INT
    trap 'rollback_and_exit 143' TERM
    trap 'rollback_and_exit 129' HUP

    local replaced_count=0
    for file in "${V8_SNAPSHOTS[@]}"; do
        keeper_name="$(basename "$(dirname "$file")")"
        rendered_file="${backup_dir}/rendered/${keeper_name}.json"
        atomic_copy "$rendered_file" "$file"
        validate_v12_snapshot "$file"
        replaced_count=$((replaced_count + 1))
        if [[ "${MASC_EVENT_QUEUE_MIGRATION_SELF_TEST_FAIL_AFTER_REPLACE:-}" == "$replaced_count" ]]
        then
            false
        fi
    done

    migration_active=false
    trap - ERR INT TERM HUP
    echo "Migrated ${#V8_SNAPSHOTS[@]} snapshot(s) to v12."
    echo "Backup: $backup_dir"
    echo "Rollback: $0 --base-path \"$BASE_PATH\" --restore \"$backup_dir\" --confirm-stopped"
}

self_test() {
    require_command jq
    require_command python3
    require_command rg
    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/masc-event-queue-migration.XXXXXX")"
    SELF_TEST_FIXTURE="$fixture"
    trap cleanup_self_test EXIT
    mkdir -p "$fixture/.masc/keepers/alpha"

    local snapshot="$fixture/.masc/keepers/alpha/event-queue.json"
    printf '%s\n' \
        '{"schema":"keeper.event_queue.state.v8","revision":9007199254740993,"pending":{"schema":"keeper.event_queue.v2","length":1,"items":[{"sentinel":"keep","exact_integer":9007199254740993}]},"transition_outbox":[]}' \
        > "$snapshot"

    MASC_EVENT_QUEUE_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" >/dev/null
    local output
    output="$(
        MASC_EVENT_QUEUE_MIGRATION_SELF_TEST=1 \
            "$0" --base-path "$fixture" --apply --confirm-stopped
    )"
    validate_v12_snapshot "$snapshot"
    [[ "$(jq -er '.pending.items[0].sentinel' "$snapshot")" == "keep" ]] \
        || die "self-test: pending stimulus was not preserved"
    rg -q '"revision": 9007199254740993' "$snapshot" \
        || die "self-test: int64 revision lost precision"
    rg -q '"exact_integer": 9007199254740993' "$snapshot" \
        || die "self-test: pending int64 lost precision"

    local backup_dir
    backup_dir="$(printf '%s\n' "$output" | sed -n 's/^Backup: //p')"
    [[ -n "$backup_dir" && -d "$backup_dir" ]] \
        || die "self-test: backup directory was not reported"

    MASC_EVENT_QUEUE_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" --apply --confirm-stopped >/dev/null
    mkdir -p "$fixture/.masc/keepers/beta"
    printf '%s\n' \
        '{"schema":"keeper.event_queue.state.v12","revision":1,"pending":{"schema":"keeper.event_queue.v2","length":0,"items":[]},"last_transition":null,"projected_dispositions":[],"transition_outbox":[],"accepted_transfer_projections":[]}' \
        > "$fixture/.masc/keepers/beta/event-queue.json"
    if MASC_EVENT_QUEUE_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" --restore "$backup_dir" --confirm-stopped >/dev/null 2>&1
    then
        die "self-test: rollback accepted an unbacked v12 snapshot"
    fi
    rm -rf "$fixture/.masc/keepers/beta"
    MASC_EVENT_QUEUE_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" --restore "$backup_dir" --confirm-stopped >/dev/null
    validate_v8_snapshot "$snapshot"

    if MASC_EVENT_QUEUE_MIGRATION_SELF_TEST=1 \
        MASC_EVENT_QUEUE_MIGRATION_SELF_TEST_FAIL_AFTER_REPLACE=1 \
        "$0" --base-path "$fixture" --apply --confirm-stopped >/dev/null 2>&1
    then
        die "self-test: injected post-replacement failure did not fail"
    fi
    validate_v8_snapshot "$snapshot"

    mkdir -p "$fixture/.masc/keepers/beta"
    printf '%s\n' \
        '{"schema":"keeper.event_queue.state.v12","revision":1,"pending":{"schema":"keeper.event_queue.v2","length":0,"items":[]},"last_transition":null,"projected_dispositions":[],"transition_outbox":[],"accepted_transfer_projections":[]}' \
        > "$fixture/.masc/keepers/beta/event-queue.json"
    if MASC_EVENT_QUEUE_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" >/dev/null 2>&1
    then
        die "self-test: mixed v8/v12 fleet was accepted"
    fi
    rm -rf "$fixture/.masc/keepers/beta"

    jq '.transition_outbox = [{"sentinel":"unprojected"}]' "$snapshot" > "${snapshot}.tmp"
    mv "${snapshot}.tmp" "$snapshot"
    if MASC_EVENT_QUEUE_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" >/dev/null 2>&1
    then
        die "self-test: non-empty v8 outbox was accepted"
    fi

    echo "event-queue migration self-test: PASS"
    cleanup_self_test
    SELF_TEST_FIXTURE=""
    trap - EXIT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-path)
            [[ $# -ge 2 ]] || die "--base-path requires a value"
            BASE_PATH="$2"
            shift 2
            ;;
        --apply)
            MODE="apply"
            shift
            ;;
        --confirm-stopped)
            CONFIRM_STOPPED=true
            shift
            ;;
        --restore)
            [[ $# -ge 2 ]] || die "--restore requires a backup directory"
            MODE="restore"
            RESTORE_DIR="$2"
            shift 2
            ;;
        --self-test)
            self_test
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

run_migration
