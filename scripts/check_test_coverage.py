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
    """Check if the latest commit message contains opt-out marker."""
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


def get_changed_lib_files():
    """Get list of lib/ files changed in this PR."""
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", f"origin/{base_ref}...HEAD", "--", "lib/"],
            capture_output=True,
            text=True,
            check=True,
        )
        return [f for f in result.stdout.strip().split("\n") if f]
    except subprocess.CalledProcessError:
        return []


def get_changed_test_files():
    """Get list of test files changed in this PR."""
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    try:
        result = subprocess.run(
            [
                "git",
                "diff",
                "--name-only",
                f"origin/{base_ref}...HEAD",
                "--",
                "*test*",
                "*/test*",
                "*_test*",
                "*spec*",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        return [f for f in result.stdout.strip().split("\n") if f]
    except subprocess.CalledProcessError:
        return []


def get_added_lines_count(lib_files):
    """Count added lines in lib/ files."""
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    total = 0
    for f in lib_files:
        try:
            result = subprocess.run(
                ["git", "diff", f"origin/{base_ref}...HEAD", "--", f],
                capture_output=True,
                text=True,
                check=True,
            )
            for line in result.stdout.split("\n"):
                if line.startswith("+") and not line.startswith("+++"):
                    total += 1
        except subprocess.CalledProcessError:
            pass
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
        print("::warning::Test Coverage Check Failed")
        for v in violations:
            print(f"::warning::{v}")
        sys.exit(1)
    else:
        print("Test coverage check passed.")
        sys.exit(0)


if __name__ == "__main__":
    check_coverage()