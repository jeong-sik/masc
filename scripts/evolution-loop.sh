#!/bin/bash
# Evolution Loop - 200회 반복으로 에이전트 품질 개선
# 토큰 로테이션 자동 지원

set -e

# Configuration
MAX_ITERATIONS=200
LOG_DIR="$ME_ROOT/workspace/yousleepwhen/masc-mcp/benchmark/logs"
SCORE_FILE="$ME_ROOT/workspace/yousleepwhen/masc-mcp/benchmark/evolution_scores.jsonl"

mkdir -p "$LOG_DIR"

# Load tokens from zshenv
source ~/.zshenv

TOKENS=(
    "$CLAUDE_CODE_OAUTH_TOKEN"
    "$CLAUDE_CODE_OAUTH_TOKEN_anyang"
    "$CLAUDE_CODE_OAUTH_TOKEN_for"
    "$CLAUDE_CODE_OAUTH_TOKEN_yhh"
    "$CLAUDE_CODE_OAUTH_TOKEN_kidsnote"
)
CURRENT_TOKEN_IDX=0

# Token rotation on quota exhaustion
rotate_token() {
    CURRENT_TOKEN_IDX=$(( (CURRENT_TOKEN_IDX + 1) % ${#TOKENS[@]} ))
    export CLAUDE_CODE_OAUTH_TOKEN="${TOKENS[$CURRENT_TOKEN_IDX]}"
    echo "[TOKEN] Rotated to token index $CURRENT_TOKEN_IDX"
}

# Check if token is exhausted (429 error)
check_token() {
    if [[ "$1" == *"rate_limit"* ]] || [[ "$1" == *"429"* ]]; then
        echo "[WARN] Token exhausted, rotating..."
        rotate_token
        return 1
    fi
    return 0
}

# Run single evolution iteration
run_iteration() {
    local gen=$1
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="$LOG_DIR/gen_${gen}_${timestamp}.log"

    echo "[GEN $gen] Starting iteration..."

    # 1. Run Skeptic Review
    echo "[GEN $gen] Phase 1: Skeptic Review"
    local skeptic_output=$(claude --print "Review social.ml for issues. Be brief." 2>&1 || true)
    check_token "$skeptic_output" || skeptic_output=$(claude --print "Review social.ml for issues. Be brief." 2>&1 || true)

    # 2. Count issues (ensure numeric values - use head -1 and validate)
    local critical_count
    critical_count=$(echo "$skeptic_output" | grep -ci "critical\|P0\|race\|corrupt" 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ ! "$critical_count" =~ ^[0-9]+$ ]] && critical_count=0

    local moderate_count
    moderate_count=$(echo "$skeptic_output" | grep -ci "moderate\|P1\|should fix" 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ ! "$moderate_count" =~ ^[0-9]+$ ]] && moderate_count=0

    # 3. Calculate scores (simplified)
    local code_score=$((100 - ${critical_count:-0} * 10 - ${moderate_count:-0} * 5))
    [[ $code_score -lt 0 ]] && code_score=0

    # 4. Log results
    local result="{\"gen\":$gen,\"timestamp\":\"$timestamp\",\"code_score\":$code_score,\"critical\":$critical_count,\"moderate\":$moderate_count}"
    echo "$result" >> "$SCORE_FILE"
    echo "$skeptic_output" > "$log_file"

    echo "[GEN $gen] Score: $code_score (Critical: $critical_count, Moderate: $moderate_count)"

    # 5. If issues found, attempt fix
    if [[ ${critical_count:-0} -gt 0 ]]; then
        echo "[GEN $gen] Phase 2: Auto-fix attempt"
        local fix_output=$(claude --print "Fix the critical issue in social.ml. Apply the fix directly." 2>&1 || true)
        check_token "$fix_output" || true
    fi

    return $code_score
}

# Main loop
echo "=== Evolution Loop Started ==="
echo "Target: $MAX_ITERATIONS iterations"
echo "Tokens available: ${#TOKENS[@]}"
echo ""

for ((gen=1; gen<=MAX_ITERATIONS; gen++)); do
    run_iteration $gen

    # Brief pause to avoid rate limits
    sleep 2

    # Progress checkpoint every 10 iterations
    if (( gen % 10 == 0 )); then
        echo ""
        echo "=== Checkpoint: $gen/$MAX_ITERATIONS iterations complete ==="
        echo "Latest scores:"
        tail -3 "$SCORE_FILE"
        echo ""
    fi
done

echo "=== Evolution Loop Complete ==="
echo "Results saved to: $SCORE_FILE"

# Summary
echo ""
echo "=== Evolution Summary ==="
echo "First generation:"
head -1 "$SCORE_FILE"
echo "Last generation:"
tail -1 "$SCORE_FILE"
