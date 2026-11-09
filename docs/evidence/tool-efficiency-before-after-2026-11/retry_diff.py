#!/usr/bin/env python3
"""Group failed tool calls by error head and show how the same Keeper retried them.

Reads, and never writes, `<base-path>/.masc/tool_calls/<YYYY-MM>/*.jsonl`. A line counts when
`record_kind` is `tool_call`. Fields used: `ts` (UTC seconds), `tool`, `keeper`, `disposition`,
`input` and `output`.

A failed call is a line with `disposition == "failed"` and `since <= ts < until`. Its retry is
the next call of the same tool by the same Keeper, when it comes within 300 seconds. The retry
diff lists the input keys the retry added (+), dropped (-) and changed (~).

A group whose retries mostly add the same key and then complete is a tool contract trap: the
Keeper fixed the arguments by itself, so the contract was learnable and the first call cost one
round trip. A group with no retry, or whose retries fail again, is not that.

The error head is the first 90 characters of the output with digits turned into N and hex runs
of 12 or more into H, so ids do not split a group.

    python3 retry_diff.py --base-path ~/me --since 2026-11-08T07:45 --until 2026-11-09T07:45

Lines that are not JSON are counted and reported.
"""

from __future__ import annotations

import argparse
import collections
import datetime
import json
import pathlib
import re
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from typing import Final

type Json = None | bool | int | float | str | list[Json] | dict[str, Json]

RETRY_WINDOW_S: Final = 300.0
HEAD_CHARS: Final = 90
DIFF_VARIANTS_SHOWN: Final = 2
TOOL_CALL: Final = "tool_call"
FAILED: Final = "failed"
COMPLETED: Final = "completed"
NO_RETRY: Final = "no retry"
NON_OBJECT_INPUT: Final = "non-object input"
CHANGED_KEYS_SHOWN_CHARS: Final = 30


@dataclass(frozen=True, slots=True)
class Retry:
    tool: str
    error: str
    diff: str
    completed: bool


def error_head(output: Json) -> str:
    text = output if isinstance(output, str) else json.dumps(output, ensure_ascii=False)
    text = re.sub(r"[0-9a-f]{12,}", "H", text)
    text = re.sub(r"\d+", "N", text)
    return text[:HEAD_CHARS].replace("\n", " ")


def timestamp(record: Mapping[str, Json]) -> float | None:
    value = record.get("ts")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def input_diff(first: Json, second: Json) -> str:
    if not isinstance(first, dict) or not isinstance(second, dict):
        return NON_OBJECT_INPUT
    added = sorted(set(second) - set(first))
    dropped = sorted(set(first) - set(second))
    changed = sorted(key for key in set(first) & set(second) if first[key] != second[key])
    return f"+{','.join(added) or '-'} -{','.join(dropped) or '-'} ~{','.join(changed)[:CHANGED_KEYS_SHOWN_CHARS] or '-'}"


def retries_of(records: Iterable[Mapping[str, Json]], since: float, until: float) -> list[Retry]:
    """One `Retry` per failed call in [since, until). Records outside the window plus the retry window are ignored."""
    lanes: dict[tuple[str, str], list[tuple[float, Mapping[str, Json]]]] = collections.defaultdict(list)
    for record in records:
        ts = timestamp(record)
        if record.get("record_kind") != TOOL_CALL or ts is None or not since <= ts < until + RETRY_WINDOW_S:
            continue
        lanes[(str(record.get("keeper")), str(record.get("tool")))].append((ts, record))
    found: list[Retry] = []
    for (_, tool), calls in lanes.items():
        calls.sort(key=lambda entry: entry[0])
        for index, (ts, call) in enumerate(calls):
            if ts >= until or call.get("disposition") != FAILED:
                continue
            following = calls[index + 1] if index + 1 < len(calls) else None
            retry = following[1] if following is not None and following[0] - ts <= RETRY_WINDOW_S else None
            diff = NO_RETRY if retry is None else input_diff(call.get("input"), retry.get("input"))
            completed = retry is not None and retry.get("disposition") == COMPLETED
            found.append(Retry(tool, error_head(call.get("output")), diff, completed))
    return found


def calls_in_window(records: Iterable[Mapping[str, Json]], since: float, until: float) -> int:
    """Tool call lines with `since <= ts < until`, the same window as the failed calls."""
    return sum(
        1
        for record in records
        if record.get("record_kind") == TOOL_CALL and (ts := timestamp(record)) is not None and since <= ts < until
    )


def read_records(base: pathlib.Path, month: str) -> tuple[list[dict[str, Json]], int]:
    records: list[dict[str, Json]] = []
    unreadable = 0
    for path in sorted((base / ".masc" / "tool_calls" / month).glob("*.jsonl")):
        with path.open(encoding="utf-8", errors="replace") as lines:
            for line in lines:
                try:
                    record: Json = json.loads(line)
                except json.JSONDecodeError:
                    unreadable += 1
                    continue
                if isinstance(record, dict):
                    records.append(record)
    return records, unreadable


def instant(text: str) -> float:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=datetime.UTC).timestamp()


def report(found: Sequence[Retry], min_failures: int) -> list[str]:
    groups: dict[tuple[str, str], list[Retry]] = collections.defaultdict(list)
    for retry in found:
        groups[(retry.tool, retry.error)].append(retry)
    lines: list[str] = []
    for (tool, error), rows in sorted(groups.items(), key=lambda item: -len(item[1])):
        if len(rows) < min_failures:
            continue
        done = sum(1 for row in rows if row.completed)
        lines.append(f"{len(rows):4} failures, retry completed {done:3}  {tool}: {error}")
        for diff, count in collections.Counter(row.diff for row in rows).most_common(DIFF_VARIANTS_SHOWN):
            lines.append(f"        retry diff {diff}  x{count}")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, default=pathlib.Path("~/me").expanduser())
    parser.add_argument("--month", default="2026-11")
    parser.add_argument("--since", required=True, help="UTC, YYYY-MM-DDTHH:MM")
    parser.add_argument("--until", required=True, help="UTC, YYYY-MM-DDTHH:MM")
    parser.add_argument("--min-failures", type=int, default=4)
    args = parser.parse_args()
    records, unreadable = read_records(args.base_path, args.month)
    since, until = instant(args.since), instant(args.until)
    found = retries_of(records, since, until)
    total = calls_in_window(records, since, until)
    print(f"window {args.since} .. {args.until} UTC, {len(found)} failed of {total} tool calls, unreadable lines {unreadable}")
    for line in report(found, args.min_failures):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
