#!/usr/bin/env python3
"""Count the DOS input calls that a screen read follows at once, from the tool-call ledger.

`masc_dos_step`, `masc_dos_press`, `masc_dos_click` and `masc_dos_type` move the
machine and answer with text. A caller that wants to see the result then calls
`masc_dos_screen`: one more tool call and one more model request. With
`include_frame=true` the input answers with the screen too. This script counts
the inputs that were followed by a screen read, so a window before the change and
a window after it can be compared.

A pair is two calls of one Keeper that follow each other among its `masc_dos_*`
calls, in the same turn (`trace_id` and `keeper_turn_id`), where the first is an
input and the second is `masc_dos_screen`. The gap is the time between the two
rows' `ts`. It holds the model's own time, so it is not the time a pair saves.

- `with_frame`: input calls whose input has `include_frame` true.
- `followed_by_screen`: input calls that start a pair. The pair count per tool
  and per runtime profile is the number to compare, divided by `calls`: a
  profile that answers differently moves it without any change of the tools.
- `screen_in_next_request`: pairs whose input call was alone in its batch
  (`batch_size` 1), so the screen read came in a later model request. Only these
  pairs cost a model request that `include_frame` removes; an input and a screen
  that one model reply asked for together cost a tool call and no request.
- `screen_result_bytes`: `result_bytes` of the screen calls that end a pair.

Reads `<base-path>/.masc/tool_calls/YYYY-MM/DD[.NNN].jsonl` and never writes to
it. A day that is still being written changes under the script, so measure a
window whose last UTC day is over to get a repeatable result. A line that is not
a JSON object, or is a DOS tool call without a readable `ts`, is counted under
`unreadable_lines`.

Usage:
    python3 docs/evidence/dos-input-then-screen-2026-11/measure_input_then_screen.py \
        --base-path ~/me --from-date 2026-11-01 --to-date 2026-11-04 --json-out result.json
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import cast

JsonObject = dict[str, object]

TOOL_CALL_RECORD_KIND = "tool_call"
SCREEN_TOOL = "masc_dos_screen"
INPUT_TOOLS = ("masc_dos_step", "masc_dos_press", "masc_dos_click", "masc_dos_type")
DOS_TOOL_PREFIX = "masc_dos_"
UNRECORDED_PROFILE = "unrecorded"
SECONDS_PER_HOUR = 3600.0
P50 = 0.5
P90 = 0.9


@dataclass(frozen=True, slots=True)
class Call:
    ts: float
    keeper: str
    tool: str
    turn: str
    profile: str
    result_bytes: int
    batch_size: int
    with_frame: bool


@dataclass(slots=True)
class InputStat:
    calls: int = 0
    with_frame: int = 0
    followed_by_screen: int = 0
    screen_in_next_request: int = 0
    gaps_s: list[float] = field(default_factory=lambda: [])
    screen_result_bytes: int = 0


@dataclass(slots=True)
class Window:
    stats: dict[str, InputStat] = field(default_factory=lambda: {})
    by_profile: dict[str, InputStat] = field(default_factory=lambda: {})
    dos_calls: int = 0
    screen_calls: int = 0
    dos_calls_by_keeper: Counter[str] = field(default_factory=lambda: Counter())
    unreadable_lines: int = 0


def as_object(value: object) -> JsonObject | None:
    return cast(JsonObject, value) if isinstance(value, dict) else None


def as_text(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def as_timestamp(value: object) -> float | None:
    """Seconds since the epoch, from the number or the ISO 8601 text a row can carry."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if math.isfinite(value) else None
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def as_byte_count(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return 0
    return max(0, int(value))


def to_call(row: JsonObject) -> Call | None:
    """The DOS tool call of a ledger row, None for a row of another kind or tool."""
    if row.get("record_kind") != TOOL_CALL_RECORD_KIND:
        return None
    tool = as_text(row.get("tool"))
    keeper = as_text(row.get("keeper"))
    if tool is None or keeper is None or not tool.startswith(DOS_TOOL_PREFIX):
        return None
    ts = as_timestamp(row.get("ts"))
    if ts is None:
        raise ValueError("ts")
    arguments = as_object(row.get("input"))
    return Call(
        ts=ts,
        keeper=keeper,
        tool=tool,
        turn=f"{as_text(row.get('trace_id')) or '?'}#{row.get('keeper_turn_id')}",
        profile=as_text(row.get("runtime_profile")) or UNRECORDED_PROFILE,
        result_bytes=as_byte_count(row.get("result_bytes")),
        batch_size=as_byte_count(row.get("batch_size")),
        with_frame=arguments is not None and arguments.get("include_frame") is True,
    )


def ledger_files(base: pathlib.Path, day: date) -> list[pathlib.Path]:
    month_dir = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
    prefix = f"{day.day:02d}"
    return sorted(month_dir.glob(f"{prefix}.jsonl")) + sorted(month_dir.glob(f"{prefix}.[0-9][0-9][0-9].jsonl"))


def read_calls(base: pathlib.Path, first: date, last: date, window: Window) -> list[Call]:
    calls: list[Call] = []
    day = first
    while day <= last:
        for path in ledger_files(base, day):
            with path.open("rb") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        row = as_object(json.loads(line))
                        if row is None:
                            raise ValueError("a ledger line is a JSON object")
                        call = to_call(row)
                    except ValueError:  # JSONDecodeError and UnicodeDecodeError are ValueErrors
                        window.unreadable_lines += 1
                        continue
                    if call is not None:
                        calls.append(call)
        day += timedelta(days=1)
    return calls


def percentile(sorted_values: list[float], fraction: float) -> float:
    return sorted_values[max(0, math.ceil(fraction * len(sorted_values)) - 1)]


def screen_after(sequence: list[Call], index: int) -> Call | None:
    """The screen read that follows sequence[index] at once in the same turn, if there is one."""
    if index + 1 >= len(sequence):
        return None
    following = sequence[index + 1]
    return following if following.tool == SCREEN_TOOL and following.turn == sequence[index].turn else None


def measure(calls: list[Call], window: Window) -> None:
    by_keeper: dict[str, list[Call]] = defaultdict(list)
    for call in sorted(calls, key=lambda call: call.ts):
        by_keeper[call.keeper].append(call)
    window.dos_calls = len(calls)
    window.dos_calls_by_keeper = Counter(call.keeper for call in calls)
    window.screen_calls = sum(1 for call in calls if call.tool == SCREEN_TOOL)
    for sequence in by_keeper.values():
        for index, call in enumerate(sequence):
            if call.tool not in INPUT_TOOLS:
                continue
            screen = screen_after(sequence, index)
            for stat in (window.stats.setdefault(call.tool, InputStat()), window.by_profile.setdefault(call.profile, InputStat())):
                stat.calls += 1
                stat.with_frame += int(call.with_frame)
                if screen is not None:
                    stat.followed_by_screen += 1
                    stat.screen_in_next_request += int(call.batch_size == 1)
                    stat.gaps_s.append(screen.ts - call.ts)
                    stat.screen_result_bytes += screen.result_bytes


def summarize(stat: InputStat) -> JsonObject:
    gaps = sorted(stat.gaps_s)
    return {
        "calls": stat.calls,
        "with_frame": stat.with_frame,
        "followed_by_screen": stat.followed_by_screen,
        "screen_in_next_request": stat.screen_in_next_request,
        "gap_hours": round(sum(gaps) / SECONDS_PER_HOUR, 2),
        "gap_p50_s": round(percentile(gaps, P50), 1) if gaps else None,
        "gap_p90_s": round(percentile(gaps, P90), 1) if gaps else None,
        "screen_result_bytes": stat.screen_result_bytes,
    }


def summarize_window(first: date, last: date, window: Window) -> JsonObject:
    return {
        "from": first.isoformat(),
        "to": last.isoformat(),
        "dos_calls": window.dos_calls,
        "screen_calls": window.screen_calls,
        "dos_calls_by_keeper": dict(sorted(window.dos_calls_by_keeper.items())),
        "unreadable_lines": window.unreadable_lines,
        "by_tool": {tool: summarize(window.stats[tool]) for tool in INPUT_TOOLS if tool in window.stats},
        "by_profile": {profile: summarize(stat) for profile, stat in sorted(window.by_profile.items())},
    }


def render(summary: JsonObject) -> str:
    lines = [
        f"window {summary['from']} .. {summary['to']} (UTC days)",
        f"masc_dos_* calls {summary['dos_calls']}, screen calls {summary['screen_calls']}, unreadable lines {summary['unreadable_lines']}",
        f"masc_dos_* calls by Keeper {summary['dos_calls_by_keeper']}",
        "",
        f"{'group':<44}{'calls':>7}{'frame':>7}{'pairs':>7}{'next req':>10}{'gap h':>8}{'p50 s':>8}{'p90 s':>8}",
    ]
    for section, kind in (("by_tool", "tool"), ("by_profile", "profile")):
        for name, entry in cast(dict[str, JsonObject], summary[section]).items():
            label = f"{kind} {name}"
            lines.append(
                f"{label:<44}{entry['calls']!s:>7}{entry['with_frame']!s:>7}{entry['followed_by_screen']!s:>7}"
                f"{entry['screen_in_next_request']!s:>10}{entry['gap_hours']!s:>8}{entry['gap_p50_s']!s:>8}{entry['gap_p90_s']!s:>8}"
            )
    return "\n".join(lines)


def parse_day(text: str) -> date:
    try:
        return date.fromisoformat(text)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{text!r} is not a YYYY-MM-DD date") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", type=parse_day, required=True)
    parser.add_argument("--to-date", type=parse_day, required=True)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    first = cast(date, args.from_date)
    last = cast(date, args.to_date)
    if last < first:
        parser.error("--to-date is before --from-date")
    window = Window()
    measure(read_calls(cast(pathlib.Path, args.base_path), first, last, window), window)
    summary = summarize_window(first, last, window)
    print(render(summary))
    if args.json_out is not None:
        cast(pathlib.Path, args.json_out).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
