#!/usr/bin/env bash
# Fail when ci.yml names a test target that test/dune cannot build.
#
# CI runs a hand-maintained allowlist of @test/runtest-<name> targets. Deleting
# the test behind one is a normal cleanup, and nothing in the deleting PR looks
# at ci.yml, so the stale target survives and dune hard-fails on the next run —
# after the full build, on main, for everyone.
#
# It has happened twice. #24332 retired the shell_ir subsystem and left
# @lib/exec/test/runtest-test_shell_ir_differential pointing at an empty alias,
# which failed main until #24352 removed it. #26921 emptied
# config/prompts/behavior, which killed Keeper_prompt_external and left its
# suite in the prompt step failing.
#
# This turns that into a seconds-long check the deleting PR sees.
#
# A target is buildable when test/dune declares it, either as a test name
# under (names ...) / (name ...) or as an explicit (alias runtest-<name>).
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

declared="$(mktemp)"
referenced="$(mktemp)"
trap 'rm -f "$declared" "$referenced"' EXIT

# Test executables: every module listed in a (names ...) block or a (name X).
grep -oE '^\s+test_[a-z_0-9]+' test/dune | tr -d ' ' > "$declared"
grep -oE '\(name test_[a-z_0-9]+\)' test/dune | sed 's/(name //;s/)//' >> "$declared"
# Explicitly named aliases, e.g. (alias runtest-dashboard-http-behavior-contracts).
grep -oE '\(alias runtest-[a-z_0-9-]+\)' test/dune \
  | sed 's/(alias runtest-//;s/)//' >> "$declared"
# Stanzas pulled in through include files.
for inc in test/stanzas/*.inc; do
  [ -e "$inc" ] || continue
  grep -oE '\(name test_[a-z_0-9]+\)' "$inc" | sed 's/(name //;s/)//' >> "$declared"
done
sort -u -o "$declared" "$declared"

grep -oE '@test/runtest-[a-z_0-9-]+' .github/workflows/ci.yml \
  | sed 's|@test/runtest-||' \
  | sort -u > "$referenced"

missing="$(comm -23 "$referenced" "$declared")"

if [ -n "$missing" ]; then
  echo "[ci-test-targets] FAIL - ci.yml names targets test/dune does not declare"
  echo
  printf '%s\n' "$missing" | sed 's/^/  - /'
  echo
  echo "dune hard-fails on a target it cannot resolve, so these break main after"
  echo "a full build. Remove the step, or restore the test it points at."
  echo
  echo "Occurrences:"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    grep -n "@test/runtest-${name}\b" .github/workflows/ci.yml | sed 's/^/  ci.yml:/'
  done <<< "$missing"
  exit 2
fi

echo "[ci-test-targets] OK - $(wc -l < "$referenced" | tr -d ' ') CI targets, all declared in test/dune"

# Second direction, the larger one: suites test/dune declares that no CI step
# runs. Those compile under @check and never execute, so their assertions can
# assert deleted text for months. Three were found this way in one day
# (#26811 benchmark, the prompt suites, test_keeper_wake_turn_context).
#
# Frozen as a ratchet rather than a hard zero: 771 is where it stands, and a
# PR that adds a suite without wiring it makes that number grow.
UNWIRED_BASELINE=771
unwired="$(comm -13 "$referenced" "$declared" | wc -l | tr -d ' ')"

if [ "$unwired" -gt "$UNWIRED_BASELINE" ]; then
  echo
  echo "[ci-test-targets] FAIL - ${unwired} suites are declared but never run in CI (baseline ${UNWIRED_BASELINE})"
  echo
  echo "$((unwired - UNWIRED_BASELINE)) more than the baseline. The full unwired"
  echo "set is large, so diff it against main rather than reading it here:"
  echo "  comm -13 <(ci targets) <(test/dune names)"
  echo
  echo "A suite outside ci.yml is compile-only: it never executes, so its"
  echo "assertions can outlive the code they pin. Add a @test/runtest-<name>"
  echo "target to .github/workflows/ci.yml."
  exit 2
fi

if [ "$unwired" -lt "$UNWIRED_BASELINE" ]; then
  echo "[ci-test-targets] unwired suites ${unwired} < baseline ${UNWIRED_BASELINE} — lower UNWIRED_BASELINE in $0 to hold the gain"
  exit 2
fi

echo "[ci-test-targets] OK - ${unwired} suites unwired, at baseline"
