#!/bin/bash
# Single improvement iteration
# Usage: ./improve.sh <improvement_id> <description>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMPROVEMENT_ID=${1:-"unknown"}
DESCRIPTION=${2:-"No description"}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DUNE_BUILD_TARGET="${MASC_LOCAL_DUNE_TARGET:-bin/main_eio.exe}"
RUN_FULL_TESTS="${MASC_LOCAL_FULL_DUNE_TESTS:-0}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Improvement: $IMPROVEMENT_ID"
echo "📝 $DESCRIPTION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Pre-check
echo "1️⃣ Pre-check..."
BEFORE_TESTS=0
if [ "$RUN_FULL_TESTS" = "1" ]; then
  BEFORE_TESTS=$(
    CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
      "$REPO_DIR/scripts/ci-run-tests.sh" \
      "$REPO_DIR/scripts/dune-local.sh test" 2>&1 | grep -c "Test Successful" || echo "0"
  )
  echo "   Tests before: $BEFORE_TESTS passing"
else
  echo "   Skipping full local pre-check. Set MASC_LOCAL_FULL_DUNE_TESTS=1 to opt in."
fi

# 2. Build
echo "2️⃣ Building $DUNE_BUILD_TARGET..."
if ! "$REPO_DIR/scripts/dune-local.sh" build "$DUNE_BUILD_TARGET" 2>&1; then
  echo "❌ Build failed!"
  exit 1
fi
echo "   ✅ Build OK"

# 3. Test
AFTER_TESTS=0
FAILED=0
if [ "$RUN_FULL_TESTS" = "1" ]; then
  echo "3️⃣ Testing full suite..."
  TEST_OUTPUT=$(
    CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
      "$REPO_DIR/scripts/ci-run-tests.sh" \
      "$REPO_DIR/scripts/dune-local.sh test" 2>&1 || true
  )
  AFTER_TESTS=$(echo "$TEST_OUTPUT" | grep -c "Test Successful" || echo "0")
  FAILED=$(echo "$TEST_OUTPUT" | grep -c "FAILED\|Error" || echo "0")
else
  echo "3️⃣ Skipping full local test suite. Set MASC_LOCAL_FULL_DUNE_TESTS=1 to opt in."
fi

echo "   Tests after: $AFTER_TESTS passing, $FAILED failed"

# 4. Evaluate
echo "4️⃣ Evaluating..."
if [ "$FAILED" -gt "0" ]; then
  echo "❌ Tests failing! Fix before committing."
  exit 1
fi

if [ "$RUN_FULL_TESTS" = "1" ] && [ "$AFTER_TESTS" -lt "$BEFORE_TESTS" ]; then
  echo "⚠️  Warning: Test count decreased"
fi

# 5. Commit
echo "5️⃣ Committing..."
git add -A
git commit -m "improve($IMPROVEMENT_ID): $DESCRIPTION

Automated improvement iteration
Tests: $AFTER_TESTS passing
Timestamp: $TIMESTAMP" || echo "Nothing to commit"

echo ""
echo "✅ Improvement $IMPROVEMENT_ID complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
