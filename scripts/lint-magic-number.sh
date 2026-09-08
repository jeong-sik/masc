#!/usr/bin/env bash
# Advisory lint: report magic-number repetition concentrations.
#
# sw-dev §Magic Number 금지: "같은 리터럴이 2곳 이상 등장하면 반드시
# named constant로 교체". The 2026-05-19 audit
# (memory/masc-code-smell-report-2026-05-19.html Hotspot #2)
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
#   --explain X  for literal X, show file:line:body for every site.
#                Unfiltered on purpose: the histogram above counts code
#                only, and a reader chasing a literal wants to see the
#                comment that explains it as well as the uses.

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

# Build a per-file literal histogram over code, not over prose.
#
# The comment above this used to say lines that are comments were stripped,
# and nothing stripped them. A digit run of four or more matches an RFC
# number, so `RFC-0233` cited ten times in one .mli read as a literal
# repeated ten times, and `RFC-0317` written into seven log messages in
# server_slack_in_process_gateway.ml read as seven more.
#
# Comments and string bodies both come out. A number inside a string is text
# -- the rule is about a value that appears in five places without a name,
# and "RFC-0317: Slack auth.test ok" is not one. Where a repeated string does
# carry a value that wants naming -- a loopback host, a config filename --
# check-ssot's R2 and R4 own that, and they name the SSOT to route it
# through, which this lint cannot.
#
# (* ... *) spans are removed whole rather than line by line, because that is
# where the citations live: a multi-line comment block is one span and a
# line-scoped filter sees only its middle lines.
#
# 80 pairs before, 10 after. Every one of the 10 is a numeric literal.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

python3 - "$TARGET" "$MIN_DIGITS" <<'HISTOGRAM' \
  | sort | uniq -c | sort -rn \
  | awk -v min="$MIN_REPS" '$1 >= min { print $1"\t"$2"\t"$3 }' > "$tmp"
import pathlib
import re
import sys

target, min_digits = sys.argv[1], int(sys.argv[2])
literal = re.compile(rb"\b[0-9]{%d,}\b" % min_digits)
comment = re.compile(rb"\(\*.*?\*\)", re.S)
# A double-quoted body, honouring backslash escapes so an embedded \" does
# not end it early.
string = re.compile(rb'"(?:[^"\\]|\\.)*"', re.S)

root = pathlib.Path(target)
paths = [root] if root.is_file() else sorted(root.rglob("*"))
for path in paths:
    if path.suffix not in (".ml", ".mli") or not path.is_file():
        continue
    code = string.sub(b' "" ', comment.sub(b" ", path.read_bytes()))
    for match in literal.findall(code):
        print(f"{path}\t{match.decode()}")
HISTOGRAM

# Output: count<TAB>file<TAB>literal
awk -F'\t' '{ printf "%5d  %-60s  %s\n", $1, $2, $3 }' "$tmp"

if [[ "$STRICT" -eq 1 ]]; then
  n=$(wc -l < "$tmp" | tr -d ' ')
  if [[ "$n" -gt 0 ]]; then
    echo "STRICT FAIL: $n (file,literal) pairs exceed --min-reps=$MIN_REPS" >&2
    exit 1
  fi
fi
