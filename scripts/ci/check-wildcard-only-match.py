#!/usr/bin/env python3
"""Lint: a [match] whose every arm is a bare wildcard decides nothing.

    match classify err with
    | _ -> Failure_provider_error { ... }

The scrutinee is computed and thrown away. Nothing branches on it, yet the
shape reads as if two cases were being told apart, so the next reader looks
for the distinction and does not find one. Four of these were in the tree on
2026-09-06 and two of them sat on top of a real classifier
(Keeper_turn_driver.classify_masc_internal_error), which is what made them
worth a lint rather than four more one-line fixes.

What to write instead:

    plain value        let x = f a in                 (nothing branches)
    two-way choice     if guard then a else b         (a [when] decided it)
    kept for effect    ignore (f a : t)               (the ignore lint asks why)

Detection is textual, like scripts/lint-cancel-guard.sh: a line ending in
[match ... with] followed by arms that all start with a bare [_]. It reads
comments as code, so prose that spells a whole match out across lines can
trip it; write such an example inline or mark the line wildcard-match-ok.

Exit 0 = no violations, exit 1 = violations found.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

MATCH_HEADER = re.compile(r"\bmatch\b.*\bwith\b\s*$")
BARE_WILDCARD_ARM = re.compile(r"^\|\s*_\s*(when\b|->)")
BLOCK_END = re.compile(r"^(let|in|;;|\)|\])")
WAIVER = "wildcard-match-ok"

# How far past the header to look for arms. An arm list longer than this is
# not the shape being detected: a match with dozens of arms has real cases.
ARM_SCAN_LINES = 40


def repo_root() -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(out.stdout.strip())


def sources(root: Path) -> list[Path]:
    """Every tracked .ml file.

    Naming the directories instead left tools/, test_lib/ and ppx_tla/ out,
    which is how a checker ends up reporting a clean tree it never read. Ask
    git rather than keep a list that drifts as directories are added.
    """
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "*.ml"],
        capture_output=True,
        text=True,
        check=True,
    )
    return sorted(
        root / name
        for name in out.stdout.split("\0")
        if name and "_build" not in Path(name).parts
    )


def violations_in(path: Path) -> list[tuple[int, str]]:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return []
    found: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        if not MATCH_HEADER.search(line) or WAIVER in line:
            continue
        arms: list[str] = []
        for offset in range(index + 1, min(index + 1 + ARM_SCAN_LINES, len(lines))):
            stripped = lines[offset].strip()
            if stripped.startswith("|"):
                arms.append(stripped)
            elif arms and stripped and BLOCK_END.match(stripped):
                break
        if arms and all(BARE_WILDCARD_ARM.match(arm) for arm in arms):
            found.append((index + 1, line.strip()))
    return found


def main() -> int:
    root = repo_root()
    total = 0
    for path in sources(root):
        for lineno, text in violations_in(path):
            rel = path.relative_to(root)
            print(f"VIOLATION: {rel}:{lineno}: {text}")
            total += 1
    if total:
        print()
        print(f"{total} match expression(s) branch on nothing.")
        print("Write the value, an if/else, or an ignore — see the header of")
        print("scripts/ci/check-wildcard-only-match.py.")
        return 1
    print("No wildcard-only match expressions found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
