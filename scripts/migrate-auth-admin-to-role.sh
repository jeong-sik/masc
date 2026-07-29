#!/usr/bin/env bash
#
# Offline migration for the current-only agent credential schema.
#
# Legacy credential objects contain both `role` and a denormalised `admin`
# boolean. The current schema keeps `role` as the sole authority. This script
# validates the complete credential inventory, preserves redirect stubs and
# credential values, removes only a consistent `admin` field, and keeps a
# byte-for-byte backup for rollback.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

MODE="dry-run"
BASE_PATH="${MASC_BASE_PATH:-$REPO_DIR}"
CONFIRM_STOPPED=false
RESTORE_DIR=""
SELF_TEST_FIXTURE=""

usage() {
    cat <<'EOF'
Usage:
  scripts/migrate-auth-admin-to-role.sh [--base-path PATH]
  scripts/migrate-auth-admin-to-role.sh --apply --confirm-stopped [--base-path PATH]
  scripts/migrate-auth-admin-to-role.sh --restore BACKUP_DIR --confirm-stopped [--base-path PATH]
  scripts/migrate-auth-admin-to-role.sh --self-test

The default mode is a read-only dry run. Apply and restore require an explicit
--confirm-stopped acknowledgement and refuse a live prod PID or port 8945
listener.
EOF
}

die() {
    echo "credential migration: $*" >&2
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

    if [[ "${MASC_AUTH_ADMIN_MIGRATION_SELF_TEST:-}" == "1" ]]; then
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

credential_kind() {
    local file="$1"
    python3 - "$file" <<'PY'
import json
import os
import sys

path = sys.argv[1]

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate field {key!r}")
        result[key] = value
    return result

def require_string(data, key):
    if not isinstance(data[key], str):
        raise ValueError(f"field {key!r} must be a string")

def require_optional_string(data, key):
    if data[key] is not None and not isinstance(data[key], str):
        raise ValueError(f"field {key!r} must be a string or null")

try:
    with open(path, encoding="utf-8") as source:
        data = json.load(source, object_pairs_hook=reject_duplicates)
    if not isinstance(data, dict):
        raise ValueError("top-level value must be an object")

    keys = set(data)
    redirect_keys = {"redirect_to"}
    current_keys = {
        "id", "agent_id", "agent_name", "token", "role", "created_at",
        "expires_at",
    }
    legacy_keys = current_keys | {"admin"}

    if keys == redirect_keys:
        require_string(data, "redirect_to")
        print("redirect")
        raise SystemExit(0)

    if keys not in (current_keys, legacy_keys):
        raise ValueError(f"unsupported field set: {sorted(keys)!r}")

    require_optional_string(data, "id")
    require_optional_string(data, "agent_id")
    require_string(data, "agent_name")
    require_string(data, "token")
    require_string(data, "created_at")
    require_optional_string(data, "expires_at")
    if data["role"] not in ("worker", "admin"):
        raise ValueError("field 'role' must be 'worker' or 'admin'")

    if keys == legacy_keys:
        if not isinstance(data["admin"], bool):
            raise ValueError("field 'admin' must be a boolean")
        if data["admin"] != (data["role"] == "admin"):
            raise ValueError("fields 'role' and 'admin' disagree")
        print("legacy")
    else:
        print("current")
except (OSError, json.JSONDecodeError, ValueError) as error:
    print(f"{os.path.basename(path)}: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

render_current_credential() {
    local source="$1"
    local target="$2"
    [[ "$(credential_kind "$source")" == "legacy" ]] \
        || die "not a validated legacy credential: $source"
    python3 - "$source" "$target" <<'PY'
import json
import sys

source_path, target_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as source_file:
    credential = json.load(source_file)

del credential["admin"]
with open(target_path, "w", encoding="utf-8") as target_file:
    json.dump(credential, target_file, ensure_ascii=False, indent=2)
    target_file.write("\n")
PY
    chmod 0600 "$target"
    [[ "$(credential_kind "$target")" == "current" ]] \
        || die "rendered credential failed current-schema validation: $source"
}

atomic_copy() {
    local source="$1"
    local target="$2"
    python3 - "$source" "$target" <<'PY'
import os
import shutil
import stat
import sys
import tempfile

source, target = sys.argv[1:]
target_directory = os.path.dirname(target)
source_mode = stat.S_IMODE(os.stat(source, follow_symlinks=False).st_mode)
temporary_fd, temporary = tempfile.mkstemp(
    prefix=f"{os.path.basename(target)}.migration.",
    dir=target_directory,
)
try:
    with open(source, "rb") as source_file, os.fdopen(
        temporary_fd, "wb"
    ) as temporary_file:
        temporary_fd = -1
        shutil.copyfileobj(source_file, temporary_file)
        os.fchmod(temporary_file.fileno(), source_mode)
        temporary_file.flush()
        os.fsync(temporary_file.fileno())
    os.replace(temporary, target)
    temporary = ""
    directory_fd = os.open(
        target_directory,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if temporary_fd >= 0:
        os.close(temporary_fd)
    if temporary:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
PY
}

sync_backup_tree() {
    local backup_dir="$1"
    python3 - "$backup_dir" <<'PY'
import os
import sys

backup_dir = sys.argv[1]
directories = []
for root, _, files in os.walk(backup_dir):
    directories.append(root)
    for filename in files:
        path = os.path.join(root, filename)
        file_fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(file_fd)
        finally:
            os.close(file_fd)

directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
for directory in reversed(directories):
    directory_fd = os.open(directory, directory_flags)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

parent_fd = os.open(os.path.dirname(backup_dir), directory_flags)
try:
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
}

ALL_FILES=()
LEGACY_FILES=()
CURRENT_FILES=()
REDIRECT_FILES=()

collect_inventory() {
    local agents_dir="$1"
    [[ -d "$agents_dir" ]] || die "credential directory not found: $agents_dir"
    ALL_FILES=()
    LEGACY_FILES=()
    CURRENT_FILES=()
    REDIRECT_FILES=()

    shopt -s nullglob
    local file kind
    for file in "$agents_dir"/*.json; do
        [[ -f "$file" && ! -L "$file" ]] \
            || die "credential entry must be a regular non-symlink file: $file"
        ALL_FILES+=("$file")
        kind="$(credential_kind "$file")" \
            || die "invalid credential inventory entry: $file"
        case "$kind" in
            legacy) LEGACY_FILES+=("$file") ;;
            current) CURRENT_FILES+=("$file") ;;
            redirect) REDIRECT_FILES+=("$file") ;;
            *) die "unknown credential classification for $file: $kind" ;;
        esac
    done
    shopt -u nullglob

    [[ "${#ALL_FILES[@]}" -gt 0 ]] || die "credential inventory is empty: $agents_dir"
    if [[ "${#LEGACY_FILES[@]}" -gt 0 && "${#CURRENT_FILES[@]}" -gt 0 ]]; then
        die "mixed legacy/current credential fleet detected; restore one complete backup"
    fi
}

write_manifest() {
    local manifest="$1"
    local backup_base_path="$2"
    shift 2
    python3 - "$manifest" "$backup_base_path" "$@" <<'PY'
import json
import os
import sys

manifest_path, base_path, *files = sys.argv[1:]
payload = {
    "schema": "masc.auth-admin-to-role.backup.v1",
    "base_path": base_path,
    "source_schema": "agent-credential.role-plus-admin",
    "target_schema": "agent-credential.role-only",
    "files": sorted(os.path.basename(path) for path in files),
}
with open(manifest_path, "w", encoding="utf-8") as manifest:
    json.dump(payload, manifest, ensure_ascii=False, indent=2)
    manifest.write("\n")
PY
}

validate_manifest() {
    local manifest="$1"
    local requested_base="$2"
    python3 - "$manifest" "$requested_base" <<'PY'
import json
import sys

manifest_path, requested_base = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as source:
    manifest = json.load(source)

expected_keys = {
    "schema", "base_path", "source_schema", "target_schema", "files",
}
if not isinstance(manifest, dict) or set(manifest) != expected_keys:
    raise SystemExit("backup manifest has an unsupported shape")
if manifest["schema"] != "masc.auth-admin-to-role.backup.v1":
    raise SystemExit("backup manifest schema is unsupported")
if manifest["base_path"] != requested_base:
    raise SystemExit("backup base path does not match the requested base path")
if manifest["source_schema"] != "agent-credential.role-plus-admin":
    raise SystemExit("backup source schema is unsupported")
if manifest["target_schema"] != "agent-credential.role-only":
    raise SystemExit("backup target schema is unsupported")
files = manifest["files"]
if (
    not isinstance(files, list)
    or not files
    or any(not isinstance(name, str) or not name.endswith(".json") for name in files)
    or files != sorted(set(files))
):
    raise SystemExit("backup manifest file inventory is invalid")
PY
}

manifest_file_list() {
    local manifest="$1"
    python3 - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    for name in json.load(source)["files"]:
        print(name)
PY
}

inventory_file_list() {
    local directory="$1"
    find "$directory" -maxdepth 1 -type f -name '*.json' -exec basename {} \; \
        | LC_ALL=C sort
}

restore_backup() {
    local runtime_root="$1"
    local agents_dir="${runtime_root}/auth/agents"
    local backup_dir
    backup_dir="$(canonical_directory "$RESTORE_DIR")"
    local manifest="${backup_dir}/manifest.json"
    local checksums="${backup_dir}/checksums.sha256"
    local backup_agents="${backup_dir}/agents"

    [[ -f "$manifest" ]] || die "backup manifest not found: $manifest"
    [[ -f "$checksums" ]] || die "backup checksums not found: $checksums"
    [[ -d "$backup_agents" ]] || die "backup credential directory not found: $backup_agents"
    validate_manifest "$manifest" "$BASE_PATH" \
        || die "backup manifest validation failed: $manifest"
    (cd "$backup_dir" && shasum -a 256 -c checksums.sha256 >/dev/null) \
        || die "backup checksum verification failed: $backup_dir"

    cmp -s <(manifest_file_list "$manifest") <(inventory_file_list "$backup_agents") \
        || die "backup credential set does not match its manifest"
    cmp -s <(manifest_file_list "$manifest") <(inventory_file_list "$agents_dir") \
        || die "current credential set does not match the backup manifest"

    local backup_file kind
    shopt -s nullglob
    for backup_file in "$backup_agents"/*.json; do
        kind="$(credential_kind "$backup_file")" \
            || die "invalid backup credential: $backup_file"
        [[ "$kind" == "legacy" || "$kind" == "redirect" ]] \
            || die "backup contains a non-source credential: $backup_file"
    done

    local restored=0 target
    for backup_file in "$backup_agents"/*.json; do
        target="${agents_dir}/$(basename "$backup_file")"
        [[ -f "$target" ]] || die "restore target disappeared: $target"
        restored=$((restored + 1))
    done
    for backup_file in "$backup_agents"/*.json; do
        target="${agents_dir}/$(basename "$backup_file")"
        atomic_copy "$backup_file" "$target"
    done
    shopt -u nullglob

    collect_inventory "$agents_dir"
    [[ "${#CURRENT_FILES[@]}" -eq 0 ]] \
        || die "restore left current-only credentials in the source inventory"
    echo "Restored $restored credential file(s) from $backup_dir"
}

run_migration() {
    require_command python3
    require_command shasum
    require_command cmp
    require_command find
    BASE_PATH="$(canonical_directory "$BASE_PATH")"
    local runtime_root="${BASE_PATH}/.masc"
    local agents_dir="${runtime_root}/auth/agents"

    if [[ -n "$RESTORE_DIR" ]]; then
        ensure_stopped "$runtime_root"
        restore_backup "$runtime_root"
        return
    fi

    collect_inventory "$agents_dir"
    echo "Validated ${#ALL_FILES[@]} file(s): ${#LEGACY_FILES[@]} legacy credential(s), ${#CURRENT_FILES[@]} current credential(s), ${#REDIRECT_FILES[@]} redirect(s)"

    if [[ "$MODE" == "dry-run" ]]; then
        echo "Dry run only. Re-run with --apply --confirm-stopped to migrate."
        return
    fi

    ensure_stopped "$runtime_root"
    if [[ "${#LEGACY_FILES[@]}" -eq 0 ]]; then
        echo "All credentials already use the role-only schema; no changes made."
        return
    fi

    umask 077
    local backup_dir
    backup_dir="${runtime_root}/migrations/auth-admin-to-role/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "${backup_dir}/agents" "${backup_dir}/rendered"

    local file basename backup_file rendered_file
    for file in "${ALL_FILES[@]}"; do
        basename="$(basename "$file")"
        backup_file="${backup_dir}/agents/${basename}"
        cp -p "$file" "$backup_file"
    done
    (
        cd "$backup_dir"
        shasum -a 256 agents/*.json > checksums.sha256
    )
    write_manifest "${backup_dir}/manifest.json" "$BASE_PATH" "${ALL_FILES[@]}"

    for file in "${LEGACY_FILES[@]}"; do
        basename="$(basename "$file")"
        rendered_file="${backup_dir}/rendered/${basename}"
        render_current_credential "$file" "$rendered_file"
    done
    sync_backup_tree "$backup_dir"

    local migration_active=true
    rollback_and_exit() {
        local exit_code="$1"
        trap - ERR INT TERM HUP
        if [[ "$migration_active" == true ]]; then
            echo "Credential migration failed; restoring original bytes..." >&2
            RESTORE_DIR="$backup_dir"
            restore_backup "$runtime_root" >&2 || true
        fi
        exit "$exit_code"
    }
    trap 'rollback_and_exit $?' ERR
    trap 'rollback_and_exit 130' INT
    trap 'rollback_and_exit 143' TERM
    trap 'rollback_and_exit 129' HUP

    local replaced=0
    for file in "${LEGACY_FILES[@]}"; do
        basename="$(basename "$file")"
        rendered_file="${backup_dir}/rendered/${basename}"
        atomic_copy "$rendered_file" "$file"
        [[ "$(credential_kind "$file")" == "current" ]] \
            || die "installed credential failed validation: $file"
        replaced=$((replaced + 1))
        if [[ "${MASC_AUTH_ADMIN_MIGRATION_SELF_TEST_FAIL_AFTER_REPLACE:-}" == "$replaced" ]]; then
            false
        fi
    done

    collect_inventory "$agents_dir"
    [[ "${#LEGACY_FILES[@]}" -eq 0 ]] \
        || die "legacy credentials remain after migration"
    migration_active=false
    trap - ERR INT TERM HUP
    echo "Migrated $replaced credential(s) to the role-only schema."
    echo "Backup: $backup_dir"
    echo "Rollback: $0 --base-path \"$BASE_PATH\" --restore \"$backup_dir\" --confirm-stopped"
    echo "Next: start only a runtime whose credential writer no longer emits admin (#26220+)."
}

self_test() {
    require_command python3
    require_command shasum
    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/masc-auth-admin-migration.XXXXXX")"
    SELF_TEST_FIXTURE="$fixture"
    trap cleanup_self_test EXIT
    local agents_dir="${fixture}/.masc/auth/agents"
    mkdir -p "$agents_dir"

    printf '%s\n' \
        '{"id":"id-alpha","agent_id":"agent-alpha","agent_name":"alpha","token":"hash-alpha","role":"admin","admin":true,"created_at":"2026-07-29T00:00:00Z","expires_at":null}' \
        > "${agents_dir}/alpha.json"
    printf '%s\n' \
        '{"id":"id-beta","agent_id":null,"agent_name":"beta","token":"hash-beta","role":"worker","admin":false,"created_at":"2026-07-29T00:00:00Z","expires_at":"2026-08-01T00:00:00Z"}' \
        > "${agents_dir}/beta.json"
    printf '%s\n' '{"redirect_to":"alpha.json"}' > "${agents_dir}/alias.json"
    chmod 0600 "$agents_dir"/*.json

    local before
    before="$(shasum -a 256 "$agents_dir"/*.json)"
    MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" >/dev/null
    [[ "$(shasum -a 256 "$agents_dir"/*.json)" == "$before" ]] \
        || die "self-test: dry run changed credential bytes"

    local output backup_dir
    output="$(
        MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
            "$0" --base-path "$fixture" --apply --confirm-stopped
    )"
    backup_dir="$(printf '%s\n' "$output" | sed -n 's/^Backup: //p')"
    [[ -n "$backup_dir" && -d "$backup_dir" ]] \
        || die "self-test: backup directory was not reported"
    [[ "$(credential_kind "${agents_dir}/alpha.json")" == "current" ]] \
        || die "self-test: admin credential was not migrated"
    [[ "$(credential_kind "${agents_dir}/beta.json")" == "current" ]] \
        || die "self-test: worker credential was not migrated"
    [[ "$(credential_kind "${agents_dir}/alias.json")" == "redirect" ]] \
        || die "self-test: redirect was changed"
    [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "${agents_dir}/alpha.json")" == "hash-alpha" ]] \
        || die "self-test: token hash changed"

    MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" --apply --confirm-stopped >/dev/null

    local incomplete_backup
    incomplete_backup="${fixture}/incomplete-backup"
    cp -R "$backup_dir" "$incomplete_backup"
    rm -f "${incomplete_backup}/agents/beta.json"
    grep -v 'agents/beta.json' "${incomplete_backup}/checksums.sha256" \
        > "${incomplete_backup}/checksums.sha256.tmp"
    mv "${incomplete_backup}/checksums.sha256.tmp" "${incomplete_backup}/checksums.sha256"
    if MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" --restore "$incomplete_backup" --confirm-stopped \
        >/dev/null 2>&1
    then
        die "self-test: incomplete backup was restored"
    fi
    [[ "$(credential_kind "${agents_dir}/alpha.json")" == "current" ]] \
        || die "self-test: failed incomplete restore changed current credentials"

    MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" --restore "$backup_dir" --confirm-stopped >/dev/null
    [[ "$(credential_kind "${agents_dir}/alpha.json")" == "legacy" ]] \
        || die "self-test: restore did not recover legacy credential"

    if MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
        MASC_AUTH_ADMIN_MIGRATION_SELF_TEST_FAIL_AFTER_REPLACE=1 \
        "$0" --base-path "$fixture" --apply --confirm-stopped >/dev/null 2>&1
    then
        die "self-test: injected replacement failure did not fail"
    fi
    [[ "$(credential_kind "${agents_dir}/alpha.json")" == "legacy" ]] \
        || die "self-test: failed migration did not restore alpha"
    [[ "$(credential_kind "${agents_dir}/beta.json")" == "legacy" ]] \
        || die "self-test: failed migration did not restore beta"

    printf '%s\n' \
        '{"id":"id-duplicate","id":"id-duplicate","agent_id":null,"agent_name":"duplicate","token":"hash-duplicate","role":"worker","admin":false,"created_at":"2026-07-29T00:00:00Z","expires_at":null}' \
        > "${agents_dir}/duplicate.json"
    if MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" >/dev/null 2>&1
    then
        die "self-test: duplicate credential field was accepted"
    fi
    rm -f "${agents_dir}/duplicate.json"

    python3 - "${agents_dir}/alpha.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    value = json.load(source)
value["admin"] = False
with open(path, "w", encoding="utf-8") as target:
    json.dump(value, target)
    target.write("\n")
PY
    if MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" >/dev/null 2>&1
    then
        die "self-test: role/admin disagreement was accepted"
    fi
    cp "${backup_dir}/agents/alpha.json" "${agents_dir}/alpha.json"

    render_current_credential "${agents_dir}/alpha.json" "${agents_dir}/alpha-current.json"
    mv "${agents_dir}/alpha-current.json" "${agents_dir}/alpha.json"
    if MASC_AUTH_ADMIN_MIGRATION_SELF_TEST=1 \
        "$0" --base-path "$fixture" >/dev/null 2>&1
    then
        die "self-test: mixed legacy/current inventory was accepted"
    fi

    echo "credential admin-to-role migration self-test: PASS"
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
