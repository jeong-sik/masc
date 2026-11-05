#!/usr/bin/env python3
"""Replay a trim of the DOS `screen_text` page over the stored requests.

The DOS tools (`masc_dos_*`) return `screen_text`, the 80x25 text page, padded with
spaces to 25 rows of 80 columns. A game that draws in a graphics mode leaves that page
blank, and the page then goes into every request that carries the result. This script
counts what the stored requests carried for the page, and what they would have carried
if each row had lost its trailing spaces and the page its trailing empty rows. It reads
the stores `measure_tool_result_carry.py` reads and never writes to them.

Definitions (a stored request, a tool message, carried, the ledger lookup of the tool
name) are those of `measure_tool_result_carry.py`. In addition:

- DOS result: a `tool_result` block whose ledger tool starts with `masc_dos_` and whose
  text is a JSON object with a string `screen_text`. The text is the block's `content`
  when that is a string, or the first string `text` of `content` when it is a list.
- trimmed page: the page with the trailing spaces of every row removed, and then the
  empty rows at its end removed. Rows keep their position, so an empty row before the
  last non-empty row stays. Rows are separated by "\\n".
- page bytes: the bytes the page takes inside the request body: the JSON text of the
  page, escaped once more because the result text is a JSON string inside the message,
  without the quotes of that string. A trimmed page is measured the same way.
- blank page: a page of spaces and newlines only.
- content bytes: the length of the block's `content` as compact JSON, which is what a
  request carries of the result. The stored copy (`text_content`) is not counted.
- carried: bytes of one distinct result times the stored requests that list its message.
- saved bytes: carried page bytes minus carried trimmed page bytes.

The script also checks that the trim loses no character other than a space or a newline
(`changed_pages`, expected 0), and reports the `files` field, which every observation
repeats, without trimming it.

Usage:
    docs/evidence/tool-result-carry-2026-11/measure_dos_screen_trim.py \\
        --base-path ~/me --from-date 2026-10-29 --to-date 2026-11-04 --json-out result.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import sys
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_tool_result_carry as carry  # noqa: E402

DOS_TOOL_PREFIX = "masc_dos_"
PAGE_FIELD = "screen_text"
FILES_FIELD = "files"
VIDEO_MODE_FIELD = "video_mode"
NO_MODE = "<none>"
PAD = " "
ROW_SEPARATOR = "\n"


@dataclasses.dataclass(frozen=True, slots=True)
class Page:
    bytes: int
    trimmed_bytes: int
    blank: bool
    changed: bool


@dataclasses.dataclass(frozen=True, slots=True)
class DosResult:
    tool_use_id: str | None
    content_bytes: int
    page: Page
    video_mode: str
    files_bytes: int
    files_key: str | None


@dataclasses.dataclass(slots=True)
class ToolTotals:
    results: int = 0
    blank_pages: int = 0
    changed_pages: int = 0
    carried_results: int = 0
    content_bytes: int = 0
    page_bytes: int = 0
    trimmed_page_bytes: int = 0
    files_bytes: int = 0


@dataclasses.dataclass(frozen=True, slots=True)
class ToolRow:
    tool: str
    results: int
    blank_pages: int
    changed_pages: int
    carried_results: int
    content_bytes: int
    page_bytes: int
    trimmed_page_bytes: int
    files_bytes: int

    @property
    def saved_bytes(self) -> int:
        return self.page_bytes - self.trimmed_page_bytes


@dataclasses.dataclass(frozen=True, slots=True)
class Summary:
    messages: int
    rows: tuple[ToolRow, ...]
    video_modes: tuple[tuple[str, int, int], ...]  # mode, results, blank pages
    files_lists: int
    unattributed_pages: int

    @property
    def results(self) -> int:
        return sum(row.results for row in self.rows)

    @property
    def blank_pages(self) -> int:
        return sum(row.blank_pages for row in self.rows)

    @property
    def changed_pages(self) -> int:
        return sum(row.changed_pages for row in self.rows)

    @property
    def carried_results(self) -> int:
        return sum(row.carried_results for row in self.rows)

    @property
    def content_bytes(self) -> int:
        return sum(row.content_bytes for row in self.rows)

    @property
    def page_bytes(self) -> int:
        return sum(row.page_bytes for row in self.rows)

    @property
    def trimmed_page_bytes(self) -> int:
        return sum(row.trimmed_page_bytes for row in self.rows)

    @property
    def saved_bytes(self) -> int:
        return self.page_bytes - self.trimmed_page_bytes

    @property
    def files_bytes(self) -> int:
        return sum(row.files_bytes for row in self.rows)


def trim_text_page(page: str) -> str:
    rows = [row.rstrip(PAD) for row in page.split(ROW_SEPARATOR)]
    while rows and rows[-1] == "":
        rows.pop()
    return ROW_SEPARATOR.join(rows)


def _compact(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _compact_length(value: object) -> int:
    return len(_compact(value).encode("utf-8"))


def _body_bytes(value: object) -> int:
    """Bytes a field value takes inside the request body.

    The result text holds the field as JSON, and the message holds that text as a JSON
    string, so the value's JSON is escaped once more. The quotes of that string are not counted.
    """
    inner = _compact(value)
    return len(json.dumps(inner, ensure_ascii=False).encode("utf-8")) - 2


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


def measure_page(page: str) -> Page:
    trimmed = trim_text_page(page)
    padding = (ROW_SEPARATOR, PAD)
    original_content = "".join(ch for ch in page if ch not in padding)
    trimmed_content = "".join(ch for ch in trimmed if ch not in padding)
    return Page(
        bytes=_body_bytes(page),
        trimmed_bytes=_body_bytes(trimmed),
        blank=original_content == "",
        changed=original_content != trimmed_content,
    )


def inspect_message(raw: bytes) -> list[DosResult]:
    """The results of one stored tool message that carry a page. Raises ValueError when the blob is not a message."""
    decoded: object = json.loads(raw)  # JSONDecodeError and UnicodeDecodeError are ValueErrors
    if not isinstance(decoded, dict):
        raise ValueError("not a JSON object")
    blocks = cast(dict[str, object], decoded).get("content_blocks")
    found: list[DosResult] = []
    if not isinstance(blocks, list):
        return found
    for block in cast(list[object], blocks):
        if not isinstance(block, dict):
            continue
        fields = cast(dict[str, object], block)
        if fields.get("type") != "tool_result":
            continue
        text = _result_text(fields.get("content"))
        if text is None:
            continue
        try:
            document: object = json.loads(text)
        except ValueError:
            continue
        if not isinstance(document, dict):
            continue
        observation = cast(dict[str, object], document)
        page = observation.get(PAGE_FIELD)
        if not isinstance(page, str):
            continue
        tool_use_id = fields.get("tool_use_id")
        mode = observation.get(VIDEO_MODE_FIELD)
        files = observation.get(FILES_FIELD)
        found.append(
            DosResult(
                tool_use_id=tool_use_id if isinstance(tool_use_id, str) else None,
                content_bytes=_compact_length(fields.get("content")),
                page=measure_page(page),
                video_mode=mode if isinstance(mode, str) else NO_MODE,
                files_bytes=_body_bytes(files) if isinstance(files, list) else 0,
                files_key=_compact(files) if isinstance(files, list) else None,
            )
        )
    return found


def summarize(
    masc_dir: pathlib.Path,
    carried: carry.Carried,
    tool_names: dict[str, str],
    skipped: carry.Skipped,
) -> Summary:
    totals: dict[str, ToolTotals] = {}
    modes: dict[str, list[int]] = {}
    files_lists: set[str] = set()
    messages = 0
    unattributed = 0
    for sha, count in carried.carriers.items():
        try:
            raw = (masc_dir / "tool_blobs" / sha[:2] / sha).read_bytes()
        except OSError:
            skipped.unreadable_blobs += 1
            continue
        try:
            results = inspect_message(raw)
        except ValueError:
            skipped.invalid_blobs += 1
            continue
        messages += 1
        if carried.recorded_bytes[sha] != len(raw):
            skipped.size_disagreements += 1
        for result in results:
            tool = tool_names.get(result.tool_use_id, carry.UNMAPPED) if result.tool_use_id is not None else carry.UNMAPPED
            if not tool.startswith(DOS_TOOL_PREFIX):
                if tool == carry.UNMAPPED:
                    unattributed += 1
                continue
            row = totals.setdefault(tool, ToolTotals())
            row.results += 1
            row.carried_results += count
            row.content_bytes += result.content_bytes * count
            row.page_bytes += result.page.bytes * count
            row.trimmed_page_bytes += result.page.trimmed_bytes * count
            row.files_bytes += result.files_bytes * count
            if result.page.blank:
                row.blank_pages += 1
            if result.page.changed:
                row.changed_pages += 1
            mode = modes.setdefault(result.video_mode, [0, 0])
            mode[0] += 1
            mode[1] += 1 if result.page.blank else 0
            if result.files_key is not None:
                files_lists.add(result.files_key)
    rows = [
        ToolRow(
            tool=tool,
            results=row.results,
            blank_pages=row.blank_pages,
            changed_pages=row.changed_pages,
            carried_results=row.carried_results,
            content_bytes=row.content_bytes,
            page_bytes=row.page_bytes,
            trimmed_page_bytes=row.trimmed_page_bytes,
            files_bytes=row.files_bytes,
        )
        for tool, row in totals.items()
    ]
    rows.sort(key=lambda row: (-row.content_bytes, row.tool))
    video_modes = tuple(sorted(((mode, seen[0], seen[1]) for mode, seen in modes.items()), key=lambda item: (-item[1], item[0])))
    return Summary(
        messages=messages,
        rows=tuple(rows),
        video_modes=video_modes,
        files_lists=len(files_lists),
        unattributed_pages=unattributed,
    )


def _pct(part: int, whole: int) -> float:
    return 100 * part / whole if whole else 0.0


def to_json(
    from_day: str, to_day: str, carried: carry.Carried, summary: Summary, skipped: carry.Skipped
) -> dict[str, object]:
    return {
        "window": {"from": from_day, "to": to_day},
        "stored_requests": carried.requests,
        "body_bytes": carried.body_bytes,
        "tool_messages": summary.messages,
        "dos_results": summary.results,
        "dos_carried_results": summary.carried_results,
        "blank_pages": summary.blank_pages,
        "changed_pages": summary.changed_pages,
        "content_bytes": summary.content_bytes,
        "page_bytes": summary.page_bytes,
        "trimmed_page_bytes": summary.trimmed_page_bytes,
        "saved_bytes": summary.saved_bytes,
        "files_bytes": summary.files_bytes,
        "files_distinct_lists": summary.files_lists,
        "unattributed_pages": summary.unattributed_pages,
        "tools": [{**dataclasses.asdict(row), "saved_bytes": row.saved_bytes} for row in summary.rows],
        "video_modes": [
            {"video_mode": mode, "results": results, "blank_pages": blank} for mode, results, blank in summary.video_modes
        ],
        "skipped": dataclasses.asdict(skipped),
    }


def _print_report(
    from_day: str, to_day: str, carried: carry.Carried, summary: Summary, skipped: carry.Skipped
) -> None:
    body = carried.body_bytes
    content = summary.content_bytes
    print(f"window {from_day} ~ {to_day}: stored requests {carried.requests}, body {body / 1e9:.3f} GB")
    print(
        f"DOS results with a page: {summary.results} distinct, carried {summary.carried_results} times, "
        f"{content / 1e9:.3f} GB of content ({_pct(content, body):.1f}% of body)"
    )
    print(
        f"  pages: {summary.blank_pages} of {summary.results} blank; page bytes carried {summary.page_bytes / 1e9:.3f} GB "
        f"({_pct(summary.page_bytes, content):.1f}% of DOS content, {_pct(summary.page_bytes, body):.1f}% of body)"
    )
    print(
        f"  after the trim: {summary.trimmed_page_bytes / 1e9:.6f} GB; saved {summary.saved_bytes / 1e9:.3f} GB "
        f"({_pct(summary.saved_bytes, content):.1f}% of DOS content, {_pct(summary.saved_bytes, body):.2f}% of body)"
    )
    print(
        f"  pages the trim would change beyond spaces and newlines: {summary.changed_pages}; "
        f"files field carried {summary.files_bytes / 1e9:.3f} GB ({_pct(summary.files_bytes, content):.1f}% of DOS content), "
        f"{summary.files_lists} distinct lists"
    )
    reasons = ", ".join(f"{name} {value}" for name, value in dataclasses.asdict(skipped).items() if value)
    print(f"skipped: {reasons or 'none'}; results with a page whose tool is unknown: {summary.unattributed_pages}")
    print()
    print(f"{'tool':22} {'results':>8} {'blank':>6} {'content_GB':>10} {'page_GB':>8} {'saved_GB':>9} {'saved%':>7}")
    for row in summary.rows:
        print(
            f"{row.tool[:22]:22} {row.results:8d} {row.blank_pages:6d} {row.content_bytes / 1e9:10.3f} "
            f"{row.page_bytes / 1e9:8.3f} {row.saved_bytes / 1e9:9.3f} {_pct(row.saved_bytes, row.content_bytes):7.1f}"
        )
    print()
    print(f"{'video mode':12} {'results':>8} {'blank pages':>12}")
    for mode, results, blank in summary.video_modes:
        print(f"{mode:12} {results:8d} {blank:12d}")


def _day_argument(text: str) -> str:
    if not carry.DAY_PATTERN.fullmatch(text):
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
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    if args.from_date > args.to_date:
        parser.error("--from-date is after --to-date")
    masc_dir = args.base_path.expanduser() / ".masc"
    if not masc_dir.is_dir():
        print(f"error: {masc_dir} is not a directory", file=sys.stderr)
        return 2
    skipped = carry.Skipped()
    carried = carry.read_carried(masc_dir, args.from_date, args.to_date, skipped)
    if carried.requests == 0:
        print("error: no stored request in the window", file=sys.stderr)
        return 2
    tool_names = carry.read_tool_names(masc_dir, args.from_date, args.to_date, skipped)
    summary = summarize(masc_dir, carried, tool_names, skipped)
    if not summary.rows:
        print("error: no DOS result with a page in the window", file=sys.stderr)
        return 2
    _print_report(args.from_date, args.to_date, carried, summary, skipped)
    if args.json_out is not None:
        payload = to_json(args.from_date, args.to_date, carried, summary, skipped)
        args.json_out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
