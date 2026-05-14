#!/usr/bin/env bash
# CI gate: String-based dispatch vs type-safe variant enforcement (STR).
# Meta-issue: #9521
#
# Anti-patterns:
#   1. String comparison chains where a variant type already exists
#   2. String.lowercase_ascii + string equality for category dispatch
#   3. json_string_opt on known enum fields without validation
#
# CONTRACT: Prefer OCaml variant types for internal dispatch. String matching
# is acceptable only at system boundaries (CLI args, JSON parsing, external APIs).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

base_ref="origin/main"
head_ref="HEAD"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      if [ "$#" -lt 2 ]; then
        echo "usage: $0 [--base REF] [--head REF]" >&2
        exit 2
      fi
      base_ref="$2"
      shift 2
      ;;
    --head)
      if [ "$#" -lt 2 ]; then
        echo "usage: $0 [--base REF] [--head REF]" >&2
        exit 2
      fi
      head_ref="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--base REF] [--head REF]" >&2
      exit 2
      ;;
  esac
done

exit_code=0

print_first_lines() {
  local limit="$1"
  awk -v limit="$limit" 'NR <= limit { print }'
}

is_enum_string_pattern() {
  local text="$1"
  if rg -q 'String\.lowercase_ascii.*=\s*"' <<< "$text"; then
    return 0
  fi
  if rg -q 'json_string_opt\s+"(status|state|kind|type|action|mode|profile)"' <<< "$text"; then
    return 0
  fi
  if rg -q 'List\.mem.*\[.*"' <<< "$text"; then
    return 0
  fi
  return 1
}

has_str_ok_comment() {
  local path="$1"
  local line_no="$2"
  local start=$((line_no > 2 ? line_no - 2 : 1))
  local end=$((line_no + 2))
  [ -f "$path" ] || return 1
  sed -n "${start},${end}p" "$path" \
    | rg -q 'STR-OK|STRING-BOUNDARY-OK|enum-string-safety: allow'
}

scan_new_enum_string_dispatch() {
  local failures=()
  local current_path=""
  local new_line_no=0
  local raw=""
  local source_label=""
  local text=""

  scan_diff_stream() {
    source_label="$1"
    current_path=""
    new_line_no=0
    while IFS= read -r raw; do
      case "$raw" in
        "diff --git "*)
          current_path=""
          new_line_no=0
          ;;
        "+++ b/"*)
          current_path="${raw#+++ b/}"
          new_line_no=0
          ;;
        "@@ "*)
          if [[ "$raw" =~ \+([0-9]+)(,([0-9]+))? ]]; then
            new_line_no="${BASH_REMATCH[1]}"
          else
            new_line_no=0
          fi
          ;;
        +*)
          if [[ "$raw" != "+++"* && "$current_path" == lib/*.ml && "$new_line_no" -gt 0 ]]; then
            text="${raw:1}"
            if is_enum_string_pattern "$text" \
               && ! has_str_ok_comment "$current_path" "$new_line_no"; then
              failures+=("${source_label}: ${current_path}:${new_line_no}: ${text}")
            fi
            new_line_no=$((new_line_no + 1))
          fi
          ;;
        -*)
          ;;
        *)
          if [ "$new_line_no" -gt 0 ]; then
            new_line_no=$((new_line_no + 1))
          fi
          ;;
      esac
    done
  }

  scan_diff_stream "${base_ref}...${head_ref}" \
    < <(git diff --unified=0 "${base_ref}...${head_ref}" -- lib/ || true)
  scan_diff_stream "staged" \
    < <(git diff --cached --unified=0 -- lib/ || true)
  scan_diff_stream "worktree" \
    < <(git diff --unified=0 -- lib/ || true)

  if [ "${#failures[@]}" -gt 0 ]; then
    echo "FAIL: new enum-like string dispatch added:"
    printf '%s\n' "${failures[@]}" | print_first_lines 40
    echo
    echo "Use a typed parser/variant, or add a nearby STR-OK comment for a real boundary parser."
    return 1
  fi

  echo "PASS: no new enum-like string dispatch added in ${base_ref}...${head_ref}, staged diff, or worktree diff"
}

# Diff ratchet: existing debt remains warning-only, but new STR sites fail.
echo "=== Scan: new enum-like string dispatch ratchet ==="
if ! scan_new_enum_string_dispatch; then
  exit_code=1
fi

# 1. Flag String.lowercase_ascii + equality chains in non-parsing code
#    Heuristic: three or more consecutive string comparisons on the same variable
echo "=== Scan: repeated string equality dispatch ==="
matches=$(rg -n 'String\.lowercase_ascii.*=\s*"' lib/ --type ml -g '!test/' || true)
if [ -n "$matches" ]; then
  echo "WARN: String.lowercase_ascii + literal comparison found (consider variant):"
  print_first_lines 20 <<< "$matches"
fi

# 2. json_string_opt on fields that should be enum-constrained
#    This is a heuristic: we flag raw json_string_opt where a typed parser exists.
echo "=== Scan: raw json_string_opt on potentially enum fields ==="
matches=$(
  rg -n 'json_string_opt\s+"(status|state|kind|type|action|mode|profile)"' \
    lib/ --type ml -g '!test/' || true
)
if [ -n "$matches" ]; then
  echo "WARN: json_string_opt on enum-like field (consider strict enum parser):"
  print_first_lines 20 <<< "$matches"
fi

# 3. List.mem + string literals for category dispatch
echo "=== Scan: List.mem string literal dispatch ==="
matches=$(rg -n 'List\.mem.*\[.*"' lib/ --type ml -g '!test/' || true)
if [ -n "$matches" ]; then
  echo "WARN: List.mem with string literals (consider variant + List.mem on variant):"
  print_first_lines 20 <<< "$matches"
fi

if [ "$exit_code" -eq 0 ]; then
  echo "=== STR gate: PASS ==="
else
  echo "=== STR gate: FAIL ==="
fi

exit "$exit_code"
