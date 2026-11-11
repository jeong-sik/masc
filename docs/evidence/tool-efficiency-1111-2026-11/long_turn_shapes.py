#!/usr/bin/env python3
"""Shapes of long Keeper turns in the tool-call ledger.

Two counts, both read only (`<base-path>/.masc/tool_calls/YYYY-MM/*.jsonl` through
`../tool-efficiency-1110-2026-11/ledger_window.py`):

1. How many different PRs a turn mentions, per Keeper, for turns with many calls and for the rest.
2. How many result bytes a later call with the same input in the same turn replaced.

Definitions:

- turn: the rows that share (`trace_id`, `keeper_turn_id`).
- long turn: a turn with at least `--long-calls` calls. The number only splits the report. No rule
  uses it, and the calls-per-turn quantiles are printed next to it.
- PR mention: a 5-digit number written as `#12345`, `/pull/12345`, `/pulls/12345`, `/issues/12345`
  or `gh pr <verb> 12345` in the JSON text of a call's input. It is a text count. It does not say
  what the command did with the PR, or whether the turn reviewed it.
- superseded result: among the calls of one turn with the same (`tool`, `input_fingerprint`), every
  call but the last. It counts when its `result_bytes` is at least `--min-bytes` and at most
  `--max-bytes` (the sizes that `Keeper_turn_driver_try_provider.aged_result_min_bytes` and
  `Common.max_agent_core_inline_result_bytes` give the finished-turn marker rule). Nothing is chosen
  here: the event is that the same input ran again. The same input may return a different result, and
  that is the case this count is about.
- `result_bytes` is the size the ledger recorded for the result. A result that the model sees only as
  a marker is still counted at the size the ledger recorded.

Usage:
    python3 docs/evidence/tool-efficiency-1111-2026-11/long_turn_shapes.py \
        --base-path ~/me --since 2026-11-08T05:40:00Z --end 2026-11-11T05:40:00Z \
        --json-out result.json
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import pathlib
import re
import statistics
import sys
from collections.abc import Sequence

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tool-efficiency-1110-2026-11"))

import ledger_window as ledger  # noqa: E402

PR_MENTION = re.compile(
    r"(?:#|/pulls?/|/issues/|\bgh\s+pr\s+[a-z-]+\s+)(\d{5})(?![0-9A-Za-z])"
)
DEFAULT_LONG_CALLS = 100
DEFAULT_MIN_BYTES = 2_048
DEFAULT_MAX_BYTES = 65_536
DEFAULT_TOP = 8
TurnKey = tuple[object, object]


@dataclasses.dataclass(slots=True)
class Call:
    ts: float
    tool: str
    input_fingerprint: str
    result_bytes: int
    keeper: str


@dataclasses.dataclass(slots=True)
class Turn:
    keeper: str
    calls: list[Call] = dataclasses.field(default_factory=list[Call])
    prs: set[str] = dataclasses.field(default_factory=set[str])


def quantiles(values: Sequence[int]) -> dict[str, int | float]:
    """`median` is the mean of the two middle values when n is even (so 5.5 for 1..10).

    `p90` is the value at index int(n * 0.9) of the sorted list, capped at the last index.
    """
    if not values:
        return {"n": 0}
    ordered = sorted(values)
    median = statistics.median(ordered)
    return {
        "n": len(ordered),
        "median": int(median) if median == int(median) else median,
        "p90": ordered[min(int(len(ordered) * 0.9), len(ordered) - 1)],
        "max": ordered[-1],
    }


def collect(base: pathlib.Path, since: float, end: float) -> dict[TurnKey, Turn]:
    turns: dict[TurnKey, Turn] = {}
    for row in ledger.read_rows(base, since, end):
        tool = row.get("tool")
        if not isinstance(tool, str):
            continue
        keeper = ledger.keeper_of(row)
        turn = turns.setdefault((row.get("trace_id"), row.get("keeper_turn_id")), Turn(keeper))
        fingerprint = row.get("input_fingerprint")
        turn.calls.append(
            Call(
                ts=ledger.number_of(row, "ts"),
                tool=tool,
                input_fingerprint=fingerprint if isinstance(fingerprint, str) else "",
                result_bytes=int(ledger.number_of(row, "result_bytes")),
                keeper=keeper,
            )
        )
        turn.prs.update(PR_MENTION.findall(json.dumps(ledger.input_of(row), ensure_ascii=False)))
    return turns


def keeper_shapes(turns: dict[TurnKey, Turn], long_calls: int, top: int) -> list[dict[str, object]]:
    by_keeper: dict[str, list[Turn]] = collections.defaultdict(list)
    for turn in turns.values():
        by_keeper[turn.keeper].append(turn)
    rows: list[dict[str, object]] = []
    for keeper, group in by_keeper.items():
        long_group = [t for t in group if len(t.calls) >= long_calls]
        short_group = [t for t in group if len(t.calls) < long_calls]
        calls = sum(len(t.calls) for t in group)
        long_total = sum(len(t.calls) for t in long_group)
        rows.append(
            {
                "keeper": keeper,
                "turns": len(group),
                "calls": calls,
                "long_turns": len(long_group),
                "long_turn_calls": long_total,
                "long_turn_call_share": round(long_total / calls, 4) if calls else 0.0,
                "calls_per_turn": quantiles([len(t.calls) for t in group]),
                "prs_per_long_turn": quantiles([len(t.prs) for t in long_group]),
                "prs_per_short_turn": quantiles([len(t.prs) for t in short_group]),
                "short_turns_without_pr_mention": sum(1 for t in short_group if not t.prs),
            }
        )
    rows.sort(key=lambda r: (-int(str(r["long_turn_calls"])), str(r["keeper"])))
    return rows[:top]


def superseded(turns: dict[TurnKey, Turn], low: int, high: int, top: int) -> dict[str, object]:
    in_range = 0
    replaced = 0
    replaced_calls = 0
    by_tool: collections.Counter[str] = collections.Counter()
    by_keeper: collections.Counter[str] = collections.Counter()
    for turn in turns.values():
        groups: dict[tuple[str, str], list[Call]] = collections.defaultdict(list)
        for call in sorted(turn.calls, key=lambda c: c.ts):
            if low <= call.result_bytes <= high:
                in_range += call.result_bytes
            if call.input_fingerprint:
                groups[(call.tool, call.input_fingerprint)].append(call)
        for group in groups.values():
            for call in group[:-1]:
                if low <= call.result_bytes <= high:
                    replaced += call.result_bytes
                    replaced_calls += 1
                    by_tool[call.tool] += call.result_bytes
                    by_keeper[call.keeper] += call.result_bytes
    return {
        "result_bytes_in_range": in_range,
        "superseded_bytes": replaced,
        "superseded_calls": replaced_calls,
        "superseded_share": round(replaced / in_range, 4) if in_range else 0.0,
        "by_tool": by_tool.most_common(top),
        "by_keeper": by_keeper.most_common(top),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="window start, ISO 8601 (UTC without an offset)")
    parser.add_argument("--end", required=True, help="window end, ISO 8601, exclusive")
    parser.add_argument("--long-calls", type=int, default=DEFAULT_LONG_CALLS)
    parser.add_argument("--min-bytes", type=int, default=DEFAULT_MIN_BYTES)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since, end = ledger.parse_utc(args.since), ledger.parse_utc(args.end)
    turns = collect(args.base_path.expanduser(), since, end)
    calls = sum(len(t.calls) for t in turns.values())
    long_turns = [t for t in turns.values() if len(t.calls) >= args.long_calls]
    long_calls = sum(len(t.calls) for t in long_turns)
    result: dict[str, object] = {
        "window": {"since": args.since, "end": args.end},
        "params": {"long_calls": args.long_calls, "min_bytes": args.min_bytes, "max_bytes": args.max_bytes},
        "turns": len(turns),
        "calls": calls,
        "calls_per_turn": quantiles([len(t.calls) for t in turns.values()]),
        "long_turns": {
            "turns": len(long_turns),
            "calls": long_calls,
            "share_of_calls": round(long_calls / calls, 4) if calls else 0.0,
        },
        "keepers_by_long_turn_calls": keeper_shapes(turns, args.long_calls, args.top),
        "superseded": superseded(turns, args.min_bytes, args.max_bytes, args.top),
    }
    text = json.dumps(result, ensure_ascii=False, indent=2)
    print(text)
    if args.json_out is not None:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
