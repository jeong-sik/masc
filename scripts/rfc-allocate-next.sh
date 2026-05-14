#!/bin/bash
# Allocate the next RFC number and advance the ledger.
#
# Reads docs/rfc/.next-number, prints the allocated number to stdout,
# advances the ledger by +1, and writes the new value back.
#
# Workflow:
#   N=$(bash scripts/rfc-allocate-next.sh)
#   $EDITOR docs/rfc/RFC-${N}-my-title.md
#   git add docs/rfc/.next-number docs/rfc/RFC-${N}-my-title.md
#   git commit -m "docs(rfc): RFC-${N} my title"
#
# Race protection: the ledger update is committed together with the new
# RFC file. Two parallel authors trying to allocate the same N will collide
# at git push time (non-fast-forward), which forces a rebase that re-runs
# this script and bumps the second author to the next free number.
#
# CI protection: see .github/workflows/rfc-number-collision-check.yml for
# the matching origin/main collision guard.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LEDGER="${REPO_ROOT}/docs/rfc/.next-number"

if [ ! -f "${LEDGER}" ]; then
  echo "error: ledger file missing: ${LEDGER}" >&2
  echo "       initialize via: echo 0079 > ${LEDGER} && git add ${LEDGER}" >&2
  exit 1
fi

CURRENT=$(tr -d '[:space:]' < "${LEDGER}")

if ! [[ "${CURRENT}" =~ ^[0-9]{4}$ ]]; then
  echo "error: ledger value must be a 4-digit number, got: '${CURRENT}'" >&2
  exit 1
fi

# Force base-10 parsing — leading zeros must not be interpreted as octal.
NEXT=$(printf "%04d" "$((10#${CURRENT} + 1))")

printf "%s\n" "${NEXT}" > "${LEDGER}"

echo "allocated: RFC-${CURRENT} (ledger advanced ${CURRENT} -> ${NEXT})" >&2
printf "%s\n" "${CURRENT}"
