#!/usr/bin/env bash
# Keep every CI test target backed by a Dune declaration and ratchet down the
# set of declared suites that CI never executes.
#
# A target is buildable when test/dune declares it directly, its dynamic
# coverage-test manifest declares it, or an explicit alias declares it.
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
# Coverage tests use a committed generated include so Dune can load the graph
# without a dynamic-include rule cycle. The manifest remains the source of
# truth; test/stanzas/dune checks the committed projection for drift.
coverage_manifest="test/stanzas/coverage_test_names.txt"
if grep -qF '(include stanzas/coverage_tests.inc)' test/dune; then
  if [ ! -f "$coverage_manifest" ]; then
    echo "[ci-test-targets] FAIL - coverage manifest is missing: $coverage_manifest"
    exit 2
  fi
  cat "$coverage_manifest" >> "$declared"
fi
# Explicitly named aliases, e.g. (alias runtest-dashboard-http-behavior-contracts).
grep -oE '\(alias runtest-[a-z_0-9-]+\)' test/dune \
  | sed 's/(alias runtest-//;s/)//' >> "$declared"
# Stanzas pulled in through include files. A .inc file that test/dune does not
# (include ...) declares nothing: dune answers "Alias ... specified on the
# command line is empty" for its target, which is the failure this check
# exists to catch, so existence on disk is not enough.
for inc in test/stanzas/*.inc; do
  [ -e "$inc" ] || continue
  grep -qF "(include stanzas/$(basename "$inc"))" test/dune || continue
  grep -oE '\(name test_[a-z_0-9]+\)' "$inc" | sed 's/(name //;s/)//' >> "$declared"
done
sort -u -o "$declared" "$declared"

grep -oE '@test/runtest-[a-z_0-9-]+' .github/workflows/ci.yml \
  | sed 's|@test/runtest-||' \
  | sort -u > "$referenced"

missing="$(comm -23 "$referenced" "$declared")"

if [ -n "$missing" ]; then
  echo "[ci-test-targets] FAIL - ci.yml names targets Dune does not declare"
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

echo "[ci-test-targets] OK - $(wc -l < "$referenced" | tr -d ' ') CI targets, all declared in Dune"

# Measured by this script on the exact branch tree.
UNWIRED_BASELINE=701
unwired="$(comm -13 "$referenced" "$declared" | wc -l | tr -d ' ')"

if [ "$unwired" -gt "$UNWIRED_BASELINE" ]; then
  echo
  echo "[ci-test-targets] FAIL - ${unwired} suites are declared but never run in CI (baseline ${UNWIRED_BASELINE})"
  echo
  echo "$((unwired - UNWIRED_BASELINE)) more than the baseline. The full unwired"
  echo "set is large, so diff it against main rather than reading it here:"
  echo "  comm -13 <(ci targets) <(Dune test names)"
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
