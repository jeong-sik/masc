#!/usr/bin/env bash
set -euo pipefail

file="${1:-lib/pipeline/pipeline.ml}"

if [[ ! -f "$file" ]]; then
  echo "lint-pipeline-usage-ssot: missing file: $file" >&2
  exit 1
fi

count="$(
  awk '
    /^let stage_collect/ { in_stage = 1 }
    in_stage && /Agent_turn\.accumulate_usage/ { count++ }
    in_stage && /^let handle_missing_required_tool_use/ { in_stage = 0 }
    END { print count + 0 }
  ' "$file"
)"

if [[ "$count" != "1" ]]; then
  cat >&2 <<EOF
lint-pipeline-usage-ssot: expected exactly one Agent_turn.accumulate_usage call in stage_collect, found $count.

stage_collect must compute usage once and reuse that value for both the crash-recovery
checkpoint and the live state update. Calling the accumulator twice can split the
usage SSOT when pricing/accounting logic changes.
EOF
  exit 1
fi

echo "lint-pipeline-usage-ssot: clean"
