"""Count supplied latest-completed output rows, retaining producer coordinates.

These are gauges of the supplied rows. There is no persistent accumulator,
world-wide event total, game progress estimate, or domain-specific inference.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, Source, boolean, evidence, number, object_value,
                      optional_string, row, serve, string)


ROW_KINDS = ("event", "value", "relation")
REFERENCE_FIELDS = ("id", "lane_id", "kind", "subject_id", "observed_at",
                    "clock", "actor", "evidence")


def coverage_value(value: object, label: str) -> dict:
    original = object_value(value, label)
    for key in ("source_id", "incarnation"):
        string(original.get(key), f"{label}.{key}")
    for key in ("cursor", "detail"):
        if key not in original:
            raise InvalidInput(f"{label}.{key} is required")
        optional_string(original[key], f"{label}.{key}")
    boolean(original.get("complete"), f"{label}.complete")
    return original


def row_reference(value: object) -> dict:
    original = object_value(value, "output row")
    for key in REFERENCE_FIELDS:
        if key not in original:
            raise InvalidInput(f"output row.{key} is required")
    for key in ("id", "lane_id", "subject_id"):
        string(original[key], f"output row.{key}")
    if original["kind"] not in ROW_KINDS:
        raise InvalidInput("output row.kind is not a supported row kind")
    number(original["observed_at"], "output row.observed_at")
    optional_string(original["actor"], "output row.actor")
    if original["clock"] is not None:
        clock = object_value(original["clock"], "output row.clock")
        string(clock.get("domain"), "output row.clock.domain")
        string(clock.get("value"), "output row.clock.value")
    evidence(original["evidence"])
    # Preserve supplied coordinates, clocks, actors, and references verbatim.
    # The complete output remains available through the host-owned blob.
    return {key: original[key] for key in REFERENCE_FIELDS}


def summarize(source: Source, observation: dict, *, recognized_source: bool) -> tuple[dict, bool]:
    producer = object_value(observation.get("producer"), "producer")
    for key in ("installation_id", "instance_id", "run_id",
                "configuration_revision", "package_revision"):
        string(producer.get(key), f"producer.{key}")
    seq = producer.get("observation_seq")
    if isinstance(seq, bool) or not isinstance(seq, int) or seq < 1:
        raise InvalidInput("producer.observation_seq must identify a completed positive sequence")
    supplied = object_value(observation.get("output"), "output")
    if not isinstance(supplied.get("rows"), list) or not isinstance(supplied.get("coverage"), list):
        raise InvalidInput("output must supply rows and coverage arrays")
    references = [row_reference(item) for item in supplied["rows"]]
    upstream_coverage = [coverage_value(item, "output coverage") for item in supplied["coverage"]]
    producer_status = coverage_value(observation.get("producer_status"), "producer_status")
    complete = (source.complete and recognized_source and producer_status["complete"]
                and all(item["complete"] for item in upstream_coverage))
    counts = {kind: sum(item["kind"] == kind for item in references) for kind in ROW_KINDS}
    result = row(source, observation,
                 lane=f"outputs/{producer['installation_id']}/statistics",
                 subject=producer["installation_id"], title="Supplied output row statistics",
                 kind="value", clock=None,
                 fields={"scope": "supplied_latest_completed_output",
                         "observed_row_count": len(references), "observed_by_kind": counts,
                         "input_complete": complete, "producer": producer,
                         "producer_status": producer_status,
                         "upstream_coverage": upstream_coverage,
                         "upstream_rows": references})
    # A calculation does not inherit an upstream actor or choose a clock from
    # multiple upstream domains. Both remain explicit on upstream references.
    result["actor"] = None
    result["related_ids"] = []
    return result, complete


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    rows, coverage = [], []
    if not sources:
        return {"rows": [], "coverage": [{
            "source_id": "output-statistics/input", "incarnation": "unobserved",
            "cursor": None, "complete": False,
            "detail": "No upstream output source was supplied; no count is known"}]}
    for source in sources:
        accepted = [item for item in source.observations if item.get("kind") == "lane_output"]
        skipped = {str(item.get("kind", "untyped")) for item in source.observations
                   if item.get("kind") != "lane_output"}
        completed = []
        for observation in accepted:
            result, complete = summarize(source, observation, recognized_source=not skipped)
            rows.append(result)
            completed.append(complete)
        status = source.coverage(skipped)
        status["complete"] = bool(accepted) and not skipped and all(completed)
        details = [status["detail"]] if status["detail"] is not None else []
        if not accepted:
            details.append("No lane_output observation supplied; no count is known")
        elif not status["complete"]:
            details.append("Counts describe supplied rows only; input coverage is incomplete")
        status["detail"] = "; ".join(details) if details else None
        coverage.append(status)
    return {"rows": rows, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-output-statistics", observe)
