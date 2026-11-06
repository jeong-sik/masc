#!/usr/bin/env python3
"""Split the time Keeper-to-Keeper delegations take into queue wait and run, and replay
whether the target's live turn explains the wait.

Reads two stores under `<base-path>/.masc` and never writes to them:

- `keepers/<keeper>/chat-operations.sqlite3`: the `operations` table, opened read-only. The
  fields used are `operation_id`, `source_json`, `state`, `created_at`, `started_at` and
  `completed_at`. The Keeper whose database holds a row is the target of that operation.
- `tool_calls/YYYY-MM/DD.jsonl` and its `DD.NNN.jsonl` segments: rows with
  `record_kind == "tool_call"`. The fields used are `ts`, `keeper`, `keeper_turn_id`, `tool`,
  `output` and `duration_ms`. `ts` is the instant the row was written, after the call returned
  (`Keeper_tool_call_log.log_call` takes it while building the row and receives `duration_ms` as
  an argument), so a call ran from `ts - duration_ms` to `ts`. The `clock_check` block of the
  result tests that reading on the rows it reads.

Definitions:

- delegation: an operation whose `source_json` names a `sender_keeper`. Operations from the
  dashboard and other surfaces have none and are left out. A row whose `source_json` is not a
  JSON object, or whose id, state or `created_at` has the wrong type, is counted under
  `unreadable_sources` and left out. A row whose times run backward is counted under
  `negative_times` and left out.
- queue wait: `started_at - created_at` of a delegation that started. A delegation that never
  started (cancelled while queued) has no queue wait.
- run: `completed_at - started_at` of a delegation that started and finished.
- long wait: a queue wait of at least `LONG_WAIT_S` seconds.
- turn span: for one target Keeper and one `keeper_turn_id`, from the earliest start (`ts` minus
  `duration_ms`) of its tool calls to the latest `ts`. The ledger holds only tool calls, so a span
  starts when a turn's first call began and ends when its last call returned. The model time
  before the first call and after the last one is outside it, and the spans are a lower bound of
  the time the target spent in turns.
  A tool-call row of a target Keeper without a usable `ts` or `keeper_turn_id` is counted under
  `unusable_rows`. A day of the window without any ledger file is listed under `missing_days`.
- target in a turn: the instant `created_at` lies inside a span of the target Keeper. This
  replays a flag that says "the target is inside a turn" at submit time, using the ledger and not
  the registry the runtime reads.
- flag replay: for each threshold of `FLAG_THRESHOLDS_S`, the delegations with a queue wait at
  or above it count as positive. True positive: flagged and positive. False positive: flagged and
  not positive. False negative: not flagged and positive.
- clock check: two consecutive calls of one turn that ran alone and in order (`execution_mode`
  `serial`, `batch_size` 1) cannot overlap. The pairs that overlap when `ts` is read as the end
  of a call and when it is read as the start are counted, with a tolerance of `CLOCK_TOLERANCE_S`.
- return: the `ts` of a tool-call row, the instant a tool result came back to the turn.
- boundary replay: for the delegations that started and whose target was in a turn at
  `created_at`, the pickup is the time from `created_at` to the first return of the target at or
  after it. The replayed wait is the smaller of the real wait and the pickup. The saved time is
  an upper bound for a pickup at a tool-result boundary: it assumes the target starts the
  operation at that instant and that the run takes as long as it did. No built change does that.
  `pickup_also_long` counts the long waits whose pickup is itself at least `LONG_WAIT_S`: the
  target's next return was that far away, so one long call kept it from a boundary.
- submit count: the `queued_count` in the result of the `masc_keeper_delegate` call that created
  the operation, read from the `output` of that tool call and joined by `operation_id`. It counts
  the operations that are queued, so the turn the target is running is not in it. A call whose
  `output` carries no `operation_id` and integer `queued_count` is counted under
  `unusable_submits`. When one operation has several submit rows, the earliest `ts` counts.

What the numbers do not show: whether a submitter that sees the flag acts on it. The replayed
flag is on for a subset of the instants the runtime flag is on, so the runtime recall is at least
the replayed one. The runtime precision can be higher or lower.

Usage:
    python3 docs/evidence/delegation-queue-wait-2026-11/measure_delegation_queue_wait.py \\
        --base-path ~/me --from-date 2026-11-01 --to-date 2026-11-05 --json-out result.json
    python3 -m unittest discover -s docs/evidence/delegation-queue-wait-2026-11
"""

from __future__ import annotations

import argparse
import bisect
import dataclasses
import datetime
import json
import math
import pathlib
import re
import sqlite3
import sys
from collections import defaultdict
from collections.abc import Iterator, Sequence
from typing import cast

LONG_WAIT_S = 600.0
FLAG_THRESHOLDS_S = (60.0, LONG_WAIT_S)
DEFAULT_TOP = 8
DELEGATE_TOOL = "masc_keeper_delegate"
QUEUED_COUNT_CAP = 3
CLOCK_TOLERANCE_S = 0.05
SECONDS_PER_HOUR = 3600.0
SECONDS_PER_DAY = 86400.0
OPERATIONS_QUERY = (
    "SELECT operation_id, source_json, state, created_at, started_at, completed_at "
    "FROM operations WHERE created_at >= ? AND created_at < ?"
)


@dataclasses.dataclass(frozen=True, slots=True)
class Delegation:
    operation_id: str
    target: str
    sender: str
    state: str
    created_at: float
    started_at: float | None
    completed_at: float | None

    @property
    def queue_wait(self) -> float | None:
        return None if self.started_at is None else self.started_at - self.created_at

    @property
    def run(self) -> float | None:
        if self.started_at is None or self.completed_at is None:
            return None
        return self.completed_at - self.started_at


@dataclasses.dataclass(slots=True)
class Skipped:
    unreadable_stores: list[str] = dataclasses.field(default_factory=lambda: cast(list[str], []))
    unreadable_sources: int = 0
    bad_lines: int = 0
    unusable_rows: int = 0
    unusable_submits: int = 0
    negative_times: int = 0
    missing_days: list[str] = dataclasses.field(default_factory=lambda: cast(list[str], []))


def utc_day_start(day: datetime.date) -> float:
    return datetime.datetime(day.year, day.month, day.day, tzinfo=datetime.timezone.utc).timestamp()


def as_float(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    return float(value) if isinstance(value, (int, float)) else None


def as_str(value: object) -> str | None:
    return value if isinstance(value, str) and value != "" else None


def as_turn_id(value: object) -> int | str | None:
    if isinstance(value, bool):
        return None
    return value if isinstance(value, (int, str)) else None


def parse_source(source_json: object) -> dict[str, object] | None:
    """The `source_json` object, or None when the column does not hold a JSON object."""
    if not isinstance(source_json, str):
        return None
    try:
        source: object = json.loads(source_json)
    except json.JSONDecodeError:
        return None
    return cast(dict[str, object], source) if isinstance(source, dict) else None


def read_delegations(
    base_path: pathlib.Path, low: float, high: float, skipped: Skipped
) -> list[Delegation]:
    found: list[Delegation] = []
    keepers = base_path / ".masc" / "keepers"
    if not keepers.is_dir():
        return found
    for store in sorted(keepers.glob("*/chat-operations.sqlite3")):
        target = store.parent.name
        try:
            connection = sqlite3.connect(f"{store.resolve().as_uri()}?mode=ro", uri=True)
            try:
                rows = connection.execute(OPERATIONS_QUERY, (low, high)).fetchall()
            finally:
                connection.close()
        except sqlite3.Error:
            skipped.unreadable_stores.append(target)
            continue
        for operation_id, source_json, state, created_at, started_at, completed_at in rows:
            source = parse_source(source_json)
            created = as_float(created_at)
            if source is None or created is None or not isinstance(operation_id, str) or not isinstance(state, str):
                skipped.unreadable_sources += 1
                continue
            sender = as_str(source.get("sender_keeper"))
            if sender is None:
                continue
            found.append(
                Delegation(operation_id, target, sender, state, created, as_float(started_at), as_float(completed_at))
            )
    return found


def tool_call_files(base_path: pathlib.Path, day: datetime.date) -> list[pathlib.Path]:
    folder = base_path / ".masc" / "tool_calls" / f"{day:%Y-%m}"
    pattern = re.compile(rf"{day:%d}(\.\d{{3}})?\.jsonl")
    if not folder.is_dir():
        return []
    return sorted(path for path in folder.iterdir() if pattern.fullmatch(path.name))


def read_objects(path: pathlib.Path, skipped: Skipped) -> Iterator[dict[str, object]]:
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                value: object = json.loads(line)
            except json.JSONDecodeError:
                skipped.bad_lines += 1
                continue
            if isinstance(value, dict):
                yield cast(dict[str, object], value)
            else:
                skipped.bad_lines += 1


Spans = dict[str, list[tuple[float, float]]]
Returns = dict[str, list[float]]
TurnKey = tuple[str, int | str]


@dataclasses.dataclass(frozen=True, slots=True)
class Ledger:
    spans: Spans
    returns: Returns
    submit_counts: dict[str, int]
    clock_check: dict[str, object]


def parse_submit(row: dict[str, object]) -> tuple[str, int] | None:
    """The `(operation_id, queued_count)` a `masc_keeper_delegate` call returned, if it returned both."""
    output = row.get("output")
    if not isinstance(output, str):
        return None
    try:
        result: object = json.loads(output)
    except json.JSONDecodeError:
        return None
    if not isinstance(result, dict):
        return None
    fields = cast(dict[str, object], result)
    operation_id = as_str(fields.get("operation_id"))
    count = fields.get("queued_count")
    if operation_id is None or isinstance(count, bool) or not isinstance(count, int):
        return None
    return operation_id, count


def is_single_serial(row: dict[str, object]) -> bool:
    """A call that ran alone and in order, so the next call of its turn began after it returned."""
    size = row.get("batch_size")
    return row.get("execution_mode") == "serial" and not isinstance(size, bool) and size == 1


def clock_check(serial: dict[TurnKey, list[tuple[float, float]]]) -> dict[str, object]:
    """Count the consecutive single serial calls of one turn that overlap under each reading of `ts`.

    Each call is `(ts, seconds)`. Under "ts is the end" the next call began at `ts - seconds`,
    which must not be before the previous `ts`. Under "ts is the start" the next `ts` must not be
    before the previous `ts + seconds`.
    """
    pairs = overlap_if_end = overlap_if_start = 0
    for calls in serial.values():
        ordered = sorted(calls)
        for (first_ts, first_seconds), (second_ts, second_seconds) in zip(ordered, ordered[1:]):
            pairs += 1
            if second_ts - second_seconds < first_ts - CLOCK_TOLERANCE_S:
                overlap_if_end += 1
            if second_ts < first_ts + first_seconds - CLOCK_TOLERANCE_S:
                overlap_if_start += 1
    return {
        "tolerance_s": CLOCK_TOLERANCE_S,
        "serial_pairs": pairs,
        "overlap_if_ts_is_end": overlap_if_end,
        "overlap_if_ts_is_start": overlap_if_start,
    }


def read_ledger(
    base_path: pathlib.Path, days: Sequence[datetime.date], keepers: frozenset[str], skipped: Skipped
) -> Ledger:
    """Per target Keeper, the sorted spans of its turns and the sorted instants its tool calls
    returned, the submit count of each delegation, and the clock check of its serial calls."""
    bounds: dict[TurnKey, list[float]] = {}
    returns: dict[str, list[float]] = defaultdict(list)
    serial: dict[TurnKey, list[tuple[float, float]]] = defaultdict(list)
    submits: dict[str, tuple[float, int]] = {}
    for day in days:
        files = tool_call_files(base_path, day)
        if not files:
            skipped.missing_days.append(day.isoformat())
        for path in files:
            for row in read_objects(path, skipped):
                if row.get("record_kind") != "tool_call":
                    continue
                ts = as_float(row.get("ts"))
                if row.get("tool") == DELEGATE_TOOL:
                    submit = parse_submit(row)
                    if submit is None or ts is None:
                        skipped.unusable_submits += 1
                    elif submit[0] not in submits or ts < submits[submit[0]][0]:
                        submits[submit[0]] = (ts, submit[1])
                keeper = as_str(row.get("keeper"))
                if keeper is None or keeper not in keepers:
                    continue
                turn = as_turn_id(row.get("keeper_turn_id"))
                if ts is None or turn is None:
                    skipped.unusable_rows += 1
                    continue
                duration = as_float(row.get("duration_ms")) or 0.0
                seconds = max(0.0, duration) / 1000.0
                start = ts - seconds
                span = bounds.setdefault((keeper, turn), [start, ts])
                span[0] = min(span[0], start)
                span[1] = max(span[1], ts)
                returns[keeper].append(ts)
                if is_single_serial(row):
                    serial[(keeper, turn)].append((ts, seconds))
    spans: Spans = defaultdict(list)
    for (keeper, _), (start, end) in bounds.items():
        spans[keeper].append((start, end))
    return Ledger(
        spans={keeper: sorted(found) for keeper, found in spans.items()},
        returns={keeper: sorted(found) for keeper, found in returns.items()},
        submit_counts={operation_id: count for operation_id, (_, count) in submits.items()},
        clock_check=clock_check(serial),
    )


def in_turn(spans: Spans, keeper: str, instant: float) -> bool:
    found = spans.get(keeper, [])
    # Spans of one Keeper can overlap, so every span that starts at or before the instant can
    # still cover it; the spans after the instant cannot.
    started = bisect.bisect_right(found, (instant, math.inf))
    return any(end >= instant for _, end in found[:started])


def next_return(returns: Returns, keeper: str, instant: float) -> float:
    """The first instant at or after `instant` when a tool call of `keeper` returned.

    Call it for an instant that `in_turn` accepted. The end of the span that covers the instant
    is itself a return, so one exists; if the spans and the returns did not come from the same
    rows this raises instead of skipping the delegation.
    """
    found = returns[keeper]
    return found[bisect.bisect_left(found, instant)]


def rank_quantile(sorted_values: Sequence[float], q: float) -> float:
    """The sample at rank round((n - 1) * q), halves rounded up, as `Tool_metrics.percentile` picks it."""
    position = (len(sorted_values) - 1) * q
    whole = int(position)
    return sorted_values[whole + 1 if position - whole >= 0.5 else whole]


def spread(values: Sequence[float]) -> dict[str, object]:
    ordered = sorted(values)
    if not ordered:
        return {"n": 0, "p50": None, "p90": None, "p99": None, "max": None, "hours": 0.0}
    return {
        "n": len(ordered),
        "p50": rank_quantile(ordered, 0.5),
        "p90": rank_quantile(ordered, 0.9),
        "p99": rank_quantile(ordered, 0.99),
        "max": ordered[-1],
        "hours": sum(ordered) / SECONDS_PER_HOUR,
    }


def checked_times(delegations: Sequence[Delegation], skipped: Skipped) -> list[Delegation]:
    """Delegations whose recorded times run forward. A row that goes backward is counted and dropped."""
    kept: list[Delegation] = []
    for delegation in delegations:
        wait = delegation.queue_wait
        run = delegation.run
        if (wait is not None and wait < 0) or (run is not None and run < 0):
            skipped.negative_times += 1
            continue
        kept.append(delegation)
    return kept


def wait_block(delegations: Sequence[Delegation]) -> dict[str, object]:
    waits = [wait for delegation in delegations if (wait := delegation.queue_wait) is not None]
    runs = [run for delegation in delegations if (run := delegation.run) is not None]
    totals = [
        delegation.completed_at - delegation.created_at
        for delegation in delegations
        if delegation.completed_at is not None and delegation.started_at is not None
    ]
    both = [
        (wait, run)
        for delegation in delegations
        if (wait := delegation.queue_wait) is not None and (run := delegation.run) is not None
    ]
    wait_sum = sum(wait for wait, _ in both)
    wall = wait_sum + sum(run for _, run in both)
    long_waits = [wait for wait in waits if wait >= LONG_WAIT_S]
    states: dict[str, int] = defaultdict(int)
    for delegation in delegations:
        states[delegation.state] += 1
    return {
        "delegations": len(delegations),
        "never_started": len(delegations) - len(waits),
        "states": dict(sorted(states.items())),
        "queue_wait_s": spread(waits),
        "run_s": spread(runs),
        "total_s": spread(totals),
        "queue_share_of_wall": wait_sum / wall if wall > 0 else None,
        "long_waits": {
            "threshold_s": LONG_WAIT_S,
            "n": len(long_waits),
            "hours": sum(long_waits) / SECONDS_PER_HOUR,
            "share_of_wait_hours": sum(long_waits) / sum(waits) if sum(waits) > 0 else None,
        },
    }


def by_target(delegations: Sequence[Delegation], top: int) -> list[dict[str, object]]:
    grouped: dict[str, list[float]] = defaultdict(list)
    for delegation in delegations:
        wait = delegation.queue_wait
        if wait is not None:
            grouped[delegation.target].append(wait)
    rows = [{"target": target, **spread(waits)} for target, waits in grouped.items()]
    rows.sort(key=lambda row: (-cast(float, row["hours"]), cast(str, row["target"])))
    return rows[:top]


def flag_replay(delegations: Sequence[Delegation], spans: Spans, thresholds: Sequence[float]) -> dict[str, object]:
    started = [delegation for delegation in delegations if delegation.queue_wait is not None]
    flags = [in_turn(spans, delegation.target, delegation.created_at) for delegation in started]
    waits = [cast(float, delegation.queue_wait) for delegation in started]
    rows: list[dict[str, object]] = []
    for threshold in thresholds:
        true_positive = sum(1 for flag, wait in zip(flags, waits, strict=True) if flag and wait >= threshold)
        false_positive = sum(1 for flag, wait in zip(flags, waits, strict=True) if flag and wait < threshold)
        false_negative = sum(1 for flag, wait in zip(flags, waits, strict=True) if not flag and wait >= threshold)
        true_negative = len(waits) - true_positive - false_positive - false_negative
        rows.append(
            {
                "threshold_s": threshold,
                "true_positive": true_positive,
                "false_positive": false_positive,
                "false_negative": false_negative,
                "true_negative": true_negative,
                "precision": true_positive / (true_positive + false_positive) if true_positive + false_positive else None,
                "recall": true_positive / (true_positive + false_negative) if true_positive + false_negative else None,
            }
        )
    flagged = [wait for flag, wait in zip(flags, waits, strict=True) if flag]
    unflagged = [wait for flag, wait in zip(flags, waits, strict=True) if not flag]
    total_hours = sum(waits) / SECONDS_PER_HOUR
    return {
        "started": len(waits),
        "flagged": len(flagged),
        "flagged_wait_hours": sum(flagged) / SECONDS_PER_HOUR,
        "flagged_share_of_wait_hours": sum(flagged) / SECONDS_PER_HOUR / total_hours if total_hours > 0 else None,
        "flagged_wait_s": spread(flagged),
        "unflagged_wait_s": spread(unflagged),
        "thresholds": rows,
    }


def boundary_replay(delegations: Sequence[Delegation], spans: Spans, returns: Returns) -> dict[str, object]:
    """What a pickup at the target's next tool return would have saved, as an upper bound.

    Only the delegations that started and whose target was in a turn at `created_at` have a
    pickup. Its replayed wait is the smaller of the real wait and the pickup.
    """
    started = [delegation for delegation in delegations if delegation.queue_wait is not None]
    all_wait_hours = sum(cast(float, delegation.queue_wait) for delegation in started) / SECONDS_PER_HOUR
    cases = [
        (cast(float, delegation.queue_wait), next_return(returns, delegation.target, delegation.created_at) - delegation.created_at)
        for delegation in started
        if in_turn(spans, delegation.target, delegation.created_at)
    ]
    long_cases = [(wait, pickup) for wait, pickup in cases if wait >= LONG_WAIT_S]
    saved_hours = sum(wait - min(wait, pickup) for wait, pickup in cases) / SECONDS_PER_HOUR
    return {
        "flagged": len(cases),
        "pickup_s": spread([pickup for _, pickup in cases]),
        "wait_hours": sum(wait for wait, _ in cases) / SECONDS_PER_HOUR,
        "replayed_wait_hours": sum(min(wait, pickup) for wait, pickup in cases) / SECONDS_PER_HOUR,
        "saved_hours": saved_hours,
        "saved_share_of_wait_hours": saved_hours / all_wait_hours if all_wait_hours > 0 else None,
        "pickup_not_before_start": sum(1 for wait, pickup in cases if pickup >= wait),
        "long_waits": {
            "n": len(long_cases),
            "wait_hours": sum(wait for wait, _ in long_cases) / SECONDS_PER_HOUR,
            "replayed_wait_hours": sum(min(wait, pickup) for wait, pickup in long_cases) / SECONDS_PER_HOUR,
            "pickup_s": spread([pickup for _, pickup in long_cases]),
            "pickup_also_long": sum(1 for _, pickup in long_cases if pickup >= LONG_WAIT_S),
        },
    }


def queued_count_label(count: int) -> str:
    return f"{QUEUED_COUNT_CAP}+" if count >= QUEUED_COUNT_CAP else str(count)


def submit_block(delegations: Sequence[Delegation], submit_counts: dict[str, int]) -> dict[str, object]:
    """Queue wait by the `queued_count` the submit result showed, for the delegations that started."""
    started = [delegation for delegation in delegations if delegation.queue_wait is not None]
    joined = [(delegation, submit_counts[delegation.operation_id]) for delegation in started if delegation.operation_id in submit_counts]
    by_label: dict[str, list[float]] = defaultdict(list)
    for delegation, count in joined:
        by_label[queued_count_label(count)].append(cast(float, delegation.queue_wait))
    long_joined = [(cast(float, delegation.queue_wait), count) for delegation, count in joined if cast(float, delegation.queue_wait) >= LONG_WAIT_S]
    long_count_one = [wait for wait, count in long_joined if count == 1]
    return {
        "started": len(started),
        "joined": len(joined),
        "by_queued_count": {
            label: {**spread(waits), "long_waits": sum(1 for wait in waits if wait >= LONG_WAIT_S)}
            for label, waits in sorted(by_label.items())
        },
        "long_waits": {
            "n": len(long_joined),
            "queued_count_one": len(long_count_one),
            "hours": sum(wait for wait, _ in long_joined) / SECONDS_PER_HOUR,
            "hours_queued_count_one": sum(long_count_one) / SECONDS_PER_HOUR,
        },
    }


def days_between(first: datetime.date, last: datetime.date) -> list[datetime.date]:
    return [first + datetime.timedelta(days=offset) for offset in range((last - first).days + 1)]


def measure(base_path: pathlib.Path, first: datetime.date, last: datetime.date, top: int) -> dict[str, object]:
    skipped = Skipped()
    low = utc_day_start(first)
    high = utc_day_start(last) + SECONDS_PER_DAY
    delegations = checked_times(read_delegations(base_path, low, high, skipped), skipped)
    ledger = read_ledger(
        base_path, days_between(first, last), frozenset(delegation.target for delegation in delegations), skipped
    )
    per_day: dict[str, list[Delegation]] = defaultdict(list)
    for delegation in delegations:
        day = datetime.datetime.fromtimestamp(delegation.created_at, datetime.timezone.utc).date()
        per_day[day.isoformat()].append(delegation)
    return {
        "params": {
            "from_date": first.isoformat(),
            "to_date": last.isoformat(),
            "long_wait_s": LONG_WAIT_S,
            "flag_thresholds_s": list(FLAG_THRESHOLDS_S),
        },
        "all": wait_block(delegations),
        "by_day": {day: wait_block(found) for day, found in sorted(per_day.items())},
        "by_target": by_target(delegations, top),
        "clock_check": ledger.clock_check,
        "flag_replay": flag_replay(delegations, ledger.spans, FLAG_THRESHOLDS_S),
        "boundary_replay": boundary_replay(delegations, ledger.spans, ledger.returns),
        "submit_queued_count": submit_block(delegations, ledger.submit_counts),
        "skipped": dataclasses.asdict(skipped),
    }


def parse_day(value: str) -> datetime.date:
    return datetime.date.fromisoformat(value)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    if args.from_date > args.to_date:
        parser.error("--from-date is after --to-date")
    if args.top < 1:
        parser.error("--top must be at least 1")
    result = measure(args.base_path.expanduser(), args.from_date, args.to_date, args.top)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out is not None:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
