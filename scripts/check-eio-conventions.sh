#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if command -v rg >/dev/null 2>&1; then
  HAVE_RG=1
else
  HAVE_RG=0
fi

search_lines() {
  local pattern="$1"
  shift
  if [ "$HAVE_RG" -eq 1 ]; then
    rg -n "$pattern" "$@" 2>/dev/null || true
  else
    grep -R -n -E -- "$pattern" "$@" 2>/dev/null || true
  fi
}

count_matches() {
  local pattern="$1"
  shift
  if [ "$HAVE_RG" -eq 1 ]; then
    rg -o "$pattern" "$@" 2>/dev/null || true
  else
    grep -R -h -o -E -- "$pattern" "$@" 2>/dev/null || true
  fi
}

count_total() {
  local pattern="$1"
  shift
  count_matches "$pattern" "$@" | wc -l | tr -d '[:space:]'
}

exclude_lines() {
  local pattern="$1"
  if [ "$HAVE_RG" -eq 1 ]; then
    rg -v "$pattern" || true
  else
    grep -E -v -- "$pattern" || true
  fi
}

fail=0

eio_sleep_hits="$(search_lines 'Eio_unix\.sleep\b' lib)"
if [ -n "$eio_sleep_hits" ]; then
  echo "ERROR: forbidden Eio_unix.sleep usage under lib/" >&2
  printf '%s\n' "$eio_sleep_hits" >&2
  fail=1
fi

blocking_sleep_hits="$(search_lines 'Unix\.sleep(f)?\b' lib)"
if [ -n "$blocking_sleep_hits" ]; then
  disallowed_blocking_sleep_hits="$(
    printf '%s\n' "$blocking_sleep_hits" \
      | exclude_lines '^lib/(process/file_lock_eio\.ml|shutdown\.ml):'
  )"
  if [ -n "$disallowed_blocking_sleep_hits" ]; then
    echo "ERROR: raw Unix.sleep/Unix.sleepf usage is only allowed in lib/process/file_lock_eio.ml and lib/shutdown.ml" >&2
    printf '%s\n' "$disallowed_blocking_sleep_hits" >&2
    fail=1
  fi
fi

echo "Eio convention snapshot:"
echo "  lib/Eio_unix.sleep: $(count_total 'Eio_unix\.sleep\b' lib)"
echo "  lib/Unix.sleep*: $(count_total 'Unix\.sleep(f)?\b' lib)"
echo "  lib/Eio.Mutex.create (): $(count_total 'Eio\.Mutex\.create \(\)' lib)"
echo "  lib/Eio.Fiber.fork: $(count_total 'Eio\.Fiber\.fork\b' lib)"
echo "  lib+test/fork_promise: $(count_total 'fork_promise\b' lib test)"

exit "$fail"
