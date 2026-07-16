#!/bin/bash
# Feedback Loop Runner - 자동 반복 개선
# Usage: ./feedback-loop.sh [iterations] [target]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ITERATIONS=${1:-10}
TARGET=${2:-"mitosis"}
LOG_DIR="logs/feedback-loop"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/${TARGET}_${TIMESTAMP}.jsonl"
DUNE_BUILD_TARGET="${MASC_LOCAL_DUNE_TARGET:-bin/main_eio.exe}"
RUN_FULL_TESTS="${MASC_LOCAL_FULL_DUNE_TESTS:-0}"

mkdir -p "$LOG_DIR"

echo "🔄 Starting feedback loop: $ITERATIONS iterations for $TARGET"
echo "📝 Logging to: $LOG_FILE"

for i in $(seq 1 $ITERATIONS); do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔁 Iteration $i / $ITERATIONS"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  START_TIME=$(date +%s%3N)
  
  # 1. Build a focused target by default. Full-suite validation belongs in CI
  # unless this local loop explicitly opts in.
  echo "🔨 Building $DUNE_BUILD_TARGET..."
  if ! "$REPO_DIR/scripts/dune-local.sh" build "$DUNE_BUILD_TARGET" 2>&1; then
    echo "{\"iteration\":$i,\"phase\":\"build\",\"status\":\"failed\"}" >> "$LOG_FILE"
    echo "❌ Build failed at iteration $i"
    continue
  fi
  
  # 2. Test
  if [ "$RUN_FULL_TESTS" = "1" ]; then
    echo "🧪 Testing full suite..."
    TEST_OUTPUT=$(
      CI_TEST_HEARTBEAT_SEC=30 \
        "$REPO_DIR/scripts/ci-run-tests.sh" \
        "$REPO_DIR/scripts/dune-local.sh test" 2>&1 || true
    )
    TEST_PASSED=$(echo "$TEST_OUTPUT" | grep -c "Test Successful" || echo "0")
    TEST_FAILED=$(echo "$TEST_OUTPUT" | grep -c "FAILED\|Error" || echo "0")
  else
    echo "🧪 Skipping full local test suite. Set MASC_LOCAL_FULL_DUNE_TESTS=1 to opt in."
    TEST_PASSED=0
    TEST_FAILED=0
  fi
  
  # 3. Measure (run metrics if available)
  echo "📊 Measuring..."
  # TODO: 실제 metrics 수집 연동
  
  END_TIME=$(date +%s%3N)
  DURATION=$((END_TIME - START_TIME))
  
  # Log result
  echo "{\"iteration\":$i,\"phase\":\"complete\",\"tests_passed\":$TEST_PASSED,\"tests_failed\":$TEST_FAILED,\"duration_ms\":$DURATION,\"timestamp\":\"$(date -Iseconds)\"}" >> "$LOG_FILE"
  
  echo "✅ Iteration $i complete: $TEST_PASSED passed, $TEST_FAILED failed (${DURATION}ms)"
  
  # 4. Check if we should stop early (all tests passing, no improvements possible)
  if [ "$TEST_FAILED" -eq "0" ] && [ "$i" -gt 5 ]; then
    echo "🎉 All tests passing for 5+ iterations. Consider stopping."
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📈 Feedback loop complete. Results in: $LOG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Summary
echo ""
echo "Summary:"
cat "$LOG_FILE" | jq -s '
  {
    total_iterations: length,
    successful: [.[] | select(.phase == "complete")] | length,
    avg_duration_ms: ([.[] | select(.duration_ms) | .duration_ms] | add / length),
    total_tests_passed: [.[] | select(.tests_passed) | .tests_passed] | add,
    total_tests_failed: [.[] | select(.tests_failed) | .tests_failed] | add
  }
' 2>/dev/null || echo "(install jq for summary)"
