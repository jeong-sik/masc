#!/usr/bin/env python3
"""Test coverage check for PRs modifying covered code paths.

Checks that code changes to covered paths have accompanying test changes.

Rules (checked for every non-skipped PR that touches covered code paths):
- added_code_lines > 10 && test_files == 0 -> warn (enforced)
- changed_code_files > 3 && added_code_lines > 0 && test_files == 0 -> warn (enforced)

Opt-out mechanisms (checked in order):
1. Branch name contains "ci-skip" — workflow if: guard
2. PR body contains "# ci:skip-test-coverage" — workflow if: guard + script defense-in-depth
3. Commit message contains "# ci:skip-test-coverage" — script-level check
"""

import os
import subprocess
import sys


COVERED_CODE_PATHS = ("lib/", "dashboard/", "config/")
TEST_DIR_NAMES = {"test", "tests"}
TEST_FILE_PREFIXES = ("test_",)
TEST_FILE_SUFFIXES = (
    "_test.ml",
    "_tests.ml",
    "_test.py",
    "_tests.py",
    "_test.ts",
    "_tests.ts",
    "_test.tsx",
    "_tests.tsx",
    "_spec.ml",
    "_spec.py",
    "_spec.ts",
    "_spec.tsx",
)
TEST_FILE_INFIXES = (".test.", ".spec.")

# Non-executable assets under covered paths that no unit test can exercise.
# Counting their added lines produces false positives — e.g. a dashboard CSS
# height fix (#23082) was flagged as "covered code with no test". Scope is
# intentionally narrow: only unambiguous assets. Config/data formats
# (.toml/.json/.yml) are out of scope here (they have their own validity gates)
# and stay covered. See #23083.
NON_CODE_SUFFIXES = (
    ".css", ".html", ".htm", ".md", ".markdown",
    ".svg", ".png", ".jpg", ".jpeg", ".webp", ".ico", ".gif",
)


def base_ref():
    return os.environ.get("GITHUB_BASE_REF", "main")


def pr_diff_range():
    return f"origin/{base_ref()}...HEAD"


def pr_commit_range():
    return f"origin/{base_ref()}..HEAD"


def is_opt_out_commit():
    """Check if any PR commit message contains opt-out marker.

    Scans PR-side commits only (origin/BASE_REF..HEAD) so base-only
    commits cannot opt a stale PR out of the coverage gate.
    Falls back to the latest commit alone when the base ref is
    unavailable (local runs outside CI).
    """
    try:
        result = subprocess.run(
            ["git", "log", pr_commit_range(), "--format=%s%n%b"],
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


def get_changed_covered_files():
    """Get list of covered code files changed in this PR."""
    stdout = run_diff_or_fail(
        ["git", "diff", "--name-only", pr_diff_range(), "--", *COVERED_CODE_PATHS]
    )
    return [f for f in stdout.strip().split("\n") if f and is_covered_code_file(f)]


def is_test_file(path):
    """Return true for actual test paths, not production check/validator code."""
    normalized = path.replace("\\", "/")
    parts = [p for p in normalized.split("/") if p]
    if any(part in TEST_DIR_NAMES for part in parts[:-1]):
        return True
    if not parts:
        return False
    basename = parts[-1]
    return (
        basename.startswith(TEST_FILE_PREFIXES)
        or basename.endswith(TEST_FILE_SUFFIXES)
        or any(infix in basename for infix in TEST_FILE_INFIXES)
    )


def is_covered_code_file(path):
    """Return true for executable code files, filtering out non-code assets.

    Symmetric counterpart to is_test_file: that positively identifies test
    files; this negatively filters non-executable assets (CSS/HTML/MD/images)
    that no unit test can exercise, so they do not trigger the "added covered
    lines with no test" rule. See #23083.
    """
    normalized = path.replace("\\", "/").lower()
    return not normalized.endswith(NON_CODE_SUFFIXES)


def get_changed_test_files():
    """Get list of test files changed in this PR.

    Uses a path predicate so production modules such as capability checks
    or validators cannot self-satisfy the coverage requirement.
    """
    stdout = run_diff_or_fail(
        ["git", "diff", "--name-only", pr_diff_range()]
    )
    return [f for f in stdout.strip().split("\n") if f and is_test_file(f)]


def get_added_lines_count(files):
    """Count added lines in changed files."""
    total = 0
    for f in files:
        stdout = run_diff_or_fail(["git", "diff", pr_diff_range(), "--", f])
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

    code_files = get_changed_covered_files()
    test_files = get_changed_test_files()
    added_lines = get_added_lines_count(code_files)

    violations = []

    if added_lines > 10 and len(test_files) == 0:
        violations.append(
            f"Added {added_lines} lines to covered code paths but no test files changed. "
            f"Add tests to cover new functionality."
        )

    if len(code_files) > 3 and len(test_files) == 0 and added_lines > 0:
        violations.append(
            f"Changed {len(code_files)} files in covered code paths but no test files changed. "
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
