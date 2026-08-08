#!/usr/bin/env bash
# check-model-inventory-truth.sh
# Drift gate for the Gemini model inventory.
#
# Originally added in PR #968 (2026-04-16) with a `starts_with "gemini-3"`
# literal grep — that itself locked in the string-classifier anti-pattern.
# Replaced 2026-05-20 (Cluster D root-fix, see
# ~/me/.tmp/pr-audit-2026-05-20/AUDIT-REPORT.md) with a typed-variant check.
#
# Invariants:
#   1a. capabilities.ml exposes `gemini_family_of_id` (the typed classifier).
#   1b. The dispatch site names all live variants (Gemini_3 | Gemini_3_1 |
#       Gemini_2_5) so a missing case is a compile-time obligation, not a
#       silent string miss.
#   1c. capabilities.mli exports the `gemini_family` variant so downstream
#       code can match on it instead of re-comparing strings.
#   2.  test_capabilities.ml covers the 3 live preview IDs
#       (proof that gemini-3 IDs resolve to the correct family + 1M context).
#   3.  Legacy gemini-2.x references in lib/ + test/ do not grow beyond the
#       baseline captured when this gate was introduced.
#
# The baseline is intentionally permissive (equal to the 2026-04-16 count).
# Follow-up PRs Cdeprecate and Cremove will lower it.
#
# Rationale: memory/feedback_policy-runtime-drift-gate.md
#   "정책 선언만으론 부족. 같은 PR에서 runtime 검증 스크립트를 함께 추가."

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPS="$ROOT/lib/llm_provider/capabilities.ml"
CAPS_MLI="$ROOT/lib/llm_provider/capabilities.mli"
TEST_CAP="$ROOT/test/test_capabilities.ml"
BASELINE_LEGACY=53

fail=0

# ── Invariant 1a: typed gemini_family classifier present ────────
if ! grep -Fq 'let gemini_family_of_id' "$CAPS"; then
  echo "FAIL: typed gemini_family_of_id missing in $CAPS" >&2
  fail=1
fi

# ── Invariant 1b: live gemini family variants are declared ───────
# The typed classifier is the dispatch boundary; the variant type must name
# the three live families so new IDs cannot be silently misclassified.
for variant in Gemini_3_1 Gemini_3 Gemini_2_5; do
  if ! grep -Fq "| Capabilities.$variant" "$CAPS" && ! grep -Fq "| $variant" "$CAPS"; then
    echo "FAIL: gemini_family variant $variant missing in $CAPS" >&2
    fail=1
  fi
done

# ── Invariant 1c: variant exported via .mli ─────────────────────
if ! grep -Fq 'type gemini_family' "$CAPS_MLI"; then
  echo "FAIL: gemini_family variant not exported in $CAPS_MLI" >&2
  fail=1
fi

# ── Invariant 2: gemini-3 live preview IDs tested ───────────────
for id in \
    "gemini-3-flash-preview" \
    "gemini-3.1-pro-preview" \
    "gemini-3.1-flash-lite-preview"; do
  if ! grep -Fq "$id" "$TEST_CAP"; then
    echo "FAIL: coverage for $id missing in $TEST_CAP" >&2
    fail=1
  fi
done

# ── Invariant 3: legacy gemini-2.x count bounded ────────────────
legacy=$(rg -n 'gemini-2\.[05]' "$ROOT/lib" "$ROOT/test" 2>/dev/null | wc -l | tr -d ' ')
if [ "$legacy" -gt "$BASELINE_LEGACY" ]; then
  echo "FAIL: legacy gemini-2.x references grew ($legacy > baseline $BASELINE_LEGACY)" >&2
  echo "  Run: rg -n 'gemini-2\\.[05]' lib/ test/" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: gemini_family typed classifier + dispatch present, preview IDs covered in tests, legacy count $legacy ≤ baseline $BASELINE_LEGACY"
