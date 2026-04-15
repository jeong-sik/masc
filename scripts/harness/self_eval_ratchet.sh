#!/usr/bin/env bash
# Self-Evaluation Ratchet — Black-box product evaluation loop.
#
# Runs the same evaluation methodology as the 2026-03-14 product eval,
# records metrics, and compares against the previous iteration.
# Feeds delta into the next iteration's task backlog.
#
# Metrics tracked:
#   - tool_pass_rate: % of tools that respond correctly
#   - p0_count: number of P0 (critical) bugs
#   - response_size_p95: 95th percentile response size in bytes
#
# Usage:
#   ./self_eval_ratchet.sh [iteration_number]
#   MCP_URL=http://127.0.0.1:9935/mcp ./self_eval_ratchet.sh  # dev instance
set -euo pipefail

ITERATION="${1:-1}"
: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
RESULTS_DIR="${MASC_BASE_PATH:-${HOME:-$PWD}}/.masc/eval_results"
RESULT_FILE="${RESULTS_DIR}/iteration_${ITERATION}.json"

mkdir -p "$RESULTS_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test_framework.sh"

echo "=== Self-Evaluation Ratchet: Iteration ${ITERATION} ==="
echo "MCP: ${MCP_URL}"
echo ""

# ── Core tool pass rate ──
TOOLS=(
  "masc_join"
  "masc_add_task"
  "masc_status"
  "masc_heartbeat"
  "masc_broadcast"
  "masc_tasks"
  "masc_agents"
  "masc_board_list"
  "masc_keeper_list"
)

AGENT_NAME="eval-ratchet-${ITERATION}"
MCP_SESSION_ID="eval-${ITERATION}-$(date +%s)"
export MCP_SESSION_ID

# Join first
call_tool 9000 "masc_join" "{\"agent_name\":\"${AGENT_NAME}\"}" >/dev/null 2>&1 || true

PASS=0
FAIL=0
P0=0
SIZES=()

for tool in "${TOOLS[@]}"; do
  args="{}"
  case "$tool" in
    masc_join) args="{\"agent_name\":\"${AGENT_NAME}\"}" ;;
    masc_add_task) args="{\"title\":\"eval task ${ITERATION}\",\"priority\":3}" ;;
    masc_heartbeat) args="{\"agent_name\":\"${AGENT_NAME}\",\"status\":\"evaluating\"}" ;;
    masc_broadcast) args="{\"message\":\"eval iteration ${ITERATION}\"}" ;;
  esac

  response="$(call_tool $((9100 + PASS + FAIL)) "$tool" "$args" 2>/dev/null || echo '{"error":"timeout"}')"
  size=${#response}
  SIZES+=("$size")

  if echo "$response" | jq -e '.result' >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    # P0: core coordination tools failing is critical
    case "$tool" in
      masc_join|masc_add_task|masc_status|masc_heartbeat)
        P0=$((P0 + 1))
        echo "  P0: ${tool} FAILED"
        ;;
    esac
    echo "  FAIL: ${tool}"
  fi
done

TOTAL=$((PASS + FAIL))
PASS_RATE="$(echo "scale=1; ${PASS} * 100 / ${TOTAL}" | bc)"

# Calculate p95 response size
IFS=$'\n' SORTED_SIZES=($(printf '%s\n' "${SIZES[@]}" | sort -n))
P95_IDX=$(( (${#SORTED_SIZES[@]} * 95 + 99) / 100 - 1 ))
P95_IDX=$(( P95_IDX < 0 ? 0 : P95_IDX ))
P95_SIZE="${SORTED_SIZES[$P95_IDX]}"

# ── Save results ──
cat > "$RESULT_FILE" <<RESULT_JSON
{
  "iteration": ${ITERATION},
  "timestamp": $(date +%s),
  "tool_pass_rate": ${PASS_RATE},
  "tools_passed": ${PASS},
  "tools_failed": ${FAIL},
  "tools_total": ${TOTAL},
  "p0_count": ${P0},
  "response_size_p95": ${P95_SIZE},
  "mcp_url": "${MCP_URL}"
}
RESULT_JSON

echo ""
echo "=== Results ==="
echo "  Tool Pass Rate: ${PASS_RATE}%  (${PASS}/${TOTAL})"
echo "  P0 Bugs: ${P0}"
echo "  Response Size p95: ${P95_SIZE} bytes"
echo "  Saved: ${RESULT_FILE}"

# ── Compare with previous iteration ──
PREV_ITERATION=$((ITERATION - 1))
PREV_FILE="${RESULTS_DIR}/iteration_${PREV_ITERATION}.json"

if [ -f "$PREV_FILE" ]; then
  PREV_RATE="$(jq '.tool_pass_rate' "$PREV_FILE")"
  PREV_P0="$(jq '.p0_count' "$PREV_FILE")"
  echo ""
  echo "=== Delta (vs iteration ${PREV_ITERATION}) ==="
  echo "  Pass Rate: ${PREV_RATE}% -> ${PASS_RATE}%"
  echo "  P0 Count: ${PREV_P0} -> ${P0}"

  # Ratchet check: pass rate must not decrease
  DECREASED="$(echo "${PASS_RATE} < ${PREV_RATE}" | bc -l)"
  if [ "$DECREASED" = "1" ]; then
    echo "  WARNING: Pass rate decreased. Regression detected."
    exit 1
  else
    echo "  STATUS: No regression."
  fi
else
  echo ""
  echo "  (No previous iteration to compare)"
fi

exit 0
