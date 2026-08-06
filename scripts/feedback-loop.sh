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

# Detect platform so metrics collection uses the right tools.
# Linux: /usr/bin/time -v, stat -c %s, /proc/self/status
# macOS: /usr/bin/time -l, stat -f %z, ps -o rss
IS_DARWIN=0
if [ "$(uname -s)" = "Darwin" ]; then
  IS_DARWIN=1
fi

# Portable epoch-milliseconds. BSD `date` (macOS) does not support %N, so fall
# back to perl (Time::HiRes) and finally to whole seconds * 1000.
now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d\n", int(time()*1000)'
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

mkdir -p "$LOG_DIR"

echo "🔄 Starting feedback loop: $ITERATIONS iterations for $TARGET"
echo "📝 Logging to: $LOG_FILE"

for i in $(seq 1 "$ITERATIONS"); do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔁 Iteration $i / $ITERATIONS"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  START_TIME=$(now_ms)
  
  # 1. Build a focused target by default. Full-suite validation belongs in CI
  # unless this local loop explicitly opts in.
  echo "🔨 Building $DUNE_BUILD_TARGET..."
  BUILD_START=$(now_ms)
  # time -v (Linux) / time -l (macOS) captures peak RSS + CPU time. Its report
  # is merged into the captured output so we can extract metrics without losing
  # build logs. The command substitution's exit status is the build's own.
  if [ "$IS_DARWIN" = "1" ]; then
    BUILD_TIME_REPORT=$(/usr/bin/time -l "$REPO_DIR/scripts/dune-local.sh" build "$DUNE_BUILD_TARGET" 2>&1) && BUILD_STATUS=0 || BUILD_STATUS=$?
  else
    BUILD_TIME_REPORT=$(/usr/bin/time -v "$REPO_DIR/scripts/dune-local.sh" build "$DUNE_BUILD_TARGET" 2>&1) && BUILD_STATUS=0 || BUILD_STATUS=$?
  fi
  BUILD_END=$(now_ms)
  BUILD_DURATION=$((BUILD_END - BUILD_START))
  # GNU time -v prints "Maximum resident set size (kbytes): N" (capital M),
  # BSD time -l prints "  N  maximum resident set size" (lowercase) — match
  # case-insensitively and take the first numeric field on the line.
  BUILD_MEM_KB=$(echo "$BUILD_TIME_REPORT" | grep -i "maximum resident set size" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; exit}}')
  if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "$BUILD_TIME_REPORT"
    echo "{\"iteration\":$i,\"phase\":\"build\",\"status\":\"failed\"}" >> "$LOG_FILE"
    echo "❌ Build failed at iteration $i"
    continue
  fi
  
  # 2. Test
  if [ "$RUN_FULL_TESTS" = "1" ]; then
    echo "🧪 Testing full suite..."
    TEST_START=$(now_ms)
    TEST_OUTPUT=$(
      CI_TEST_HEARTBEAT_SEC=30 \
        "$REPO_DIR/scripts/ci-run-tests.sh" \
        "$REPO_DIR/scripts/dune-local.sh test" 2>&1 || true
    )
    TEST_END=$(now_ms)
    TEST_DURATION=$((TEST_END - TEST_START))
    TEST_PASSED=$(echo "$TEST_OUTPUT" | grep -c "Test Successful" || echo "0")
    TEST_FAILED=$(echo "$TEST_OUTPUT" | grep -c "FAILED\|Error" || echo "0")
  else
    echo "🧪 Skipping full local test suite. Set MASC_LOCAL_FULL_DUNE_TESTS=1 to opt in."
    TEST_PASSED=0
    TEST_FAILED=0
    TEST_DURATION=0
  fi
  
  # 3. Measure — collect real per-iteration metrics.
  echo "📊 Measuring..."
  # Binary size of the build artifact, if it exists.
  BIN_SIZE_BYTES=0
  BIN_PATH="$REPO_DIR/_build/default/$DUNE_BUILD_TARGET"
  if [ -n "$DUNE_BUILD_TARGET" ] && [ -f "$BIN_PATH" ]; then
    if [ "$IS_DARWIN" = "1" ]; then
      BIN_SIZE_BYTES=$(stat -f %z "$BIN_PATH" 2>/dev/null || echo "0")
    else
      BIN_SIZE_BYTES=$(stat -c %s "$BIN_PATH" 2>/dev/null || echo "0")
    fi
  fi
  # Peak RSS of this shell (approximation of the iteration's memory footprint).
  SHELL_PEAK_RSS_KB=0
  if [ "$IS_DARWIN" = "1" ]; then
    SHELL_PEAK_RSS_KB=$(ps -o rss= -p $$ 2>/dev/null | awk '{print $1}' || echo "0")
  else
    SHELL_PEAK_RSS_KB=$(awk '/VmHWM/{print $2}' /proc/self/status 2>/dev/null || echo "0")
  fi
  
  END_TIME=$(now_ms)
  DURATION=$((END_TIME - START_TIME))
  
  # Log result
  echo "{\"iteration\":$i,\"phase\":\"complete\",\"tests_passed\":$TEST_PASSED,\"tests_failed\":$TEST_FAILED,\"duration_ms\":$DURATION,\"build_duration_ms\":$BUILD_DURATION,\"build_mem_kb\":$BUILD_MEM_KB,\"test_duration_ms\":$TEST_DURATION,\"bin_size_bytes\":$BIN_SIZE_BYTES,\"shell_peak_rss_kb\":$SHELL_PEAK_RSS_KB,\"timestamp\":\"$(date -Iseconds)\"}" >> "$LOG_FILE"
  
  echo "✅ Iteration $i complete: $TEST_PASSED passed, $TEST_FAILED failed (${DURATION}ms, build ${BUILD_DURATION}ms, ${BUILD_MEM_KB}KB peak)"
  
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
    total_tests_failed: [.[] | select(.tests_failed) | .tests_failed] | add,
    avg_build_duration_ms: ([.[] | select(.build_duration_ms) | .build_duration_ms] | add / length),
    avg_build_mem_kb: ([.[] | select(.build_mem_kb) | .build_mem_kb] | add / length),
    avg_bin_size_bytes: ([.[] | select(.bin_size_bytes) | .bin_size_bytes] | add / length)
  }
' 2>/dev/null || echo "(install jq for summary)"
