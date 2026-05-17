#!/usr/bin/env bash
# Anti-Fake Test Audit — scan test files for vacuous / fake test patterns.
# Uses shell heuristics (no OCaml build required).
#
# Modes:
#   (default)          test/ scan for fake-test patterns (Alcotest assertions)
#   --production-scan  lib/  scan for silent-failure anti-patterns (RFC-0097 §3.4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE="test-scan"
if [ "${1:-}" = "--production-scan" ]; then
  MODE="production-scan"
  shift
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: ripgrep (rg) is required"
  exit 2
fi

if [ "$MODE" = "production-scan" ]; then
  # RFC-0097 §3.4 — production-code silent-failure scan against lib/.
  # Baseline is captured in scripts/lint/silent-skip-grandfather.txt;
  # any new occurrence outside the grandfather list fails the gate.
  GRANDFATHER="scripts/lint/silent-skip-grandfather.txt"
  if [ ! -f "$GRANDFATHER" ]; then
    echo "ERROR: grandfather inventory missing at $GRANDFATHER" >&2
    exit 2
  fi

  echo "=== Production Silent-Failure Scan (RFC-0097) ==="
  echo ""

  # Build the grandfather allow-list of "path:line" pairs.
  ALLOW=$(grep -vE '^(#|$)' "$GRANDFATHER" | awk -F: '{print $1":"$2}' | sort -u)

  FAIL=0

  # Pattern 1: ignore (Error _) — HARD FAIL on any occurrence.
  IGNORE_ERROR_HITS=$(rg -n --type ocaml -e 'ignore \(Error ' lib/ 2>/dev/null || true)
  if [ -n "$IGNORE_ERROR_HITS" ]; then
    echo "FAIL: \`ignore (Error _)\` is unconditional silent-skip (RFC-0097 §3.4)."
    echo "      Baseline is 0; new occurrences must propagate the Result."
    echo "$IGNORE_ERROR_HITS"
    FAIL=$((FAIL + 1))
  fi

  # Pattern 2: | Error _ -> ()  (and bivalent | Ok _ | Error _ -> ())
  E_HITS=$(rg -n --type ocaml -e '\| (Ok _ \| )?Error _ -> \(\)' lib/ 2>/dev/null || true)
  if [ -n "$E_HITS" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      key=$(printf '%s' "$line" | awk -F: '{print $1":"$2}')
      if ! printf '%s\n' "$ALLOW" | grep -Fxq "$key"; then
        echo "FAIL: ungrandfathered silent-skip at $key"
        echo "      (RFC-0097 §3.4 — add to $GRANDFATHER with Quiet justification,"
        echo "       or migrate to typed propagation)"
        echo "      $line"
        FAIL=$((FAIL + 1))
      fi
    done <<< "$E_HITS"
  fi

  # Pattern 3: try ... with _ -> () — same grandfather mechanism.
  # Comment-aware filter: OCaml docstrings cite the anti-pattern as
  # `[with _ -> ()]` inside [...] brackets. Skip if:
  #   - line content starts with `*` or `(*` (line is inside a comment block)
  #   - the matched substring appears inside square brackets (doc citation)
  #   - line ends with `*)` (comment close on a citation line)
  T_HITS=$(rg -nU --type ocaml --multiline -e 'with[[:space:]]+_[[:space:]]+->[[:space:]]+\(\)' lib/ 2>/dev/null || true)
  if [ -n "$T_HITS" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      content=$(printf '%s' "$line" | cut -d: -f3-)
      # Filter A: line-start comment markers.
      if printf '%s' "$content" | grep -qE '^[[:space:]]*(\*|\(\*)'; then
        continue
      fi
      # Filter B: doc citation pattern [with _ -> ()] inside brackets,
      # or line ends with comment close *).
      if printf '%s' "$content" | grep -qE '\[[^][]*with[[:space:]]+_[[:space:]]+->[[:space:]]+\(\)[^][]*\]'; then
        continue
      fi
      if printf '%s' "$content" | grep -qE '\*\)[[:space:]]*$'; then
        continue
      fi
      key=$(printf '%s' "$line" | awk -F: '{print $1":"$2}')
      if ! printf '%s\n' "$ALLOW" | grep -Fxq "$key"; then
        echo "FAIL: ungrandfathered try-with-underscore-unit at $key"
        echo "      (RFC-0097 §3.4)"
        echo "      $line"
        FAIL=$((FAIL + 1))
      fi
    done <<< "$T_HITS"
  fi

  # Pattern 4: let _ = ... |> Result.bind — HARD FAIL on any occurrence.
  RB_HITS=$(rg -n --type ocaml -e 'let _ = .*\|> Result\.bind' lib/ 2>/dev/null || true)
  if [ -n "$RB_HITS" ]; then
    echo "FAIL: \`let _ = ... |> Result.bind\` discards a chained Result (RFC-0097 §3.4)."
    echo "$RB_HITS"
    FAIL=$((FAIL + 1))
  fi

  echo ""
  echo "=== Production Scan Summary ==="
  if [ "$FAIL" -gt 0 ]; then
    echo "  $FAIL violation(s) above grandfathered baseline."
    echo ""
    echo "Resolution paths:"
    echo "  1. Propagate the Result/Error (preferred)."
    echo "  2. Use Mcp_error_code.Quiet { reason ; recovered } at the transport"
    echo "     boundary and document the skip rationale inline."
    echo "  3. Add the site to $GRANDFATHER with a justifying"
    echo "     code comment at the line (PR review must accept the addition)."
    exit 1
  fi
  echo "  Clean — no new silent-failure sites beyond grandfathered baseline."
  exit 0
fi

# Default mode below: test-scan.
echo "=== Anti-Fake Test Audit ==="
echo ""

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
