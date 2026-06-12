#!/usr/bin/env python3
"""Test coverage check for PRs modifying lib/.

Checks that code changes to lib/ have accompanying test changes.

Rules (checked for every non-skipped PR that touches lib/):
- added_lib_lines > 10 && test_files == 0 -> warn (enforced)
- lib_changed_files > 3 && test_files == 0 -> warn (enforced)

Opt-out mechanisms (checked in order):
1. Branch name contains "ci-skip" — workflow if: guard
2. PR body contains "# ci:skip-test-coverage" — workflow if: guard + script defense-in-depth
3. Commit message contains "# ci:skip-test-coverage" — script-level check
"""

import os
import subprocess
import sys


def is_opt_out_commit():
    """Check if any PR commit message contains opt-out marker.

    Scans all commits in the PR range (origin/BASE_REF...HEAD) so that
    a single opt-out commit in a multi-commit PR does not bypass the
    check for earlier commits (edge case: opt-out buried in the last
    commit while substantive changes sit in earlier commits).
    Falls back to the latest commit alone when the base ref is
    unavailable (local runs outside CI).
    """
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    try:
        result = subprocess.run(
            ["git", "log", f"origin/{base_ref}...HEAD", "--format=%s%n%b"],
            capture_output=True,
            text=True,
            check=True,
        )
        return "# ci:skip-test-coverage" in result.stdout.lower()
    except subprocess.CalledProcessError:
        try:
            result = subprocess.run(
                ["git", "log", "-1", "--format=%s%n%b"],
                capture_output=True,
                text=True,
                check=True,
            )
            return "# ci:skip-test-coverage" in result.stdout.lower()
        except subprocess.CalledProcessError:
            return False


def run_diff_or_fail(args):
    """Run a git diff; a failure means the check cannot see the PR's
    changes (shallow clone, missing base ref), which must fail the job
    loudly — an empty result here would silently pass every PR."""
    try:
        return subprocess.run(
            args,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except subprocess.CalledProcessError as e:
        print(f"::error::Test coverage check cannot diff against the base ref: {e.stderr.strip()}")
        print("::error::Refusing to report a pass without seeing the diff (checkout needs fetch-depth: 0).")
        sys.exit(2)


def get_changed_lib_files():
    """Get list of lib/ files changed in this PR."""
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    stdout = run_diff_or_fail(
        ["git", "diff", "--name-only", f"origin/{base_ref}...HEAD", "--", "lib/"]
    )
    return [f for f in stdout.strip().split("\n") if f]


def get_changed_test_files():
    """Get list of test files changed in this PR.

    Uses multiple pathspec globs to catch common OCaml test file naming
    conventions: *test*, *spec*, *check_*, *validator*, and test/
    directories.
    """
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    stdout = run_diff_or_fail(
        [
            "git",
            "diff",
            "--name-only",
            f"origin/{base_ref}...HEAD",
            "--",
            "*test*",
            "*spec*",
            "*check_*",
            "*validator*",
            "**/test/",
        ]
    )
    return [f for f in stdout.strip().split("\n") if f]


def get_added_lines_count(lib_files):
    """Count added lines in lib/ files."""
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    total = 0
    for f in lib_files:
        stdout = run_diff_or_fail(["git", "diff", f"origin/{base_ref}...HEAD", "--", f])
        for line in stdout.split("\n"):
            if line.startswith("+") and not line.startswith("+++"):
                total += 1
    return total


def check_coverage():
    # Defense-in-depth: check PR_BODY for opt-out
    # (also guarded by workflow-level if:, but this catches edge cases)
    pr_body = os.environ.get("PR_BODY", "")
    if "# ci:skip-test-coverage" in pr_body.lower():
        print("Skipped: opt-out via PR body")
        sys.exit(0)

    # Check commit message for opt-out
    if is_opt_out_commit():
        print("Skipped: opt-out via commit message")
        sys.exit(0)

    lib_files = get_changed_lib_files()
    test_files = get_changed_test_files()
    added_lines = get_added_lines_count(lib_files)

    violations = []

    if added_lines > 10 and len(test_files) == 0:
        violations.append(
            f"Added {added_lines} lines to lib/ but no test files changed. "
            f"Add tests to cover new functionality."
        )

    if len(lib_files) > 3 and len(test_files) == 0:
        violations.append(
            f"Changed {len(lib_files)} files in lib/ but no test files changed. "
            f"Consider adding tests for at least the critical paths."
        )

    if violations:
        print("::error::Test Coverage Check Failed")
        for v in violations:
            print(f"::error::{v}")
        sys.exit(1)
    else:
        print("Test coverage check passed.")
        sys.exit(0)


if __name__ == "__main__":
    check_coverage()
