#!/usr/bin/env python3
"""Measure how long Keeper runs go on, and what reaches a Keeper's queue meanwhile.

A run is one raw trace file of a Keeper (`<base>/.masc/keepers/<keeper>/raw-traces/turn-*.jsonl`).
Its rounds are the `before_turn_params` hooks the trace records: one per model
request. A run ends when the model answers without a tool call, or when a
provider error ends it (`run_finished.error`).

The queue of a Keeper is read when a turn starts. A queue row that arrives while
a run goes on cannot be read before the run ends. The reaction ledger
(`<base>/.masc/keepers/<keeper>/reaction-ledger/v7/YYYY-MM/DD.jsonl`) records
each acknowledged row with its arrival time. This script finds the rows that
arrived inside a run of their Keeper, and counts how long they had to wait at
least: from their arrival to the end of that run.

Reported:

- `runs`: rounds per run, the runs of at least 100 and at least 400 rounds, and
  per runtime profile and per UTC day (of the run's start).
- `spin_runs`: runs of at least `--spin-min-rounds` rounds where one tool makes at
  least `--spin-top-share` of the tool calls. The thresholds describe the runs
  in this report; nothing at runtime reads them.
- `arrivals_during_runs`: acknowledged rows that arrived inside a run, by the
  rounds of that run and by row kind, with `blocked_hours` (arrival to run end)
  and `acked_before_run_end`, the rows acknowledged before that run ended. The
  queue is drained between turns, so that count is expected to be 0. Its
  `by_day` table has, per UTC day of arrival, every acknowledged row, those that
  arrived inside a run, and their wait. A day with acknowledged rows and none
  inside a run may be a day whose raw traces are gone; the chart marks the days
  that have no round record.

Only rows that arrived inside the span a Keeper's raw traces cover count. Older
raw traces are rotated away, and a row whose run is gone would look like a row
that arrived while the Keeper was idle.

- `visible_at_next_round`: a replay, not a deployed result. For each such row, the
  time from its arrival to the next `before_turn_params` of that run: when a
  round that follows tool results could first have shown it
  (docs/rfc/RFC-arrived-stimuli-reach-the-running-turn.md). A row that arrived
  after the run's last request has no later round and is counted apart
  (`rows_after_the_last_round`), and so is a row inside a run that has no round
  records at all (`rows_in_runs_without_rounds`).

Reads the two stores and never writes to them. A line that is not a JSON object
is counted under `unreadable_lines`. A file that is listed and gone before it is
opened (a Keeper rotates its raw traces while this runs) is counted under
`unreadable_files`. Measure a window whose last UTC day is over to get a
repeatable result.

Usage:
    python3 docs/evidence/runs-and-arrivals-2026-11/measure_runs_and_arrivals.py \
        --base-path ~/me --json-out result.json --svg-out chart.svg
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import cast

JsonObject = dict[str, object]

BEFORE_TURN_PARAMS = "before_turn_params"
RECORD_HOOK = "hook_invoked"
RECORD_TOOL_STARTED = "tool_execution_started"
RECORD_RUN_STARTED = "run_started"
RECORD_RUN_FINISHED = "run_finished"
ACK_KIND = "event_queue_ack"
LONG_RUN_ROUNDS = (100, 400)
# Bucket lower bounds in rounds; the last bucket is open at the top.
RUN_SIZE_BUCKETS = (0, 10, 50, 100)
SECONDS_PER_HOUR = 3600.0
SECONDS_PER_MINUTE = 60.0
P50 = 0.5
P90 = 0.9
P99 = 0.99
IMMEDIATE = "immediate"
ERROR_KIND_CHARS = 40


@dataclass(frozen=True, slots=True)
class Run:
    keeper: str
    profile: str
    start: float
    end: float
    rounds: int
    round_times: tuple[float, ...]
    tool_calls: int
    top_tool: str | None
    top_tool_calls: int
    error_kind: str | None


@dataclass(frozen=True, slots=True)
class Ack:
    keeper: str
    event_id: str
    arrived: float
    acked: float
    urgency: str
    kind: str


@dataclass(slots=True)
class Unreadable:
    lines: int = 0
    files: int = 0


def as_object(value: object) -> JsonObject | None:
    return cast("JsonObject", value) if isinstance(value, dict) else None


def as_float(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    return None


def as_text(value: object) -> str | None:
    return value if isinstance(value, str) else None


def profile_of(agent_name: str | None) -> str:
    """`agent_core-glm-coding.glm-5.3-flash` names the profile after the first dot."""
    if agent_name is None:
        return "unrecorded"
    return agent_name.split(".", 1)[1] if "." in agent_name else agent_name


def read_run(path: pathlib.Path, keeper: str, unreadable: Unreadable) -> Run | None:
    round_times: list[float] = []
    tools: Counter[str] = Counter()
    first_ts: float | None = None
    last_ts: float | None = None
    agent: str | None = None
    error: str | None = None
    with path.open("rb") as handle:
        for line in handle:
            try:
                row = as_object(json.loads(line))
            except ValueError:
                row = None
            if row is None:
                unreadable.lines += 1
                continue
            ts = as_float(row.get("ts"))
            if ts is not None:
                first_ts = ts if first_ts is None else first_ts
                last_ts = ts
            kind = row.get("record_type")
            if kind == RECORD_HOOK and row.get("hook_name") == BEFORE_TURN_PARAMS:
                if ts is not None:
                    round_times.append(ts)
            elif kind == RECORD_RUN_STARTED:
                agent = as_text(row.get("agent_name"))
            elif kind == RECORD_TOOL_STARTED:
                tools[as_text(row.get("tool_name")) or "?"] += 1
            elif kind == RECORD_RUN_FINISHED:
                error = as_text(row.get("error"))
    if first_ts is None or last_ts is None:
        return None
    top = tools.most_common(1)
    return Run(
        keeper=keeper,
        profile=profile_of(agent),
        start=first_ts,
        end=last_ts,
        rounds=len(round_times),
        round_times=tuple(round_times),
        tool_calls=sum(tools.values()),
        top_tool=top[0][0] if top else None,
        top_tool_calls=top[0][1] if top else 0,
        error_kind=error[:ERROR_KIND_CHARS] if error else None,
    )


def read_runs(base: pathlib.Path, unreadable: Unreadable) -> list[Run]:
    runs: list[Run] = []
    for path in sorted((base / ".masc" / "keepers").glob("*/raw-traces/turn-*.jsonl")):
        try:
            run = read_run(path, path.parent.parent.name, unreadable)
        except FileNotFoundError:
            # A Keeper rotates its raw traces while this script lists them.
            unreadable.files += 1
            continue
        if run is not None:
            runs.append(run)
    return runs


def ack_of(row: JsonObject, keeper: str) -> Ack | None:
    reaction = as_object(row.get("reaction"))
    if reaction is None or reaction.get("kind") != ACK_KIND:
        return None
    receipt = as_object(reaction.get("transition_receipt"))
    transition = as_object(receipt.get("transition")) if receipt else None
    source = as_object(transition.get("source")) if transition else None
    if receipt is None or source is None:
        return None
    arrived = as_float(source.get("arrived_at_unix"))
    acked = as_float(receipt.get("applied_at_unix"))
    event_id = as_text(row.get("event_id"))
    if arrived is None or acked is None or event_id is None:
        return None
    payload = as_object(source.get("payload"))
    kind = (as_text(payload.get("kind")) if payload else None) or as_text(reaction.get("stimulus_kind")) or "?"
    return Ack(keeper, event_id, arrived, acked, as_text(source.get("urgency")) or "?", kind)


def read_acks(base: pathlib.Path, unreadable: Unreadable) -> list[Ack]:
    seen: set[tuple[str, str]] = set()
    acks: list[Ack] = []
    for path in sorted((base / ".masc" / "keepers").glob("*/reaction-ledger/v7/*/*.jsonl")):
        keeper = path.parts[-5]
        try:
            handle = path.open("rb")
        except FileNotFoundError:
            unreadable.files += 1
            continue
        with handle:
            for line in handle:
                try:
                    row = as_object(json.loads(line))
                except ValueError:
                    row = None
                if row is None:
                    unreadable.lines += 1
                    continue
                ack = ack_of(row, keeper)
                if ack is None or (ack.keeper, ack.event_id) in seen:
                    continue
                seen.add((ack.keeper, ack.event_id))
                acks.append(ack)
    return acks


def percentile(sorted_values: list[float], share: float) -> float:
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * share))]


def day_of(ts: float) -> str:
    return datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%d")


def in_window(ts: float, first_day: date | None, last_day: date | None) -> bool:
    day = datetime.fromtimestamp(ts, UTC).date()
    return (first_day is None or day >= first_day) and (last_day is None or day <= last_day)


def is_spin(run: Run, min_rounds: int, top_share: float) -> bool:
    return run.rounds >= min_rounds and run.tool_calls > 0 and run.top_tool_calls / run.tool_calls >= top_share


def round_stats(runs: list[Run]) -> JsonObject:
    """Runs with no `before_turn_params` hook (an official client runs its own loop) have no rounds to count."""
    with_rounds = [run for run in runs if run.rounds > 0]
    if not with_rounds:
        return {"runs": len(runs), "runs_without_rounds": len(runs)}
    rounds = sorted(float(run.rounds) for run in with_rounds)
    return {
        "runs": len(runs),
        "runs_without_rounds": len(runs) - len(with_rounds),
        "rounds": sum(run.rounds for run in with_rounds),
        "rounds_per_run_of_runs_with_rounds": {
            "p50": percentile(rounds, P50),
            "p90": percentile(rounds, P90),
            "p99": percentile(rounds, P99),
            "max": rounds[-1],
        },
    }


def long_run_stats(runs: list[Run], threshold: int) -> JsonObject:
    long_runs = [run for run in runs if run.rounds >= threshold]
    total_rounds = sum(run.rounds for run in runs)
    rounds = sum(run.rounds for run in long_runs)
    return {
        "runs": len(long_runs),
        "rounds": rounds,
        "share_of_all_rounds": round(rounds / total_rounds, 4) if total_rounds else 0.0,
        "wall_hours": round(sum(run.end - run.start for run in long_runs) / SECONDS_PER_HOUR, 2),
    }


def profile_table(runs: list[Run], min_rounds: int, top_share: float) -> list[JsonObject]:
    grouped: dict[str, list[Run]] = defaultdict(list)
    for run in runs:
        grouped[run.profile].append(run)
    table: list[JsonObject] = []
    for profile, members in grouped.items():
        spins = [run for run in members if is_spin(run, min_rounds, top_share)]
        table.append(
            {
                "profile": profile,
                "runs": len(members),
                "rounds": sum(run.rounds for run in members),
                "runs_ge_100": sum(1 for run in members if run.rounds >= LONG_RUN_ROUNDS[0]),
                "runs_ge_400": sum(1 for run in members if run.rounds >= LONG_RUN_ROUNDS[1]),
                "spin_runs": len(spins),
                "spin_rounds": sum(run.rounds for run in spins),
            }
        )
    return sorted(table, key=lambda row: -cast("int", row["rounds"]))


def day_table(runs: list[Run]) -> list[JsonObject]:
    grouped: dict[str, list[Run]] = defaultdict(list)
    for run in runs:
        grouped[day_of(run.start)].append(run)
    table: list[JsonObject] = []
    for day in sorted(grouped):
        members = grouped[day]
        long_runs = [run for run in members if run.rounds >= LONG_RUN_ROUNDS[0]]
        table.append(
            {
                "day": day,
                "runs": len(members),
                "rounds": sum(run.rounds for run in members),
                "runs_ge_100": len(long_runs),
                "rounds_in_ge_100": sum(run.rounds for run in long_runs),
            }
        )
    return table


def spin_rows(runs: list[Run], min_rounds: int, top_share: float) -> list[JsonObject]:
    rows: list[JsonObject] = []
    for run in sorted(runs, key=lambda item: -item.rounds):
        if not is_spin(run, min_rounds, top_share):
            continue
        rows.append(
            {
                "keeper": run.keeper,
                "day": day_of(run.start),
                "profile": run.profile,
                "rounds": run.rounds,
                "hours": round((run.end - run.start) / SECONDS_PER_HOUR, 2),
                "top_tool": run.top_tool,
                "top_tool_calls": run.top_tool_calls,
                "tool_calls": run.tool_calls,
                "ended_by": run.error_kind or "the model answered",
            }
        )
    return rows


def bucket_names() -> list[str]:
    bounds = RUN_SIZE_BUCKETS
    return [
        f"{bounds[index]}-{bounds[index + 1] - 1} rounds" if index + 1 < len(bounds) else f"{bounds[index]}+ rounds"
        for index in range(len(bounds))
    ]


def bucket_name(rounds: int) -> str:
    names = bucket_names()
    for index in range(len(RUN_SIZE_BUCKETS) - 1, -1, -1):
        if rounds >= RUN_SIZE_BUCKETS[index]:
            return names[index]
    return names[0]


def run_containing(runs: list[Run], ts: float) -> Run | None:
    for run in runs:
        if run.start <= ts <= run.end:
            return run
    return None


def arrivals_during_runs(runs: list[Run], acks: list[Ack], first_day: date | None, last_day: date | None) -> JsonObject:
    by_keeper: dict[str, list[Run]] = defaultdict(list)
    for run in runs:
        by_keeper[run.keeper].append(run)
    considered = 0
    during: list[tuple[Ack, Run]] = []
    for ack in acks:
        keeper_runs = by_keeper.get(ack.keeper)
        if not keeper_runs or not in_window(ack.arrived, first_day, last_day):
            continue
        if not min(run.start for run in keeper_runs) <= ack.arrived <= max(run.end for run in keeper_runs):
            continue
        considered += 1
        run = run_containing(keeper_runs, ack.arrived)
        if run is not None:
            during.append((ack, run))
    by_bucket: dict[str, list[tuple[Ack, Run]]] = defaultdict(list)
    by_kind: dict[str, list[tuple[Ack, Run]]] = defaultdict(list)
    for ack, run in during:
        by_bucket[bucket_name(run.rounds)].append((ack, run))
        by_kind[ack.kind].append((ack, run))

    def summarize(pairs: list[tuple[Ack, Run]]) -> JsonObject:
        blocked = sorted((run.end - ack.arrived) / SECONDS_PER_MINUTE for ack, run in pairs)
        return {
            "rows": len(pairs),
            "immediate": sum(1 for ack, _ in pairs if ack.urgency == IMMEDIATE),
            "blocked_hours": round(sum(blocked) / SECONDS_PER_MINUTE, 1),
            "blocked_minutes_p50": round(percentile(blocked, P50), 1),
            "blocked_minutes_p90": round(percentile(blocked, P90), 1),
            "blocked_hours_max": round(blocked[-1] / SECONDS_PER_MINUTE, 2),
        }

    return {
        "acked_rows_in_coverage": considered,
        "arrived_during_a_run": len(during),
        "acked_before_run_end": sum(1 for ack, run in during if ack.acked < run.end),
        "visible_at_next_round": visible_at_next_round(during),
        "by_run_size": {name: summarize(by_bucket[name]) for name in bucket_names() if name in by_bucket},
        "by_kind": {
            kind: summarize(pairs) for kind, pairs in sorted(by_kind.items(), key=lambda item: -len(item[1]))
        },
        "by_day": arrivals_by_day(
            [ack for ack in acks if in_window(ack.arrived, first_day, last_day)], during, runs
        ),
    }


def next_round_after(run: Run, ts: float) -> float | None:
    for round_time in run.round_times:
        if round_time >= ts:
            return round_time
    return None


def visible_at_next_round(during: list[tuple[Ack, Run]]) -> JsonObject:
    """The wait to the next round against the wait to the run's end, for the same rows."""
    waits: list[float] = []
    saved: list[float] = []
    in_runs_without_rounds = 0
    after_the_last_round = 0
    for ack, run in during:
        later = next_round_after(run, ack.arrived)
        if later is None or later > run.end:
            if run.rounds == 0:
                in_runs_without_rounds += 1
            else:
                after_the_last_round += 1
            continue
        waits.append(later - ack.arrived)
        saved.append(run.end - later)
    apart: JsonObject = {
        "rows_in_runs_without_rounds": in_runs_without_rounds,
        "rows_after_the_last_round": after_the_last_round,
    }
    if not waits:
        return {"rows": 0, **apart}
    waits.sort()
    return {
        "rows": len(waits),
        **apart,
        "seconds_to_next_round_p50": round(percentile(waits, P50), 1),
        "seconds_to_next_round_p90": round(percentile(waits, P90), 1),
        "seconds_to_next_round_max": round(waits[-1], 1),
        "hours_earlier_than_the_run_end": round(sum(saved) / SECONDS_PER_HOUR, 1),
    }


def arrivals_by_day(acks: list[Ack], during: list[tuple[Ack, Run]], runs: list[Run]) -> list[JsonObject]:
    """Per UTC day of arrival, from the first day of a run to the last: every acknowledged row, the ones
    that arrived inside a run, their wait. Days before the first trace have no run to arrive inside."""
    if not runs:
        return []
    first_day, last_day = day_of(min(run.start for run in runs)), day_of(max(run.end for run in runs))
    acked: Counter[str] = Counter(
        day for day in (day_of(ack.arrived) for ack in acks) if first_day <= day <= last_day
    )
    inside: Counter[str] = Counter()
    blocked: dict[str, float] = defaultdict(float)
    for ack, run in during:
        day = day_of(ack.arrived)
        inside[day] += 1
        blocked[day] += (run.end - ack.arrived) / SECONDS_PER_HOUR
    return [
        {
            "day": day,
            "acked_rows": acked[day],
            "arrived_during_a_run": inside[day],
            "blocked_hours": round(blocked[day], 1),
        }
        for day in sorted(acked)
    ]


def measure(
    base: pathlib.Path,
    first_day: date | None,
    last_day: date | None,
    spin_min_rounds: int,
    spin_top_share: float,
) -> JsonObject:
    unreadable = Unreadable()
    runs = [run for run in read_runs(base, unreadable) if in_window(run.start, first_day, last_day)]
    acks = read_acks(base, unreadable)
    window = (
        {"first_run_utc": day_of(min(run.start for run in runs)), "last_run_utc": day_of(max(run.end for run in runs))}
        if runs
        else {}
    )
    return {
        "window": window,
        "read_at_utc": datetime.now(UTC).strftime("%Y-%m-%dT%H:%MZ"),
        "unreadable_lines": unreadable.lines,
        "unreadable_files": unreadable.files,
        "runs": {
            **round_stats(runs),
            **{f"ge_{threshold}": long_run_stats(runs, threshold) for threshold in LONG_RUN_ROUNDS},
        },
        "by_profile": profile_table(runs, spin_min_rounds, spin_top_share),
        "by_day": day_table(runs),
        "spin_runs": spin_rows(runs, spin_min_rounds, spin_top_share),
        "arrivals_during_runs": arrivals_during_runs(runs, acks, first_day, last_day),
    }


BLUE, ORANGE, RED, GREY = "#6b8fb5", "#d9822b", "#b5483a", "#b8b8b8"


def day_axis(rows: list[JsonObject]) -> list[str]:
    """Every UTC day from the first to the last row; a day without a row still gets a slot."""
    if not rows:
        return []
    first = parse_day(cast("str", rows[0]["day"]))
    last = parse_day(cast("str", rows[-1]["day"]))
    return [(first + timedelta(days=offset)).isoformat() for offset in range((last - first).days + 1)]


def svg_chart(result: JsonObject) -> str:
    """Two bar panels per UTC day: model requests of runs, and queue wait behind runs.

    A day with no round record is a grey tick in both panels. The raw traces of that
    day are gone, so the panels say nothing about it; it is not a day with no waiting.
    """
    run_rows = cast("list[JsonObject]", result["by_day"])
    rounds_of = {cast("str", row["day"]): cast("int", row["rounds"]) for row in run_rows}
    long_of = {cast("str", row["day"]): cast("int", row["rounds_in_ge_100"]) for row in run_rows}
    waits = {
        cast("str", row["day"]): cast("float", row["blocked_hours"])
        for row in cast("list[JsonObject]", cast("JsonObject", result["arrivals_during_runs"])["by_day"])
    }
    days = day_axis(run_rows)
    width, panel_height, left, bottom_pad, top1 = 760, 170, 56, 28, 40
    bar_width = max(6, (width - left - 20) // max(1, len(days)) - 4)
    plot_height = panel_height - bottom_pad - 10
    top_rounds = max(list(rounds_of.values()) + [1])
    top_wait = max(list(waits.values()) + [1.0])
    top2 = top1 + panel_height + 30
    height = top2 + panel_height + 28
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img" '
        'font-family="system-ui, sans-serif" font-size="11">',
        f'<rect width="{width}" height="{height}" fill="#ffffff"/>',
        '<text x="56" y="16" font-weight="600">Model requests per day (rounds), by the size of the run they belong to</text>',
    ]
    for x, color, label in ((56, BLUE, "runs under 100 rounds"), (230, ORANGE, "runs of 100 rounds or more"), (440, GREY, "no round records that day")):
        parts.append(f'<rect x="{x}" y="23" width="8" height="8" fill="{color}"/>')
        parts.append(f'<text x="{x + 12}" y="31">{label}</text>')

    def bar(x: float, y_base: float, value: float, scale: float, color: str) -> str:
        height = value * scale
        return f'<rect x="{x}" y="{y_base - height:.1f}" width="{bar_width}" height="{height:.1f}" fill="{color}"/>'

    def tick(x: float, y_base: float) -> str:
        return f'<rect x="{x}" y="{y_base - 3}" width="{bar_width}" height="3" fill="{GREY}"/>'

    def day_label(x: float, y_base: float, day: str, recorded: bool) -> str:
        fill = "#000000" if recorded else "#8a8a8a"
        return f'<text x="{x}" y="{y_base + 12}" font-size="8" fill="{fill}" transform="rotate(60 {x} {y_base + 12})">{day[5:]}</text>'

    base1 = top1 + panel_height - bottom_pad
    base2 = top2 + panel_height - bottom_pad
    for index, day in enumerate(days):
        x = left + index * (bar_width + 4)
        recorded = rounds_of.get(day, 0) > 0
        if recorded:
            scale = plot_height / top_rounds
            short = rounds_of[day] - long_of[day]
            parts.append(bar(x, base1, short, scale, BLUE))
            parts.append(bar(x, base1 - short * scale, long_of[day], scale, ORANGE))
        else:
            parts.append(tick(x, base1))
        parts.append(day_label(x, base1, day, recorded))
    parts.append(f'<text x="4" y="{base1 - plot_height + 8}">{top_rounds}</text>')
    parts.append(f'<text x="4" y="{base1}">0</text>')
    parts.append(f'<text x="56" y="{top2 - 6}" font-weight="600">Hours queue rows waited at least, behind the run that was going on</text>')
    for index, day in enumerate(days):
        x = left + index * (bar_width + 4)
        recorded = rounds_of.get(day, 0) > 0
        if recorded:
            parts.append(bar(x, base2, waits.get(day, 0.0), plot_height / top_wait, RED))
        else:
            parts.append(tick(x, base2))
        parts.append(day_label(x, base2, day, recorded))
    parts.append(f'<text x="4" y="{base2 - plot_height + 8}">{top_wait:.0f} h</text>')
    parts.append(f'<text x="4" y="{base2}">0</text>')
    parts.append(
        f'<text x="56" y="{height - 4}" font-size="9" fill="#555555">A grey tick is a day with no round record. '
        "Days with few records are partial too: raw traces are rotated away.</text>"
    )
    parts.append("</svg>")
    return "\n".join(parts)


def parse_day(text: str) -> date:
    return datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=UTC).date()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", help="first UTC day of a run's start or a row's arrival, YYYY-MM-DD")
    parser.add_argument("--to-date", help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--spin-min-rounds", type=int, default=150)
    parser.add_argument("--spin-top-share", type=float, default=0.85)
    parser.add_argument("--json-out", type=pathlib.Path)
    parser.add_argument("--svg-out", type=pathlib.Path)
    args = parser.parse_args()
    first_day = parse_day(args.from_date) if args.from_date else None
    last_day = parse_day(args.to_date) if args.to_date else None
    if first_day and last_day and first_day > last_day + timedelta(days=0):
        parser.error("--from-date is after --to-date")
    result = measure(args.base_path.expanduser(), first_day, last_day, args.spin_min_rounds, args.spin_top_share)
    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.json_out:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    if args.svg_out:
        args.svg_out.write_text(svg_chart(result) + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
