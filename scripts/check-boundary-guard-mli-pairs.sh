#!/usr/bin/env bash
# Boundary-guard .mli pairing lint (diff-driven)
#
# Catches the sweep-miss anti-pattern where a refactor PR newly adds a `.mli`
# whose paired `.ml` is already in a `check_forbidden_outside` allow-list of
# `scripts/check-boundary-guard.sh`, but the `.mli` was not added alongside.
# The newly-exposed docstrings then trigger boundary-guard failures on every
# subsequent PR until the allow-list is updated.
#
# Background: PR #11248 split keeper_meta_json_scrub.mli without adding it to
# the V10 allow-list, blocking the merge queue (PR #11272). See memory
# `feedback_jane-street-refactor-sweep-miss` (5 occurrences as of 2026-04-27).
#
# This gate is diff-driven and only flags .mli files newly added in the PR
# whose paired .ml is already allow-listed. It does NOT flag historical .mli
# files that boundary-guard already accepts (those have no forbidden hits).
#
# CI usage:
#   BASE_REF=origin/${{ github.base_ref }} scripts/check-boundary-guard-mli-pairs.sh
# Local usage (defaults to origin/main):
#   scripts/check-boundary-guard-mli-pairs.sh
#
# Bash-3.2 compatible.

set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${REPO_ROOT}/scripts/check-boundary-guard.sh"
BASE_REF="${BASE_REF:-origin/main}"

if [ ! -f "${GUARD}" ]; then
  echo "PAIR-GATE: ${GUARD} not found" >&2
  exit 2
fi

# git diff requires the base ref to exist locally. Tolerate missing ref by
# falling back to HEAD~1 (single-commit default), and ultimately skipping if
# we cannot establish a base. CI workflows that need this gate must set
# fetch-depth: 0 or fetch the base branch explicitly.
if ! git -C "${REPO_ROOT}" rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
  if git -C "${REPO_ROOT}" rev-parse --verify --quiet HEAD~1 >/dev/null; then
    echo "PAIR-GATE: BASE_REF '${BASE_REF}' not found, falling back to HEAD~1"
    BASE_REF="HEAD~1"
  else
    echo "PAIR-GATE: skipped — cannot resolve BASE_REF '${BASE_REF}'"
    exit 0
  fi
fi

# Collect newly-added .mli files from the PR diff
new_mli_list=$(git -C "${REPO_ROOT}" diff --name-only --diff-filter=A \
  "${BASE_REF}...HEAD" -- '*.mli' || true)

if [ -z "${new_mli_list}" ]; then
  echo "PAIR-GATE: no newly-added .mli files in diff vs ${BASE_REF}"
  exit 0
fi

rc=0
violations=""
checked_count=0

for mli in ${new_mli_list}; do
  ml="${mli%.mli}.ml"
  # Look up the paired .ml in the boundary-guard allow-list. If the paired
  # .ml is not allow-listed, this gate is silent — boundary-guard itself
  # handles the case (the .mli either has no forbidden hits, or boundary-guard
  # will fail with its own message).
  if grep -F -q "\"${ml}\"" "${GUARD}"; then
    checked_count=$((checked_count + 1))
    if ! grep -F -q "\"${mli}\"" "${GUARD}"; then
      violations="${violations}
  - newly-added ${mli} is paired with allow-listed ${ml}, but is missing from scripts/check-boundary-guard.sh"
      rc=1
    fi
  fi
done

if [ "${rc}" -ne 0 ]; then
  echo "PAIR-GATE FAIL: boundary-guard allow-list missing .mli companion(s)${violations}"
  echo
  echo "fix: add the missing .mli path to the same check_forbidden_outside"
  echo "     block in scripts/check-boundary-guard.sh"
  echo "ref: feedback_jane-street-refactor-sweep-miss (5+ occurrences)"
  echo "     PR #11248 → blocked #11272 → fix-forward #11280 / #11283"
  exit 1
fi

echo "PAIR-GATE: checked ${checked_count} newly-added .mli vs allow-list — OK"
exit 0
