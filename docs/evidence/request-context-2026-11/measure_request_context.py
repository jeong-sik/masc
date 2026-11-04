#!/usr/bin/env python3
"""Measure how much context each Keeper's model requests carry.

Reads two stores under `<base-path>/.masc`, never writes to them:

- `keeper_turn_events/<keeper>/<trace_id>-<absolute_turn>-<hash>.jsonl`: one turn
  trace per file. An `agent_core_stream_message_delta` event with a `usage`
  object closes one model request. `input_tokens` is the whole prompt, and
  `cache_read_input_tokens` is the part of it the provider served from its cache.
- `keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl`: one capture per turn
  (`trace_id`, `absolute_turn`) of a request the turn sent. `wire.body_bytes` is
  the size of the HTTP body. Every message lists its `media`. Other requests of
  the same turn are not captured, so the sizes describe the captured requests
  only.

Definitions:

- model request: one `usage` event in the window (`--from-date` midnight UTC to
  `--until`).
- answered turn: a turn whose trace holds at least one `usage` event. A captured
  request is unanswered when its turn has a trace and no `usage` event, and
  untraced when no trace file carries its (`trace_id`, `absolute_turn`).
- stale image: an image of a captured request that is not one of its latest N
  images, counted in message order. The what-if columns are the base64 size of
  the stale images over the body bytes, pooled over all requests of the Keeper
  and as the median of the per-request shares. It is not a measurement of a
  policy that exists: no code drops images from the history today.
- same-size requests: the largest number of captured requests of one Keeper that
  share one `body_bytes` value, and that value.

Nothing here reads message text or image bytes.

Usage:
    docs/evidence/request-context-2026-11/measure_request_context.py --base-path ~/me \
        --from-date 2026-11-01 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

import masc_base_path  # noqa: E402

USAGE_EVENT = "agent_core_stream_message_delta"
USAGE_MARKER = b'"usage"'
IMAGE_MEDIA_PREFIX = "image/"
KEEP_LATEST_IMAGES = (1, 3)
TOP_BODY_KEEPERS = 8
BASE64_GROUP_BYTES = 3
BASE64_GROUP_CHARS = 4
TRACE_NAME_PARTS = 3
MEDIAN = 0.5
P90 = 0.9
P99 = 0.99

ANSWERED = "answered"
UNANSWERED = "unanswered"
UNTRACED = "untraced"

TurnKey = tuple[str, int]
KeeperTurn = tuple[str, TurnKey]


@dataclass(frozen=True, slots=True)
class Usage:
    keeper: str
    input_tokens: int
    cache_read_tokens: int
    output_tokens: int


@dataclass(frozen=True, slots=True)
class TraceReading:
    usages: list[Usage]
    traced: frozenset[KeeperTurn]
    answered: frozenset[KeeperTurn]


@dataclass(frozen=True, slots=True)
class RequestBody:
    keeper: str
    body_bytes: int
    image_bytes: tuple[int, ...]
    turn: TurnKey | None


def number_of(value: object) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def count_of(value: object) -> int:
    number = number_of(value)
    return int(number) if number is not None else 0


def base64_chars(raw_bytes: int) -> int:
    """Characters of the base64 text for `raw_bytes` bytes (padded)."""
    groups = -(-raw_bytes // BASE64_GROUP_BYTES)
    return groups * BASE64_GROUP_CHARS


def stale_image_chars(image_bytes: tuple[int, ...], keep_latest: int) -> int:
    stale = image_bytes[: max(len(image_bytes) - keep_latest, 0)]
    return sum(base64_chars(size) for size in stale)


def turn_key_of(path: pathlib.Path) -> TurnKey | None:
    """`<trace_id>-<absolute_turn>-<hash>.jsonl` -> (trace_id, absolute_turn).

    The trace id itself contains hyphens, so the name is split from the right.
    """
    parts = path.stem.rsplit("-", TRACE_NAME_PARTS - 1)
    if len(parts) != TRACE_NAME_PARTS or not parts[1].isdigit():
        return None
    return parts[0], int(parts[1])


def parse_usage_event(line: bytes) -> tuple[float, int, int, int] | None:
    """(ts, input tokens, cache read tokens, output tokens) of a usage event, or None for any other line."""
    try:
        row = json.loads(line)
    except ValueError:
        return None
    if not isinstance(row, dict):
        return None
    event = row.get("event")
    ts = number_of(row.get("ts"))
    usage = event.get("usage") if isinstance(event, dict) else None
    if not isinstance(event, dict) or event.get("type") != USAGE_EVENT or not isinstance(usage, dict) or ts is None:
        return None
    return (
        ts,
        count_of(usage.get("input_tokens")),
        count_of(usage.get("cache_read_input_tokens")),
        count_of(usage.get("output_tokens")),
    )


def read_traces(base: pathlib.Path, since: float, until: float) -> TraceReading:
    usages: list[Usage] = []
    traced: set[KeeperTurn] = set()
    answered: set[KeeperTurn] = set()
    root = base / ".masc" / "keeper_turn_events"
    if not root.is_dir():
        return TraceReading(usages, frozenset(), frozenset())
    for keeper_dir in sorted(root.iterdir()):
        if not keeper_dir.is_dir():
            continue
        for path in sorted(keeper_dir.glob("*.jsonl")):
            try:
                if path.stat().st_mtime < since:
                    continue
            except OSError:
                continue
            turn = turn_key_of(path)
            if turn is not None:
                traced.add((keeper_dir.name, turn))
            with path.open("rb") as handle:
                for line in handle:
                    if USAGE_MARKER not in line:
                        continue
                    parsed = parse_usage_event(line)
                    if parsed is None:
                        continue
                    ts, input_tokens, cache_read_tokens, output_tokens = parsed
                    if turn is not None:
                        answered.add((keeper_dir.name, turn))
                    if since <= ts <= until:
                        usages.append(Usage(keeper_dir.name, input_tokens, cache_read_tokens, output_tokens))
    return TraceReading(usages, frozenset(traced), frozenset(answered))


def image_sizes(messages: object) -> tuple[int, ...]:
    sizes: list[int] = []
    if not isinstance(messages, list):
        return ()
    for message in messages:
        media = message.get("media") if isinstance(message, dict) else None
        for item in media if isinstance(media, list) else []:
            if isinstance(item, dict) and str(item.get("media_type", "")).startswith(IMAGE_MEDIA_PREFIX):
                sizes.append(count_of(item.get("bytes")))
    return tuple(sizes)


def capture_turn(row: dict[str, object]) -> TurnKey | None:
    trace_id = row.get("trace_id")
    turn = row.get("absolute_turn")
    if isinstance(trace_id, str) and isinstance(turn, int) and not isinstance(turn, bool):
        return trace_id, turn
    return None


def read_request_bodies(base: pathlib.Path, first: date, last: date, since: float, until: float) -> list[RequestBody]:
    bodies: list[RequestBody] = []
    keepers = base / ".masc" / "keepers"
    if not keepers.is_dir():
        return bodies
    for keeper_dir in sorted(keepers.iterdir()):
        day = first
        while day <= last:
            path = keeper_dir / "provider-inputs" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
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
                    wire = row.get("wire")
                    captured = number_of(row.get("captured_at"))
                    body = number_of(wire.get("body_bytes")) if isinstance(wire, dict) else None
                    if captured is None or body is None or not since <= captured <= until:
                        continue
                    bodies.append(
                        RequestBody(keeper_dir.name, int(body), image_sizes(row.get("messages")), capture_turn(row))
                    )
    return bodies


def quantile(ordered: list[float], fraction: float) -> float:
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def answer_state(body: RequestBody, traces: TraceReading) -> str:
    key = None if body.turn is None else (body.keeper, body.turn)
    if key is None or key not in traces.traced:
        return UNTRACED
    return ANSWERED if key in traces.answered else UNANSWERED


def summarize_usage(usages: list[Usage]) -> dict[str, object]:
    per_keeper: dict[str, list[Usage]] = defaultdict(list)
    for usage in usages:
        per_keeper[usage.keeper].append(usage)
    total_input = sum(usage.input_tokens for usage in usages)
    rows = []
    for keeper, items in per_keeper.items():
        keeper_input = sum(item.input_tokens for item in items)
        rows.append(
            {
                "keeper": keeper,
                "requests": len(items),
                "input_tokens": keeper_input,
                "cache_read_tokens": sum(item.cache_read_tokens for item in items),
                "output_tokens": sum(item.output_tokens for item in items),
                "mean_input_tokens": round(keeper_input / len(items)),
            }
        )
    rows.sort(key=lambda row: (-int(row["input_tokens"]), str(row["keeper"])))  # type: ignore[call-overload]
    return {
        "keepers": len(per_keeper),
        "requests": len(usages),
        "input_tokens": total_input,
        "cache_read_tokens": sum(usage.cache_read_tokens for usage in usages),
        "output_tokens": sum(usage.output_tokens for usage in usages),
        "mean_input_tokens": round(total_input / len(usages)) if usages else 0,
        "by_keeper": rows,
    }


def same_size_requests(items: list[RequestBody]) -> tuple[int, int]:
    """(how many requests share the most common body size, that size). Ties go to the larger size."""
    sizes = Counter(item.body_bytes for item in items)
    size, count = max(sizes.items(), key=lambda entry: (entry[1], entry[0]))
    return count, size


def stale_share(body: RequestBody, keep_latest: int) -> float:
    return stale_image_chars(body.image_bytes, keep_latest) / body.body_bytes if body.body_bytes else 0.0


def keeper_body_row(keeper: str, items: list[RequestBody], traces: TraceReading) -> dict[str, object]:
    sizes = sorted(float(item.body_bytes) for item in items)
    counts = sorted(float(len(item.image_bytes)) for item in items)
    total = sum(item.body_bytes for item in items)
    states = [(item, answer_state(item, traces)) for item in items]
    same_count, same_size = same_size_requests(items)
    row: dict[str, object] = {
        "keeper": keeper,
        "requests": len(items),
        "body_bytes_sum": total,
        "body_bytes_mean": round(statistics.fmean(sizes)),
        "body_bytes_p50": round(quantile(sizes, MEDIAN)),
        "body_bytes_p90": round(quantile(sizes, P90)),
        "body_bytes_max": round(sizes[-1]),
        "images_mean": round(statistics.fmean(counts), 1),
        "images_p50": round(quantile(counts, MEDIAN)),
        "images_max": round(counts[-1]),
        "same_size_requests_max": same_count,
        "same_size_bytes": same_size,
        "unanswered_requests": sum(1 for _, state in states if state == UNANSWERED),
        "unanswered_body_bytes": sum(item.body_bytes for item, state in states if state == UNANSWERED),
        "untraced_requests": sum(1 for _, state in states if state == UNTRACED),
    }
    for keep in KEEP_LATEST_IMAGES:
        stale = sum(stale_image_chars(item.image_bytes, keep) for item in items)
        shares = sorted(stale_share(item, keep) for item in items)
        row[f"stale_image_share_keep_latest_{keep}"] = round(stale / total, 3) if total else 0.0
        row[f"stale_image_share_median_keep_latest_{keep}"] = round(quantile(shares, MEDIAN), 3)
    return row


def summarize_bodies(bodies: list[RequestBody], traces: TraceReading) -> dict[str, object]:
    per_keeper: dict[str, list[RequestBody]] = defaultdict(list)
    for body in bodies:
        per_keeper[body.keeper].append(body)
    rows = [keeper_body_row(keeper, items, traces) for keeper, items in per_keeper.items()]
    rows.sort(key=lambda row: (-int(row["body_bytes_sum"]), str(row["keeper"])))  # type: ignore[call-overload]
    all_sizes = sorted(float(body.body_bytes) for body in bodies)
    states = [(body, answer_state(body, traces)) for body in bodies]
    return {
        "keepers": len(per_keeper),
        "requests": len(bodies),
        "body_bytes_sum": sum(body.body_bytes for body in bodies),
        "body_bytes_p50": round(quantile(all_sizes, MEDIAN)) if all_sizes else 0,
        "body_bytes_p99": round(quantile(all_sizes, P99)) if all_sizes else 0,
        "body_bytes_max": round(all_sizes[-1]) if all_sizes else 0,
        "unanswered_requests": sum(1 for _, state in states if state == UNANSWERED),
        "unanswered_body_bytes": sum(body.body_bytes for body, state in states if state == UNANSWERED),
        "untraced_requests": sum(1 for _, state in states if state == UNTRACED),
        "by_keeper": rows[:TOP_BODY_KEEPERS],
    }


def parse_day(text: str) -> date:
    return date.fromisoformat(text)


def parse_until(text: str) -> float:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--until", type=parse_until, required=True, help="ignore anything after this ISO-8601 time")
    parser.add_argument("--json-out", default=None, help="write the summary to this file")
    args = parser.parse_args()
    base = masc_base_path.require(parser, args.base_path, "--base-path")

    since = datetime(args.from_date.year, args.from_date.month, args.from_date.day, tzinfo=timezone.utc).timestamp()
    traces = read_traces(base, since, args.until)
    summary = {
        "window": {
            "from": args.from_date.isoformat(),
            "to": args.to_date.isoformat(),
            "until": datetime.fromtimestamp(args.until, timezone.utc).isoformat(),
        },
        "model_requests": summarize_usage(traces.usages),
        "captured_request_bodies": summarize_bodies(
            read_request_bodies(base, args.from_date, args.to_date, since, args.until), traces
        ),
    }
    text = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)
    print(text)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
