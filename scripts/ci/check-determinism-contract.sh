#!/usr/bin/env bash
# CI gate: Deterministic / Non-deterministic boundary contract enforcement (DET/NDT).
# Meta-issue: #9522
#
# CONTRACT:
#   - Deterministic logic must not depend on non-deterministic outputs for
#     branching decisions (e.g., do not branch on wall-clock, random, or
#     unordered collection iteration).
#   - Non-deterministic inputs must be wrapped in explicit `NonDet` or
#     `Random` or `Clock` types at the boundary.
#   - Sound partial parsing: return `Some` only when certain, `None` otherwise.
#     Never guess a default from an unknown input.

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

is_det_ndt_pattern() {
  local text="$1"
  if rg -q 'Unix\.gettimeofday|Random\.|Unix\.times|Sys\.time|Unix\.getpid' <<< "$text"; then
    return 0
  fi
  if rg -q 'Option\.value.*~default:' <<< "$text"; then
    return 0
  fi
  if rg -q '\|\s*_\s*->\s*Some' <<< "$text"; then
    return 0
  fi
  return 1
}

has_det_ndt_ok_comment() {
  local path="$1"
  local line_no="$2"
  local start=$((line_no > 2 ? line_no - 2 : 1))
  local end=$((line_no + 2))
  [ -f "$path" ] || return 1
  sed -n "${start},${end}p" "$path" \
    | rg -q 'DET-OK|NDT-OK|determinism-contract: allow|sound-partial: allow'
}

scan_new_det_ndt_debt() {
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
            if is_det_ndt_pattern "$text" \
               && ! has_det_ndt_ok_comment "$current_path" "$new_line_no"; then
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
    echo "FAIL: new deterministic-boundary debt added:"
    printf '%s\n' "${failures[@]}" | print_first_lines 40
    echo
    echo "Wrap non-determinism at the boundary, keep parsing sound-partial, or add a nearby DET-OK/NDT-OK comment with rationale."
    return 1
  fi

  echo "PASS: no new deterministic-boundary debt added in ${base_ref}...${head_ref}, staged diff, or worktree diff"
}

# Diff ratchet: existing DET/NDT debt remains warning-only, but new sites fail.
echo "=== Scan: new deterministic-boundary ratchet ==="
if ! scan_new_det_ndt_debt; then
  exit_code=1
fi

# 1. Deterministic code branching on non-deterministic values
echo "=== Scan: deterministic branch on non-deterministic source ==="
nd_patterns=$(
  rg -n 'Unix\.gettimeofday\|Random\.|Unix\.times\|Sys\.time\|Unix\.getpid' lib/ --type ml -g '!test/' || true
)
if [ -n "$nd_patterns" ]; then
  echo "WARN: Non-deterministic source used in lib/ (ensure wrapped at boundary):"
  print_first_lines 20 <<< "$nd_patterns"
fi

# 2. Sound partial check: Option.value ~default on parsed external input
#    This catches the anti-pattern of assigning a default when parsing fails.
echo "=== Scan: permissive default on unknown input ==="
permissive=$(
  rg -B1 -n 'Option\.value.*~default:' lib/keeper/ lib/mcp_server_*.ml --type ml -g '!test/' || true
)
if [ -n "$permissive" ]; then
  echo "WARN: Option.value with default on potentially unknown input (sound partial?):"
  print_first_lines 20 <<< "$permissive"
fi

# 3. Unknown -> catch-all default in match (the "permissive default" anti-pattern)
echo "=== Scan: catch-all permissive default ==="
catch_all=$(
  rg -A1 -n '\|\s*_\s*->\s*Some' lib/ --type ml -g '!test/' || true
)
if [ -n "$catch_all" ]; then
  echo "WARN: catch-all branch returning Some (possible unsound default):"
  print_first_lines 20 <<< "$catch_all"
fi

# 4. Hashtbl.iter / Map.iter used where order matters for deterministic replay
echo "=== Scan: unordered iteration in deterministic context ==="
unordered=$(
  rg -n 'Hashtbl\.iter\|Hashtbl\.fold\|Map\. iter\|Map\. fold' lib/ --type ml -g '!test/' || true
)
if [ -n "$unordered" ]; then
  echo "INFO: unordered collection iteration (verify order does not affect output):"
  print_first_lines 10 <<< "$unordered"
fi

if [ "$exit_code" -eq 0 ]; then
  echo "=== DET/NDT gate: PASS ==="
else
  echo "=== DET/NDT gate: FAIL ==="
fi

exit "$exit_code"
