#!/usr/bin/env python3
"""What two runs of GET /api/v1/dashboard/logs have in common once their lines are aligned.

The body is the newest 200 lines of the server's own log. They hold the lines the probe
caused and the lines of periodic tasks, so the window shifts by a line when a periodic
task runs once more, and compare.py leaves the entries out (volatile_fields.txt). This
reads the kept bodies of two runs and checks the part that belongs to routing: the
`HTTP auth rejected` lines. Newest first, they must be the same for as long as both
windows reach. Any other line that only one side has is listed.

  logs_tail_diff.py BEFORE_DIR AFTER_DIR

Exits 1 when the rejection lines differ or a body was not kept.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from pathlib import Path

MODES = ("default", "strict")
ROLES = ("worker", "admin")
ROUTE = ("GET", "/api/v1/dashboard/logs")
REJECTION = "HTTP auth rejected"
# probe.py blanks a number that looks like an epoch time as the bare word EPOCH.
BLANKED_NUMBER = re.compile(r'(?<![\w"])EPOCH(?![\w"])')


def log_messages(directory: Path, mode: str, role: str) -> list[str] | None:
    """The messages of the kept body, newest first; None when it was not kept."""
    data = json.loads((directory / mode / "results.json").read_text(encoding="utf-8"))
    for row in data["rows"]:
        if (row["method"], row["route_path"]) != ROUTE:
            continue
        name = row.get("http1_responses", {}).get(role, {}).get("body_file")
        if not name:
            return None
        text = (directory / mode / "bodies" / name).read_text(encoding="utf-8")
        return [entry["message"] for entry in json.loads(BLANKED_NUMBER.sub("0", text))["entries"]]
    return None


def rejections(messages: list[str]) -> list[str]:
    return [message for message in messages if message.startswith(REJECTION)]


def same_where_both_reach(before: list[str], after: list[str]) -> bool:
    """The rejection lines of both windows agree, newest first, as far as both go."""
    shared = min(len(before), len(after))
    return before[:shared] == after[:shared]


def one_sided(before: list[str], after: list[str]) -> list[str]:
    """Lines that alignment finds on one side only, marked `-` (before) and `+` (after)."""
    lines: list[str] = []
    matcher = difflib.SequenceMatcher(None, before, after, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        lines += [f"- {message}" for message in before[i1:i2]]
        lines += [f"+ {message}" for message in after[j1:j2]]
    return lines


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("before", type=Path)
    ap.add_argument("after", type=Path)
    args = ap.parse_args()
    problems = 0
    for mode in MODES:
        for role in ROLES:
            before = log_messages(args.before, mode, role)
            after = log_messages(args.after, mode, role)
            if before is None or after is None:
                problems += 1
                print(f"[{mode}] as {role}: a body was not kept")
                continue
            before_rejections, after_rejections = rejections(before), rejections(after)
            agree = same_where_both_reach(before_rejections, after_rejections)
            problems += not agree
            print(
                f"[{mode}] as {role}: {len(before)} and {len(after)} lines, "
                f"{len(before_rejections)} and {len(after_rejections)} rejection lines, "
                f"{'the same newest first' if agree else 'DIFFERENT'}"
            )
            for line in one_sided(before, after):
                print(f"    {line}")
    print(f"{problems} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
