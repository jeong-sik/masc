#!/usr/bin/env python3
"""Fail when docs/spec/ names a source file that does not exist.

These documents are what an agent or a new reader is pointed at for "how the
system works". A path that no longer resolves is worse than no path: it sends
the reader looking for a module the repository deliberately deleted, and it
reads as current because everything around it is.

Scope is docs/spec/ only. RFCs and audits are dated records — an RFC proposing
a module that was never built, or an audit describing files since removed, is
supposed to keep saying so.

check-spec-truth.sh covers the other direction for TLA+ specs (annotations
pointing at OCaml sources). This is the same idea for prose.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
SPEC = REPO / "docs" / "spec"

# Backtick-quoted repo-relative source paths. Globs (`keeper_memory*.ml`) and
# directories are deliberately not matched — they are prose, not references.
REFERENCE = re.compile(
    r"`((?:lib|bin|test|scripts|dashboard/src|proto)/[A-Za-z0-9_./-]+"
    r"\.(?:ml|mli|ts|tsx|py|sh|tla|cfg))`"
)


def main() -> int:
    if not SPEC.is_dir():
        print(f"FAIL: {SPEC} is missing")
        return 1

    checked = 0
    missing: list[tuple[str, int, str]] = []
    for doc in sorted(SPEC.rglob("*.md")):
        text = doc.read_text()
        for match in REFERENCE.finditer(text):
            checked += 1
            path = match.group(1)
            if not (REPO / path).exists():
                lineno = text.count("\n", 0, match.start()) + 1
                missing.append((str(doc.relative_to(REPO)), lineno, path))

    print(f"=== spec file references: {checked} checked ===")
    if not checked:
        print("FAIL: no references found — the pattern stopped matching")
        return 1
    if not missing:
        print("PASS: every referenced source file exists")
        return 0

    print("FAIL: docs/spec names source files that do not exist:")
    for doc, lineno, path in missing:
        print(f"  {doc}:{lineno} -> {path}")
    print()
    print("Moved: update the path. Deleted: remove the claim, including any")
    print("'this was retired in #N' note — a tombstone is still dead context.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
