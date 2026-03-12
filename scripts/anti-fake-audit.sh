#!/usr/bin/env bash
# Anti-Fake Test Audit — scan test files for vacuous / fake test patterns.
# Uses shell heuristics (no OCaml build required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Anti-Fake Test Audit ==="
echo ""

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: ripgrep (rg) is required"
  exit 2
fi

if ! command -v bc >/dev/null 2>&1; then
  echo "ERROR: bc is required"
  exit 2
fi

TEST_FILES=()
while IFS= read -r file; do
  TEST_FILES+=("$file")
done < <(find test -name "test_*.ml" -type f | sort)
FILE_COUNT=${#TEST_FILES[@]}

echo "Found $FILE_COUNT test files"
echo ""

FAKE=0
SUSPECT=0
GOOD=0

for f in "${TEST_FILES[@]}"; do
  ASSERT_TRUE=$(rg -c "assert true|assert_bool.*true" "$f" 2>/dev/null || echo 0)
  LET_IGNORE=$(rg -c "let _ =" "$f" 2>/dev/null || echo 0)
  TODO_COUNT=$(rg -c '\(\* TODO|\(\* FIXME' "$f" 2>/dev/null || echo 0)

  REAL_ASSERT=$(rg -c 'Alcotest\.|assert_equal|check_raises' "$f" 2>/dev/null || echo 0)
  PROP_TEST=$(rg -c 'QCheck|quickcheck|Crowbar|property' "$f" 2>/dev/null || echo 0)
  ROUNDTRIP=$(rg -c 'roundtrip' "$f" 2>/dev/null || echo 0)

  PENALTY=$(echo "scale=2; $ASSERT_TRUE * 0.3 + $LET_IGNORE * 0.2 + $TODO_COUNT * 0.15" | bc)
  BONUS=$(echo "scale=2; $REAL_ASSERT * 0.05 + $PROP_TEST * 0.05 + $ROUNDTRIP * 0.1" | bc)
  BONUS=$(echo "scale=2; if ($BONUS > 0.5) 0.5 else $BONUS" | bc)
  SCORE=$(echo "scale=2; s = 0.5 - $PENALTY + $BONUS; if (s < 0) 0 else if (s > 1) 1 else s" | bc)

  TIER="good"
  if (( $(echo "$SCORE < 0.3" | bc -l) )); then
    TIER="FAKE"
    FAKE=$((FAKE + 1))
  elif (( $(echo "$SCORE < 0.5" | bc -l) )); then
    TIER="SUSPECT"
    SUSPECT=$((SUSPECT + 1))
  else
    GOOD=$((GOOD + 1))
  fi

  printf "  %-55s  score=%-5s  [%s]\n" "$f" "$SCORE" "$TIER"
done

echo ""
echo "=== Summary ==="
echo "  Good:    $GOOD"
echo "  Suspect: $SUSPECT"
echo "  Fake:    $FAKE"
echo "  Total:   $FILE_COUNT"

if [ "$FAKE" -gt 0 ]; then
  echo ""
  echo "WARNING: $FAKE fake test file(s) detected."
  exit 1
fi

exit 0
