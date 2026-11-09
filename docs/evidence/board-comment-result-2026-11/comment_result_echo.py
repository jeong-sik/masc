#!/usr/bin/env python3
"""masc_board_comment answers: how much of an answer repeats the text just written, and whether the writer reads the thread again.

A writer sends the comment text in the call, so the call is already in its context. An answer that
carries the text back puts the same bytes in the context twice. This script counts, in the tool-call
ledger, how many bytes of the answers of successful `masc_board_comment` calls are the written text, and
how often the same Keeper reads the thread of that post right after the write (a Keeper that cannot see
what it wrote may read it back). Run it for a span before the answer stopped carrying the text and for a
span after, and compare the two rows.

Reads, and never writes, the tool-call ledger files `<base>/.masc/tool_calls/YYYY-MM/*.jsonl`.

Definitions:

- successful call: a `masc_board_comment` ledger line whose `disposition` is not `failed` and whose
  output does not start with `Your call to "` (the refusal the tool layer writes for arguments that do
  not match the schema; it repeats the arguments, so it is counted apart as `refused`).
- written text: the `body` of the call's `input` when it is a string, else its `content`; the order the
  tool reads them in. An input that is not an object, or has neither, has no written text.
- repeated bytes: the UTF-8 length of the written text as JSON string content (escaped, quotes left
  off) when that text occurs in the answer, else 0. A text shorter than `MIN_TEXT_BYTES` is not counted,
  so a one-word comment that happens to occur in a field name is not a repeat.
- cut short: the answer is a JSON object with a `_truncated` member, which is how the tool output
  boundary marks an answer it cut.
- read after the write: the same Keeper's next ledger call, no later than `--reread-s` seconds after the
  write began (`ts` is the start of a call), is `masc_board_post_get` whose `input.post_id` is the post
  the comment went to.

Usage:
    python3 docs/evidence/board-comment-result-2026-11/comment_result_echo.py \
        --base-path ~/me --since 2026-11-02T00:00:00 --end 2026-11-09T09:00:00 \
        --json-out docs/evidence/board-comment-result-2026-11/result-before-2026-11-02_11-09.json
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import re
import statistics
import sys
from collections import defaultdict
from collections.abc import Sequence
from typing import cast

UTC = datetime.timezone.utc
COMMENT_TOOL = "masc_board_comment"
POST_GET_TOOL = "masc_board_post_get"
REFUSAL_PREFIX = 'Your call to "'
MIN_TEXT_BYTES = 40
MAX_DAYS = 31
SHARE_DIGITS = 4
LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
DEFAULT_REREAD_S = 60.0


def parse_instant(text: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=UTC)


def stamp(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch, UTC).isoformat()


def ledger_files(base: pathlib.Path, since: datetime.datetime, until: datetime.datetime) -> list[pathlib.Path]:
    """The ledger files of each UTC day the span touches, in name order."""
    paths: list[pathlib.Path] = []
    day = since.date()
    while day <= until.date():
        folder = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
        if folder.is_dir():
            paths.extend(sorted(p for p in folder.iterdir() if (m := LEDGER_FILE.match(p.name)) and int(m["day"]) == day.day))
        day += datetime.timedelta(days=1)
    return paths


def text_of(value: object) -> str:
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def written_text(input_value: object) -> str | None:
    """The text a `masc_board_comment` input writes: `body` when a string, else `content`."""
    if isinstance(input_value, str):
        try:
            input_value = cast("object", json.loads(input_value))
        except ValueError:
            return None
    if not isinstance(input_value, dict):
        return None
    fields = cast("dict[str, object]", input_value)
    for name in ("body", "content"):
        value = fields.get(name)
        if isinstance(value, str):
            return value
    return None


def post_id_of(input_value: object) -> str | None:
    if isinstance(input_value, str):
        try:
            input_value = cast("object", json.loads(input_value))
        except ValueError:
            return None
    if not isinstance(input_value, dict):
        return None
    post_id = cast("dict[str, object]", input_value).get("post_id")
    return post_id if isinstance(post_id, str) else None


def escaped(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)[1:-1]


def is_cut_short(answer: str) -> bool:
    try:
        parsed = cast("object", json.loads(answer))
    except ValueError:
        return False
    return isinstance(parsed, dict) and "_truncated" in parsed


class Row:
    """One ledger call, with only what this script reads."""

    __slots__ = ("ts", "tool", "failed", "answer", "text", "post_id")

    def __init__(self, ts: float, tool: str, failed: bool, answer: str, text: str | None, post_id: str | None) -> None:
        self.ts = ts
        self.tool = tool
        self.failed = failed
        self.answer = answer
        self.text = text
        self.post_id = post_id


def read_rows(paths: Sequence[pathlib.Path], since: float, until: float) -> dict[str, list[Row]]:
    """Calls by Keeper, each Keeper's calls in time order. Calls of other tools keep neither text nor answer."""
    by_keeper: dict[str, list[Row]] = defaultdict(list)
    for path in paths:
        with path.open("rb") as lines:
            for raw in lines:
                try:
                    row = cast("object", json.loads(raw))
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                fields = cast("dict[str, object]", row)
                ts = fields.get("ts")
                tool = fields.get("tool")
                keeper = fields.get("keeper")
                if fields.get("record_kind") != "tool_call" or isinstance(ts, bool) or not isinstance(ts, (int, float)):
                    continue
                if not isinstance(tool, str) or not isinstance(keeper, str) or not since <= ts < until:
                    continue
                input_value = fields.get("input")
                is_comment = tool == COMMENT_TOOL
                by_keeper[keeper].append(
                    Row(
                        ts=float(ts),
                        tool=tool,
                        failed=fields.get("disposition") == "failed",
                        answer=text_of(fields.get("output")) if is_comment else "",
                        text=written_text(input_value) if is_comment else None,
                        post_id=post_id_of(input_value) if tool in (COMMENT_TOOL, POST_GET_TOOL) else None,
                    )
                )
    for rows in by_keeper.values():
        rows.sort(key=lambda r: r.ts)
    return by_keeper


def measure(base: pathlib.Path, since: datetime.datetime, end: datetime.datetime, reread_s: float) -> dict[str, object]:
    by_keeper = read_rows(ledger_files(base, since, end), since.timestamp(), end.timestamp())
    answer_sizes: list[int] = []
    repeated_bytes = 0
    repeating_calls = 0
    cut_short = 0
    refused = 0
    failed = 0
    rereads = 0
    for rows in by_keeper.values():
        for index, call in enumerate(rows):
            if call.tool != COMMENT_TOOL:
                continue
            if call.failed:
                failed += 1
                continue
            if call.answer.startswith(REFUSAL_PREFIX):
                refused += 1
                continue
            answer_sizes.append(len(call.answer.encode("utf-8")))
            if is_cut_short(call.answer):
                cut_short += 1
            if call.text is not None and len(call.text.encode("utf-8")) >= MIN_TEXT_BYTES and escaped(call.text) in call.answer:
                repeated_bytes += len(escaped(call.text).encode("utf-8"))
                repeating_calls += 1
            following = rows[index + 1] if index + 1 < len(rows) else None
            if (
                following is not None
                and following.tool == POST_GET_TOOL
                and following.ts - call.ts <= reread_s
                and call.post_id is not None
                and following.post_id == call.post_id
            ):
                rereads += 1
    calls = len(answer_sizes)
    total = sum(answer_sizes)
    return {
        "window": {"since": stamp(since.timestamp()), "end": stamp(end.timestamp())},
        "successful_calls": calls,
        "failed_calls": failed,
        "refused_calls": refused,
        "answer_bytes": total,
        "answer_bytes_median": int(statistics.median(answer_sizes)) if answer_sizes else None,
        "repeated_text_bytes": repeated_bytes,
        "repeated_text_share": round(repeated_bytes / total, SHARE_DIGITS) if total else None,
        "calls_repeating_text": repeating_calls,
        "answers_cut_short": cut_short,
        "read_after_write": {
            "within_s": reread_s,
            "calls": rereads,
            "share": round(rereads / calls, SHARE_DIGITS) if calls else None,
        },
    }


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="UTC, like 2026-11-02T00:00:00")
    parser.add_argument("--end", required=True, help="UTC, like 2026-11-09T09:00:00")
    parser.add_argument("--reread-s", type=float, default=DEFAULT_REREAD_S)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since = parse_instant(cast("str", args.since))
    end = parse_instant(cast("str", args.end))
    if end <= since:
        print("--end must come after --since", file=sys.stderr)
        return 2
    if end - since > datetime.timedelta(days=MAX_DAYS):
        print(f"the span must stay within {MAX_DAYS} days", file=sys.stderr)
        return 2
    result = measure(cast("pathlib.Path", args.base_path).expanduser(), since, end, cast("float", args.reread_s))
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
