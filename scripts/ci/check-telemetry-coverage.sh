#!/usr/bin/env bash
# CI gate: 100% telemetry intent coverage + missing metric detection (TEL).
# Meta-issue: #9520
#
# CONTRACT: Every significant action (spawn, keeper turn, tool call, approval
# decision, failure) must emit at least one telemetry event. Missing metrics
# should be flagged, not silently absent.

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

file_has_telemetry_reference() {
  local path="$1"
  [ -f "$path" ] || return 1
  rg -q 'Metrics_store_eio|Log\.[A-Za-z_]+|telemetry|Prometheus\.|metric_' "$path"
}

is_action_handler_line() {
  local text="$1"
  rg -q 'let.*handle_|let.*spawn|let.*dispatch' <<< "$text"
}

has_tel_ok_comment() {
  local path="$1"
  local line_no="$2"
  local start=$((line_no > 2 ? line_no - 2 : 1))
  local end=$((line_no + 2))
  [ -f "$path" ] || return 1
  sed -n "${start},${end}p" "$path" \
    | rg -q 'TEL-OK|telemetry-coverage: allow'
}

scan_new_action_handlers_without_telemetry() {
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
          if [[ "$raw" != "+++"* && ( "$current_path" == lib/*.ml || "$current_path" == bin/*.ml ) && "$new_line_no" -gt 0 ]]; then
            text="${raw:1}"
            if is_action_handler_line "$text" \
               && ! file_has_telemetry_reference "$current_path" \
               && ! has_tel_ok_comment "$current_path" "$new_line_no"; then
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
    < <(git diff --unified=0 "${base_ref}...${head_ref}" -- lib/ bin/ || true)
  scan_diff_stream "staged" \
    < <(git diff --cached --unified=0 -- lib/ bin/ || true)
  scan_diff_stream "worktree" \
    < <(git diff --unified=0 -- lib/ bin/ || true)

  if [ "${#failures[@]}" -gt 0 ]; then
    echo "FAIL: new significant action handler has no visible telemetry in its file:"
    printf '%s\n' "${failures[@]}" | print_first_lines 40
    echo
    echo "Add Metrics_store_eio/Log/Prometheus telemetry, or add a nearby TEL-OK comment with rationale."
    return 1
  fi

  echo "PASS: no new telemetry-uncovered action handlers in ${base_ref}...${head_ref}, staged diff, or worktree diff"
}

# Diff ratchet: existing coverage debt remains warning-only, but new action
# handlers in files with no visible telemetry reference fail.
echo "=== Scan: new action handler telemetry ratchet ==="
if ! scan_new_action_handlers_without_telemetry; then
  exit_code=1
fi

# 1. List functions that perform significant actions but have no Metrics_store_eio.record
#    or Log.* telemetry call within the same function body.
echo "=== Scan: significant actions without telemetry ==="
# Heuristic: keeper turn functions, spawn wrappers, tool dispatch
action_files=$(
  rg -l 'let.*handle_\|let.*spawn\|let.*dispatch' lib/keeper/ lib/ --type ml 2>/dev/null || true
)
for f in $action_files; do
  if rg -q 'Metrics_store_eio\.record\|Log\.[A-Za-z_]+\.|Eio\.traceln' "$f"; then
    : # ok
  else
    echo "WARN: $f contains action handlers but no visible telemetry call"
  fi
done

# 2. Check that telemetry field names in OCaml match JSON schema keys
#    (prevents metric ingestion drop due to key mismatch).
echo "=== Scan: telemetry key consistency ==="
# Extract json field names used in telemetry-related files
telemetry_json_keys=$(
  rg 'json_string_opt\s+"([^"]+)"' lib/telemetry_*.ml lib/metrics_*.ml --type ml -o -r '$1' 2>/dev/null | sort -u || true
)
if [ -n "$telemetry_json_keys" ]; then
  echo "INFO: telemetry JSON keys found: $(echo "$telemetry_json_keys" | wc -l | xargs)"
fi

# 3. Warn if new source files are added without any telemetry import
new_ml_files=$(git diff --name-only "${base_ref}...${head_ref}" -- lib/ bin/ 2>/dev/null | grep '\.ml$' || true)
for f in $new_ml_files; do
  if [ -f "$f" ] && ! file_has_telemetry_reference "$f"; then
    echo "WARN: new file $f has no telemetry reference (consider adding observability)"
  fi
done

if [ "$exit_code" -eq 0 ]; then
  echo "=== TEL gate: PASS ==="
else
  echo "=== TEL gate: FAIL ==="
fi

exit "$exit_code"
