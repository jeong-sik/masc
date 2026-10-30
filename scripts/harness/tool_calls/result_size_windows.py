#!/usr/bin/env python3
"""Read tool-call ledger rows and print one numeric result-size table.

No result object or blob is opened. The only output-body inspection is a
prefix check for the server's blob marker. Windows are UTC half-open ranges.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import datetime as dt
import json
from pathlib import Path
import sys

BLOB_MARKER = "[masc:blob sha256="
CEILINGS = (16_384, 32_768)
UNMEASURED = "unmeasured"


class InputError(ValueError):
    pass


@dataclass(frozen=True)
class Window:
    label: str
    start: dt.datetime
    end: dt.datetime
    only: str | None = None
    exclude: str | None = None

    def covers(self, tool: str, ts: float) -> bool:
        return (
            self.start.timestamp() <= ts < self.end.timestamp()
            and (self.only is None or tool == self.only)
            and (self.exclude is None or tool != self.exclude)
        )


def utc(text: str) -> dt.datetime:
    try:
        value = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as exc:
        raise InputError(f"invalid timestamp: {text!r}") from exc
    if value.tzinfo is None:
        raise InputError(f"timestamp needs a timezone: {text!r}")
    return value.astimezone(dt.timezone.utc)


def parse_window(spec: str) -> Window:
    parts = spec.split(",")
    if len(parts) not in (3, 4):
        raise InputError("window needs LABEL,START,END[,only=TOOL|except=TOOL]")
    label, start_text, end_text = (part.strip() for part in parts[:3])
    if not label:
        raise InputError("window label is empty")
    start, end = utc(start_text), utc(end_text)
    if end <= start:
        raise InputError("window end must follow start")
    only = exclude = None
    if len(parts) == 4:
        key, separator, tool = parts[3].partition("=")
        if not separator or not tool:
            raise InputError("window filter needs only=TOOL or except=TOOL")
        if key == "only":
            only = tool
        elif key == "except":
            exclude = tool
        else:
            raise InputError(f"unknown window filter: {key}")
    return Window(label, start, end, only, exclude)


def ledger_files(directory: Path, windows: list[Window]) -> list[Path]:
    days: set[dt.date] = set()
    for window in windows:
        day = window.start.date()
        # The end is exclusive. A midnight end does not require that day's file.
        last = (window.end - dt.timedelta(microseconds=1)).date()
        while day <= last:
            days.add(day)
            day += dt.timedelta(days=1)
    return [
        directory / f"{day:%Y-%m}" / f"{day:%d}.jsonl"
        for day in sorted(days)
    ]


@dataclass
class Cell:
    calls: int = 0
    buckets: list[int] = field(default_factory=lambda: [0, 0, 0])
    missing_size: int = 0
    inline: int = 0
    server_stored: int = 0
    missing_output: int = 0
    handler_stored: int = 0
    projection_stored: int = 0
    missing_path: int = 0


def bucket(size: int) -> int:
    if size <= CEILINGS[0]:
        return 0
    if size <= CEILINGS[1]:
        return 1
    return 2


def nonnegative_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def count(directory: Path, windows: list[Window]) -> dict[tuple[str, str, str, str], Cell]:
    cells: dict[tuple[str, str, str, str], Cell] = {}
    for path in ledger_files(directory, windows):
        if not path.is_file():
            raise InputError(f"missing ledger day: {path}")
        with path.open(encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise InputError(f"invalid ledger row: {path}:{number}") from exc
                if not isinstance(row, dict):
                    raise InputError(f"non-object ledger row: {path}:{number}")
                if row.get("record_kind") != "tool_call":
                    continue
                ts = row.get("ts")
                if isinstance(ts, bool) or not isinstance(ts, (int, float)):
                    raise InputError(f"tool row has no numeric ts: {path}:{number}")
                tool = row.get("tool")
                if not isinstance(tool, str) or not tool:
                    raise InputError(f"tool row has no tool: {path}:{number}")
                lane = row.get("lane")
                lane = lane if isinstance(lane, str) and lane else "<missing>"
                runtime = row.get("runtime_profile")
                runtime = runtime if isinstance(runtime, str) and runtime else "<missing>"
                output = row.get("output")
                stored = (
                    isinstance(output, dict) and isinstance(output.get("_blob"), dict)
                ) or (isinstance(output, str) and output.startswith(BLOB_MARKER))
                inline = isinstance(output, str) and not stored
                evidence = row.get("execution_evidence")
                evidence = evidence if isinstance(evidence, dict) else {}
                for window in windows:
                    if not window.covers(tool, float(ts)):
                        continue
                    cell = cells.setdefault((window.label, tool, lane, runtime), Cell())
                    cell.calls += 1
                    if stored:
                        cell.server_stored += 1
                    elif inline:
                        cell.inline += 1
                    else:
                        cell.missing_output += 1
                    if tool == "Execute":
                        size = nonnegative_int(evidence.get("compared_output_bytes"))
                        handler = evidence.get("handler_stored")
                        if not isinstance(handler, bool):
                            cell.missing_path += 1
                        elif handler:
                            cell.handler_stored += 1
                        elif stored:
                            cell.projection_stored += 1
                    else:
                        size = nonnegative_int(row.get("result_bytes"))
                        if stored:
                            cell.projection_stored += 1
                    if size is None:
                        cell.missing_size += 1
                    else:
                        cell.buckets[bucket(size)] += 1
    return cells


def safe(text: str) -> str:
    return text.replace("|", "/").replace("\n", " ").replace("\r", " ")


def render(cells: dict[tuple[str, str, str, str], Cell], windows: list[Window]) -> str:
    columns = [
        "window", "start_utc", "end_utc", "tool", "lane", "runtime_profile",
        "calls", "<=16384", "16385-32768", ">32768", "missing_size",
        "inline", "server_stored", "missing_output", "handler_stored",
        "projection_stored", "missing_path",
    ]
    lines = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for window in windows:
        entries = [
            (key, value) for key, value in cells.items() if key[0] == window.label
        ]
        if not entries:
            entries = [((window.label, "<no calls>", "-", "-"), Cell())]
        for (_, tool, lane, runtime), cell in sorted(entries):
            if tool == "Execute" and cell.missing_size:
                sizes = [UNMEASURED] * 3
            else:
                sizes = [str(value) for value in cell.buckets]
            if tool == "Execute" and cell.missing_path:
                paths = [UNMEASURED, UNMEASURED]
            else:
                paths = [str(cell.handler_stored), str(cell.projection_stored)]
            values = [
                safe(window.label), window.start.strftime("%Y-%m-%dT%H:%M:%SZ"),
                window.end.strftime("%Y-%m-%dT%H:%M:%SZ"),
                safe(tool), safe(lane), safe(runtime), str(cell.calls),
                *sizes, str(cell.missing_size), str(cell.inline),
                str(cell.server_stored), str(cell.missing_output),
                *paths, str(cell.missing_path),
            ]
            lines.append("| " + " | ".join(values) + " |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--masc-dir", required=True, type=Path)
    parser.add_argument(
        "--window", action="append", required=True,
        help="LABEL,START,END[,only=TOOL|except=TOOL]",
    )
    args = parser.parse_args(argv)
    try:
        windows = [parse_window(spec) for spec in args.window]
        if len({window.label for window in windows}) != len(windows):
            raise InputError("window labels must be distinct")
        cells = count(args.masc_dir / "tool_calls", windows)
    except InputError as exc:
        print(exc, file=sys.stderr)
        return 2
    sys.stdout.write(render(cells, windows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
