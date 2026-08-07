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
# Field-wise, not one match per line: test/dune puts two names on a line in
# two places, and `grep -o` with a `^` anchor only ever reports the first. That
# is how this check came to report test_task_cache_invariant_13397 as missing
# while (names ...) declared it. The trailing `)` closing a (names ...) list is
# stripped so the last entry in each block still counts.
awk '/^[[:space:]]+test_[a-z_0-9]+/ {
       for (i = 1; i <= NF; i++) {
         name = $i
         sub(/\)+$/, "", name)
         if (name ~ /^test_[a-z_0-9]+$/) print name
       }
     }' test/dune > "$declared"
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

# 714 -> 710: this PR wires test_tool_input_validation, and #27429,
# #27433 and #27441 each wired a suite test/dune already declared without
# lowering this number. Measured on the merged tree after all four, not
# computed -- #27441 landed between this branch's first push and now.
UNWIRED_BASELINE=708
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

# Below the baseline is an improvement, not a defect, so it reports and passes.
# Failing here made every suite-wiring PR turn main red until someone edited
# this number: 748 went red, #27181 set 747, and 746 was red again within the
# hour. scripts/ocaml-structure-ratchet.sh already treats its own drift-down
# this way ("baseline can be lowered", exit 0); this now matches it.
if [ "$unwired" -lt "$UNWIRED_BASELINE" ]; then
  echo "[ci-test-targets] OK - ${unwired} suites unwired, ${UNWIRED_BASELINE} baseline — lower UNWIRED_BASELINE in $0 to hold the gain"
else
  echo "[ci-test-targets] OK - ${unwired} suites unwired, at baseline"
fi
