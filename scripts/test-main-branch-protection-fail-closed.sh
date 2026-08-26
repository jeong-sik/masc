#!/usr/bin/env bash
# Fixture test for scripts/ci/check-main-branch-protection.sh.
#
# The guard's whole point is that it fails closed: a branch-protection audit
# it could not perform must not read as an audit that passed. Every exit path
# below used to have an opt-in bypass (BRANCH_PROTECTION_ALLOW_UNREADABLE and
# its consecutive-401 counter) that no caller ever set, so the bypass was
# removed. These cases pin what replaced it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/ci/check-main-branch-protection.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Stands in for the GitHub CLI. MOCK_GH_MODE picks which API outcome the
# guard has to handle.
cat >"$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "${MOCK_GH_MODE:-ok}" in
  401) echo "gh: Requires authentication (HTTP 401)" >&2; exit 1 ;;
  403) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
  missing_context) printf 'context=Some Other Check\nstrict=true\nenforce_admins=true\n'; exit 0 ;;
  strict_false) printf 'context=CI Gate\nstrict=false\nenforce_admins=true\n'; exit 0 ;;
  strict_unreadable) printf 'context=CI Gate\nstrict=unreadable\nenforce_admins=true\n'; exit 0 ;;
  admin_false) printf 'context=CI Gate\nstrict=true\nenforce_admins=false\n'; exit 0 ;;
  admin_unreadable) printf 'context=CI Gate\nstrict=true\nenforce_admins=unreadable\n'; exit 0 ;;
  ok) printf 'context=CI Gate\nstrict=true\nenforce_admins=true\n'; exit 0 ;;
  *) echo "unknown MOCK_GH_MODE" >&2; exit 2 ;;
esac
MOCK
chmod +x "$work/bin/gh"

failures=0

expect_exit() {
  local label="$1" expected="$2" mode="$3"
  shift 3
  local actual=0
  env PATH="$work/bin:$PATH" MOCK_GH_MODE="$mode" \
    BRANCH_PROTECTION_REPOSITORY="owner/repo" \
    BRANCH_PROTECTION_BRANCH="main" \
    BRANCH_PROTECTION_REQUIRED_CONTEXTS="CI Gate" \
    "$@" bash "$GUARD" >"$work/out" 2>&1 || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: ${label}: expected exit ${expected}, got ${actual}"
    sed 's/^/    /' "$work/out"
    failures=$((failures + 1))
    return
  fi
  echo "ok: ${label} (exit ${actual})"
}

expect_output() {
  local label="$1" expected="$2"
  if ! grep -Fq "$expected" "$work/out"; then
    echo "FAIL: ${label}: missing output: ${expected}"
    sed 's/^/    /' "$work/out"
    failures=$((failures + 1))
    return
  fi
  echo "ok: ${label}"
}

# An unreadable audit is not a passing audit.
expect_exit "401 fails closed" 1 401
expect_exit "403 fails closed" 1 403

# The bypass is gone rather than merely off by default: setting the variable
# that used to enable it changes nothing.
expect_exit "retired bypass variable does not reopen 401" 1 401 \
  BRANCH_PROTECTION_ALLOW_UNREADABLE=1
expect_exit "retired bypass variable does not reopen 403" 1 403 \
  BRANCH_PROTECTION_ALLOW_UNREADABLE=1

# The drift the guard exists to catch: main no longer requires CI Gate, which
# is what lets an unchecked merge land.
expect_exit "absent required context is drift" 1 missing_context

# The merge gate applies only if branches are current and admins cannot bypass
# it. Both are required policy now; a missing field is an unreadable audit.
expect_exit "admin enforcement enabled passes" 0 ok
expect_output "enabled admin state reaches final status" "admin enforcement: enabled"

expect_exit "non-strict required checks fail" 1 strict_false
expect_output "non-strict state names stale-base bypass" "required status checks are not strict"

expect_exit "unreadable strict setting fails closed" 1 strict_unreadable
expect_output "unreadable strict state names the failed field" "required_status_checks.strict is unreadable"

expect_exit "disabled admin enforcement fails" 1 admin_false
expect_output "disabled admin state names bypass" "admin enforcement is disabled"

expect_exit "unreadable admin enforcement fails closed" 1 admin_unreadable
expect_output "unreadable admin state names the failed field" "enforce_admins.enabled is unreadable"

if ((failures > 0)); then
  echo "branch protection fail-closed fixture: ${failures} failure(s)"
  exit 1
fi
echo "branch protection fail-closed fixture: all cases passed"
