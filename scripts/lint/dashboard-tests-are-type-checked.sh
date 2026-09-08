#!/usr/bin/env bash
# Dashboard test files must not switch type checking off.
#
# `@ts-nocheck` turns off the whole file, so a fixture keeps compiling after the
# type it builds has gained, lost or renamed a field. That is not theory: the
# DashboardError fixtures in error-notification-state.test.ts kept a shape the
# type had already left, and the file still passed because it was nocheck'd.
#
# Generated output (schemas/*_generated.ts) is exempt: atdgen writes it and the
# repository does not hand-edit it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCAN_ROOT="${REPO_ROOT}/dashboard/src"

# A scan that finds no test files is a broken scope, not a clean repository.
MIN_TEST_FILES=400

scan() {
  local root="$1"
  rg --files "$root" -g '*.test.ts' -g '*.test.tsx' 2>/dev/null || true
}

offenders() {
  local root="$1"
  local files
  files="$(scan "$root")"
  [[ -n "$files" ]] || return 0
  printf '%s\n' "$files" | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if rg -q '@ts-nocheck' "$f"; then printf '%s\n' "$f"; fi
  done
}

self_test() {
  local tmp status rc=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/src"

  printf 'export const a = 1\n' > "$tmp/src/clean.test.ts"
  status="$(offenders "$tmp/src")"
  if [[ -n "$status" ]]; then
    echo "[FAIL] a file without the marker was reported: $status" >&2
    rc=1
  else
    echo "[PASS] pass: a test file with no marker is not reported"
  fi

  printf '// @ts-nocheck\nexport const b = 2\n' > "$tmp/src/dirty.test.ts"
  status="$(offenders "$tmp/src")"
  if [[ "$status" == *"dirty.test.ts"* ]]; then
    echo "[PASS] fire: a test file carrying the marker is reported"
  else
    echo "[FAIL] the marker was not reported" >&2
    rc=1
  fi

  # A non-test file carrying the marker is out of scope.
  printf '// @ts-nocheck\nexport const c = 3\n' > "$tmp/src/generated.ts"
  status="$(offenders "$tmp/src")"
  if [[ "$status" == *"generated.ts"* ]]; then
    echo "[FAIL] a non-test file was reported" >&2
    rc=1
  else
    echo "[PASS] pass: a non-test file with the marker is out of scope"
  fi

  return "$rc"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

scanned="$(scan "$SCAN_ROOT" | wc -l | tr -d ' ')"
if (( scanned < MIN_TEST_FILES )); then
  echo "[ts-nocheck] scanned ${scanned} test file(s) under ${SCAN_ROOT}, expected at least ${MIN_TEST_FILES}." >&2
  echo "The scan scope is wrong, not the repository clean. Fix the glob or lower MIN_TEST_FILES with a reason." >&2
  exit 2
fi

found="$(offenders "$SCAN_ROOT")"
if [[ -n "$found" ]]; then
  echo "Dashboard test files must not disable type checking:" >&2
  printf '%s\n' "$found" | sed 's|^|  |' >&2
  echo >&2
  echo "Remove the @ts-nocheck line and fix what the compiler then reports." >&2
  exit 1
fi

echo "dashboard tests type-checked: 0 file(s) with @ts-nocheck across ${scanned} test file(s)"
