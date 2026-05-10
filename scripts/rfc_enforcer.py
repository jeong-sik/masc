#!/usr/bin/env python3
"""RFC §1 Enforcer — ensure caller-context completeness in RFC drafts.

Checks RFC markdown files for §1 section completeness rules:
  R1: No <!-- TODO --> comments in §1
  R2: At least 3 file:line citations
  R3: At least 1 code block
  R4: No sub-agent placeholder text
  R5: .tmp/rfc-NNNN-caller-context.md companion file exists

Usage:
    python scripts/rfc_enforcer.py --check docs/rfc/
    python scripts/rfc_enforcer.py --check docs/rfc/ --strict

Exit codes:
    0 — all RFCs pass
    1 — one or more violations found
    2 — runtime error
"""

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple


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


def main() -> int:
    parser = argparse.ArgumentParser(description="RFC §1 Enforcer")
    parser.add_argument(
        "--check",
        type=Path,
        required=True,
        help="Directory containing RFC files to check",
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
