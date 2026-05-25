#!/usr/bin/env bash
# cascade_exhausted pattern analyzer
# Parses fleet keeper-turn logs for cascade exhaustion events and produces a summary.
#
# Usage:
#   ./bin/cascade_exhausted_analyzer.sh <log-file-or-dir> [output-json]
#
# Exit codes:
#   0  analysis completed
#   1  usage error
#   2  no exhausted events found

set -euo pipefail

usage() {
  echo "Usage: $0 <log-file-or-dir> [output-json]" >&2
  exit 1
}

if [ $# -lt 1 ]; then
  usage
fi

INPUT="$1"
OUTPUT="${2:-/dev/stdout}"

# Collect log lines
if [ -d "$INPUT" ]; then
  FILES=$(find "$INPUT" -name '*.json' -o -name '*.jsonl' -o -name '*.log' | sort)
else
  FILES="$INPUT"
fi

if [ -z "$FILES" ]; then
  echo "No log files found in $INPUT" >&2
  exit 1
fi

# Extract cascade_exhausted events from JSON log lines
# Expected patterns:
#   {"kind":"cascade_exhausted","cascade_name":"...","reason":{...}}
#   {"kind":"no_tool_capable_provider","cascade_name":"...",...}
EXHAUSTED_EVENTS=$(grep -h 'cascade_exhausted\|no_tool_capable_provider' $FILES 2>/dev/null || true)

if [ -z "$EXHAUSTED_EVENTS" ]; then
  echo "No cascade_exhausted events found." >&2
  exit 2
fi

TOTAL_LINES=$(echo "$EXHAUSTED_EVENTS" | wc -l | tr -d ' ')

# Count by cascade_name (extract JSON field values)
CASCADE_NAMES=$(echo "$EXHAUSTED_EVENTS" | grep -oP '"cascade_name"\s*:\s*"[^"]*"' | sed 's/"cascade_name"\s*:\s*"//;s/"//' | sort | uniq -c | sort -rn)

# Count by kind
KINDS=$(echo "$EXHAUSTED_EVENTS" | grep -oP '"kind"\s*:\s*"[^"]*"' | sed 's/"kind"\s*:\s*"//;s/"//' | sort | uniq -c | sort -rn)

# Extract reason tags
REASON_TAGS=$(echo "$EXHAUSTED_EVENTS" | grep -oP '"tag"\s*:\s*"[^"]*"' | sed 's/"tag"\s*:\s*"//;s/"//' | sort | uniq -c | sort -rn)

# Extract reason messages (truncated)
REASON_MSGS=$(echo "$EXHAUSTED_EVENTS" | grep -oP '"message"\s*:\s*"[^"]*"' | sed 's/"message"\s*:\s*"//;s/"//' | sort | uniq -c | sort -rn)

# Count by date (ISO prefix from timestamps)
DATES=$(echo "$EXHAUSTED_EVENTS" | grep -oP '\d{4}-\d{2}-\d{2}' | sort | uniq -c | sort -rn)

# Build JSON output
cat > "$OUTPUT" <<ENDJSON
{
  "analysis_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "input": "$INPUT",
  "total_exhausted_events": $TOTAL_LINES,
  "by_cascade_name": [
$(echo "$CASCADE_NAMES" | while read count name; do
  if [ -n "$count" ] && [ -n "$name" ]; then
    echo "    {\"cascade_name\": \"$name\", \"count\": $count},"
  fi
done | sed '$ s/,$//')
  ],
  "by_kind": [
$(echo "$KINDS" | while read count kind; do
  if [ -n "$count" ] && [ -n "$kind" ]; then
    echo "    {\"kind\": \"$kind\", \"count\": $count},"
  fi
done | sed '$ s/,$//')
  ],
  "by_reason_tag": [
$(echo "$REASON_TAGS" | while read count tag; do
  if [ -n "$count" ] && [ -n "$tag" ]; then
    echo "    {\"tag\": \"$tag\", \"count\": $count},"
  fi
done | sed '$ s/,$//')
  ],
  "top_reason_messages": [
$(echo "$REASON_MSGS" | head -10 | while read count msg; do
  if [ -n "$count" ] && [ -n "$msg" ]; then
    echo "    {\"message\": \"$msg\", \"count\": $count},"
  fi
done | sed '$ s/,$//')
  ],
  "by_date": [
$(echo "$DATES" | while read count date; do
  if [ -n "$count" ] && [ -n "$date" ]; then
    echo "    {\"date\": \"$date\", \"count\": $count},"
  fi
done | sed '$ s/,$//')
  ]
}
ENDJSON

echo "Analysis complete: $TOTAL_LINES exhausted events from $(echo "$FILES" | wc -l | tr -d ' ') file(s)" >&2
echo "Output written to $OUTPUT" >&2