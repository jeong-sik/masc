#!/usr/bin/env python3
"""rfc-generate-index.py — Generate RFC index table from frontmatter.

Usage:
  scripts/rfc-generate-index.py              # print to stdout
  scripts/rfc-generate-index.py --check       # exit 1 if stale
  scripts/rfc-generate-index.py --update      # overwrite README table
"""
from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

RFC_DIR = Path("docs/rfc")
README = RFC_DIR / "README.md"
TABLE_HEADER = "| # | Title | Status | Last activity | Sub-docs |"
TABLE_SEP = "|---|---|---|---|---|"


@dataclass
class RfcEntry:
    number: str
    title: str = "(untitled)"
    status: str = "Draft"
    last_activity: str = "-"
    sub_docs: list[str] = field(default_factory=list)


def extract_frontmatter(filepath: Path) -> dict[str, str]:
    """Extract YAML frontmatter key:value pairs."""
    result: dict[str, str] = {}
    in_fm = False
    for line in filepath.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped == "---":
            if in_fm:
                break
            in_fm = True
            continue
        if in_fm and ":" in stripped:
            key, _, value = stripped.partition(":")
            result[key.strip()] = value.strip().strip('"')
    return result


def last_git_activity(filepath: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "log", "-1", "--format=%h %cs", "--", str(filepath)],
            capture_output=True, text=True, check=False,
        )
        return result.stdout.strip() or "(untracked)"
    except Exception:
        return "-"


def collect_entries() -> dict[str, RfcEntry]:
    entries: dict[str, RfcEntry] = {}
    sub_docs: dict[str, list[str]] = {}

    for fpath in sorted(RFC_DIR.glob("RFC-*.md")):
        name = fpath.name
        num = name[4:8]

        if "-phase-" in name:
            sub_docs.setdefault(num, []).append(name)
            continue

        fm = extract_frontmatter(fpath)
        title = fm.get("title", "")
        if not title:
            first_line = ""
            for line in fpath.read_text(encoding="utf-8").splitlines():
                if line.startswith("# "):
                    first_line = line
                    break
            title = re.sub(r"^# RFC[- ]*\d+[.: —–-]*\s*", "", first_line)
            if not title:
                title = "(untitled)"

        entries[num] = RfcEntry(
            number=num,
            title=title,
            status=fm.get("status", "Draft"),
            last_activity=last_git_activity(fpath),
            sub_docs=sub_docs.get(num, []),
        )

    return entries


def generate_table(entries: dict[str, RfcEntry]) -> str:
    lines = [TABLE_HEADER, TABLE_SEP]
    for num in sorted(entries):
        e = entries[num]
        title = e.title
        if len(title) > 80:
            title = title[:77] + "..."
        subs = ", ".join(e.sub_docs) if e.sub_docs else "-"
        lines.append(f"| {num} | {title} | {e.status} | {e.last_activity} | {subs} |")
    return "\n".join(lines)


def check_mode(table: str) -> int:
    text = README.read_text(encoding="utf-8")
    start = text.find(TABLE_HEADER)
    if start == -1:
        print("ERROR: Table header not found in README.md", file=sys.stderr)
        return 1
    end = text.find("\n\n", start)
    if end == -1:
        end = len(text)
    existing = text[start:end].rstrip("\n")
    if existing == table:
        print("OK: RFC index table is up to date")
        return 0
    print("MISMATCH: RFC index table is stale. Run: scripts/rfc-generate-index.py --update")
    for i, (a, b) in enumerate(zip(existing.splitlines(), table.splitlines())):
        if a != b:
            print(f"  line {i+1}: {a!r} != {b!r}")
    return 1


def update_mode(table: str) -> int:
    text = README.read_text(encoding="utf-8")
    start = text.find(TABLE_HEADER)
    if start == -1:
        print("ERROR: Table header not found in README.md", file=sys.stderr)
        return 1
    end = text.find("\n\n", start)
    if end == -1:
        end = len(text)
    suffix = text[end:].lstrip("\n")
    new_text = text[:start] + table + "\n\n" + suffix
    README.write_text(new_text, encoding="utf-8")
    print(f"Updated RFC index table in {README}")
    return 0


def main() -> int:
    import os
    os.chdir(subprocess.run(["git", "rev-parse", "--show-toplevel"],
                            capture_output=True, text=True, check=True
                            ).stdout.strip())
    entries = collect_entries()
    table = generate_table(entries)

    if "--check" in sys.argv:
        return check_mode(table)
    if "--update" in sys.argv:
        return update_mode(table)
    print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
