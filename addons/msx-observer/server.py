"""Project supplied MSX snapshots. Never connects to the machine or sends input."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, Source, evidence, optional_string, row,
                      serve, string)


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    machine_id = string(binding.get("machine_id"), "machine_id")
    incarnation = string(binding.get("incarnation"), "incarnation")
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
            item = row(source, observation, lane="msx/frame", subject=machine,
                       title="MSX frame captured", kind="value",
                       clock={"domain": f"msx/{machine}/{run}/frame", "value": str(frame)},
                       fields={"machine_id": machine, "machine_incarnation": run,
                               "frame": frame, "screen": screen,
                               "input_cursor": optional_string(observation.get("input_cursor"), "input_cursor"),
                               "matches_binding": machine == machine_id and run == incarnation})
            item["evidence"] = [*item["evidence"], screen]
            rows.append(item)
        coverage.append(source.coverage(skipped))
    return {"rows": rows, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-msx-observer", observe)
