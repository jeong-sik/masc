#!/usr/bin/env bash
# Regenerate docs/rfc/RFC-0071-inventory.csv from current lib/ state.
#
# Lower-bound scan: catches single-line `| _ -> false`, `| _ -> None`,
# `| _ -> ()` patterns. Multi-line `_ ->` arms and `_ -> SomeCtor`
# permissive defaults are NOT captured — those need the typed-AST
# codemod (RFC-0071 §3.2, WS-3).
#
# Output schema (4 columns):
#   file,line,rhs,triage_class_guess
# - file: path relative to repo root
# - line: 1-indexed line number
# - rhs: literal RHS captured (false | None | ())
# - triage_class_guess: always "unclassified" at regen time; codemod
#   (RFC-0071 §3.4.1, WS-3) updates this during dry-run.
#
# Excluded: */test/, lib/exec/parser/ (Menhir-generated).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

OUTPUT="${OUTPUT:-docs/rfc/RFC-0071-inventory.csv}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Header + data rows (sorted stably).
{
  printf 'file,line,rhs,triage_class_guess\n'
  find lib -type f -name '*.ml' \
    -not -path 'lib/exec/parser/*' \
    -not -path '*/test/*' \
    -print0 \
    | xargs -0 grep -nE \
        '^[[:space:]]*\|[[:space:]]*_[[:space:]]*->[[:space:]]*(false|None|\(\))[[:space:]]*$' \
        2>/dev/null \
    | awk -F: '
        {
          # match[0] is "file:line:content"; extract literal RHS.
          file = $1
          line = $2
          # rejoin remainder as content (in case ":" appears in content).
          content = $0
          sub(/^[^:]*:[^:]*:/, "", content)
          # Strip leading whitespace and "| _ -> ".
          sub(/^[[:space:]]*\|[[:space:]]*_[[:space:]]*->[[:space:]]*/, "", content)
          # Strip trailing whitespace.
          sub(/[[:space:]]*$/, "", content)
          printf "%s,%s,%s,unclassified\n", file, line, content
        }' \
    | sort -t, -k1,1 -k2,2n
} > "$tmp"

mv "$tmp" "$OUTPUT"
trap - EXIT

rows=$(( $(wc -l < "$OUTPUT") - 1 ))
echo "Regenerated $OUTPUT: $rows data rows." >&2
