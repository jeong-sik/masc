#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
monitor="$repo_root/scripts/monitor-system-health.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

resolved="$(
  env -u MASC_BASE_PATH \
    "$monitor" \
    --base-path "$fixture" \
    --print-pressure-paths
)"
expected="$(
  printf 'state=%s/.masc/masc-host-pressure.state\nevents=%s/.masc/masc-host-pressure.events.jsonl' \
    "$fixture" \
    "$fixture"
)"
if [ "$resolved" != "$expected" ]; then
  printf 'unexpected default pressure paths\nexpected:\n%s\nactual:\n%s\n' \
    "$expected" \
    "$resolved" >&2
  exit 1
fi

custom_state="$fixture/custom/state.json"
resolved="$(
  MASC_BASE_PATH="$fixture" \
  MASC_HOST_FD_PRESSURE_STATE_FILE="$custom_state" \
    "$monitor" \
    --print-pressure-paths
)"
expected="$(
  printf 'state=%s\nevents=%s/.masc/masc-host-pressure.events.jsonl' \
    "$custom_state" \
    "$fixture"
)"
if [ "$resolved" != "$expected" ]; then
  printf 'unexpected overridden pressure paths\nexpected:\n%s\nactual:\n%s\n' \
    "$expected" \
    "$resolved" >&2
  exit 1
fi

if env -u MASC_BASE_PATH "$monitor" --print-pressure-paths >/dev/null 2>&1; then
  echo "missing base path unexpectedly succeeded" >&2
  exit 1
fi

if "$monitor" --base-path relative --print-pressure-paths >/dev/null 2>&1; then
  echo "relative base path unexpectedly succeeded" >&2
  exit 1
fi
