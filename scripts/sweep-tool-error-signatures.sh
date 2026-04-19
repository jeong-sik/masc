#!/usr/bin/env bash
# sweep-tool-error-signatures.sh — daily bucketing of tool-call failures
# by (tool_name, error_signature) for RFC #8760 R4.
#
# Reads ~/me/.masc/tool_calls/YYYY-MM/DD.jsonl (or $MASC_BASE_PATH) and emits
# newline-delimited JSON records, one per (tool, signature) pair with count.
#
# Purpose: observe whether persona/hint changes reduce per-class repeats
# over time. Pair with RFC #8760 R1/R2 rollouts.
#
# Usage:
#   scripts/sweep-tool-error-signatures.sh [days] [out_dir]
#
# Examples:
#   scripts/sweep-tool-error-signatures.sh               # today -> stdout
#   scripts/sweep-tool-error-signatures.sh 2             # last 2 days
#   scripts/sweep-tool-error-signatures.sh 3 data/tool-error-sweeps
#
# Output record shape (one JSON per line):
#   {"date":"2026-04-18","tool":"masc_code_read","sig":"...","count":48}
#
# Requires: jq
# Related: scripts/analyze-tool-call-quality.sh (human-readable counterpart)

set -euo pipefail

DAYS="${1:-1}"
OUT_DIR="${2:-}"
BASE_PATH="${MASC_BASE_PATH:-${HOME}/me}"
TOOL_CALLS_DIR="${BASE_PATH}/.masc/tool_calls"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required. Install: brew install jq" >&2
  exit 1
fi

if [ ! -d "$TOOL_CALLS_DIR" ]; then
  echo "no tool call data at ${TOOL_CALLS_DIR}" >&2
  exit 0
fi

emit_day() {
  local date="$1" file="$2"
  [ -f "$file" ] || return 0

  jq -rc '
    select(.success == false) |
    . as $row |
    ($row.output // "") |
    (try (fromjson | .error) catch null) as $err |
    select($err != null) |
    [$row.tool, ($err | tostring)]
    | @tsv
  ' "$file" 2>/dev/null |
  awk -F'\t' -v d="$date" '
    function normalize(s,    r) {
      r = s
      gsub(/\/Users\/[^ ]+/, "<path>", r)
      gsub(/\/home\/[^ ]+/, "<path>", r)
      gsub(/[0-9]{6,}/, "<num>", r)
      gsub(/[a-f0-9]{32,}/, "<hash>", r)
      r = substr(r, 1, 80)
      return r
    }
    function js(s,    r) {
      r = s
      gsub(/\\/, "\\\\", r)
      gsub(/"/,  "\\\"", r)
      gsub(/\t/, "\\t",  r)
      gsub(/\n/, "\\n",  r)
      gsub(/\r/, "\\r",  r)
      return r
    }
    {
      sig = normalize($2)
      key = $1 "\x01" sig
      counts[key]++
      tools[key] = $1
      sigs[key]  = sig
    }
    END {
      for (k in counts) {
        printf "{\"date\":\"%s\",\"tool\":\"%s\",\"sig\":\"%s\",\"count\":%d}\n", \
          d, js(tools[k]), js(sigs[k]), counts[k]
      }
    }
  ' |
  sort -t: -k5 -rn
}

for i in $(seq 0 $((DAYS - 1))); do
  if date -v-${i}d +%Y-%m/%d >/dev/null 2>&1; then
    day_path=$(date -v-${i}d +%Y-%m/%d)
    day_iso=$(date -v-${i}d +%Y-%m-%d)
  else
    day_path=$(date -d "-${i} days" +%Y-%m/%d)
    day_iso=$(date -d "-${i} days" +%Y-%m-%d)
  fi
  src="${TOOL_CALLS_DIR}/${day_path}.jsonl"
  if [ -n "$OUT_DIR" ]; then
    month_dir="${OUT_DIR}/$(printf '%s' "$day_iso" | cut -c1-7)"
    mkdir -p "$month_dir"
    dst="${month_dir}/$(printf '%s' "$day_iso" | cut -c9-10).jsonl"
    emit_day "$day_iso" "$src" > "$dst"
    echo "wrote $(wc -l < "$dst" | tr -d ' ') records -> $dst" >&2
  else
    emit_day "$day_iso" "$src"
  fi
done
