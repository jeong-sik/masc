#!/usr/bin/env bash
# Pin the three pieces that make the required CI verdict enforceable.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verdict="$repo_root/.github/workflows/main-ci-verdict.yml"
cleanup="$repo_root/.github/workflows/ci-cancel-closed-pr.yml"
watchdog="$repo_root/scripts/ci/check-main-branch-protection.sh"

assert_contains() {
  local file="$1" literal="$2" label="$3"
  if ! grep -Fq -- "$literal" "$file"; then
    echo "FAIL: $label: missing '$literal' in ${file#"$repo_root/"}"
    exit 1
  fi
  echo "ok: $label"
}

assert_absent() {
  local file="$1" literal="$2" label="$3"
  if grep -Fq -- "$literal" "$file"; then
    echo "FAIL: $label: stale '$literal' remains in ${file#"$repo_root/"}"
    exit 1
  fi
  echo "ok: $label"
}

assert_contains "$verdict" "branches: [main]" \
  "main pushes trigger the merge audit"
assert_contains "$verdict" "github.event_name == 'push' && github.sha" \
  "each pushed merge SHA owns its concurrency key"
assert_contains "$verdict" "python3 scripts/ci/check-merge-audit.py" \
  "the live workflow invokes the verdict guard"
assert_contains "$verdict" "select(.merge_commit_sha == \$sha)" \
  "associated PR resolution matches the exact merge commit"
assert_contains "$cleanup" 'github.event.pull_request.merged == false' \
  "only unmerged closed PRs have CI cancelled"
assert_contains "$watchdog" 'required_status_checks.strict is unreadable' \
  "watchdog fails closed on strict-policy drift"
assert_contains "$watchdog" 'admin enforcement is disabled' \
  "watchdog rejects admin CI bypass"
assert_absent "$repo_root/scripts/ci/run-lint-suite.sh" \
  "patch is applied by an operator" \
  "lint no longer describes a deferred workflow patch"

echo "merge safety wiring fixture: all cases passed"
