#!/usr/bin/env bash
# Fail when the CI execution manifests name a test target that the Dune test
# declarations cannot build.
#
# CI runs a hand-maintained allowlist of @test/runtest-<name> targets. Deleting
# the test behind one is a normal cleanup, and nothing in the deleting PR looks
# at the CI manifests, so the stale target survives and dune hard-fails on the next run —
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
# A target is buildable when test/dune declares it directly, its dynamic
# coverage-test manifest declares it, or an explicit alias declares it.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit

declared="$(mktemp)"
referenced="$(mktemp)"
trap 'rm -f "$declared" "$referenced"' EXIT

CI_TARGET_SOURCES=(
  .github/workflows/ci.yml
  scripts/ci-run-focused-tests.sh
)

# Test executables: every module listed in a (names ...) block or a (name X).
# Field-wise, not one match per line: test/dune puts two names on a line in
# two places, and `grep -o` with a `^` anchor only ever reports the first. That
# is how this check came to report test_task_cache_invariant_13397 as missing
# while (names ...) declared it. The trailing `)` closing a (names ...) list is
# stripped so the last entry in each block still counts.
# Field-aware: only (names ...) entries are test executables with a
# runtest-<name> alias. (modules ...) lists the support modules compiled into
# them, which have none — `dune build @test/runtest-<module>` answers "Alias ...
# is empty". Counting both inflated the unwired baseline with six such modules
# (test_operator_control_support, test_keeper_tool_matrix_cases, and four
# siblings; the first two verified against dune directly), and let the
# referenced-subset-declared check above pass for a name dune cannot build —
# the exact breakage that check exists to catch.
awk '/^[[:space:]]*\(names/ { field = "names"; line = substr($0, index($0, "(names") + 6) }
     /^[[:space:]]*\(modules/ { field = "modules"; line = substr($0, index($0, "(modules") + 8) }
     /^[[:space:]]*\((libraries|preprocess|deps|flags|action|alias)/ { field = ""; line = "" }
     !/^[[:space:]]*\(/ { line = $0 }
     field == "names" {
       n = split(line, parts, /[[:space:]]+/)
       for (i = 1; i <= n; i++) {
         name = parts[i]
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

grep -h -oE '@test/runtest-[a-z_0-9-]+' "${CI_TARGET_SOURCES[@]}" \
  | sed 's|@test/runtest-||' \
  | sort -u > "$referenced"

duplicate_references="$(
  grep -h -oE '@test/runtest-[a-z_0-9-]+' "${CI_TARGET_SOURCES[@]}" \
    | sed 's|@test/runtest-||' \
    | sort \
    | uniq -d
)"

if [ -n "$duplicate_references" ]; then
  echo "[ci-test-targets] FAIL - CI executes the same Dune test target more than once"
  echo
  printf '%s\n' "$duplicate_references" | sed 's/^/  - /'
  echo
  echo "Keep one authoritative invocation for each target; repeated runtest aliases"
  echo "spend CI time without adding coverage."
  exit 2
fi

missing="$(comm -23 "$referenced" "$declared")"

if [ -n "$missing" ]; then
  echo "[ci-test-targets] FAIL - CI names targets Dune does not declare"
  echo
  printf '%s\n' "$missing" | sed 's/^/  - /'
  echo
  echo "dune hard-fails on a target it cannot resolve, so these break main after"
  echo "a full build. Remove the step, or restore the test it points at."
  echo
  echo "Occurrences:"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    grep -Hn "@test/runtest-${name}\b" "${CI_TARGET_SOURCES[@]}" | sed 's/^/  /'
  done <<< "$missing"
  exit 2
fi

echo "[ci-test-targets] OK - $(wc -l < "$referenced" | tr -d ' ') CI targets, all declared in Dune"

# Exact current count. Adding an unwired suite is a regression.
# 509 -> 160: wired 349 declared-but-unrun suites, each built and run before
# being listed. The 160 left are not "the ones that fail": the wired list is
# the alphabetical head of the set and stops at test_safe_ops. Measured on
# the rest: 121 of the 125 after test_safe_ops pass and are follow-up wiring,
# 4 fail; of the 35 before it, 17 fail, 5 are not runnable tests (4 e2e
# stanzas gated on MASC_E2E_TESTS, 1 plain executable), test_fusion_wake
# times out in CI (#29064), and the remainder is unmeasured. The declared
# count also includes those 5 non-test aliases.
UNWIRED_BASELINE=39
unwired="$(comm -13 "$referenced" "$declared" | wc -l | tr -d ' ')"

if [ "$unwired" -gt "$UNWIRED_BASELINE" ]; then
  echo
  echo "[ci-test-targets] FAIL - ${unwired} suites are declared but never run in CI (baseline ${UNWIRED_BASELINE})"
  echo
  echo "$((unwired - UNWIRED_BASELINE)) more than the baseline. The full unwired"
  echo "set is large, so diff it against main rather than reading it here:"
  echo "  comm -13 <(ci targets) <(Dune test names)"
  echo
  echo "A suite outside the CI manifests is compile-only: it never executes, so its"
  echo "assertions can outlive the code they pin. Add a @test/runtest-<name>"
  echo "target to one of the declared CI target sources."
  exit 2
fi

# A count below the baseline is a regression too. The gap between the two is
# budget: a later change can add an unwired suite and still read as "OK", so a
# gain nobody locked in becomes room for new debt. Measured on 2026-08-13: 45
# test files added after this ratchet landed (#26959) are still unwired, and
# #28383 is one of them -- it added test_caller_identity_credential_binding
# with the baseline unchanged at 662 on both sides of the merge.
if [ "$unwired" -lt "$UNWIRED_BASELINE" ]; then
  echo
  echo "[ci-test-targets] FAIL - ${unwired} suites unwired, under the ${UNWIRED_BASELINE} baseline by $((UNWIRED_BASELINE - unwired))"
  echo
  echo "Set UNWIRED_BASELINE=${unwired} in $0. The gap is not slack to spend:"
  echo "leaving it lets a later change add an unwired suite and still pass."
  exit 2
fi

echo "[ci-test-targets] OK - ${unwired} suites unwired, at baseline"
