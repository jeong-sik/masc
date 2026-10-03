#!/usr/bin/env python3
"""Compare frozen baseline/preflight run-detail exports without model calls.

The manifest supplies source_head, environment, config_sha256, evidence_kind
(fixture/native/live), and pairs of {sample_id, baseline, preflight}. Each arm
is an unmodified /standalone-lanes run-detail JSON response. Input payloads must
match exactly. This report measures recorded end-to-end durations and routes,
not provider dispatch counts, semantic quality or installed TUI behavior.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import statistics
import sys
from pathlib import Path
from typing import TypeAlias, cast

Json: TypeAlias = None | bool | int | float | str | list["Json"] | dict[str, "Json"]


def obj(value: Json, name: str) -> dict[str, Json]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def text(value: Json, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a nonblank string")
    return value


def sha(value: Json, name: str, length: int = 64) -> str:
    result = text(value, name)
    if len(result) != length or any(c not in "0123456789abcdef" for c in result):
        raise ValueError(f"{name} must be a lowercase SHA hex digest")
    return result


def digest(value: Json) -> str:
    return hashlib.sha256(
        json.dumps(
            value, sort_keys=True, separators=(",", ":"), allow_nan=False
        ).encode()
    ).hexdigest()


def number(value: Json, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be finite numeric evidence")
    try:
        result = float(value)
    except OverflowError as error:
        raise ValueError(f"{name} exceeds finite numeric evidence") from error
    if not math.isfinite(result):
        raise ValueError(f"{name} must be finite numeric evidence")
    return result


def required(record: dict[str, Json], key: str) -> Json:
    if key not in record:
        raise ValueError(f"missing required input field {key}")
    return record[key]


def string(value: Json, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string")
    return value


def count(value: Json, name: str) -> int:
    if type(value) is not int or value < 0:
        raise ValueError(f"{name} must be a nonnegative integer")
    return value


def array(value: Json, name: str) -> list[Json]:
    if not isinstance(value, list):
        raise ValueError(f"{name} must be an array")
    return value


def turn_ref(value: Json) -> None:
    raw = text(value, "turn_ref")
    trace, separator, turn = raw.rpartition("#")
    if not trace or not separator or not turn.removeprefix("-").isascii() or not turn.removeprefix("-").isdigit():
        raise ValueError("turn_ref must contain a trace and integer turn")


def goals(value: Json) -> None:
    # Keeper_librarian.goal_context_to_json and Keeper_turn_task_context.to_json
    # share the same Goal_store criterion representation.
    for item in array(value, "goals"):
        goal = obj(item, "goal")
        text(goal.get("goal_id"), "goal_id")
        if goal.get("phase") not in ("executing", "verifying", "awaiting_confirmation", "completed", "dropped"):
            raise ValueError("unknown Goal phase")
        criterion = obj(goal.get("criterion"), "criterion")
        text(criterion.get("revision"), "criterion revision")
        string(criterion.get("title"), "criterion title")
        for key in ("metric", "target_value"):
            value = required(criterion, key)
            if value is not None:
                string(value, "criterion " + key)


def goal_context(value: Json) -> None:
    context = obj(value, "goal_context")
    status = context.get("status")
    fields = {
        "no_task": {"status"},
        "available": {"status", "task_id", "goals"},
        "unavailable": {"status", "task_id", "detail"},
    }
    if not isinstance(status, str) or status not in fields:
        raise ValueError("unknown goal context status")
    if context.keys() != fields[status]:
        raise ValueError("goal context fields do not match status")
    if status == "no_task":
        return
    text(context.get("task_id"), "task_id")
    if status == "available":
        goals(context.get("goals"))
    elif status == "unavailable":
        string(context.get("detail"), "goal context detail")


def goal_source_error(value: Json) -> None:
    # Match the durable Goal_store_unavailable record, including nested reason
    # and mirror diagnostics, rather than treating an error object as complete.
    record = obj(value, "goal source error")
    string(record.get("file"), "goal source file")

    def unix_error(value: Json) -> None:
        error = obj(value, "unix error")
        kind = text(error.get("kind"), "unix error kind")
        if kind == "eunknownerr" and type(error.get("code")) is not int:
            raise ValueError("unknown Unix error requires its integer code")

    def reason(value: Json) -> None:
        error = obj(value, "goal source reason")
        kind = error.get("kind")
        if kind == "unreadable":
            unix_error(error.get("error"))
        elif kind in ("not_json", "schema_rejected"):
            string(error.get("detail"), "goal source detail")
            if kind == "schema_rejected":
                string(error.get("field"), "goal source field")
        elif kind != "missing_after_init":
            raise ValueError("unknown goal source reason")

    reason(record.get("reason"))
    mirror = obj(record.get("mirror"), "goal mirror")
    if mirror.get("kind") == "mirror_unreadable":
        unix_error(mirror.get("error"))
    elif mirror.get("kind") == "mirror_decodes":
        count(mirror.get("goal_count"), "mirror goal count")
        string(mirror.get("updated_at"), "mirror updated_at")
    elif mirror.get("kind") == "mirror_rejected":
        reason(mirror.get("reason"))
    elif mirror.get("kind") != "mirror_absent":
        raise ValueError("unknown goal mirror kind")
    reset = obj(record.get("reset_step"), "goal reset step")
    if reset.get("kind") == "repair_field":
        string(reset.get("field"), "goal repair field")
    elif reset.get("kind") not in ("reset_goal_store", "restore_permission"):
        raise ValueError("unknown goal reset step")


def task_context(value: Json) -> None:
    context = obj(value, "historical task context")
    kind = context.get("kind")
    fields = {
        "no_task": {"kind"},
        "admission_not_recorded": {"kind"},
        "task_source_unavailable": {"kind", "detail"},
        "task": {"kind", "task_id", "goals"},
    }
    if not isinstance(kind, str) or kind not in fields:
        raise ValueError("unknown historical task context kind")
    if context.keys() != fields[kind]:
        raise ValueError("historical task context fields do not match kind")
    if kind in ("no_task", "admission_not_recorded"):
        return
    if kind == "task_source_unavailable":
        string(context.get("detail"), "task source detail")
        return
    text(context.get("task_id"), "historical task_id")
    observation = obj(context.get("goals"), "historical goals")
    if observation.get("kind") == "observed":
        goals(observation.get("goals"))
    elif observation.get("kind") == "unavailable":
        error = obj(observation.get("error"), "historical goals error")
        if error.get("kind") == "goal_links_unavailable":
            string(error.get("detail"), "goal links detail")
        elif error.get("kind") == "linked_goal_missing":
            text(error.get("goal_id"), "missing goal_id")
        elif error.get("kind") == "goal_source_unavailable":
            goal_source_error(error.get("error"))
        else:
            raise ValueError("unknown historical goals error")
    else:
        raise ValueError("unknown historical goals observation")


def input_payload(value: Json, actor: str) -> None:
    # SSOT: Keeper_librarian_runtime.exact_input_payload, prompt_material_payload
    # and Keeper_librarian.prompt_variables (eligible Memory-only preflight).
    payload = obj(value, "input payload")
    messages = count(payload.get("message_count"), "message_count")
    count(payload.get("current_fact_count"), "current_fact_count")
    actual = obj(payload.get("actual_input"), "actual_input")
    turn_ref(actual.get("turn_ref"))
    goal_context(actual.get("goal_context"))
    string(actual.get("keeper_instructions"), "keeper_instructions")
    for item in array(actual.get("historical_task_contexts"), "historical_task_contexts"):
        history = obj(item, "historical task range")
        for first, after in (("first_message", "after_message"), ("first_tool_observation", "after_tool_observation")):
            lower = count(history.get(first), first)
            upper = count(history.get(after), after)
            if lower > upper or (after == "after_message" and upper > messages):
                raise ValueError("historical task range exceeds its frozen input")
        source = obj(history.get("source"), "historical task source")
        if source.get("kind") == "atoms":
            text(source.get("trace_id"), "historical source trace_id")
            if count(source.get("start_atom"), "start_atom") > count(source.get("end_atom"), "end_atom"):
                raise ValueError("reversed historical atom range")
        elif source.get("kind") not in ("official_turn", "boundary_only"):
            raise ValueError("unknown historical source kind")
        attribution = obj(history.get("attribution"), "historical attribution")
        if attribution.get("kind") == "observed":
            turn_ref(attribution.get("turn_ref"))
            task_context(attribution.get("task_context"))
        elif attribution.get("kind") != "unattributed":
            raise ValueError("unknown historical attribution kind")
    prompt = obj(actual.get("prompt"), "prompt")
    if prompt.get("key") != "librarian":
        raise ValueError("preflight comparison requires the eligible librarian prompt")
    if prompt.get("source") not in ("override", "file"):
        raise ValueError("preflight comparison requires a resolved prompt source")
    path = required(prompt, "file_path")
    if path is not None:
        string(path, "prompt file_path")
    text(prompt.get("effective_template"), "effective_template")
    count(prompt.get("rendered_bytes"), "rendered_bytes")
    sha(prompt.get("rendered_sha256"), "rendered prompt hash")
    variables = obj(actual.get("rendered_prompt_variables"), "rendered_prompt_variables")
    for key in ("keeper_id", "facts_budget", "keeper_instructions", "historical_task_contexts",
                "continuity", "working_context", "working_contexts_rule", "goal_context", "current_memory",
                "conversation_history", "turn_tool_observations", "counterpart_observations"):
        string(required(variables, key), "rendered variable " + key)
    for key, variable in variables.items():
        string(variable, "rendered variable " + key)
    if variables["keeper_id"] != actor:
        raise ValueError("run actor must match the frozen keeper_id")
    rendered_history = json.loads(string(variables["historical_task_contexts"], "rendered historical_task_contexts"), object_pairs_hook=unique_object)
    if digest(rendered_history) != digest(actual["historical_task_contexts"]):
        raise ValueError("rendered historical task context disagrees with frozen typed context")
    rendered_goal = json.loads(string(variables["goal_context"], "rendered goal_context"), object_pairs_hook=unique_object)
    goal_context(rendered_goal)
    if rendered_goal != actual["goal_context"]:
        raise ValueError("rendered goal context disagrees with frozen typed context")
    continuity = json.loads(string(variables["continuity"], "continuity"), object_pairs_hook=unique_object)
    if continuity is not None:
        raise ValueError("evaluated preflight requires null frozen continuity")
    context = json.loads(string(variables["working_context"], "working_context"), object_pairs_hook=unique_object)
    # Keeper_librarian_context.prompt_json empty. This is the recorded
    # projection, not proof of unexported fields in the runtime input record.
    if context != {"sources": [], "previous": None, "unavailable": []}:
        raise ValueError("evaluated preflight requires empty frozen working_context")


def unique_object(pairs: list[tuple[str, Json]]) -> dict[str, Json]:
    record: dict[str, Json] = {}
    for key, value in pairs:
        if key in record:
            raise ValueError(f"duplicate JSON object key {key!r}")
        record[key] = value
    return record


def attempts(value: Json, name: str) -> list[Json]:
    if not isinstance(value, list):
        raise ValueError(f"{name} must be an array")
    for item in value:
        attempt = obj(item, "preflight attempt")
        text(attempt.get("destination_uri"), "attempt destination")
        text(attempt.get("model"), "attempt model")
        refusal = obj(attempt.get("refusal"), "attempt refusal")
        if not isinstance(refusal.get("detail"), str):
            raise ValueError("refusal detail must be a string")
        if refusal.get("kind") == "http_response":
            if type(refusal.get("status")) is not int:
                raise ValueError("HTTP refusal status must be an integer")
            text(refusal.get("destination_uri"), "HTTP refusal destination")
            if refusal["destination_uri"] != attempt["destination_uri"]:
                raise ValueError("HTTP refusal destination disagrees with attempted destination")
            body = refusal.get("body")
            if not isinstance(body, str):
                encoded = obj(body, "HTTP refusal body")
                if encoded.get("encoding") != "base64" or not isinstance(encoded.get("content"), str):
                    raise ValueError("HTTP refusal body must contain base64 text")
                raw = base64.b64decode(cast(str, encoded["content"]), validate=True)
                if type(encoded.get("total_bytes")) is not int or encoded["total_bytes"] != len(raw):
                    raise ValueError("HTTP refusal body byte count disagrees")
        elif refusal.get("kind") != "transport":
            raise ValueError("unknown preflight refusal kind")
    return value


def validate_observation(observation: dict[str, Json]) -> None:
    status = observation.get("status")
    received_fields = ("destination", "model", "request_body_sha256", "decision",
                       "probabilities", "confidence", "passed_over")
    forbidden = {
        "awaiting_answer": ("reason", "failure"),
        "skipped": ("failure",), "ineligible": ("failure",),
        "question_unavailable": ("failure",), "failed": ("reason",),
        "invalid_answer": ("failure", "decision", "confidence", "probabilities"),
        "judged": ("failure", "reason"),
    }
    for key in forbidden.get(str(status), ()):
        if key in observation:
            raise ValueError(f"preflight {status} must not report {key}")
    if status in ("awaiting_answer", "failed", "skipped", "ineligible", "question_unavailable") and any(key in observation for key in received_fields):
        raise ValueError("answerless preflight cannot contain received-answer evidence")
    if status in ("awaiting_answer", "skipped", "ineligible", "question_unavailable"):
        if status != "awaiting_answer":
            text(observation.get("reason"), "uncalled preflight reason")
        if "elapsed_s" not in observation or observation["elapsed_s"] is not None:
            raise ValueError("uncalled or awaiting preflight must record null elapsed time")
        if "failure" in observation:
            raise ValueError("uncalled or awaiting preflight cannot contain completed failure evidence")
        return
    if number(observation.get("elapsed_s"), "preflight elapsed_s") < 0:
        raise ValueError("preflight elapsed_s must be nonnegative")
    if status == "failed":
        failure = obj(observation.get("failure"), "preflight failure")
        if failure.get("kind") != "every_destination_refused" or not attempts(failure.get("attempts"), "failure attempts"):
            raise ValueError("failed preflight must record destination refusals")
        return
    if status not in ("judged", "invalid_answer"):
        raise ValueError("unknown completed preflight observation status")
    destination = obj(observation.get("destination"), "preflight destination")
    text(destination.get("destination_uri"), "preflight destination URI")
    text(destination.get("model"), "preflight requested model")
    text(observation.get("model"), "preflight answering model")
    sha(observation.get("request_body_sha256"), "preflight request hash")
    attempts(observation.get("passed_over"), "passed-over attempts")
    if status == "invalid_answer":
        text(observation.get("reason"), "invalid preflight answer reason")
        return
    labels = ("keep_current", "needs_generation", "uncertain")
    decision = text(observation.get("decision"), "preflight decision")
    probabilities = obj(observation.get("probabilities"), "preflight probabilities")
    if decision not in labels or set(probabilities) != set(labels):
        raise ValueError("preflight probabilities must cover exactly the declared choices")
    confidence = number(observation.get("confidence"), "preflight confidence")
    values = {label: number(probabilities[label], "preflight probability") for label in labels}
    if not 0 <= confidence <= 1 or any(not 0 <= value <= 1 for value in values.values()):
        raise ValueError("preflight confidence and probabilities must be within zero and one")
    # Match Typesafeai_types.decode_choice's one-rounding-error-per-option bound.
    if abs(sum(values.values()) - 1) > sys.float_info.epsilon * len(labels):
        raise ValueError("preflight probabilities must sum to one")
    if values[decision] != max(values.values()):
        raise ValueError("preflight decision must have a highest probability")


def read_run(detail: Json) -> tuple[dict[str, Json], Json, dict[str, Json], float]:
    run = obj(obj(detail, "detail").get("run"), "run")
    if run.get("lane") != "librarian_exact":
        raise ValueError("both arms must be Librarian runs")
    availability = obj(run.get("payload_availability"), "payload_availability")
    for key in ("input", "output"):
        if obj(availability.get(key), key).get("state") != "available":
            raise ValueError(
                f"{key} must be available; missing evidence cannot be measured"
            )
    if run.get("status") not in ("succeeded", "failed", "cancelled"):
        raise ValueError("run must have a durably recorded terminal result")
    if "selected_slot" not in run:
        raise ValueError("terminal run must explicitly record selected_slot")
    selected_slot = run["selected_slot"]
    if selected_slot is not None:
        text(selected_slot, "selected_slot")
    output = obj(run.get("output"), "output")
    if run["status"] == "succeeded" and output.get("generation_path") == "full_lane":
        text(selected_slot, "successful full-lane selected_slot")
    if run["status"] == "failed":
        text(run.get("code"), "failed run code")
        text(run.get("detail"), "failed run detail")
    elif "code" in run or "detail" in run:
        raise ValueError("nonfailed run must not record code or detail")
    elapsed = number(run.get("elapsed_s"), "run elapsed_s")
    if elapsed < 0:
        raise ValueError("elapsed_s must be finite and nonnegative")
    source_input = obj(run.get("input"), "input")
    if source_input.get("kind") != "exact":
        raise ValueError("Librarian input must use the exact payload envelope")
    payload = source_input.get("payload")
    input_payload(payload, text(run.get("actor"), "run actor"))
    return run, payload, output, elapsed


def compare(manifest: Json) -> dict[str, Json]:
    data = obj(manifest, "manifest")
    source_head = sha(data.get("source_head"), "source_head", 40)
    config_hash = sha(data.get("config_sha256"), "config_sha256")
    environment = text(data.get("environment"), "environment")
    kind = text(data.get("evidence_kind"), "evidence_kind")
    if kind not in ("fixture", "native", "live"):
        raise ValueError("evidence_kind must distinguish fixture, native and live")
    pairs = data.get("pairs")
    if not isinstance(pairs, list) or not pairs:
        raise ValueError("pairs must be a nonempty list")
    sample_ids: set[str] = set()
    run_ids: set[str] = set()
    records: list[Json] = []
    deltas: list[float] = []
    skips = 0
    for item in pairs:
        pair = obj(item, "pair")
        sample_id = text(pair.get("sample_id"), "sample_id")
        if sample_id in sample_ids:
            raise ValueError("duplicate sample_id")
        sample_ids.add(sample_id)
        baseline, before, baseline_output, baseline_s = read_run(pair.get("baseline"))
        preflight, after, preflight_output, preflight_s = read_run(
            pair.get("preflight")
        )
        if text(baseline.get("actor"), "baseline actor") != text(preflight.get("actor"), "preflight actor"):
            raise ValueError("paired runs must use the same Keeper actor")
        for run in (baseline, preflight):
            run_id = text(run.get("run_id"), "run_id")
            if run_id in run_ids:
                raise ValueError("run reused across pairs or arms")
            run_ids.add(run_id)
        if digest(before) != digest(after):
            raise ValueError(
                f"{sample_id}: input payloads differ; freeze the same input"
            )
        if baseline_output.get("generation_path") != "full_lane":
            raise ValueError("baseline must enter the generation lane")
        baseline_jev = obj(baseline_output.get("jev_preflight"), "baseline preflight")
        if (
            baseline_jev.get("status") != "skipped"
            or baseline_jev.get("reason") != "librarian_preflight_disabled"
            or baseline_output.get("full_llm_skipped") is not False
        ):
            raise ValueError("baseline must record disabled preflight and no skip")
        validate_observation(baseline_jev)
        if "preflight_domain_rejection" not in baseline_output or baseline_output["preflight_domain_rejection"] is not None:
            raise ValueError("baseline must explicitly record null domain rejection")
        observation = obj(
            preflight_output.get("jev_preflight"), "preflight observation"
        )
        path = preflight_output.get("generation_path")
        skipped = preflight_output.get("full_llm_skipped")
        status = observation.get("status")
        if status in ("skipped", "ineligible", "question_unavailable"):
            raise ValueError("preflight arm must enter preflight evaluation")
        if status not in (
            "awaiting_answer",
            "failed",
            "invalid_answer",
            "judged",
        ):
            raise ValueError("unknown preflight observation status")
        validate_observation(observation)
        if status == "awaiting_answer" and path != "not_entered":
            raise ValueError("awaiting preflight cannot enter generation")
        if status == "judged" and observation.get("decision") not in (
            "keep_current",
            "needs_generation",
            "uncertain",
        ):
            raise ValueError("unknown preflight decision")
        if "preflight_domain_rejection" not in preflight_output:
            raise ValueError(
                "preflight must explicitly record domain rejection or null"
            )
        if not isinstance(skipped, bool) or path not in (
            "not_entered",
            "full_lane",
            "jev_no_change",
        ):
            raise ValueError("preflight route must be explicitly recorded")
        rejection = preflight_output.get("preflight_domain_rejection")
        keep_fallback = status == "judged" and observation.get("decision") == "keep_current" and path == "full_lane"
        if keep_fallback:
            text(rejection, "keep-current fallback domain rejection")
        elif rejection is not None:
            raise ValueError("domain rejection requires keep-current full-lane fallback")
        if path == "not_entered" and (
            status != "awaiting_answer"
            or preflight.get("status") not in ("failed", "cancelled")
            or preflight.get("selected_slot") is not None
        ):
            raise ValueError("generation not entered requires interrupted awaiting preflight without slot")
        if skipped:
            if (
                path != "jev_no_change"
                or observation.get("status") != "judged"
                or observation.get("decision") != "keep_current"
                or preflight.get("selected_slot") is not None
                or preflight_output.get("preflight_domain_rejection") is not None
            ):
                raise ValueError("contradictory no-change evidence")
            skips += 1
        elif path == "jev_no_change":
            raise ValueError("no-change route must record actual skip")
        delta = preflight_s - baseline_s
        deltas.append(delta)
        records.append(
            {
                "sample_id": sample_id,
                "input_sha256": digest(before),
                "baseline_run_id": baseline["run_id"],
                "preflight_run_id": preflight["run_id"],
                "baseline_status": baseline["status"],
                "preflight_status": preflight["status"],
                "baseline_failure": {key: baseline[key] for key in ("code", "detail")}
                    if baseline["status"] == "failed" else None,
                "preflight_failure": {key: preflight[key] for key in ("code", "detail")}
                    if preflight["status"] == "failed" else None,
                "preflight_observation": observation,
                "baseline_elapsed_s": baseline_s,
                "preflight_elapsed_s": preflight_s,
                "paired_delta_s": delta,
                "generation_path": path,
                "full_llm_skipped": skipped,
            }
        )
    return {
        "declared_source_head": source_head,
        "declared_config_sha256": config_hash,
        "declared_environment": environment,
        "declared_evidence_kind": kind,
        "manifest_sha256": digest(manifest),
        "pairs": records,
        "paired_median_delta_s": statistics.median(deltas),
        "recorded_generation_skips": skips,
        "actual_provider_request_count": "not_measured",
        "semantic_quality_regressions": "not_measured",
        "installed_tui_agreement": "not_measured",
        "goal_completion": "not_established",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    path = cast(Path, args.manifest)
    try:
        manifest = cast(Json, json.loads(path.read_text(), object_pairs_hook=unique_object))
        report = compare(manifest)
        rendered = json.dumps(report, indent=2, allow_nan=False)
    except (OSError, ValueError) as error:
        print(f"preflight measurement refused: {error}", file=sys.stderr)
        return 1
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
