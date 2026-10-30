"""Measure frame differences between two supplied MSX capture snapshots.

The worker retains one baseline per source in memory. No cumulative counter,
machine access, input replay, frame-rate estimate, or durable state is implied.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, Source, boolean, evidence, number, object_value,
                      optional_string, row, serve, stable_id, string)


PRODUCER_IDENTITY = ("installation_id", "instance_id", "run_id",
                     "configuration_revision", "package_revision")


def integer(value: object, label: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise InvalidInput(f"{label} must be an integer >= {minimum}")
    return value


def coverage_value(value: object) -> dict:
    status = object_value(value, "coverage")
    for field in ("source_id", "incarnation"):
        string(status.get(field), f"coverage.{field}")
    for field in ("cursor", "detail"):
        if field not in status:
            raise InvalidInput(f"coverage.{field} is required")
        optional_string(status[field], f"coverage.{field}")
    boolean(status.get("complete"), "coverage.complete")
    return status


@dataclass(frozen=True)
class Sample:
    source: Source
    observation: dict
    producer: dict
    capture: dict
    upstream_coverage: list[dict]
    producer_status: dict

    @property
    def frame(self) -> int:
        return self.capture["fields"]["frame"]

    @property
    def sequence(self) -> int:
        return self.producer["observation_seq"]

    @property
    def identity(self) -> tuple:
        return tuple(self.producer[field] for field in PRODUCER_IDENTITY)

    @property
    def complete(self) -> bool:
        return (self.source.complete and self.producer_status["complete"]
                and all(status["complete"] for status in self.upstream_coverage))

    def reference(self) -> dict:
        return {"source": self.source.coverage(set()), "producer": self.producer,
                "producer_status": self.producer_status,
                "upstream_coverage": self.upstream_coverage,
                "source_event_id": self.observation["id"],
                "output_evidence": self.observation["evidence"],
                "capture": self.capture}


def read_sample(source: Source, machine: str) -> Sample:
    if len(source.observations) != 1:
        raise InvalidInput("Expected exactly one latest completed lane_output snapshot")
    observation = source.observations[0]
    if observation.get("kind") != "lane_output":
        raise InvalidInput("Input kind must be lane_output")
    string(observation.get("id"), "observation.id")
    number(observation.get("observed_at"), "observation.observed_at")
    evidence(observation.get("evidence"))
    producer = object_value(observation.get("producer"), "producer")
    for field in PRODUCER_IDENTITY:
        string(producer.get(field), f"producer.{field}")
    seq = integer(producer.get("observation_seq"), "producer.observation_seq", minimum=1)
    if (source.incarnation != producer["instance_id"] or source.cursor != str(seq)
            or observation["id"] != f"{producer['instance_id']}/output/{seq}"):
        raise InvalidInput("Source cursor, incarnation, and event must match producer coordinates")
    status = coverage_value(observation.get("producer_status"))
    if (status["source_id"] != producer["instance_id"]
            or status["incarnation"] != producer["instance_id"] or status["cursor"] != str(seq)):
        raise InvalidInput("Producer status must match the supplied producer instance and sequence")
    output = object_value(observation.get("output"), "output")
    supplied_rows, supplied_coverage = output.get("rows"), output.get("coverage")
    if not isinstance(supplied_rows, list) or len(supplied_rows) != 1:
        raise InvalidInput("Expected exactly one MSX capture row; no frame baseline is known")
    if not isinstance(supplied_coverage, list) or not supplied_coverage:
        raise InvalidInput("MSX capture requires explicit source coverage")
    upstream_coverage = [coverage_value(value) for value in supplied_coverage]
    capture = object_value(supplied_rows[0], "capture")
    for field in ("id", "lane_id", "subject_id"):
        string(capture.get(field), f"capture.{field}")
    prefix = f"{producer['instance_id']}/{seq}/"
    if (capture["lane_id"] != f"{producer['instance_id']}/msx/frame"
            or not capture["id"].startswith(prefix) or len(capture["id"]) == len(prefix)):
        raise InvalidInput("Capture must belong to this producer's MSX lane and output sequence")
    number(capture.get("observed_at"), "capture.observed_at")
    if "actor" not in capture:
        raise InvalidInput("capture.actor is required; unknown actors must be null")
    optional_string(capture["actor"], "capture.actor")
    refs = evidence(capture.get("evidence"))
    fields = object_value(capture.get("fields"), "capture.fields")
    subject = string(fields.get("machine_id"), "capture.machine_id")
    incarnation = string(fields.get("machine_incarnation"), "capture.machine_incarnation")
    origin = string(fields.get("source_id"), "capture.source_id")
    if fields.get("incarnation") != incarnation:
        raise InvalidInput("Capture source incarnation must match its machine incarnation")
    matching_coverage = [item for item in upstream_coverage if item["source_id"] == origin]
    if len(matching_coverage) != 1 or matching_coverage[0]["incarnation"] != incarnation:
        raise InvalidInput("Capture requires its matching source and machine incarnation coverage")
    frame = integer(fields.get("frame"), "capture.frame")
    matches = boolean(fields.get("matches_binding"), "capture.matches_binding")
    if "input_cursor" not in fields:
        raise InvalidInput("capture.input_cursor is required")
    optional_string(fields["input_cursor"], "capture.input_cursor")
    screen = evidence([fields.get("screen")])[0]
    if screen not in refs:
        raise InvalidInput("Capture screen must be present in its evidence")
    expected_clock = {"domain": f"msx/{subject}/{incarnation}/frame", "value": str(frame)}
    if capture.get("clock") != expected_clock:
        raise InvalidInput("Capture clock must match machine, incarnation, and integer frame")
    if (capture.get("kind") != "value" or capture["subject_id"] != subject
            or subject != machine or not matches):
        raise InvalidInput("Capture does not match the requested machine and observer binding")
    return Sample(source, observation, producer, capture, upstream_coverage, status)


@dataclass(frozen=True)
class Baseline:
    sample: Sample
    result: dict


def measurement(current: Sample, previous: Sample | None, state: str,
                reason: str | None, value: int | None) -> dict:
    captures = [current] if previous is None else [previous, current]
    result = row(current.source, current.observation,
                 lane=f"outputs/{current.producer['installation_id']}/frame-progress",
                 subject=current.capture["subject_id"], title="MSX observed frame progress",
                 kind="value", clock=current.capture["clock"],
                 fields={"scope": "between_supplied_msx_captures", "unit": "frames",
                         "state": state, "reason": reason, "value": value,
                         "input_complete": current.complete,
                         "baseline_storage": "worker_memory",
                         "previous": None if previous is None else previous.reference(),
                         "current": current.reference()})
    result["id"] = stable_id("msx-frame-progress", state, reason,
                             [sample.reference() for sample in captures])
    result["actor"] = None
    result["evidence"] = []
    for sample in captures:
        for reference in [*sample.observation["evidence"], *sample.capture["evidence"]]:
            if reference not in result["evidence"]:
                result["evidence"].append(reference)
    # These are arithmetic inputs, not asserted causal relationships. The host
    # namespaces related_ids as package-local IDs; upstream IDs stay in fields.
    return result


def advance(previous: Baseline | None, current: Sample) -> tuple[Baseline | None, dict]:
    if not current.complete:
        return None, measurement(current, None, "unknown", "input_incomplete", None)
    if previous is None:
        result = measurement(current, None, "baseline", "first_complete_sample", None)
        return Baseline(current, result), result
    before = previous.sample
    if current.identity != before.identity:
        reason = "producer_changed"
    elif current.sequence < before.sequence:
        return None, measurement(current, before, "unknown", "producer_cursor_regressed", None)
    elif current.sequence == before.sequence:
        if current.reference() != before.reference():
            return None, measurement(current, before, "unknown", "same_cursor_changed", None)
        return previous, previous.result
    elif current.capture["clock"]["domain"] != before.capture["clock"]["domain"]:
        reason = "machine_incarnation_changed"
    elif current.frame < before.frame:
        reason = "frame_regressed"
    else:
        result = measurement(current, before, "measured", None, current.frame - before.frame)
        return Baseline(current, result), result
    result = measurement(current, before, "baseline", reason, None)
    return Baseline(current, result), result


class FrameProgress:
    def __init__(self) -> None:
        self.baselines: dict[str, Baseline] = {}

    def __call__(self, binding: dict, sources: tuple[Source, ...]) -> dict:
        machine = string(binding.get("machine_id"), "binding.machine_id")
        ids = [source.source_id for source in sources]
        if len(set(ids)) != len(ids):
            self.baselines = {}
            raise InvalidInput("Input source IDs must be distinct")
        rows, coverage, next_baselines = [], [], {}
        for source in sources:
            status = source.coverage(set())
            try:
                sample = read_sample(source, machine)
                baseline, result = advance(self.baselines.get(source.source_id), sample)
                rows.append(result)
                if baseline is not None:
                    next_baselines[source.source_id] = baseline
                status["complete"] = sample.complete
                metric = result["fields"]
                if metric["state"] == "unknown":
                    status["complete"] = False
                reason = metric["reason"]
            except InvalidInput as error:
                status["complete"] = False
                reason = f"unknown: {error}"
            if reason is not None:
                status["detail"] = reason if status["detail"] is None else f"{status['detail']}; {reason}"
            coverage.append(status)
        self.baselines = next_baselines
        if not sources:
            coverage.append({"source_id": "frame-progress/input", "incarnation": "unobserved",
                             "cursor": None, "complete": False,
                             "detail": "unknown: no upstream source; frame baseline cleared"})
        return {"rows": rows, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-frame-progress", FrameProgress())
