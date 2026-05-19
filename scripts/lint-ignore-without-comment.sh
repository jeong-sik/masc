#!/usr/bin/env bash
# Lint: every `ignore (...)` call must carry a justification comment
# either on the previous line or on the same line.
#
# Rationale: sw-dev §임시조치 주석 의무. `ignore (...)` discards a
# return value (and therefore a contract) without saying why. The
# 2026-05-19 audit
# (memory/masc-mcp-code-smell-report-2026-05-19.html Hotspot #4)
# found 94 ignore() calls of which 85 had no comment. PR #16609
# removed the keeper_registry concentration (10 sites); the
# remaining ~75 are scattered across the tree.
#
# This script does NOT mutate code. It surfaces ignore() sites that
# lack a justification and lets reviewers decide whether to add a
# comment, change the signature, or accept the site as fire-and-
# forget (with a comment).
#
# Accepted justification shapes (same line OR previous line):
#   (* WORKAROUND: ... *)
#   (* HACK: ... *)
#   (* fire-and-forget: ... *)
#   (* RFC-XXXX: ... *)        — RFC-anchored
#   (* TODO: ... *)            — explicit deferral
#   (* See ... *)              — cross-reference
#
# Test files are excluded by default (mock setup, fixture noise).
#
# Modes:
#   default     list every site that lacks justification (file:line:body)
#   --counts    per-file totals
#   --strict    exit 1 if any unjustified site found (CI ratchet)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required" >&2
  exit 2
fi

MODE="list"
STRICT=0
TARGET="lib/"
INCLUDE_TESTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --counts)        MODE="counts"; shift ;;
    --strict)        STRICT=1; shift ;;
    --include-tests) INCLUDE_TESTS=1; shift ;;
    --target)        TARGET="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Regex matching accepted justification keywords inside an OCaml
# comment. Match anywhere in the line (handles same-line comments).
JUSTIFY_RE='\(\*[[:space:]]*(WORKAROUND|HACK|fire-and-forget|RFC-[0-9]{4}|TODO|See|see)\b'

tmp_all="$(mktemp)"
tmp_unjust="$(mktemp)"
trap 'rm -f "$tmp_all" "$tmp_unjust"' EXIT

# Collect every ignore() site (line-prefixed with whitespace, then "ignore (")
rg -nP --with-filename '^\s*ignore \(' "$TARGET" 2>/dev/null > "$tmp_all"

# Drop test files unless asked
if [[ "$INCLUDE_TESTS" -eq 0 ]]; then
  grep -v '/test/' "$tmp_all" > "$tmp_all.notest" || true
  mv "$tmp_all.notest" "$tmp_all"
fi

# For each site, look at: (a) same line for inline comment, (b) previous line
while IFS= read -r site; do
  file="${site%%:*}"
  rest="${site#*:}"
  lineno="${rest%%:*}"
  body="${rest#*:}"

  same_line_ok=0
  prev_line_ok=0

  if printf '%s\n' "$body" | rg -qP "$JUSTIFY_RE"; then
    same_line_ok=1
  fi

  if [[ "$lineno" -gt 1 ]]; then
    prev_line="$(sed -n "$((lineno-1))p" "$file" 2>/dev/null || true)"
    if printf '%s\n' "$prev_line" | rg -qP "$JUSTIFY_RE"; then
      prev_line_ok=1
    fi
  fi

  if [[ "$same_line_ok" -eq 0 && "$prev_line_ok" -eq 0 ]]; then
    printf '%s\n' "$site" >> "$tmp_unjust"
  fi
done < "$tmp_all"

case "$MODE" in
  list)
    cat "$tmp_unjust"
    ;;
  counts)
    cut -d: -f1 "$tmp_unjust" | sort | uniq -c | sort -rn
    ;;
esac

if [[ "$STRICT" -eq 1 ]]; then
  n=$(wc -l < "$tmp_unjust" | tr -d ' ')
  if [[ "$n" -gt 0 ]]; then
    echo "STRICT FAIL: $n ignore() sites lack a justification comment" >&2
    exit 1
  fi
fi
