#!/usr/bin/env bash
set -euo pipefail

patterns=(
  "actionable_signal_context:true"
  "actionable_signal_context:false"
  "actionable_signal_context:bool"
  "actionable_signal_context : bool"
)

failed=0
for pattern in "${patterns[@]}"; do
  if rg -n --fixed-strings "$pattern" lib test; then
    echo "no-actionable-signal-bool-context: forbidden legacy bool context: $pattern" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "no-actionable-signal-bool-context: PASS"
