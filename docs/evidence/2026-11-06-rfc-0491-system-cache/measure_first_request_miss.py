# pyright: strict
"""First-request cache misses by which System blocks changed (RFC-0491 §1.2, §6).

usage: python3 -I measure_first_request_miss.py <base-path>/.masc <YYYY-MM/DD> [--start <iso>] [--end <iso>]

Pairs consecutive turns of one Keeper from its turn records. A block whose
digest differs between the two turns is a changed block; a different
`model_input_front` (kind, digest) is a moved front. The later turn's first
request is the earliest `per_request` row of the cost ledger for
(agent, trace_id, keeper_turn_id = absolute_turn). Official client Keepers
write no `per_request` row, so their pairs count but join nothing.
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import sys
from collections import Counter
from collections.abc import Iterator
from dataclasses import dataclass
from typing import cast

BLOCKS = ("keeper_instructions", "active_goals", "completion_authority", "constitution_amendments")
NO_CHANGE = ("none",)

type Json = dict[str, object]
type Front = tuple[object, object]
type Row = tuple[tuple[str, ...], bool]


@dataclass(frozen=True, slots=True)
class FirstRequest:
    timestamp: datetime.datetime
    miss_tokens: int
    input_tokens: int


@dataclass(frozen=True, slots=True)
class Turn:
    front: Front
    digests: tuple[tuple[str, object], ...]
    key: tuple[str, object, object]


def instant(value: object) -> datetime.datetime | None:
    match value:
        case int() | float():
            return datetime.datetime.fromtimestamp(value, datetime.UTC)
        case str():
            return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        case _:
            return None


def as_json(value: object) -> Json | None:
    if isinstance(value, dict):
        return {str(k): v for k, v in cast("dict[object, object]", value).items()}
    return None


def as_list(value: object) -> list[object]:
    return cast("list[object]", value) if isinstance(value, list) else []


def objects(path: pathlib.Path) -> Iterator[Json]:
    with path.open(encoding="utf-8") as lines:
        for line in lines:
            try:
                value: object = json.loads(line)
            except json.JSONDecodeError:
                continue
            row = as_json(value)
            if row is not None:
                yield row


def count(value: object) -> int:
    return value if isinstance(value, int) else 0


@dataclass(frozen=True, slots=True)
class Window:
    start: datetime.datetime | None
    end: datetime.datetime | None

    def holds(self, at: datetime.datetime | None) -> bool:
        return (
            at is not None
            and (self.start is None or self.start <= at)
            and (self.end is None or at < self.end)
        )


def first_requests(costs: pathlib.Path, window: Window) -> dict[tuple[str, object, object], FirstRequest]:
    first: dict[tuple[str, object, object], FirstRequest] = {}
    for row in objects(costs):
        at = instant(row.get("timestamp"))
        if row.get("usage_scope") != "per_request" or at is None or not window.holds(at):
            continue
        key = (str(row.get("agent")), row.get("trace_id"), row.get("keeper_turn_id"))
        seen = first.get(key)
        if seen is None or at < seen.timestamp:
            first[key] = FirstRequest(at, count(row.get("cache_miss_input_tokens")), count(row.get("input_tokens")))
    return first


def turns(keeper: str, records: pathlib.Path, window: Window) -> Iterator[Turn]:
    for row in objects(records):
        if not window.holds(instant(row.get("ts"))):
            continue
        front_fields = as_json(row.get("model_input_front")) or {}
        digests: list[tuple[str, object]] = []
        for item in as_list(row.get("blocks")):
            block = as_json(item)
            if block is not None and block.get("block") in BLOCKS:
                digests.append((str(block.get("block")), block.get("digest")))
        yield Turn(
            front=(front_fields.get("kind"), front_fields.get("digest")),
            digests=tuple(sorted(digests, key=lambda pair: pair[0])),
            key=(keeper, row.get("trace_id"), row.get("absolute_turn")),
        )


def changed(previous: Turn, current: Turn) -> tuple[str, ...]:
    old, new = dict(previous.digests), dict(current.digests)
    return tuple(name for name in BLOCKS if old.get(name) != new.get(name)) or NO_CHANGE


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(usage=__doc__)
    parser.add_argument("base", type=pathlib.Path)
    parser.add_argument("day")
    parser.add_argument("--start", type=instant)
    parser.add_argument("--end", type=instant)
    args = parser.parse_args(argv[1:])
    base = cast("pathlib.Path", args.base)
    day = cast("str", args.day)
    window = Window(cast("datetime.datetime | None", args.start), cast("datetime.datetime | None", args.end))
    first = first_requests(base / "costs" / f"{day}.jsonl", window)
    pairs: Counter[Row] = Counter()
    joined: Counter[Row] = Counter()
    miss: Counter[Row] = Counter()
    sent: Counter[Row] = Counter()
    for keeper_dir in sorted((base / "keepers").iterdir()):
        records = keeper_dir / "turn-records" / f"{day}.jsonl"
        if not records.is_file():
            continue
        previous: Turn | None = None
        for turn in turns(keeper_dir.name, records, window):
            if previous is not None:
                row: Row = (changed(previous, turn), previous.front != turn.front)
                pairs[row] += 1
                request = first.get(turn.key)
                if request is not None:
                    joined[row] += 1
                    miss[row] += request.miss_tokens
                    sent[row] += request.input_tokens
            previous = turn
    total = sum(miss.values())
    print(f"window {day} start={window.start or '-'} end={window.end or '-'}: pairs {pairs.total()}, joined {joined.total()}, first-request miss tokens {total:,}")
    print("| changed System blocks | front moved | pairs | joined | first-request miss tokens | share | miss rate |")
    print("|---|---|---|---|---|---|---|")
    for row, n in sorted(pairs.items(), key=lambda item: (item[0][0] == NO_CHANGE, -item[1])):
        share = f"{miss[row] / total:.1%}" if total else "-"
        rate = f"{miss[row] / sent[row]:.1%}" if sent[row] else "-"
        print(f"| {' + '.join(row[0])} | {'yes' if row[1] else 'no'} | {n} | {joined[row]} | {miss[row]:,} | {share} | {rate} |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
