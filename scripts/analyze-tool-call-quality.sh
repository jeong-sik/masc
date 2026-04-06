#!/usr/bin/env bash
# analyze-tool-call-quality.sh — Samchon-inspired tool call quality analysis
#
# Reads .masc/tool_calls/ JSONL logs (from keeper_tool_call_log.ml)
# and produces quality metrics aligned with function calling harness principles:
#   1. Tool selection accuracy (per keeper, per model)
#   2. Success/failure rate by tool category
#   3. Duration distribution (fast/normal/slow)
#   4. Failed call details (each failure = harness improvement signal)
#
# Usage:
#   ./scripts/analyze-tool-call-quality.sh [base_path] [days]
#
# Examples:
#   ./scripts/analyze-tool-call-quality.sh              # today, default path
#   ./scripts/analyze-tool-call-quality.sh . 3           # last 3 days
#
# Requires: jq
# Data source: .masc/tool_calls/YYYY-MM/DD.jsonl (PR #5526)

set -euo pipefail

BASE_PATH="${1:-.}"
DAYS="${2:-1}"
TOOL_CALLS_DIR="${BASE_PATH}/.masc/tool_calls"

if ! command -v jq &>/dev/null; then
  echo "jq required. Install: brew install jq" >&2
  exit 1
fi

if [ ! -d "$TOOL_CALLS_DIR" ]; then
  echo "No tool call data found at ${TOOL_CALLS_DIR}"
  echo "Server needs restart with PR #5526 merged to start collecting."
  exit 0
fi

# Collect JSONL files from last N days
FILES=()
for i in $(seq 0 $((DAYS - 1))); do
  DATE=$(date -v-${i}d +%Y-%m/%d 2>/dev/null || date -d "-${i} days" +%Y-%m/%d 2>/dev/null)
  F="${TOOL_CALLS_DIR}/${DATE}.jsonl"
  if [ -f "$F" ]; then
    FILES+=("$F")
  fi
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No tool call data for last ${DAYS} day(s)."
  echo "Checked: ${TOOL_CALLS_DIR}/"
  exit 0
fi

echo "=== Tool Call Quality Analysis (Samchon Harness Metrics) ==="
echo "Source: ${#FILES[@]} file(s), last ${DAYS} day(s)"
echo ""

# Stream files directly into jq (avoid loading all data into memory)

echo "[1/6] Overview"
echo "─────────────────────────────────────────"
jq -s '
  {
    total_calls: length,
    success: ([.[] | select(.success == true)] | length),
    failure: ([.[] | select(.success == false)] | length),
    unique_keepers: ([.[] | .keeper] | unique | length),
    unique_tools: ([.[] | .tool] | unique | length),
    avg_duration_ms: (([.[] | .duration_ms] | add) / length | . * 10 | floor / 10),
  } |
  "Total calls:     \(.total_calls)",
  "Success:         \(.success) (\(.success * 100 / .total_calls)%)",
  "Failure:         \(.failure) (\(.failure * 100 / .total_calls)%)",
  "Unique keepers:  \(.unique_keepers)",
  "Unique tools:    \(.unique_tools)",
  "Avg duration:    \(.avg_duration_ms)ms"
' "${FILES[@]}"
echo ""

echo "[2/6] Per-Keeper Tool Call Quality"
echo "─────────────────────────────────────────"
jq -s '
  group_by(.keeper) | map({
    keeper: .[0].keeper,
    total: length,
    success: ([.[] | select(.success)] | length),
    fail: ([.[] | select(.success | not)] | length),
    tools_used: ([.[] | .tool] | unique | length),
    avg_ms: (([.[] | .duration_ms] | add) / length | . * 10 | floor / 10),
  }) | sort_by(-.total) | .[] |
  "\(.keeper)\t\(.total)\t\(.success)/\(.fail)\t\(.tools_used) tools\t\(.avg_ms)ms"
' "${FILES[@]}" | (echo -e "KEEPER\tCALLS\tOK/FAIL\tTOOLS\tAVG_MS"; cat) | column -t -s $'\t'
echo ""

echo "[3/6] Tool Success Rate (Top 20)"
echo "─────────────────────────────────────────"
jq -s '
  group_by(.tool) | map({
    tool: .[0].tool,
    total: length,
    ok: ([.[] | select(.success)] | length),
    fail: ([.[] | select(.success | not)] | length),
    rate: (([.[] | select(.success)] | length) * 100 / length),
    avg_ms: (([.[] | .duration_ms] | add) / length | . * 10 | floor / 10),
  }) | sort_by(-.total) | .[:20] | .[] |
  "\(.tool)\t\(.total)\t\(.rate)%\t\(.avg_ms)ms"
' "${FILES[@]}" | (echo -e "TOOL\tCALLS\tSUCCESS%\tAVG_MS"; cat) | column -t -s $'\t'
echo ""

echo "[4/6] Duration Distribution (Samchon: fast recovery = good harness)"
echo "─────────────────────────────────────────"
jq -s '
  {
    fast: ([.[] | select(.duration_ms < 500)] | length),
    normal: ([.[] | select(.duration_ms >= 500 and .duration_ms < 2000)] | length),
    slow: ([.[] | select(.duration_ms >= 2000 and .duration_ms < 10000)] | length),
    very_slow: ([.[] | select(.duration_ms >= 10000)] | length),
    total: length
  } |
  "  <500ms (fast):    \(.fast) (\(.fast * 100 / .total)%)",
  "  500-2s (normal):  \(.normal) (\(.normal * 100 / .total)%)",
  "  2-10s (slow):     \(.slow) (\(.slow * 100 / .total)%)",
  "  >10s (very slow): \(.very_slow) (\(.very_slow * 100 / .total)%)"
' "${FILES[@]}"
echo ""

echo "[5/6] Failed Calls Detail (Samchon: failures are loop inputs)"
echo "─────────────────────────────────────────"
FAIL_COUNT=$(jq -s '[.[] | select(.success == false)] | length' "${FILES[@]}")
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "  No failures recorded."
else
  jq -s '
    [.[] | select(.success == false)] | group_by(.tool) | map({
      tool: .[0].tool,
      count: length,
      keepers: ([.[] | .keeper] | unique),
      sample_output: (.[0].output | if length > 120 then .[:120] + "..." else . end),
    }) | sort_by(-.count) | .[:10] | .[] |
    "  \(.tool) (\(.count)x, keepers: \(.keepers | join(",")))",
    "    sample: \(.sample_output)",
    ""
  ' "${FILES[@]}"
fi
echo ""

echo "[6/6] Tool Category Distribution"
echo "─────────────────────────────────────────"
jq -s '
  def cat:
    if test("bash|shell") then "shell"
    elif test("github|git|worktree") then "git"
    elif test("edit|write|delete") then "edit"
    elif test("fs_read|code_read") then "file"
    elif test("board|social") then "board"
    elif test("search|symbols") then "search"
    elif test("task|claim|broadcast|heartbeat|transition") then "coord"
    elif test("memory|recall|context") then "memory"
    elif test("status|dashboard|agents") then "status"
    else "other"
    end;
  group_by(.tool | cat) | map({
    category: (.[0].tool | cat),
    count: length,
    ok: ([.[] | select(.success)] | length),
  }) | sort_by(-.count) | .[] |
  "  \(.category)\t\(.count) calls\t\(.ok * 100 / .count)% ok"
' "${FILES[@]}" | column -t -s $'\t'
echo ""

echo "=== Samchon Harness Alignment Check ==="
echo ""
echo "Principle 1 (Type Coercion): Check OAS logs for coercion entries"
echo "Principle 2 (Self-Healing):  Retry rate = failure calls / total calls"
echo "Principle 3 (Schema First):  $FAIL_COUNT failures — each is a harness improvement signal"
echo "Principle 4 (Small Model QA): Run with MASC_KEEPER_LLM_RERANK=false to test raw 9B"
echo ""
echo "Data location: ${TOOL_CALLS_DIR}/"
