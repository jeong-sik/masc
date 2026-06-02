#!/usr/bin/env bash
# Regression test for scripts/opam-pin-external-deps.sh downgrade guard.
#
# Run: bash test/test_opam_pin_downgrade_guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PIN_SCRIPT="${REPO_ROOT}/scripts/opam-pin-external-deps.sh"

source "${REPO_ROOT}/scripts/oas-agent-sdk-pin.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="${TMP}/bin"
CALLS_FILE="${TMP}/opam.calls"
FLOOR_FILE="${TMP}/agent_sdk.floor"
mkdir -p "${FAKE_BIN}"

cat > "${FAKE_BIN}/opam" <<'FAKE_OPAM'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  list)
    for arg in "$@"; do
      if [[ "${arg}" == "--short" ]]; then
        echo "fake opam list rejects --short with explicit columns" >&2
        exit 44
      fi
    done
    if [[ "${FAKE_OPAM_LIST_FAIL:-0}" == "1" ]]; then
      echo "fake opam list failure" >&2
      exit 42
    fi
    if [[ -n "${FAKE_AGENT_SDK_LIST_OUTPUT+x}" ]]; then
      printf '%b' "${FAKE_AGENT_SDK_LIST_OUTPUT}"
    else
      printf 'agent_sdk %s\n' "${FAKE_AGENT_SDK_VERSION:-0.0.0}"
    fi
    ;;
  show)
    shift
    if [[ "${1:-}" == "agent_sdk" && "${2:-}" == "--field=version" ]]; then
      if [[ "${FAKE_OPAM_SHOW_MISSING:-0}" == "1" ]]; then
        echo "[ERROR] No package matching agent_sdk found" >&2
        exit 1
      fi
      [[ "${FAKE_OPAM_SHOW_FAIL:-0}" == "1" ]] && exit 43
      printf '%s\n' "${FAKE_OPAM_SHOW_VERSION:-${FAKE_AGENT_SDK_VERSION:-0.0.0}}"
      exit 0
    fi
    echo "unexpected fake opam show command: $*" >&2
    exit 2
    ;;
  pin)
    shift
    if [[ "${1:-}" == "add" ]]; then
      printf 'pin add %s %s\n' "${2:-}" "${3:-}" >> "${OPAM_FAKE_CALLS:?}"
      exit 0
    fi
    echo "unexpected fake opam pin command: $*" >&2
    exit 2
    ;;
  install)
    shift
    printf 'install %s\n' "$*" >> "${OPAM_FAKE_CALLS:?}"
    ;;
  *)
    echo "unexpected fake opam command: $*" >&2
    exit 2
    ;;
esac
FAKE_OPAM
chmod +x "${FAKE_BIN}/opam"

run_pin_script() {
  env \
    PATH="${FAKE_BIN}:${PATH}" \
    OPAM_FAKE_CALLS="${CALLS_FILE}" \
    MASC_AGENT_SDK_FLOOR_PATH="${FLOOR_FILE}" \
    MASC_SKIP_OPAM_LOCK=1 \
    "$@"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "${needle}" "${file}"; then
    echo "FAIL: expected ${file} to contain: ${needle}" >&2
    echo "--- ${file} ---" >&2
    cat "${file}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq "${needle}" "${file}"; then
    echo "FAIL: expected ${file} not to contain: ${needle}" >&2
    echo "--- ${file} ---" >&2
    cat "${file}" >&2
    exit 1
  fi
}

: > "${CALLS_FILE}"
rm -f "${FLOOR_FILE}"
if run_pin_script FAKE_AGENT_SDK_VERSION=999.999.999 bash "${PIN_SCRIPT}" >"${TMP}/case1.out" 2>"${TMP}/case1.err"; then
  echo "FAIL case 1: stale branch downgrade should be rejected" >&2
  exit 1
fi
assert_contains "${TMP}/case1.err" "refusing to downgrade installed agent_sdk 999.999.999"
assert_not_contains "${CALLS_FILE}" "pin add agent_sdk"
echo "ok case 1 - newer installed agent_sdk is not downgraded"

: > "${CALLS_FILE}"
printf '999.999.999\n' > "${FLOOR_FILE}"
if run_pin_script FAKE_AGENT_SDK_VERSION="${OAS_AGENT_SDK_MIN_VERSION}" bash "${PIN_SCRIPT}" >"${TMP}/case2.out" 2>"${TMP}/case2.err"; then
  echo "FAIL case 2: recorded floor downgrade should be rejected" >&2
  exit 1
fi
assert_contains "${TMP}/case2.err" "refusing to downgrade agent_sdk below recorded floor 999.999.999"
assert_not_contains "${CALLS_FILE}" "pin add agent_sdk"
echo "ok case 2 - recorded floor blocks stale worktree downgrade"

: > "${CALLS_FILE}"
printf '999.999.999\n' > "${FLOOR_FILE}"
run_pin_script FAKE_AGENT_SDK_VERSION=999.999.999 MASC_ALLOW_OAS_PIN_DOWNGRADE=1 bash "${PIN_SCRIPT}" >"${TMP}/case3.out" 2>"${TMP}/case3.err"
assert_contains "${CALLS_FILE}" "pin add agent_sdk"
if [[ "$(cat "${FLOOR_FILE}")" != "999.999.999" ]]; then
  echo "FAIL case 3: rollback override should not lower the recorded floor" >&2
  exit 1
fi
echo "ok case 3 - explicit rollback override permits the pin without lowering the floor"

: > "${CALLS_FILE}"
rm -f "${FLOOR_FILE}"
run_pin_script FAKE_AGENT_SDK_VERSION="${OAS_AGENT_SDK_MIN_VERSION}" bash "${PIN_SCRIPT}" >"${TMP}/case4.out" 2>"${TMP}/case4.err"
assert_contains "${CALLS_FILE}" "pin add agent_sdk"
if [[ "$(cat "${FLOOR_FILE}")" != "${OAS_AGENT_SDK_MIN_VERSION}" ]]; then
  echo "FAIL case 4: expected recorded floor ${OAS_AGENT_SDK_MIN_VERSION}, got $(cat "${FLOOR_FILE}" 2>/dev/null || true)" >&2
  exit 1
fi
echo "ok case 4 - equal installed version permits normal pinning and records the floor"

: > "${CALLS_FILE}"
rm -f "${FLOOR_FILE}"
if run_pin_script \
  FAKE_AGENT_SDK_VERSION=999.999.999 \
  AGENT_SDK_PIN_URL=git@local:agent-sdk-old.git \
  bash "${PIN_SCRIPT}" >"${TMP}/case5.out" 2>"${TMP}/case5.err"; then
  echo "FAIL case 5: AGENT_SDK_PIN_URL downgrade should still be rejected" >&2
  exit 1
fi
assert_contains "${TMP}/case5.err" "refusing to downgrade installed agent_sdk 999.999.999"
assert_contains "${TMP}/case5.err" "branch pin source: git@local:agent-sdk-old.git"
assert_not_contains "${CALLS_FILE}" "pin add agent_sdk"
echo "ok case 5 - AGENT_SDK_PIN_URL does not bypass downgrade protection"

: > "${CALLS_FILE}"
printf '999.999.999\n' > "${FLOOR_FILE}"
run_pin_script \
  FAKE_AGENT_SDK_VERSION=999.999.999 \
  AGENT_SDK_PIN_URL=git@local:agent-sdk-old.git \
  MASC_ALLOW_OAS_PIN_DOWNGRADE=1 \
  bash "${PIN_SCRIPT}" >"${TMP}/case6.out" 2>"${TMP}/case6.err"
assert_contains "${CALLS_FILE}" "pin add agent_sdk git@local:agent-sdk-old.git"
if [[ "$(cat "${FLOOR_FILE}")" != "999.999.999" ]]; then
  echo "FAIL case 6: AGENT_SDK_PIN_URL rollback override should not lower the recorded floor" >&2
  exit 1
fi
echo "ok case 6 - explicit rollback override permits AGENT_SDK_PIN_URL without lowering the floor"

case7_err="${TMP}/case7.err"
: > "${CALLS_FILE}"
rm -f "${FLOOR_FILE}"
if run_pin_script \
  FAKE_OPAM_LIST_FAIL=1 \
  FAKE_OPAM_SHOW_VERSION=999.999.999 \
  bash "${PIN_SCRIPT}" >"${TMP}/case7.out" 2>"${case7_err}"; then
  echo "FAIL case 7: opam list inspection failure should fail closed" >&2
  exit 1
fi
assert_contains "${case7_err}" "failed to inspect installed agent_sdk via opam list"
assert_contains "${case7_err}" "refusing to mutate agent_sdk pin because installed version could not be determined"
assert_not_contains "${CALLS_FILE}" "pin add agent_sdk"
echo "ok case 7 - opam inspection failure fails closed"

: > "${CALLS_FILE}"
rm -f "${FLOOR_FILE}"
if run_pin_script \
  FAKE_AGENT_SDK_LIST_OUTPUT=$'other_pkg 1.0.0\n' \
  FAKE_OPAM_SHOW_VERSION=999.999.999 \
  bash "${PIN_SCRIPT}" >"${TMP}/case8.out" 2>"${TMP}/case8.err"; then
  echo "FAIL case 8: opam show fallback should still block a newer installed version" >&2
  exit 1
fi
assert_contains "${TMP}/case8.err" "refusing to downgrade installed agent_sdk 999.999.999"
assert_not_contains "${CALLS_FILE}" "pin add agent_sdk"
echo "ok case 8 - opam show fallback preserves installed-version protection"

: > "${CALLS_FILE}"
rm -f "${FLOOR_FILE}"
if run_pin_script \
  FAKE_AGENT_SDK_LIST_OUTPUT=$'other_pkg 1.0.0\n' \
  FAKE_OPAM_SHOW_FAIL=1 \
  bash "${PIN_SCRIPT}" >"${TMP}/case9.out" 2>"${TMP}/case9.err"; then
  echo "FAIL case 9: unexpected opam show failure should fail closed" >&2
  exit 1
fi
assert_contains "${TMP}/case9.err" "failed to inspect installed agent_sdk via opam show"
assert_contains "${TMP}/case9.err" "refusing to mutate agent_sdk pin because installed version could not be determined"
assert_not_contains "${CALLS_FILE}" "pin add agent_sdk"
echo "ok case 9 - unexpected opam show failure fails closed"

: > "${CALLS_FILE}"
rm -f "${FLOOR_FILE}"
run_pin_script \
  FAKE_AGENT_SDK_LIST_OUTPUT=$'other_pkg 1.0.0\n' \
  FAKE_OPAM_SHOW_MISSING=1 \
  bash "${PIN_SCRIPT}" >"${TMP}/case10.out" 2>"${TMP}/case10.err"
assert_contains "${CALLS_FILE}" "pin add agent_sdk"
recorded_floor="$(head -n 1 "${FLOOR_FILE}" 2>/dev/null || true)"
if [[ "${recorded_floor}" != "${OAS_AGENT_SDK_MIN_VERSION}" ]]; then
  echo "FAIL case 10: fresh switch should record floor ${OAS_AGENT_SDK_MIN_VERSION}, got ${recorded_floor}" >&2
  exit 1
fi
echo "ok case 10 - fresh switch without installed agent_sdk permits initial pinning"

echo ""
echo "[opam-pin-downgrade-guard test] PASS - 10/10 cases"
