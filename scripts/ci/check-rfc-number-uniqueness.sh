#!/usr/bin/env bash
# check-rfc-number-uniqueness.sh — block PRs that introduce a duplicate RFC number.
#
# The next RFC number in `docs/rfc/.next-number` is allocated *locally* when a
# PR is authored: the author reads the file, adds `docs/rfc/RFC-0NNN-*.md`,
# and bumps the number. Two PRs branched from the same main read the same
# value and each add a `RFC-0NNN-*.md` with the same number but different
# slugs. The two file names never collide, so no existing CI check fails;
# both merge and the RFC number SSOT splits (two documents, one number).
#
# As of 2026-06-17 main already carries 15 such duplicate numbers (e.g.
# RFC-0003, RFC-0058, ...), so a whole-tree scan would fail main itself and
# could not be added as a gate. This check is therefore *incremental*: it
# fails only on a duplicate number that is newly introduced by this PR —
# present as a duplicate on HEAD but not as a duplicate on the base ref.
#
# Meta-issue family: #9516 (SSOT root-cause prevention).
#
# Usage:
#   scripts/ci/check-rfc-number-uniqueness.sh                  # BASE_REF=origin/main
#   BASE_REF=origin/develop scripts/ci/check-rfc-number-uniqueness.sh
#
# Exit codes: 0 = clean / 1 = new duplicate introduced / 2 = error

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

BASE_REF="${BASE_REF:-origin/${GITHUB_BASE_REF:-main}}"

if ! git rev-parse --verify --quiet "${BASE_REF}" >/dev/null 2>&1; then
  echo "PASS (advisory): base ref '${BASE_REF}' not found locally;"
  echo "  set BASE_REF (or run in CI where github.base_ref is fetched) to enable the gate."
  exit 0
fi

# Print RFC numbers (one per line, sorted) for every RFC-* file in a tree-ish.
rfc_nums_in() {
  local ref="$1"
  git ls-tree -r --name-only "${ref}" -- docs/rfc 2>/dev/null \
    | grep -E 'RFC-[0-9]{3,}' \
    | sed -E 's|.*/RFC-([0-9]+).*|\1|' \
    | sort
}

# Numbers that appear 2+ times in a tree-ish.
dups_in() {
  local ref="$1"
  rfc_nums_in "${ref}" | uniq -d
}

base_dups="$(dups_in "${BASE_REF}" || true)"
head_dups="$(dups_in HEAD || true)"

# New duplicates = duplicated on HEAD but NOT duplicated on the base.
new_dups=""
while IFS= read -r n; do
  [ -z "${n}" ] && continue
  if ! printf '%s\n' "${base_dups}" | grep -qxF "${n}"; then
    new_dups+="${n}"$'\n'
  fi
done <<< "${head_dups}"

if [ -n "$(printf '%s' "${new_dups}" | sed '/^[[:space:]]*$/d')" ]; then
  echo "FAIL: this PR introduces duplicate RFC number(s) (base=${BASE_REF}):"
  printf '%s\n' "${new_dups}" | sed '/^[[:space:]]*$/d' | while IFS= read -r n; do
    echo "  RFC-${n} is claimed by multiple files on HEAD but was not a duplicate on ${BASE_REF}:"
    git ls-tree -r --name-only HEAD -- docs/rfc | grep -E "RFC-${n}-" | sed 's/^/    /'
  done
  echo
  echo "Fix: renumber one of the files above to the next free RFC number and bump docs/rfc/.next-number."
  exit 1
fi

echo "PASS: no new duplicate RFC numbers introduced (base=${BASE_REF})."
