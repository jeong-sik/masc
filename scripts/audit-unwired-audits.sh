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

UNWIRED_BASELINE=11

all="$(mktemp)"
called="$(mktemp)"
trap 'rm -f "$all" "$called"' EXIT

ls scripts/*.sh scripts/*.py 2>/dev/null | xargs -n1 basename | sort -u > "$all"

# Names appear either as scripts/<name> or bare inside a for-loop list.
grep -ohE "scripts/[a-z0-9_.-]+\.(sh|py)|^[[:space:]]+(audit|check|verify|guard)[a-z0-9_.-]*\.(sh|py)" \
  .github/workflows/*.yml 2>/dev/null \
  | sed 's|scripts/||; s/^[[:space:]]*//' \
  | sort -u > "$called"

unwired="$(comm -23 "$all" "$called" | grep -cE '^(audit|check|verify|guard)' || true)"

if [ "$unwired" -gt "$UNWIRED_BASELINE" ]; then
  echo "[unwired-audits] FAIL - ${unwired} audit scripts are never run by CI (baseline ${UNWIRED_BASELINE})"
  echo
  comm -23 "$all" "$called" | grep -E '^(audit|check|verify|guard)' | sed 's/^/  - /'
  echo
  echo "A guard CI does not run cannot fail, so it does not guard anything."
  echo "Wire it into .github/workflows/ci.yml, or record here why it cannot run"
  echo "on a runner (live runtime state, missing tool, required arguments)."
  exit 2
fi

if [ "$unwired" -lt "$UNWIRED_BASELINE" ]; then
  echo "[unwired-audits] ${unwired} < baseline ${UNWIRED_BASELINE} — lower UNWIRED_BASELINE in $0 to hold the gain"
  exit 2
fi

echo "[unwired-audits] OK - ${unwired} audit scripts unwired, at baseline"
