#!/usr/bin/env python3
"""Measure where Keeper turn time goes and what chat operations wait for.

Reads three stores under `<base-path>/.masc`, never writes to them:

- `tool_calls/YYYY-MM/DD[.NNN].jsonl`: the tool-call ledger (`record_kind` is
  `tool_call`). `ts` is the time the call ended; `duration_ms` is its length.
- `keeper_turn_events/<keeper>/*.jsonl`: one trace file per turn run. The first
  line is the run's first event, the last line its last event.
- `keepers/<keeper>/chat-operations.sqlite3`: delegated and chat operations,
  opened read-only. One operation per Keeper runs at a time.
- `agent-core-events/YYYY-MM/DD.jsonl`: MASC bus events. Only the
  `provider_admission:waited` ones are read: a model request that found every
  permit of its provider account held and queued.

Definitions:

- run interval: [first event ts, last event ts] of one trace file. Turn time of
  a Keeper is the union of its run intervals, so overlapping runs count once.
- tool time: the sum of `duration_ms` over all calls.
- inside seconds: the part of a call or of a gap that lies in the turn time of
  the call's Keeper. The ledger and the trace files are written by different
  code, so a call can lie outside every run interval of its Keeper: its turn
  wrote no trace file, or its turn has one and the call still lies before the
  file's first event or after its last. Shares of turn time use inside seconds
  only. The sums in `tool_time_s` and `between_calls` keep every call. A Keeper
  without any trace file in the window has no turn time, so all its calls have
  zero inside seconds by construction (`keepers_without_any_trace_file`).
- trace file: `keeper_turn_events/<keeper>/trace-<id>-<run>-<turn>-<hash>.jsonl`.
  A call has one when a file of its Keeper is named for its `trace_id` and
  `keeper_turn_id`. Only the file names are read, so a file pruned after the
  window makes its calls look untraced. In the 2026-11 code the only writer is
  `Keeper_autonomous_stream.create` (lib/keeper/keeper_autonomous_stream.ml),
  so a `direct` turn (`Keeper_turn.run_direct_turn_with_fsm`, the turn that
  answers a `masc_keeper_msg` message) writes none.
- traced call outside the turn time: a call whose turn has a trace file and
  of which more than a microsecond lies outside the turn time of its Keeper.
  `traced_calls_outside_turns` counts them and their outside seconds, in total
  and by `turn_kind`. `calls_partly_inside_turn_time` counts the ones that also
  have seconds inside, and `turns_that_also_have_autonomous_calls` counts the
  turns among them whose key also carries an `autonomous` call.
- turn kind set: the `turn_kind` values of the calls of one turn, joined with
  `+` (`direct`, `autonomous`, `autonomous+direct`). The ledger writes
  `turn_kind` per call, so one turn key can carry both. `turns_by_kind_set`
  splits every turn of the window into exactly one set.
- between-calls time: inside one turn (`trace_id`, `keeper_turn_id`), calls sorted
  by start (`ts` minus duration). The gap before every call after the first is
  its start minus the previous call's end. Overlapping calls count as 0.
  The gap holds model inference and provider queueing together.
- reread: a call whose (keeper, tool, `input_fingerprint`) was seen at most one
  hour earlier with the same `output_fingerprint`. Same rule as
  scripts/measure-tool-efficiency.py, except the one-hour memory carries over
  midnight here.
- long Execute: an Execute call of 60 seconds or more. Polling when its command
  has `sleep`, a `for ... in`, `while` or `until`.
- queue wait: `started_at` minus `created_at` of an operation. An operation is
  a delegate when its source has a `sender_keeper`.
- admission wait: `waited_ms` of a `provider_admission:waited` event. A request
  granted a permit at once is not reported, so the events are the requests that
  queued.
- tool transitions: for each pair of consecutive calls in a turn, the gap goes
  to the pair (previous tool, next tool). Pairs of the same tool are kept apart
  from pairs of different tools.
- batch size: the ledger's `batch_size`, the number of tool calls the model
  asked for in one response. Execution mode: its `execution_mode`
  (`serial` or `concurrent`), set by the tool's descriptor in agent_core.
- schedule wake: a `stimulus` row of a Keeper's reaction ledger
  (`keepers/<keeper>/reaction-ledger/v7/YYYY-MM/DD.jsonl`) is an event that
  entered the Keeper's event queue at `stimulus.arrived_at_unix`. Its first
  `turn_started` reaction ends the wait. A stimulus whose only reaction is
  `event_queue_cancelled` never started a turn. The reaction files of the day
  after `--to-date` are read too, so a wake that started just after the window
  is not counted as unstarted.
- cancelled during Execute: an operation that failed with `Turn_cancelled` and
  whose `completed_at` falls inside an Execute call of the same Keeper
  (`start - 3 s` .. `end + 3 s`; the ledger writes a call's row when it
  returns). The Execute time lost is the part that had run by `completed_at`.

Nothing here reads message text. Command text is read only for the polling test.

Usage:
    docs/evidence/lane-time-2026-11/measure_lane_time.py --base-path ~/me \
        --from-date 2026-11-01 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sqlite3
import statistics
import sys
from bisect import bisect_right
from collections import Counter, defaultdict
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

import masc_base_path  # noqa: E402
from tool_call_log_paths import tool_call_log_paths  # noqa: E402

TOOL_CALL_RECORD_KIND = "tool_call"
EXECUTE_TOOL = "Execute"
LONG_EXECUTE_SEC = 60.0
REREAD_WINDOW_SEC = 3600.0
TRACE_TAIL_BYTES = 65536
TRACE_FILE_NAME = re.compile(r"^(trace-\d+-\d+)-(\d+)-[0-9a-f]+\.jsonl$")
AUTONOMOUS_TURN_KIND = "autonomous"
FLOAT_NOISE_S = 1e-6
SECONDS_PER_HOUR = 3600.0
SECONDS_PER_MINUTE = 60.0
ADMISSION_MARKER = b"provider_admission:waited"
ADMISSION_WAIT_HOURS_HIGH = 5.0
TOP_TOOL_TRANSITIONS = 10
WAKE_TAIL_SEC = 1800.0
TOP_WAKE_KEEPERS = 5
REACTION_LEDGER_DIR = pathlib.PurePosixPath("reaction-ledger") / "v7"
TURN_STARTED = "turn_started"
QUEUE_CANCELLED = "event_queue_cancelled"
CANCELLED_TURN = "Turn_cancelled"
CANCEL_MATCH_SLACK_SEC = 3.0
POLL_COMMAND = re.compile(r"\bsleep\b|\bfor\s+\w+\s+in\b|\bwhile\b|\buntil\b")

Interval = tuple[float, float]


@dataclass(frozen=True, slots=True)
class Call:
    keeper: str
    turn: str
    tool: str
    start: float
    end: float
    reread: bool
    polling: bool
    batch_size: int = 0
    mode: str = "unknown"
    turn_kind: str = "unknown"


@dataclass(frozen=True, slots=True)
class Operation:
    keeper: str
    origin: str
    state: str
    created_at: float
    started_at: float | None
    completed_at: float | None
    failure_kind: str | None


@dataclass(frozen=True, slots=True)
class Wake:
    keeper: str
    arrived: float
    started: float | None
    cancelled: bool


@dataclass(frozen=True, slots=True)
class AdmissionWait:
    ts: float
    provider: str
    model: str
    admission_class: str
    waited_s: float


def text_of(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def number_of(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def command_text(value: object) -> str:
    if not isinstance(value, dict):
        return ""
    for key in ("command", "cmd"):
        found = value.get(key)
        if isinstance(found, str) and found.strip():
            return found
    argv = value.get("argv")
    if isinstance(argv, list) and all(isinstance(part, str) for part in argv):
        return " ".join(argv)
    return ""


def ledger_files(base: pathlib.Path, day: date) -> list[pathlib.Path]:
    live = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
    return tool_call_log_paths(base, live)


def read_calls(base: pathlib.Path, first: date, last: date, until: float) -> list[Call]:
    calls: list[Call] = []
    last_seen: dict[tuple[str, str, str], tuple[float, str]] = {}
    day = first
    while day <= last:
        for path in ledger_files(base, day):
            with path.open("rb") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict) or row.get("record_kind") != TOOL_CALL_RECORD_KIND:
                        continue
                    end = number_of(row.get("ts"))
                    if end is None or end > until:
                        continue
                    duration = (number_of(row.get("duration_ms")) or 0.0) / 1000.0
                    keeper = text_of(row.get("keeper")) or "?"
                    tool = text_of(row.get("tool")) or "?"
                    turn = f"{keeper}/{text_of(row.get('trace_id')) or '?'}#{row.get('keeper_turn_id')}"
                    reread = False
                    input_fp = text_of(row.get("input_fingerprint"))
                    output_fp = text_of(row.get("output_fingerprint"))
                    if input_fp is not None and output_fp is not None:
                        key = (keeper, tool, input_fp)
                        previous = last_seen.get(key)
                        reread = previous is not None and previous[1] == output_fp and end - previous[0] <= REREAD_WINDOW_SEC
                        last_seen[key] = (end, output_fp)
                    polling = tool == EXECUTE_TOOL and POLL_COMMAND.search(command_text(row.get("input"))) is not None
                    batch_size = row.get("batch_size")
                    calls.append(
                        Call(
                            keeper,
                            turn,
                            tool,
                            end - duration,
                            end,
                            reread,
                            polling,
                            batch_size if isinstance(batch_size, int) and batch_size >= 1 else 0,
                            text_of(row.get("execution_mode")) or "unknown",
                            text_of(row.get("turn_kind")) or "unknown",
                        )
                    )
        day += timedelta(days=1)
    return calls


def union_seconds(intervals: list[Interval]) -> float:
    total = 0.0
    current: Interval | None = None
    for start, end in sorted(intervals):
        if current is None or start > current[1]:
            if current is not None:
                total += current[1] - current[0]
            current = (start, end)
        else:
            current = (current[0], max(current[1], end))
    if current is not None:
        total += current[1] - current[0]
    return total


def overlap_seconds(start: float, end: float, intervals: list[Interval]) -> float:
    """Time of [start, end] covered by the union of `intervals`."""
    clipped = [(max(a, start), min(b, end)) for a, b in intervals if b > start and a < end]
    return union_seconds(clipped)


@dataclass(frozen=True, slots=True)
class TurnClock:
    """The run intervals of one Keeper, merged into sorted spans that neither overlap nor touch."""

    spans: tuple[Interval, ...]
    starts: tuple[float, ...]

    @staticmethod
    def of(intervals: Iterable[Interval]) -> TurnClock:
        merged: list[Interval] = []
        for start, end in sorted(intervals):
            if merged and start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], end))
            else:
                merged.append((start, end))
        return TurnClock(tuple(merged), tuple(start for start, _ in merged))

    @property
    def seconds(self) -> float:
        return sum(end - start for start, end in self.spans)

    def overlap(self, start: float, end: float) -> float:
        """The seconds of [start, end] that lie in a span."""
        total = 0.0
        index = bisect_right(self.starts, end) - 1
        while index >= 0 and self.spans[index][1] > start:
            span_start, span_end = self.spans[index]
            total += min(end, span_end) - max(start, span_start)
            index -= 1
        return total


def first_event_ts(path: pathlib.Path) -> float | None:
    with path.open("rb") as handle:
        try:
            return number_of(json.loads(handle.readline()).get("ts"))
        except (ValueError, AttributeError):
            return None


def last_event_ts(path: pathlib.Path) -> float | None:
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        handle.seek(max(0, handle.tell() - TRACE_TAIL_BYTES))
        for line in reversed(handle.read().splitlines()):
            try:
                ts = number_of(json.loads(line).get("ts"))
            except (ValueError, AttributeError):
                continue
            if ts is not None:
                return ts
    return None


def read_runs(base: pathlib.Path, since: float, until: float) -> dict[str, list[Interval]]:
    runs: dict[str, list[Interval]] = defaultdict(list)
    root = base / ".masc" / "keeper_turn_events"
    if not root.is_dir():
        return runs
    for keeper_dir in sorted(root.iterdir()):
        if not keeper_dir.is_dir():
            continue
        for path in keeper_dir.glob("*.jsonl"):
            try:
                if path.stat().st_mtime < since:
                    continue
            except OSError:
                continue
            start, end = first_event_ts(path), last_event_ts(path)
            if start is None or end is None or end < since or start > until:
                continue
            runs[keeper_dir.name].append((max(start, since), min(end, until)))
    return runs


def read_trace_keys(base: pathlib.Path) -> frozenset[str]:
    """`<keeper>/<trace id>#<turn id>` of every trace file, spelled like `Call.turn`."""
    keys: set[str] = set()
    root = base / ".masc" / "keeper_turn_events"
    if not root.is_dir():
        return frozenset()
    for keeper_dir in root.iterdir():
        if not keeper_dir.is_dir():
            continue
        for path in keeper_dir.glob("*.jsonl"):
            named = TRACE_FILE_NAME.match(path.name)
            if named is not None:
                keys.add(f"{keeper_dir.name}/{named.group(1)}#{named.group(2)}")
    return frozenset(keys)


def read_operations(base: pathlib.Path, since: float, until: float) -> list[Operation]:
    operations: list[Operation] = []
    for db in sorted((base / ".masc" / "keepers").glob("*/chat-operations.sqlite3")):
        try:
            connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            rows = connection.execute(
                "select state, created_at, started_at, completed_at, failure_kind, source_json from operations"
            ).fetchall()
            connection.close()
        except sqlite3.Error:
            continue
        for state, created, started, completed, failure_kind, source_json in rows:
            if created is None or created < since or created > until:
                continue
            try:
                source = json.loads(source_json)
            except (TypeError, ValueError):
                source = {}
            source = source if isinstance(source, dict) else {}
            origin = "delegate" if source.get("sender_keeper") else f"channel:{source.get('channel')}"
            operations.append(Operation(db.parent.name, origin, str(state), float(created), started, completed, failure_kind))
    return operations


def read_wakes(base: pathlib.Path, first: date, last: date, since: float, until: float) -> list[Wake]:
    """Stimuli that arrived in [since, until], with their first `turn_started` (read through the day after `last`)."""
    arrived: dict[tuple[str, str], float] = {}
    started: dict[tuple[str, str], float] = {}
    cancelled: set[tuple[str, str]] = set()
    for keeper_dir in sorted((base / ".masc" / "keepers").glob("*")):
        ledger = keeper_dir / REACTION_LEDGER_DIR
        day = first
        while day <= last + timedelta(days=1):
            path = ledger / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
            day += timedelta(days=1)
            if not path.is_file():
                continue
            with path.open("rb") as handle:
                for line in handle:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    keeper, stimulus_id = text_of(row.get("keeper_name")), text_of(row.get("stimulus_id"))
                    if keeper is None or stimulus_id is None:
                        continue
                    key = (keeper, stimulus_id)
                    if row.get("record_kind") == "stimulus":
                        stimulus = row.get("stimulus")
                        at = number_of(stimulus.get("arrived_at_unix")) if isinstance(stimulus, dict) else None
                        if at is not None and since <= at <= until:
                            arrived[key] = at
                    elif row.get("record_kind") == "reaction":
                        reaction = row.get("reaction")
                        kind = text_of(reaction.get("kind")) if isinstance(reaction, dict) else None
                        recorded = number_of(row.get("recorded_at_unix"))
                        if kind == TURN_STARTED and recorded is not None:
                            started[key] = min(recorded, started.get(key, recorded))
                        elif kind == QUEUE_CANCELLED:
                            cancelled.add(key)
    return [Wake(key[0], at, started.get(key), key in cancelled) for key, at in sorted(arrived.items())]


def read_admission_waits(base: pathlib.Path, since: float, until: float) -> list[AdmissionWait]:
    waits: list[AdmissionWait] = []
    day = datetime.fromtimestamp(since, timezone.utc).date()
    last = datetime.fromtimestamp(until, timezone.utc).date()
    while day <= last:
        path = base / ".masc" / "agent-core-events" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
        if path.is_file():
            with path.open("rb") as handle:
                for line in handle:
                    if ADMISSION_MARKER not in line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(event, dict):
                        continue
                    ts = number_of(event.get("ts_unix"))
                    payload = event.get("payload")
                    waited_ms = number_of(payload.get("waited_ms")) if isinstance(payload, dict) else None
                    if ts is None or waited_ms is None or ts < since or ts > until or not isinstance(payload, dict):
                        continue
                    waits.append(
                        AdmissionWait(
                            ts,
                            str(payload.get("provider_id")),
                            str(payload.get("model")),
                            str(payload.get("admission_class")),
                            waited_ms / 1000.0,
                        )
                    )
        day += timedelta(days=1)
    return waits


def quantiles(values: list[float]) -> dict[str, float | int]:
    if not values:
        return {"n": 0}
    ordered = sorted(values)

    def at(fraction: float) -> float:
        return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]

    return {
        "n": len(ordered),
        "p50_s": round(at(0.5), 1),
        "p90_s": round(at(0.9), 1),
        "mean_s": round(statistics.fmean(ordered), 1),
        "sum_s": round(sum(ordered), 1),
    }


def count_quantiles(values: list[int]) -> dict[str, float | int]:
    if not values:
        return {"n": 0}
    ordered = sorted(values)

    def at(fraction: float) -> int:
        return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]

    return {
        "n": len(ordered),
        "p50": at(0.5),
        "p90": at(0.9),
        "p99": at(0.99),
        "max": ordered[-1],
        "mean": round(statistics.fmean(ordered), 1),
    }


def ranked_transitions(
    pair_count: Counter[tuple[str, str]], pair_gap_s: dict[tuple[str, str], float], *, same_tool: bool
) -> dict[str, object]:
    """Total and top pairs by gap, for pairs of one tool (`same_tool`) or of two different tools."""
    chosen = [(pair, seconds) for pair, seconds in pair_gap_s.items() if (pair[0] == pair[1]) == same_tool]
    chosen.sort(key=lambda item: (-item[1], item[0]))
    return {
        "pairs": sum(pair_count[pair] for pair, _ in chosen),
        "gap_s": round(sum(seconds for _, seconds in chosen), 1),
        "top_by_gap": [
            {
                "from": pair[0],
                "to": pair[1],
                "pairs": pair_count[pair],
                "gap_s": round(seconds, 1),
                "mean_gap_s": round(seconds / pair_count[pair], 1),
            }
            for pair, seconds in chosen[:TOP_TOOL_TRANSITIONS]
        ],
    }


def percent(part: float, whole: float) -> float | None:
    return round(part / whole * 100, 1) if whole > 0 else None


def seconds_inside(clocks: Mapping[str, TurnClock], keeper: str, start: float, end: float) -> float:
    """The seconds of start..end that lie in the turn time of the Keeper; a Keeper without a clock has none."""
    clock = clocks.get(keeper)
    return clock.overlap(start, end) if clock is not None and end > start else 0.0


def summarize_inside_turns(calls: list[Call], clocks: Mapping[str, TurnClock]) -> dict[str, object]:
    """The tool, gap, reread, long and polling seconds that lie in the Keeper's turn time, and their share of it."""
    turn_s = sum(clock.seconds for clock in clocks.values())
    tool_s = execute_s = long_s = polling_s = gap_s = reread_s = 0.0
    polling_by_keeper: dict[str, float] = defaultdict(float)
    by_turn: dict[str, list[Call]] = defaultdict(list)
    for call in calls:
        by_turn[call.turn].append(call)
        seconds = seconds_inside(clocks, call.keeper, call.start, call.end)
        tool_s += seconds
        if call.tool == EXECUTE_TOOL:
            execute_s += seconds
            if call.end - call.start >= LONG_EXECUTE_SEC:
                long_s += seconds
                if call.polling:
                    polling_s += seconds
                    if seconds > 0.0:
                        polling_by_keeper[call.keeper] += seconds
    for turn_calls in by_turn.values():
        turn_calls.sort(key=lambda call: (call.start, call.end))
        for previous, current in zip(turn_calls, turn_calls[1:]):
            gap = seconds_inside(clocks, current.keeper, previous.end, current.start)
            gap_s += gap
            if current.reread:
                reread_s += gap + seconds_inside(clocks, current.keeper, current.start, current.end)
    other_s = turn_s - tool_s - gap_s
    return {
        "tool_time_s": round(tool_s, 1),
        "execute_time_s": round(execute_s, 1),
        "between_calls_s": round(gap_s, 1),
        "other_turn_time_s": round(other_s, 1),
        "rereads_after_first_call_turn_time_s": round(reread_s, 1),
        "long_execute_time_s": round(long_s, 1),
        "polling_time_s": round(polling_s, 1),
        "polling_by_keeper": {
            keeper: {"polling_s": round(seconds, 1), "turn_time_s": round(clocks[keeper].seconds, 1)}
            for keeper, seconds in sorted(polling_by_keeper.items(), key=lambda item: -item[1])
        },
        "percent_of_turn_time": {
            "tool": percent(tool_s, turn_s),
            "execute": percent(execute_s, turn_s),
            "between_calls": percent(gap_s, turn_s),
            "other": percent(other_s, turn_s),
            "rereads_after_first_call": percent(reread_s, turn_s),
            "long_execute": percent(long_s, turn_s),
            "polling": percent(polling_s, turn_s),
        },
    }


def summarize_untraced(calls: list[Call], trace_keys: frozenset[str], clocks: Mapping[str, TurnClock]) -> dict[str, object]:
    """The calls of turns that have no trace file, and how many of their seconds the Keepers' turn time covers."""
    untraced = [call for call in calls if call.turn not in trace_keys]
    kinds_of_turn: dict[str, set[str]] = defaultdict(set)
    for call in calls:
        kinds_of_turn[call.turn].add(call.turn_kind)
    turns_by_kind_set: dict[str, dict[str, int]] = {}
    for turn, kinds in kinds_of_turn.items():
        counts = turns_by_kind_set.setdefault("+".join(sorted(kinds)), {"turns": 0, "without_trace_file": 0})
        counts["turns"] += 1
        counts["without_trace_file"] += int(turn not in trace_keys)
    without_clock = [call for call in untraced if call.keeper not in clocks]
    with_clock = [call for call in untraced if call.keeper in clocks]

    def block(members: list[Call]) -> dict[str, object]:
        return {
            "calls": len(members),
            "tool_time_s": round(sum(call.end - call.start for call in members), 1),
            "execute_time_s": round(sum(call.end - call.start for call in members if call.tool == EXECUTE_TOOL), 1),
        }

    def by_turn_kind(members: list[Call]) -> dict[str, dict[str, object]]:
        grouped: dict[str, list[Call]] = defaultdict(list)
        for call in members:
            grouped[call.turn_kind].append(call)
        return {kind: block(group) for kind, group in sorted(grouped.items())}

    return {
        **block(untraced),
        "turns": len({call.turn for call in untraced}),
        "tool_time_inside_turns_s": round(sum(seconds_inside(clocks, call.keeper, call.start, call.end) for call in untraced), 1),
        "keepers_with_a_trace_file": {**block(with_clock), "by_turn_kind": by_turn_kind(with_clock)},
        "keepers_without_any_trace_file": {
            "keepers": sorted({call.keeper for call in without_clock}),
            **block(without_clock),
            "by_turn_kind": by_turn_kind(without_clock),
        },
        "turns_in_window": len(kinds_of_turn),
        "turns_by_kind_set": dict(sorted(turns_by_kind_set.items())),
        "by_turn_kind": by_turn_kind(untraced),
    }


def summarize_traced_outside(calls: list[Call], trace_keys: frozenset[str], clocks: Mapping[str, TurnClock]) -> dict[str, object]:
    """The calls of turns that have a trace file but lie partly or wholly outside the turn time of their Keeper."""
    kinds_of_turn: dict[str, set[str]] = defaultdict(set)
    for call in calls:
        kinds_of_turn[call.turn].add(call.turn_kind)
    hits: list[tuple[Call, float, float]] = []  # call, inside seconds, outside seconds
    for call in calls:
        if call.turn not in trace_keys:
            continue
        inside_s = seconds_inside(clocks, call.keeper, call.start, call.end)
        outside_s = (call.end - call.start) - inside_s
        if outside_s > FLOAT_NOISE_S:
            hits.append((call, inside_s, outside_s))
    by_kind: dict[str, list[tuple[Call, float, float]]] = defaultdict(list)
    for hit in hits:
        by_kind[hit[0].turn_kind].append(hit)
    turns = {call.turn for call, _, _ in hits}

    def block(members: list[tuple[Call, float, float]]) -> dict[str, object]:
        return {
            "calls": len(members),
            "tool_time_outside_turns_s": round(sum(outside_s for _, _, outside_s in members), 1),
            "execute_time_outside_turns_s": round(sum(outside_s for call, _, outside_s in members if call.tool == EXECUTE_TOOL), 1),
        }

    return {
        **block(hits),
        "turns": len(turns),
        "calls_partly_inside_turn_time": sum(1 for _, inside_s, _ in hits if inside_s > FLOAT_NOISE_S),
        "turns_that_also_have_autonomous_calls": sum(1 for turn in turns if AUTONOMOUS_TURN_KIND in kinds_of_turn[turn]),
        "by_turn_kind": {kind: block(members) for kind, members in sorted(by_kind.items())},
    }


def summarize_calls(calls: list[Call], busy_by_keeper: dict[str, float]) -> dict[str, object]:
    by_turn: dict[str, list[Call]] = defaultdict(list)
    for call in calls:
        by_turn[call.turn].append(call)
    gaps: list[float] = []
    reread_gaps: list[float] = []
    overlapping = 0
    pair_count: Counter[tuple[str, str]] = Counter()
    pair_gap_s: dict[tuple[str, str], float] = defaultdict(float)
    for turn_calls in by_turn.values():
        turn_calls.sort(key=lambda call: (call.start, call.end))
        for previous, current in zip(turn_calls, turn_calls[1:]):
            gap = current.start - previous.end
            if gap < 0:
                overlapping += 1
                gap = 0.0
            gaps.append(gap)
            pair_count[(previous.tool, current.tool)] += 1
            pair_gap_s[(previous.tool, current.tool)] += gap
            if current.reread:
                reread_gaps.append(gap + (current.end - current.start))
    tool_s = sum(call.end - call.start for call in calls)
    execute_s = sum(call.end - call.start for call in calls if call.tool == EXECUTE_TOOL)
    busy_s = sum(busy_by_keeper.values())
    long_execute = [call for call in calls if call.tool == EXECUTE_TOOL and call.end - call.start >= LONG_EXECUTE_SEC]
    polling = [call for call in long_execute if call.polling]
    return {
        "turns": len(by_turn),
        "calls": len(calls),
        "calls_per_turn": count_quantiles([len(turn_calls) for turn_calls in by_turn.values()]),
        "calls_by_batch_size": {str(size): count for size, count in sorted(Counter(call.batch_size for call in calls).items())},
        "execution_modes": {
            mode: {
                "calls": sum(1 for call in calls if call.mode == mode),
                "time_s": round(sum(call.end - call.start for call in calls if call.mode == mode), 1),
            }
            for mode in sorted({call.mode for call in calls})
        },
        "turn_time_s": round(busy_s, 1),
        "tool_time_s": round(tool_s, 1),
        "execute_time_s": round(execute_s, 1),
        "between_calls": {**quantiles(gaps), "overlapping_pairs": overlapping},
        "tool_transitions": {
            "same_tool": ranked_transitions(pair_count, pair_gap_s, same_tool=True),
            "cross_tool": ranked_transitions(pair_count, pair_gap_s, same_tool=False),
        },
        "rereads_after_first_call": {"calls": len(reread_gaps), "turn_time_s": round(sum(reread_gaps), 1)},
        "long_execute": {
            "calls": len(long_execute),
            "time_s": round(sum(call.end - call.start for call in long_execute), 1),
            "polling_calls": len(polling),
            "polling_time_s": round(sum(call.end - call.start for call in polling), 1),
        },
    }


def decompose_waits(
    waits: list[tuple[str, float, float]],
    long_execute: dict[str, list[Interval]],
    runs: dict[str, list[Interval]],
) -> dict[str, object]:
    """Splits waits, given as (keeper, begin, end), by what the same Keeper was doing during them."""
    total_wait = overlap_long = overlap_run = 0.0
    blocked_waits: list[float] = []
    for keeper, begin, end in waits:
        wait = end - begin
        if wait <= 0:
            continue
        total_wait += wait
        overlap_long += overlap_seconds(begin, end, long_execute.get(keeper, []))
        overlap_run += overlap_seconds(begin, end, runs.get(keeper, []))
        if any(a <= begin < b for a, b in long_execute.get(keeper, [])):
            blocked_waits.append(wait)
    return {
        "total_wait_s": round(total_wait, 1),
        "wait_overlapping_long_execute_s": round(overlap_long, 1),
        "wait_overlapping_a_run_of_the_same_keeper_s": round(overlap_run, 1),
        "created_during_long_execute": quantiles(blocked_waits),
    }


def summarize_wakes(
    wakes: list[Wake],
    long_execute: dict[str, list[Interval]],
    runs: dict[str, list[Interval]],
) -> dict[str, object]:
    started = [wake for wake in wakes if wake.started is not None]
    latency = [max(wake.started - wake.arrived, 0.0) for wake in started if wake.started is not None]
    tail = [seconds for seconds in latency if seconds >= WAKE_TAIL_SEC]
    tail_by_keeper: dict[str, list[float]] = defaultdict(list)
    for wake in started:
        assert wake.started is not None
        if wake.started - wake.arrived >= WAKE_TAIL_SEC:
            tail_by_keeper[wake.keeper].append(wake.started - wake.arrived)
    top_tail = sorted(tail_by_keeper.items(), key=lambda item: (-sum(item[1]), item[0]))[:TOP_WAKE_KEEPERS]
    return {
        "stimuli": len(wakes),
        "turn_started": len(started),
        "cancelled_in_queue": sum(1 for wake in wakes if wake.started is None and wake.cancelled),
        "no_turn_started": sum(1 for wake in wakes if wake.started is None and not wake.cancelled),
        "latency": quantiles(latency),
        "waited_at_least_30_min": {
            "n": len(tail),
            "sum_s": round(sum(tail), 1),
            "top_keepers": [
                {"keeper": keeper, "n": len(waits), "sum_s": round(sum(waits), 1)} for keeper, waits in top_tail
            ],
        },
        **decompose_waits(
            [(wake.keeper, wake.arrived, wake.started) for wake in started if wake.started is not None],
            long_execute,
            runs,
        ),
    }


def summarize_operations(
    operations: list[Operation],
    long_execute: dict[str, list[Interval]],
    runs: dict[str, list[Interval]],
) -> dict[str, object]:
    started = [op for op in operations if op.started_at is not None]
    decomposition = decompose_waits(
        [(op.keeper, op.created_at, op.started_at) for op in started if op.started_at is not None],
        long_execute,
        runs,
    )
    by_origin: dict[str, dict[str, object]] = {}
    for origin in sorted({op.origin for op in operations}):
        group = [op for op in operations if op.origin == origin]
        waits = [op.started_at - op.created_at for op in group if op.started_at is not None]
        run_times = [
            op.completed_at - op.started_at
            for op in group
            if op.started_at is not None and op.completed_at is not None
        ]
        by_origin[origin] = {
            "operations": len(group),
            "states": dict(Counter(op.state for op in group)),
            "failure_kinds": dict(Counter(str(op.failure_kind) for op in group if op.state == "failed")),
            "wait": quantiles(waits),
            "run": quantiles(run_times),
        }
    return {
        "operations": len(operations),
        "started": len(started),
        **decomposition,
        "by_origin": by_origin,
    }


def summarize_cancelled_turns(
    operations: list[Operation],
    execute_calls: dict[str, list[Interval]],
) -> dict[str, object]:
    cancelled = [op for op in operations if op.failure_kind == CANCELLED_TURN and op.completed_at is not None]
    during = during_long = 0
    lost_s = lost_long_s = 0.0
    for op in cancelled:
        assert op.completed_at is not None
        for start, end in sorted(execute_calls.get(op.keeper, [])):
            if start - CANCEL_MATCH_SLACK_SEC <= op.completed_at <= end + CANCEL_MATCH_SLACK_SEC:
                ran_s = min(end - start, max(op.completed_at - start, 0.0))
                during += 1
                lost_s += ran_s
                if end - start >= LONG_EXECUTE_SEC:
                    during_long += 1
                    lost_long_s += ran_s
                break
    return {
        "turn_cancelled_operations": len(cancelled),
        "cancelled_during_execute": during,
        "cancelled_during_long_execute": during_long,
        "execute_time_lost_s": round(lost_s, 1),
        "long_execute_time_lost_s": round(lost_long_s, 1),
    }


def summarize_admission(waits: list[AdmissionWait]) -> dict[str, object]:
    by_provider: dict[str, float] = defaultdict(float)
    by_class: dict[str, float] = defaultdict(float)
    by_hour: dict[str, float] = defaultdict(float)
    for wait in waits:
        by_provider[f"{wait.provider}/{wait.model}"] += wait.waited_s
        by_class[wait.admission_class] += wait.waited_s
        by_hour[datetime.fromtimestamp(wait.ts, timezone.utc).strftime("%Y-%m-%dT%HZ")] += wait.waited_s
    hourly = sorted(seconds / SECONDS_PER_HOUR for seconds in by_hour.values())
    return {
        "events": len(waits),
        "wait": quantiles([wait.waited_s for wait in waits]),
        "by_provider_model_s": {
            key: round(seconds, 1) for key, seconds in sorted(by_provider.items(), key=lambda item: -item[1])[:8]
        },
        "by_class_s": {key: round(seconds, 1) for key, seconds in sorted(by_class.items())},
        "clock_hours_with_events": len(hourly),
        "median_wait_hours_per_clock_hour": round(hourly[len(hourly) // 2], 2) if hourly else None,
        "clock_hours_over_5_wait_hours": sum(1 for hours in hourly if hours > ADMISSION_WAIT_HOURS_HIGH),
    }


def parse_day(text: str) -> date:
    return date.fromisoformat(text)


def parse_until(text: str) -> float:
    moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--until", type=parse_until, required=True, help="ignore anything after this ISO-8601 time (UTC when it has no offset)")
    parser.add_argument("--json-out", default=None, help="write the summary to this file")
    args = parser.parse_args()
    base = masc_base_path.require(parser, args.base_path, "--base-path")

    since = datetime(args.from_date.year, args.from_date.month, args.from_date.day, tzinfo=timezone.utc).timestamp()
    calls = read_calls(base, args.from_date, args.to_date, args.until)
    runs = read_runs(base, since, args.until)
    clocks = {keeper: TurnClock.of(intervals) for keeper, intervals in runs.items()}
    busy_by_keeper = {keeper: clock.seconds for keeper, clock in clocks.items()}
    long_execute: dict[str, list[Interval]] = defaultdict(list)
    execute_calls: dict[str, list[Interval]] = defaultdict(list)
    for call in calls:
        if call.tool != EXECUTE_TOOL:
            continue
        execute_calls[call.keeper].append((call.start, call.end))
        if call.end - call.start >= LONG_EXECUTE_SEC:
            long_execute[call.keeper].append((call.start, call.end))
    operations = read_operations(base, since, args.until)
    trace_keys = read_trace_keys(base)
    summary = {
        "window": {
            "from": args.from_date.isoformat(),
            "to": args.to_date.isoformat(),
            "until": datetime.fromtimestamp(args.until, timezone.utc).isoformat(),
            "hours": round((args.until - since) / SECONDS_PER_HOUR, 2),
            "keepers_with_turn_traces": len(runs),
        },
        "turn_time": {
            **summarize_calls(calls, busy_by_keeper),
            "inside_turns": summarize_inside_turns(calls, clocks),
            "calls_without_trace_file": summarize_untraced(calls, trace_keys, clocks),
            "traced_calls_outside_turns": summarize_traced_outside(calls, trace_keys, clocks),
        },
        "chat_operations": summarize_operations(operations, long_execute, runs),
        "cancelled_turns": summarize_cancelled_turns(operations, execute_calls),
        "schedule_wakes": summarize_wakes(
            read_wakes(base, args.from_date, args.to_date, since, args.until), long_execute, runs
        ),
        "provider_admission": summarize_admission(read_admission_waits(base, since, args.until)),
    }
    text = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)
    print(text)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
