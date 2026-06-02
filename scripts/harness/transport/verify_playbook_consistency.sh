#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/../../../docs/TRANSPORT-PRACTICAL-PLAYBOOK.md"
RUN_ALL="${SCRIPT_DIR}/run_all.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "${PLAYBOOK}" ]] || fail "missing playbook: ${PLAYBOOK}"
[[ -f "${RUN_ALL}" ]] || fail "missing run_all.sh: ${RUN_ALL}"

grep -Fq 'run_harness "${SCRIPT_DIR}/verify_truth.sh"' "${RUN_ALL}" \
  || fail "run_all.sh no longer invokes verify_truth.sh"

grep -Fq './scripts/harness/transport/verify_truth.sh' "${PLAYBOOK}" \
  || fail "playbook no longer documents verify_truth.sh"

grep -Fq '`./scripts/harness/transport/run_all.sh`' "${PLAYBOOK}" \
  || fail "playbook no longer documents run_all.sh inclusion"

grep -Fq 'CI' "${PLAYBOOK}" \
  || fail "playbook no longer documents the CI transport harness path"

echo "PASS: transport playbook stays aligned with verify_truth.sh/run_all.sh/CI relationship"
