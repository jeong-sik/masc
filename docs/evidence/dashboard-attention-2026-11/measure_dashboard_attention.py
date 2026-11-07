#!/usr/bin/env python3
"""Measure what Keeper `masc_dashboard` calls returned and what the text becomes when a suggested action that
neighbouring Attention items share is written once.

Reads, and never writes, `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` and `<DD>.<NNN>.jsonl`
(one JSON object per line) and the blobs under `<base-path>/.masc/tool_blobs/<sha[0:2]>/<sha>`.
A line counts when `record_kind` is `tool_call`, `tool` is `masc_dashboard` and `ts` (UTC seconds) lies in
[--since, --until).

Definitions:

- result_bytes: the `result_bytes` field, the size of the result before it was shown to the model.
- text: the dashboard text a stored call stands for. `output` is `{"_blob": {"sha256": ...}}` when the text handed
  to the lane was a blob marker (lib/keeper_tool_call_log.ml `blob_aware_output_json`), so the text is read from
  the blob. Otherwise `output` is a string the ledger keeps cut to a few KB, which counts only when it is not
  cut (no `_truncated` marker) and its size equals `result_bytes`. A call without a readable text is counted
  under `unreadable` and takes no part in the sizes.
- Attention body: the lines after `== Attention Required` while they are item lines (`  [!] `, `  [~] ` or
  `  [i] `) or action lines (`      -> `). Before the change they come in pairs, an item line and its action line.
  A text whose body is not pairs is counted under `not_split` and takes no part in the sizes.
- run: neighbouring items that suggest the same action.
- regrouped: the text `Dashboard_attention.format_items` gives after the change (lib/dashboard/dashboard_attention.ml).
  `regroup` ports it onto the stored text: the item lines of a run, then one action line, with
  `(<n> items above)` appended when the run has more than one item.
- held item: an attention line `  [~] task-N · <title>: held by <owner>, which has no Keeper queue`
  (lib/operator_task_attention.ml `summary`). repeated title bytes: the UTF-8 size of the `<title>` of the held
  items whose title the `== Tasks` section prints again. The change does not touch them.
- window bytes: the sum of `result_bytes` over every `tool_call` line of the window, any tool.
- p50: the element at index floor(0.5 * (n - 1)) of the sorted values.

Usage:
    python3 docs/evidence/dashboard-attention-2026-11/measure_dashboard_attention.py \
        --base-path ~/me --since 2026-11-03T00:00:00 --until 2026-11-07T15:00:00 \
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
TOOL = "masc_dashboard"
LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
TRUNCATED_KEY = "_truncated"
ATTENTION_HEADER = "== Attention Required"
TASKS_HEADER = "== Tasks"
SECTION_PREFIX = "== "
SEPARATOR_PREFIX = "---"
ITEM_LINE = re.compile(r"^  \[[!~i]\] ")
ACTION_PREFIX = "      -> "
HELD_ITEM = re.compile(r"^  \[~\] task-[0-9]+ · (?P<title>.+): held by ")
GROUPED_ACTION = re.compile(r"^(?P<action>.*?)(?: \((?P<count>[0-9]+) items above\))?$")
# Inline ceiling of a tool result per lane, lib/runtime/runtime_execution.ml:85-91 and lib/core/common.ml:217,235.
CEILINGS = (("16384", 16_384), ("32768", 32_768), ("65536", 65_536))
UTC = datetime.timezone.utc
Json = dict[str, object]


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    keeper: str
    result_bytes: int
    text: str | None
    unreadable: str


@dataclasses.dataclass(frozen=True, slots=True)
class Item:
    line: str
    action: str


@dataclasses.dataclass(frozen=True, slots=True)
class Section:
    """A dashboard text cut around the body of its Attention section."""

    head: tuple[str, ...]
    items: tuple[Item, ...]
    tail: tuple[str, ...]


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


def text_of(output: object, result_bytes: int, blob_root: pathlib.Path) -> tuple[str | None, str]:
    """The whole dashboard text a ledger `output` stands for, or None with the reason it cannot be read."""
    if isinstance(output, dict):
        blob = cast("Json", output).get("_blob")
        sha = cast("Json", blob).get("sha256") if isinstance(blob, dict) else None
        if not isinstance(sha, str) or len(sha) < 2:
            return None, "no_blob_sha"
        path = blob_root / sha[:2] / sha
        if not path.is_file():
            return None, "blob_missing"
        return path.read_text(encoding="utf-8", errors="replace"), ""
    if isinstance(output, str):
        if TRUNCATED_KEY in output or len(output.encode("utf-8")) != result_bytes:
            return None, "cut_excerpt"
        return output, ""
    return None, "no_output"


def split_section(text: str) -> Section | str:
    """The Attention section of a dashboard text, or the reason it cannot be cut."""
    lines = text.split("\n")
    header = next((i for i, line in enumerate(lines) if line.startswith(ATTENTION_HEADER)), None)
    if header is None:
        return "no_attention_section"
    end = header + 1
    while end < len(lines) and (ITEM_LINE.match(lines[end]) or lines[end].startswith(ACTION_PREFIX)):
        end += 1
    body = lines[header + 1 : end]
    if len(body) % 2:
        return "body_not_pairs"
    items: list[Item] = []
    for index in range(0, len(body), 2):
        item_line, action_line = body[index], body[index + 1]
        if not ITEM_LINE.match(item_line) or not action_line.startswith(ACTION_PREFIX):
            return "body_not_pairs"
        items.append(Item(item_line, action_line[len(ACTION_PREFIX) :]))
    return Section(tuple(lines[: header + 1]), tuple(items), tuple(lines[end:]))


def runs_of(items: Sequence[Item]) -> list[list[Item]]:
    """Port of the fold in `format_items`: runs of neighbouring items with the same action, in order."""
    runs: list[list[Item]] = []
    for item in items:
        if runs and runs[-1][0].action == item.action:
            runs[-1].append(item)
        else:
            runs.append([item])
    return runs


def render(items: Sequence[Item]) -> list[str]:
    lines: list[str] = []
    for run in runs_of(items):
        lines.extend(item.line for item in run)
        action = run[0].action
        lines.append(f"{ACTION_PREFIX}{action} ({len(run)} items above)" if len(run) > 1 else f"{ACTION_PREFIX}{action}")
    return lines


def regroup(section: Section) -> str:
    """Port of `format_items` onto the Attention section of a stored dashboard text."""
    return "\n".join([*section.head, *render(section.items), *section.tail])


def original(section: Section) -> str:
    """The text a section was cut from."""
    body = [line for item in section.items for line in (item.line, f"{ACTION_PREFIX}{item.action}")]
    return "\n".join([*section.head, *body, *section.tail])


def runs_are_closed(body: Sequence[str], items: Sequence[Item]) -> bool:
    """Each action line closes the item lines since the previous one, names their action, states their number
    when it is more than one, and differs from the action of the run before it."""
    start = 0
    count = 0
    previous: str | None = None
    for line in body:
        if ITEM_LINE.match(line):
            count += 1
            continue
        parsed = GROUPED_ACTION.match(line[len(ACTION_PREFIX) :]) if line.startswith(ACTION_PREFIX) else None
        if parsed is None or count == 0 or parsed["action"] == previous:
            return False
        stated = parsed["count"]
        if (stated is None) != (count == 1) or (stated is not None and int(stated) != count):
            return False
        if any(item.action != parsed["action"] for item in items[start : start + count]):
            return False
        previous = parsed["action"]
        start += count
        count = 0
    return count == 0 and start == len(items)


def checks_hold(text: str, section: Section, after: str) -> dict[str, bool]:
    """What must stay true of one regrouped text."""
    after_lines = after.split("\n")
    tail_start = len(after_lines) - len(section.tail)
    body = after_lines[len(section.head) : tail_start]
    return {
        "split_round_trips": original(section) == text,
        "item_lines_kept_in_order": [line for line in body if ITEM_LINE.match(line)] == [item.line for item in section.items],
        "every_run_closed_by_one_action_line": runs_are_closed(body, section.items),
        "text_outside_the_body_unchanged": after_lines[: len(section.head)] == list(section.head) and after_lines[tail_start:] == list(section.tail),
        "not_longer": len(after.encode("utf-8")) <= len(text.encode("utf-8")),
    }


def held_titles(text: str) -> list[str]:
    """The titles of the held items of the Attention section, in order."""
    return [held["title"] for line in text.split("\n") if (held := HELD_ITEM.match(line))]


def tasks_section(text: str) -> str:
    """The lines under `== Tasks`, up to the next section header or separator."""
    lines = text.split("\n")
    start = next((i for i, line in enumerate(lines) if line.startswith(TASKS_HEADER)), None)
    if start is None:
        return ""
    end = start + 1
    while end < len(lines) and not lines[end].startswith((SECTION_PREFIX, SEPARATOR_PREFIX)):
        end += 1
    return "\n".join(lines[start + 1 : end])


def repeated_title_bytes(text: str) -> int:
    """UTF-8 bytes of the held item titles that the Tasks section prints again."""
    tasks = tasks_section(text)
    return sum(len(title.encode("utf-8")) for title in held_titles(text) if title in tasks)


def read_calls(paths: Sequence[pathlib.Path], since: float, until: float, blob_root: pathlib.Path) -> Iterator[Call]:
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                if b'"masc_dashboard"' not in raw:
                    continue
                try:
                    row = cast("object", json.loads(raw))
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                fields = cast("Json", row)
                if fields.get("record_kind") != RECORD_KIND or fields.get("tool") != TOOL:
                    continue
                stamp = fields.get("ts")
                if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not since <= float(stamp) < until:
                    continue
                size = fields.get("result_bytes")
                keeper = fields.get("keeper")
                result_bytes = size if isinstance(size, int) and not isinstance(size, bool) else 0
                text, reason = text_of(fields.get("output"), result_bytes, blob_root)
                yield Call(keeper=keeper if isinstance(keeper, str) else "", result_bytes=result_bytes, text=text, unreadable=reason)


def window_bytes(paths: Sequence[pathlib.Path], since: float, until: float) -> int:
    """The sum of `result_bytes` over every `tool_call` line of the window, any tool."""
    total = 0
    for path in paths:
        with path.open("rb") as handle:
            for raw in handle:
                if b'"result_bytes"' not in raw:
                    continue
                try:
                    row = cast("object", json.loads(raw))
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                fields = cast("Json", row)
                stamp = fields.get("ts")
                size = fields.get("result_bytes")
                if fields.get("record_kind") != RECORD_KIND or isinstance(stamp, bool) or not isinstance(stamp, (int, float)):
                    continue
                if since <= float(stamp) < until and isinstance(size, int) and not isinstance(size, bool):
                    total += size
    return total


def spread(values: Sequence[int]) -> dict[str, int]:
    ordered = sorted(values)
    if not ordered:
        return {"min": 0, "p50": 0, "max": 0}
    return {"min": ordered[0], "p50": ordered[(len(ordered) - 1) // 2], "max": ordered[-1]}


def summarize(calls: Iterator[Call]) -> Json:
    total = 0
    unreadable: Counter[str] = Counter()
    not_split: Counter[str] = Counter()
    keepers: Counter[str] = Counter()
    before_sizes: list[int] = []
    after_sizes: list[int] = []
    item_counts: list[int] = []
    run_counts: list[int] = []
    held_counts: list[int] = []
    repeated: list[int] = []
    failed: Counter[str] = Counter()
    above_before = {name: 0 for name, _ in CEILINGS}
    above_after = {name: 0 for name, _ in CEILINGS}
    above_ledger = {name: 0 for name, _ in CEILINGS}
    for call in calls:
        total += 1
        keepers[call.keeper] += 1
        for name, ceiling in CEILINGS:
            above_ledger[name] += call.result_bytes > ceiling
        if call.text is None:
            unreadable[call.unreadable] += 1
            continue
        section = split_section(call.text)
        if isinstance(section, str):
            not_split[section] += 1
            continue
        after = regroup(section)
        before_sizes.append(len(call.text.encode("utf-8")))
        after_sizes.append(len(after.encode("utf-8")))
        item_counts.append(len(section.items))
        run_counts.append(len(runs_of(section.items)))
        held_counts.append(len(held_titles(call.text)))
        repeated.append(repeated_title_bytes(call.text))
        for name, held in checks_hold(call.text, section, after).items():
            if not held:
                failed[name] += 1
        for name, ceiling in CEILINGS:
            above_before[name] += before_sizes[-1] > ceiling
            above_after[name] += after_sizes[-1] > ceiling
    return {
        "calls": total,
        "keepers": dict(keepers.most_common()),
        "unreadable": dict(sorted(unreadable.items())),
        "not_split": dict(sorted(not_split.items())),
        "measured_calls": len(before_sizes),
        "bytes_before": {"sum": sum(before_sizes), **spread(before_sizes)},
        "bytes_after": {"sum": sum(after_sizes), **spread(after_sizes)},
        "attention_items": spread(item_counts),
        "attention_runs": spread(run_counts),
        "held_items": spread(held_counts),
        "repeated_title_bytes": spread(repeated),
        "above_ceiling_before": above_before,
        "above_ceiling_after": above_after,
        "above_ceiling_by_ledger_result_bytes": above_ledger,
        "checks_failed": dict(sorted(failed.items())),
    }


def parse_instant(text: str) -> datetime.datetime:
    parsed = datetime.datetime.fromisoformat(text)
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", type=parse_instant, required=True)
    parser.add_argument("--until", type=parse_instant, required=True)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    base = cast("pathlib.Path", args.base_path).expanduser()
    since = cast("datetime.datetime", args.since)
    until = cast("datetime.datetime", args.until)
    paths = ledger_files(base, since, until)
    calls = read_calls(paths, since.timestamp(), until.timestamp(), base / ".masc" / "tool_blobs")
    summary = summarize(calls)
    summary["window_result_bytes_any_tool"] = window_bytes(paths, since.timestamp(), until.timestamp())
    summary["window"] = {"since": since.isoformat(), "until": until.isoformat(), "ledger_files": len(paths)}
    text = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
