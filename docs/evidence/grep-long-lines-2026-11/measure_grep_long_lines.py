#!/usr/bin/env python3
"""Measure how long the matched lines of Keeper Grep results are, and what cutting them would have changed.

Reads, and never writes, `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` and `<DD>.<NNN>.jsonl`
(one JSON object per line) and the blobs under `<base-path>/.masc/tool_blobs/<sha[0:2]>/<sha>`.
A line counts when `record_kind` is `tool_call`, `tool` is `Grep` and `ts` (UTC seconds) lies in
[--since, --until).

Definitions:

- result_bytes: the `result_bytes` field, the size of the result before it was shown to the model.
- stored result: `output` is `{"_blob": {"sha256": ...}}` when the text handed to the lane was a blob marker
  (lib/keeper_tool_call_log.ml `blob_aware_output_json`), so the result is read from the blob; a failed call
  has text after the JSON object, which is ignored. Otherwise `output` is a string the ledger keeps cut to a
  few KB. It counts only when it parses as a whole result, and a cut one carries the key `_truncated`.
- matched line: one string of the result's `matches` array, except the last string when it starts with
  `...[` (the omission note of `lines_to_json`).
- after the cut: the same result with every matched line cut to --cap bytes and `error_detail` cut to
  --budget bytes (a port of `cut_to_bytes` in lib/keeper/keeper_tool_shared_runtime.ml), the size computed
  by re-serializing the cut parts. This is a lower bound for the new size of a call with matched lines:
  the old budget loop dropped every line after an oversized first line, and those lines are not stored.
  The upper bound is --budget plus the largest envelope around `matches`.

Usage:
    python3 docs/evidence/grep-long-lines-2026-11/measure_grep_long_lines.py \
        --base-path ~/me --since 2026-11-06T09:52:00 --until 2026-11-07T09:52:00 \
        --json-out result.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import re
import sys
from collections import Counter
from collections.abc import Iterator, Sequence
from typing import cast

RECORD_KIND = "tool_call"
TOOL = "Grep"
LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
OMISSION_NOTE = "...["
# The ledger keeps a long inline `output` as a JSON object cut to a few KB that carries this key.
TRUNCATED_KEY = "_truncated"
FILE_PREFIX = re.compile(r"^(?P<path>[^:]+):[0-9]+:")
# Inline ceiling of a tool result per lane, lib/runtime/runtime_execution.ml:85-91 and lib/core/common.ml:217,235.
CEILINGS = (("16384", 16_384), ("32768", 32_768), ("65536", 65_536))
DEFAULT_CAP = 2_000
DEFAULT_BUDGET = 32_000
TOP_FILES = 5
UTC = datetime.timezone.utc
DECODER = json.JSONDecoder()


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    keeper: str
    result_bytes: int
    result: dict[str, object] | None
    unreadable: str


def ledger_files(base: pathlib.Path, since: datetime.datetime, until: datetime.datetime) -> list[pathlib.Path]:
    """The ledger files of each UTC day the window touches, in name order."""
    paths: list[pathlib.Path] = []
    day = since.date()
    last = until.date()
    while day <= last:
        folder = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
        if folder.is_dir():
            paths.extend(sorted(p for p in folder.iterdir() if (m := LEDGER_FILE.match(p.name)) and int(m["day"]) == day.day))
        day += datetime.timedelta(days=1)
    return paths


def first_object(text: str) -> dict[str, object] | None:
    """The JSON object a text starts with; text after it (a failure note) is ignored."""
    try:
        value = cast("object", DECODER.raw_decode(text.lstrip())[0])
    except ValueError:
        return None
    return cast("dict[str, object]", value) if isinstance(value, dict) else None


def result_of(output: object, blob_root: pathlib.Path) -> tuple[dict[str, object] | None, str]:
    """The whole JSON result a ledger `output` stands for, or None with the reason it cannot be read."""
    if isinstance(output, dict):
        blob = cast("dict[str, object]", output).get("_blob")
        sha = cast("dict[str, object]", blob).get("sha256") if isinstance(blob, dict) else None
        if not isinstance(sha, str) or len(sha) < 2:
            return None, "no_blob_sha"
        path = blob_root / sha[:2] / sha
        if not path.is_file():
            return None, "blob_missing"
        parsed = first_object(path.read_text(encoding="utf-8", errors="replace"))
        return (parsed, "") if parsed is not None else (None, "blob_not_json")
    if isinstance(output, str):
        parsed = first_object(output)
        if parsed is None or TRUNCATED_KEY in parsed:
            return None, "cut_excerpt"
        return parsed, ""
    return None, "no_output"


def read_calls(paths: Sequence[pathlib.Path], since: float, until: float, blob_root: pathlib.Path) -> Iterator[Call]:
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                if b'"Grep"' not in raw:
                    continue
                try:
                    row = cast("object", json.loads(raw))
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                fields = cast("dict[str, object]", row)
                if fields.get("record_kind") != RECORD_KIND or fields.get("tool") != TOOL:
                    continue
                stamp = fields.get("ts")
                if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not since <= float(stamp) < until:
                    continue
                size = fields.get("result_bytes")
                keeper = fields.get("keeper")
                result, reason = result_of(fields.get("output"), blob_root)
                yield Call(
                    keeper=keeper if isinstance(keeper, str) else "",
                    result_bytes=size if isinstance(size, int) and not isinstance(size, bool) else 0,
                    result=result,
                    unreadable=reason,
                )


def matched_lines(result: dict[str, object]) -> list[str] | None:
    """The `matches` strings of a result without the trailing omission note, or None without a `matches` array."""
    matches = result.get("matches")
    if not isinstance(matches, list):
        return None
    lines = [item for item in cast("list[object]", matches) if isinstance(item, str)]
    if lines and lines[-1].startswith(OMISSION_NOTE):
        lines = lines[:-1]
    return lines


def json_bytes(value: object) -> int:
    """The size `Yojson.Safe.to_string` gives a value: compact, non-ASCII kept as UTF-8."""
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def cut_to_bytes(text: str, limit: int) -> str:
    """Port of `cut_to_bytes`: at most `limit` bytes of a text on a UTF-8 boundary, then a note of what was cut."""
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text
    kept = data[:limit].decode("utf-8", errors="ignore")
    return f"{kept}...[cut: {len(kept.encode('utf-8'))} of {len(data)} bytes kept]"


@dataclasses.dataclass(frozen=True, slots=True)
class Projection:
    size: int
    lines_cut: bool
    error_detail_cut: bool


def project(result: dict[str, object], result_bytes: int, cap: int, budget: int) -> Projection:
    """The result size when every matched line is cut to `cap` bytes and `error_detail` to `budget` bytes."""
    size = result_bytes
    lines_cut = False
    matches = result.get("matches")
    lines = matched_lines(result)
    if lines is not None and isinstance(matches, list):
        cut = [cut_to_bytes(line, cap) for line in lines]
        lines_cut = cut != lines
        size += json_bytes(cut + cast("list[object]", matches)[len(lines):]) - json_bytes(matches)
    detail = result.get("error_detail")
    error_detail_cut = False
    if isinstance(detail, str):
        shortened = cut_to_bytes(detail, budget)
        error_detail_cut = shortened != detail
        size += json_bytes(shortened) - json_bytes(detail)
    return Projection(size=size, lines_cut=lines_cut, error_detail_cut=error_detail_cut)


def percentile(sorted_values: Sequence[int], fraction: float) -> int:
    return sorted_values[min(len(sorted_values) - 1, int(fraction * (len(sorted_values) - 1)))] if sorted_values else 0


def file_of(line: str) -> str:
    found = FILE_PREFIX.match(line)
    return found["path"] if found else ""


def summarize(calls: Iterator[Call], cap: int, budget: int) -> dict[str, object]:
    total = 0
    all_bytes = 0
    readable = 0
    exact = 0
    unreadable: Counter[str] = Counter()
    lengths: list[int] = []
    long_files: Counter[str] = Counter()
    long_keepers: Counter[str] = Counter()
    before_calls = {name: 0 for name, _ in CEILINGS}
    before_bytes = {name: 0 for name, _ in CEILINGS}
    after_calls = {name: 0 for name, _ in CEILINGS}
    after_bytes = {name: 0 for name, _ in CEILINGS}
    line_cut_calls = 0
    line_cut_before = 0
    line_cut_after = 0
    detail_cut_calls = 0
    detail_cut_before = 0
    detail_cut_after = 0
    envelope_largest = 0
    for call in calls:
        total += 1
        all_bytes += call.result_bytes
        after = call.result_bytes
        if call.result is None:
            unreadable[call.unreadable] += 1
        else:
            lines = matched_lines(call.result)
            readable += 1
            exact += json_bytes(call.result) == call.result_bytes
            if lines is not None:
                lengths.extend(len(line.encode("utf-8")) for line in lines)
                long_lines = [line for line in lines if len(line.encode("utf-8")) > cap]
                if long_lines:
                    long_keepers[call.keeper] += 1
                    long_files.update({file_of(line) for line in long_lines})
            projected = project(call.result, call.result_bytes, cap, budget)
            after = projected.size
            if projected.lines_cut:
                line_cut_calls += 1
                line_cut_before += call.result_bytes
                line_cut_after += projected.size
                envelope_largest = max(envelope_largest, call.result_bytes - json_bytes(call.result.get("matches")))
            if projected.error_detail_cut:
                detail_cut_calls += 1
                detail_cut_before += call.result_bytes
                detail_cut_after += projected.size
        for name, ceiling in CEILINGS:
            if call.result_bytes > ceiling:
                before_calls[name] += 1
                before_bytes[name] += call.result_bytes
            if after > ceiling:
                after_calls[name] += 1
                after_bytes[name] += after
    lengths.sort()
    return {
        "cap_bytes": cap,
        "budget_bytes": budget,
        "calls": total,
        "result_bytes": all_bytes,
        "unreadable": dict(sorted(unreadable.items())),
        "readable_calls": readable,
        "reserialized_size_equals_result_bytes": exact,
        "matched_lines": len(lengths),
        "line_bytes": {
            "p50": percentile(lengths, 0.5),
            "p90": percentile(lengths, 0.9),
            "p99": percentile(lengths, 0.99),
            "max": lengths[-1] if lengths else 0,
        },
        "lines_above_cap": sum(1 for length in lengths if length > cap),
        "calls_with_a_line_above_cap": sum(long_keepers.values()),
        "keepers_with_a_line_above_cap": dict(long_keepers.most_common()),
        "files_of_lines_above_cap": dict(long_files.most_common(TOP_FILES)),
        "line_cut": {
            "calls": line_cut_calls,
            "bytes_before": line_cut_before,
            "bytes_after_lower_bound": line_cut_after,
            "bytes_after_upper_bound": line_cut_calls * (budget + envelope_largest),
        },
        "error_detail_cut": {"calls": detail_cut_calls, "bytes_before": detail_cut_before, "bytes_after": detail_cut_after},
        "above_ceiling_before": {name: {"calls": before_calls[name], "bytes": before_bytes[name]} for name, _ in CEILINGS},
        "above_ceiling_after_lower_bound": {name: {"calls": after_calls[name], "bytes": after_bytes[name]} for name, _ in CEILINGS},
    }


def parse_instant(text: str) -> datetime.datetime:
    parsed = datetime.datetime.fromisoformat(text)
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", type=parse_instant, required=True)
    parser.add_argument("--until", type=parse_instant, required=True)
    parser.add_argument("--cap", type=int, default=DEFAULT_CAP)
    parser.add_argument("--budget", type=int, default=DEFAULT_BUDGET)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    base = cast("pathlib.Path", args.base_path).expanduser()
    since = cast("datetime.datetime", args.since)
    until = cast("datetime.datetime", args.until)
    paths = ledger_files(base, since, until)
    calls = read_calls(paths, since.timestamp(), until.timestamp(), base / ".masc" / "tool_blobs")
    summary = summarize(calls, cast("int", args.cap), cast("int", args.budget))
    summary["window"] = {"since": since.isoformat(), "until": until.isoformat(), "ledger_files": len(paths)}
    text = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
