#!/usr/bin/env bash
# Fixture test for scripts/ci/check-main-branch-protection.sh consecutive-401
# counter (BRANCH_PROTECTION_UNREADABLE_STATE_FILE):
#   - consecutive bypassed 401s increment the counter and fail closed at the
#     BRANCH_PROTECTION_UNREADABLE_MAX_CONSECUTIVE threshold,
#   - a successful read resets the counter,
#   - an unwritable state file fails closed instead of silently disabling the
#     counter (fail-open),
#   - a non-numeric threshold is rejected instead of crashing later.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO_ROOT/scripts/ci/check-main-branch-protection.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/branch-protection-guard.XXXXXX")"
trap 'chmod -R u+w "$fixture" 2>/dev/null; rm -rf "$fixture"' EXIT

mock_bin="$fixture/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh: MOCK_GH_MODE=401 emits a 401 on `gh api`; otherwise answers the two
# --jq queries the guard issues with valid branch-protection payloads.
if [[ "${MOCK_GH_MODE:-ok}" == "401" ]]; then
  echo "gh: Bad credentials (HTTP 401)" >&2
  exit 1
fi
case "${*}" in
  *enforce_admins*) printf 'true\n' ;;
  *) printf 'CI Gate\n' ;;
esac
MOCK
chmod +x "$mock_bin/gh"

failures=0

run_guard() {
  env \
    PATH="$mock_bin:$PATH" \
    BRANCH_PROTECTION_REPOSITORY="org/repo" \
    BRANCH_PROTECTION_BRANCH="main" \
    BRANCH_PROTECTION_REQUIRED_CONTEXTS="CI Gate" \
    "$@" bash "$GUARD" >/dev/null 2>&1
}

expect_exit() {
  local want="$1" label="$2"
  shift 2
  local got=0
  run_guard "$@" || got=$?
  if [[ "$got" -ne "$want" ]]; then
    echo "FAIL: ${label} (expected exit ${want}, got ${got})" >&2
    failures=$((failures + 1))
  else
    echo "ok: ${label}"
  fi
}

expect_state() {
  local want="$1" label="$2" file="$3"
  local got
  got="$(cat "$file")"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: ${label} (expected state '${want}', got '${got}')" >&2
    failures=$((failures + 1))
  else
    echo "ok: ${label}"
  fi
}

state_file="$fixture/state/consecutive-401"

# 1) Consecutive bypassed 401s increment the counter and fail closed at the
#    default threshold (3).
expect_exit 0 "401 bypass run 1 is permitted" \
  MOCK_GH_MODE=401 BRANCH_PROTECTION_ALLOW_UNREADABLE=1 \
  BRANCH_PROTECTION_UNREADABLE_STATE_FILE="$state_file"
expect_exit 0 "401 bypass run 2 is permitted" \
  MOCK_GH_MODE=401 BRANCH_PROTECTION_ALLOW_UNREADABLE=1 \
  BRANCH_PROTECTION_UNREADABLE_STATE_FILE="$state_file"
expect_exit 1 "401 bypass run 3 fails closed at threshold" \
  MOCK_GH_MODE=401 BRANCH_PROTECTION_ALLOW_UNREADABLE=1 \
  BRANCH_PROTECTION_UNREADABLE_STATE_FILE="$state_file"
expect_state 3 "counter reached threshold" "$state_file"

# 2) A successful read resets the counter.
expect_exit 0 "successful read passes" \
  BRANCH_PROTECTION_UNREADABLE_STATE_FILE="$state_file"
expect_state 0 "counter reset after success" "$state_file"

# 3) An unwritable state file must fail closed instead of letting the counter
#    reset to 1 every run (fail-open). Requires a non-root user for chmod to
#    actually block writes.
if [[ $EUID -ne 0 ]]; then
  readonly_dir="$fixture/readonly"
  mkdir -p "$readonly_dir"
  chmod 0555 "$readonly_dir"
  expect_exit 1 "unwritable state file fails closed" \
    MOCK_GH_MODE=401 BRANCH_PROTECTION_ALLOW_UNREADABLE=1 \
    BRANCH_PROTECTION_UNREADABLE_STATE_FILE="$readonly_dir/consecutive-401"
  chmod 0755 "$readonly_dir"
else
  echo "skip: unwritable-state-file scenario requires non-root"
fi

# 4) A non-numeric threshold is rejected up front instead of crashing with an
#    unbound-variable error inside the counter.
expect_exit 1 "non-numeric max-consecutive rejected" \
  MOCK_GH_MODE=401 BRANCH_PROTECTION_ALLOW_UNREADABLE=1 \
  BRANCH_PROTECTION_UNREADABLE_STATE_FILE="$state_file" \
  BRANCH_PROTECTION_UNREADABLE_MAX_CONSECUTIVE="abc"

# 5) 401 without bypass still fails closed.
expect_exit 1 "401 without bypass fails" MOCK_GH_MODE=401

if ((failures > 0)); then
  echo "branch protection counter fixture: ${failures} failure(s)" >&2
  exit 1
fi
echo "branch protection counter fixture: OK"
