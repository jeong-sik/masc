#!/usr/bin/env python3
"""Replay one rule on stored requests: tool results older than the current turn become markers.

Reads `<base-path>/.masc/keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl` and never
writes to it. A row is one captured request. The fields used:

- `messages[]`: `role`, `artifact.bytes` (the stored size of the message) and `media`
  (the images the message carries).
- `system_prompt.bytes` and `tool_schemas[].artifact.bytes`.

Definitions:

- prompt bytes: the sum of the message sizes, the system prompt and the tool schemas.
  Image bytes are not in it, so a request that carries images is smaller here than its
  `wire.body_bytes`.
- turn boundary: a `role == "user"` message. The current turn starts at the last one
  and the previous turn at the one before it. A request with fewer than two user
  messages has no previous turn and is counted in `no_boundary`.
- aged result: a `role == "tool"` message without media before the cut. The rule
  `before_current_turn` cuts at the current turn and `before_previous_turn` at the
  previous one.
- marker: what an aged result would be replaced by. A message of N bytes saves
  `N - marker_bytes` when N is at least the threshold and larger than the marker. The
  default marker size is the average stored size of the stubs that stored requests
  already carry (`docs/evidence/tool-result-carry-2026-11`).
- exposed bytes: the bytes at and after the cut. When the cut moves forward at the
  next turn, the first aged result changes, and a provider that caches by prefix has
  to read everything after it again. This is the most that move can re-send.

A message without an integer `artifact.bytes` is skipped and counted in
`bad_message_entries`. Rows that are not JSON objects are counted in `bad_lines`.

This is a size replay. It does not say how often a model reads a marker back, and it
counts bytes, not tokens.

Usage:
    python3 docs/evidence/aged-tool-results-2026-11/measure_aged_tool_results.py \
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
from collections.abc import Iterator, Sequence
from typing import cast

DAY_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}")
DEFAULT_MARKER_BYTES = 596
DEFAULT_THRESHOLDS = (1024, 2048, 4096, 16384)
DEFAULT_HEADLINE = 2048
DEFAULT_TOP = 12
# Upper bounds, exclusive, of the first three prompt size bands. The last band is open.
SIZE_BANDS = (100_000, 1_000_000, 5_000_000)
QUANTILES = (0.25, 0.5, 0.75, 0.9)
RULES = ("before_current_turn", "before_previous_turn")


@dataclasses.dataclass(frozen=True, slots=True)
class Message:
    role: str
    size: int
    has_media: bool


@dataclasses.dataclass(frozen=True, slots=True)
class Request:
    keeper: str
    messages: tuple[Message, ...]
    system_bytes: int
    schema_bytes: int


@dataclasses.dataclass(frozen=True, slots=True)
class CutResult:
    aged_bytes: int
    saved: tuple[int, ...]
    exposed_bytes: int


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0
    bad_message_entries: int = 0
    no_boundary: int = 0


@dataclasses.dataclass(slots=True)
class RuleTally:
    aged_bytes: int = 0
    exposed_bytes: int = 0
    saved: list[int] = dataclasses.field(default_factory=list[int])
    headline_shares: list[float] = dataclasses.field(default_factory=list[float])


@dataclasses.dataclass(slots=True)
class KeeperTally:
    requests: int = 0
    prompt_bytes: int = 0
    saved_headline: int = 0


@dataclasses.dataclass(slots=True)
class BandTally:
    requests: int = 0
    prompt_bytes: int = 0
    saved_headline: int = 0


@dataclasses.dataclass(slots=True)
class Tally:
    requests: int = 0
    prompt_bytes: int = 0
    system_bytes: int = 0
    schema_bytes: int = 0
    role_bytes: dict[str, int] = dataclasses.field(default_factory=dict[str, int])
    media_tool_messages: int = 0
    tool_messages: int = 0
    rules: dict[str, RuleTally] = dataclasses.field(default_factory=dict[str, RuleTally])
    keepers: dict[str, KeeperTally] = dataclasses.field(default_factory=dict[str, KeeperTally])
    bands: list[BandTally] = dataclasses.field(
        default_factory=lambda: [BandTally() for _ in range(len(SIZE_BANDS) + 1)]
    )


def as_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_object(value: object) -> dict[str, object] | None:
    return cast(dict[str, object], value) if isinstance(value, dict) else None


def parse_message(position: int, entry: object) -> tuple[int, Message] | None:
    """The message and where it sits: its `index`, or its place in the row without one."""
    fields = as_object(entry)
    if fields is None:
        return None
    role = fields.get("role")
    size = as_int((as_object(fields.get("artifact")) or {}).get("bytes"))
    media = fields.get("media")
    if not isinstance(role, str) or size is None:
        return None
    index = as_int(fields.get("index"))
    has_media = isinstance(media, list) and len(cast(list[object], media)) > 0
    return (position if index is None else index), Message(role, size, has_media)


def parse_request(keeper: str, row: dict[str, object], skipped: Skipped) -> Request | None:
    raw = row.get("messages")
    if not isinstance(raw, list):
        return None
    parsed = [parse_message(position, entry) for position, entry in enumerate(cast(list[object], raw))]
    skipped.bad_message_entries += sum(1 for entry in parsed if entry is None)
    placed = sorted((entry for entry in parsed if entry is not None), key=lambda entry: entry[0])
    messages = tuple(message for _, message in placed)
    system_bytes = as_int((as_object(row.get("system_prompt")) or {}).get("bytes")) or 0
    schemas = row.get("tool_schemas")
    schema_bytes = 0
    if isinstance(schemas, list):
        for schema in cast(list[object], schemas):
            schema_bytes += as_int((as_object((as_object(schema) or {}).get("artifact")) or {}).get("bytes")) or 0
    return Request(keeper, messages, system_bytes, schema_bytes)


def user_positions(messages: Sequence[Message]) -> list[int]:
    return [position for position, message in enumerate(messages) if message.role == "user"]


def apply_cut(
    messages: Sequence[Message], cut: int, thresholds: Sequence[int], marker_bytes: int
) -> CutResult:
    aged = [
        message.size
        for position, message in enumerate(messages)
        if position < cut and message.role == "tool" and not message.has_media
    ]
    saved = tuple(
        sum(max(0, size - marker_bytes) for size in aged if size >= threshold)
        for threshold in thresholds
    )
    exposed = sum(message.size for message in messages[cut:])
    return CutResult(sum(aged), saved, exposed)


def quantile(sorted_values: Sequence[float], q: float) -> float:
    """Nearest rank: the smallest value with at least a share q of the values at or below it."""
    return sorted_values[max(0, math.ceil(q * len(sorted_values)) - 1)]


def observe(
    tally: Tally,
    request: Request,
    skipped: Skipped,
    thresholds: Sequence[int],
    marker_bytes: int,
    headline_index: int,
) -> None:
    positions = user_positions(request.messages)
    if len(positions) < 2:
        skipped.no_boundary += 1
        return
    message_bytes = sum(message.size for message in request.messages)
    prompt = message_bytes + request.system_bytes + request.schema_bytes
    tally.requests += 1
    tally.prompt_bytes += prompt
    tally.system_bytes += request.system_bytes
    tally.schema_bytes += request.schema_bytes
    for message in request.messages:
        tally.role_bytes[message.role] = tally.role_bytes.get(message.role, 0) + message.size
        if message.role == "tool":
            tally.tool_messages += 1
            tally.media_tool_messages += 1 if message.has_media else 0
    keeper = tally.keepers.setdefault(request.keeper, KeeperTally())
    keeper.requests += 1
    keeper.prompt_bytes += prompt
    band = tally.bands[bisect.bisect_right(SIZE_BANDS, prompt)]
    band.requests += 1
    band.prompt_bytes += prompt
    for rule, cut in zip(RULES, (positions[-1], positions[-2]), strict=True):
        result = apply_cut(request.messages, cut, thresholds, marker_bytes)
        rule_tally = tally.rules.setdefault(rule, RuleTally(saved=[0] * len(thresholds)))
        rule_tally.aged_bytes += result.aged_bytes
        rule_tally.exposed_bytes += result.exposed_bytes
        for index, saved in enumerate(result.saved):
            rule_tally.saved[index] += saved
        rule_tally.headline_shares.append(result.saved[headline_index] / prompt if prompt > 0 else 0.0)
        if rule == RULES[0]:
            keeper.saved_headline += result.saved[headline_index]
            band.saved_headline += result.saved[headline_index]


def day_files(base_path: pathlib.Path, from_date: str, to_date: str) -> Iterator[tuple[str, pathlib.Path]]:
    for path in sorted((base_path / ".masc" / "keepers").glob("*/provider-inputs/*/*.jsonl")):
        day = f"{path.parent.name}-{path.stem}"
        if DAY_PATTERN.fullmatch(day) and from_date <= day <= to_date:
            yield path.parent.parent.parent.name, path


def measure(
    base_path: pathlib.Path,
    from_date: str,
    to_date: str,
    thresholds: Sequence[int],
    marker_bytes: int,
    headline: int,
    excluded: Sequence[str],
) -> tuple[Tally, Skipped]:
    tally, skipped = Tally(), Skipped()
    headline_index = list(thresholds).index(headline)
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
                request = parse_request(keeper, row, skipped) if row is not None else None
                if request is None:
                    skipped.bad_lines += 1
                    continue
                observe(tally, request, skipped, thresholds, marker_bytes, headline_index)
    return tally, skipped


def share(part: int, whole: int) -> float:
    return round(part / whole, 4) if whole > 0 else 0.0


def report(
    tally: Tally, skipped: Skipped, thresholds: Sequence[int], marker_bytes: int, headline: int, top: int
) -> dict[str, object]:
    prompt = tally.prompt_bytes
    rules: dict[str, object] = {}
    for rule in RULES:
        rule_tally = tally.rules.get(rule, RuleTally(saved=[0] * len(thresholds)))
        shares = sorted(rule_tally.headline_shares)
        rules[rule] = {
            "aged_tool_bytes": rule_tally.aged_bytes,
            "aged_tool_share": share(rule_tally.aged_bytes, prompt),
            "exposed_bytes": rule_tally.exposed_bytes,
            "exposed_share": share(rule_tally.exposed_bytes, prompt),
            "saved_bytes_by_threshold": {str(t): s for t, s in zip(thresholds, rule_tally.saved, strict=True)},
            "saved_share_by_threshold": {
                str(t): share(s, prompt) for t, s in zip(thresholds, rule_tally.saved, strict=True)
            },
            "per_request_saved_share_at_headline": {
                f"p{round(q * 100)}": round(quantile(shares, q), 4) for q in QUANTILES
            }
            if shares
            else {},
        }
    keepers = sorted(tally.keepers.items(), key=lambda item: -item[1].prompt_bytes)[:top]
    return {
        "params": {"marker_bytes": marker_bytes, "thresholds": list(thresholds), "headline_threshold": headline},
        "requests": {"counted": tally.requests, **dataclasses.asdict(skipped)},
        "prompt_bytes": prompt,
        "shares_of_prompt": {
            "system_prompt": share(tally.system_bytes, prompt),
            "tool_schemas": share(tally.schema_bytes, prompt),
            **{f"{role}_messages": share(size, prompt) for role, size in sorted(tally.role_bytes.items())},
        },
        "tool_messages": {"count": tally.tool_messages, "with_media": tally.media_tool_messages},
        "rules": rules,
        "by_prompt_size": [
            {
                "prompt_bytes_below": SIZE_BANDS[index] if index < len(SIZE_BANDS) else None,
                "requests": band.requests,
                "prompt_share": share(band.prompt_bytes, prompt),
                "saved_share_of_band": share(band.saved_headline, band.prompt_bytes),
                "saved_share_of_total": share(band.saved_headline, prompt),
            }
            for index, band in enumerate(tally.bands)
        ],
        "by_keeper": [
            {
                "keeper": name,
                "requests": k.requests,
                "prompt_bytes": k.prompt_bytes,
                "saved_share_before_current_turn_at_headline": share(k.saved_headline, k.prompt_bytes),
            }
            for name, k in keepers
        ],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--marker-bytes", type=int, default=DEFAULT_MARKER_BYTES)
    parser.add_argument("--threshold", type=int, action="append", dest="thresholds")
    parser.add_argument("--headline-threshold", type=int, default=DEFAULT_HEADLINE)
    parser.add_argument("--exclude-keeper", action="append", default=[])
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    thresholds = tuple(args.thresholds or DEFAULT_THRESHOLDS)
    for day in (args.from_date, args.to_date):
        try:
            datetime.date.fromisoformat(day)
        except ValueError:
            parser.error(f"not a YYYY-MM-DD day: {day}")
    if args.headline_threshold not in thresholds:
        parser.error("--headline-threshold must be one of the thresholds")
    tally, skipped = measure(
        args.base_path.expanduser(), args.from_date, args.to_date, thresholds,
        args.marker_bytes, args.headline_threshold, args.exclude_keeper,
    )
    result = report(tally, skipped, thresholds, args.marker_bytes, args.headline_threshold, args.top)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out is not None:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
