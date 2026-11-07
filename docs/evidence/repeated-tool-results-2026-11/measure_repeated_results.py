#!/usr/bin/env python3
"""Count the tool results a turn receives again with the same content.

A tool that answers twice with the same text puts that text in the request twice, and
every later request of the turn carries both. This script counts those bytes in two
places. It reads both and never writes to either.

- Stored requests: `<base-path>/.masc/keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl`,
  one captured request per turn, with the message blobs in
  `<base-path>/.masc/tool_blobs/<2 hex>/<sha256>`.
- The tool call ledger: `<base-path>/.masc/tool_calls/YYYY-MM/DD.jsonl` and its
  `DD.NNN.jsonl` segments.

Definitions:

- result: one `tool_result` block. A tool message holds one block per call of a batch, so it can
  hold several. The size of a result is the length of its `content` in UTF-8 bytes.
- turn (stored request): the messages from a `user` message whose blob has
  `origin == "conversation"` up to the next one. The front summary (`agent_instruction`), a
  `recovery_instruction` and the trailing `system_context` message do not start a turn. A user
  message whose blob is missing is taken as a start, which can only move a repeat from the same
  turn to an earlier turn.
- repeated result (stored request): a result of a `role == "tool"` message without media, at
  least `--min-bytes` large, that equals an earlier result of the request. The message blob
  holds the results. The digest in `content_ref` cannot name one, because the blob also holds the
  call ids and two equal answers get two digests. If an equal result is earlier in the same turn,
  the repeat is a same-turn repeat. If it is only in an earlier turn of the request, the repeat
  is an earlier-turn repeat. A request keeps the turns before it, so a result that several stored
  requests of a keeper carry is counted in each of them. That is right for the share of the bytes
  sent and wrong for the number of calls: the ledger view counts a call once.
- equal (`--match`): with `text`, the default, two results are equal when their texts are
  equal. A stub for such a repeat loses nothing the first result did not show. With `answer`,
  they are equal when the ledger rows of their calls have the same `output_fingerprint`, the
  digest of the answer the tool declares, which leaves out a receipt field such as a clock or an
  execution time. That finds repeats whose texts differ in those fields and a stub for them
  hides the fields. A block is joined to its ledger row by keeper, session and its own
  `tool_use_id`. A result without a row is counted in `unmatched_results` and skipped. The
  ledger view always compares fingerprints.
- saved bytes: for every same-turn repeat, its size minus `--stub-bytes`, but not below 0. This
  is what the request would save if the text of the repeat were replaced by a short text that
  points at the first result. The default is the text size of an existing marker, 348 bytes
  being the most common size in the stored requests, so a stub is assumed not to be smaller.
  Earlier-turn repeats are counted apart and save nothing here.
- repeated result (ledger): a row with `record_kind == "tool_call"` and `result_bytes` of at
  least `--min-bytes` whose `output_fingerprint` equals the one of an earlier row with the
  same keeper, `session_id` and `keeper_turn_id`. Rows before `--since` still count as
  earlier rows, so load the day before `--since` too.
- share: bytes of the repeated results over all prompt bytes (stored requests: message sizes,
  system prompt and tool schemas) or over all result bytes (ledger). The result bytes leave
  out the JSON around a result, so the share of the prompt is a little low.

Limits:

- A stored request is one per turn and not necessarily the first of its turn. The request view
  is a size sample of one request, in bytes and not in tokens.
- With `--match answer` a repeat that a stub would shorten no longer shows the model the
  receipt fields of the repeated call. Whether it needs them is not measured.
- The ledger view compares fingerprints, so it can count a pair whose texts differ. The request
  view with `--match text` counts only equal texts.
- The ledger counts a result once however many requests carry it. The request view counts
  what one request carries. Neither multiplies a repeat by the requests that follow it.
- The ledger `result_bytes` of a tool that returns an image includes the image. The
  request view skips a message with media.
- A blob that the blob sweep deleted is counted in `missing_blobs` and its message is not
  compared, so the request view then undercounts.

Usage:
    python3 docs/evidence/repeated-tool-results-2026-11/measure_repeated_results.py \
        --base-path ~/me --from-date 2026-11-06 --to-date 2026-11-07 \
        --since 2026-11-06T09:52:00 --until 2026-11-07T03:00:00 --json-out result.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import hashlib
import json
import math
import pathlib
import re
import sys
from collections.abc import Callable, Iterator, Sequence
from typing import cast

DAY_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}")
SHA_PATTERN = re.compile(r"sha256=([0-9a-f]{64})")
LEDGER_NAME = re.compile(r"(\d{2})(?:\.\d+)?\.jsonl")
TOOL_CALL = "tool_call"
TURN_ORIGIN = "conversation"
DEFAULT_MIN_BYTES = 1024
DEFAULT_STUB_BYTES = 350
DEFAULT_TOP = 8
QUANTILES = (("p50", 0.5), ("p90", 0.9), ("p99", 0.99))
VIEWS = ("requests", "ledger", "both")
MATCHES = ("text", "answer")

UTC = datetime.timezone.utc


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
    fixed_bytes: int
    messages: tuple[Message, ...]


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    ts: float
    tool: str
    size: int
    fingerprint: str


GroupKey = tuple[str, str, int]
CallKey = tuple[str, str, str]


@dataclasses.dataclass(slots=True)
class Ledger:
    groups: dict[GroupKey, list[tuple[str, Call]]] = dataclasses.field(default_factory=dict[GroupKey, list[tuple[str, Call]]])
    # (keeper, session, tool_use_id) -> output_fingerprint, for every keeper including excluded ones.
    fingerprints: dict[CallKey, str] = dataclasses.field(default_factory=dict[CallKey, str])


@dataclasses.dataclass(frozen=True, slots=True)
class Params:
    min_bytes: int
    stub_bytes: int
    since: float | None
    until: float | None


@dataclasses.dataclass(slots=True)
class Skipped:
    bad_lines: int = 0
    bad_message_entries: int = 0
    outside_window: int = 0
    missing_blobs: int = 0
    unreadable_blobs: int = 0
    other_records: int = 0
    unkeyed_calls: int = 0
    unmatched_results: int = 0


@dataclasses.dataclass(slots=True)
class Bucket:
    """Requests (total = prompt bytes) or calls (total = result bytes) and their repeats."""

    count: int = 0
    total_bytes: int = 0
    repeat_count: int = 0
    repeat_bytes: int = 0
    saved_bytes: int = 0
    earlier_count: int = 0
    earlier_bytes: int = 0

    def add(self, total_bytes: int, repeat_sizes: Sequence[int], stub_bytes: int, earlier_sizes: Sequence[int]) -> None:
        self.count += 1
        self.total_bytes += total_bytes
        self.repeat_count += len(repeat_sizes)
        self.repeat_bytes += sum(repeat_sizes)
        self.saved_bytes += sum(max(0, size - stub_bytes) for size in repeat_sizes)
        self.earlier_count += len(earlier_sizes)
        self.earlier_bytes += sum(earlier_sizes)


def new_buckets() -> dict[str, Bucket]:
    return {}


@dataclasses.dataclass(slots=True)
class Tally:
    total: Bucket = dataclasses.field(default_factory=Bucket)
    by_keeper: dict[str, Bucket] = dataclasses.field(default_factory=new_buckets)
    by_tool: dict[str, Bucket] = dataclasses.field(default_factory=new_buckets)
    by_period: dict[str, Bucket] = dataclasses.field(default_factory=new_buckets)
    # Stored requests only: the saved share of each request.
    request_shares: list[float] = dataclasses.field(default_factory=list[float])

    def add(
        self,
        keeper: str,
        tool: str | None,
        period: str,
        total_bytes: int,
        repeat_sizes: Sequence[int],
        stub_bytes: int,
        earlier_sizes: Sequence[int] = (),
    ) -> None:
        buckets = [self.total, self.by_keeper.setdefault(keeper, Bucket()), self.by_period.setdefault(period, Bucket())]
        if tool is not None:
            buckets.append(self.by_tool.setdefault(tool, Bucket()))
        for bucket in buckets:
            bucket.add(total_bytes, repeat_sizes, stub_bytes, earlier_sizes)


def as_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_number(value: object) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def as_object(value: object) -> dict[str, object] | None:
    return cast(dict[str, object], value) if isinstance(value, dict) else None


def as_text(value: object) -> str | None:
    return value if isinstance(value, str) and value != "" else None


def sha_of(value: object) -> str | None:
    match = SHA_PATTERN.search(value) if isinstance(value, str) else None
    return match.group(1) if match else None


def in_window(instant: float, params: Params) -> bool:
    return (params.since is None or instant >= params.since) and (params.until is None or instant < params.until)


def period_of(instant: float, fmt: str) -> str:
    return datetime.datetime.fromtimestamp(instant, UTC).strftime(fmt)


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
    captured = as_number(row.get("captured_at"))
    if not isinstance(raw, list) or captured is None:
        return None
    parsed = [parse_message(position, entry) for position, entry in enumerate(cast(list[object], raw))]
    skipped.bad_message_entries += sum(1 for entry in parsed if entry is None)
    placed = sorted((entry for entry in parsed if entry is not None), key=lambda entry: entry[0])
    fixed = as_int((as_object(row.get("system_prompt")) or {}).get("bytes")) or 0
    schemas = row.get("tool_schemas")
    if isinstance(schemas, list):
        for schema in cast(list[object], schemas):
            fixed += as_int((as_object((as_object(schema) or {}).get("artifact")) or {}).get("bytes")) or 0
    return Stored(keeper, as_text(row.get("trace_id")), captured, fixed, tuple(message for _, message in placed))


def day_files(base_path: pathlib.Path, from_date: str, to_date: str) -> Iterator[tuple[str, pathlib.Path]]:
    for path in sorted((base_path / ".masc" / "keepers").glob("*/provider-inputs/*/*.jsonl")):
        day = f"{path.parent.name}-{path.stem}"
        if DAY_PATTERN.fullmatch(day) and from_date <= day <= to_date:
            yield path.parent.parent.parent.name, path


def load_requests(
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


@dataclasses.dataclass(frozen=True, slots=True)
class Result:
    call_id: str | None
    text: str


def result_blocks(blob: object) -> list[Result]:
    """The `tool_result` blocks of a message blob. A lone block without a `tool_use_id` takes the
    top-level `tool_call_id`."""
    fields = as_object(blob) or {}
    blocks = fields.get("content_blocks")
    if not isinstance(blocks, list):
        return []
    results: list[Result] = []
    for block in cast(list[object], blocks):
        item = as_object(block)
        if item is None or item.get("type") != "tool_result":
            continue
        content = item.get("content")
        body = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False, sort_keys=True)
        results.append(Result(as_text(item.get("tool_use_id")), body))
    if len(results) == 1 and results[0].call_id is None:
        return [Result(as_text(fields.get("tool_call_id")), results[0].text)]
    return results


def read_blob(base_path: pathlib.Path, sha: str, skipped: Skipped) -> dict[str, object] | None:
    path = base_path / ".masc" / "tool_blobs" / sha[:2] / sha
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        skipped.missing_blobs += 1
        return None
    try:
        decoded: object = json.loads(raw)
    except json.JSONDecodeError:
        decoded = None
    blob = as_object(decoded)
    if blob is None:
        skipped.unreadable_blobs += 1
    return blob


def read_results(base_path: pathlib.Path, sha: str, skipped: Skipped) -> list[Result]:
    """The results of a tool message blob; none when the blob is missing or holds no result."""
    blob = read_blob(base_path, sha, skipped)
    if blob is None:
        return []
    results = result_blocks(blob)
    if not results:
        skipped.unreadable_blobs += 1
    return results


def starts_turn(base_path: pathlib.Path, message: Message, skipped: Skipped) -> bool:
    """A user message whose blob says `conversation`; one that cannot be read is taken as a start."""
    blob = read_blob(base_path, message.sha, skipped) if message.sha is not None else None
    return blob is None or blob.get("origin") == TURN_ORIGIN


def repeated_results(
    base_path: pathlib.Path,
    messages: Sequence[Message],
    params: Params,
    skipped: Skipped,
    answer_of: Callable[[str], str | None] | None,
) -> tuple[list[int], list[int]]:
    """Sizes of the results that repeat an earlier one: of the same turn, and of an earlier turn only.

    `answer_of` maps a call id to the ledger fingerprint of its answer; None compares the texts."""
    this_turn: set[str] = set()
    earlier_turns: set[str] = set()
    same: list[int] = []
    earlier: list[int] = []
    for message in messages:
        if message.role == "user":
            if starts_turn(base_path, message, skipped):
                earlier_turns |= this_turn
                this_turn = set()
            continue
        if message.role != "tool" or message.has_media or message.sha is None or message.size < params.min_bytes:
            continue
        for result in read_results(base_path, message.sha, skipped):
            encoded = result.text.encode("utf-8")
            if len(encoded) < params.min_bytes or len(encoded) == 0:
                continue
            if answer_of is None:
                identity = hashlib.sha256(encoded).hexdigest()
            else:
                identity = answer_of(result.call_id) if result.call_id is not None else None
                if identity is None:
                    skipped.unmatched_results += 1
                    continue
            if identity in this_turn:
                same.append(len(encoded))
                continue
            if identity in earlier_turns:
                earlier.append(len(encoded))
            this_turn.add(identity)
    return same, earlier


def replay_requests(
    base_path: pathlib.Path,
    stored: Sequence[Stored],
    params: Params,
    skipped: Skipped,
    fingerprints: dict[CallKey, str] | None,
) -> Tally:
    tally = Tally()
    for request in stored:
        if not in_window(request.captured_at, params):
            skipped.outside_window += 1
            continue
        answer_of = None if fingerprints is None else answer_lookup(fingerprints, request)
        sizes, earlier_sizes = repeated_results(base_path, request.messages, params, skipped, answer_of)
        prompt = sum(message.size for message in request.messages) + request.fixed_bytes
        period = period_of(request.captured_at, "%Y-%m-%dT%H")
        tally.add(request.keeper, None, period, prompt, sizes, params.stub_bytes, earlier_sizes)
        tally.request_shares.append(sum(max(0, size - params.stub_bytes) for size in sizes) / prompt if prompt > 0 else 0.0)
    return tally


def answer_lookup(fingerprints: dict[CallKey, str], request: Stored) -> Callable[[str], str | None]:
    def lookup(call_id: str) -> str | None:
        return None if request.trace is None else fingerprints.get((request.keeper, request.trace, call_id))

    return lookup


def ledger_files(base_path: pathlib.Path, from_date: str, to_date: str) -> Iterator[pathlib.Path]:
    for month in sorted((base_path / ".masc" / "tool_calls").glob("????-??")):
        for path in sorted(month.glob("*.jsonl")):
            name = LEDGER_NAME.fullmatch(path.name)
            if name is not None and from_date <= f"{month.name}-{name.group(1)}" <= to_date:
                yield path


def parse_call(row: dict[str, object]) -> tuple[GroupKey, str, Call, CallKey | None] | None:
    keeper, session, tool = as_text(row.get("keeper")), as_text(row.get("session_id")), as_text(row.get("tool"))
    turn, size, ts = as_int(row.get("keeper_turn_id")), as_int(row.get("result_bytes")), as_number(row.get("ts"))
    fingerprint = as_text(row.get("output_fingerprint"))
    if keeper is None or session is None or tool is None or turn is None or size is None or ts is None or fingerprint is None:
        return None
    call_id = as_text(row.get("tool_use_id"))
    call_key = None if call_id is None else (keeper, session, call_id)
    return (keeper, session, turn), keeper, Call(ts, tool, size, fingerprint), call_key


def load_ledger(
    base_path: pathlib.Path, from_date: str, to_date: str, excluded: Sequence[str], skipped: Skipped
) -> Ledger:
    ledger = Ledger()
    for path in ledger_files(base_path, from_date, to_date):
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    decoded: object = json.loads(line)
                except json.JSONDecodeError:
                    skipped.bad_lines += 1
                    continue
                row = as_object(decoded)
                if row is None:
                    skipped.bad_lines += 1
                    continue
                if row.get("record_kind") != TOOL_CALL:
                    skipped.other_records += 1
                    continue
                parsed = parse_call(row)
                if parsed is None:
                    skipped.unkeyed_calls += 1
                    continue
                key, keeper, call, call_key = parsed
                if call_key is not None:
                    ledger.fingerprints[call_key] = call.fingerprint
                if keeper not in excluded:
                    ledger.groups.setdefault(key, []).append((keeper, call))
    return ledger


def replay_ledger(groups: dict[GroupKey, list[tuple[str, Call]]], params: Params, skipped: Skipped) -> Tally:
    tally = Tally()
    for calls in groups.values():
        seen: set[str] = set()
        for keeper, call in sorted(calls, key=lambda item: item[1].ts):
            big = call.size >= params.min_bytes
            repeated = big and call.fingerprint in seen
            if big:
                seen.add(call.fingerprint)
            if not in_window(call.ts, params):
                skipped.outside_window += 1
                continue
            tally.add(keeper, call.tool, period_of(call.ts, "%Y-%m-%d"), call.size, [call.size] if repeated else [], params.stub_bytes)
    return tally


def quantile(sorted_values: Sequence[float], q: float) -> float:
    if not sorted_values:
        return 0.0
    return sorted_values[max(0, math.ceil(q * len(sorted_values)) - 1)]


def share(part: float, whole: float) -> float:
    return round(part / whole, 4) if whole > 0 else 0.0


def bucket_block(bucket: Bucket, with_earlier: bool) -> dict[str, object]:
    block: dict[str, object] = {
        "count": bucket.count,
        "bytes": bucket.total_bytes,
        "repeat_count": bucket.repeat_count,
        "repeat_bytes": bucket.repeat_bytes,
        "repeat_share": share(bucket.repeat_bytes, bucket.total_bytes),
        "saved_bytes": bucket.saved_bytes,
        "saved_share": share(bucket.saved_bytes, bucket.total_bytes),
    }
    if with_earlier:
        block["earlier_turn_repeat_count"] = bucket.earlier_count
        block["earlier_turn_repeat_bytes"] = bucket.earlier_bytes
        block["earlier_turn_repeat_share"] = share(bucket.earlier_bytes, bucket.total_bytes)
    return block


def top_blocks(label: str, buckets: dict[str, Bucket], top: int, with_earlier: bool) -> list[dict[str, object]]:
    ranked = sorted(buckets.items(), key=lambda item: (-(item[1].repeat_bytes + item[1].earlier_bytes), item[0]))[:top]
    return [{label: name, **bucket_block(bucket, with_earlier)} for name, bucket in ranked]


def report(tally: Tally, top: int, period_label: str, ledger: bool) -> dict[str, object]:
    """`count` is requests or calls and `bytes` is prompt bytes or result bytes."""
    with_earlier = not ledger
    result: dict[str, object] = {
        **bucket_block(tally.total, with_earlier),
        "by_keeper": top_blocks("keeper", tally.by_keeper, top, with_earlier),
        period_label: [{"at": at, **bucket_block(bucket, with_earlier)} for at, bucket in sorted(tally.by_period.items())],
    }
    if ledger:
        result["by_tool"] = top_blocks("tool", tally.by_tool, top, with_earlier)
    else:
        ordered = sorted(tally.request_shares)
        result["requests_with_repeat"] = sum(1 for value in ordered if value > 0)
        result["per_request_saved_share"] = {
            **{name: round(quantile(ordered, q), 4) for name, q in QUANTILES},
            "max": round(ordered[-1], 4) if ordered else 0.0,
        }
    return result


def parse_instant(text: str) -> float:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=UTC).timestamp()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", required=True, help="first UTC day of the files, YYYY-MM-DD")
    parser.add_argument("--to-date", required=True, help="last UTC day of the files, YYYY-MM-DD")
    parser.add_argument("--since", help="count items at or after this UTC time, YYYY-MM-DDTHH:MM:SS")
    parser.add_argument("--until", help="count items before this UTC time")
    parser.add_argument("--view", choices=VIEWS, default="both")
    parser.add_argument("--match", choices=MATCHES, default="text", help="how stored requests tell equal results")
    parser.add_argument("--min-bytes", type=int, default=DEFAULT_MIN_BYTES)
    parser.add_argument("--stub-bytes", type=int, default=DEFAULT_STUB_BYTES)
    parser.add_argument("--exclude-keeper", action="append", default=[])
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
    if args.min_bytes < 0 or args.stub_bytes < 0 or args.top <= 0:
        parser.error("--min-bytes and --stub-bytes must not be negative and --top must be positive")
    params = Params(args.min_bytes, args.stub_bytes, instants["since"], instants["until"])
    base_path = args.base_path.expanduser()
    skipped = Skipped()
    result: dict[str, object] = {
        "params": {
            "min_bytes": params.min_bytes,
            "stub_bytes": params.stub_bytes,
            "since": params.since,
            "until": params.until,
            "excluded_keepers": args.exclude_keeper,
            "match": args.match,
        }
    }
    needs_ledger = args.view in ("ledger", "both") or args.match == "answer"
    ledger = load_ledger(base_path, args.from_date, args.to_date, args.exclude_keeper, skipped) if needs_ledger else Ledger()
    if args.view in ("requests", "both"):
        stored = load_requests(base_path, args.from_date, args.to_date, args.exclude_keeper, skipped)
        fingerprints = ledger.fingerprints if args.match == "answer" else None
        result["requests"] = report(replay_requests(base_path, stored, params, skipped, fingerprints), args.top, "by_hour", ledger=False)
    if args.view in ("ledger", "both"):
        result["ledger"] = report(replay_ledger(ledger.groups, params, skipped), args.top, "by_day", ledger=True)
    result["skipped"] = dataclasses.asdict(skipped)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out is not None:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
