#!/usr/bin/env python3
"""Count the Keeper turns a server shutdown cut short, whether they went on, and what they cost.

Reads three things under `<base-path>/.masc` and never writes to them:

- `logs/system_log_YYYY-MM-DD.jsonl`: the `Received SIGTERM` line that starts a
  shutdown, and the `keeper_chat_error ... Keeper owner stopped the active turn` lines
  the Keeper owners write while it runs. A stop line belongs to the latest shutdown that
  began at most 60 seconds before it. Stop lines that belong to no shutdown are counted
  and left out.
- `costs/YYYY-MM/DD.jsonl`: rows with `usage_scope == "per_request"`. The fields used are
  `agent`, `keeper_turn_id`, `timestamp` (when the request finished),
  `request_latency_ms`, `input_tokens`, `non_cached_input_tokens`, `output_tokens` and
  `runtime_id`.
- `tool_calls/YYYY-MM/DD.jsonl` and its `DD.NNN.jsonl` segments: `keeper`,
  `keeper_turn_id`, `ts` (when the row was written, after the call returned), `tool` and
  `input_fingerprint`.

Definitions:

- turn: the requests of one `agent` with the same `keeper_turn_id`.
- cut turn: the turn of the stopped Keeper's last model request that finished at most
  `recent` seconds before the stop line (a request that finished up to 5 seconds after
  it counts, for clock slack). `recent` is a parameter and the report has one block per
  value, because the logs do not name the turn that was running.
- duplicate stop lines: several stop lines of one shutdown can name the same turn, and a
  later shutdown can name a turn that has no request since its last cut. Neither is a new
  cut, and each counts once as a duplicate.
- repeat cut: a later shutdown cuts a turn again after it went on, meaning the turn has a
  request that starts more than 5 seconds after its last cut. The turns of the first cuts
  are the "cut turns" of the report, and every cut including the repeat ones is `all_cuts`.
- no recent request: the stopped Keeper had no model request in the `recent` seconds
  before the stop line, so no turn is named.
- elapsed: the stop time minus the start of the first request of the cut (the request
  finish time minus `request_latency_ms`). A repeat cut starts counting at the first request
  after the previous cut. A turn that began before the first day of the window is cut short
  on the left.
- resumed: a request of the same turn starts more than 5 seconds after the stop. The gap
  is the time from the stop to the start of that request. A turn can also show tool calls
  after the stop without a cost row, so `not_resumed_with_calls_after_stop` counts the
  not resumed turns that have such a call.
- loss bounds: the lower bound counts a resumed cut as its gap and a cut that was not
  resumed as its elapsed time, which assumes the work done before a stop is used again. The
  upper bound counts the elapsed time of every cut plus the gap of the resumed ones, which
  assumes that work is done again. Neither counts the model request that was running at the
  stop, because it has no cost row.
- carried context: for a resumed cut turn with at least two requests before the stop whose
  input grew by `CONTEXT_GROWTH_MIN_TOKENS` or more from its first request to its last one
  before the stop, the share (first request after the stop - first request of the turn) /
  (last request before the stop - first request of the turn) of input tokens. A share near 1
  or above means the request after the restart carries what the turn had built up. A share
  near 0 means it starts from the context the turn began with.
- turn number: the runtime takes `total_turns + 1` at the start of a turn
  (`lib/keeper/keeper_unified_turn.ml`) and raises `total_turns` when a turn ends in success
  or failure and records its result (`keeper_unified_metrics_result.ml`,
  `keeper_unified_metrics_failure.ml`, `keeper_turn_spend_commit.ml` under `lib/keeper/`). A
  turn that a shutdown stops records nothing, so the next turn of that Keeper takes the same
  number. "Resumed" therefore means the Keeper ran another turn after the restart. It does not
  show that the stopped work went on.
- repeated call: a tool call whose `ts` is more than `CLOCK_SLACK_S` after the stop and that has
  the same tool and `input_fingerprint` as a call of the same turn whose `ts` is at or before the
  stop. Reading each call at `ts - duration_ms`, its start, instead gives the same counts in the
  three windows of 2026-11-01 to 2026-11-05 (counted outside the script).
- turn span: the first request start to the last request end of a turn. It leaves out
  the time before the first and after the last model request.
- finish share for a wait of D seconds: for a cut turn that had run e seconds, take the
  other turns whose span is longer than e. The share of them whose span is at most
  e + D is how likely the cut turn would have finished if the shutdown had waited D
  seconds. The mean over the cut turns is reported. A span ends at the last model
  request, so a real turn ends later and the share is an upper bound.

A row that is not a JSON object is counted in `bad_lines`. A per-request cost row without
an agent, a turn id or a finish time is counted in `cost_rows_without_turn`.

This reads log sentences, and the sentences are not a schema. If `shutdowns` is 0 for a
window that had restarts, check `SHUTDOWN_MARKER` and `STOP_MARKER` against the log.
A turn that was not resumed under the same turn id may have been taken up again under a
new one, and this does not follow that.

Usage:
    python3 docs/evidence/restart-cancelled-turns-2026-11/measure_restart_cancelled_turns.py \
        --base-path ~/me --from-date 2026-11-01 --to-date 2026-11-05 \
        --json-out result.json
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
import sys
from collections import Counter, defaultdict
from collections.abc import Iterator, Mapping, Sequence
from typing import cast

SHUTDOWN_MARKER = "Received SIGTERM"
STOP_MARKER = "Keeper owner stopped the active turn"
STOP_TAG = "keeper_chat_error"
COST_MARKER = "per_request"
FINGERPRINT_FIELD = "input_fingerprint"
ATTRIBUTION_WINDOW_S = 60.0
CLOCK_SLACK_S = 5.0
DEFAULT_RECENT_S = (120.0, 600.0, 1800.0)
DEFAULT_DRAIN_S = (60.0, 300.0, 900.0)
DEFAULT_TOP = 8
REPEATED_TOOLS_SHOWN = 5
CONTEXT_GROWTH_MIN_TOKENS = 5000
CARRIED_SHARE_HIGH = 0.8
CARRIED_SHARE_LOW = 0.2
SECONDS_PER_HOUR = 3600.0

TurnKey = tuple[str, int]


@dataclasses.dataclass(frozen=True, slots=True)
class Stop:
    at: float
    keeper: str


@dataclasses.dataclass(frozen=True, slots=True)
class Request:
    start: float
    end: float
    turn: int
    input_tokens: int
    uncached_tokens: int
    output_tokens: int
    runtime_id: str


@dataclasses.dataclass(frozen=True, slots=True)
class ToolCall:
    at: float
    tool: str
    fingerprint: str


@dataclasses.dataclass(frozen=True, slots=True)
class CutTurn:
    keeper: str
    turn: int
    shutdown: int
    stopped_at: float
    elapsed_s: float
    resume_gap_s: float | None
    requests: int
    input_tokens: int
    uncached_tokens: int
    output_tokens: int
    runtime_id: str


@dataclasses.dataclass(frozen=True, slots=True)
class Cuts:
    first: list[CutTurn]
    repeats: list[CutTurn]
    no_recent: int
    duplicates: int


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0
    cost_rows_without_turn: int = 0
    missing_days: list[str] = dataclasses.field(default_factory=list[str])


@dataclasses.dataclass(frozen=True, slots=True)
class Turns:
    by_agent: dict[str, list[Request]]
    ends: dict[str, list[float]]
    spans: dict[TurnKey, tuple[float, float]]


@dataclasses.dataclass(frozen=True, slots=True)
class Inputs:
    logs: list[pathlib.Path]
    costs: list[pathlib.Path]
    tool_calls: list[pathlib.Path]


def as_str(value: object) -> str | None:
    return value if isinstance(value, str) and value != "" else None


def as_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_float(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    return float(value) if isinstance(value, (int, float)) else None


def parse_utc(value: object) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.timestamp()


def read_objects(
    path: pathlib.Path, needles: Sequence[str], skipped: Skipped
) -> Iterator[dict[str, object]]:
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not any(needle in line for needle in needles):
                continue
            try:
                value: object = json.loads(line)
            except json.JSONDecodeError:
                skipped.bad_lines += 1
                continue
            if isinstance(value, dict):
                yield cast(dict[str, object], value)
            else:
                skipped.bad_lines += 1


def read_logs(paths: Sequence[pathlib.Path], skipped: Skipped) -> tuple[list[float], list[Stop]]:
    shutdowns: list[float] = []
    stops: list[Stop] = []
    for path in paths:
        for row in read_objects(path, (SHUTDOWN_MARKER, STOP_MARKER), skipped):
            message = as_str(row.get("message"))
            at = parse_utc(row.get("ts"))
            if message is None or at is None:
                continue
            if SHUTDOWN_MARKER in message:
                shutdowns.append(at)
            elif STOP_TAG in message and STOP_MARKER in message:
                keeper = as_str(row.get("keeper_name"))
                if keeper is not None:
                    stops.append(Stop(at, keeper))
    return sorted(shutdowns), sorted(stops, key=lambda stop: stop.at)


def parse_request(row: Mapping[str, object], skipped: Skipped) -> tuple[str, Request] | None:
    if row.get("usage_scope") != COST_MARKER:
        return None
    agent = as_str(row.get("agent"))
    turn = as_int(row.get("keeper_turn_id"))
    end = parse_utc(row.get("timestamp"))
    if agent is None or turn is None or end is None:
        skipped.cost_rows_without_turn += 1
        return None
    latency_s = max(0.0, as_float(row.get("request_latency_ms")) or 0.0) / 1000.0
    return agent, Request(
        start=end - latency_s,
        end=end,
        turn=turn,
        input_tokens=as_int(row.get("input_tokens")) or 0,
        uncached_tokens=as_int(row.get("non_cached_input_tokens")) or 0,
        output_tokens=as_int(row.get("output_tokens")) or 0,
        runtime_id=as_str(row.get("runtime_id")) or "unknown",
    )


def read_costs(paths: Sequence[pathlib.Path], skipped: Skipped) -> list[tuple[str, Request]]:
    parsed: list[tuple[str, Request]] = []
    for path in paths:
        for row in read_objects(path, (COST_MARKER,), skipped):
            item = parse_request(row, skipped)
            if item is not None:
                parsed.append(item)
    return parsed


def read_tool_calls(
    paths: Sequence[pathlib.Path], wanted: set[TurnKey], skipped: Skipped
) -> dict[TurnKey, list[ToolCall]]:
    calls: dict[TurnKey, list[ToolCall]] = defaultdict(list)
    for path in paths:
        for row in read_objects(path, (FINGERPRINT_FIELD,), skipped):
            keeper = as_str(row.get("keeper"))
            turn = as_int(row.get("keeper_turn_id"))
            at = as_float(row.get("ts"))
            tool = as_str(row.get("tool"))
            fingerprint = as_str(row.get(FINGERPRINT_FIELD))
            if keeper is None or turn is None or at is None or tool is None or fingerprint is None:
                continue
            if (keeper, turn) in wanted:
                calls[(keeper, turn)].append(ToolCall(at, tool, fingerprint))
    return calls


def index_requests(parsed: Sequence[tuple[str, Request]]) -> Turns:
    by_agent: dict[str, list[Request]] = defaultdict(list)
    for agent, request in parsed:
        by_agent[agent].append(request)
    ends: dict[str, list[float]] = {}
    spans: dict[TurnKey, tuple[float, float]] = {}
    for agent, requests in by_agent.items():
        requests.sort(key=lambda request: request.end)
        ends[agent] = [request.end for request in requests]
        for request in requests:
            first, last = spans.get((agent, request.turn), (request.start, request.end))
            spans[(agent, request.turn)] = (min(first, request.start), max(last, request.end))
    return Turns(dict(by_agent), ends, spans)


def attribute(stops: Sequence[Stop], shutdowns: Sequence[float]) -> tuple[list[tuple[Stop, int]], int]:
    attributed: list[tuple[Stop, int]] = []
    unattributed = 0
    for stop in stops:
        index = bisect.bisect_right(shutdowns, stop.at) - 1
        if index >= 0 and stop.at - shutdowns[index] <= ATTRIBUTION_WINDOW_S:
            attributed.append((stop, index))
        else:
            unattributed += 1
    return attributed, unattributed


def find_cut_turns(attributed: Sequence[tuple[Stop, int]], turns: Turns, recent_s: float) -> Cuts:
    first: dict[TurnKey, CutTurn] = {}
    repeats: list[CutTurn] = []
    latest: dict[TurnKey, CutTurn] = {}
    no_recent = 0
    duplicates = 0
    for stop, shutdown in attributed:
        requests = turns.by_agent.get(stop.keeper, [])
        last = bisect.bisect_right(turns.ends.get(stop.keeper, []), stop.at + CLOCK_SLACK_S) - 1
        if last < 0 or stop.at - requests[last].end > recent_s:
            no_recent += 1
            continue
        turn = requests[last].turn
        key = (stop.keeper, turn)
        previous = latest.get(key)
        if previous is not None and previous.shutdown == shutdown:
            duplicates += 1
            continue
        same_turn = [request for request in requests if request.turn == turn]
        members = [
            request
            for request in same_turn
            if request.start <= stop.at + CLOCK_SLACK_S
            and (previous is None or request.start > previous.stopped_at + CLOCK_SLACK_S)
        ]
        if not members:
            duplicates += 1
            continue
        later = [request.start for request in same_turn if request.start > stop.at + CLOCK_SLACK_S]
        cut = CutTurn(
            keeper=stop.keeper,
            turn=turn,
            shutdown=shutdown,
            stopped_at=stop.at,
            elapsed_s=max(0.0, stop.at - min(request.start for request in members)),
            resume_gap_s=min(later) - stop.at if later else None,
            requests=len(members),
            input_tokens=sum(request.input_tokens for request in members),
            uncached_tokens=sum(request.uncached_tokens for request in members),
            output_tokens=sum(request.output_tokens for request in members),
            runtime_id=requests[last].runtime_id,
        )
        latest[key] = cut
        if previous is None:
            first[key] = cut
        else:
            repeats.append(cut)
    return Cuts(list(first.values()), repeats, no_recent, duplicates)


def quantile(sorted_values: Sequence[float], q: float) -> float:
    """Nearest rank: the smallest value with at least a share q of the values at or below it."""
    return sorted_values[max(0, math.ceil(q * len(sorted_values)) - 1)]


def finish_shares(
    cut: Sequence[CutTurn],
    spans: Mapping[TurnKey, tuple[float, float]],
    waits_s: Sequence[float],
) -> list[dict[str, object]]:
    cut_keys = {(turn.keeper, turn.turn) for turn in cut}
    durations = sorted(end - start for key, (start, end) in spans.items() if key not in cut_keys)
    rows: list[dict[str, object]] = []
    for wait in waits_s:
        shares: list[float] = []
        without_reference = 0
        for turn in cut:
            first_longer = bisect.bisect_right(durations, turn.elapsed_s)
            longer = len(durations) - first_longer
            if longer == 0:
                without_reference += 1
                continue
            finishing = bisect.bisect_right(durations, turn.elapsed_s + wait) - first_longer
            shares.append(finishing / longer)
        rows.append(
            {
                "wait_s": wait,
                "mean_finish_share": round(sum(shares) / len(shares), 4) if shares else None,
                "cut_turns_without_reference": without_reference,
            }
        )
    return rows


def repeated_calls(
    cut: Sequence[CutTurn], calls: Mapping[TurnKey, Sequence[ToolCall]]
) -> dict[str, object]:
    before = after = repeated = 0
    by_tool: Counter[str] = Counter()
    for turn in cut:
        if turn.resume_gap_s is None:
            continue
        own = calls.get((turn.keeper, turn.turn), [])
        seen = {(call.tool, call.fingerprint) for call in own if call.at <= turn.stopped_at}
        before += sum(1 for call in own if call.at <= turn.stopped_at)
        for call in own:
            if call.at > turn.stopped_at + CLOCK_SLACK_S:
                after += 1
                if (call.tool, call.fingerprint) in seen:
                    repeated += 1
                    by_tool[call.tool] += 1
    return {
        "calls_before_stop": before,
        "calls_after_stop": after,
        "calls_after_stop_repeating_before_stop": repeated,
        "repeated_share": round(repeated / after, 4) if after else None,
        "repeated_by_tool": [
            {"tool": tool, "calls": count}
            for tool, count in sorted(by_tool.items(), key=lambda item: (-item[1], item[0]))[:REPEATED_TOOLS_SHOWN]
        ],
    }


def unresumed_with_calls(cut: Sequence[CutTurn], calls: Mapping[TurnKey, Sequence[ToolCall]]) -> int:
    return sum(
        1
        for turn in cut
        if turn.resume_gap_s is None
        and any(call.at > turn.stopped_at + CLOCK_SLACK_S for call in calls.get((turn.keeper, turn.turn), []))
    )


def carried_context(cut: Sequence[CutTurn], turns: Turns) -> dict[str, object]:
    shares: list[float] = []
    for turn in cut:
        if turn.resume_gap_s is None:
            continue
        own = sorted(
            (request for request in turns.by_agent.get(turn.keeper, []) if request.turn == turn.turn),
            key=lambda request: request.start,
        )
        before = [request for request in own if request.start <= turn.stopped_at + CLOCK_SLACK_S]
        after = [request for request in own if request.start > turn.stopped_at + CLOCK_SLACK_S]
        if not before or not after:
            continue
        growth = before[-1].input_tokens - before[0].input_tokens
        if growth < CONTEXT_GROWTH_MIN_TOKENS:
            continue
        shares.append((after[0].input_tokens - before[0].input_tokens) / growth)
    ordered = sorted(shares)
    return {
        "min_growth_tokens": CONTEXT_GROWTH_MIN_TOKENS,
        "turns": len(ordered),
        "retained_share": {
            "p10": round(quantile(ordered, 0.1), 3),
            "p50": round(quantile(ordered, 0.5), 3),
            "p90": round(quantile(ordered, 0.9), 3),
        }
        if ordered
        else None,
        "at_least_80_percent": sum(1 for share in ordered if share >= CARRIED_SHARE_HIGH),
        "below_20_percent": sum(1 for share in ordered if share < CARRIED_SHARE_LOW),
    }


def hours(seconds: float) -> float:
    return round(seconds / SECONDS_PER_HOUR, 3)


def spread(values: Sequence[float], scale: float) -> dict[str, float]:
    if not values:
        return {"p50": 0.0, "p90": 0.0, "max": 0.0}
    ordered = sorted(values)
    return {
        "p50": round(quantile(ordered, 0.5) / scale, 3),
        "p90": round(quantile(ordered, 0.9) / scale, 3),
        "max": round(ordered[-1] / scale, 3),
    }


def breakdown(cut: Sequence[CutTurn], key: str, top: int | None) -> list[dict[str, object]]:
    totals: dict[str, list[float]] = defaultdict(lambda: [0.0, 0.0])
    for turn in cut:
        name = turn.keeper if key == "keeper" else turn.runtime_id
        totals[name][0] += 1
        totals[name][1] += turn.elapsed_s
    ranked = sorted(totals.items(), key=lambda item: (-item[1][1], item[0]))
    return [
        {key: name, "cut_turns": int(count), "elapsed_hours": hours(seconds)}
        for name, (count, seconds) in ranked[:top]
    ]


def share(seconds: float, span_s: float) -> float | None:
    return round(seconds / span_s, 4) if span_s > 0 else None


def cut_totals(cuts: Sequence[CutTurn]) -> dict[str, object]:
    return {
        "cuts": len(cuts),
        "turns": len({(cut.keeper, cut.turn) for cut in cuts}),
        "elapsed_hours": hours(sum(cut.elapsed_s for cut in cuts)),
        "requests": sum(cut.requests for cut in cuts),
        "input_tokens": sum(cut.input_tokens for cut in cuts),
        "uncached_input_tokens": sum(cut.uncached_tokens for cut in cuts),
        "output_tokens": sum(cut.output_tokens for cut in cuts),
    }


def cuts_per_turn(cuts: Sequence[CutTurn]) -> dict[str, int]:
    per_turn = Counter((cut.keeper, cut.turn) for cut in cuts)
    return {str(times): count for times, count in sorted(Counter(per_turn.values()).items())}


def loss_bounds(cuts: Sequence[CutTurn], span_s: float) -> dict[str, object]:
    lower = upper = 0.0
    for cut in cuts:
        if cut.resume_gap_s is None:
            lower += cut.elapsed_s
            upper += cut.elapsed_s
        else:
            lower += cut.resume_gap_s
            upper += cut.elapsed_s + cut.resume_gap_s
    return {
        "lower_hours": hours(lower),
        "lower_share": share(lower, span_s),
        "upper_hours": hours(upper),
        "upper_share": share(upper, span_s),
    }


def window_block(
    recent_s: float,
    cuts: Cuts,
    shutdown_count: int,
    turns: Turns,
    calls: Mapping[TurnKey, Sequence[ToolCall]],
    waits_s: Sequence[float],
    top: int,
) -> dict[str, object]:
    cut = cuts.first
    all_cuts = [*cuts.first, *cuts.repeats]
    turn_span_s = sum(end - start for start, end in turns.spans.values())
    elapsed = sum(turn.elapsed_s for turn in cut)
    per_shutdown_count = [0.0] * shutdown_count
    per_shutdown_elapsed = [0.0] * shutdown_count
    for turn in cut:
        per_shutdown_count[turn.shutdown] += 1
        per_shutdown_elapsed[turn.shutdown] += turn.elapsed_s
    resumed = [turn for turn in cut if turn.resume_gap_s is not None]
    not_resumed = [turn for turn in cut if turn.resume_gap_s is None]
    gaps = [turn.resume_gap_s for turn in resumed if turn.resume_gap_s is not None]
    return {
        "recent_request_s": recent_s,
        "cut_turns": len(cut),
        "duplicate_stop_lines": cuts.duplicates,
        "no_recent_request": cuts.no_recent,
        "shutdowns_with_cut_turn": len({turn.shutdown for turn in cut}),
        "elapsed_hours": hours(elapsed),
        "share_of_turn_span": share(elapsed, turn_span_s),
        "elapsed_minutes": spread([turn.elapsed_s for turn in cut], 60.0),
        "cut_turns_per_shutdown": spread(per_shutdown_count, 1.0),
        "elapsed_hours_per_shutdown": spread(per_shutdown_elapsed, SECONDS_PER_HOUR),
        "requests": sum(turn.requests for turn in cut),
        "input_tokens": sum(turn.input_tokens for turn in cut),
        "uncached_input_tokens": sum(turn.uncached_tokens for turn in cut),
        "output_tokens": sum(turn.output_tokens for turn in cut),
        "resumed_cut_turns": len(resumed),
        "resumed_elapsed_hours": hours(sum(turn.elapsed_s for turn in resumed)),
        "resume_gap_minutes": spread(gaps, 60.0),
        "resume_gap_hours_total": hours(sum(gaps)),
        "not_resumed_cut_turns": len(not_resumed),
        "not_resumed_elapsed_hours": hours(sum(turn.elapsed_s for turn in not_resumed)),
        "not_resumed_with_calls_after_stop": unresumed_with_calls(cut, calls),
        "carried_context": carried_context(cut, turns),
        "repeated_calls": repeated_calls(cut, calls),
        "finish_share_if_shutdown_waited": finish_shares(cut, turns.spans, waits_s),
        "by_keeper": breakdown(cut, "keeper", top),
        "by_runtime": breakdown(cut, "runtime_id", None),
        "repeat_cuts": cut_totals(cuts.repeats),
        "all_cuts": {
            **cut_totals(all_cuts),
            "shutdowns": len({turn.shutdown for turn in all_cuts}),
            "share_of_turn_span": share(sum(turn.elapsed_s for turn in all_cuts), turn_span_s),
            "cuts_per_turn": cuts_per_turn(all_cuts),
            "loss": loss_bounds(all_cuts, turn_span_s),
        },
    }


def days_between(from_date: str, to_date: str) -> list[datetime.date]:
    first = datetime.date.fromisoformat(from_date)
    last = datetime.date.fromisoformat(to_date)
    return [first + datetime.timedelta(days=offset) for offset in range((last - first).days + 1)]


def tool_call_files(base_path: pathlib.Path, day: datetime.date) -> list[pathlib.Path]:
    folder = base_path / ".masc" / "tool_calls" / f"{day:%Y-%m}"
    pattern = re.compile(rf"{day:%d}(\.\d{{3}})?\.jsonl")
    if not folder.is_dir():
        return []
    return sorted(path for path in folder.iterdir() if pattern.fullmatch(path.name))


def input_paths(base_path: pathlib.Path, days: Sequence[datetime.date], skipped: Skipped) -> Inputs:
    logs: list[pathlib.Path] = []
    costs: list[pathlib.Path] = []
    tool_calls: list[pathlib.Path] = []
    for day in days:
        log = base_path / ".masc" / "logs" / f"system_log_{day.isoformat()}.jsonl"
        cost = base_path / ".masc" / "costs" / f"{day:%Y-%m}" / f"{day:%d}.jsonl"
        ledger = tool_call_files(base_path, day)
        for label, found, target in (
            ("logs", [log] if log.is_file() else [], logs),
            ("costs", [cost] if cost.is_file() else [], costs),
            ("tool_calls", ledger, tool_calls),
        ):
            if found:
                target.extend(found)
            else:
                skipped.missing_days.append(f"{label}:{day.isoformat()}")
    return Inputs(logs, costs, tool_calls)


def measure(
    base_path: pathlib.Path,
    from_date: str,
    to_date: str,
    recent_s: Sequence[float],
    waits_s: Sequence[float],
    top: int,
) -> dict[str, object]:
    skipped = Skipped()
    inputs = input_paths(base_path, days_between(from_date, to_date), skipped)
    shutdowns, stops = read_logs(inputs.logs, skipped)
    parsed = read_costs(inputs.costs, skipped)
    turns = index_requests(parsed)
    attributed, unattributed = attribute(stops, shutdowns)
    found = [find_cut_turns(attributed, turns, recent) for recent in recent_s]
    wanted = {(turn.keeper, turn.turn) for cuts in found for turn in cuts.first}
    calls = read_tool_calls(inputs.tool_calls, wanted, skipped)
    blocks = [
        window_block(recent, cuts, len(shutdowns), turns, calls, waits_s, top)
        for recent, cuts in zip(recent_s, found, strict=True)
    ]
    return {
        "params": {
            "from_date": from_date,
            "to_date": to_date,
            "recent_request_s": list(recent_s),
            "wait_s": list(waits_s),
            "attribution_window_s": ATTRIBUTION_WINDOW_S,
            "clock_slack_s": CLOCK_SLACK_S,
        },
        "shutdowns": len(shutdowns),
        "stop_lines": len(stops),
        "attributed_stop_lines": len(attributed),
        "unattributed_stop_lines": unattributed,
        "requests": len(parsed),
        "turns": len(turns.spans),
        "turn_span_hours": hours(sum(end - start for start, end in turns.spans.values())),
        "skipped": dataclasses.asdict(skipped),
        "windows": blocks,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--recent-request-s", type=float, action="append", dest="recent")
    parser.add_argument("--wait-s", type=float, action="append", dest="waits")
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    for day in (args.from_date, args.to_date):
        try:
            datetime.date.fromisoformat(day)
        except ValueError:
            parser.error(f"not a YYYY-MM-DD day: {day}")
    if args.from_date > args.to_date:
        parser.error("--from-date is after --to-date")
    result = measure(
        args.base_path.expanduser(),
        args.from_date,
        args.to_date,
        tuple(args.recent or DEFAULT_RECENT_S),
        tuple(args.waits or DEFAULT_DRAIN_S),
        args.top,
    )
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out is not None:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
