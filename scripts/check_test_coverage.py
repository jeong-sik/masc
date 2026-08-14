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

import json
import os
from pathlib import Path, PurePosixPath
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

NON_CODE_SUFFIXES_PATH = (
    Path(__file__).resolve().parents[1] / ".ci/test-coverage-non-code-suffixes.txt"
)


def load_non_code_suffixes(path=NON_CODE_SUFFIXES_PATH):
    """Load repo policy for assets that should not trigger the coverage gate."""
    suffixes = []
    for line_no, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith(".") or "/" in line or "\\" in line:
            raise ValueError(f"{path}:{line_no}: invalid non-code suffix {line!r}")
        suffixes.append(line.lower())
    return frozenset(suffixes)


NON_CODE_SUFFIXES = load_non_code_suffixes()

# Build configuration under covered paths. These have no suffix, so the
# suffix policy in .ci/test-coverage-non-code-suffixes.txt cannot express
# them, and they are exactly what is_covered_code_file's docstring excludes:
# no unit test can exercise a dune stanza. Without this, a PR that adds a
# compiler flag to four libraries' dune files is asked for tests.
BUILD_CONFIG_NAMES = frozenset({"dune", "dune-project", "dune-workspace"})

DEPENDENCY_LOCKFILE_NAMES = frozenset(
    {"bun.lock", "bun.lockb", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"}
)
DEPENDENCY_MANIFEST_FIELDS = frozenset(
    {
        "bundleDependencies",
        "bundledDependencies",
        "dependencies",
        "devDependencies",
        "optionalDependencies",
        "overrides",
        "peerDependencies",
        "peerDependenciesMeta",
        "pnpm",
        "resolutions",
    }
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
        print(
            f"::error::Test coverage check cannot diff against the base ref: {e.stderr.strip()}"
        )
        print(
            "::error::Refusing to report a pass without seeing the diff (checkout needs fetch-depth: 0)."
        )
        sys.exit(2)


def read_json_at_revision(revision, path):
    """Read one JSON object exactly as committed at revision:path.

    Missing files, invalid JSON, and non-object roots are not dependency-only:
    the coverage gate must keep treating an unclassified manifest change as
    product code rather than silently exempting it.
    """
    try:
        result = subprocess.run(
            ["git", "show", f"{revision}:{path}"],
            capture_output=True,
            text=True,
            check=True,
        )
        value = json.loads(result.stdout)
        return value if isinstance(value, dict) else None
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def is_dependency_metadata_only(path):
    """Return true only for generated lockfiles or dependency-only manifests.

    package.json remains covered when scripts, exports, runtime metadata, or
    any other non-dependency field changes. This is a structural JSON
    comparison, not a branch-name, author, or diff-text heuristic.
    """
    normalized = PurePosixPath(path.replace("\\", "/"))
    if normalized.name in DEPENDENCY_LOCKFILE_NAMES:
        return True
    if normalized.name != "package.json":
        return False

    base = read_json_at_revision(f"origin/{base_ref()}", path)
    head = read_json_at_revision("HEAD", path)
    if base is None or head is None or base == head:
        return False

    def without_dependencies(manifest):
        return {
            key: value
            for key, value in manifest.items()
            if key not in DEPENDENCY_MANIFEST_FIELDS
        }

    return without_dependencies(base) == without_dependencies(head)


def get_changed_covered_files():
    """Get list of covered code files changed in this PR."""
    stdout = run_diff_or_fail(
        ["git", "diff", "--name-only", pr_diff_range(), "--", *COVERED_CODE_PATHS]
    )
    return [
        f
        for f in stdout.strip().split("\n")
        if f and is_covered_code_file(f) and not is_dependency_metadata_only(f)
    ]


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
    files; this negatively filters non-executable assets (CSS/HTML/MD/images,
    and build configuration such as dune) that no unit test can exercise, so
    they do not trigger the "added covered lines with no test" rule.
    See #23083.
    """
    normalized = PurePosixPath(path.replace("\\", "/"))
    if normalized.name in BUILD_CONFIG_NAMES:
        return False
    return normalized.suffix.lower() not in NON_CODE_SUFFIXES


def get_changed_test_files():
    """Get list of test files changed in this PR.

    Uses a path predicate so production modules such as capability checks
    or validators cannot self-satisfy the coverage requirement.
    """
    stdout = run_diff_or_fail(["git", "diff", "--name-only", pr_diff_range()])
    return [f for f in stdout.strip().split("\n") if f and is_test_file(f)]


OCAML_SUFFIXES = {".ml", ".mli"}
SLASH_COMMENT_SUFFIXES = {".ts", ".tsx", ".js", ".jsx", ".css", ".scss"}
# Config formats stay covered on purpose (see
# .ci/test-coverage-non-code-suffixes.txt), and a runtime binding is where the
# reason for a value belongs. Without this the gate counted every explanatory
# line as new code, so writing down why a number changed cost more than
# changing it silently.
HASH_COMMENT_SUFFIXES = {".toml"}


def comment_line_numbers(text, suffix):
    """1-indexed lines of [text] that hold nothing but comment.

    A line counts only when every non-blank character on it is inside a
    comment, so `let x = 1 (* note *)` stays code. OCaml block comments nest,
    which a regex cannot track — the depth counter is why this reads the file
    rather than the diff hunk: a continuation line in the middle of a block
    carries no marker of its own, and those are most of a docstring.
    """
    if suffix in OCAML_SUFFIXES:
        openers, closers, line_comment = ["(*"], ["*)"], None
    elif suffix in SLASH_COMMENT_SUFFIXES:
        openers, closers, line_comment = ["/*"], ["*/"], "//"
    elif suffix in HASH_COMMENT_SUFFIXES:
        openers, closers, line_comment = [], [], "#"
    else:
        return set()

    comment_only = set()
    depth = 0
    for lineno, line in enumerate(text.split("\n"), 1):
        saw_code = False
        i = 0
        while i < len(line):
            two = line[i : i + 2]
            if (
                depth == 0
                and line_comment
                and line[i : i + len(line_comment)] == line_comment
            ):
                break  # rest of the line is comment
            if two in openers:
                depth += 1
                i += 2
                continue
            if depth > 0 and two in closers:
                depth -= 1
                i += 2
                continue
            if depth == 0 and not line[i].isspace():
                saw_code = True
            i += 1
        if not saw_code:
            comment_only.add(lineno)
    return comment_only


def added_line_numbers(path):
    """1-indexed new-file line numbers this PR added to [path]."""
    stdout = run_diff_or_fail(["git", "diff", "-U0", pr_diff_range(), "--", path])
    added, cursor = [], 0
    for line in stdout.split("\n"):
        if line.startswith("@@"):
            try:
                cursor = int(line.split("+", 1)[1].split(",", 1)[0].split(" ", 1)[0])
            except (IndexError, ValueError):
                cursor = 0
            continue
        if cursor and line.startswith("+") and not line.startswith("+++"):
            added.append(cursor)
            cursor += 1
    return added


def get_added_lines_count(files):
    """Count added lines that are not comment.

    A documentation-only change to an .mli is entirely comment, so counting raw
    `+` lines made this rule unsatisfiable for it: the only way out was the
    manual opt-out marker, used once in the last 200 commits. A gate that fires
    on changes it cannot be satisfied by teaches readers to merge past it.
    """
    total = 0
    for f in files:
        try:
            content = subprocess.run(
                ["git", "show", f"HEAD:{f}"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout
        except subprocess.CalledProcessError:
            content = ""
        comments = comment_line_numbers(content, PurePosixPath(f).suffix.lower())
        total += sum(1 for n in added_line_numbers(f) if n not in comments)
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
