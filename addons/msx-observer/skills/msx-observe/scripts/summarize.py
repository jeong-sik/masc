"""Project selected MSX capture coordinates from stdin; never contact a machine."""

from __future__ import annotations

import argparse
import json
import sys


def object_value(value: object, field: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"{field} must be an object")
    return value


def text(value: object, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a nonempty string")
    return value


def summarize(value: object, selected: list[str]) -> dict:
    document = object_value(value, "input")
    rows, coverage = document.get("rows"), document.get("coverage")
    if not isinstance(rows, list) or not isinstance(coverage, list):
        raise ValueError("input requires rows and coverage arrays")
    if not selected or len(set(selected)) != len(selected):
        raise ValueError("select distinct row IDs")
    by_id = {}
    for item in rows:
        item = object_value(item, "row")
        identity = text(item.get("id"), "row.id")
        if identity in by_id:
            raise ValueError("duplicate row ID in input")
        by_id[identity] = item
    captures = []
    for identity in selected:
        if identity not in by_id:
            raise ValueError(f"selected row is absent: {identity}")
        item = by_id[identity]
        fields = object_value(item.get("fields"), "row.fields")
        machine = text(fields.get("machine_id"), "machine_id")
        incarnation = text(fields.get("machine_incarnation"), "machine_incarnation")
        frame = fields.get("frame")
        if isinstance(frame, bool) or not isinstance(frame, int) or frame < 0:
            raise ValueError("frame must be a nonnegative integer")
        clock = object_value(item.get("clock"), "row.clock")
        if clock != {"domain": f"msx/{machine}/{incarnation}/frame", "value": str(frame)}:
            raise ValueError("clock does not match the captured machine, incarnation, and frame")
        if item.get("kind") != "value" or item.get("subject_id") != machine:
            raise ValueError("selected row is not an MSX capture value")
        captures.append({
            "row_id": identity, "lane_id": item["lane_id"],
            "observed_at": item["observed_at"], "actor": item["actor"],
            "machine_id": machine, "machine_incarnation": incarnation,
            "frame": frame, "clock": clock,
            "matches_binding": fields["matches_binding"],
            "input_cursor": fields["input_cursor"], "input_ledger": fields["input_ledger"],
            "evidence": item["evidence"],
        })
    return {"captures": captures, "coverage": coverage}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--row-id", action="append", required=True)
    args = parser.parse_args()
    try:
        output = summarize(json.load(sys.stdin), args.row_id)
        print(json.dumps(output, ensure_ascii=False, allow_nan=False))
        return 0
    except (ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
