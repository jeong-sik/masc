#!/usr/bin/env bash
# Regression test for scripts/check-oas-pin-forward.sh.
#
# Covers the exact-ancestry proof used by check-oas-pin.sh to accept a
# shared opam switch whose agent_sdk pin moved strictly forward from this
# checkout's recorded SSOT SHA, and to fail closed otherwise.
#
# Run: bash test/test_check_oas_pin_forward.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FORWARD_SCRIPT="${REPO_ROOT}/scripts/check-oas-pin-forward.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

UPSTREAM="${TMP}/upstream"
mkdir -p "${UPSTREAM}" "${TMP}/hooks-empty"
git -C "${UPSTREAM}" init -q -b main
git -C "${UPSTREAM}" config user.email test@example.invalid
git -C "${UPSTREAM}" config user.name test
# Isolate from operator-global hooks (e.g. direct-commit-to-main guards).
git -C "${UPSTREAM}" config core.hooksPath "${TMP}/hooks-empty"

commit_file() {
  local name="$1"
  printf '%s\n' "${name}" > "${UPSTREAM}/${name}"
  git -C "${UPSTREAM}" add "${name}"
  GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" \
    git -C "${UPSTREAM}" commit -q -m "${name}"
  git -C "${UPSTREAM}" rev-parse HEAD
}

SHA_A="$(commit_file a)"
SHA_B="$(commit_file b)"

# Divergent commit on a side branch (not reachable from main).
git -C "${UPSTREAM}" checkout -q -b side "${SHA_A}"
SHA_C="$(commit_file c)"
git -C "${UPSTREAM}" checkout -q main

expect_accept() {
  local desc="$1" expected="$2" installed="$3"
  if ! bash "${FORWARD_SCRIPT}" "${expected}" "${installed}" "${UPSTREAM}" main; then
    echo "FAIL: ${desc} — expected acceptance" >&2
    exit 1
  fi
  echo "ok ${desc}"
}

expect_reject() {
  local desc="$1" expected="$2" installed="$3" remote="${4:-${UPSTREAM}}"
  if bash "${FORWARD_SCRIPT}" "${expected}" "${installed}" "${remote}" main; then
    echo "FAIL: ${desc} — expected fail-closed rejection" >&2
    exit 1
  fi
  echo "ok ${desc}"
}

expect_accept "case 1 - descendant pin on main is accepted as forward drift" "${SHA_A}" "${SHA_B}"
expect_reject "case 2 - backward drift is rejected" "${SHA_B}" "${SHA_A}"
expect_reject "case 3 - divergent pin unreachable from main is rejected" "${SHA_A}" "${SHA_C}"
expect_reject "case 4 - equal SHAs are not forward drift" "${SHA_A}" "${SHA_A}"
expect_reject "case 5 - unreachable remote fails closed" "${SHA_A}" "${SHA_B}" "${TMP}/no-such-repo"
expect_reject "case 6 - malformed installed SHA fails closed" "${SHA_A}" "not-a-sha"
expect_reject "case 7 - malformed expected SHA fails closed" "not-a-sha" "${SHA_B}"

echo ""
echo "[check-oas-pin-forward test] PASS - 7/7 cases"
