#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="${MASC_DEPLOYMENT_PREFLIGHT_HELPER:-$REPO_ROOT/_build/default/bin/deployment_preflight_helper.exe}"
ARCHIVE_SCRIPT="$REPO_ROOT/scripts/archive-keeper-chat-cutover-v1.sh"

[[ -x "$HELPER" ]] || {
  printf '[keeper-chat-cutover-archive-test] helper is not executable: %s\n' "$HELPER" >&2
  exit 1
}

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/keeper-chat-cutover-archive.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

success_base="$fixture_root/success"
requested_archive="$success_base/.masc/archive/smoke"
mkdir -p "$success_base/.masc/keepers/demo/.chat-direct-active-v1"
MASC_DEPLOYMENT_PREFLIGHT_HELPER="$HELPER" \
  "$HELPER" lease-run \
    --base-path "$success_base" \
    -- \
    "$ARCHIVE_SCRIPT" \
      --base-path "$success_base" \
      --archive-dir "$requested_archive" \
    >/dev/null

canonical_base="$(cd "$success_base" && pwd -P)"
canonical_archive="$canonical_base/.masc/archive/smoke"
[[ -d "$canonical_archive/keepers/demo/.chat-direct-active-v1" ]]
[[ -f "$canonical_archive/SHA256SUMS" ]]
"$HELPER" inspect-keeper-chat-cutover --base-path "$success_base" \
  | jq -e '.artifact_count == 0 and .stranded_work_count == 0' \
  >/dev/null

blocked_base="$fixture_root/blocked"
blocked_archive="$blocked_base/.masc/archive/smoke"
mkdir -p "$blocked_base/.masc/keepers/demo/.chat-direct-active-v1"
touch "$blocked_base/.masc/keepers/demo/.chat-direct-active-v1/kmsg-active"
if MASC_DEPLOYMENT_PREFLIGHT_HELPER="$HELPER" \
  "$HELPER" lease-run \
    --base-path "$blocked_base" \
    -- \
    "$ARCHIVE_SCRIPT" \
      --base-path "$blocked_base" \
      --archive-dir "$blocked_archive" \
    >/dev/null 2>&1; then
  printf '[keeper-chat-cutover-archive-test] active marker was archived\n' >&2
  exit 1
fi
[[ -f "$blocked_base/.masc/keepers/demo/.chat-direct-active-v1/kmsg-active" ]]
[[ ! -e "$blocked_base/.masc/archive" ]]

escape_base="$fixture_root/escape"
escape_archive="$escape_base/.masc/archive/../outside"
mkdir -p "$escape_base/.masc/keepers/demo/.chat-direct-active-v1"
if MASC_DEPLOYMENT_PREFLIGHT_HELPER="$HELPER" \
  "$HELPER" lease-run \
    --base-path "$escape_base" \
    -- \
    "$ARCHIVE_SCRIPT" \
      --base-path "$escape_base" \
      --archive-dir "$escape_archive" \
    >/dev/null 2>&1; then
  printf '[keeper-chat-cutover-archive-test] escaping archive path was accepted\n' >&2
  exit 1
fi
[[ -d "$escape_base/.masc/keepers/demo/.chat-direct-active-v1" ]]
[[ ! -e "$escape_base/.masc/outside" ]]

printf '[keeper-chat-cutover-archive-test] OK\n'
