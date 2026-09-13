#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}"/{scripts,test,proto,docs,.github,bin}
cp "${SCRIPT_DIR}/check-checkpoint-installation-legacy-purge.sh" "${fixture}/scripts/"
# Read the actual checkpoint owners without copying or mutating source files.
ln -s "${REPO_ROOT}/lib" "${fixture}/lib"

check_result() {
  local expected="$1" actual=0 output
  output="$(bash "${fixture}/scripts/check-checkpoint-installation-legacy-purge.sh" 2>&1)" || actual=$?
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Expected purge exit ${expected}, received ${actual}: ${output}" >&2
    exit 1
  fi
}

# A different typed owner may have a constructor with the same spelling.
printf '%s\n' 'let module Action = Masc.Lane_addon_action in Action.Outcome_unknown' \
  > "${fixture}/test/test_tui_lane_addons.ml"
check_result 0

# An unqualified constructor on a checkpoint-owned test surface remains banned.
printf '%s\n' 'let outcome = Outcome_unknown' > "${fixture}/test/test_keeper_checkpoint_store.ml"
check_result 1
rm "${fixture}/test/test_keeper_checkpoint_store.ml"

# A qualified checkpoint constructor is banned even in another feature test.
printf '%s\n' 'let outcome = Keeper_checkpoint_store.Outcome_unknown' > "${fixture}/test/test_other_feature.ml"
check_result 1
rm "${fixture}/test/test_other_feature.ml"

# The other retired symbols retain their global purge checks.
printf '%s\n' 'let outcome = Transaction_outcome_unknown' > "${fixture}/test/test_other_feature.ml"
check_result 1
rm "${fixture}/test/test_other_feature.ml"
check_result 0
echo '[checkpoint-installation-legacy-purge-test] OK'
