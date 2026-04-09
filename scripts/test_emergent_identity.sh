#!/usr/bin/env bash
# Keeper Emergent Identity System - Integration Test
#
# Runs 3 agents for a specified duration and measures:
# - Upvote ratio (target: >20% vs current ~0%)
# - Reaction diversity (pattern distance between agents)
# - Cost (MODEL calls count)
#
# Usage: ./scripts/test_emergent_identity.sh [duration_hours]
# Default: 24 hours

set -euo pipefail

DURATION_HOURS="${1:-24}"
DURATION_SECS=$((DURATION_HOURS * 3600))
TEST_AGENTS=("dreamer" "connector" "historian")
BASE_PATH="${MASC_BASE_PATH:-${HOME}/me}"
LOG_DIR="${BASE_PATH}/logs/emergent_identity_test"
METRICS_FILE="$LOG_DIR/metrics_$(date +%Y%m%d_%H%M%S).json"

mkdir -p "$LOG_DIR"

echo "=============================================="
echo "Keeper Emergent Identity System - Integration Test"
echo "=============================================="
echo "Duration: ${DURATION_HOURS}h (${DURATION_SECS}s)"
echo "Agents: ${TEST_AGENTS[*]}"
echo "Log dir: $LOG_DIR"
echo "Metrics: $METRICS_FILE"
echo "=============================================="

# Initialize metrics
cat > "$METRICS_FILE" << EOF
{
  "test_start": "$(date -Iseconds)",
  "duration_hours": $DURATION_HOURS,
  "agents": $(printf '%s\n' "${TEST_AGENTS[@]}" | jq -R . | jq -s .),
  "snapshots": []
}
EOF

# Function to collect metrics
collect_metrics() {
    local snapshot_time=$(date -Iseconds)

    echo "[$(date +%H:%M:%S)] Collecting metrics..."

    # Get reaction counts per agent
    local reaction_file="${BASE_PATH}/.masc/reaction_history.jsonl"

    if [[ -f "$reaction_file" ]]; then
        local metrics_json=$(cat "$reaction_file" | \
            jq -s '
                group_by(.agent_name) |
                map({
                    agent: .[0].agent_name,
                    total: length,
                    upvotes: [.[] | select(.reaction == "upvote")] | length,
                    comments: [.[] | select(.reaction == "comment_intent")] | length,
                    passes: [.[] | select(.reaction == "pass")] | length,
                    skips: [.[] | select(.reaction == "skip")] | length
                })
            ' 2>/dev/null || echo "[]")

        # Calculate upvote ratio
        local total_reactions=$(echo "$metrics_json" | jq '[.[].total] | add // 0')
        local total_upvotes=$(echo "$metrics_json" | jq '[.[].upvotes] | add // 0')
        local upvote_ratio=$(echo "scale=4; $total_upvotes / ($total_reactions + 0.001)" | bc)

        echo "   Total reactions: $total_reactions"
        echo "   Total upvotes: $total_upvotes"
        echo "   Upvote ratio: $upvote_ratio"

        # Get board stats
        local board_stats=$(curl -s "http://127.0.0.1:8935/board/stats" 2>/dev/null || echo '{}')

        # Append snapshot
        local snapshot=$(jq -n \
            --arg time "$snapshot_time" \
            --argjson reactions "$metrics_json" \
            --arg upvote_ratio "$upvote_ratio" \
            --argjson board "$board_stats" \
            '{
                timestamp: $time,
                reactions: $reactions,
                upvote_ratio: ($upvote_ratio | tonumber),
                board: $board
            }')

        # Update metrics file
        jq --argjson snap "$snapshot" '.snapshots += [$snap]' "$METRICS_FILE" > "$METRICS_FILE.tmp" && \
            mv "$METRICS_FILE.tmp" "$METRICS_FILE"
    else
        echo "   No reaction history yet"
    fi
}

# Function to trigger heartbeat for an agent
trigger_heartbeat() {
    local agent="$1"
    echo "[$(date +%H:%M:%S)] Triggering heartbeat for $agent..."

    curl -s -X POST "http://127.0.0.1:8935/tools/keeper_heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"agent_name\": \"$agent\", \"reason\": \"integration_test\"}" \
        > "$LOG_DIR/${agent}_$(date +%H%M%S).log" 2>&1 || true
}

# Function to check diversity
check_diversity() {
    echo "[$(date +%H:%M:%S)] Checking agent diversity..."

    curl -s -X POST "http://127.0.0.1:8935/tools/keeper_cycle" \
        -H "Content-Type: application/json" \
        -d '{"action": "diversity_check"}' 2>/dev/null || echo "Diversity check not available"
}

# Main test loop
echo ""
echo "Starting test loop..."
echo "Press Ctrl+C to stop early and generate report"
echo ""

START_TIME=$(date +%s)
INTERVAL_SECS=1800  # 30 minutes between heartbeats

trap 'echo ""; echo "Test interrupted. Generating final report..."; generate_report; exit 0' INT

generate_report() {
    echo ""
    echo "=============================================="
    echo "Final Report"
    echo "=============================================="

    local end_time=$(date -Iseconds)
    local elapsed=$(($(date +%s) - START_TIME))

    # Update metrics with end time
    jq --arg end "$end_time" --arg elapsed "$elapsed" \
        '.test_end = $end | .elapsed_seconds = ($elapsed | tonumber)' \
        "$METRICS_FILE" > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"

    # Print summary
    echo "Duration: $((elapsed / 3600))h $((elapsed % 3600 / 60))m"
    echo ""

    if [[ -f "$METRICS_FILE" ]]; then
        echo "Reaction Summary:"
        jq -r '.snapshots[-1].reactions[] | "  \(.agent): \(.total) reactions, \(.upvotes) upvotes (\(if .total > 0 then (.upvotes * 100 / .total | floor) else 0 end)%)"' "$METRICS_FILE" 2>/dev/null || echo "  No data"

        echo ""
        echo "Overall Upvote Ratio:"
        jq -r '.snapshots[-1].upvote_ratio | "  \(. * 100 | floor)% (target: >20%)"' "$METRICS_FILE" 2>/dev/null || echo "  No data"
    fi

    echo ""
    echo "Full metrics: $METRICS_FILE"
    echo "=============================================="
}

# Initial metrics
collect_metrics

ITERATION=0
while true; do
    ELAPSED=$(($(date +%s) - START_TIME))

    if [[ $ELAPSED -ge $DURATION_SECS ]]; then
        echo ""
        echo "Test duration reached."
        generate_report
        break
    fi

    ITERATION=$((ITERATION + 1))
    echo ""
    echo "=== Iteration $ITERATION (elapsed: $((ELAPSED / 60))m) ==="

    # Trigger heartbeats for all test agents
    for agent in "${TEST_AGENTS[@]}"; do
        trigger_heartbeat "$agent"
        sleep 10  # Small delay between agents
    done

    # Collect metrics
    collect_metrics

    # Check diversity every 4 iterations (2 hours)
    if [[ $((ITERATION % 4)) -eq 0 ]]; then
        check_diversity
    fi

    # Wait for next iteration
    echo "[$(date +%H:%M:%S)] Sleeping ${INTERVAL_SECS}s until next iteration..."
    sleep "$INTERVAL_SECS"
done
