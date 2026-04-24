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
HARNESS=0

count_rg() {
  local pattern="$1"
  local file="$2"
  rg -c "$pattern" "$file" 2>/dev/null || echo 0
}

has_rg() {
  local pattern="$1"
  local file="$2"
  rg -q "$pattern" "$file" 2>/dev/null
}

for f in "${TEST_FILES[@]}"; do
  ASSERT_TRUE=$(count_rg "assert true|assert_bool.*true" "$f")
  LET_IGNORE=$(count_rg "let _ =" "$f")
  TODO_COUNT=$(count_rg '\(\* TODO|\(\* FIXME' "$f")

  REAL_ASSERT=$(count_rg 'Alcotest\.|assert_equal|check_raises|Alcotest\.fail|fail[[:space:]]+"|failwith[[:space:]]+"|assert[[:space:]]*\(|(^|[^A-Za-z0-9_])check[[:space:]]+(bool|int|string|float|list|option|pair|\()' "$f")
  PROP_TEST=$(count_rg 'QCheck|quickcheck|Crowbar|property' "$f")
  ROUNDTRIP=$(count_rg 'roundtrip' "$f")

  if ! has_rg 'Alcotest\.run|run[[:space:]]+"' "$f" \
     && has_rg 'Arg\.parse|Sys\.argv|Unix\.system|exit[[:space:]]+[01]' "$f"; then
    HARNESS=$((HARNESS + 1))
    printf "  %-55s  score=n/a    [HARNESS]\n" "$f"
    continue
  fi

  LET_IGNORE_PENALTY=$(echo "scale=2; p = $LET_IGNORE * 0.02; if (p > 0.25) 0.25 else p" | bc)
  PENALTY=$(echo "scale=2; $ASSERT_TRUE * 0.3 + $LET_IGNORE_PENALTY + $TODO_COUNT * 0.15" | bc)
  BONUS=$(echo "scale=2; $REAL_ASSERT * 0.08 + $PROP_TEST * 0.05 + $ROUNDTRIP * 0.1" | bc)
  BONUS=$(echo "scale=2; if ($BONUS > 0.7) 0.7 else $BONUS" | bc)
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
echo "  Harness: $HARNESS"
echo "  Total:   $FILE_COUNT"

if [ "$FAKE" -gt 0 ]; then
  echo ""
  echo "WARNING: $FAKE fake test file(s) detected."
  exit 1
fi

exit 0
