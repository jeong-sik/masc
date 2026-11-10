#!/usr/bin/env python3
"""Compare the dashboard's persisted tool metrics with the tool-call ledger, per tool and UTC day.

Reads, and never writes:
  - `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>[.<NNN>].jsonl`, rows with `record_kind == "tool_call"`
    (fields used: `ts`, `tool`, `output`, `disposition`),
  - `<base-path>/.masc/tool-metrics.sqlite3`, table `tool_metric_events(ts, tool_name, disposition)`.

The ledger names tools the way a Keeper calls them (`Read`); the store names them the way dispatch does
(`tool_read_file`). `PUBLIC_TO_STORE` maps the spellings that differ. A ledger tool with no store name of
the same spelling and no entry there is listed under `unmapped_ledger_tools`, not dropped.

An argument refusal is a ledger row whose `output` is a string starting with `Your call to "` (Agent Core's
refusal text, `Tool_input_validation.format_errors_inline`). Agent Core refuses it before any handler runs, so
the row has no `disposition` and the call never reached the dispatch observers that write the store.

For each tool: `gap = ledger_calls - store_calls` and `gap_minus_refused = gap - ledger_refused`. Before the
change that makes a refused call reach the observers, `gap_minus_refused == 0` means the refusals are the whole
difference for that tool. After it, `gap == 0` is the expected value for those tools. The store also counts
calls the ledger does not hold (a client calling the MCP server), so a negative `gap_minus_refused` is
possible and means the store holds more than the ledger.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import json
import pathlib
import re
import sqlite3
import sys
from collections.abc import Iterator

REFUSAL_PREFIX = 'Your call to "'
LEDGER_FILE = re.compile(r"^[0-9]{2}(?:\.[0-9]{3})?\.jsonl$")
# Public names the ledger records that dispatch records under another name
# (`Keeper_tool_descriptor`: `~public_name` / `~internal_name`).
PUBLIC_TO_STORE = {
    "Execute": "tool_execute",
    "Grep": "tool_search_files",
    "Read": "tool_read_file",
    "Edit": "tool_edit_file",
    "Write": "tool_write_file",
    "WebSearch": "masc_web_search",
    "WebFetch": "masc_web_fetch",
    "BrowserTabs": "masc_browser_tabs",
    "BrowserRead": "masc_browser_read",
    "BrowserGoto": "masc_browser_goto",
    "BrowserAct": "masc_browser_act",
    "BrowserInteract": "masc_browser_interact",
}


@dataclasses.dataclass(frozen=True, slots=True)
class Cell:
    ledger_calls: int = 0
    ledger_refused: int = 0
    store_calls: int = 0
    store_failed: int = 0

    @property
    def gap(self) -> int:
        return self.ledger_calls - self.store_calls

    @property
    def gap_minus_refused(self) -> int:
        return self.gap - self.ledger_refused

    def plus(self, other: "Cell") -> "Cell":
        return Cell(
            self.ledger_calls + other.ledger_calls,
            self.ledger_refused + other.ledger_refused,
            self.store_calls + other.store_calls,
            self.store_failed + other.store_failed,
        )

    def to_json(self) -> dict[str, int]:
        return {
            "ledger_calls": self.ledger_calls,
            "ledger_refused": self.ledger_refused,
            "store_calls": self.store_calls,
            "store_failed": self.store_failed,
            "gap": self.gap,
            "gap_minus_refused": self.gap_minus_refused,
        }


def parse_utc(text: str) -> float:
    parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError(f"time needs an offset or Z: {text!r}")
    return parsed.timestamp()


def day_of(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%d")


def ledger_files(base_path: pathlib.Path, since: float, end: float) -> Iterator[pathlib.Path]:
    first = dt.datetime.fromtimestamp(since, dt.timezone.utc)
    last = dt.datetime.fromtimestamp(end, dt.timezone.utc)
    month, year = first.month, first.year
    while (year, month) <= (last.year, last.month):
        directory = base_path / ".masc" / "tool_calls" / f"{year:04d}-{month:02d}"
        if directory.is_dir():
            for path in sorted(directory.iterdir()):
                if LEDGER_FILE.match(path.name):
                    yield path
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)


def store_name(public: str) -> str:
    return PUBLIC_TO_STORE.get(public, public)


def read_ledger(base_path: pathlib.Path, since: float, end: float) -> dict[tuple[str, str], tuple[int, int]]:
    """(day, store tool name) -> (calls, refused)."""
    cells: dict[tuple[str, str], list[int]] = collections.defaultdict(lambda: [0, 0])
    for path in ledger_files(base_path, since, end):
        with path.open(encoding="utf-8", errors="replace") as lines:
            for line in lines:
                if '"tool_call"' not in line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = row.get("ts")
                tool = row.get("tool")
                if row.get("record_kind") != "tool_call" or not isinstance(ts, (int, float)) or not isinstance(tool, str):
                    continue
                if not since <= ts < end:
                    continue
                output = row.get("output")
                cell = cells[(day_of(ts), store_name(tool))]
                cell[0] += 1
                if isinstance(output, str) and output.startswith(REFUSAL_PREFIX) and row.get("disposition") is None:
                    cell[1] += 1
    return {key: (calls, refused) for key, (calls, refused) in cells.items()}


def open_store(base_path: pathlib.Path) -> sqlite3.Connection:
    path = base_path / ".masc" / "tool-metrics.sqlite3"
    if not path.is_file():
        raise SystemExit(f"no tool metrics store at {path}")
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def read_store(connection: sqlite3.Connection, since: float, end: float) -> dict[tuple[str, str], tuple[int, int]]:
    """(day, tool name) -> (calls, failed)."""
    cells: dict[tuple[str, str], tuple[int, int]] = {}
    rows = connection.execute(
        "SELECT strftime('%Y-%m-%d', ts, 'unixepoch'), tool_name, count(*),"
        " sum(CASE WHEN disposition = 'failed' THEN 1 ELSE 0 END)"
        " FROM tool_metric_events WHERE ts >= ? AND ts < ? GROUP BY 1, 2",
        (since, end),
    )
    for day, tool, calls, failed in rows:
        cells[(day, tool)] = (int(calls), int(failed))
    return cells


def compare(
    ledger: dict[tuple[str, str], tuple[int, int]],
    store: dict[tuple[str, str], tuple[int, int]],
) -> dict[str, object]:
    store_tools = {tool for _, tool in store}
    compared = {key: cell for key, cell in ledger.items() if key[1] in store_tools}
    unmapped: collections.Counter[str] = collections.Counter()
    for (_, tool), (calls, _) in ledger.items():
        if tool not in store_tools:
            unmapped[tool] += calls
    by_day_tool: dict[tuple[str, str], Cell] = {}
    for key in sorted(set(compared) | {key for key in store if key[1] in {t for _, t in compared}}):
        ledger_calls, refused = ledger.get(key, (0, 0))
        store_calls, store_failed = store.get(key, (0, 0))
        by_day_tool[key] = Cell(ledger_calls, refused, store_calls, store_failed)
    by_tool: dict[str, Cell] = collections.defaultdict(Cell)
    by_day: dict[str, Cell] = collections.defaultdict(Cell)
    for (day, tool), cell in by_day_tool.items():
        by_tool[tool] = by_tool[tool].plus(cell)
        by_day[day] = by_day[day].plus(cell)
    total = Cell()
    for cell in by_tool.values():
        total = total.plus(cell)
    exact = sorted(tool for tool, cell in by_tool.items() if cell.ledger_refused > 0 and cell.gap_minus_refused == 0)
    return {
        "tools_compared": len(by_tool),
        "tools_with_refusals": sum(1 for cell in by_tool.values() if cell.ledger_refused > 0),
        "tools_where_refusals_are_the_whole_gap": exact,
        "totals": total.to_json(),
        "days": [{"day": day, **cell.to_json()} for day, cell in sorted(by_day.items())],
        "tools": [
            {"tool": tool, **cell.to_json()}
            for tool, cell in sorted(by_tool.items(), key=lambda item: (-item[1].ledger_refused, item[0]))
            if cell.ledger_refused > 0 or cell.gap != 0
        ],
        "by_day_tool_with_refusals": [
            {"day": day, "tool": tool, **cell.to_json()}
            for (day, tool), cell in by_day_tool.items()
            if cell.ledger_refused > 0
        ],
        "unmapped_ledger_tools": dict(unmapped.most_common()),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, default=pathlib.Path.home() / "me")
    parser.add_argument("--since", required=True, help="UTC, e.g. 2026-11-02T00:00:00Z")
    parser.add_argument("--end", required=True, help="UTC, exclusive")
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since, end = parse_utc(args.since), parse_utc(args.end)
    if not since < end:
        raise SystemExit("--since must be before --end")
    with open_store(args.base_path) as connection:
        report = compare(read_ledger(args.base_path, since, end), read_store(connection, since, end))
    report = {"window": {"since": args.since, "end": args.end}, **report}
    if args.json_out:
        args.json_out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    totals = report["totals"]
    print(f"window {args.since} .. {args.end}: {report['tools_compared']} tools compared")
    print(f"totals: {totals}")
    print(f"tools with refusals: {report['tools_with_refusals']}; refusals are the whole gap for: {report['tools_where_refusals_are_the_whole_gap']}")
    for row in report["tools"][:15]:  # type: ignore[index]
        print(f"  {row['tool']:30s} ledger {row['ledger_calls']:7d} store {row['store_calls']:7d} gap {row['gap']:5d} refused {row['ledger_refused']:5d} gap-refused {row['gap_minus_refused']:5d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
