#!/usr/bin/env python3
"""Count the tool-result bytes that stored requests carry, by tool.

Reads three stores under `<base-path>/.masc` and never writes to them:

- `keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl`: one captured request per
  turn. `wire.body_bytes` is the size of the HTTP body. A `messages[]` entry with
  `role == "tool"` names its stored JSON by the `sha256=` in `artifact.content_ref`.
- `tool_blobs/<sha[:2]>/<sha>`: that stored JSON. Its `content_blocks[]` hold the
  message's `tool_result` blocks.
- `tool_calls/YYYY-MM/DD[.NNN].jsonl`: the tool-call ledger. A row with
  `record_kind == "tool_call"` pairs a `tool_use_id` with the `tool` that ran.

Definitions:

- stored request: a captured request whose row has a `tool_schemas` list. The
  turn's other requests are not captured, so every count is over captured requests.
- tool message: one distinct stored JSON of a `role == "tool"` message, keyed by its
  sha256. Its stored size is the length of the blob file.
- carried: the number of times stored requests list the tool message. Carried bytes
  are the stored size times that number. A history keeps a message for many turns and
  every request pays for it.
- result: one `tool_result` block of a tool message. Its tool is the ledger row's
  `tool` for the block's `tool_use_id`, or `<unmapped>` when the ledger window has no
  such row. A result's bytes are the length of its compact JSON. The bytes around the
  blocks of a message (role, origin, call id, separators) go to its first result, so
  the results of a message add up to its stored size.
- stored copy: the `text_content` field of a `tool_result` block, counted as
  `,"text_content":` and the JSON string. `Agent_core.History.content_block_to_json`
  writes it next to the typed blocks of `content`. The wire encoders send the blocks
  and not this string (`Api_common.tool_result_wire_fields_with`,
  `Backend_openai_serialize.tool_result_content_string`). It counts in the stored size
  and not in what a request carries.
- stub: a result whose text starts with `[masc:blob sha256=`, the marker
  `Tool_output.encode_for_agent_core` writes where it replaced a historical result
  with a reference. `bytes=N` in the marker is the size of the replaced result. A
  result's text is its `content` when that is a string, or the first string `text`
  of `content` when it is a list.

Sizes are of the stored JSON, not of the wire form. The blob is read as compact JSON
(no spaces after `,` and `:`). A blob whose compact re-serialization has another
length than the file is counted in `reserialization_mismatch`, because its result and
copy sizes are then off by a few bytes.

Nothing here reads image bytes.

Usage:
    docs/evidence/tool-result-carry-2026-11/measure_tool_result_carry.py \
        --base-path ~/me --from-date 2026-10-29 --to-date 2026-11-04 \
        --json-out result.json
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime
import json
import pathlib
import re
import sys
from collections.abc import Iterator
from typing import cast

DAY_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}")
SHA_PATTERN = re.compile(r"sha256=([0-9a-f]{64})")
# The marker `Tool_output.encode_for_agent_core` writes:
# [masc:blob sha256=%s bytes=%d mime=%s[ answer_sha256=%s] preview=%S]
STUB_PATTERN = re.compile(
    r'\[masc:blob sha256=[0-9a-f]{64} bytes=(\d+) mime=\S+(?: answer_sha256=\S+)? preview="'
)
STORED_COPY_FIELD = ',"text_content":'
UNMAPPED = "<unmapped>"
DEFAULT_TOP = 20


@dataclasses.dataclass(slots=True)
class Skipped:
    """What the readers could not use. Reported, never dropped silently."""

    bad_lines: int = 0
    bad_message_entries: int = 0
    unplaced_files: int = 0
    unidentified_calls: int = 0
    unreadable_blobs: int = 0
    invalid_blobs: int = 0
    size_disagreements: int = 0
    reserialization_mismatch: int = 0


@dataclasses.dataclass(slots=True)
class Carried:
    requests: int = 0
    body_bytes: int = 0
    carriers: collections.Counter[str] = dataclasses.field(default_factory=collections.Counter)
    recorded_bytes: dict[str, int] = dataclasses.field(default_factory=dict)


@dataclasses.dataclass(frozen=True, slots=True)
class Result:
    tool_use_id: str | None
    bytes: int
    stored_copy_bytes: int
    stub_original_bytes: int | None


@dataclasses.dataclass(slots=True)
class ToolTotals:
    results: int = 0
    stub_results: int = 0
    stored_bytes: int = 0
    carried_bytes: int = 0
    stored_copy_carried_bytes: int = 0
    stub_bytes: int = 0
    stub_carried_bytes: int = 0
    stub_original_bytes: int = 0


@dataclasses.dataclass(frozen=True, slots=True)
class ToolRow:
    tool: str
    results: int
    stub_results: int
    stored_bytes: int
    carried_bytes: int
    stored_copy_carried_bytes: int
    stub_bytes: int
    stub_carried_bytes: int
    stub_original_bytes: int


@dataclasses.dataclass(frozen=True, slots=True)
class Summary:
    messages: int
    rows: tuple[ToolRow, ...]

    @property
    def carried_bytes(self) -> int:
        return sum(row.carried_bytes for row in self.rows)

    @property
    def stored_copy_carried_bytes(self) -> int:
        return sum(row.stored_copy_carried_bytes for row in self.rows)

    @property
    def stub_carried_bytes(self) -> int:
        return sum(row.stub_carried_bytes for row in self.rows)

    @property
    def stub_results(self) -> int:
        return sum(row.stub_results for row in self.rows)


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


def _int_field(container: object, key: str) -> int | None:
    if not isinstance(container, dict):
        return None
    value = cast(dict[str, object], container).get(key)
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def read_carried(masc_dir: pathlib.Path, from_day: str, to_day: str, skipped: Skipped) -> Carried:
    carried = Carried()
    for path in sorted(masc_dir.glob("keepers/*/provider-inputs/*/*.jsonl")):
        if _placed_in_window(path, from_day, to_day, skipped) is None:
            continue
        for row in _rows(path, skipped):
            if not isinstance(row.get("tool_schemas"), list):
                continue
            carried.requests += 1
            carried.body_bytes += _int_field(row.get("wire"), "body_bytes") or 0
            messages = row.get("messages")
            if not isinstance(messages, list):
                continue
            for entry in cast(list[object], messages):
                fields = cast(dict[str, object], entry) if isinstance(entry, dict) else {}
                if fields.get("role") != "tool":
                    continue
                artifact = fields.get("artifact")
                reference = cast(dict[str, object], artifact).get("content_ref") if isinstance(artifact, dict) else None
                found = SHA_PATTERN.search(reference) if isinstance(reference, str) else None
                recorded = _int_field(artifact, "bytes")
                if found is None or recorded is None:
                    skipped.bad_message_entries += 1
                    continue
                carried.carriers[found.group(1)] += 1
                carried.recorded_bytes[found.group(1)] = recorded
    return carried


def read_tool_names(masc_dir: pathlib.Path, from_day: str, to_day: str, skipped: Skipped) -> dict[str, str]:
    names: dict[str, str] = {}
    for path in sorted(masc_dir.glob("tool_calls/*/*.jsonl")):
        if _placed_in_window(path, from_day, to_day, skipped) is None:
            continue
        for row in _rows(path, skipped):
            if row.get("record_kind") != "tool_call":
                continue
            tool_use_id, tool = row.get("tool_use_id"), row.get("tool")
            if isinstance(tool_use_id, str) and isinstance(tool, str):
                names[tool_use_id] = tool
            else:
                skipped.unidentified_calls += 1
    return names


def _compact(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _compact_length(value: object) -> int:
    return len(_compact(value).encode("utf-8"))


def _result_text(content: object) -> str | None:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for part in cast(list[object], content):
            if isinstance(part, dict):
                text = cast(dict[str, object], part).get("text")
                if isinstance(text, str):
                    return text
    return None


def _stub_original_bytes(content: object) -> int | None:
    text = _result_text(content)
    found = STUB_PATTERN.match(text) if text is not None else None
    return int(found.group(1)) if found else None


def inspect_blob(raw: bytes, skipped: Skipped) -> list[Result]:
    """The results of one stored tool message. Raises ValueError when the blob is not a message."""
    decoded: object = json.loads(raw)  # JSONDecodeError and UnicodeDecodeError are ValueErrors
    if not isinstance(decoded, dict):
        raise ValueError("not a JSON object")
    message = cast(dict[str, object], decoded)
    if len(_compact(message).encode("utf-8")) != len(raw):
        skipped.reserialization_mismatch += 1
    blocks = message.get("content_blocks")
    results: list[Result] = []
    if isinstance(blocks, list):
        for block in cast(list[object], blocks):
            if not isinstance(block, dict):
                continue
            fields = cast(dict[str, object], block)
            if fields.get("type") != "tool_result":
                continue
            tool_use_id = fields.get("tool_use_id")
            copy = fields.get("text_content")
            results.append(
                Result(
                    tool_use_id=tool_use_id if isinstance(tool_use_id, str) else None,
                    bytes=_compact_length(fields),
                    stored_copy_bytes=(len(STORED_COPY_FIELD) + _compact_length(copy)) if isinstance(copy, str) else 0,
                    stub_original_bytes=_stub_original_bytes(fields.get("content")),
                )
            )
    if not results:
        return [Result(None, len(raw), 0, None)]
    around = len(raw) - sum(result.bytes for result in results)
    if around > 0:
        first = results[0]
        results[0] = dataclasses.replace(first, bytes=first.bytes + around)
    return results


def summarize(
    masc_dir: pathlib.Path, carried: Carried, tool_names: dict[str, str], skipped: Skipped
) -> Summary:
    totals: dict[str, ToolTotals] = {}
    messages = 0
    for sha, count in carried.carriers.items():
        try:
            raw = (masc_dir / "tool_blobs" / sha[:2] / sha).read_bytes()
        except OSError:
            skipped.unreadable_blobs += 1
            continue
        try:
            results = inspect_blob(raw, skipped)
        except ValueError:
            skipped.invalid_blobs += 1
            continue
        messages += 1
        if carried.recorded_bytes[sha] != len(raw):
            skipped.size_disagreements += 1
        for result in results:
            tool = tool_names.get(result.tool_use_id, UNMAPPED) if result.tool_use_id is not None else UNMAPPED
            row = totals.setdefault(tool, ToolTotals())
            row.results += 1
            row.stored_bytes += result.bytes
            row.carried_bytes += result.bytes * count
            row.stored_copy_carried_bytes += result.stored_copy_bytes * count
            if result.stub_original_bytes is not None:
                row.stub_results += 1
                row.stub_bytes += result.bytes
                row.stub_carried_bytes += result.bytes * count
                row.stub_original_bytes += result.stub_original_bytes
    rows = [
        ToolRow(
            tool=tool,
            results=row.results,
            stub_results=row.stub_results,
            stored_bytes=row.stored_bytes,
            carried_bytes=row.carried_bytes,
            stored_copy_carried_bytes=row.stored_copy_carried_bytes,
            stub_bytes=row.stub_bytes,
            stub_carried_bytes=row.stub_carried_bytes,
            stub_original_bytes=row.stub_original_bytes,
        )
        for tool, row in totals.items()
    ]
    rows.sort(key=lambda row: (-row.carried_bytes, row.tool))
    return Summary(messages=messages, rows=tuple(rows))


def _pct(part: int, whole: int) -> float:
    return 100 * part / whole if whole else 0.0


def to_json(
    from_day: str, to_day: str, carried: Carried, summary: Summary, skipped: Skipped
) -> dict[str, object]:
    return {
        "window": {"from": from_day, "to": to_day},
        "stored_requests": carried.requests,
        "body_bytes": carried.body_bytes,
        "tool_messages": summary.messages,
        "carried_bytes": summary.carried_bytes,
        "stored_copy_carried_bytes": summary.stored_copy_carried_bytes,
        "stub_results": summary.stub_results,
        "stub_carried_bytes": summary.stub_carried_bytes,
        "tools": [dataclasses.asdict(row) for row in summary.rows],
        "skipped": dataclasses.asdict(skipped),
    }


def _print_report(
    from_day: str, to_day: str, carried: Carried, summary: Summary, skipped: Skipped, top: int
) -> None:
    body = carried.body_bytes
    total = summary.carried_bytes
    print(f"window {from_day} ~ {to_day}: stored requests {carried.requests}, body {body / 1e9:.2f} GB")
    print(
        f"tool messages {summary.messages} distinct, carried {total / 1e9:.3f} GB "
        f"({_pct(total, body):.1f}% of body)"
    )
    copy = summary.stored_copy_carried_bytes
    print(
        f"  stored copy (not on the wire): {copy / 1e9:.3f} GB "
        f"({_pct(copy, total):.1f}% of carried, {_pct(copy, body):.1f}% of body)"
    )
    stubs = summary.stub_carried_bytes
    print(
        f"  blob stubs: {summary.stub_results} results, {stubs / 1e9:.3f} GB "
        f"({_pct(stubs, total):.1f}% of carried, {_pct(stubs, body):.1f}% of body)"
    )
    reasons = ", ".join(f"{name} {value}" for name, value in dataclasses.asdict(skipped).items() if value)
    print(f"skipped: {reasons or 'none'}")
    print()
    print(
        f"{'tool':30} {'results':>8} {'stubs':>6} {'mean_B':>8} {'carried_GB':>10} {'share%':>7} "
        f"{'stub_GB':>8} {'copy_GB':>8} {'stub_B':>7} {'orig_B':>7}"
    )
    for row in summary.rows[:top]:
        mean = row.stored_bytes / row.results
        stub_mean = row.stub_bytes / row.stub_results if row.stub_results else 0.0
        original_mean = row.stub_original_bytes / row.stub_results if row.stub_results else 0.0
        print(
            f"{row.tool[:30]:30} {row.results:8d} {row.stub_results:6d} {mean:8.0f} "
            f"{row.carried_bytes / 1e9:10.3f} {_pct(row.carried_bytes, total):7.1f} "
            f"{row.stub_carried_bytes / 1e9:8.3f} {row.stored_copy_carried_bytes / 1e9:8.3f} "
            f"{stub_mean:7.0f} {original_mean:7.0f}"
        )


def _day_argument(text: str) -> str:
    if not DAY_PATTERN.fullmatch(text):
        raise argparse.ArgumentTypeError(f"{text!r} is not YYYY-MM-DD")
    try:
        datetime.date.fromisoformat(text)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{text!r} is not a date: {error}") from error
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True, help="directory that holds .masc")
    parser.add_argument("--from-date", type=_day_argument, required=True)
    parser.add_argument("--to-date", type=_day_argument, required=True)
    parser.add_argument("--top", type=int, default=DEFAULT_TOP, help="tools to print (default %(default)s)")
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    if args.from_date > args.to_date:
        parser.error("--from-date is after --to-date")
    if args.top < 1:
        parser.error("--top must be at least 1")
    masc_dir = args.base_path.expanduser() / ".masc"
    if not masc_dir.is_dir():
        print(f"error: {masc_dir} is not a directory", file=sys.stderr)
        return 2
    skipped = Skipped()
    carried = read_carried(masc_dir, args.from_date, args.to_date, skipped)
    if carried.requests == 0:
        print("error: no stored request in the window", file=sys.stderr)
        return 2
    tool_names = read_tool_names(masc_dir, args.from_date, args.to_date, skipped)
    summary = summarize(masc_dir, carried, tool_names, skipped)
    _print_report(args.from_date, args.to_date, carried, summary, skipped, args.top)
    if args.json_out is not None:
        payload = to_json(args.from_date, args.to_date, carried, summary, skipped)
        args.json_out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
