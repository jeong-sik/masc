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

# A scan-scope entry is a whole line holding one repo-relative source path:
# the shape bash arrays take. Paths appearing mid-line are arguments, globs or
# prose, and are not scope declarations.
#
# Both spellings count. Quotes are the common one, but an array literal takes
# bare words just as happily, and check-checkpoint-installation-legacy-purge.sh
# writes it that way — for two years its manual-compaction block scanned zero
# files without saying so, because this guard only looked inside quotes.
#
# The bare form has to start the line to be a declaration: that is what keeps
# prose and comments out, since a `#` can no longer precede the path.
#
# An exclusion glob is the third spelling. `-g '!dashboard/src/x.ts'` claims
# the file is there and deliberately out of scope, which rots exactly the way
# a scope entry does -- dashboard/src/goal-loop-status.ts was excluded from
# the normalizePhase check for two releases after it and its type were
# deleted, so the exclusion was silently narrowing nothing and waiting to
# re-apply to any future file of that name. Only paths under a source root
# count: a bare basename in a -g is matched against the scanned tree, not the
# repo, and this file excludes itself that way.
#
# This file's own examples sit in comments, so it does not report itself — but
# it is skipped anyway rather than rely on that.
scan_entries() {
  local tree="$1"
  rg --line-number --no-heading \
    --glob '*.sh' \
    --glob '!guard-scan-targets-exist.sh' \
    '(^|[[:space:]])"((lib|dashboard|bin)/[A-Za-z0-9/_.-]+\.[a-z]+)"[[:space:]]*\\?[[:space:]]*$' \
    -r '$2' \
    "$tree/scripts" 2>/dev/null || true
  rg --line-number --no-heading \
    --glob '*.sh' \
    --glob '!guard-scan-targets-exist.sh' \
    '^[[:space:]]*((lib|dashboard|bin)/[A-Za-z0-9/_.-]+\.[a-z]+)[[:space:]]*\\?[[:space:]]*$' \
    -r '$1' \
    "$tree/scripts" 2>/dev/null || true
  rg --line-number --no-heading \
    --glob '*.sh' \
    --glob '!guard-scan-targets-exist.sh' \
    "(-g|--glob)[[:space:]]+'!((lib|dashboard|bin|test)/[A-Za-z0-9/_.-]+\.[a-z]+)'" \
    -r '$2' \
    "$tree/scripts" 2>/dev/null || true
}

report() {
  local tree="$1" row file path
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    file="${row%%:*}"
    path="${row##*:}"
    # rg -r replaces the match and keeps the rest of the line, so an entry
    # arrives with whatever sat around it: indentation before, and for the
    # exclusion-glob arm a line-continuation after.
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]\\]}"}"
    # bin/*.exe is what dune produces, not a file a scanner reads: it is absent
    # from every clean checkout, so its absence says nothing about scope.
    case "$path" in *.exe) continue ;; esac
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
    # Both spellings, so neither arm can be dropped without this failing.
    printf 'SCAN_FILES=(\n  "lib/present.ml"\n  "lib/absent.ml"\n)\nBARE=(\n  lib/bare_present.ml\n  lib/bare_absent.ml\n)\nrg -n \\\n  -g '"'"'!lib/glob_present.ml'"'"' \\\n  -g '"'"'!lib/glob_absent.ml'"'"' \\\n  pat lib\n' \
      >"$scratch/scripts/probe.sh"
    : >"$scratch/lib/present.ml"
    : >"$scratch/lib/bare_present.ml"
    : >"$scratch/lib/glob_present.ml"
    want="scripts/probe.sh|lib/absent.ml
scripts/probe.sh|lib/bare_absent.ml
scripts/probe.sh|lib/glob_absent.ml"
    got="$(report "$scratch" | sort)"
    if [ "$got" != "$want" ]; then
      echo "[guard-scan-targets-exist] self-test: expected the two absent entries, got '${got}'" >&2
      exit 1
    fi
    : >"$scratch/lib/absent.ml"
    : >"$scratch/lib/bare_absent.ml"
    : >"$scratch/lib/glob_absent.ml"
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
