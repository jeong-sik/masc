#!/usr/bin/env bash
# analyze-keeper-bash-failures.sh
#
# Reproducible census for the keeper Bash quality loop. Reads
# <base-path>/.masc/tool_calls and buckets Bash failures by the same leak
# classes used in the 240h runtime triage.
#
# Usage:
#   scripts/analyze-keeper-bash-failures.sh [base_path] [window_hours]
#
# Examples:
#   scripts/analyze-keeper-bash-failures.sh /Users/dancer/me 240
#   MASC_BASE_PATH=/Users/dancer/me scripts/analyze-keeper-bash-failures.sh

set -euo pipefail

BASE_PATH="${1:-${MASC_BASE_PATH:-$(pwd)}}"
WINDOW_HOURS="${2:-240}"
TOOL_CALLS_DIR="${BASE_PATH}/.masc/tool_calls"

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
def failed: (.success == false or .semantic_success == false);
def inferred_shape:
  if (combined | test("gh pr checks"; "i")) then "gh_pr_checks"
  elif (combined | test("&&|\\|\\||;|\\n|\\r"; "i")) then "chaining"
  elif (combined | test("2>/dev/null|2> /dev/null|2>>/dev/null|2>&1|\\| head|\\| grep|\\| sed|\\| python|>|<"; "i")) then "pipe_or_redirect"
  else "unknown" end;
def category:
  if (output_text | test("\"shape_block\""; "i")) then
    ((try (output_text | fromjson | .shape_block) catch null) // "unknown") as $shape
    | if ($shape|tostring) == "unknown" then "shape_block:" + inferred_shape else "shape_block:" + ($shape|tostring) end
  elif (combined | test("Path syntax blocked|shell quoting, globbing, brace expansion|Glob expansion|Brace expansion"; "i")) then "path_syntax_blocked"
  elif (combined | test("pipe_or_redirect|keeper_bash accepts one direct command|2>/dev/null|2> /dev/null|2>>/dev/null|2>&1|\\| head|\\| grep|\\| sed|\\| python|&&|\\|\\|"; "i")) then "shape_block:pipe_or_redirect"
  elif (combined | test("is a MASC tool, not a shell command|tool_invoked_as_shell_command"; "i")) then "wrong_tool_channel"
  elif (combined | test("keeper_bash cannot bypass the PR creation approval|gh_pr_create_requires_keeper_pr_create"; "i")) then "pr_create_policy_bypass"
  elif (combined | test("tool_approval_required|destructive|blocked for all presets|operator_required|risk threshold"; "i")) then "approval_or_destructive_block"
  elif (combined | test("sandbox root cannot run git/gh|multiple sandbox repos|Set cwd explicitly"; "i")) then "cwd_required_multi_repo"
  elif (combined | test("No such file or directory|cannot access|cannot change to|cwd_not_directory|not a git repository|outside allowed directories|Path blocked"; "i")) then "missing_path_or_wrong_cwd"
  elif (combined | test("sandbox_image_missing|Unable to find image.*masc-keeper-sandbox|pull access denied for masc-keeper-sandbox"; "i")) then "docker_image_missing"
  elif (combined | test("timeout|timed out"; "i")) then "timeout"
  elif (combined | test("streak_gate|called [0-9]+ times consecutively|failed 3 times in a row"; "i")) then "repeat_or_streak_gate"
  elif (combined | test("regex parse error|usage_error|ambiguous argument|unknown revision|Wrong arguments or flags|command not found"; "i")) then "command_usage_or_regex_error"
  elif (combined | test("tool call failed|general_error|exit_code.*1|semantic_status\":\"runtime_error"; "i")) then "command_exit_nonzero"
  else "other" end;
fromjson? | select(type == "object") | select((.ts // 0) >= $cutoff) | select(.tool == "Bash")
'

echo "=== Keeper Bash Failure Census ==="
echo "base_path=${BASE_PATH}"
echo "window_hours=${WINDOW_HOURS}"
echo "cutoff_unix=${CUTOFF}"
echo "files=${#FILES[@]}"
echo

jq -Rr --argjson cutoff "$CUTOFF" "$JQ_FILTER | [.success, .semantic_success] | @tsv" "${FILES[@]}" |
awk '
  BEGIN { total=0; fail=0; ok=0 }
  { total++; if ($1 == "false" || $2 == "false") fail++; else ok++ }
  END {
    pct = total > 0 ? fail * 100.0 / total : 0
    printf "total\t%d\nfailed_or_semantic_failed\t%d\nok\t%d\nfailure_pct\t%.2f\n\n", total, fail, ok, pct
  }
'

echo "[failure categories]"
jq -Rr --argjson cutoff "$CUTOFF" "$JQ_FILTER | select(failed) | category" "${FILES[@]}" |
sort | uniq -c | sort -nr
echo

echo "[top failed commands]"
jq -Rr --argjson cutoff "$CUTOFF" "$JQ_FILTER | select(failed) | [category, cmd] | @tsv" "${FILES[@]}" |
sort | uniq -c | sort -nr | awk 'NR <= 40 { print }'
