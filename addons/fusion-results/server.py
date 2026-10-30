"""Project captured Fusion detail responses into composable Lane outputs.

This worker reads only supplied snapshots. Fusion computation, credentials,
durable acceptance, projection and delivery remain owned by the existing host.
"""
from __future__ import annotations

from enum import Enum
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from fusion_judge import JudgeFailure, canonical_judge
from protocol import (InvalidInput, Source, evidence, number, object_value,
                      row, serve, stable_id, string)


class RunState(Enum):
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class RunStage(Enum):
    ACCEPTED = "accepted"
    PANEL = "panel"
    JUDGE = "judge"
    COMPUTED = "computed"
    RECORDING_EVIDENCE = "recording_evidence"
    COMPLETED = "completed"
    FAILED = "failed"


class EvidenceState(Enum):
    RECORDED = "recorded"
    PENDING = "pending"
    ABSENT = "absent"


TOPOLOGIES = frozenset(("simple", "refine", "conditional", "judge_of_judges",
                        "staged_judge_of_judges"))


def state(enum, value, label):
    try:
        return enum(value)
    except (ValueError, TypeError) as error:
        raise InvalidInput(f"Unknown {label}: {value!r}") from error


def progress_count(progress: dict, key: str) -> int:
    count = progress.get(key)
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        raise InvalidInput(f"run.progress.{key} must be a nonnegative integer")
    return count


def validate_progress(run: dict, run_state: RunState) -> None:
    stage = state(RunStage, run.get("stage"), "Fusion run stage")
    if "progress" not in run:
        raise InvalidInput("run.progress is required")
    progress = run["progress"]
    if run_state is not RunState.RUNNING:
        expected = RunStage.COMPLETED if run_state is RunState.COMPLETED else RunStage.FAILED
        if stage is not expected or progress is not None:
            raise InvalidInput("Fusion status, stage and progress disagree")
        return
    if stage not in (RunStage.ACCEPTED, RunStage.PANEL, RunStage.JUDGE,
                     RunStage.COMPUTED, RunStage.RECORDING_EVIDENCE):
        raise InvalidInput("Running Fusion requires a running stage")
    progress = object_value(progress, "run.progress")
    if stage is RunStage.ACCEPTED:
        return
    expected = progress_count(progress, "panel_expected")
    if stage is RunStage.PANEL:
        return
    answered = progress_count(progress, "panel_answered")
    failed = progress_count(progress, "panel_failed")
    if answered + failed != expected:
        raise InvalidInput("Fusion answered + failed counts must equal panel_expected")


def parse_detail(value: object) -> tuple[dict, RunState, EvidenceState, dict | None]:
    detail = object_value(value, "Fusion detail")
    string(detail.get("generated_at"), "generated_at")
    run = object_value(detail.get("run"), "run")
    for key in ("run_id", "keeper", "preset"):
        string(run.get(key), f"run.{key}")
    if not isinstance(run.get("topology"), str) or run["topology"] not in TOPOLOGIES:
        raise InvalidInput("Unknown Fusion topology")
    started = number(run.get("started_at"), "run.started_at")
    if started < 0:
        raise InvalidInput("run.started_at must be nonnegative")
    run_state = state(RunState, run.get("status"), "Fusion run status")
    validate_progress(run, run_state)
    if run_state is RunState.RUNNING:
        if "finished_at" not in run or run["finished_at"] is not None:
            raise InvalidInput("Running Fusion has a finished_at")
    else:
        finished = number(run.get("finished_at"), "run.finished_at")
        if finished < started:
            raise InvalidInput("Fusion finished_at precedes started_at")
    if run_state is RunState.FAILED:
        string(run.get("error"), "run.error")
        string(run.get("failure_code"), "run.failure_code")
    elif "error" in run or "failure_code" in run:
        raise InvalidInput("Only failed Fusion may supply failure fields")
    if ("decision" in run) != ("summary" in run):
        raise InvalidInput("Fusion decision preview and summary must appear together")
    if "decision" in run:
        if run_state is not RunState.COMPLETED:
            raise InvalidInput("Only completed Fusion may supply a decision preview")
        for key in ("decision", "summary"):
            if not isinstance(run[key], str):
                raise InvalidInput(f"run.{key} must be a string")
    retained = object_value(detail.get("evidence"), "Fusion evidence")
    evidence_state = state(EvidenceState, retained.get("status"), "Fusion evidence status")
    if evidence_state is EvidenceState.PENDING and run_state is not RunState.RUNNING:
        raise InvalidInput("Pending Fusion evidence requires a running run")
    if evidence_state is EvidenceState.ABSENT and run_state is RunState.RUNNING:
        raise InvalidInput("Absent Fusion evidence requires a terminal run")
    if "post" not in retained:
        raise InvalidInput("Fusion evidence.post is required")
    post = retained["post"]
    if evidence_state is EvidenceState.RECORDED:
        post = object_value(post, "Fusion evidence.post")
        string(post.get("id"), "post.id")
        if not isinstance(post.get("body"), str):
            raise InvalidInput("Recorded Fusion evidence requires a string post.body")
        origin = object_value(post.get("origin"), "post.origin")
        if origin.get("source") != "fusion" or origin.get("fusion_run_id") != run["run_id"]:
            raise InvalidInput("Board post does not identify this exact Fusion run")
        producer = string(origin.get("fusion_producer"), "post.origin.fusion_producer")
        if not producer.strip() or producer != run["keeper"]:
            raise InvalidInput("Board post does not identify this exact Fusion producer")
        judge = canonical_judge(post)
        if run_state is RunState.COMPLETED and isinstance(judge, JudgeFailure):
            raise InvalidInput("Completed Fusion run cannot carry a failed canonical judge")
        if run_state is RunState.FAILED:
            if not isinstance(judge, JudgeFailure):
                raise InvalidInput("Failed Fusion run requires a failed canonical judge")
            if judge.failure_code != run["failure_code"] or judge.error != run["error"]:
                raise InvalidInput("Failed canonical judge must agree with the Fusion run failure")
    elif post is not None:
        raise InvalidInput("Unrecorded Fusion evidence must have a null post")
    return run, run_state, evidence_state, post


def project(source: Source, observation: dict) -> tuple[list[dict], bool]:
    run, run_state, evidence_state, post = parse_detail(observation.get("detail"))
    if source.incarnation != run["run_id"]:
        raise InvalidInput("Fusion source incarnation does not identify this exact run")
    snapshots = evidence(observation.get("evidence"))
    if not snapshots or snapshots[0]["sha256"] is None:
        raise InvalidInput("Fusion observation requires immutable snapshot evidence")
    run_id = run["run_id"]
    complete = (source.complete and run_state is not RunState.RUNNING
                and evidence_state is EvidenceState.RECORDED)
    status = row(source, observation, lane="fusion/status", subject=run_id,
                 title=f"Fusion {run_state.value}: {run_id}", kind="event",
                 fields={"fusion_run": run, "evidence_status": evidence_state.value,
                         "board_post_id": post["id"] if post is not None else None,
                         "input_complete": complete,
                         "scope": "captured_fusion_detail"})
    status["id"] = stable_id(status["id"], "status")
    # The snapshot exporter is not the panel or judge actor.
    status["actor"] = None
    rows = [status]
    if post is not None:
        result = row(source, observation, lane="fusion/result", subject=run_id,
                     title=f"Retained Fusion evidence: {run_id}", kind="value",
                     fields={"fusion_run_id": run_id, "topology": run["topology"],
                             "run_status": run_state.value, "board_post": post,
                             "decision_preview": run.get("decision"),
                             "summary": run.get("summary"),
                             "scope": "captured_board_evidence",
                             "input_complete": complete})
        result["id"] = stable_id(result["id"], "result")
        result["actor"] = None
        result["related_ids"] = [status["id"]]
        rows.append(result)
    return rows, complete


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    rows, coverage = [], []
    if not sources:
        return {"rows": [], "coverage": [{
            "source_id": "fusion-results/input", "incarnation": "unobserved",
            "cursor": None, "complete": False, "detail": "No Fusion snapshot supplied"}]}
    for source in sources:
        skipped = set()
        completed = []
        source_rows = []
        for observation in source.observations:
            if observation.get("kind") != "fusion_run":
                skipped.add(str(observation.get("kind", "untyped")))
                continue
            projected, complete = project(source, observation)
            source_rows.extend(projected)
            completed.append(complete)
        status = source.coverage(skipped)
        status["complete"] = bool(completed) and all(completed) and not skipped
        if skipped:
            for item in source_rows:
                item["fields"]["input_complete"] = False
        rows.extend(source_rows)
        if not status["complete"]:
            reason = "Snapshot lacks a terminal run with recorded exact-run evidence; no delivery or read success is inferred"
            status["detail"] = "; ".join(filter(None, (status["detail"], reason)))
        coverage.append(status)
    return {"rows": rows, "coverage": coverage}


def text_summary(output: dict) -> str:
    if any(item["lane_id"] == "fusion/result" for item in output["rows"]):
        return "Fusion status and retained Board evidence are available in structuredContent with exact run identity."
    if output["rows"]:
        return "Fusion status is available in structuredContent with exact run identity; no retained Board evidence is available in this capture."
    return "No Fusion snapshot rows are available; structuredContent reports the observation coverage."


if __name__ == "__main__":
    manifest = tomllib.loads(Path(__file__).with_name("lane.toml").read_text())
    serve("masc-fusion-results", observe,
          text_summary=text_summary,
          max_reply_bytes=manifest["resources"]["max_reply_bytes"])
