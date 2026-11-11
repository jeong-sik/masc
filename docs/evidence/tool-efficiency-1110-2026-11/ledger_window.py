"""Read-only reader of the Keeper tool-call ledger, shared by the scripts in this folder.

The ledger is `<base>/.masc/tool_calls/<YYYY-MM>/*.jsonl`, one JSON object per line. A row's `ts` is the clock when
the row is built after the result has arrived (`Time_compat.now ()` in `lib/keeper_tool_call_log.ml`, with
`duration_ms` already known), so it equals the end of the call or comes a little later. The window [since, end) holds
the calls whose row was built inside it, and a call began at about `ts - duration_ms / 1000`.
"""

from __future__ import annotations

import datetime
import json
import pathlib
import re
from collections.abc import Iterator

LEDGER_FILE = re.compile(r"^[0-9]{2}(?:\.[0-9]{3})?\.jsonl$")
TOOL_CALL = '"record_kind":"tool_call"'

Row = dict[str, object]


def parse_utc(text: str) -> float:
    """Seconds since the epoch for an ISO 8601 time. A time without an offset is UTC."""
    moment = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment.timestamp()


def read_rows(base: pathlib.Path, since: float, end: float, markers: tuple[str, ...] = ()) -> Iterator[Row]:
    """Yield the tool_call rows with since <= ts < end.

    `markers` are substrings of the raw line, for example '"tool":"Execute"'. A line is parsed only when it holds
    at least one of them, or when `markers` is empty. A file last written before `since` cannot hold a row inside
    the window, so it is not opened.
    """
    root = base / ".masc" / "tool_calls"
    if not root.is_dir():
        return
    for month in sorted(path for path in root.iterdir() if path.is_dir()):
        for path in sorted(month.iterdir()):
            if not LEDGER_FILE.match(path.name) or path.stat().st_mtime < since:
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if TOOL_CALL not in line or (markers and not any(marker in line for marker in markers)):
                        continue
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    ts = row.get("ts")
                    if isinstance(ts, (int, float)) and since <= ts < end:
                        yield row


def text_of(output: object) -> str:
    """The `output` of a row as text. A row keeps a string, or a JSON value for structured results."""
    return output if isinstance(output, str) else json.dumps(output, ensure_ascii=False)


def input_of(row: Row) -> dict[str, object]:
    """The `input` of a row when it is an object, otherwise an empty object."""
    value = row.get("input")
    return value if isinstance(value, dict) else {}


def number_of(row: Row, key: str) -> float:
    """A numeric field of a row, 0.0 when it is missing or not a number."""
    value = row.get(key)
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0.0


def keeper_of(row: Row) -> str:
    value = row.get("keeper")
    return value if isinstance(value, str) and value else "?"
