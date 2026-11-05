#!/usr/bin/env python3
"""Rank the tools that ride in agent-core requests by how rarely a turn needs them,
and replay a `defer_loading = true` change over the stored requests.

Reads two stores under `<base-path>/.masc` and never writes to them:

- `keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl`: one captured request per
  turn. `tool_schemas[]` lists the tools that rode in it, and `artifact.bytes` is
  the JSON size of one tool's schema as the Keeper sent it.
- `tool_calls/YYYY-MM/DD[.NNN].jsonl`: the tool-call ledger.

Definitions:

- stored request: a captured request whose row has a `tool_schemas` list. The
  turn's other requests are not captured, so every count is over captured requests.
- surface: the sum of `artifact.bytes` over one stored request's `tool_schemas`.
- rides: the tool's name is in the request's `tool_schemas`.
- agent-core Keeper: a Keeper with at least one stored request in the window. Only
  agent-core lanes defer tools; the other lanes are handed the whole tool array.
- needed turn: a distinct (`trace_id`, `keeper_turn_id` or `turn`) pair of ledger
  rows with `record_kind == "tool_call"` and `tool == <name>` from an agent-core
  Keeper.
- loading cost: the sum of the tool's schema bytes over the stored requests that
  carry it.
- deferring cost: needed turns x the median surface. masc #32062 judges a deferral
  by this pair and not by call counts: loading costs the schema on every request,
  and deferring costs a request-prefix miss on each turn that has to load it.
- ratio: loading cost / deferring cost. A tool no turn needed has no ratio.
- replay: for each named tool, remove its schema from the stored requests that
  would no longer carry it. A conversation that has called a deferred tool carries
  its schema afterwards (`Keeper_identity_tool_search.already_used`), so a request
  keeps the schema when its Keeper called the tool, under one of two rules:
  `same-day` keeps it for the Keeper's requests of the day it called the tool
  (the estimate; it releases a schema a long conversation would still carry from
  an earlier day), and `from-first-call` keeps it for every request from the
  Keeper's first call in the window to the end of the window (the lower bound on
  what the change removes). Every request that carried the tool gains
  `len(name) + 2` bytes either way, because the `keeper_tool_search` listing names
  each deferred tool, placed or not, joined with ", ".

- composition: how much of a request body each part takes, for the stored requests
  that record `wire.body_bytes`. The parts are the tool schemas, the system prompt
  (`system_prompt.bytes`), the messages by role (the sum of `messages[].artifact.bytes`
  per `role`) and `unaccounted`, the rest of the body (image data of requests with
  media, and the JSON around the parts; never below zero). Shares are pooled over
  all bytes and taken as the median of the per-request shares. A message's
  `artifact.bytes` is the size of its stored JSON, which can exceed what the request
  carries: a tool result with typed blocks is stored with a flat `text_content` copy
  next to the blocks, and the request carries the blocks only. The message shares
  are upper bounds.

A tool's name here is the name the Keeper sees (`BrowserSession`), which is the
name in both stores. Its file under `config/tools/` can have another name
(`masc_browser_session`).

Nothing here reads message text.

Usage:
    docs/evidence/defer-loading-2026-11/measure_defer_replay.py --base-path ~/me \
        --from-date 2026-10-29 --to-date 2026-11-05 \
        --tools BrowserSession,BrowserInstruct,keeper_candle_gift,keeper_candle_equip \
        --json-out result.json
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
from collections.abc import Iterator, Mapping, Sequence
from types import MappingProxyType
from typing import cast

DAY_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}")
LISTING_SEPARATOR = ", "
CARRY_SAME_DAY = "same-day"
CARRY_FROM_FIRST_CALL = "from-first-call"
CARRY_RULES = (CARRY_SAME_DAY, CARRY_FROM_FIRST_CALL)
TOOL_SCHEMAS = "tool_schemas"
SYSTEM_PROMPT = "system_prompt"
UNACCOUNTED = "unaccounted"
DEFAULT_MIN_PRESENCE_PCT = 90.0
DEFAULT_TOP = 20


@dataclasses.dataclass(frozen=True, slots=True)
class StoredRequest:
    keeper: str
    day: str
    tools: Mapping[str, int]
    body_bytes: int
    system_bytes: int
    message_bytes: Mapping[str, int]


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    keeper: str
    day: str
    tool: str
    turn: tuple[str, str]


@dataclasses.dataclass(slots=True)
class Skipped:
    """What the readers could not use. Reported, never dropped silently."""

    bad_lines: int = 0
    bad_schema_entries: int = 0
    bad_message_entries: int = 0
    unplaced_files: int = 0


@dataclasses.dataclass(frozen=True, slots=True)
class ToolRow:
    name: str
    presence_pct: float
    median_bytes: float
    loading_bytes: int
    calls: int
    needed_turns: int
    ratio: float | None


@dataclasses.dataclass(frozen=True, slots=True)
class ReplayTool:
    name: str
    requests_carrying: int
    requests_released: int
    released_bytes: int
    listing_bytes: int
    keeper_days_loading: int


@dataclasses.dataclass(frozen=True, slots=True)
class Replay:
    carry: str
    tools: tuple[ReplayTool, ...]
    surface_median_before: float
    surface_median_after: float
    summed_before: int
    summed_after: int


@dataclasses.dataclass(frozen=True, slots=True)
class Composition:
    requests: int
    body_bytes: int
    pooled_pct: Mapping[str, float]
    median_pct: Mapping[str, float]


def _day_of(path: pathlib.Path) -> str | None:
    day = f"{path.parent.name}-{path.name.split('.', 1)[0]}"
    return day if DAY_PATTERN.fullmatch(day) else None


def _placed_in_window(path: pathlib.Path, from_day: str, to_day: str, skipped: Skipped) -> str | None:
    day = _day_of(path)
    if day is None:
        skipped.unplaced_files += 1
        return None
    return day if from_day <= day <= to_day else None


def _rows(path: pathlib.Path, skipped: Skipped) -> Iterator[dict[str, object]]:
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                row: object = json.loads(line)
            except json.JSONDecodeError:
                skipped.bad_lines += 1
                continue
            if isinstance(row, dict):
                yield cast(dict[str, object], row)
            else:
                skipped.bad_lines += 1


def _schema_sizes(schemas: list[object], skipped: Skipped) -> dict[str, int]:
    sizes: dict[str, int] = {}
    for entry in schemas:
        name: object = None
        size: object = None
        if isinstance(entry, dict):
            fields = cast(dict[str, object], entry)
            name = fields.get("name")
            artifact = fields.get("artifact")
            if isinstance(artifact, dict):
                size = cast(dict[str, object], artifact).get("bytes")
        if isinstance(name, str) and isinstance(size, int) and not isinstance(size, bool):
            sizes[name] = sizes.get(name, 0) + size
        else:
            skipped.bad_schema_entries += 1
    return sizes


def _int_field(container: object, key: str) -> int | None:
    if not isinstance(container, dict):
        return None
    value = cast(dict[str, object], container).get(key)
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _message_sizes(messages: object, skipped: Skipped) -> dict[str, int]:
    sizes: dict[str, int] = {}
    if messages is None:
        return sizes
    if not isinstance(messages, list):
        skipped.bad_message_entries += 1
        return sizes
    for entry in cast(list[object], messages):
        fields = cast(dict[str, object], entry) if isinstance(entry, dict) else {}
        role = fields.get("role")
        size = _int_field(fields.get("artifact"), "bytes")
        if isinstance(role, str) and size is not None:
            sizes[role] = sizes.get(role, 0) + size
        else:
            skipped.bad_message_entries += 1
    return sizes


def read_stored_requests(
    masc_dir: pathlib.Path, from_day: str, to_day: str, skipped: Skipped
) -> list[StoredRequest]:
    found: list[StoredRequest] = []
    for path in sorted(masc_dir.glob("keepers/*/provider-inputs/*/*.jsonl")):
        day = _placed_in_window(path, from_day, to_day, skipped)
        if day is None:
            continue
        keeper = path.parents[2].name
        for row in _rows(path, skipped):
            schemas = row.get("tool_schemas")
            if not isinstance(schemas, list):
                continue
            sizes = _schema_sizes(cast(list[object], schemas), skipped)
            messages = _message_sizes(row.get("messages"), skipped)
            found.append(
                StoredRequest(
                    keeper=keeper,
                    day=day,
                    tools=MappingProxyType(sizes),
                    body_bytes=_int_field(row.get("wire"), "body_bytes") or 0,
                    system_bytes=_int_field(row.get("system_prompt"), "bytes") or 0,
                    message_bytes=MappingProxyType(messages),
                )
            )
    return found


def read_calls(masc_dir: pathlib.Path, from_day: str, to_day: str, skipped: Skipped) -> list[Call]:
    found: list[Call] = []
    for path in sorted(masc_dir.glob("tool_calls/*/*.jsonl")):
        day = _placed_in_window(path, from_day, to_day, skipped)
        if day is None:
            continue
        for row in _rows(path, skipped):
            if row.get("record_kind") != "tool_call":
                continue
            tool, keeper = row.get("tool"), row.get("keeper")
            if not isinstance(tool, str) or not isinstance(keeper, str):
                skipped.bad_lines += 1
                continue
            turn_id = row.get("keeper_turn_id") or row.get("turn")
            found.append(Call(keeper, day, tool, (str(row.get("trace_id")), str(turn_id))))
    return found


def _agent_core_calls(requests: Sequence[StoredRequest], calls: Sequence[Call]) -> list[Call]:
    keepers = {request.keeper for request in requests}
    return [call for call in calls if call.keeper in keepers]


def _surface(request: StoredRequest) -> int:
    return sum(request.tools.values())


def summarize_tools(
    requests: Sequence[StoredRequest], calls: Sequence[Call], min_presence_pct: float
) -> tuple[float, list[ToolRow]]:
    """Surface median and one row per tool riding in at least `min_presence_pct` of requests."""
    if not requests:
        raise ValueError("no stored request in the window")
    surface_median = statistics.median(_surface(request) for request in requests)
    sizes: dict[str, list[int]] = {}
    for request in requests:
        for name, size in request.tools.items():
            sizes.setdefault(name, []).append(size)
    call_counts: dict[str, int] = {}
    turns: dict[str, set[tuple[str, str]]] = {}
    for call in _agent_core_calls(requests, calls):
        call_counts[call.tool] = call_counts.get(call.tool, 0) + 1
        turns.setdefault(call.tool, set()).add(call.turn)
    rows: list[ToolRow] = []
    for name, per_request in sizes.items():
        presence = 100 * len(per_request) / len(requests)
        if presence < min_presence_pct:
            continue
        loading = sum(per_request)
        needed = len(turns.get(name, ()))
        ratio = loading / (needed * surface_median) if needed else None
        rows.append(
            ToolRow(
                name=name,
                presence_pct=presence,
                median_bytes=statistics.median(per_request),
                loading_bytes=loading,
                calls=call_counts.get(name, 0),
                needed_turns=needed,
                ratio=ratio,
            )
        )
    rows.sort(key=lambda row: (row.ratio is not None, -(row.ratio or 0.0), -row.loading_bytes, row.name))
    return surface_median, rows


def replay(
    requests: Sequence[StoredRequest], calls: Sequence[Call], names: Sequence[str], carry: str = CARRY_SAME_DAY
) -> Replay:
    if carry not in CARRY_RULES:
        raise ValueError(f"unknown carry rule {carry!r}; use one of {', '.join(CARRY_RULES)}")
    if not requests:
        raise ValueError("no stored request in the window")
    riding = {name for request in requests for name in request.tools}
    never = [name for name in names if name not in riding]
    if never:
        raise ValueError(f"never rides in a stored request (typo, or already deferred): {', '.join(never)}")
    first_call: dict[tuple[str, str], str] = {}
    for call in calls:
        key = (call.keeper, call.tool)
        first_call[key] = min(call.day, first_call.get(key, call.day))
    called_days = {(call.keeper, call.day, call.tool) for call in calls}

    def carried(request: StoredRequest, name: str) -> bool:
        if carry == CARRY_SAME_DAY:
            return (request.keeper, request.day, name) in called_days
        return first_call.get((request.keeper, name), "9999-99-99") <= request.day

    carrying = dict.fromkeys(names, 0)
    released = dict.fromkeys(names, 0)
    released_bytes = dict.fromkeys(names, 0)
    listing_bytes = dict.fromkeys(names, 0)
    loading_days: dict[str, set[tuple[str, str]]] = {name: set() for name in names}
    before_sizes: list[int] = []
    after_sizes: list[int] = []
    for request in requests:
        before = _surface(request)
        after = before
        for name in names:
            size = request.tools.get(name)
            if size is None:
                continue
            carrying[name] += 1
            listing = len(name) + len(LISTING_SEPARATOR)
            listing_bytes[name] += listing
            after += listing
            if carried(request, name):
                loading_days[name].add((request.keeper, request.day))
            else:
                released[name] += 1
                released_bytes[name] += size
                after -= size
        before_sizes.append(before)
        after_sizes.append(after)
    tools = tuple(
        ReplayTool(
            name=name,
            requests_carrying=carrying[name],
            requests_released=released[name],
            released_bytes=released_bytes[name],
            listing_bytes=listing_bytes[name],
            keeper_days_loading=len(loading_days[name]),
        )
        for name in names
    )
    return Replay(
        carry=carry,
        tools=tools,
        surface_median_before=statistics.median(before_sizes),
        surface_median_after=statistics.median(after_sizes),
        summed_before=sum(before_sizes),
        summed_after=sum(after_sizes),
    )


def composition(requests: Sequence[StoredRequest]) -> Composition | None:
    """Shares of the request body by part, over the requests that record a body size."""
    measured = [request for request in requests if request.body_bytes > 0]
    if not measured:
        return None
    pooled: dict[str, int] = {}
    shares: dict[str, list[float]] = {}
    for request in measured:
        parts = {TOOL_SCHEMAS: sum(request.tools.values()), SYSTEM_PROMPT: request.system_bytes}
        for role, size in request.message_bytes.items():
            parts[f"messages.{role}"] = size
        parts[UNACCOUNTED] = max(request.body_bytes - sum(parts.values()), 0)
        for name, size in parts.items():
            pooled[name] = pooled.get(name, 0) + size
            shares.setdefault(name, []).append(size / request.body_bytes)
    total = sum(request.body_bytes for request in measured)
    padding = [0.0] * len(measured)
    return Composition(
        requests=len(measured),
        body_bytes=total,
        pooled_pct={name: 100 * size / total for name, size in pooled.items()},
        median_pct={
            name: 100 * statistics.median(values + padding[len(values) :]) for name, values in shares.items()
        },
    )


def to_json(
    from_day: str,
    to_day: str,
    requests: Sequence[StoredRequest],
    surface_median: float,
    rows: Sequence[ToolRow],
    breakdown: Composition | None,
    outcomes: Sequence[Replay],
    skipped: Skipped,
) -> dict[str, object]:
    return {
        "window": {"from": from_day, "to": to_day},
        "stored_requests": len(requests),
        "agent_core_keepers": len({request.keeper for request in requests}),
        "keeper_days": len({(request.keeper, request.day) for request in requests}),
        "surface_median_bytes": surface_median,
        "skipped": dataclasses.asdict(skipped),
        "composition": None
        if breakdown is None
        else {
            "requests": breakdown.requests,
            "body_bytes": breakdown.body_bytes,
            "pooled_pct": {name: round(value, 2) for name, value in breakdown.pooled_pct.items()},
            "median_pct": {name: round(value, 2) for name, value in breakdown.median_pct.items()},
        },
        "tools": [
            {**dataclasses.asdict(row), "ratio": None if row.ratio is None else round(row.ratio, 2)}
            for row in rows
        ],
        "replays": [
            {
                **dataclasses.asdict(outcome),
                "removed_bytes": outcome.summed_before - outcome.summed_after,
                "removed_pct": round(
                    100 * (outcome.summed_before - outcome.summed_after) / outcome.summed_before, 2
                ),
            }
            for outcome in outcomes
        ],
    }


def _day_argument(text: str) -> str:
    try:
        return datetime.date.fromisoformat(text).isoformat()
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"not a YYYY-MM-DD date: {text}") from error


def _print_report(
    from_day: str,
    to_day: str,
    requests: Sequence[StoredRequest],
    surface_median: float,
    rows: Sequence[ToolRow],
    breakdown: Composition | None,
    outcomes: Sequence[Replay],
    skipped: Skipped,
    top: int,
) -> None:
    keepers = len({request.keeper for request in requests})
    print(
        f"window {from_day}..{to_day}: {len(requests)} stored requests, {keepers} agent-core Keepers, "
        f"surface median {surface_median:.0f} B"
    )
    print(
        f"skipped: {skipped.bad_lines} unreadable lines, {skipped.bad_schema_entries} schema entries "
        f"without a size, {skipped.bad_message_entries} message entries without a role or size, "
        f"{skipped.unplaced_files} files whose name is not a day"
    )
    if breakdown is not None:
        print(
            f"composition of {breakdown.requests} requests with a body size "
            f"({breakdown.body_bytes / 1e9:.2f} GB pooled): share of body, pooled / median per request"
        )
        for name in sorted(breakdown.pooled_pct, key=lambda part: -breakdown.pooled_pct[part]):
            print(f"  {name:24} {breakdown.pooled_pct[name]:6.1f}% {breakdown.median_pct[name]:6.1f}%")
    print(f"{'tool':36} {'pres%':>6} {'med_B':>6} {'load_MB':>8} {'calls':>6} {'turns':>6} {'ratio':>7}")
    for row in rows[:top]:
        ratio = "-" if row.ratio is None else f"{row.ratio:.1f}"
        print(
            f"{row.name[:36]:36} {row.presence_pct:6.1f} {row.median_bytes:6.0f} "
            f"{row.loading_bytes / 1e6:8.2f} {row.calls:6d} {row.needed_turns:6d} {ratio:>7}"
        )
    for outcome in outcomes:
        removed = outcome.summed_before - outcome.summed_after
        print(
            f"replay ({outcome.carry}): surface median {outcome.surface_median_before:.0f} B -> "
            f"{outcome.surface_median_after:.0f} B; summed {outcome.summed_before / 1e6:.1f} MB -> "
            f"{outcome.summed_after / 1e6:.1f} MB ({100 * removed / outcome.summed_before:.2f}% removed)"
        )
        print(f"{'tool':28} {'carrying':>9} {'released':>9} {'net_MB':>7} {'keeper_days_loading':>20}")
        for tool in outcome.tools:
            net = tool.released_bytes - tool.listing_bytes
            print(
                f"{tool.name:28} {tool.requests_carrying:9d} {tool.requests_released:9d} "
                f"{net / 1e6:7.2f} {tool.keeper_days_loading:20d}"
            )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True, help="directory that holds .masc")
    parser.add_argument("--from-date", type=_day_argument, required=True)
    parser.add_argument("--to-date", type=_day_argument, required=True)
    parser.add_argument("--min-presence", type=float, default=DEFAULT_MIN_PRESENCE_PCT)
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--tools", default="", help="comma separated names to replay a deferral for")
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    from_day, to_day = cast(str, args.from_date), cast(str, args.to_date)
    if from_day > to_day:
        parser.error("--from-date is after --to-date")
    masc_dir = cast(pathlib.Path, args.base_path) / ".masc"
    skipped = Skipped()
    requests = read_stored_requests(masc_dir, from_day, to_day, skipped)
    calls = read_calls(masc_dir, from_day, to_day, skipped)
    names = [name for name in cast(str, args.tools).split(",") if name]
    try:
        surface_median, rows = summarize_tools(requests, calls, cast(float, args.min_presence))
        outcomes = [replay(requests, calls, names, rule) for rule in CARRY_RULES] if names else []
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    breakdown = composition(requests)
    _print_report(from_day, to_day, requests, surface_median, rows, breakdown, outcomes, skipped, cast(int, args.top))
    json_out = cast(pathlib.Path | None, args.json_out)
    if json_out is not None:
        payload = to_json(from_day, to_day, requests, surface_median, rows, breakdown, outcomes, skipped)
        json_out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
