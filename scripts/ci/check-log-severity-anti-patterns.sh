#!/usr/bin/env bash
# CI gate: Log severity anti-pattern detector.
# Contract: docs/spec/18-log-severity-taxonomy.md (rules L1-L5).
#
# Rationale
#   `lib/masc_log/log.{ml,mli}` exposes 4 levels (Debug | Info | Warn | Error)
#   with no per-callsite contract. The taxonomy doc defines 5 anti-patterns
#   observed in production logs. Each pattern is a structural marker that
#   `rg` can detect.
#
# Mode
#   Ratchet: each rule has a baseline = count of known violations in `lib/` at
#   adoption time. CI fails if the count INCREASES (new violation introduced).
#   The baseline is meant to drop as Phase 2-3 reclassification PRs land —
#   bump the constant down whenever a cleanup PR reduces the count.
#
# Why ratchet (not strict)
#   ~50 existing violations across 4 active rules. A strict gate would block
#   all PRs until cleanup is finished. The ratchet catches every new violation
#   immediately while letting the cleanup happen at its own cadence.
#
# Format-string caveat
#   OCaml `Log.X.info` calls span 2-N lines; the format literal is on a
#   separate line from the function call. The patterns use `rg -U` (multi-line)
#   with a `(?s:.{0,500})` window to bridge the gap. 500 chars is empirical —
#   long enough for any real format string, short enough to avoid spanning
#   adjacent unrelated calls.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Baselines captured 2026-04-27 against origin/main @ d09db6b4fd.
# Decrease these only — increases mean a new violation slipped in.
BASELINE_L1_SILENT=28
BASELINE_L1_LOGGING_ONLY=12
BASELINE_L2_OPERATOR_BROADCAST=13
BASELINE_L4_WATCHDOG_TICK=9
BASELINE_L5_VALIDATION_SUCCESS=0

exit_code=0
total_current=0
total_baseline=0

# Multi-line scan. Returns count of unique callsite locations.
# `rg` exits 1 when there are zero matches; pipefail would propagate that as
# a script abort. Force a non-failing exit so wc sees an empty stream.
count_pattern() {
  local pat="$1"
  ( rg -nUP --type ml -g '!test/' "$pat" lib/ 2>/dev/null || true ) | wc -l | tr -d ' '
}

check_rule() {
  local rule_id="$1"
  local description="$2"
  local pattern="$3"
  local baseline="$4"
  local doc_section="$5"

  local current
  current=$(count_pattern "$pattern")
  total_current=$((total_current + current))
  total_baseline=$((total_baseline + baseline))

  if [ "$current" -gt "$baseline" ]; then
    echo "FAIL  $rule_id ($description): $current > baseline=$baseline"
    echo "      see docs/spec/18-log-severity-taxonomy.md $doc_section"
    echo "      first 5 offending lines:"
    rg -nUP --type ml -g '!test/' "$pattern" lib/ 2>/dev/null \
      | head -5 | sed 's/^/        /'
    echo
    exit_code=1
  elif [ "$current" -lt "$baseline" ]; then
    echo "OK    $rule_id ($description): $current < baseline=$baseline"
    echo "      cleanup detected — drop BASELINE in this script to lock in the gain"
  else
    echo "OK    $rule_id ($description): $current"
  fi
}

# L1 — silent fallback should be Error, not Info/Warn.
check_rule "L1a" "silent + warn" \
  'Log\.[A-Z][a-z]+\.warn[^"]*"[^"]*silent[^"]*' \
  "$BASELINE_L1_SILENT" \
  "§ 3.1"

check_rule "L1b" "logging-only mode + warn" \
  'Log\.[A-Z][a-z]+\.warn[^"]*(?s:.{0,500})logging-only mode' \
  "$BASELINE_L1_LOGGING_ONLY" \
  "§ 3.1"

# L2 — operator_broadcast emission is Warn/Error, not Info.
check_rule "L2" "operator_broadcast + info" \
  'Log\.[A-Z][a-z]+\.info[^"]*(?s:.{0,500})operator_broadcast' \
  "$BASELINE_L2_OPERATOR_BROADCAST" \
  "§ 3.2"

# L4 — periodic ticks (watchdog/keepalive/heartbeat) are Debug, not Info.
# L3 (model behavior promoted to Error) and L5 (validation success as Info) are
# intentionally omitted from this initial gate — current count is 0 in main, so
# there's no baseline to drift from. Add them as separate check_rule calls if a
# regression appears.
check_rule "L4" "watchdog/keepalive/heartbeat + info" \
  'Log\.[A-Z][a-z]+\.info[^"]*(?s:.{0,500})(watchdog tick|keepalive emitted|heartbeat sent)' \
  "$BASELINE_L4_WATCHDOG_TICK" \
  "§ 3.4"

# L5 — validation success log is Debug, not Info.
check_rule "L5" "validation success (coerced) + info" \
  'Log\.[A-Z][a-z]+\.info[^"]*(?s:.{0,500})tool_input_validation coerced' \
  "$BASELINE_L5_VALIDATION_SUCCESS" \
  "§ 3.5"

echo
echo "─── Summary ───────────────────────────────"
echo "  current total:  $total_current"
echo "  baseline total: $total_baseline"
echo "  delta:          $((total_current - total_baseline))"

if [ "$exit_code" -eq 0 ]; then
  echo "  status: OK"
else
  echo "  status: FAIL — new anti-pattern violation(s) introduced"
fi

exit "$exit_code"
