"""Project supplied MSX snapshots. Never connects to the machine or sends input."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, Source, evidence, object_value,
                      optional_string, row, serve, string)


def input_ledger(value: object, cursor: str | None) -> dict | None:
    if value is None:
        return None  # A frame-only source has not supplied its input history.
    ledger = object_value(value, "capture.input_ledger")
    if ledger.get("format") != "msx-input-jsonl-sequence":
        raise InvalidInput("capture.input_ledger format must be msx-input-jsonl-sequence")
    count = ledger.get("entry_count")
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        raise InvalidInput("input_ledger.entry_count must be a nonnegative integer")
    if cursor != str(count):
        raise InvalidInput("input ledger count must match the captured input cursor")
    reference = evidence([ledger.get("evidence")])[0]
    if reference["sha256"] is None or reference["uri"] != "lane-sequence:" + reference["sha256"]:
        raise InvalidInput("input ledger must name a host-owned lane-sequence root")
    return {"format": "msx-input-jsonl-sequence", "entry_count": count, "evidence": reference}


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    machine_id = string(binding.get("machine_id"), "machine_id")
    incarnation = optional_string(binding.get("incarnation"), "incarnation")
    rows, coverage = [], []
    for source in sources:
        skipped: set[str] = set()
        for observation in source.observations:
            if observation.get("kind") != "capture":
                skipped.add(str(observation.get("kind", "untyped")))
                continue
            machine = string(observation.get("machine_id"), "capture.machine_id")
            run = string(observation.get("incarnation"), "capture.incarnation")
            frame = observation.get("frame")
            if isinstance(frame, bool) or not isinstance(frame, int) or frame < 0:
                raise InvalidInput("capture.frame must be a nonnegative integer")
            screen = evidence([observation.get("screen")])[0]
            cursor = optional_string(observation.get("input_cursor"), "input_cursor")
            if "input_ledger" not in observation:
                raise InvalidInput("capture.input_ledger is required; use null for unobserved input history")
            inputs = input_ledger(observation["input_ledger"], cursor)
            item = row(source, observation, lane="msx/frame", subject=machine,
                       title="MSX frame captured", kind="value",
                       clock={"domain": f"msx/{machine}/{run}/frame", "value": str(frame)},
                       fields={"machine_id": machine, "machine_incarnation": run,
                               "frame": frame, "screen": screen,
                               "input_cursor": cursor, "input_ledger": inputs,
                               "matches_binding": machine == machine_id
                               and (incarnation is None or run == incarnation)})
            item["evidence"] = [*item["evidence"], screen]
            if inputs is not None:
                item["evidence"].append(inputs["evidence"])
            rows.append(item)
        coverage.append(source.coverage(skipped))
    return {"rows": rows, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-msx-observer", observe)
