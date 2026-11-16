#!/usr/bin/env python3
"""Find runs that send one tool call with the same input, response after response.

A run is one raw trace file of a Keeper (`<base>/.masc/keepers/<keeper>/raw-traces/turn-<ms>-*.jsonl`).
A response is the set of `tool_execution_started` records that share one `tool_turn`.
A repeat round is a response that holds exactly one call whose tool name and
input equal the single call of the response right before it. The result is not
compared: a status read returns a new observation time on every call, so equal
results would miss the loop this measures.

Per run, the longest stretch of such responses is reported when it holds at
least `--min-rounds` responses. `span_h` runs from the first call start of the
stretch to the last one. `runtime` is the `agent_name` of the run's last
`run_started` record, which names the Agent Core runtime when one served the
run. Runs are chosen by the millisecond stamp in the file name.

`--min-rounds` only cuts the report. Nothing in MASC uses it.

Reads the raw traces and never writes to them. A line that is not a JSON object
is skipped and counted under `unreadable_lines`.

Usage:
    python3 -I -B repeated_tool_rounds.py --base-path ~/me --since <epoch> --end <epoch> --min-rounds 10
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
from dataclasses import dataclass
from typing import cast

JsonObject = dict[str, object]
STAMP = re.compile(r"turn-(\d{13})-")
MS_PER_S = 1000
S_PER_H = 3600
PRINT_DIGITS = 2


@dataclass(frozen=True, slots=True)
class Call:
    name: str
    input_key: str
    ts: float


@dataclass(frozen=True, slots=True)
class Stretch:
    keeper: str
    trace: str
    runtime: str
    tool: str
    rounds: int
    first_ts: float
    last_ts: float


@dataclass(frozen=True, slots=True)
class RunRead:
    calls_by_response: dict[int, tuple[Call, ...]]
    runtime: str
    unreadable_lines: int


def read_run(path: pathlib.Path) -> RunRead:
    calls: dict[int, list[Call]] = {}
    runtime = ""
    unreadable = 0
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            try:
                parsed: object = json.loads(line)
            except json.JSONDecodeError:
                unreadable += 1
                continue
            if not isinstance(parsed, dict):
                unreadable += 1
                continue
            rec = cast(JsonObject, parsed)
            kind = rec.get("record_type")
            if kind == "run_started":
                name = rec.get("agent_name")
                if isinstance(name, str):
                    runtime = name
            elif kind == "tool_execution_started":
                turn = rec.get("tool_turn")
                ts = rec.get("ts")
                if isinstance(turn, int) and isinstance(ts, (int, float)):
                    key = json.dumps(rec.get("tool_input"), sort_keys=True)
                    calls.setdefault(turn, []).append(Call(str(rec.get("tool_name")), key, float(ts)))
    return RunRead({t: tuple(cs) for t, cs in calls.items()}, runtime, unreadable)


def longest_stretch(keeper: str, trace: str, run: RunRead) -> Stretch | None:
    best: Stretch | None = None
    prev: Call | None = None
    rounds = 0
    first_ts = 0.0
    for turn in sorted(run.calls_by_response):
        calls = run.calls_by_response[turn]
        if len(calls) != 1:
            prev, rounds = None, 0
            continue
        call = calls[0]
        if prev is not None and (prev.name, prev.input_key) == (call.name, call.input_key):
            rounds += 1
        else:
            rounds, first_ts = 1, call.ts
        prev = call
        if best is None or rounds > best.rounds:
            best = Stretch(keeper, trace, run.runtime, call.name, rounds, first_ts, call.ts)
    return best


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-path", required=True)
    ap.add_argument("--since", type=int, required=True)
    ap.add_argument("--end", type=int, required=True)
    ap.add_argument("--min-rounds", type=int, required=True)
    args = ap.parse_args()
    base = pathlib.Path(cast(str, args.base_path)).expanduser()
    since = cast(int, args.since)
    end = cast(int, args.end)
    min_rounds = cast(int, args.min_rounds)

    found: list[Stretch] = []
    unreadable = 0
    for path in sorted((base / ".masc" / "keepers").glob("*/raw-traces/turn-*.jsonl")):
        stamp = STAMP.search(path.name)
        if stamp is None or not (since <= int(stamp.group(1)) / MS_PER_S < end):
            continue
        run = read_run(path)
        unreadable += run.unreadable_lines
        stretch = longest_stretch(path.parent.parent.name, path.name, run)
        if stretch is not None and stretch.rounds >= min_rounds:
            found.append(stretch)
    found.sort(key=lambda s: s.last_ts - s.first_ts, reverse=True)

    by_runtime: dict[str, dict[str, float]] = {}
    for s in found:
        row = by_runtime.setdefault(s.runtime, {"runs": 0, "rounds": 0, "span_h": 0.0})
        row["runs"] += 1
        row["rounds"] += s.rounds
        row["span_h"] += (s.last_ts - s.first_ts) / S_PER_H

    report: JsonObject = {
        "since": since,
        "end": end,
        "min_rounds": min_rounds,
        "runs": len(found),
        "rounds": sum(s.rounds for s in found),
        "span_h": round(sum(s.last_ts - s.first_ts for s in found) / S_PER_H, PRINT_DIGITS),
        "by_runtime": {
            k: {"runs": int(v["runs"]), "rounds": int(v["rounds"]), "span_h": round(v["span_h"], PRINT_DIGITS)}
            for k, v in sorted(by_runtime.items())
        },
        "unreadable_lines": unreadable,
        "stretches": [
            {
                "keeper": s.keeper,
                "trace": s.trace,
                "runtime": s.runtime,
                "tool": s.tool,
                "rounds": s.rounds,
                "span_h": round((s.last_ts - s.first_ts) / S_PER_H, PRINT_DIGITS),
            }
            for s in found
        ],
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
