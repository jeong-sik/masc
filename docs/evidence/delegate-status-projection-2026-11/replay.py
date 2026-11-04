#!/usr/bin/env python3
"""Replay the masc_keeper_delegate_status projection over recorded calls.

Reads the tool-call ledger under `<base-path>/.masc/tool_calls/YYYY-MM/`, takes
every recorded `masc_keeper_delegate_status` call and measures how many bytes
`Keeper_chat_operation.to_status_json` would have left out of its result.

Definitions:

- before: the ledger's `result_bytes` for the call, the size of the result the
  model received. The ledger clips long text in the stored `output` (a clipped
  object carries `"_truncated": true`), so the stored output can be shorter than
  `result_bytes`; this script never sizes a result from the stored output alone.
- dropped: compact-JSON bytes of the stored output, minus the same after keeping
  only the projection's fields (plus `completed_reply`). The dropped fields are
  the request echo, so a clipped reply does not change them.
- after: before minus dropped.

The projection is applied by field name only. Nothing here reads message text.

Usage:
    docs/evidence/delegate-status-projection-2026-11/replay.py --base-path ~/me \
        --from-date 2026-11-01 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from datetime import date, datetime, timedelta, timezone

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

import masc_base_path  # noqa: E402
from tool_call_log_paths import tool_call_log_paths  # noqa: E402

TOOL = "masc_keeper_delegate_status"
# The fields Keeper_chat_operation.to_status_json reports, plus the
# completed_reply the status body appends for a succeeded operation.
KEPT_FIELDS = (
    "operation_id",
    "created_at",
    "batch_execution_id",
    "state",
    "started_at",
    "completed_at",
    "outcome_ref",
    "failure_kind",
    "failure_detail",
    "completed_reply",
)
NO_STATE = "(no state)"


def compact_bytes(value: object) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def parse_day(text: str) -> date:
    return date.fromisoformat(text)


def parse_until(text: str) -> float:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()


def ledger_files(base: pathlib.Path, day: date) -> list[pathlib.Path]:
    live = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
    return tool_call_log_paths(base, live)


def output_object(row: dict[str, object]) -> dict[str, object] | None:
    out = row.get("output")
    if isinstance(out, str):
        try:
            out = json.loads(out)
        except ValueError:
            return None
    return out if isinstance(out, dict) else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--until", type=parse_until, default=None, help="ignore calls after this ISO-8601 time")
    parser.add_argument("--json-out", default=None, help="write the summary to this file")
    args = parser.parse_args()
    base = masc_base_path.require(parser, args.base_path, "--base-path")

    calls = 0
    unsized = 0
    before = 0
    dropped = 0
    clipped_rows = 0
    by_state: dict[str, dict[str, int]] = {}

    day = args.from_date
    while day <= args.to_date:
        for path in ledger_files(base, day):
            with path.open("rb") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict) or row.get("record_kind") != "tool_call" or row.get("tool") != TOOL:
                        continue
                    ts = row.get("ts")
                    if args.until is not None and isinstance(ts, (int, float)) and ts > args.until:
                        continue
                    calls += 1
                    rb = row.get("result_bytes")
                    if not isinstance(rb, int):
                        unsized += 1
                        continue
                    obj = output_object(row)
                    state = str(obj.get("state")) if obj is not None and "state" in obj else NO_STATE
                    drop = 0
                    if obj is not None and state != NO_STATE:
                        kept = {k: v for k, v in obj.items() if k in KEPT_FIELDS}
                        drop = compact_bytes(obj) - compact_bytes(kept)
                    out = row.get("output")
                    if isinstance(out, str) and rb != len(out.encode("utf-8")):
                        clipped_rows += 1
                    before += rb
                    dropped += drop
                    slot = by_state.setdefault(state, {"calls": 0, "before_bytes": 0, "dropped_bytes": 0, "after_bytes": 0})
                    slot["calls"] += 1
                    slot["before_bytes"] += rb
                    slot["dropped_bytes"] += drop
                    slot["after_bytes"] += rb - drop
        day += timedelta(days=1)

    after = before - dropped
    summary = {
        "tool": TOOL,
        "window": {
            "from": args.from_date.isoformat(),
            "to": args.to_date.isoformat(),
            "until": datetime.fromtimestamp(args.until, timezone.utc).isoformat() if args.until is not None else None,
        },
        "calls": calls,
        "calls_without_result_bytes": unsized,
        "calls_whose_stored_output_differs_from_result_bytes": clipped_rows,
        "before_result_bytes": before,
        "dropped_bytes": dropped,
        "after_bytes": after,
        "dropped_share": round(dropped / before, 4) if before else None,
        "by_state": dict(sorted(by_state.items())),
        "kept_fields": list(KEPT_FIELDS),
    }
    text = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)
    print(text)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
