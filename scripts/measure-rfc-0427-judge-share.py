#!/usr/bin/env python3
"""Count how many tool_execute calls the judge still decides (RFC-0427 C-1).

RFC-0422 put a kernel-enforced box in front of the judge: a command the box
proves harmless runs without a judgment. RFC-0427 C-1 asks how far that moves
the judge's share, and answers with a count over the structured system log,
never with an estimate. This script produces the row RFC-0427 section 5 keeps.

What is counted, and from which line:

  authorized      "external effect authorized operation=tool_execute source=S"
                  one line per authorized execution; S is the path that said yes
                  (readonly_sandbox, keeper_always_allow, one_shot_resolution,
                  observed_in_box). one_shot_resolution is the judge.
  refused         "observe run refused operation=tool_execute"  the box ran the
                  command and it failed inside the box; the judge decided after.
  unavailable     "observe run unavailable operation=tool_execute"  no box could
                  be built for that endpoint; the judge decided.
  cwd errors      Execute tool_call receipts whose error names cwd_missing or
                  cwd_not_directory (RFC-0427 A).

A remote rg's "No such file" naming a host path is not counted: the lane
rewrites the guest's spelling of the keeper root to the host's before the
keeper sees it, so that path is the guest's own answer that the directory is
absent there, not a host path handed to the guest.

The window is half-open on the record's own ts: since <= ts < until, compared
as ISO-8601 text, which the log writes in UTC with a Z suffix.

Usage:
    scripts/measure-rfc-0427-judge-share.py --since 2026-09-05T16:20:00Z \
        --until 2026-09-07T16:20:00Z ~/me/.masc/logs/system_log_2026-09-0[567].jsonl
    scripts/measure-rfc-0427-judge-share.py --selftest
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

AUTHORIZED = "external effect authorized operation=tool_execute source="
REFUSED = "observe run refused operation=tool_execute"
UNAVAILABLE = "observe run unavailable operation=tool_execute"
EXECUTE_RECEIPT = "tool_call tool=Execute "
RECEIPT_ERROR = "outcome=error"
CWD_ERRORS = ("cwd_missing", "cwd_not_directory")
JUDGE_SOURCE = "one_shot_resolution"
BOX_SOURCE = "observed_in_box"


@dataclass
class Counts:
    authorized_by_source: Counter = field(default_factory=Counter)
    refused: int = 0
    unavailable: int = 0
    cwd_errors: int = 0
    records: int = 0

    @property
    def authorized(self) -> int:
        return sum(self.authorized_by_source.values())

    @property
    def judge(self) -> int:
        return self.authorized_by_source[JUDGE_SOURCE]

    @property
    def boxed(self) -> int:
        return self.authorized_by_source[BOX_SOURCE]


def in_window(ts: str, since: str | None, until: str | None) -> bool:
    if since is not None and ts < since:
        return False
    if until is not None and ts >= until:
        return False
    return True


def count_line(counts: Counts, message: str) -> None:
    if message.startswith(AUTHORIZED):
        source = message[len(AUTHORIZED) :].split(" ", 1)[0]
        counts.authorized_by_source[source] += 1
    elif message.startswith(REFUSED):
        counts.refused += 1
    elif message.startswith(UNAVAILABLE):
        counts.unavailable += 1
    elif EXECUTE_RECEIPT in message and RECEIPT_ERROR in message:
        if any(code in message for code in CWD_ERRORS):
            counts.cwd_errors += 1


def count_lines(lines, since: str | None, until: str | None) -> Counts:
    counts = Counts()
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue
        ts = record.get("ts")
        message = record.get("message")
        if not isinstance(ts, str) or not isinstance(message, str):
            continue
        if not in_window(ts, since, until):
            continue
        counts.records += 1
        count_line(counts, message)
    return counts


def render(counts: Counts, label: str) -> str:
    share = f"{100.0 * counts.judge / counts.authorized:.1f}%" if counts.authorized else "-"
    header = (
        "| window | tool_execute | judge | observed_in_box | refused | unavailable |"
        " cwd errors |\n|---|---|---|---|---|---|---|"
    )
    row = (
        f"| {label} | {counts.authorized:,} | {counts.judge:,} ({share}) |"
        f" {counts.boxed:,} | {counts.refused:,} | {counts.unavailable:,} |"
        f" {counts.cwd_errors:,} |"
    )
    by_source = ", ".join(
        f"{source} {n:,}" for source, n in sorted(counts.authorized_by_source.items())
    )
    return f"{header}\n{row}\n\nauthorized by source: {by_source or 'none'}\nrecords in window: {counts.records:,}"


SELFTEST_LOG = """\
{"ts":"2026-09-05T16:20:00Z","message":"external effect authorized operation=tool_execute source=readonly_sandbox"}
{"ts":"2026-09-05T16:21:00Z","message":"external effect authorized operation=tool_execute source=one_shot_resolution"}
{"ts":"2026-09-05T16:22:00Z","message":"external effect authorized operation=tool_execute source=observed_in_box"}
{"ts":"2026-09-05T16:23:00Z","message":"observe run refused operation=tool_execute exit=1 stderr_bytes=110; the judge decides"}
{"ts":"2026-09-05T16:24:00Z","message":"observe run unavailable operation=tool_execute reason=docker_observe_unsupported: ..."}
{"ts":"2026-09-05T16:25:00Z","message":"keeper:x tool_call tool=Execute source=- params=[cwd] outcome=error error_preview={\\"error\\":\\"cwd_not_directory: /Users/x/y (directory does not exist)\\"}"}
{"ts":"2026-09-05T16:27:00Z","message":"keeper:x tool_call tool=Execute source=- outcome=ok out_len=3"}
{"ts":"2026-09-05T16:19:59Z","message":"external effect authorized operation=tool_execute source=one_shot_resolution"}
{"ts":"2026-09-07T16:20:00Z","message":"external effect authorized operation=tool_execute source=one_shot_resolution"}
not json at all
"""


def selftest() -> int:
    counts = count_lines(
        SELFTEST_LOG.splitlines(), "2026-09-05T16:20:00Z", "2026-09-07T16:20:00Z"
    )
    expected = {
        "authorized": 3,
        "judge": 1,
        "boxed": 1,
        "refused": 1,
        "unavailable": 1,
        "cwd_errors": 1,
        "records": 7,
    }
    got = {name: getattr(counts, name) for name in expected}
    if got != expected:
        print(f"selftest FAILED: expected {expected}, got {got}", file=sys.stderr)
        return 1
    print("selftest ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("logs", nargs="*", type=Path, help="system_log_*.jsonl files")
    parser.add_argument("--since", help="inclusive ISO-8601 UTC lower bound on ts")
    parser.add_argument("--until", help="exclusive ISO-8601 UTC upper bound on ts")
    parser.add_argument("--label", help="row label; defaults to the window")
    parser.add_argument("--selftest", action="store_true", help="run the embedded fixture")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.logs:
        parser.error("give at least one log file, or --selftest")

    def lines():
        for path in args.logs:
            with path.open(encoding="utf-8", errors="replace") as handle:
                yield from handle

    counts = count_lines(lines(), args.since, args.until)
    label = args.label or f"{args.since or 'start'} .. {args.until or 'end'}"
    print(render(counts, label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
