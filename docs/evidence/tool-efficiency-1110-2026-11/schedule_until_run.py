#!/usr/bin/env python3
"""masc_schedule_create calls that carry until_github_run: how many were refused for the missing due time.

Read-only.

Usage:
    python3 -I docs/evidence/tool-efficiency-1110-2026-11/schedule_until_run.py SINCE_ISO END_ISO [BASE_PATH]

The window is [SINCE, END) in UTC. BASE_PATH defaults to ~/me. The ledger rows are read from
BASE_PATH/.masc/tool_calls/YYYY-MM/*.jsonl.

Prints one JSON object:
  with_until              masc_schedule_create rows whose input has until_github_run
  with_until_completed    of those, rows with disposition completed
  missing_due_refused     of those, rows refused with "one of due_at_unix, due_at_iso, due_in_sec is required"
  missing_due_rate        missing_due_refused / with_until
  carried_due_field       missing_due_refused rows whose input had a due_* field anyway (expected 0)
  next_create             the same Keeper's next masc_schedule_create within 180 s of a missing-due refusal:
                          completed | failed (any other disposition) | none
"""

from __future__ import annotations

import collections
import dataclasses
import json
import pathlib
import sys
from collections.abc import Iterable

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import ledger_window as ledger  # noqa: E402

DUE_FIELDS = ("due_in_sec", "due_at_iso", "due_at_unix")
NEED_DUE = "one of due_at_unix, due_at_iso, due_in_sec is required"
HEAD_CHARS = 300
NEXT_WINDOW_S = 180.0


@dataclasses.dataclass(frozen=True, slots=True)
class Create:
    ts: float
    has_until: bool
    has_due_field: bool
    refused_missing_due: bool
    completed: bool


def measure(rows: Iterable[ledger.Row]) -> dict[str, object]:
    """`rows` are the tool_call rows of the window; rows of other tools are ignored."""
    by_keeper: dict[str, list[Create]] = collections.defaultdict(list)
    for row in rows:
        if row.get("tool") != "masc_schedule_create":
            continue
        inp = ledger.input_of(row)
        head = ledger.text_of(row.get("output"))[:HEAD_CHARS]
        by_keeper[ledger.keeper_of(row)].append(
            Create(
                ts=ledger.number_of(row, "ts"),
                has_until="until_github_run" in inp,
                has_due_field=any(field in inp for field in DUE_FIELDS),
                refused_missing_due=row.get("disposition") == "failed" and NEED_DUE in head,
                completed=row.get("disposition") == "completed",
            )
        )
    count: collections.Counter[str] = collections.Counter()
    next_create: collections.Counter[str] = collections.Counter()
    for creates in by_keeper.values():
        creates.sort(key=lambda create: create.ts)
        for index, create in enumerate(creates):
            if not create.has_until:
                continue
            count["with_until"] += 1
            count["with_until_completed"] += create.completed
            if not create.refused_missing_due:
                continue
            count["missing_due_refused"] += 1
            count["carried_due_field"] += create.has_due_field
            following = next((c for c in creates[index + 1 :] if c.ts - create.ts <= NEXT_WINDOW_S), None)
            next_create["none" if following is None else "completed" if following.completed else "failed"] += 1
    with_until = count["with_until"]
    return {
        "with_until": with_until,
        "with_until_completed": count["with_until_completed"],
        "missing_due_refused": count["missing_due_refused"],
        "missing_due_rate": round(count["missing_due_refused"] / with_until, 4) if with_until else None,
        "carried_due_field": count["carried_due_field"],
        "next_create": dict(next_create),
    }


def main() -> None:
    since, end = ledger.parse_utc(sys.argv[1]), ledger.parse_utc(sys.argv[2])
    base = pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else "~/me").expanduser()
    window = {"since": sys.argv[1], "end": sys.argv[2], "hours": round((end - since) / 3600, 2)}
    result = measure(ledger.read_rows(base, since, end, ('"tool":"masc_schedule_create"',)))
    print(json.dumps({"window": window, **result}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
