#!/usr/bin/env bash
# analyze-keeper-execute-failures.sh
#
# Reproducible census for the keeper Execute quality loop. Reads
# <base-path>/.masc/tool_calls and buckets Execute failures by the same leak
# classes used in the 240h runtime triage. It also prints a compact summary
# for the adjacent descriptor-backed file/edit surfaces that share the same
# failure budget.
#
# Usage:
#   scripts/analyze-keeper-execute-failures.sh [base_path] [window_hours]
#
# Examples:
#   scripts/analyze-keeper-execute-failures.sh /Users/dancer/me 240
#   MASC_BASE_PATH=/Users/dancer/me scripts/analyze-keeper-execute-failures.sh

set -euo pipefail

BASE_PATH="${1:-${MASC_BASE_PATH:-$(pwd)}}"
WINDOW_HOURS="${2:-240}"
TOOL_CALLS_DIR="${BASE_PATH}/.masc/tool_calls"
EXECUTE_COUNTERS_URL="${MASC_EXECUTE_COUNTERS_URL:-${MASC_LEGENDARY_BASH_COUNTERS_URL:-}}"
if [ -z "$EXECUTE_COUNTERS_URL" ]; then
  if [ -n "${MASC_HTTP_BASE_URL:-}" ]; then
    EXECUTE_COUNTERS_URL="${MASC_HTTP_BASE_URL%/}/api/v1/legendary_bash/counters"
  else
    MASC_COUNTER_HOST="${MASC_HOST:-127.0.0.1}"
    MASC_COUNTER_PORT="${MASC_HTTP_PORT:-${MASC_PORT:-8935}}"
    EXECUTE_COUNTERS_URL="http://${MASC_COUNTER_HOST}:${MASC_COUNTER_PORT}/api/v1/legendary_bash/counters"
  fi
fi
EXECUTE_COUNTERS_TIMEOUT_SEC="${MASC_EXECUTE_COUNTERS_TIMEOUT_SEC:-${MASC_LEGENDARY_BASH_COUNTERS_TIMEOUT_SEC:-2}}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 required" >&2
  exit 1
fi

if [ ! -d "$TOOL_CALLS_DIR" ]; then
  echo "no tool call data at ${TOOL_CALLS_DIR}" >&2
  exit 0
fi

CUTOFF="$(
  python3 - "$WINDOW_HOURS" <<'PY'
import sys
import time

hours = float(sys.argv[1])
print(time.time() - hours * 3600.0)
PY
)"

FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(find "$TOOL_CALLS_DIR" -type f -name '*.jsonl' -mtime "-$((WINDOW_HOURS / 24 + 2))" | sort)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "no recent tool call files under ${TOOL_CALLS_DIR}" >&2
  exit 0
fi

JQ_FILTER='
def cmd:
  if (.input|type) == "object" then (.input.command // .input.cmd // "")
  elif (.input|type) == "string" then .input
  else "" end;
def output_text:
  if (.output|type) == "string" then .output
  elif (.output|type) == "object" and (.output._blob.preview? != null) then .output._blob.preview
  else (.output|tostring) end;
def combined: output_text + " " + (.action_radius.error // "") + " " + cmd;
def failed: (.success == false);
def inferred_shape:
  if (cmd | test("gh pr checks"; "i")) then "repo_cli_pr_checks"
  elif (cmd | test("&&|\\|\\||;|\\n|\\r"; "i")) then "chaining"
  elif (cmd | test("2>/dev/null|2> /dev/null|2>>/dev/null|2>&1|\\| head|\\| grep|\\| sed|\\| python|>|<"; "i")) then "pipe_or_redirect"
  else "unknown" end;
def category:
  if (output_text | test("\"shape_block\""; "i")) then
    ((try (output_text | fromjson | .shape_block) catch null) // "unknown") as $shape
    | if ($shape|tostring) == "unknown" then "shape_block:" + inferred_shape else "shape_block:" + ($shape|tostring) end
  elif (combined | test("old_string and new_string are identical"; "i")) then "edit_identical_noop_candidate"
  elif (combined | test("old_string not found"; "i")) then "edit_old_string_not_found"
  elif (combined | test("old_string found [0-9]+ times|Use replace_all=true"; "i")) then "edit_ambiguous_match"
  elif (combined | test("path_outside_sandbox|Write restricted to allowed sandboxes|Cross-agent playground"; "i")) then "path_outside_sandbox"
  elif (combined | test("is a MASC tool, not a shell command|tool_invoked_as_shell_command|repo CLI is NOT available in the keeper sandbox"; "i")) then "wrong_tool_channel"
  elif (combined | test("command.*not.*allowed|not allowlisted|not in allowlist|not permitted by.*allowlist"; "i")) then "command_not_allowed"
  elif (combined | test("pipe_or_redirect|Execute accepts one direct command|tool_execute accepts one direct command|tool_execute_command_shape_blocked|2>/dev/null|2> /dev/null|2>>/dev/null|2>&1|\\| head|\\| grep|\\| sed|\\| python|&&|\\|\\|"; "i")) then "shape_block:pipe_or_redirect"
  elif (combined | test("tool_approval_required|destructive|operator_required|risk threshold"; "i")) then "approval_or_destructive_block"
  elif (combined | test("sandbox root cannot run repo CLI|multiple sandbox repos|Set cwd explicitly"; "i")) then "cwd_required_multi_repo"
  elif (combined | test("No such file or directory|cannot access|cannot change to|cwd_not_directory|not a git repository|outside allowed directories|Path blocked"; "i")) then "missing_path_or_wrong_cwd"
  elif (combined | test("image_not_found|Unable to find image.*masc-keeper-sandbox|pull access denied for masc-keeper-sandbox"; "i")) then "docker_image_not_found"
  elif (combined | test("timeout|timed out"; "i")) then "timeout"
  elif (combined | test("streak_gate|called [0-9]+ times consecutively|failed 3 times in a row"; "i")) then "repeat_or_streak_gate"
  elif (combined | test("regex parse error|usage_error|ambiguous argument|unknown revision|Wrong arguments or flags|command not found"; "i")) then "command_usage_or_regex_error"
  elif (combined | test("tool call failed|general_error|exit_code.*1"; "i")) then "command_exit_nonzero"
  else "other" end;
fromjson? | select(type == "object") | select((.ts // 0) >= $cutoff)
| select(.tool == "Execute" or .tool == "tool_execute")
'

SURFACE_FILTER='
def cmd:
  if (.input|type) == "object" then (.input.command // .input.cmd // "")
  elif (.input|type) == "string" then .input
  else "" end;
def output_text:
  if (.output|type) == "string" then .output
  elif (.output|type) == "object" and (.output._blob.preview? != null) then .output._blob.preview
  else (.output|tostring) end;
def combined: output_text + " " + (.action_radius.error // "") + " " + cmd;
def failed: (.success == false);
def inferred_shape:
  if (cmd | test("gh pr checks"; "i")) then "repo_cli_pr_checks"
  elif (cmd | test("&&|\\|\\||;|\\n|\\r"; "i")) then "chaining"
  elif (cmd | test("2>/dev/null|2> /dev/null|2>>/dev/null|2>&1|\\| head|\\| grep|\\| sed|\\| python|>|<"; "i")) then "pipe_or_redirect"
  else "unknown" end;
def category:
  if (output_text | test("\"shape_block\""; "i")) then
    ((try (output_text | fromjson | .shape_block) catch null) // "unknown") as $shape
    | if ($shape|tostring) == "unknown" then "shape_block:" + inferred_shape else "shape_block:" + ($shape|tostring) end
  elif (combined | test("old_string and new_string are identical"; "i")) then "edit_identical_noop_candidate"
  elif (combined | test("old_string not found"; "i")) then "edit_old_string_not_found"
  elif (combined | test("old_string found [0-9]+ times|Use replace_all=true"; "i")) then "edit_ambiguous_match"
  elif (combined | test("path_outside_sandbox|Write restricted to allowed sandboxes|Cross-agent playground"; "i")) then "path_outside_sandbox"
  elif (combined | test("is a MASC tool, not a shell command|tool_invoked_as_shell_command|repo CLI is NOT available in the keeper sandbox"; "i")) then "wrong_tool_channel"
  elif (combined | test("command.*not.*allowed|not allowlisted|not in allowlist|not permitted by.*allowlist"; "i")) then "command_not_allowed"
  elif (combined | test("pipe_or_redirect|Execute accepts one direct command|tool_execute accepts one direct command|tool_execute_command_shape_blocked|2>/dev/null|2> /dev/null|2>>/dev/null|2>&1|\\| head|\\| grep|\\| sed|\\| python|&&|\\|\\|"; "i")) then "shape_block:pipe_or_redirect"
  elif (combined | test("tool_approval_required|destructive|operator_required|risk threshold"; "i")) then "approval_or_destructive_block"
  elif (combined | test("sandbox root cannot run repo CLI|multiple sandbox repos|Set cwd explicitly"; "i")) then "cwd_required_multi_repo"
  elif (combined | test("No such file or directory|cannot access|cannot change to|cwd_not_directory|not a git repository|outside allowed directories|Path blocked"; "i")) then "missing_path_or_wrong_cwd"
  elif (combined | test("image_not_found|Unable to find image.*masc-keeper-sandbox|pull access denied for masc-keeper-sandbox"; "i")) then "docker_image_not_found"
  elif (combined | test("timeout|timed out"; "i")) then "timeout"
  elif (combined | test("streak_gate|called [0-9]+ times consecutively|failed 3 times in a row"; "i")) then "repeat_or_streak_gate"
  elif (combined | test("regex parse error|usage_error|ambiguous argument|unknown revision|Wrong arguments or flags|command not found"; "i")) then "command_usage_or_regex_error"
  elif (combined | test("tool call failed|general_error|exit_code.*1"; "i")) then "command_exit_nonzero"
  else "other" end;
fromjson? | select(type == "object") | select((.ts // 0) >= $cutoff)
| . as $row
| select(["Execute", "tool_execute", "tool_search_files", "tool_edit_file", "EditFile", "WriteFile"] | index($row.tool))
'

echo "=== Keeper Execute Failure Census ==="
echo "base_path=${BASE_PATH}"
echo "window_hours=${WINDOW_HOURS}"
echo "cutoff_unix=${CUTOFF}"
echo "files=${#FILES[@]}"
echo

jq -Rr --argjson cutoff "$CUTOFF" "$JQ_FILTER | [.success] | @tsv" "${FILES[@]}" |
awk '
  BEGIN { total=0; fail=0; ok=0 }
  { total++; if ($1 == "false") fail++; else ok++ }
  END {
    pct = total > 0 ? fail * 100.0 / total : 0
    printf "total\t%d\nfailed\t%d\nok\t%d\nfailure_pct\t%.2f\n\n", total, fail, ok, pct
  }
'

echo "[failure categories]"
jq -Rr --argjson cutoff "$CUTOFF" "$JQ_FILTER | select(failed) | category" "${FILES[@]}" |
sort | uniq -c | sort -nr
echo

echo "[top failed commands]"
jq -Rr --argjson cutoff "$CUTOFF" "$JQ_FILTER | select(failed) | [category, cmd] | @tsv" "${FILES[@]}" |
sort | uniq -c | sort -nr | awk 'NR <= 40 { print }'

echo
echo "[surface summary]"
jq -Rr --argjson cutoff "$CUTOFF" "$SURFACE_FILTER | [.tool, (if failed then \"failed\" else \"ok\" end)] | @tsv" "${FILES[@]}" |
awk '
  BEGIN {
    split("Execute tool_execute tool_search_files tool_edit_file EditFile WriteFile", order, " ")
    print "tool\tfailed\tok\tfailure_pct"
  }
  {
    total[$1]++
    if ($2 == "failed") fail[$1]++
    else ok[$1]++
  }
  END {
    for (i = 1; i <= length(order); i++) {
      tool = order[i]
      if (total[tool] > 0) {
        pct = fail[tool] * 100.0 / total[tool]
        printf "%s\t%d\t%d\t%.2f\n", tool, fail[tool] + 0, ok[tool] + 0, pct
      }
    }
  }
'

echo
echo "[surface failure categories]"
jq -Rr --argjson cutoff "$CUTOFF" "$SURFACE_FILTER | select(failed) | [.tool, category] | @tsv" "${FILES[@]}" |
sort | uniq -c | sort -nr | awk 'NR <= 80 { print }'

echo
echo "[top failed commands by surface]"
jq -Rr --argjson cutoff "$CUTOFF" "$SURFACE_FILTER | select(failed) | [.tool, category, cmd] | @tsv" "${FILES[@]}" |
sort | uniq -c | sort -nr | awk 'NR <= 80 { print }'

echo
echo "[live execute counters]"
if ! command -v curl >/dev/null 2>&1; then
  echo "unavailable	curl_missing"
else
  COUNTERS_JSON="$(
    curl -fsS --max-time "$EXECUTE_COUNTERS_TIMEOUT_SEC" \
      "$EXECUTE_COUNTERS_URL" 2>/dev/null || true
  )"
  if [ -z "$COUNTERS_JSON" ]; then
    echo "unavailable	${EXECUTE_COUNTERS_URL}"
  else
    echo "url	${EXECUTE_COUNTERS_URL}"
    echo "$COUNTERS_JSON" | jq -r '
      def n($key): (.[$key] // 0);
      "shell_gate_caller\tallow\treject\tcannot_parse",
      ("tool_search_files_bash\t"
       + (n("shell_gate_tool_search_files_bash_allow") | tostring) + "\t"
       + (n("shell_gate_tool_search_files_bash_reject") | tostring) + "\t"
       + (n("shell_gate_tool_search_files_bash_cannot_parse") | tostring))
    '
  fi
fi
