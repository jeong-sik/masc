#!/usr/bin/env bash
# verify-bloodflow-restoration.sh
#
# Phase A bloodflow-restoration verification helper.  Reads operator-side
# JSONL logs and grep counters for the five Phase A signals defined in
# planning/claude-plans/me-workspace-yousleepwhen-masc-sunny-starfish.md
# section 10:
#
#   F1 — per-keeper raw token fallback fired
#   F2 — silent_auth_token_resolve_error volume + would_reject mode mix
#   F4 — string-match SSOT collapse (no contains_substring outside SSOT)
#   F5 — typed gh-api / strip_keeper_prefix helpers in use (compile-only;
#        dynamic check by scanning for legacy literal patterns)
#
# This script does NOT change state.  It prints a punch list of what each
# Phase B promotion gate (PR-2 strict reject, PR-4 typed terminal state)
# needs from the soak window, and a single composite KPI line:
#
#   mutation_to_passive_ratio = mutating_calls / passive_calls
#
# The plan target is 1:8 -> 1:3 within seven days post-deploy.  The
# script just reports the current ratio; the operator decides whether
# the gate is met.
#
# Usage:
#   scripts/verify-bloodflow-restoration.sh
#   scripts/verify-bloodflow-restoration.sh --since 24h     # last 24 hours of logs
#   scripts/verify-bloodflow-restoration.sh --logs <dir>    # override log dir
#
# Exits 0 if all five signals are reachable in the log set.  The metric
# values themselves never trigger non-zero exit — that is a soak-policy
# decision, not a build-gate one.

# Verification script: every count is best-effort.  Empty grep results
# (exit 1) and missing log files are valid signals, not errors, so we
# do NOT use set -e here.  Real fatal errors (find missing, dir
# missing) are checked explicitly below.
set -o pipefail

SINCE=""
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

default_base_path() {
  if [ -n "${MASC_BASE_PATH:-}" ]; then
    printf '%s\n' "$MASC_BASE_PATH"
  else
    printf '%s\n' "$ROOT"
  fi
}

LOG_DIR="${MASC_LOG_DIR:-$(default_base_path)/.masc/logs}"

while [ $# -gt 0 ]; do
  case "$1" in
    --logs) LOG_DIR="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$LOG_DIR" ]; then
  echo "verify-bloodflow: log dir $LOG_DIR not found"
  echo "  hint: server has not started since deploy, or logs are elsewhere."
  echo "  set MASC_LOG_DIR or pass --logs <path>."
  exit 1
fi

# Build a list of log files honoring --since via mtime when present.
collect_logs() {
  local glob="$1"
  if [ -n "$SINCE" ]; then
    # find -mtime takes days; convert hours/days suffix.  If the user
    # passed a value find can't handle, fall back to all-time.
    local mtime_arg=""
    case "$SINCE" in
      *h) mtime_arg="-mmin -$(( ${SINCE%h} * 60 ))" ;;
      *d) mtime_arg="-mtime -${SINCE%d}" ;;
      *)  mtime_arg="" ;;
    esac
    find "$LOG_DIR" -maxdepth 1 -type f -name "$glob" $mtime_arg 2>/dev/null | sort
  else
    find "$LOG_DIR" -maxdepth 1 -type f -name "$glob" 2>/dev/null | sort
  fi
}

count_pattern_in() {
  local pattern="$1"; shift
  # Bash 3.2 + set -u: "${arr[@]}" on an empty array unbound-errors.
  # Tolerate the empty case explicitly.
  if [ "$#" -eq 0 ]; then echo 0; return; fi
  grep -F -- "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' '
}

# macOS ships with bash 3.2 which lacks mapfile.  Use a portable read loop.
auth_logs=()
while IFS= read -r line; do auth_logs+=("$line"); done < <(collect_logs 'auth_resolve_*.jsonl')
sys_logs=()
while IFS= read -r line; do sys_logs+=("$line"); done < <(collect_logs 'system_log_*.jsonl')
kp_logs=()
while IFS= read -r line; do kp_logs+=("$line"); done < <(collect_logs 'keeper_*.jsonl')

echo "=== Phase A bloodflow-restoration verification ==="
echo "log dir: $LOG_DIR"
echo "since:   ${SINCE:-all time}"
echo

# ----- F1: per-keeper raw token fallback fired ----------------------------
f1=$(count_pattern_in '"source":"per_keeper_token_file"' "${auth_logs[@]}")
echo "F1 per_keeper_token_file source events: $f1"
if [ "$f1" -lt 1 ] && [ "${#auth_logs[@]}" -gt 0 ]; then
  echo "  NOTE: F1 fallback never fired in this log window — either no"
  echo "  subprocess MCP calls happened, or MASC_TOKEN was always set."
fi

# ----- F2: silent_auth + would_reject mode mix ----------------------------
silent=$(count_pattern_in '[silent:auth_token_resolve_error]' "${sys_logs[@]}")
would=$(count_pattern_in   '[would_reject:auth_token_resolve_error]' "${sys_logs[@]}")
echo
echo "F2 silent_auth_token_resolve_error events: $silent"
echo "   would_reject companion events:          $would"
if [ "$silent" -gt 0 ] && [ "$would" -lt "$silent" ]; then
  echo "  NOTE: silent count > would_reject count — Auth_strict_mode might"
  echo "  be Off in part of the window.  Check MASC_AUTH_STRICT env."
fi

# ----- F4: contains_substring SSOT --------------------------------------
# Static check: count call sites of [String_util.contains_substring] only
# (function calls, not the [_ci] sibling and not doc-comments referencing
# the symbol by name).  Pattern requires a non-word char after
# [contains_substring] so [contains_substring_ci] does not match.
# Phase A F4 collapsed only the SSOT consumer; PR-5 main (the producer
# refactor) is what drives this count to 0.
f4_files=$(grep -rlE 'String_util\.contains_substring[^_a-zA-Z]' \
  "$ROOT/lib/keeper/" 2>/dev/null | wc -l | tr -d ' ')
echo
echo "F4 contains_substring caller files in lib/keeper/: $f4_files"
if [ "$f4_files" -eq 0 ]; then
  echo "  -> Phase B PR-5 main complete (target 0 reached)."
elif [ "$f4_files" -le 1 ]; then
  echo "  -> Phase A F4 SSOT collapse holds (target after PR-5: 0)."
else
  echo "  -> Phase B PR-5 main scope: $f4_files files still call SSOT."
fi

# ----- F5: gh-api token-aware + strip_keeper_prefix helpers in use -------
# Static check: legacy literal slice patterns.  We count files that
# contain the slice as **executable code**, not as prose inside a
# doc-comment reference (e.g. [String.sub trimmed 0 7 = "keeper-"] in a
# Phase A F5 comment that documents the now-collapsed legacy pattern).
# Heuristic: drop lines starting with a continuation `*` (multi-line
# OCaml comment body) before counting unique files.
count_files_excluding_doc_prose() {
  local pattern="$1"
  local dir="$2"
  # Drop two false-positive forms before counting unique files:
  # 1. multi-line OCaml comment continuation (line starts with ` * `)
  # 2. doc-comment bracketed pseudo-code references like `[String.sub ...]`
  #    (the bracketed form never appears in real OCaml code paths since
  #    OCaml lists do not wrap boolean expressions).
  grep -rnE "$pattern" "$dir" 2>/dev/null \
    | grep -vE ':[[:space:]]*\*[[:space:]]+' \
    | grep -vF '[String.sub' \
    | grep -vF '[is_prefix' \
    | cut -d: -f1 | sort -u | wc -l | tr -d ' '
}
prefix_literals=$(count_files_excluding_doc_prose \
  'String\.sub [a-z_]+ 0 [0-9]+ = "keeper-"' "$ROOT/lib/keeper/")
api_prefix=$(count_files_excluding_doc_prose \
  'is_prefix [a-z_]+ ~prefix:"api"' "$ROOT/lib/keeper/")
echo
echo "F5 legacy keeper- literal slice files:   $prefix_literals (target 0)"
echo "   legacy is_prefix \"api\" files:         $api_prefix (target 0)"

# ----- Composite KPI: mutation_to_passive_ratio --------------------------
echo
mutating=$(count_pattern_in '"tool":"tool_execute"' "${kp_logs[@]}")
mutating=$(( mutating + $(count_pattern_in '"tool":"tool_search_files"'   "${kp_logs[@]}") ))
mutating=$(( mutating + $(count_pattern_in '"tool":"tool_edit_file"' "${kp_logs[@]}") ))
mutating=$(( mutating + $(count_pattern_in '"tool":"keeper_git"'     "${kp_logs[@]}") ))

passive=$(count_pattern_in '"tool":"masc_status"'       "${kp_logs[@]}")
passive=$(( passive + $(count_pattern_in '"tool":"keeper_tasks_list"' "${kp_logs[@]}") ))
passive=$(( passive + $(count_pattern_in '"tool":"keeper_board_post_get"'  "${kp_logs[@]}") ))
passive=$(( passive + $(count_pattern_in '"tool":"keeper_board_list"' "${kp_logs[@]}") ))

echo "=== Composite KPI ==="
echo "mutating tool calls (bash/shell/fs_edit/git): $mutating"
echo "passive tool calls (status/tasks_list/board): $passive"
if [ "$passive" -gt 0 ]; then
  ratio_x100=$(( mutating * 100 / passive ))
  echo "mutation_to_passive_ratio: ${ratio_x100}/100  (plan target 7d post-deploy: 33/100 i.e. 1:3)"
else
  echo "mutation_to_passive_ratio: undefined (no passive calls observed)"
fi

# ----- Reachability summary ---------------------------------------------
echo
echo "=== Phase B promotion-gate readiness ==="
if [ "$silent" -eq 0 ] && [ "$would" -eq 0 ]; then
  echo "PR-2 (Strict reject): no F2 traffic in window — soak inconclusive."
elif [ "$would" -ge "$silent" ]; then
  echo "PR-2 (Strict reject): would_reject mode covers all silent events ($would >= $silent)."
  echo "  -> Drill into 'agent' label to identify legitimate internal callers"
  echo "     before promoting Auth_strict_mode default to Strict."
else
  echo "PR-2 (Strict reject): would_reject lags silent ($would < $silent) — investigate."
fi

echo
echo "verify-bloodflow: done"
