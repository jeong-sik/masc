#!/bin/bash
# Single improvement iteration
# Usage: ./improve.sh <improvement_id> <description>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMPROVEMENT_ID=${1:-"unknown"}
DESCRIPTION=${2:-"No description"}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Improvement: $IMPROVEMENT_ID"
echo "📝 $DESCRIPTION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Pre-check
echo "1️⃣ Pre-check..."
BEFORE_TESTS=$(
  CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
    "$REPO_DIR/scripts/ci-run-tests.sh" \
    "opam exec -- dune test --root \"$REPO_DIR\"" 2>&1 | grep -c "Test Successful" || echo "0"
)
echo "   Tests before: $BEFORE_TESTS passing"

# 2. Build
echo "2️⃣ Building..."
if ! opam exec -- dune build --root "$REPO_DIR" 2>&1; then
  echo "❌ Build failed!"
  exit 1
fi
echo "   ✅ Build OK"

# 3. Test
echo "3️⃣ Testing..."
TEST_OUTPUT=$(
  CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
    "$REPO_DIR/scripts/ci-run-tests.sh" \
    "opam exec -- dune test --root \"$REPO_DIR\"" 2>&1 || true
)
AFTER_TESTS=$(echo "$TEST_OUTPUT" | grep -c "Test Successful" || echo "0")
FAILED=$(echo "$TEST_OUTPUT" | grep -c "FAILED\|Error" || echo "0")

echo "   Tests after: $AFTER_TESTS passing, $FAILED failed"

# 4. Evaluate
echo "4️⃣ Evaluating..."
if [ "$FAILED" -gt "0" ]; then
  echo "❌ Tests failing! Fix before committing."
  exit 1
fi

if [ "$AFTER_TESTS" -lt "$BEFORE_TESTS" ]; then
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
