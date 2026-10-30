"""Signed changes between supplied value rows, without a cumulative history."""
from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, Source, boolean, evidence, number, object_value,
                      optional_string, row, serve, stable_id, string)


def numeric(value: object, label: str) -> int | float:
    # Integers retain exact arithmetic instead of passing through float().
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InvalidInput(f"{label} must be a number, not a boolean or string")
    if isinstance(value, float) and not math.isfinite(value):
        raise InvalidInput(f"{label} must be finite")
    return value


def coverage(value: object) -> dict:
    result = object_value(value, "coverage")
    for field in ("source_id", "incarnation"):
        string(result.get(field), f"coverage.{field}")
    for field in ("cursor", "detail"):
        if field not in result:
            raise InvalidInput(f"coverage.{field} is required")
        optional_string(result[field], f"coverage.{field}")
    boolean(result.get("complete"), "coverage.complete")
    return result


@dataclass(frozen=True)
class Sample:
    source: Source
    observation: dict
    producer: dict
    value_row: dict
    producer_status: dict
    upstream_coverage: list[dict]
    field: str
    unit: str

    @property
    def sequence(self) -> int:
        return self.producer["observation_seq"]

    @property
    def value(self) -> int | float:
        return self.value_row["fields"][self.field]

    @property
    def producer_identity(self) -> dict:
        return {key: value for key, value in self.producer.items()
                if key != "observation_seq"}

    @property
    def identity(self) -> tuple:
        clock = self.value_row["clock"]
        return (self.value_row["subject_id"], self.value_row["lane_id"],
                None if clock is None else clock["domain"], self.field, self.unit,
                sorted((item["source_id"], item["incarnation"])
                       for item in self.upstream_coverage))

    @property
    def complete(self) -> bool:
        return (self.source.complete and self.producer_status["complete"]
                and all(item["complete"] for item in self.upstream_coverage))

    def reference(self) -> dict:
        # The wrapper's acquisition time may change when the same completed
        # output is reread. The original value row keeps its own observed_at.
        return {"source": self.source.coverage(set()), "producer": self.producer,
                "producer_status": self.producer_status,
                "upstream_coverage": self.upstream_coverage,
                "source_event_id": self.observation["id"],
                "output_actor": self.observation["actor"],
                "output_evidence": self.observation["evidence"], "row": self.value_row}

    def payload(self) -> tuple:
        # Source availability and producer status are live acquisition state;
        # the committed row/output must stay immutable at a producer cursor.
        return (self.producer, self.value_row, self.upstream_coverage,
                self.observation["id"], self.observation["actor"], self.observation["evidence"])


def read_sample(source: Source, field: str, unit: str) -> Sample:
    if len(source.observations) != 1:
        raise InvalidInput("Expected exactly one latest completed lane_output observation")
    observation = source.observations[0]
    if observation.get("kind") != "lane_output":
        raise InvalidInput("Input kind must be lane_output")
    number(observation.get("observed_at"), "observation.observed_at")
    evidence(observation.get("evidence"))
    if "actor" not in observation:
        raise InvalidInput("observation.actor is required; unknown actors must be null")
    optional_string(observation["actor"], "observation.actor")
    producer = object_value(observation.get("producer"), "producer")
    for key in ("installation_id", "instance_id", "run_id",
                "configuration_revision", "package_revision"):
        string(producer.get(key), f"producer.{key}")
    sequence = producer.get("observation_seq")
    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 1:
        raise InvalidInput("producer.observation_seq must be a positive integer")
    instance = producer["instance_id"]
    if (source.incarnation != instance or source.cursor != str(sequence)
            or observation.get("id") != f"{instance}/output/{sequence}"):
        raise InvalidInput("Source cursor, incarnation and event must match producer coordinates")
    status = coverage(observation.get("producer_status"))
    if (status["source_id"] != instance or status["incarnation"] != instance
            or status["cursor"] != str(sequence)):
        raise InvalidInput("Producer status must match its instance and sequence")
    output = object_value(observation.get("output"), "output")
    values, statuses = output.get("rows"), output.get("coverage")
    if not isinstance(values, list) or len(values) != 1:
        raise InvalidInput("Expected exactly one supplied value row; select a named output")
    if not isinstance(statuses, list):
        raise InvalidInput("Supplied output requires an explicit coverage array")
    statuses = [coverage(item) for item in statuses]
    source_ids = [item["source_id"] for item in statuses]
    if len(source_ids) != len(set(source_ids)):
        raise InvalidInput("Upstream coverage source IDs must be distinct")
    value = object_value(values[0], "value row")
    for key in ("id", "lane_id", "subject_id", "title"):
        string(value.get(key), f"row.{key}")
    prefix = f"{instance}/{sequence}/"
    if (not value["id"].startswith(prefix) or len(value["id"]) == len(prefix)
            or not value["lane_id"].startswith(instance + "/")
            or value["lane_id"] == instance + "/"):
        raise InvalidInput("Value row must belong to the supplied producer and sequence")
    if value.get("kind") != "value":
        raise InvalidInput("Input must be a value row")
    number(value.get("observed_at"), "row.observed_at")
    if "actor" not in value or "clock" not in value:
        raise InvalidInput("row.actor and row.clock are required; unknown values must be null")
    optional_string(value["actor"], "row.actor")
    if value["clock"] is not None:
        clock = object_value(value["clock"], "row.clock")
        if set(clock) != {"domain", "value"}:
            raise InvalidInput("row.clock requires exactly domain and value")
        string(clock["domain"], "clock.domain")
        string(clock["value"], "clock.value")
    evidence(value.get("evidence"))
    fields = object_value(value.get("fields"), "row.fields")
    numeric(fields.get(field), f"row.fields[{field!r}]")
    return Sample(source, observation, producer, value, status, statuses, field, unit)


@dataclass(frozen=True)
class Baseline:
    sample: Sample
    result: dict


@dataclass(frozen=True)
class History:
    accepted: Baseline | None
    seen: Sample
    gap: dict | None


def with_gap(result: dict, gap: dict | None) -> dict:
    fields = {**result["fields"], "intervening_input_gap": gap is not None,
              "last_input_gap": gap}
    references = list(result["evidence"])
    if gap is not None:
        for reference in [*gap["output_evidence"], *gap["row"]["evidence"]]:
            if reference not in references:
                references.append(reference)
    return {**result, "fields": fields, "evidence": references,
            "id": stable_id("value-difference", fields)}


def measurement(current: Sample, previous: Sample | None, state: str,
                reason: str | None, value: int | float | None, gap: dict | None = None) -> dict:
    direction = None if value is None else "up" if value > 0 else "down" if value < 0 else "unchanged"
    result = row(current.source, current.observation,
                 lane=f"values/{current.source.source_id}/difference",
                 subject=current.value_row["subject_id"], title=f"Observed {current.field} change",
                 kind="value", clock=current.value_row["clock"],
                 fields={"scope": "between_supplied_values", "field": current.field,
                         "unit": current.unit, "state": state, "reason": reason,
                         "value": value, "direction": direction,
                         "input_complete": current.complete, "baseline_storage": "worker_memory",
                         "previous": None if previous is None else previous.reference(),
                         "current": current.reference()})
    samples = [current] if previous is None else [previous, current]
    result["actor"] = None
    result["evidence"] = []
    for sample in samples:
        for reference in [*sample.observation["evidence"], *sample.value_row["evidence"]]:
            if reference not in result["evidence"]:
                result["evidence"].append(reference)
    return with_gap(result, gap)


def advance(history: History | None, current: Sample) -> tuple[History | None, dict]:
    accepted = None if history is None else history.accepted
    before = None if accepted is None else accepted.sample
    reason = "first_complete_sample"
    if history is not None:
        seen = history.seen
        producer_changed = ((current.producer_identity, current.field, current.unit)
                            != (seen.producer_identity, seen.field, seen.unit))
        if not producer_changed:
            if current.sequence < seen.sequence:
                return None, measurement(current, before, "unknown", "producer_cursor_regressed", None, history.gap)
            if current.sequence == seen.sequence and current.payload() != seen.payload():
                return None, measurement(current, before, "unknown", "same_cursor_changed", None, history.gap)
        if producer_changed or current.identity != seen.identity:
            reason = "identity_changed"
            history = None
            accepted = None
            before = None
    if not current.complete:
        gap = {**current.reference(), "acquired_at": current.observation["observed_at"]}
        result = measurement(current, before, "unknown", "input_incomplete", None, gap)
        return History(accepted, current, gap), result
    gap = None if history is None else history.gap
    if accepted is None:
        result = measurement(current, before, "baseline", reason, None, gap)
        return History(Baseline(current, result), current, None), result
    before = accepted.sample
    if current.sequence == before.sequence:
        # A later acquisition gap cannot revise an already measured interval.
        # Keep it pending until a new endpoint supplies another interval.
        return History(accepted, current, gap), accepted.result
    try:
        difference = numeric(current.value - before.value, "difference")
    except (InvalidInput, OverflowError):
        return None, measurement(current, before, "unknown", "difference_not_finite", None, gap)
    result = measurement(current, before, "measured", None, difference, gap)
    return History(Baseline(current, result), current, None), result


class ValueDifference:
    def __init__(self) -> None:
        self.histories: dict[str, History] = {}

    def __call__(self, binding: dict, sources: tuple[Source, ...]) -> dict:
        field = string(binding.get("field"), "binding.field")
        unit = string(binding.get("unit"), "binding.unit")
        ids = [source.source_id for source in sources]
        if len(set(ids)) != len(ids):
            self.histories = {}
            raise InvalidInput("Input source IDs must be distinct")
        rows, statuses, next_histories = [], [], {}
        for source in sources:
            status = source.coverage(set())
            try:
                sample = read_sample(source, field, unit)
                history, result = advance(self.histories.get(source.source_id), sample)
                rows.append(result)
                if history is not None:
                    next_histories[source.source_id] = history
                status["complete"] = sample.complete and result["fields"]["state"] != "unknown"
                reason = result["fields"]["reason"]
            except InvalidInput as error:
                status["complete"] = False
                reason = f"unknown: {error}"
            if reason is not None:
                status["detail"] = reason if status["detail"] is None else f"{status['detail']}; {reason}"
            statuses.append(status)
        self.histories = next_histories
        if not sources:
            statuses.append({"source_id": "value-difference/input", "incarnation": "unobserved",
                             "cursor": None, "complete": False,
                             "detail": "unknown: no upstream source; value baseline cleared"})
        return {"rows": rows, "coverage": statuses}


if __name__ == "__main__":
    serve("masc-value-difference", ValueDifference())
