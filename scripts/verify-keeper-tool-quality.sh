#!/usr/bin/env bash
# Verification script for Keeper tool calling quality (Issue #3877)
#
# Usage:
#   ./scripts/verify-keeper-tool-quality.sh [masc_port]
#
# Default port: 8935

set -euo pipefail

MASC_PORT="${1:-8935}"
BASE_URL="http://127.0.0.1:${MASC_PORT}"

echo "=== Keeper Tool Calling Quality Verification ==="
echo "Target: ${BASE_URL}"
echo ""

# 1. Check if MASC is running
echo "[1/5] Checking MASC health..."
if ! curl -sf "${BASE_URL}/health" > /dev/null; then
  echo "❌ MASC is not running at ${BASE_URL}"
  echo "Start with: ./start-masc-mcp.sh --http"
  exit 1
fi
echo "✓ MASC is running"
echo ""

# 2. Get keeper list and tool calling metrics
echo "[2/5] Fetching keeper metrics..."
KEEPER_DATA=$(curl -sf "${BASE_URL}/api/v1/keeper/list" || echo "[]")

TOTAL_KEEPERS=$(echo "$KEEPER_DATA" | jq 'length')
echo "Total keepers: ${TOTAL_KEEPERS}"

if [ "$TOTAL_KEEPERS" -eq 0 ]; then
  echo "⚠️  No keepers found"
  exit 0
fi
echo ""

# 3. Analyze tool calling statistics
echo "[3/5] Analyzing tool calling statistics..."
echo "$KEEPER_DATA" | jq -r '
  ["KEEPER", "TOOL_TURNS", "TEXT_TURNS", "AUTO_TURNS", "MODEL"] | @tsv,
  (.[] | [
    .name // "-",
    .autonomous_tool_turn_count // 0,
    .autonomous_text_turn_count // 0,
    .autonomous_turn_count // 0,
    (.last_model_used // .active_model // "-")
  ] | @tsv)
' | column -t -s $'\t'
echo ""

# 4. Calculate aggregate metrics
echo "[4/5] Aggregate metrics..."
echo "$KEEPER_DATA" | jq -r '
  {
    total_keepers: length,
    keepers_with_tool_calls: ([.[] | select((.autonomous_tool_turn_count // 0) > 0)] | length),
    total_tool_turns: ([.[] | .autonomous_tool_turn_count // 0] | add),
    total_text_turns: ([.[] | .autonomous_text_turn_count // 0] | add),
    total_auto_turns: ([.[] | .autonomous_turn_count // 0] | add),
    models_used: ([.[] | .last_model_used // .active_model // empty] | unique | sort)
  } |
  "Total keepers: \(.total_keepers)",
  "Keepers with tool calls: \(.keepers_with_tool_calls) (\((.keepers_with_tool_calls * 100.0 / .total_keepers) | floor)%)",
  "Total tool turns: \(.total_tool_turns)",
  "Total text turns: \(.total_text_turns)",
  "Total autonomous turns: \(.total_auto_turns)",
  "Tool turn ratio: \(if .total_auto_turns > 0 then ((.total_tool_turns * 100.0 / .total_auto_turns) | floor) else 0 end)%",
  "Models in use: \(.models_used | join(", "))"
'
echo ""

# 5. Check tool metrics endpoint
echo "[5/5] Checking global tool metrics..."
TOOL_METRICS=$(curl -sf "${BASE_URL}/api/v1/tool-metrics" || echo '{"top_tools":[]}')

echo "$TOOL_METRICS" | jq -r '
  if .top_tools | length > 0 then
    ["TOOL", "TOTAL", "SUCCESS", "FAIL", "SUCCESS_RATE"] | @tsv,
    (.top_tools[:10] | .[] | [
      .name,
      .total_count,
      .success_count,
      .failure_count,
      (if .total_count > 0 then (((.success_count * 100.0) / .total_count) | floor | tostring) + "%" else "N/A" end)
    ] | @tsv)
  else
    "No tool metrics available yet"
  end
' | column -t -s $'\t'
echo ""

# Summary and recommendations
echo "=== Summary ==="
KEEPERS_WITH_TOOLS=$(echo "$KEEPER_DATA" | jq '[.[] | select((.autonomous_tool_turn_count // 0) > 0)] | length')
TOTAL_TOOL_TURNS=$(echo "$KEEPER_DATA" | jq '[.[] | .autonomous_tool_turn_count // 0] | add')

if [ "$KEEPERS_WITH_TOOLS" -eq 0 ]; then
  echo "❌ CRITICAL: No keepers have made successful tool calls"
  echo ""
  echo "Recommended actions:"
  echo "1. Verify cascade configuration prioritizes GLM over local models"
  echo "2. Check GLM API key: echo \$MASC_GLM_API_KEY"
  echo "3. Restart MASC: ./start-masc-mcp.sh --http"
  echo "4. Monitor for 24 hours and re-run this script"
  exit 1
elif [ "$KEEPERS_WITH_TOOLS" -lt $((TOTAL_KEEPERS * 60 / 100)) ]; then
  echo "⚠️  WARNING: Only ${KEEPERS_WITH_TOOLS}/${TOTAL_KEEPERS} keepers have made tool calls"
  echo ""
  echo "Recommended actions:"
  echo "1. Check per-keeper model assignment in keeper TOML files"
  echo "2. Review keeper autonomy settings (proactive mode enabled?)"
  echo "3. Verify tool availability with: curl ${BASE_URL}/api/v1/tool-registry"
  exit 0
else
  echo "✓ HEALTHY: ${KEEPERS_WITH_TOOLS}/${TOTAL_KEEPERS} keepers making tool calls"
  echo "✓ Total tool turns: ${TOTAL_TOOL_TURNS}"
  echo ""
  echo "System is functioning well. Continue monitoring."
  exit 0
fi
