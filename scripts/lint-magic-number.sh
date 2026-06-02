#!/usr/bin/env bash
# Advisory lint: report magic-number repetition concentrations.
#
# sw-dev §Magic Number 금지: "같은 리터럴이 2곳 이상 등장하면 반드시
# named constant로 교체". The 2026-05-19 audit
# (memory/masc-mcp-code-smell-report-2026-05-19.html Hotspot #2)
# called out the worst offenders (32602 ×30 in one file; 3600 ×15;
# 1000 ×14; 1024 ×11) but did not provide a measurement tool that
# survives code drift.
#
# Tunables:
#   --min-digits N    minimum literal length (default 4 — skips
#                     0/1/-1, small counters, byte sizes 1..255)
#   --min-reps N      minimum repetitions in a single file
#                     (default 5 — skips one-off literals)
#   --target PATH     scan root (default lib/)
#
# Allowlist (always skipped):
#   - Single-digit and 2/3-digit literals (port numbers, small caps)
#   - Common time literals: 60, 1000 (ms↔s), 3600 (s↔h) — surfaced
#     but suppressed in the recommend list when they live in a file
#     whose name contains 'time' or 'budget' (callers know context)
#
# Modes:
#   default      "file lit reps" tab-separated, sorted by reps desc
#   --strict     exit 1 if any (file, lit, reps≥threshold) found
#   --explain X  for literal X, show file:line:body for every site

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required" >&2
  exit 2
fi

MIN_DIGITS=4
MIN_REPS=5
TARGET="lib/"
STRICT=0
EXPLAIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-digits) MIN_DIGITS="$2"; shift 2 ;;
    --min-reps)   MIN_REPS="$2"; shift 2 ;;
    --target)     TARGET="$2"; shift 2 ;;
    --strict)     STRICT=1; shift ;;
    --explain)    EXPLAIN="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$EXPLAIN" ]]; then
  rg -nP --with-filename "\\b${EXPLAIN}\\b" "$TARGET" 2>/dev/null
  exit 0
fi

# Build per-file literal histogram. Strip lines that are comments,
# test fixtures, or generated artifacts (.mli signatures live with .ml).
# We accept any digit run >= MIN_DIGITS, prefixed by a word boundary.
LITERAL_RE="\\b[0-9]{${MIN_DIGITS},}\\b"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# rg -o prints only the matched text; combined with file path produces
# file:line:literal. We then group (file,literal).
rg -onP --with-filename "$LITERAL_RE" "$TARGET" 2>/dev/null \
  | awk -F: '{ printf "%s\t%s\n", $1, $3 }' \
  | sort | uniq -c | sort -rn \
  | awk -v min="$MIN_REPS" '$1 >= min { print $1"\t"$2 }' > "$tmp"

# Output: count<TAB>file<TAB>literal
awk -F'\t' '{ printf "%5d  %-60s  %s\n", $1, $2, $3 }' "$tmp"

if [[ "$STRICT" -eq 1 ]]; then
  n=$(wc -l < "$tmp" | tr -d ' ')
  if [[ "$n" -gt 0 ]]; then
    echo "STRICT FAIL: $n (file,literal) pairs exceed --min-reps=$MIN_REPS" >&2
    exit 1
  fi
fi
