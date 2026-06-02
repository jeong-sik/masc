#!/usr/bin/env python3
"""RFC §1 Enforcer and number-collision guard.

§1 mode (default): ensure caller-context completeness in RFC drafts.
  R1: No <!-- TODO --> comments in §1
  R2: At least 3 file:line citations
  R3: At least 1 code block
  R4: No sub-agent placeholder text
  R5: .tmp/rfc-NNNN-caller-context.md companion file exists

--check-numbering mode (RFC-0078): block RFC number collisions.
  Reads PR-added RFC-NNNN-*.md files (added since base ref) and rejects
  any NNNN that already has a different file on the base ref. Multi-phase
  additions opt in via PR body line ``RFC-EXTEND: NNNN`` (env PR_BODY) or
  RFC frontmatter ``extends: "NNNN"``.

--check-ledger-monotonic mode: ensure docs/rfc/.next-number is greater than
  every RFC-NNNN-*.md file currently present in the checkout.

Usage:
    python scripts/rfc_enforcer.py --check docs/rfc/
    python scripts/rfc_enforcer.py --check docs/rfc/ --strict
    python scripts/rfc_enforcer.py --check-numbering \
        --base-ref origin/main --head-ref HEAD
    python scripts/rfc_enforcer.py --check-ledger-monotonic

Exit codes:
    0 — all checks pass
    1 — one or more violations found
    2 — runtime error
"""

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Set, Tuple


@dataclass(frozen=True)
class Violation:
    file: Path
    line: int
    rule: str
    message: str

    def format(self) -> str:
        return f"  {self.file.name}:{self.line} [{self.rule}] {self.message}"


def _extract_section1(content: str) -> Optional[Tuple[str, int]]:
    """Extract §1 section content and its starting line number.

    Matches from '## §1 Problem' up to but not including '## §2' or end of file.
    """
    match = re.search(r'(## §1\s+.*?)(?=\n## §2|\n## §0|\Z)', content, re.DOTALL)
    if not match:
        return None
    start_line = content[:match.start()].count('\n') + 1
    return match.group(1), start_line


def _count_lines_before(content: str, pos: int, section_start_line: int) -> int:
    """Count line number within the file for a position within section1."""
    return section_start_line + content[:pos].count('\n')


def check_rfc_file(rfc_file: Path, check_tmp_file: bool = True) -> List[Violation]:
    """Check a single RFC file for §1 completeness violations."""
    violations: List[Violation] = []
    content = rfc_file.read_text(encoding="utf-8")

    # Extract §1 section
    section1_result = _extract_section1(content)
    if section1_result is None:
        violations.append(Violation(rfc_file, 0, "NO_SECTION1", "No §1 section found"))
        return violations

    section1, section_start_line = section1_result

    # Rule 1: No TODO comments in §1
    for m in re.finditer(r'<!--\s*TODO', section1, re.IGNORECASE):
        line = _count_lines_before(section1, m.start(), section_start_line)
        violations.append(Violation(rfc_file, line, "R1_NO_TODO", "TODO comment found in §1"))

    # Rule 2: At least 3 file:line citations
    # Pattern: path/to/file.ml:123 or `path/to/file.ml:123` or similar
    citation_pattern = re.compile(
        r'`?[\w/-]+\.(?:ml|mli|dune|toml|json|yml|yaml):\d+`?'
    )
    citations = citation_pattern.findall(section1)
    if len(citations) < 3:
        violations.append(
            Violation(
                rfc_file,
                0,
                "R2_MIN_CITATIONS",
                f"Only {len(citations)} file:line citations found (minimum 3)",
            )
        )

    # Rule 3: At least 1 code block
    code_blocks = re.findall(r'```[\w]*\n', section1)
    if len(code_blocks) < 1:
        violations.append(
            Violation(
                rfc_file, 0, "R3_MIN_CODE_BLOCK", "No code block found in §1"
            )
        )

    # Rule 4: No sub-agent placeholder text
    placeholder_pattern = re.compile(
        r'sub-agent.*(?:통합 영역|pending|TODO|results?.*pending|placeholder)',
        re.IGNORECASE,
    )
    for m in placeholder_pattern.finditer(section1):
        line = _count_lines_before(section1, m.start(), section_start_line)
        violations.append(
            Violation(
                rfc_file,
                line,
                "R4_NO_PLACEHOLDER",
                "Sub-agent placeholder text found in §1",
            )
        )

    # Rule 5: Companion caller-context file exists
    if check_tmp_file:
        # Extract RFC number from filename: RFC-0052-...
        rfc_match = re.search(r'RFC-(\d+)', rfc_file.name)
        if rfc_match:
            rfc_num = rfc_match.group(1)
            # Check for .tmp/rfc-NNNN-caller-context.md or .tmp/rfc-NNNN-p2-caller-context.md
            tmp_dir = rfc_file.parent.parent.parent / ".tmp"
            possible_names = [
                f"rfc-{rfc_num}-caller-context.md",
                f"rfc-{rfc_num}-p2-caller-context.md",
                f"rfc-00{rfc_num}-caller-context.md",
            ]
            found = any((tmp_dir / name).exists() for name in possible_names)
            if not found:
                violations.append(
                    Violation(
                        rfc_file,
                        0,
                        "R5_NO_CALLER_CONTEXT",
                        f"No caller-context file found in .tmp/ for RFC-{rfc_num}",
                    )
                )

    return violations


def check_all_rfcs(rfc_dir: Path, check_tmp_file: bool = True) -> Tuple[List[Violation], int, int]:
    """Check all RFC files in a directory.

    Returns (violations, files_checked, files_passed).
    """
    all_violations: List[Violation] = []
    files_checked = 0
    files_passed = 0

    if not rfc_dir.exists():
        print(f"ERROR: Directory not found: {rfc_dir}", file=sys.stderr)
        sys.exit(2)

    for rfc_file in sorted(rfc_dir.glob("RFC-*.md")):
        files_checked += 1
        violations = check_rfc_file(rfc_file, check_tmp_file)
        if violations:
            all_violations.extend(violations)
        else:
            files_passed += 1

    return all_violations, files_checked, files_passed


_RFC_FILENAME_RE = re.compile(r"^RFC-(\d{4})-[a-zA-Z0-9._-]+\.md$")
_RFC_EXTEND_RE = re.compile(r"^RFC-EXTEND:\s*(\d{4})\s*$", re.MULTILINE)
_FRONTMATTER_EXTENDS_RE = re.compile(
    r'^extends:\s*\[?\s*"?(\d{4})"?\s*\]?\s*$', re.MULTILINE
)


def _git(*args: str) -> str:
    """Run git and return stdout (stripped). Raises on non-zero."""
    result = subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    )
    return result.stdout.strip()


def _added_rfc_files(base_ref: str, head_ref: str) -> List[str]:
    """Return paths of RFC-*.md files added on head vs base."""
    out = _git(
        "diff",
        "--name-only",
        "--diff-filter=A",
        f"{base_ref}...{head_ref}",
        "--",
        "docs/rfc/",
    )
    return [
        line
        for line in out.splitlines()
        if _RFC_FILENAME_RE.match(Path(line).name)
    ]


def _base_rfc_files_for_number(base_ref: str, number: str) -> List[str]:
    """Return paths of RFC-NNNN-*.md files present on base_ref."""
    out = _git("ls-tree", "--name-only", base_ref, "docs/rfc/")
    return [
        line
        for line in out.splitlines()
        if _RFC_FILENAME_RE.match(Path(line).name)
        and Path(line).name.startswith(f"RFC-{number}-")
    ]


def _extends_optin_numbers(pr_body: str, added_files: List[str]) -> Set[str]:
    """Collect numbers that this PR is explicitly extending.

    Two opt-in sources:
      - PR body line ``RFC-EXTEND: NNNN``
      - Frontmatter ``extends: "NNNN"`` in any of the added RFC files
    """
    numbers: Set[str] = set()
    for match in _RFC_EXTEND_RE.finditer(pr_body or ""):
        numbers.add(match.group(1))
    for path in added_files:
        try:
            content = Path(path).read_text(encoding="utf-8")
        except OSError:
            continue
        for match in _FRONTMATTER_EXTENDS_RE.finditer(content):
            numbers.add(match.group(1))
    return numbers


def check_ledger_monotonic(rfc_dir: Path) -> List[Violation]:
    """Return violations when .next-number can allocate an existing RFC number."""
    violations: List[Violation] = []
    ledger = rfc_dir / ".next-number"
    if not ledger.exists():
        return [
            Violation(
                ledger,
                0,
                "RFC_LEDGER_MISSING",
                "RFC ledger file is missing",
            )
        ]

    value = ledger.read_text(encoding="utf-8").strip()
    if re.fullmatch(r"\d{4}", value) is None:
        return [
            Violation(
                ledger,
                1,
                "RFC_LEDGER_INVALID",
                f"RFC ledger value must be a 4-digit number, got: {value!r}",
            )
        ]

    max_existing = 0
    max_name = None
    for rfc_file in rfc_dir.glob("RFC-*.md"):
        match = _RFC_FILENAME_RE.match(rfc_file.name)
        if match is None:
            continue
        number = int(match.group(1), 10)
        if number > max_existing:
            max_existing = number
            max_name = rfc_file.name

    current = int(value, 10)
    if current <= max_existing:
        expected = f"{max_existing + 1:04d}"
        violations.append(
            Violation(
                ledger,
                1,
                "RFC_LEDGER_NOT_MONOTONIC",
                (
                    f"ledger is {value}, but highest existing RFC is "
                    f"{max_existing:04d} ({max_name}); expected at least {expected}"
                ),
            )
        )

    return violations


def check_numbering(base_ref: str, head_ref: str, pr_body: str) -> List[Violation]:
    """Return collision violations for RFC numbers added in this PR."""
    violations: List[Violation] = []
    try:
        added = _added_rfc_files(base_ref, head_ref)
    except subprocess.CalledProcessError as exc:
        msg = exc.stderr.strip() or str(exc)
        return [Violation(Path("git"), 0, "GIT_ERROR", msg)]

    optin = _extends_optin_numbers(pr_body, added)

    for path in added:
        name = Path(path).name
        m = _RFC_FILENAME_RE.match(name)
        if m is None:
            continue
        number = m.group(1)
        try:
            existing = _base_rfc_files_for_number(base_ref, number)
        except subprocess.CalledProcessError:
            existing = []
        if not existing:
            continue
        if number in optin:
            continue
        existing_str = ", ".join(sorted(existing))
        violations.append(
            Violation(
                Path(path),
                0,
                "RFC_NUMBER_COLLISION",
                (
                    f"RFC-{number} already exists on {base_ref}: {existing_str}. "
                    "Allocate next via scripts/rfc-allocate-next.sh, or opt in "
                    f"to multi-phase via PR body 'RFC-EXTEND: {number}' or "
                    f'frontmatter \'extends: "{number}"\'.'
                ),
            )
        )

    return violations


def main() -> int:
    parser = argparse.ArgumentParser(description="RFC §1 Enforcer + number guard")
    parser.add_argument(
        "--check",
        type=Path,
        help="Directory containing RFC files to check (§1 mode)",
    )
    parser.add_argument(
        "--check-numbering",
        action="store_true",
        help="Check for RFC number collisions between PR additions and base ref",
    )
    parser.add_argument(
        "--check-ledger-monotonic",
        action="store_true",
        help="Check that docs/rfc/.next-number is above every existing RFC number",
    )
    parser.add_argument(
        "--rfc-dir",
        type=Path,
        default=Path("docs/rfc"),
        help="RFC directory for --check-ledger-monotonic (default: docs/rfc)",
    )
    parser.add_argument(
        "--base-ref",
        default="origin/main",
        help="Base git ref for --check-numbering (default: origin/main)",
    )
    parser.add_argument(
        "--head-ref",
        default="HEAD",
        help="Head git ref for --check-numbering (default: HEAD)",
    )
    parser.add_argument(
        "--files",
        nargs="+",
        type=Path,
        help="Specific RFC files to check (relative paths)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as failures (fail on any issue)",
    )
    parser.add_argument(
        "--no-tmp-check",
        action="store_true",
        help="Skip R5 (caller-context file existence check)",
    )
    parser.add_argument(
        "--ignore-missing-section1",
        action="store_true",
        help="Ignore NO_SECTION1 violations (grandfathering pre-0052 RFCs)",
    )
    args = parser.parse_args()

    # --check-numbering and --check-ledger-monotonic run independently of --check.
    if args.check_numbering:
        pr_body = os.environ.get("PR_BODY", "")
        violations = check_numbering(args.base_ref, args.head_ref, pr_body)
        if violations:
            print(f"Found {len(violations)} RFC numbering violation(s):\n")
            for v in violations:
                print(v.format())
            print()
            return 1
        print("RFC numbering: no collisions detected.")
        return 0

    if args.check_ledger_monotonic:
        violations = check_ledger_monotonic(args.rfc_dir)
        if violations:
            print(f"Found {len(violations)} RFC ledger violation(s):\n")
            for v in violations:
                print(v.format())
            print()
            return 1
        print("RFC ledger: monotonic.")
        return 0

    if args.check is None:
        parser.error("--check is required unless --check-numbering is used")

    # Determine which files to check
    if args.files:
        rfc_files = [args.check / f for f in args.files]
    else:
        rfc_files = sorted(args.check.glob("RFC-*.md"))

    all_violations: List[Violation] = []
    files_checked = 0
    files_passed = 0

    for rfc_file in rfc_files:
        if not rfc_file.exists():
            print(f"Warning: file not found: {rfc_file}", file=sys.stderr)
            continue
        files_checked += 1
        violations = check_rfc_file(rfc_file, check_tmp_file=not args.no_tmp_check)
        if args.ignore_missing_section1:
            violations = [v for v in violations if v.rule != "NO_SECTION1"]
        if violations:
            all_violations.extend(violations)
        else:
            files_passed += 1

    # Print results
    print(f"Checked {files_checked} RFC file(s), {files_passed} passed.")

    if all_violations:
        print(f"\nFound {len(all_violations)} violation(s):\n")
        for v in all_violations:
            print(v.format())
        print()
        return 1

    print("All RFC §1 sections pass enforcement.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
