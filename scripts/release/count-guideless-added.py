#!/usr/bin/env python3
"""Count the `가이드 없음(...)` guide markers in a release note's Added section.

Born from [규약 제안 #1] (changelog.d Added 항목의 사용 가이드 1장 규칙):
the gate decision is deferred until numbers exist, so every release note
gets counted the same way. Reads the note from a file or a GitHub Release
tag, finds the `### Added` section, and reports:

- total added bullets (top-level `- ` lines inside the section)
- guideless count and their bullets (markers: 가이드 없음(대상 문서: ...) and
  가이드 없음(문서 없음), plus the English v0.54.0 spelling
  "No guide yet (none found in docs/guides, TUI-GUIDE.md or
  KEEPER-USER-MANUAL.md)")
- a JSON and a Markdown summary (so the number can be committed next to the
  note, e.g. docs/releases/guide-metrics-<tag>.md)

Old notes without any marker count as 0 guideless (AC 1): absence of the
rule is counted as absence of markers, never as an error.

Usage:
  python3 scripts/release/count-guideless-added.py --tag v0.52.0 \
      --note-path docs/releases/v0.52.0.md --out-md docs/releases/guide-metrics-v0.52.0.md
  python3 scripts/release/count-guideless-added.py --tag v0.52.0 --from-github
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

# All guideless spellings the counter recognises. The Korean markers are the
# canonical spelling (see docs/releases/guide-metrics-v0.54.0.md); the
# English "No guide yet (" form was used once, in the published v0.54.0
# notes, so old notes keep counting the same way.
GUIDELESS_MARKERS = (
    "가이드 없음(",
    "No guide yet (",
)


def read_note(path: str | None, tag: str, from_github: bool) -> str:
    if from_github:
        text = subprocess.run(
            ["gh", "release", "view", tag, "--json", "body", "--jq", ".body"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        return text
    if not path:
        raise SystemExit("either --note-path or --from-github is required")
    return Path(path).read_text(encoding="utf-8")


def added_bullets(note: str) -> list[str]:
    """Return the top-level bullets of the `### Added` section.

    A bullet is joined with its continuation lines (wrapped text and nested
    `  - ` items) before marker matching. The generated notes hard-wrap at
    ~72 columns, so a `가이드 없음(...)` marker often lands on a wrapped
    line rather than the `- ` line; matching per physical line undercounts.
    """
    bullets: list[str] = []
    inside = False
    current: str | None = None
    for line in note.splitlines():
        if line.startswith("### "):
            if current is not None:
                bullets.append(current)
                current = None
            inside = line.strip().lower().startswith("### added")
            continue
        if line.startswith("#") and inside:
            if current is not None:
                bullets.append(current)
                current = None
            inside = False
            continue
        if not inside:
            continue
        if line.startswith("- "):
            if current is not None:
                bullets.append(current)
            current = line[2:].strip()
        elif line.strip() == "":
            if current is not None:
                bullets.append(current)
                current = None
        elif current is not None:
            current += " " + line.strip()
    if current is not None:
        bullets.append(current)
    return bullets


def is_guideless(bullet: str) -> bool:
    return any(marker in bullet for marker in GUIDELESS_MARKERS)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="release tag, e.g. v0.52.0")
    parser.add_argument("--note-path", help="path to the release note file")
    parser.add_argument("--from-github", action="store_true",
                        help="read the note body from the GitHub Release")
    parser.add_argument("--out-json", help="write the JSON summary here")
    parser.add_argument("--out-md", help="write the Markdown summary here")
    args = parser.parse_args()

    note = read_note(args.note_path, args.tag, args.from_github)
    bullets = added_bullets(note)
    guideless = [b for b in bullets if is_guideless(b)]

    summary = {
        "tag": args.tag,
        "added_total": len(bullets),
        "guideless_total": len(guideless),
        "guideless_items": guideless,
    }

    if args.out_json:
        Path(args.out_json).write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    if args.out_md:
        lines = [
            f"# Guide coverage — {args.tag}",
            "",
            f"- Added 항목: {summary['added_total']}",
            f"- 가이드 없음 표기: {summary['guideless_total']}",
            "",
        ]
        lines += [f"- {item}" for item in guideless] or ["- (표기 없음)"]
        lines += ["", "측정: scripts/release/count-guideless-added.py",
                  "규칙: changelog.d Added 항목의 사용 가이드 1장 (규약 제안 #1)"]
        Path(args.out_md).write_text("\n".join(lines) + "\n", encoding="utf-8")

    json.dump(summary, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
