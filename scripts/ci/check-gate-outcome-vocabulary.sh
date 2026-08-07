#!/usr/bin/env bash
# The CI Gate aggregator must not call a cancelled job a failed one.
#
# `check()` in ci.yml folds every needs.<job>.result into PASS / FAIL. Only
# success and skipped pass, so cancelled printed as "FAIL <job> cancelled".
# Over the last 20 CI runs the job conclusions were 110 success, 45 cancelled
# and 4 failure — a reader met that line eleven times more often than a real
# failure, and it sends them looking for a defect in the diff. Cancellation
# means the check never ran; it still blocks, under its own word.
#
# This extracts check() straight out of ci.yml and drives it, so the assertion
# tracks the workflow rather than a copy of it.
#
# Usage: check-gate-outcome-vocabulary.sh [--fail|--self-test]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ci.yml"

MODE="${1:---fail}"
case "$MODE" in
  --fail | --self-test) ;;
  -h | --help)
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--self-test]" >&2
    exit 2
    ;;
esac

[ -f "$WORKFLOW" ] || {
  echo "[gate-outcome-vocabulary] missing $WORKFLOW" >&2
  exit 2
}

# Lift the function body out of the workflow's run: block and strip its indent.
extract_check() {
  awk '
    /^          check\(\) \{/ { grabbing = 1 }
    grabbing {
      line = $0
      sub(/^          /, "", line)
      print line
      if (line == "}") exit
    }
  ' "$1"
}

drive() {
  local body="$1" result="$2" mode="${3:-}"
  # shellcheck disable=SC2016
  bash -c "
    fail=0
    $body
    check probe '$result' $mode
    printf 'fail=%s\n' \"\$fail\"
  "
}

body="$(extract_check "$WORKFLOW")"
if [ -z "$body" ]; then
  echo "[gate-outcome-vocabulary] could not find check() in ci.yml — did the" >&2
  echo "aggregator move or change indentation? This check reads it verbatim." >&2
  exit 1
fi

problems=0
expect() {
  local label="$1" result="$2" want_word="$3" want_fail="$4" mode="${5:-}"
  local out
  out="$(drive "$body" "$result" "$mode")"
  local word fail
  word="$(printf '%s\n' "$out" | head -1 | awk '{print $1}')"
  fail="$(printf '%s\n' "$out" | sed -n 's/^fail=//p')"
  if [ "$word" != "$want_word" ] || [ "$fail" != "$want_fail" ]; then
    echo "  MISMATCH $label: got ${word}/fail=${fail}, want ${want_word}/fail=${want_fail}" >&2
    problems=$((problems + 1))
  elif [ "$MODE" = "--self-test" ]; then
    # `[ ... ] && echo` as the last statement returns 1 in --fail mode, which
    # under `set -e` ends the function — and the caller reads that as a
    # mismatch. An if/elif has no exit status to leak.
    echo "  ok $label -> ${word} fail=${fail}"
  fi
}

expect "success passes"            success   PASS 0
expect "skipped passes"            skipped   PASS 0
expect "failure blocks as FAIL"    failure   FAIL 1
expect "cancelled blocks as STOP"  cancelled STOP 1
expect "advisory never blocks"     cancelled WARN 0 advisory

if [ "$problems" -ne 0 ]; then
  echo "[gate-outcome-vocabulary] the aggregator's outcome vocabulary changed" >&2
  echo "A cancelled job must block under its own word, not as a failure." >&2
  exit 1
fi

echo "[gate-outcome-vocabulary] OK: 5 outcomes map as declared"
