#!/usr/bin/env bash
# One-shot archive for storage owned by the removed Keeper chat implementation.
# Run only while deployment_preflight_helper lease-run owns the BasePath lease.

set -euo pipefail

BASE_PATH=""
ARCHIVE_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFLIGHT_HELPER="${MASC_DEPLOYMENT_PREFLIGHT_HELPER:-}"

fail() {
  printf '[keeper-chat-cutover-archive] FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,/^$/p' "$0"
  printf 'Usage: %s --base-path PATH --archive-dir ABSOLUTE_PATH\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path)
      [[ $# -ge 2 ]] || fail "--base-path requires a value"
      BASE_PATH="$2"
      shift 2
      ;;
    --archive-dir)
      [[ $# -ge 2 ]] || fail "--archive-dir requires a value"
      ARCHIVE_DIR="$2"
      shift 2
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

[[ -n "$BASE_PATH" ]] || fail "--base-path is required"
[[ -n "$ARCHIVE_DIR" ]] || fail "--archive-dir is required"
[[ "$ARCHIVE_DIR" == /* ]] || fail "archive path must be absolute: $ARCHIVE_DIR"
command -v jq >/dev/null 2>&1 || fail "jq is required"
if command -v sha256sum >/dev/null 2>&1; then
  HASH_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_TOOL="shasum"
else
  fail "sha256sum or shasum is required to seal the archive"
fi

if [[ -z "$PREFLIGHT_HELPER" ]]; then
  if [[ -x "$SCRIPT_DIR/masc-deployment-preflight-helper" ]]; then
    PREFLIGHT_HELPER="$SCRIPT_DIR/masc-deployment-preflight-helper"
  elif [[ -x "$REPO_ROOT/_build/default/bin/deployment_preflight_helper.exe" ]]; then
    PREFLIGHT_HELPER="$REPO_ROOT/_build/default/bin/deployment_preflight_helper.exe"
  else
    fail "typed deployment preflight helper is required"
  fi
fi
[[ -x "$PREFLIGHT_HELPER" ]] || fail "typed deployment preflight helper is not executable: $PREFLIGHT_HELPER"

owner_pid="${MASC_DEPLOYMENT_LEASE_OWNER_PID:-}"
[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] \
  || fail "run this script through deployment_preflight_helper lease-run"
"$PREFLIGHT_HELPER" verify-lease-owner \
  --base-path "$BASE_PATH" \
  --owner-pid "$owner_pid" \
  >/dev/null \
  || fail "BasePath lease proof is invalid"

requested_base_path="$(cd "$BASE_PATH" && pwd -L)"
requested_archive_parent="$(dirname "$ARCHIVE_DIR")"
archive_name="$(basename "$ARCHIVE_DIR")"
[[ -n "$archive_name" && "$archive_name" != "." && "$archive_name" != ".." ]] \
  || fail "archive destination has an invalid final component"
requested_archive_parent_name="$(basename "$requested_archive_parent")"
[[ "$requested_archive_parent_name" == "archive" ]] \
  || fail "archive destination must be below the BasePath archive directory"
requested_archive_runtime_root="$(dirname "$requested_archive_parent")"
[[ -d "$requested_archive_runtime_root" && ! -L "$requested_archive_runtime_root" ]] \
  || fail "archive runtime root is not an exact directory: $requested_archive_runtime_root"
requested_archive_parent="$(cd "$requested_archive_runtime_root" && pwd -L)/archive"
BASE_PATH="$(cd "$BASE_PATH" && pwd -P)"
runtime_root="$BASE_PATH/.masc"
keepers_root="$runtime_root/keepers"
archive_parent="$runtime_root/archive"

[[ -d "$runtime_root" && ! -L "$runtime_root" ]] \
  || fail "runtime root is not an exact directory: $runtime_root"
if [[ "$requested_archive_parent" != "$requested_base_path/.masc/archive" \
      && "$requested_archive_parent" != "$archive_parent" ]]; then
  fail "archive destination must be an immediate child of $archive_parent"
fi
ARCHIVE_DIR="$archive_parent/$archive_name"
[[ ! -e "$ARCHIVE_DIR" && ! -L "$ARCHIVE_DIR" ]] \
  || fail "archive destination already exists: $ARCHIVE_DIR"
if [[ -e "$archive_parent" || -L "$archive_parent" ]]; then
  [[ -d "$archive_parent" && ! -L "$archive_parent" ]] \
    || fail "archive parent is not an exact directory: $archive_parent"
fi
if [[ -e "$keepers_root" || -L "$keepers_root" ]]; then
  [[ -d "$keepers_root" && ! -L "$keepers_root" ]] \
    || fail "Keeper runtime root is not an exact directory: $keepers_root"
  symlink_path="$(find "$keepers_root" -type l -print -quit)"
  [[ -z "$symlink_path" ]] || fail "Keeper runtime root contains a symlink: $symlink_path"
fi

report="$("$PREFLIGHT_HELPER" inspect-keeper-chat-cutover --base-path "$BASE_PATH")" \
  || fail "Keeper chat cutover inventory could not be read"
active_queue_rows="$(jq -er '.active_queue_row_count' <<<"$report")" \
  || fail "inventory omitted active_queue_row_count"
direct_markers="$(jq -er '.direct_marker_count' <<<"$report")" \
  || fail "inventory omitted direct_marker_count"
artifact_count="$(jq -er '.artifact_count' <<<"$report")" \
  || fail "inventory omitted artifact_count"

[[ "$active_queue_rows" -eq 0 ]] \
  || fail "refusing to archive $active_queue_rows active queue rows"
[[ "$direct_markers" -eq 0 ]] \
  || fail "refusing to archive $direct_markers active direct-delivery markers"
[[ "$artifact_count" -gt 0 ]] || fail "no Keeper chat cutover artifacts found"

if [[ ! -e "$archive_parent" ]]; then
  mkdir "$archive_parent"
fi
mkdir "$ARCHIVE_DIR"
printf '%s\n' "$report" >"$ARCHIVE_DIR/preflight.json"
printf 'schema=masc.keeper_chat_cutover_archive.v1\nbase_path=%s\narchived_at_utc=%s\n' \
  "$BASE_PATH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >"$ARCHIVE_DIR/manifest.txt"

artifact_paths=()
while IFS= read -r source_path; do
  artifact_paths+=("$source_path")
done < <(
  jq -r '
    [.queue_databases[].path,
     .queue_sidecars[].path,
     .direct_delivery_directories[].path] | .[]
  ' <<<"$report"
)
[[ "${#artifact_paths[@]}" -eq "$artifact_count" ]] \
  || fail "inventory artifact count changed while preparing archive"

for source_path in "${artifact_paths[@]}"; do
  case "$source_path" in
    "$keepers_root"/*) ;;
    *) fail "inventory returned a path outside the Keeper runtime root: $source_path" ;;
  esac
  [[ -e "$source_path" && ! -L "$source_path" ]] \
    || fail "inventory artifact changed before archive: $source_path"
  relative_path="${source_path#"$runtime_root"/}"
  destination="$ARCHIVE_DIR/$relative_path"
  mkdir -p "$(dirname "$destination")"
  mv "$source_path" "$destination"
done

post_report="$("$PREFLIGHT_HELPER" inspect-keeper-chat-cutover --base-path "$BASE_PATH")" \
  || fail "post-archive Keeper chat cutover inventory could not be read"
post_artifact_count="$(jq -er '.artifact_count' <<<"$post_report")" \
  || fail "post-archive inventory omitted artifact_count"
[[ "$post_artifact_count" -eq 0 ]] \
  || fail "Keeper chat artifacts remain after archive: $post_report"
printf '%s\n' "$post_report" >"$ARCHIVE_DIR/postflight.json"

if [[ "$HASH_TOOL" == "sha256sum" ]]; then
  (cd "$ARCHIVE_DIR" && find . -type f ! -name SHA256SUMS -print0 \
    | xargs -0 sha256sum) >"$ARCHIVE_DIR/SHA256SUMS"
else
  (cd "$ARCHIVE_DIR" && find . -type f ! -name SHA256SUMS -print0 \
    | xargs -0 shasum -a 256) >"$ARCHIVE_DIR/SHA256SUMS"
fi

printf '[keeper-chat-cutover-archive] OK: artifacts=%d archive=%s\n' \
  "$artifact_count" "$ARCHIVE_DIR"
