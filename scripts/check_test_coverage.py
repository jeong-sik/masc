#!/usr/bin/env python3
"""Test coverage check for PRs modifying source directories.

Checks that code changes to lib/, dashboard/, or config/ have accompanying test changes.

Rules (checked for every non-skipped PR that touches src paths):
- added_src_lines > 10 && test_files == 0 -> warn (enforced)
- src_changed_files > 3 && test_files == 0 -> warn (enforced)

Opt-out mechanisms (checked in order):
1. Branch name contains "ci-skip" — workflow if: guard
2. PR body contains "# ci:skip-test-coverage" — workflow if: guard + script defense-in-depth
3. Any PR commit message contains "# ci:skip-test-coverage" — script-level check
"""

import os
import subprocess
import sys

SRC_PATHS = ["lib/", "dashboard/", "config/"]


def _git(args, check=True):
    """Run git command and return stdout."""
    result = subprocess.run(
        ["git"] + args, capture_output=True, text=True, check=check
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, args, result.stdout, result.stderr)
    return result


def is_any_commit_opt_out():
    """Check if any PR commit message contains opt-out marker."""
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    try:
        # List all commit messages in the PR range
        result = _git(["log", f"origin/{base_ref}...HEAD", "--format=%s%n%b"])
        return "# ci:skip-test-coverage" in result.stdout.lower()
    except subprocess.CalledProcessError:
        # Fall back to single-commit check
        try:
            result = _git(["log", "-1", "--format=%s%n%b"])
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


def get_changed_src_files():
    """Get list of source files changed in this PR across all src paths."""
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    stdout = run_diff_or_fail(
        ["git", "diff", "--name-only", f"origin/{base_ref}...HEAD", "--"] + SRC_PATHS
    )
    return [f for f in stdout.strip().split("\n") if f]


def get_changed_test_files():
    """Get list of test files changed in this PR.

    Discovers test files by scanning the diff for patterns:
    - Paths under test/ or src/test/ directories
    - Files named *_test.ml, *_spec.ml, test_*.ml, *_check.ml, *_coverage.ml
    """
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    stdout = run_diff_or_fail(
        ["git", "diff", "--name-only", f"origin/{base_ref}...HEAD"]
    )
    all_changed = [f for f in stdout.strip().split("\n") if f]

    # Match test files by path or name pattern
    test_files = []
    for f in all_changed:
        if f.startswith("test/"):
            test_files.append(f)
            continue
        # Check file name for test patterns
        basename = os.path.basename(f)
        if any(basename.startswith(p) or basename.endswith(s) for p, s in
               [("test_", ""), ("check_", ""), ("", "_test"), ("", "_spec"),
                ("", "_check"), ("", "_coverage"), ("", "_validator")]):
            test_files.append(f)
        # Also catch files inside any test/ segment of the path
        parts = f.split("/")
        if "test" in parts and parts.index("test") < len(parts) - 1:
            test_files.append(f)

    return sorted(set(test_files))


def get_added_lines_count(src_files):
    """Count added lines in changed source files."""
    base_ref = os.environ.get("GITHUB_BASE_REF", "main")
    total = 0
    for f in src_files:
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

    # Check ALL PR commits for opt-out (not just the latest)
    if is_any_commit_opt_out():
        print("Skipped: opt-out via commit message (all commits checked)")
        sys.exit(0)

    src_files = get_changed_src_files()
    test_files = get_changed_test_files()
    added_lines = get_added_lines_count(src_files)

    violations = []

    if added_lines > 10 and len(test_files) == 0:
        violations.append(
            f"Added {added_lines} lines to source files but no test files changed."
        )
    if len(src_files) > 3 and len(test_files) == 0:
        violations.append(
            f"Changed {len(src_files)} source files but no test files changed."
        )

    print(f"Source files changed: {len(src_files)} ({added_lines} new lines)")
    print(f"Test files changed:   {len(test_files)}")
    if test_files:
        for tf in test_files[:10]:
            print(f"  - {tf}")
        if len(test_files) > 10:
            print(f"  ... ({len(test_files) - 10} more)")

    if violations:
        for v in violations:
            print(f"::warning::Test coverage: {v}")
        sys.exit(1)

    print("Test coverage check passed.")


if __name__ == "__main__":
    check_coverage()