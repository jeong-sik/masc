#!/usr/bin/env python3
"""Count failed tool calls in the tool-call ledger by tool and by what the failure says.

Reads, and never writes, `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` and
`<DD>.<NNN>.jsonl`: one JSON object per line. A line counts when `record_kind` is `tool_call`
and `ts` (UTC seconds) lies in [--since, --until). Fields used: `tool`, `keeper`,
`session_id`, `keeper_turn_id`, `disposition` and `output`.

Definitions:

- failed: `disposition` is `failed`. A line without a `disposition` counts as a call that did
  not fail, so a ledger written before that field existed reads as zero failures.
- signature: the first line of `output`, every digit run written as `N`, every run of eight or
  more hex digits written as `<hex>`, cut at --width characters. Two failures with the same
  signature say the same thing to the model.
- turn: one (`keeper`, `session_id`, `keeper_turn_id`) triple; `keeper_turn_id` is a number or
  text. A line without a usable `keeper_turn_id` counts as its own turn. `turns` of a group is
  the number of distinct turns among its failures.

A line that is not JSON, has no numeric `ts`, or has no text `tool` is counted in `skipped` and
left out of every number.

Usage:
    python3 docs/evidence/failed-calls-2026-11/measure_failed_calls.py \
        --base-path ~/me --since 2026-11-06T09:30:00 --until 2026-11-07T09:30:00 \
        --json-out result.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import re
import sys
from collections import defaultdict
from collections.abc import Iterator, Sequence
from typing import cast

RECORD_KIND = "tool_call"
FAILED = "failed"
LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
DIGITS = re.compile(r"[0-9]+")
LONG_HEX = re.compile(r"\b[0-9a-f]{8,}\b")
DEFAULT_WIDTH = 110
DEFAULT_TOP = 12
MAX_DAYS = 366

UTC = datetime.timezone.utc


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    tool: str
    keeper: str
    turn: str
    failed: bool
    signature: str


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0


def signature_of(output: str, width: int) -> str:
    """The first line of a result with its numbers and hashes folded, cut at `width`."""
    lines = output.strip().splitlines()
    first = lines[0] if lines else ""
    return DIGITS.sub("N", LONG_HEX.sub("<hex>", first))[:width]


def keeper_of(fields: dict[str, object]) -> str:
    keeper = fields.get("keeper")
    return keeper if isinstance(keeper, str) else ""


def turn_of(fields: dict[str, object], keeper: str, ordinal: int) -> str:
    """The turn key of a line: its keeper, session and turn number, or the line itself without a number."""
    number = fields.get("keeper_turn_id")
    session = fields.get("session_id")
    usable = (isinstance(number, int) and not isinstance(number, bool)) or (isinstance(number, str) and number != "")
    if not usable:
        return f"line-{ordinal}"
    return f"{keeper}/{session if isinstance(session, str) else ''}/{number}"


def parse_call(raw: bytes, since: float, until: float, width: int, skipped: Skipped, ordinal: int) -> Call | None:
    """The call a ledger line records, or None when the line is outside the window or not a call."""
    try:
        row = cast("object", json.loads(raw))
    except ValueError:
        skipped.bad_lines += 1
        return None
    if not isinstance(row, dict):
        skipped.bad_lines += 1
        return None
    fields = cast("dict[str, object]", row)
    if fields.get("record_kind") != RECORD_KIND:
        return None
    stamp = fields.get("ts")
    tool = fields.get("tool")
    if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not isinstance(tool, str):
        skipped.bad_lines += 1
        return None
    if not since <= float(stamp) < until:
        return None
    keeper = keeper_of(fields)
    output = fields.get("output")
    failed = fields.get("disposition") == FAILED
    return Call(
        tool=tool,
        keeper=keeper,
        turn=turn_of(fields, keeper, ordinal),
        failed=failed,
        signature=signature_of(output, width) if failed and isinstance(output, str) else "",
    )


def ledger_files(base: pathlib.Path, since: datetime.datetime, until: datetime.datetime) -> list[pathlib.Path]:
    """The ledger files of each UTC day the window touches, in name order."""
    paths: list[pathlib.Path] = []
    day = since.date()
    last = until.date()
    while day <= last:
        folder = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
        if folder.is_dir():
            paths.extend(sorted(p for p in folder.iterdir() if (m := LEDGER_FILE.match(p.name)) and int(m["day"]) == day.day))
        day += datetime.timedelta(days=1)
    return paths


def read_calls(paths: Sequence[pathlib.Path], since: float, until: float, width: int, skipped: Skipped) -> Iterator[Call]:
    ordinal = 0
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                ordinal += 1
                call = parse_call(raw, since, until, width, skipped, ordinal)
                if call is not None:
                    yield call


def summarize(calls: Iterator[Call], top: int) -> dict[str, object]:
    per_tool: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    groups: dict[tuple[str, str], list[Call]] = defaultdict(list)
    total = 0
    failed_total = 0
    for call in calls:
        total += 1
        per_tool[call.tool][0] += 1
        if call.failed:
            failed_total += 1
            per_tool[call.tool][1] += 1
            groups[(call.tool, call.signature)].append(call)
    tools = sorted(per_tool.items(), key=lambda item: (-item[1][1], -item[1][0], item[0]))
    signatures = sorted(groups.items(), key=lambda item: (-len(item[1]), item[0]))
    return {
        "calls": total,
        "failed": failed_total,
        "tools": [{"tool": tool, "calls": counts[0], "failed": counts[1]} for tool, counts in tools if counts[1] > 0][:top],
        "signatures": [
            {
                "tool": tool,
                "signature": signature,
                "failed": len(items),
                "keepers": len({item.keeper for item in items}),
                "turns": len({item.turn for item in items}),
            }
            for (tool, signature), items in signatures[:top]
        ],
    }


def parse_instant(text: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=UTC)


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="UTC, like 2026-11-06T09:30:00")
    parser.add_argument("--until", required=True, help="UTC, like 2026-11-07T09:30:00")
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since = parse_instant(cast("str", args.since))
    until = parse_instant(cast("str", args.until))
    if until <= since or until - since > datetime.timedelta(days=MAX_DAYS):
        print(f"--until must come after --since, within {MAX_DAYS} days", file=sys.stderr)
        return 2
    base = cast("pathlib.Path", args.base_path).expanduser()
    skipped = Skipped()
    paths = ledger_files(base, since, until)
    summary = summarize(
        read_calls(paths, since.timestamp(), until.timestamp(), cast("int", args.width), skipped),
        cast("int", args.top),
    )
    summary["skipped"] = dataclasses.asdict(skipped)
    summary["window"] = {"since": since.isoformat(), "until": until.isoformat(), "files": len(paths)}
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
