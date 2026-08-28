#!/usr/bin/env bash
# Ratchet the number of audit scripts that CI never runs.
#
# scripts/ holds 183 files and ci.yml called 63 of them before today. The
# audit/check/verify ones are guards: they exist to fail when something drifts.
# A guard nobody runs is indistinguishable from no guard, and this is how
# scripts are born — the PR that writes one does not touch ci.yml.
#
# Thirteen were wired in this branch and all eleven already passed, so nothing
# had been blocking them. Twelve remain, each for a stated reason:
#
#   - credential and fleet audits read a live .masc runtime through
#     MASC_BASE_PATH; on a runner they would inspect an empty directory
#   - check-memory-leak.sh needs valgrind, absent from the CI image
#   - a few take required arguments
#
# The ratchet freezes that 11. Adding a guard without wiring it grows the
# number and fails here; wiring one shrinks it and asks for the baseline to
# move, so the gain is held.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

# Measured, not computed: 14 is what the widened scan reports on main. The
# previous 9 came from a narrower pattern that skipped scripts/ci/ entirely
# and did not match lint-* names, so self-declared gates
# (check-logging-consistency, lint-cancel-guard) were invisible to it.
# See #27626.
UNWIRED_BASELINE=11

all="$(mktemp)"
called="$(mktemp)"
trap 'rm -f "$all" "$called"' EXIT

# scripts/ci/ holds guards too — check-logging-consistency.sh lives there
# and was invisible to this count.
ls scripts/*.sh scripts/*.py scripts/ci/*.sh scripts/ci/*.py 2>/dev/null \
  | xargs -n1 basename | sort -u > "$all"

# Names appear either as scripts/<name> or bare inside a for-loop list.
grep -ohE "scripts/(ci/)?[a-z0-9_.-]+\.(sh|py)|^[[:space:]]+(audit|check|verify|guard|lint)[a-z0-9_.-]*\.(sh|py)" \
  .github/workflows/*.yml scripts/ci/run-lint-suite.sh 2>/dev/null \
  | sed 's|scripts/ci/||; s|scripts/||; s/^[[:space:]]*//' \
  | sort -u > "$called"

GUARD_NAME_RE='^(audit|check|verify|guard|lint)|lint'
unwired="$(comm -23 "$all" "$called" | grep -cE "$GUARD_NAME_RE" || true)"

if [ "$unwired" -gt "$UNWIRED_BASELINE" ]; then
  echo "[unwired-audits] FAIL - ${unwired} audit scripts are never run by CI (baseline ${UNWIRED_BASELINE})"
  echo
  comm -23 "$all" "$called" | grep -E "$GUARD_NAME_RE" | sed 's/^/  - /'
  echo
  echo "A guard CI does not run cannot fail, so it does not guard anything."
  echo "Wire it into .github/workflows/ci.yml, or record here why it cannot run"
  echo "on a runner (live runtime state, missing tool, required arguments)."
  exit 2
fi

# Below the baseline is the improvement this check exists to produce, so it
# reports and passes. Failing here means the PR that wires an audit goes red
# for doing the thing asked of it, and main stays red until someone edits this
# number -- the failure mode recorded when 748 went red, #27181 set 747, and
# 746 was red again within the hour.
# ocaml-structure-ratchet.sh treats its own drift-down this way. Measured
# 2026-08-24: ci-run-test-suite.sh does not — a suite that stops failing has
# to lose its line in test/ci-known-failures.txt in the same commit, citing
# #28383, where a slack gap let a new unwired suite land unnoticed. The two
# policies each have an incident behind them and the repo has not picked one;
# do not read this comment as saying every ratchet agrees.
if [ "$unwired" -lt "$UNWIRED_BASELINE" ]; then
  echo "[unwired-audits] OK - ${unwired} audit scripts unwired, ${UNWIRED_BASELINE} baseline — lower UNWIRED_BASELINE in $0 to hold the gain"
  exit 0
fi

echo "[unwired-audits] OK - ${unwired} audit scripts unwired, at baseline"
