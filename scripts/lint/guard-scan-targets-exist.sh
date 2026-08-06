#!/usr/bin/env bash
# A guard that lists files to scan must list files that are there.
#
# The scanners in scripts/lint and scripts/audit hold their scope as a bash
# array of repo-relative paths and skip anything missing — usually a literal
# `[[ -f "$file" ]] || return 0`. So when a file moves or goes away the guard
# keeps reporting OK over a smaller set, and nothing says the scope shrank.
#
# Measured on the tree this was written against:
#
#   no-legacy-tool-surface-name.sh          16 declared, 10 scanned
#   no-tool-substrate-adapter-surface.sh     8 declared,  4 scanned
#   no-runtime-literal-outside-boundary-…   20 declared, 13 scanned
#   audit-shell-ir-consumption.sh            3 declared,  2 scanned
#
# Four of those entries were not deletions: lib/tool_catalog.{ml,mli} and
# lib/tool_catalog_surfaces.{ml,mli} had moved into their own directories and
# were still being written to, just no longer watched.
#
# Usage: guard-scan-targets-exist.sh [--fail|--print|--self-test]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MODE="${1:---fail}"
case "$MODE" in
  --fail | --print | --self-test) ;;
  -h | --help)
    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print|--self-test]" >&2
    exit 2
    ;;
esac

command -v rg >/dev/null 2>&1 || {
  echo "[guard-scan-targets-exist] required tool missing: rg" >&2
  exit 2
}

# A scan-scope entry is a whole line holding one quoted repo-relative source
# path: the shape bash arrays take. Paths appearing mid-line are arguments,
# globs or prose, and are not scope declarations.
#
# This file's own examples sit in comments, never alone on a line inside
# quotes, so it does not report itself — but it is skipped anyway rather than
# rely on that.
scan_entries() {
  local tree="$1"
  rg --line-number --no-heading \
    --glob '*.sh' \
    --glob '!guard-scan-targets-exist.sh' \
    '(^|[[:space:]])"((lib|dashboard|bin)/[A-Za-z0-9/_.-]+\.[a-z]+)"[[:space:]]*\\?[[:space:]]*$' \
    -r '$2' \
    "$tree/scripts" 2>/dev/null || true
}

report() {
  local tree="$1" row file path
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    file="${row%%:*}"
    path="${row##*:}"
    # rg -r keeps whatever preceded the match on the line, so an entry passed as
    # a continued argument arrives indented.
    path="${path#"${path%%[![:space:]]*}"}"
    [ -e "$tree/$path" ] || echo "${file#"$tree/"}|$path"
  done < <(scan_entries "$tree")
}

case "$MODE" in
  --print)
    report "$ROOT"
    exit 0
    ;;
  --self-test)
    scratch="$(mktemp -d -t guard-scan-targets.XXXXXX)"
    trap 'rm -rf "$scratch"' EXIT
    mkdir -p "$scratch/scripts" "$scratch/lib"
    printf 'SCAN_FILES=(\n  "lib/present.ml"\n  "lib/absent.ml"\n)\n' \
      >"$scratch/scripts/probe.sh"
    : >"$scratch/lib/present.ml"
    got="$(report "$scratch")"
    if [ "$got" != "scripts/probe.sh|lib/absent.ml" ]; then
      echo "[guard-scan-targets-exist] self-test: expected the absent entry, got '${got}'" >&2
      exit 1
    fi
    : >"$scratch/lib/absent.ml"
    if [ -n "$(report "$scratch")" ]; then
      echo "[guard-scan-targets-exist] self-test: a present entry was still reported" >&2
      exit 1
    fi
    echo "[guard-scan-targets-exist] self-test OK"
    exit 0
    ;;
esac

stale="$(report "$ROOT")"
declared="$(scan_entries "$ROOT" | wc -l | tr -d ' ')"

if [ -z "$stale" ]; then
  echo "[guard-scan-targets-exist] OK: ${declared} declared scan targets, every one present"
  exit 0
fi

echo "[guard-scan-targets-exist] a guard declares a scan target that is not there:" >&2
while IFS='|' read -r file path; do
  [ -n "$path" ] || continue
  echo "  $file" >&2
  echo "      → $path" >&2
done <<<"$stale"
echo >&2
echo "Repoint it if the file moved; drop it if the file is gone. Leaving it" >&2
echo "makes the guard pass over a scope smaller than the one it states." >&2
exit 1
