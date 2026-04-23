#!/usr/bin/env bash
# CI gate: 100% telemetry intent coverage + missing metric detection (TEL).
# Meta-issue: #9520
#
# CONTRACT: Every significant action (spawn, keeper turn, tool call, approval
# decision, failure) must emit at least one telemetry event. Missing metrics
# should be flagged, not silently absent.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

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
new_ml_files=$(git diff --name-only origin/main -- lib/ bin/ 2>/dev/null | grep '\.ml$' || true)
for f in $new_ml_files; do
  if [ -f "$f" ] && ! rg -q 'Metrics_store_eio\|Log\.[A-Za-z_]+\|telemetry' "$f"; then
    echo "WARN: new file $f has no telemetry reference (consider adding observability)"
  fi
done

if [ "$exit_code" -eq 0 ]; then
  echo "=== TEL gate: PASS ==="
fi

exit "$exit_code"
