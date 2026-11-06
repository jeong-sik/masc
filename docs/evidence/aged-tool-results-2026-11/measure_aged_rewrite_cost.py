#!/usr/bin/env python3
"""Replay what replacing aged tool results at the next turn's start costs a prefix cache.

`measure_aged_tool_results.py` counts the bytes a marker would remove. A provider that
caches by request prefix has to read again everything after the first message that
changed. This script counts those bytes for the rule "a tool result becomes a marker when
the turn that made it ends", and for the stored requests of one window.

Reads `<base-path>/.masc/keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl` and never
writes to it. A row is one captured request (one per turn). The fields used:

- `trace_id`, `captured_at`, `absolute_turn`: which session the request belongs to and
  its order in it.
- `system_prompt.bytes` and `tool_schemas[].artifact.bytes`: the non-message part of the
  prompt.
- `messages[]`: `index`, `role`, `artifact.bytes`, `artifact.content_ref` (`sha256=` names
  the content) and `media`.

Definitions:

- prompt bytes: the message sizes, the system prompt and the tool schemas. Image bytes
  are not in it.
- predecessor: the stored request of the same keeper and `trace_id` just before this one,
  ordered by `captured_at`, then `absolute_turn`. A request without one is `cold`.
- current turn: the messages from the last `user` message on. A request with fewer than
  two `user` messages has no previous turn and is counted in `no_boundary`.
- aged result: a `role == "tool"` message without media before the current turn, whose
  size is at least the threshold and larger than the marker.
- saved bytes: for every aged result, its size minus the marker size.
- fresh result: an aged result that no earlier stored request of the trace had as aged.
  A result is named by its digest and by how many equal digests came before it in the
  request, so a repeated identical result is a new result. Requests before `--since`
  still count as earlier requests, so load the day before `--since` too.
- rewrite bytes: in a request with a predecessor and at least one fresh result, the
  bytes from the first fresh result up to the current turn, a replaced result at marker
  size. This is what a provider reads again because the first fresh result changed. The
  current turn is new in any case and is not counted.

The rewrite bytes are an upper estimate: they assume the provider still holds the whole
history before the current turn. A cache that expired holds nothing and reads all of it
whatever the request looks like.

This is a size replay of one stored request per turn, in bytes, not tokens. A turn sends
several requests and the stored one is not necessarily the first. It says nothing about
how often a model reads a marker back.

With `--requests-per-turn K` (repeatable) the report adds one price block per K. A cache
read costs the fraction `c` of an uncached read. Per turn, the markers save
`K * c * saved_share` of one prompt (every request of the turn reads a smaller cached
prefix) and the rewrite costs `(1 - c) * rewrite_share`. `break_even_cache_price` is the
`c` where both are equal. `net_per_turn_in_prompts` is saving minus cost, in units of one
prompt read uncached.

Usage:
    python3 docs/evidence/aged-tool-results-2026-11/measure_aged_rewrite_cost.py \
        --base-path ~/me --from-date 2026-11-04 --to-date 2026-11-06 \
        --since 2026-11-05T03:00:00 --until 2026-11-06T03:00:00 --json-out result.json
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
from collections.abc import Iterator, Sequence
from typing import cast

DAY_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}")
SHA_PATTERN = re.compile(r"sha256=([0-9a-f]{64})")
DEFAULT_MARKER_BYTES = 596
DEFAULT_THRESHOLD = 2048
DEFAULT_TOP = 8
QUANTILES = (("p50", 0.5), ("p90", 0.9), ("p99", 0.99))
PRICES = (0.1, 0.25, 0.5)

Key = tuple[str, int]


@dataclasses.dataclass(frozen=True, slots=True)
class Message:
    role: str
    size: int
    sha: str | None
    has_media: bool


@dataclasses.dataclass(frozen=True, slots=True)
class Stored:
    keeper: str
    trace: str | None
    captured_at: float
    turn: int
    fixed_bytes: int
    messages: tuple[Message, ...]


@dataclasses.dataclass(frozen=True, slots=True)
class Params:
    threshold: int
    marker_bytes: int
    since: float | None
    until: float | None


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0
    bad_message_entries: int = 0
    no_boundary: int = 0
    outside_window: int = 0


@dataclasses.dataclass(slots=True)
class KeeperTally:
    prompt_bytes: int = 0
    saved_bytes: int = 0
    rewrite_bytes: int = 0


@dataclasses.dataclass(slots=True)
class Tally:
    requests: int = 0
    cold: int = 0
    prompt_bytes: int = 0
    saved_bytes: int = 0
    rewrite_bytes: int = 0
    with_rewrite: int = 0
    unkeyed_aged: int = 0
    rewrite_shares: list[float] = dataclasses.field(default_factory=list[float])
    keepers: dict[str, KeeperTally] = dataclasses.field(default_factory=dict[str, KeeperTally])


def as_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_object(value: object) -> dict[str, object] | None:
    return cast(dict[str, object], value) if isinstance(value, dict) else None


def sha_of(value: object) -> str | None:
    match = SHA_PATTERN.search(value) if isinstance(value, str) else None
    return match.group(1) if match else None


def parse_message(position: int, entry: object) -> tuple[int, Message] | None:
    fields = as_object(entry)
    if fields is None:
        return None
    role = fields.get("role")
    artifact = as_object(fields.get("artifact")) or {}
    size = as_int(artifact.get("bytes"))
    if not isinstance(role, str) or size is None:
        return None
    index = as_int(fields.get("index"))
    media = fields.get("media")
    has_media = isinstance(media, list) and len(cast(list[object], media)) > 0
    return (position if index is None else index), Message(role, size, sha_of(artifact.get("content_ref")), has_media)


def parse_stored(keeper: str, row: dict[str, object], skipped: Skipped) -> Stored | None:
    raw = row.get("messages")
    captured = row.get("captured_at")
    if not isinstance(raw, list) or isinstance(captured, bool) or not isinstance(captured, (int, float)):
        return None
    parsed = [parse_message(position, entry) for position, entry in enumerate(cast(list[object], raw))]
    skipped.bad_message_entries += sum(1 for entry in parsed if entry is None)
    placed = sorted((entry for entry in parsed if entry is not None), key=lambda entry: entry[0])
    fixed = as_int((as_object(row.get("system_prompt")) or {}).get("bytes")) or 0
    schemas = row.get("tool_schemas")
    if isinstance(schemas, list):
        for schema in cast(list[object], schemas):
            fixed += as_int((as_object((as_object(schema) or {}).get("artifact")) or {}).get("bytes")) or 0
    trace = row.get("trace_id")
    return Stored(
        keeper=keeper,
        trace=trace if isinstance(trace, str) else None,
        captured_at=float(captured),
        turn=as_int(row.get("absolute_turn")) or 0,
        fixed_bytes=fixed,
        messages=tuple(message for _, message in placed),
    )


def result_keys(messages: Sequence[Message]) -> list[Key | None]:
    """A message named by its digest and by how many equal digests came before it."""
    seen: dict[str, int] = {}
    keys: list[Key | None] = []
    for message in messages:
        if message.sha is None:
            keys.append(None)
            continue
        count = seen.get(message.sha, 0)
        seen[message.sha] = count + 1
        keys.append((message.sha, count))
    return keys


def turn_start(messages: Sequence[Message]) -> int | None:
    """Index of the last user message, or None when there is no earlier turn."""
    users = [position for position, message in enumerate(messages) if message.role == "user"]
    return users[-1] if len(users) >= 2 else None


def aged_results(messages: Sequence[Message], start: int, params: Params) -> list[int]:
    return [
        position
        for position, message in enumerate(messages)
        if position < start
        and message.role == "tool"
        and not message.has_media
        and message.size >= params.threshold
        and message.size > params.marker_bytes
    ]


def rewrite_bytes(messages: Sequence[Message], aged: Sequence[int], first: int, start: int, marker_bytes: int) -> int:
    """Bytes from `first` up to `start` with the aged results at marker size."""
    replaced = set(aged)
    return sum(marker_bytes if position in replaced else messages[position].size for position in range(first, start))


def observe(
    tally: Tally,
    seen: set[Key],
    has_predecessor: bool,
    current: Stored,
    params: Params,
    counted: bool,
    skipped: Skipped,
) -> None:
    """Add what `current` ages to `seen`; count the request in `tally` when it is in the window."""
    messages = current.messages
    start = turn_start(messages)
    if start is None:
        if counted:
            skipped.no_boundary += 1
        return
    aged = aged_results(messages, start, params)
    keys = result_keys(messages)
    fresh = [position for position in aged if (key := keys[position]) is not None and key not in seen]
    seen.update(key for position in aged if (key := keys[position]) is not None)
    if not counted:
        return
    prompt = sum(message.size for message in messages) + current.fixed_bytes
    saved = sum(messages[position].size - params.marker_bytes for position in aged)
    rewrite = (
        rewrite_bytes(messages, aged, min(fresh), start, params.marker_bytes) if has_predecessor and fresh else 0
    )
    tally.requests += 1
    tally.prompt_bytes += prompt
    tally.saved_bytes += saved
    tally.rewrite_bytes += rewrite
    tally.unkeyed_aged += sum(1 for position in aged if keys[position] is None)
    if has_predecessor:
        tally.rewrite_shares.append(rewrite / prompt if prompt > 0 else 0.0)
        tally.with_rewrite += 1 if rewrite > 0 else 0
    else:
        tally.cold += 1
    keeper = tally.keepers.setdefault(current.keeper, KeeperTally())
    keeper.prompt_bytes += prompt
    keeper.saved_bytes += saved
    keeper.rewrite_bytes += rewrite


def day_files(base_path: pathlib.Path, from_date: str, to_date: str) -> Iterator[tuple[str, pathlib.Path]]:
    for path in sorted((base_path / ".masc" / "keepers").glob("*/provider-inputs/*/*.jsonl")):
        day = f"{path.parent.name}-{path.stem}"
        if DAY_PATTERN.fullmatch(day) and from_date <= day <= to_date:
            yield path.parent.parent.parent.name, path


def load(
    base_path: pathlib.Path, from_date: str, to_date: str, excluded: Sequence[str], skipped: Skipped
) -> list[Stored]:
    stored: list[Stored] = []
    for keeper, path in day_files(base_path, from_date, to_date):
        if keeper in excluded:
            continue
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    decoded: object = json.loads(line)
                except json.JSONDecodeError:
                    skipped.bad_lines += 1
                    continue
                row = as_object(decoded)
                request = parse_stored(keeper, row, skipped) if row is not None else None
                if request is None:
                    skipped.bad_lines += 1
                    continue
                stored.append(request)
    return stored


def in_window(request: Stored, params: Params) -> bool:
    return (params.since is None or request.captured_at >= params.since) and (
        params.until is None or request.captured_at < params.until
    )


def replay(stored: Sequence[Stored], params: Params, skipped: Skipped) -> Tally:
    """Walk each keeper and trace in order. A request outside the window only ages results."""
    tally = Tally()
    groups: dict[tuple[str, str], list[Stored]] = {}
    alone: list[Stored] = []
    for request in stored:
        if request.trace is None:
            alone.append(request)
        else:
            groups.setdefault((request.keeper, request.trace), []).append(request)
    ordered = [sorted(group, key=lambda item: (item.captured_at, item.turn)) for group in groups.values()]
    ordered.extend([request] for request in alone)
    for group in ordered:
        seen: set[Key] = set()
        for position, request in enumerate(group):
            counted = in_window(request, params)
            if not counted:
                skipped.outside_window += 1
            observe(tally, seen, position > 0, request, params, counted, skipped)
    return tally


def quantile(sorted_values: Sequence[float], q: float) -> float:
    if not sorted_values:
        return 0.0
    return sorted_values[max(0, math.ceil(q * len(sorted_values)) - 1)]


def share(part: float, whole: float) -> float:
    return round(part / whole, 4) if whole > 0 else 0.0


def price_block(saved_share: float, rewrite_share: float, requests_per_turn: float) -> dict[str, object]:
    gain = requests_per_turn * saved_share
    return {
        "requests_per_turn": requests_per_turn,
        "break_even_cache_price": round(rewrite_share / (gain + rewrite_share), 4) if gain + rewrite_share > 0 else 0.0,
        "net_per_turn_in_prompts": {
            str(price): round(price * gain - (1 - price) * rewrite_share, 4) for price in PRICES
        },
    }


def report(
    tally: Tally, skipped: Skipped, params: Params, top: int, requests_per_turn: Sequence[float]
) -> dict[str, object]:
    prompt = tally.prompt_bytes
    warm = len(tally.rewrite_shares)
    ordered = sorted(tally.rewrite_shares)
    keepers = sorted(tally.keepers.items(), key=lambda item: -item[1].prompt_bytes)[:top]
    result: dict[str, object] = {
        "params": {
            "threshold": params.threshold,
            "marker_bytes": params.marker_bytes,
            "since": params.since,
            "until": params.until,
        },
        "requests": {"counted": tally.requests, "cold": tally.cold, **dataclasses.asdict(skipped)},
        "prompt_bytes": prompt,
        "saved": {"bytes": tally.saved_bytes, "share_of_prompt": share(tally.saved_bytes, prompt)},
        "rewrite": {
            "bytes": tally.rewrite_bytes,
            "share_of_prompt": share(tally.rewrite_bytes, prompt),
            "requests_with_rewrite": tally.with_rewrite,
            "share_of_requests_with_predecessor": share(tally.with_rewrite, warm),
            "per_request_share": {
                **{name: round(quantile(ordered, q), 4) for name, q in QUANTILES},
                "max": round(ordered[-1], 4) if ordered else 0.0,
            },
        },
        "aged_results_without_digest": tally.unkeyed_aged,
        "by_keeper": [
            {
                "keeper": name,
                "prompt_bytes": keeper.prompt_bytes,
                "saved_share": share(keeper.saved_bytes, keeper.prompt_bytes),
                "rewrite_share": share(keeper.rewrite_bytes, keeper.prompt_bytes),
            }
            for name, keeper in keepers
        ],
    }
    if requests_per_turn:
        saved_share = tally.saved_bytes / prompt if prompt > 0 else 0.0
        rewrite_share = tally.rewrite_bytes / prompt if prompt > 0 else 0.0
        result["price"] = [price_block(saved_share, rewrite_share, count) for count in requests_per_turn]
    return result


def parse_instant(text: str) -> float:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=datetime.timezone.utc).timestamp()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", required=True, help="first UTC day of the files, YYYY-MM-DD")
    parser.add_argument("--to-date", required=True, help="last UTC day of the files, YYYY-MM-DD")
    parser.add_argument("--since", help="count requests captured at or after this UTC time, YYYY-MM-DDTHH:MM:SS")
    parser.add_argument("--until", help="count requests captured before this UTC time")
    parser.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD)
    parser.add_argument("--marker-bytes", type=int, default=DEFAULT_MARKER_BYTES)
    parser.add_argument("--exclude-keeper", action="append", default=[])
    parser.add_argument("--requests-per-turn", type=float, action="append", default=[], help="adds a price block")
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    for day in (args.from_date, args.to_date):
        try:
            datetime.date.fromisoformat(day)
        except ValueError:
            parser.error(f"not a YYYY-MM-DD day: {day}")
    instants: dict[str, float | None] = {}
    for name in ("since", "until"):
        text = cast("str | None", getattr(args, name))
        try:
            instants[name] = None if text is None else parse_instant(text)
        except ValueError:
            parser.error(f"not a YYYY-MM-DDTHH:MM:SS time: {text}")
    if any(count <= 0 for count in args.requests_per_turn):
        parser.error("--requests-per-turn must be positive")
    params = Params(args.threshold, args.marker_bytes, instants["since"], instants["until"])
    skipped = Skipped()
    stored = load(args.base_path.expanduser(), args.from_date, args.to_date, args.exclude_keeper, skipped)
    result = report(replay(stored, params, skipped), skipped, params, args.top, args.requests_per_turn)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out is not None:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
