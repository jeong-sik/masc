#!/usr/bin/env python3
"""Compare tool calls and stored requests before and after one deploy instant.

Reads two stores under `<base-path>/.masc` and never writes to them:

- `tool_calls/YYYY-MM/DD.jsonl` and its `DD.NNN.jsonl` segments: rows with
  `record_kind == "tool_call"`. The fields used are `ts` (when the row was written, after the
  call returned), `keeper`, `tool`, `input`, `output` and `result_bytes`. A call that began before
  the deploy instant and returned after it counts as after; on 2026-11-05 no call does that for
  the three boot instants of the README (counted outside the script).
- `keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl`: one captured request per turn.
  The fields used are `captured_at` and `tool_schemas[].name` and `.artifact.bytes`,
  the size of one tool schema as the Keeper sent it.

Definitions:

- before: from 00:00 UTC of `--from-date` up to `--deploy-at`, without the days named by
  `--exclude-day`. A day is left out as a whole, so a window that starts on an excluded day
  loses that day's hours too.
- after: from `--deploy-at` up to `--until`.
- hours of a side: the length of the side in hours. For the before side, the hours of each
  excluded day are not counted.
- bytes per call: the sum of `result_bytes` over the calls divided by their number. A row
  without an integer `result_bytes` counts as 0 bytes.
- contains call: a call whose `input` is an object with a `contains` key. The report gives
  bytes per call for the contains calls and for the other calls of the same side, which
  compares two kinds of call inside one window and does not depend on the workload.
- delegate state: the first `"state": "<Name>"` in the recorded `output` text of a
  `masc_keeper_delegate_status` call. The ledger keeps only the start of a long output, and
  the state is written near the start. A call whose output has no such text counts as
  `no_state`: a rejected call, or an error text from the caller side.
- repeat poll: a `masc_keeper_delegate_status` call whose `input.operation_id` was already
  polled by the same Keeper on the same side with the same delegate state. It returned a state
  the Keeper had already read.
- surface: the sum of `tool_schemas[].artifact.bytes` of one captured request.
- ride: the tool's name is in the request's `tool_schemas`.
- keeper delta: the median surface of a Keeper's after requests minus the median of its
  before requests, for Keepers with at least `MIN_KEEPER_REQUESTS` requests on both sides.
  The report gives the median of those deltas.

What the numbers do not show: the workload differs between the sides (see `workload`), the
sides are not randomized, and a change in bytes per call can come from which Keepers and
tasks were running. The per-day rows in `by_day` show the trend before the deploy, so a
difference that was already there before it is visible.

Usage:
    python3 docs/evidence/post-deploy-effects-2026-11/measure_post_deploy_effects.py --base-path ~/me \\
        --from-date 2026-11-01 --deploy-at 2026-11-05T06:02:38Z --until 2026-11-06T00:00:00Z \\
        --exclude-day 2026-11-01 --json-out result.json
    python3 -m unittest discover -s docs/evidence/post-deploy-effects-2026-11
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import re
import statistics
import sys
from collections import defaultdict
from collections.abc import Iterator, Mapping, Sequence
from typing import cast

DELEGATE_STATUS_TOOL = "masc_keeper_delegate_status"
DEFAULT_CONTAINS_TOOLS = ("masc_schedule_notes_list", "keeper_artifact_read")
DEFAULT_RIDE_TOOLS = ("BrowserSession", "BrowserInstruct", "keeper_candle_gift", "keeper_candle_equip")
MIN_KEEPER_REQUESTS = 5
SECONDS_PER_HOUR = 3600.0
SECONDS_PER_DAY = 86400.0
STATE_PATTERN = re.compile(r'"state"\s*:\s*"([A-Za-z_]+)"')
NO_STATE = "no_state"
SIDES = ("before", "after")


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    ts: float
    keeper: str
    tool: str
    result_bytes: int
    contains: bool
    state: str | None
    operation: str | None


@dataclasses.dataclass(frozen=True, slots=True)
class Request:
    captured_at: float
    keeper: str
    surface: int
    tools: frozenset[str]


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0
    unusable_rows: int = 0
    missing_days: list[str] = dataclasses.field(default_factory=lambda: cast(list[str], []))


@dataclasses.dataclass(frozen=True, slots=True)
class Window:
    start: float
    deploy: float
    until: float
    excluded: frozenset[datetime.date]


def utc_day(ts: float) -> datetime.date:
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).date()


def day_start(day: datetime.date) -> float:
    return datetime.datetime(day.year, day.month, day.day, tzinfo=datetime.timezone.utc).timestamp()


def parse_utc(value: str) -> float:
    parsed = datetime.datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise ValueError(f"no UTC offset: {value}")
    return parsed.timestamp()


def as_float(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    return float(value) if isinstance(value, (int, float)) else None


def as_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_str(value: object) -> str | None:
    return value if isinstance(value, str) and value != "" else None


def side_of(window: Window, ts: float) -> str | None:
    """`before`, `after`, or None when the instant is outside the window or on an excluded day."""
    if ts < window.start or ts >= window.until:
        return None
    if ts >= window.deploy:
        return "after"
    return None if utc_day(ts) in window.excluded else "before"


def side_hours(window: Window) -> dict[str, float]:
    before = 0.0
    day = utc_day(window.start)
    while day_start(day) < window.deploy:
        if day not in window.excluded:
            low = max(day_start(day), window.start)
            high = min(day_start(day) + SECONDS_PER_DAY, window.deploy)
            before += max(0.0, high - low)
        day += datetime.timedelta(days=1)
    return {"before": before / SECONDS_PER_HOUR, "after": (window.until - window.deploy) / SECONDS_PER_HOUR}


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


def delegate_state(output: object) -> str:
    text = output if isinstance(output, str) else json.dumps(output)
    found = STATE_PATTERN.search(text)
    return found.group(1) if found else NO_STATE


def parse_call(row: Mapping[str, object], skipped: Skipped) -> Call | None:
    if row.get("record_kind") != "tool_call":
        return None
    ts = as_float(row.get("ts"))
    tool = as_str(row.get("tool"))
    keeper = as_str(row.get("keeper"))
    if ts is None or tool is None or keeper is None:
        skipped.unusable_rows += 1
        return None
    row_input = row.get("input")
    fields = cast(dict[str, object], row_input) if isinstance(row_input, dict) else {}
    is_status = tool == DELEGATE_STATUS_TOOL
    return Call(
        ts=ts,
        keeper=keeper,
        tool=tool,
        result_bytes=as_int(row.get("result_bytes")) or 0,
        contains="contains" in fields,
        state=delegate_state(row.get("output")) if is_status else None,
        operation=as_str(fields.get("operation_id")) if is_status else None,
    )


def parse_request(row: Mapping[str, object]) -> Request | None:
    captured_at = as_float(row.get("captured_at"))
    keeper = as_str(row.get("keeper"))
    schemas = row.get("tool_schemas")
    if captured_at is None or keeper is None or not isinstance(schemas, list):
        return None
    surface = 0
    names: set[str] = set()
    for schema in cast(list[object], schemas):
        if not isinstance(schema, dict):
            continue
        fields = cast(dict[str, object], schema)
        name = as_str(fields.get("name"))
        if name is not None:
            names.add(name)
        artifact = fields.get("artifact")
        if isinstance(artifact, dict):
            surface += as_int(cast(dict[str, object], artifact).get("bytes")) or 0
    return Request(captured_at, keeper, surface, frozenset(names))


def tool_call_files(base_path: pathlib.Path, day: datetime.date) -> list[pathlib.Path]:
    folder = base_path / ".masc" / "tool_calls" / f"{day:%Y-%m}"
    pattern = re.compile(rf"{day:%d}(\.\d{{3}})?\.jsonl")
    if not folder.is_dir():
        return []
    return sorted(path for path in folder.iterdir() if pattern.fullmatch(path.name))


def request_files(base_path: pathlib.Path, day: datetime.date) -> list[pathlib.Path]:
    keepers = base_path / ".masc" / "keepers"
    if not keepers.is_dir():
        return []
    found = (keeper / "provider-inputs" / f"{day:%Y-%m}" / f"{day:%d}.jsonl" for keeper in keepers.iterdir())
    return sorted(path for path in found if path.is_file())


def days_of(window: Window) -> list[datetime.date]:
    first = utc_day(window.start)
    last = utc_day(window.until - 1.0)
    return [first + datetime.timedelta(days=offset) for offset in range((last - first).days + 1)]


def read_calls(base_path: pathlib.Path, window: Window, skipped: Skipped) -> list[Call]:
    calls: list[Call] = []
    for day in days_of(window):
        files = tool_call_files(base_path, day)
        if not files:
            skipped.missing_days.append(f"tool_calls:{day.isoformat()}")
        for path in files:
            for row in read_objects(path, skipped):
                call = parse_call(row, skipped)
                if call is not None:
                    calls.append(call)
    return calls


def read_requests(base_path: pathlib.Path, window: Window, skipped: Skipped) -> list[Request]:
    requests: list[Request] = []
    for day in days_of(window):
        files = request_files(base_path, day)
        if not files:
            skipped.missing_days.append(f"provider_inputs:{day.isoformat()}")
        for path in files:
            for row in read_objects(path, skipped):
                request = parse_request(row)
                if request is not None:
                    requests.append(request)
    return requests


def rank_quantile(sorted_values: Sequence[int], q: float) -> int:
    """The sample at rank round((n - 1) * q), halves rounded up, as `Tool_metrics.percentile` picks it."""
    position = (len(sorted_values) - 1) * q
    whole = int(position)
    return sorted_values[whole + 1 if position - whole >= 0.5 else whole]


def mean_bytes(calls: Sequence[Call]) -> float | None:
    return sum(call.result_bytes for call in calls) / len(calls) if calls else None


def per_call(calls: Sequence[Call]) -> dict[str, object]:
    with_contains = [call for call in calls if call.contains]
    plain = [call for call in calls if not call.contains]
    return {
        "calls": len(calls),
        "result_bytes": sum(call.result_bytes for call in calls),
        "bytes_per_call": mean_bytes(calls),
        "contains_calls": len(with_contains),
        "contains_share": len(with_contains) / len(calls) if calls else None,
        "contains_bytes_per_call": mean_bytes(with_contains),
        "plain_bytes_per_call": mean_bytes(plain),
    }


def workload(calls: Sequence[Call], hours: float) -> dict[str, object]:
    total = sum(call.result_bytes for call in calls)
    return {
        "calls": len(calls),
        "result_bytes": total,
        "keepers": len({call.keeper for call in calls}),
        "calls_per_hour": len(calls) / hours if hours > 0 else None,
        "result_bytes_per_hour": total / hours if hours > 0 else None,
    }


def by_state(calls: Sequence[Call]) -> dict[str, dict[str, object]]:
    grouped: dict[str, list[int]] = defaultdict(list)
    for call in calls:
        grouped[call.state or NO_STATE].append(call.result_bytes)
    block: dict[str, dict[str, object]] = {}
    for state in sorted(grouped):
        sizes = sorted(grouped[state])
        block[state] = {
            "calls": len(sizes),
            "result_bytes": sum(sizes),
            "mean": sum(sizes) / len(sizes),
            "p50": rank_quantile(sizes, 0.5),
            "min": sizes[0],
            "max": sizes[-1],
        }
    return block


def repeat_polls(calls: Sequence[Call]) -> dict[str, object]:
    """Polls that name an operation, and how many of them repeat an earlier poll of the same
    Keeper, operation and state. A repeat returned the state the Keeper had already read."""
    seen: set[tuple[str, str, str]] = set()
    polls = 0
    repeats = 0
    for call in sorted(calls, key=lambda each: each.ts):
        if call.operation is None:
            continue
        polls += 1
        key = (call.keeper, call.operation, call.state or NO_STATE)
        if key in seen:
            repeats += 1
        seen.add(key)
    return {
        "polls": polls,
        "operations": len({(call.keeper, call.operation) for call in calls if call.operation is not None}),
        "repeat_polls": repeats,
        "repeat_share": repeats / polls if polls else None,
    }


def surface_block(requests: Sequence[Request], ride_tools: Sequence[str]) -> dict[str, object]:
    surfaces = [request.surface for request in requests]
    return {
        "requests": len(requests),
        "surface_median": statistics.median(surfaces) if surfaces else None,
        "surface_mean": sum(surfaces) / len(surfaces) if surfaces else None,
        "rides": {tool: sum(1 for request in requests if tool in request.tools) for tool in ride_tools},
    }


def keeper_deltas(before: Sequence[Request], after: Sequence[Request]) -> dict[str, object]:
    sizes: dict[str, dict[str, list[int]]] = defaultdict(lambda: {"before": [], "after": []})
    for label, requests in (("before", before), ("after", after)):
        for request in requests:
            sizes[request.keeper][label].append(request.surface)
    deltas: list[float] = []
    for pair in sizes.values():
        if min(len(pair["before"]), len(pair["after"])) >= MIN_KEEPER_REQUESTS:
            deltas.append(statistics.median(pair["after"]) - statistics.median(pair["before"]))
    return {
        "keepers": len(deltas),
        "median_delta_bytes": statistics.median(deltas) if deltas else None,
        "keepers_smaller": sum(1 for delta in deltas if delta < 0),
    }


def by_day(calls: Sequence[Call], window: Window, tools: Sequence[str]) -> dict[str, dict[str, object]]:
    """One row per (tool, UTC day, side). The deploy day appears once per side."""
    grouped: dict[str, list[Call]] = defaultdict(list)
    for call in calls:
        if call.tool not in tools or call.ts < window.start or call.ts >= window.until:
            continue
        side = "after" if call.ts >= window.deploy else "before"
        grouped[f"{call.tool}|{utc_day(call.ts).isoformat()}|{side}"].append(call)
    return {key: per_call(grouped[key]) for key in sorted(grouped)}


def measure(
    base_path: pathlib.Path,
    window: Window,
    contains_tools: Sequence[str],
    ride_tools: Sequence[str],
) -> dict[str, object]:
    skipped = Skipped()
    calls = read_calls(base_path, window, skipped)
    requests = read_requests(base_path, window, skipped)
    hours = side_hours(window)
    sides: dict[str, list[Call]] = {label: [] for label in SIDES}
    for call in calls:
        side = side_of(window, call.ts)
        if side is not None:
            sides[side].append(call)
    request_sides: dict[str, list[Request]] = {label: [] for label in SIDES}
    for request in requests:
        side = side_of(window, request.captured_at)
        if side is not None:
            request_sides[side].append(request)
    all_tools = (*contains_tools, DELEGATE_STATUS_TOOL)
    return {
        "params": {
            "from": datetime.datetime.fromtimestamp(window.start, datetime.timezone.utc).isoformat(),
            "deploy_at": datetime.datetime.fromtimestamp(window.deploy, datetime.timezone.utc).isoformat(),
            "until": datetime.datetime.fromtimestamp(window.until, datetime.timezone.utc).isoformat(),
            "excluded_days": sorted(day.isoformat() for day in window.excluded),
            "min_keeper_requests": MIN_KEEPER_REQUESTS,
        },
        "hours": hours,
        "workload": {label: workload(sides[label], hours[label]) for label in SIDES},
        "tools": {
            tool: {label: per_call([call for call in sides[label] if call.tool == tool]) for label in SIDES}
            for tool in all_tools
        },
        "delegate_status_by_state": {
            label: by_state([call for call in sides[label] if call.tool == DELEGATE_STATUS_TOOL]) for label in SIDES
        },
        "delegate_status_repeats": {
            label: repeat_polls([call for call in sides[label] if call.tool == DELEGATE_STATUS_TOOL])
            for label in SIDES
        },
        "by_day": by_day(calls, window, all_tools),
        "schema_surface": {
            **{label: surface_block(request_sides[label], ride_tools) for label in SIDES},
            "keeper_delta": keeper_deltas(request_sides["before"], request_sides["after"]),
        },
        "skipped": dataclasses.asdict(skipped),
    }


def parse_day(value: str) -> datetime.date:
    return datetime.date.fromisoformat(value)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--deploy-at", required=True, help="ISO 8601 instant with an offset, for example 2026-11-05T06:02:38Z")
    parser.add_argument("--until", required=True, help="end of the after side, ISO 8601 with an offset")
    parser.add_argument("--exclude-day", type=parse_day, action="append", default=[], help="UTC day left out of the before side")
    parser.add_argument("--contains-tool", action="append", dest="contains_tools")
    parser.add_argument("--ride-tool", action="append", dest="ride_tools")
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        deploy = parse_utc(args.deploy_at.replace("Z", "+00:00"))
        until = parse_utc(args.until.replace("Z", "+00:00"))
    except ValueError as error:
        parser.error(str(error))
    start = day_start(args.from_date)
    if not start < deploy < until:
        parser.error("need --from-date before --deploy-at and --deploy-at before --until")
    window = Window(start, deploy, until, frozenset(args.exclude_day))
    result = measure(
        args.base_path.expanduser(),
        window,
        tuple(args.contains_tools or DEFAULT_CONTAINS_TOOLS),
        tuple(args.ride_tools or DEFAULT_RIDE_TOOLS),
    )
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out is not None:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
