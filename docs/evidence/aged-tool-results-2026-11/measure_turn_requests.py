#!/usr/bin/env python3
"""Count model requests per turn and the prefix-cache hit of a turn's first request.

`measure_aged_rewrite_cost.py` needs two numbers it cannot read from the stored requests:
how many requests a turn sends (each one reads the history, so each one gains from a
smaller history) and how often the first request of a turn finds the history in the
provider's cache (a cold first request pays nothing extra for a rewrite).

Reads `<base-path>/.masc/keeper_turn_events/<keeper>/<trace>-<turn>-<hash>.jsonl`, one file
per turn, and never writes to it. The events used:

- `run_started`: `ts` and `run_id` (`<trace>#<turn>`).
- `agent_core_stream_message_start`: `model`.
- `agent_core_stream_message_delta` with `usage`: `stream_scope` (the request's place in the
  turn), `usage.input_tokens` (cache reads included) and `usage.cache_read_input_tokens`.
  The last usage of a `stream_scope` is the request's usage.
- the `ts` of the last line, which is when the turn ended.

A usage without `cache_read_input_tokens` counts as no cache read.

Only the lanes that run through the Agent Core write these usage events. A turn on a
vendor CLI lane has none and is not counted.

Definitions:

- turn: one file with a `run_started` event, at least one usage event and a `run_id` of the
  form `<trace>#<turn>`. A turn started before `--since` or at or after `--until` is not counted.
- requests per turn: the number of `stream_scope` values that carry a usage event.
- first request: the usage of the smallest `stream_scope`. Its hit is
  `cache_read_input_tokens / input_tokens`.
- gap: the start of the turn minus the end of the turn before it (same keeper and trace, turn
  number one lower). A turn without that turn in the files read has the gap `unknown`.
- model: the `model` of the first `agent_core_stream_message_start`.
- median, p90: the value at rank `ceil(q * n)` of the sorted values, never an average of two.

Cached tokens are provider-reported tokens, not bytes. The files are chosen by their
modification time, which is never earlier than the start of the turn they record.
A file that is deleted after the scan listed it is counted in `vanished_files` and not read.

Usage:
    python3 docs/evidence/aged-tool-results-2026-11/measure_turn_requests.py \
        --base-path ~/me --since 2026-11-05T03:00:00 --until 2026-11-06T03:00:00 --json-out result.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import math
import pathlib
import re
import sys
from collections import defaultdict
from collections.abc import Iterator, Sequence
from typing import cast

RUN_ID = re.compile(r"^(?P<trace>.+)#(?P<turn>[0-9]+)$")
DEFAULT_TOP = 6
UNKNOWN_MODEL = "unknown"
# Upper edges in seconds, ascending. The last bucket has no upper edge.
GAP_EDGES = ((60.0, "<1m"), (300.0, "1-5m"), (600.0, "5-10m"), (1800.0, "10-30m"), (3600.0, "30-60m"))
GAP_LAST = ">60m"
GAP_UNKNOWN = "unknown"
GAP_ORDER = (*(label for _, label in GAP_EDGES), GAP_LAST, GAP_UNKNOWN)


@dataclasses.dataclass(frozen=True, slots=True)
class Usage:
    input_tokens: int
    cache_read_tokens: int


@dataclasses.dataclass(frozen=True, slots=True)
class Turn:
    keeper: str
    trace: str
    number: int
    started: float
    ended: float
    model: str
    usages: tuple[Usage, ...]


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0
    no_usage: int = 0
    outside_window: int = 0
    vanished_files: int = 0


def as_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_number(value: object) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def as_object(value: object) -> dict[str, object] | None:
    return cast(dict[str, object], value) if isinstance(value, dict) else None


def parse_turn(keeper: str, lines: Sequence[str], skipped: Skipped) -> Turn | None:
    started: float | None = None
    ended: float | None = None
    trace: str | None = None
    number: int | None = None
    model = UNKNOWN_MODEL
    model_seen = False
    usage: dict[int, Usage] = {}
    for line in lines:
        try:
            decoded: object = json.loads(line)
        except json.JSONDecodeError:
            skipped.bad_lines += 1
            continue
        top = as_object(decoded)
        event = as_object((top or {}).get("event"))
        if top is None or event is None:
            skipped.bad_lines += 1
            continue
        stamp = as_number(top.get("ts"))
        if stamp is not None:
            ended = stamp
        kind = event.get("type")
        if kind == "run_started" and started is None:
            match = RUN_ID.match(str(event.get("run_id")))
            if match is not None and stamp is not None:
                trace, number, started = match.group("trace"), int(match.group("turn")), stamp
        elif kind == "agent_core_stream_message_start" and not model_seen:
            name = event.get("model")
            model, model_seen = (name if isinstance(name, str) else UNKNOWN_MODEL), True
        elif kind == "agent_core_stream_message_delta":
            fields = as_object(event.get("usage"))
            scope = as_int(event.get("stream_scope"))
            read, total = (as_int((fields or {}).get(key)) for key in ("cache_read_input_tokens", "input_tokens"))
            if fields is not None and scope is not None and total is not None:
                usage[scope] = Usage(total, read or 0)
    if started is None or ended is None or trace is None or number is None:
        return None
    if not usage:
        skipped.no_usage += 1
        return None
    return Turn(keeper, trace, number, started, ended, model, tuple(usage[scope] for scope in sorted(usage)))


def turn_files(base_path: pathlib.Path, since: float | None, skipped: Skipped) -> Iterator[tuple[str, pathlib.Path]]:
    root = base_path / ".masc" / "keeper_turn_events"
    if not root.is_dir():
        return
    for folder in sorted(root.iterdir()):
        for path in sorted(folder.glob("*.jsonl")):
            try:
                modified = path.stat().st_mtime
            except FileNotFoundError:
                skipped.vanished_files += 1
                continue
            if since is None or modified >= since:
                yield folder.name, path


def load(base_path: pathlib.Path, since: float | None, skipped: Skipped) -> list[Turn]:
    turns: list[Turn] = []
    for keeper, path in turn_files(base_path, since, skipped):
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except FileNotFoundError:
            skipped.vanished_files += 1
            continue
        turn = parse_turn(keeper, lines, skipped)
        if turn is not None:
            turns.append(turn)
    return turns


def gaps(turns: Sequence[Turn]) -> dict[tuple[str, str, int], float]:
    """Seconds from the end of the turn before to the start of each turn that has one."""
    by_turn = {(turn.keeper, turn.trace, turn.number): turn for turn in turns}
    return {
        key: turn.started - before.ended
        for key, turn in by_turn.items()
        if (before := by_turn.get((key[0], key[1], key[2] - 1))) is not None
    }


def gap_label(seconds: float | None) -> str:
    if seconds is None:
        return GAP_UNKNOWN
    return next((label for edge, label in GAP_EDGES if seconds < edge), GAP_LAST)


def quantile(sorted_values: Sequence[float], q: float) -> float:
    if not sorted_values:
        return 0.0
    return sorted_values[max(0, math.ceil(q * len(sorted_values)) - 1)]


def share(part: float, whole: float) -> float:
    return round(part / whole, 4) if whole > 0 else 0.0


def first_hits(turns: Sequence[Turn]) -> dict[str, object]:
    firsts = [turn.usages[0] for turn in turns]
    total = sum(item.input_tokens for item in firsts)
    ratios = sorted(item.cache_read_tokens / item.input_tokens for item in firsts if item.input_tokens > 0)
    return {
        "turns": len(turns),
        "hit_share_of_tokens": share(sum(item.cache_read_tokens for item in firsts), total),
        "median_hit": round(quantile(ratios, 0.5), 4),
        "share_of_turns_below_half": share(sum(1 for ratio in ratios if ratio < 0.5), len(ratios)),
    }


def requests_per_turn(turns: Sequence[Turn]) -> dict[str, float]:
    counts = sorted(float(len(turn.usages)) for turn in turns)
    return {
        "mean": round(sum(counts) / len(counts), 2) if counts else 0.0,
        "median": quantile(counts, 0.5),
        "p90": quantile(counts, 0.9),
    }


def by_gap(turns: Sequence[Turn], seconds: dict[tuple[str, str, int], float]) -> list[dict[str, object]]:
    buckets: dict[str, list[Turn]] = defaultdict(list)
    for turn in turns:
        buckets[gap_label(seconds.get((turn.keeper, turn.trace, turn.number)))].append(turn)
    return [{"gap": label, **first_hits(buckets[label])} for label in GAP_ORDER if buckets[label]]


def report(turns: Sequence[Turn], skipped: Skipped, since: float | None, until: float | None, top: int) -> dict[str, object]:
    seconds = gaps(turns)
    window = [turn for turn in turns if (since is None or turn.started >= since) and (until is None or turn.started < until)]
    skipped.outside_window += len(turns) - len(window)
    models: dict[str, list[Turn]] = defaultdict(list)
    for turn in window:
        models[turn.model].append(turn)
    ranked = sorted(models.items(), key=lambda item: -len(item[1]))[:top]
    return {
        "params": {"since": since, "until": until},
        "turns": {"counted": len(window), **dataclasses.asdict(skipped)},
        "requests_per_turn": requests_per_turn(window),
        "first_request": first_hits(window),
        "first_request_by_gap": by_gap(window, seconds),
        "by_model": [
            {
                "model": name,
                "requests_per_turn": requests_per_turn(items),
                "first_request": first_hits(items),
                "first_request_by_gap": by_gap(items, seconds),
            }
            for name, items in ranked
        ],
    }


def parse_instant(text: str) -> float:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=datetime.timezone.utc).timestamp()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", help="count turns started at or after this UTC time, YYYY-MM-DDTHH:MM:SS")
    parser.add_argument("--until", help="count turns started before this UTC time")
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    instants: dict[str, float | None] = {}
    for name in ("since", "until"):
        text = cast("str | None", getattr(args, name))
        try:
            instants[name] = None if text is None else parse_instant(text)
        except ValueError:
            parser.error(f"not a YYYY-MM-DDTHH:MM:SS time: {text}")
    skipped = Skipped()
    turns = load(args.base_path.expanduser(), instants["since"], skipped)
    result = report(turns, skipped, instants["since"], instants["until"], args.top)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out is not None:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
