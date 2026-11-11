#!/usr/bin/env python3
"""Share of tool calls and result bytes that repeat an earlier call of the same Keeper.

Read-only. Definition of docs/reports/2026-11-05-tool-efficiency.md section 1.2 ("same result fetched again"): a
call repeats an earlier call when the Keeper, the tool, the input_fingerprint and the output_fingerprint are all
equal and the earlier call was at most one hour before it. A call without both fingerprints cannot repeat. The
earlier call may lie before the window: rows up to one hour before `since` seed the memory and are not counted.

Usage:
    python3 -I docs/evidence/tool-efficiency-1111-2026-11/repeated_results.py SINCE_ISO END_ISO [BASE_PATH]

BASE_PATH defaults to ~/me. Prints one JSON object. The ledger is read through the reader of the 1110 folder.
"""

from __future__ import annotations

import dataclasses
import json
import pathlib
import sys
from collections.abc import Iterable, Mapping

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tool-efficiency-1110-2026-11"))

import ledger_window as ledger  # noqa: E402

WITHIN_S = 3600.0
TOP_TOOLS = 8


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    ts: float
    keeper: str
    tool: str
    input_fingerprint: str | None
    output_fingerprint: str | None
    result_bytes: int


@dataclasses.dataclass(frozen=True, slots=True)
class ToolShare:
    calls: int
    result_bytes: int
    repeated_calls: int
    repeated_bytes: int


@dataclasses.dataclass(frozen=True, slots=True)
class Share:
    calls: int
    result_bytes: int
    repeated_calls: int
    repeated_bytes: int
    by_tool: Mapping[str, ToolShare]


def _text(value: object) -> str | None:
    return value if isinstance(value, str) and value != "" else None


def _bytes(value: object) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def call_of(row: ledger.Row) -> Call | None:
    ts = row.get("ts")
    keeper = row.get("keeper")
    tool = row.get("tool")
    if not isinstance(ts, (int, float)) or not isinstance(keeper, str) or not isinstance(tool, str):
        return None
    return Call(
        ts=float(ts),
        keeper=keeper,
        tool=tool,
        input_fingerprint=_text(row.get("input_fingerprint")),
        output_fingerprint=_text(row.get("output_fingerprint")),
        result_bytes=_bytes(row.get("result_bytes")),
    )


def measure(calls: Iterable[Call], since: float, end: float) -> Share:
    """Count the calls with since <= ts < end; the calls before `since` only seed the one-hour memory."""
    last_seen: dict[tuple[str, str, str, str], float] = {}
    counted: dict[str, list[int]] = {}
    for call in sorted(calls, key=lambda c: c.ts):
        if call.ts >= end:
            break
        key = (
            (call.keeper, call.tool, call.input_fingerprint, call.output_fingerprint)
            if call.input_fingerprint is not None and call.output_fingerprint is not None
            else None
        )
        previous = last_seen.get(key) if key is not None else None
        if call.ts >= since:
            repeated = previous is not None and call.ts - previous <= WITHIN_S
            tally = counted.setdefault(call.tool, [0, 0, 0, 0])
            tally[0] += 1
            tally[1] += call.result_bytes
            if repeated:
                tally[2] += 1
                tally[3] += call.result_bytes
        if key is not None:
            last_seen[key] = call.ts
    by_tool = {tool: ToolShare(*tally) for tool, tally in counted.items()}
    return Share(
        calls=sum(t.calls for t in by_tool.values()),
        result_bytes=sum(t.result_bytes for t in by_tool.values()),
        repeated_calls=sum(t.repeated_calls for t in by_tool.values()),
        repeated_bytes=sum(t.repeated_bytes for t in by_tool.values()),
        by_tool=by_tool,
    )


def report(share: Share, since: float, end: float) -> dict[str, object]:
    top = sorted(share.by_tool.items(), key=lambda item: item[1].repeated_bytes, reverse=True)[:TOP_TOOLS]
    hours = (end - since) / 3600.0
    return {
        "hours": round(hours, 2),
        "calls": share.calls,
        "result_bytes": share.result_bytes,
        "repeated_calls": share.repeated_calls,
        "repeated_calls_pct": round(100.0 * share.repeated_calls / share.calls, 1) if share.calls else None,
        "repeated_bytes": share.repeated_bytes,
        "repeated_bytes_pct": round(100.0 * share.repeated_bytes / share.result_bytes, 1) if share.result_bytes else None,
        "repeated_bytes_per_day": round(share.repeated_bytes * 24.0 / hours) if hours > 0 else None,
        "result_bytes_per_day": round(share.result_bytes * 24.0 / hours) if hours > 0 else None,
        "top_by_repeated_bytes": [
            {
                "tool": tool,
                "repeated_calls": t.repeated_calls,
                "repeated_bytes": t.repeated_bytes,
                "tool_result_bytes": t.result_bytes,
            }
            for tool, t in top
        ],
    }


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    since, end = ledger.parse_utc(argv[1]), ledger.parse_utc(argv[2])
    base = pathlib.Path(argv[3]) if len(argv) == 4 else pathlib.Path.home() / "me"
    calls = [c for c in map(call_of, ledger.read_rows(base, since - WITHIN_S, end)) if c is not None]
    print(json.dumps(report(measure(calls, since, end), since, end), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
