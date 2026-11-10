#!/usr/bin/env python3
"""Does a ledger row's ts mark the start or the end of its call?

Read-only.

Usage:
    python3 -I docs/evidence/tool-efficiency-1110-2026-11/ts_position.py SINCE_ISO END_ISO [BASE_PATH]

The window is [SINCE, END) in UTC by the time a row was built (ledger_window.py). BASE_PATH defaults to ~/me. The
ledger rows are read from BASE_PATH/.masc/tool_calls/YYYY-MM/*.jsonl.

Execute calls of one Keeper turn run one after the other. Take two Execute rows that follow each other in the ts order
of one (keeper, trace_id, turn); the earlier call lasted at least 60 s (FIRST_MIN_S) and the later one at most 20 s
(SECOND_MAX_S). Let gap be the later row's ts minus the earlier row's ts.
  If ts were the start of each call, the later call could not start before the earlier one had ended, so the gap would
  be at least the earlier call's duration. A pair with a smaller gap contradicts "ts is the start".
  If ts is the end of each call (or the time the row is built right after it), the later call ends at least its own
  duration after the earlier call ended, so the gap is at least the later call's duration. A pair with a smaller gap
  contradicts "ts is the end".
A row without trace_id or turn is skipped.

Prints one JSON object: pairs, contradicts_ts_is_start, contradicts_ts_is_end.
"""

from __future__ import annotations

import collections
import json
import pathlib
import sys
from collections.abc import Iterable

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import ledger_window as ledger  # noqa: E402

FIRST_MIN_S = 60.0
SECOND_MAX_S = 20.0


def measure(rows: Iterable[ledger.Row]) -> dict[str, int]:
    """`rows` are the tool_call rows of the window; rows of other tools are ignored."""
    turns: dict[tuple[str, str, str], list[tuple[float, float]]] = collections.defaultdict(list)
    for row in rows:
        trace, turn = row.get("trace_id"), row.get("turn")
        if row.get("tool") != "Execute" or trace is None or turn is None:
            continue
        calls = turns[(ledger.keeper_of(row), str(trace), str(turn))]
        calls.append((ledger.number_of(row, "ts"), ledger.number_of(row, "duration_ms") / 1000))
    pairs = start_contradicted = end_contradicted = 0
    for calls in turns.values():
        calls.sort()
        for (earlier_ts, earlier_s), (later_ts, later_s) in zip(calls, calls[1:]):
            if earlier_s < FIRST_MIN_S or later_s > SECOND_MAX_S:
                continue
            gap = later_ts - earlier_ts
            pairs += 1
            start_contradicted += gap < earlier_s
            end_contradicted += gap < later_s
    return {"pairs": pairs, "contradicts_ts_is_start": start_contradicted, "contradicts_ts_is_end": end_contradicted}


def main() -> None:
    since, end = ledger.parse_utc(sys.argv[1]), ledger.parse_utc(sys.argv[2])
    base = pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else "~/me").expanduser()
    window = {"since": sys.argv[1], "end": sys.argv[2], "hours": round((end - since) / 3600, 2)}
    result = measure(ledger.read_rows(base, since, end, ('"tool":"Execute"',)))
    print(json.dumps({"window": window, **result}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
