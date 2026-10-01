"""Render supplied Fusion outputs as reports with explicit coverage and lineage.

No model calls, publication, credentials or delivery claims live in this worker.
The host retains and delivers reports through its existing evidence surface.
"""
from __future__ import annotations

from enum import Enum
import json
from dataclasses import dataclass
from pathlib import Path
import sys
import tomllib

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, Source, boolean, evidence, finite_json, object_value,
                      number, optional_string, row, serve, stable_id, string)
from fusion_sampling import coverage, validate_sampling_result


class RunState(Enum):
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class ComputationState(Enum):
    ANSWERED = "answered"
    HOST_ERROR = "host_error"
    OUTCOME_UNKNOWN = "outcome_unknown"
    INVALID_RESPONSE = "invalid_response"


class ComputationRole(Enum):
    PANEL = "panel"
    JUDGE = "judge"


class JudgeState(Enum):
    SYNTHESIZED = "synthesized"
    FAILED = "failed"


@dataclass(frozen=True)
class JudgeSynthesis:
    resolved_answer: str


@dataclass(frozen=True)
class JudgeFailure:
    failure_code: str
    error: str


def canonical_judge(post):
    judge = object_value(object_value(post.get("meta"), "Board post.meta").get("judge"),
                         "Board post.meta.judge")
    try:
        status = JudgeState(judge.get("status"))
    except (ValueError, TypeError) as error:
        raise InvalidInput("Unknown canonical Fusion judge status") from error
    if status is JudgeState.SYNTHESIZED:
        answer = judge.get("resolved_answer")
        if not isinstance(answer, str):
            raise InvalidInput("Canonical judge resolved_answer must be a string")
        return JudgeSynthesis(answer)
    if status is JudgeState.FAILED:
        return JudgeFailure(string(judge.get("failure_code"), "judge.failure_code"),
                            string(judge.get("error"), "judge.error"))


@dataclass(frozen=True)
class ReportContent:
    run_id: str
    heading: str
    post_headline: str | None
    judge: JudgeSynthesis | JudgeFailure | None
    failure: tuple[str, str] | None


@dataclass(frozen=True)
class ComputationContent:
    analysis_id: str
    role: ComputationRole
    status: ComputationState
    model: str | None
    text: str | None
    error: dict | None
    validation_error: str | None


@dataclass(frozen=True)
class ReportDraft:
    item: dict
    content: ReportContent | ComputationContent | None


def render_body(content: ReportContent | ComputationContent, *, complete: bool) -> str:
    if isinstance(content, ComputationContent):
        body = f"# Fusion 계산 보고서 · {content.role.value}\n\n분석: {content.analysis_id}\n"
        body += f"\n모델 호출 상태: {content.status.value}\n"
        body += f"\n실제 응답 모델: {content.model if content.model is not None else '확인되지 않음'}\n"
        body += "\n입력 범위: " + ("보존된 입력과 모델 결과" if complete else "불완전한 결과") + "\n"
        if content.text is not None:
            body += f"\n## 보존된 모델 응답\n\n{content.text}\n"
        elif content.validation_error is not None:
            body += "\nFusion에서 사용할 수 있는 텍스트 응답이 없습니다. 원본 응답은 입력 근거에 보존했습니다.\n"
            body += "\n## Fusion 응답 검증 실패\n\n" + content.validation_error + "\n"
        else:
            body += "\n보존된 모델 응답이 없습니다.\n"
        if content.error is not None:
            body += "\n## 실제 sampling 오류\n\n" + json.dumps(content.error, ensure_ascii=False) + "\n"
        return body + "\n전달 상태: 이 보고서의 전달·열람은 별도 기록으로 확인합니다.\n"
    body = f"# Fusion 보고서 · {content.heading}\n\n실행: {content.run_id}\n"
    body += "\n입력 범위: " + ("기록된 실행 결과" if complete else "불완전한 결과") + "\n"
    if content.failure is not None:
        code, error = content.failure
        body += f"\n실패: {code} · {error}\n"
    if content.post_headline is not None:
        body += f"\n## Board 기록 요약\n\n{content.post_headline}\n"
    if isinstance(content.judge, JudgeSynthesis):
        body += f"\n## 보존된 분석 내용\n\n{content.judge.resolved_answer}\n"
    elif isinstance(content.judge, JudgeFailure):
        body += f"\n## 심판 실패\n\n{content.judge.failure_code}: {content.judge.error}\n"
    else:
        body += "\n보존된 분석 내용이 아직 없습니다.\n"
    return body + "\n전달 상태: 이 보고서의 전달·열람은 별도 기록으로 확인합니다.\n"


def run_state(value):
    try:
        return RunState(value)
    except (ValueError, TypeError) as error:
        raise InvalidInput("Unknown Fusion run status") from error


def computation_report(source, observation, original, *, producer, producer_status,
                       upstream_coverage, base_complete):
    fields = object_value(original.get("fields"), "computation fields")
    computation = object_value(fields.get("computation"), "computation")
    analysis_id = string(computation.get("analysis_id"), "analysis_id")
    if string(original.get("subject_id"), "computation row.subject_id") != analysis_id:
        raise InvalidInput("Computation row subject differs from its analysis")
    try:
        role = ComputationRole(computation.get("role"))
        status = ComputationState(computation.get("status"))
    except (ValueError, TypeError) as error:
        raise InvalidInput("Unknown computation role or status") from error
    for key in ("model", "text", "stop_reason"):
        if key not in computation:
            raise InvalidInput(f"computation.{key} is required")
    model = optional_string(computation["model"], "computation.model")
    text = computation["text"]
    if text is not None and not isinstance(text, str):
        raise InvalidInput("computation.text must be text or null")
    optional_string(computation["stop_reason"], "computation.stop_reason")
    refs = object_value(fields.get("model_evidence"), "model_evidence")
    if set(refs) not in ({"request", "outcome"}, {"request"}):
        raise InvalidInput("model_evidence requires request and an optional outcome")
    if status is not ComputationState.OUTCOME_UNKNOWN and "outcome" not in refs:
        raise InvalidInput("Known computation outcomes require retained outcome evidence")
    for reference in evidence(list(refs.values())):
        if reference["sha256"] is None:
            raise InvalidInput("Model evidence requires immutable digests")
    input_complete = boolean(fields.get("input_complete"), "computation.input_complete")
    inputs = fields.get("input_coverage")
    if not isinstance(inputs, list):
        raise InvalidInput("computation.input_coverage must be an array")
    inputs = [coverage(item, "computation input coverage") for item in inputs]
    validate_sampling_result(computation, fields, refs, original.get("evidence"), observation.get("sampling_receipts"))
    response, error = fields["sampling_response"], fields["sampling_error"]
    validation_error = fields.get("validation_error")
    if status is ComputationState.ANSWERED:
        if model is None or not model.strip() or text is None or response is None or error is not None:
            raise InvalidInput("Answered computation requires its actual model response")
    complete = (base_complete and input_complete and bool(inputs)
                and all(item["complete"] for item in inputs)
                and status is not ComputationState.OUTCOME_UNKNOWN)
    item = row(source, observation, lane="fusion/report", subject=analysis_id,
               title=f"Fusion 계산 보고서 · {role.value} · {status.value}", kind="value", fields={
                   "format": "markdown", "analysis_id": analysis_id,
                   "computation": {key: value for key, value in computation.items() if key != "text"},
                   "computation_status": status.value, "model_evidence": refs, "input_complete": complete,
                   "validation_error": validation_error,
                   "scope": "supplied_fusion_computation", "content_trust": "untrusted_model_text",
                   "delivery_status": "not_attempted", "delivery_label": "아직 전달하지 않음"})
    item["id"] = stable_id(item["id"], original["id"], analysis_id, role.value, "computation-report")
    item["actor"] = None
    references = evidence(item["evidence"]) + evidence(original.get("evidence")) + evidence(list(refs.values()))
    item["evidence"] = list({json.dumps(reference, sort_keys=True): reference for reference in references}.values())
    display_model = model
    if validation_error is not None and isinstance(response.get("model"), str) and response["model"].strip():
        display_model = response["model"]
    return ReportDraft(item, ComputationContent(analysis_id, role, status, display_model, text, error,
                                               validation_error)), complete


def row_coordinates(original):
    # Full payloads remain readable in the host-owned immutable output blob.
    # Coordinates retain the exact rows without repeating their analysis body.
    for key in ("id", "lane_id", "subject_id"):
        string(original.get(key), f"row.{key}")
    if original.get("kind") not in ("event", "value", "relation"):
        raise InvalidInput("Unknown upstream row kind")
    number(original.get("observed_at"), "row.observed_at")
    if "actor" not in original:
        raise InvalidInput("row.actor is required")
    optional_string(original["actor"], "row.actor")
    if "clock" not in original:
        raise InvalidInput("row.clock is required")
    if original["clock"] is not None:
        clock = object_value(original["clock"], "row.clock")
        string(clock.get("domain"), "row.clock.domain")
        string(clock.get("value"), "row.clock.value")
    evidence(original.get("evidence"))
    related = original.get("related_ids")
    if not isinstance(related, list):
        raise InvalidInput("row.related_ids must be an array")
    for identity in related:
        string(identity, "row.related_ids entry")
    return {key: original[key] for key in (
        "id", "lane_id", "kind", "subject_id", "observed_at", "clock", "actor", "evidence", "related_ids")}


def reports(source: Source, observation: dict, *, recognized: bool):
    finite_json(observation, "Retained report input")
    producer = object_value(observation.get("producer"), "producer")
    for key in ("installation_id", "instance_id", "run_id",
                "configuration_revision", "package_revision"):
        string(producer.get(key), f"producer.{key}")
    sequence = producer.get("observation_seq")
    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 1:
        raise InvalidInput("producer.observation_seq must be a positive completed sequence")
    if producer.get("coverage_scope") != "whole_producer":
        raise InvalidInput("Report input requires whole-producer coverage")
    retained = evidence(observation.get("evidence"))
    if not retained or not any(item["sha256"] is not None for item in retained):
        raise InvalidInput("Report input requires a retained upstream output digest")
    output = object_value(observation.get("output"), "output")
    if not isinstance(output.get("rows"), list) or not isinstance(output.get("coverage"), list):
        raise InvalidInput("Output must contain rows and coverage arrays")
    upstream_coverage = [coverage(item, "output coverage") for item in output["coverage"]]
    coverage_by_source = {}
    for item in upstream_coverage:
        key = (item["source_id"], item["incarnation"])
        if key in coverage_by_source and coverage_by_source[key] != item:
            raise InvalidInput("Conflicting upstream coverage for the same source incarnation")
        coverage_by_source[key] = item
    producer_status = coverage(observation.get("producer_status"), "producer_status")
    if source.incarnation != producer["instance_id"]:
        raise InvalidInput("Source incarnation does not identify this producer instance")
    if (producer_status["incarnation"] != producer["instance_id"]
            or producer_status["source_id"] != producer["instance_id"]):
        raise InvalidInput("Producer status does not identify this producer instance")
    cursor = str(sequence)
    if (source.cursor != cursor or producer_status["cursor"] != cursor
            or observation.get("id") != f"{producer['instance_id']}/output/{cursor}"):
        raise InvalidInput("Report input coordinates disagree with the completed producer sequence")
    base_complete = (source.complete and recognized and producer_status["complete"]
                     and bool(upstream_coverage) and all(c["complete"] for c in upstream_coverage))
    groups = {}
    computed, computed_completions, raw_computed_rows = [], [], []
    skipped = set()
    ports = {f"{producer['instance_id']}/fusion/status": "fusion/status",
             f"{producer['instance_id']}/fusion/result": "fusion/result"}
    ports[f"{producer['instance_id']}/fusion/computation"] = "fusion/computation"
    for original in output["rows"]:
        original = object_value(original, "upstream row")
        lane = string(original.get("lane_id"), "row.lane_id")
        if lane not in ports:
            skipped.add(lane)
            continue
        lane = ports[lane]
        identity = string(original.get("id"), "row.id")
        if not identity.startswith(f"{producer['instance_id']}/{sequence}/"):
            raise InvalidInput("Fusion row identity disagrees with the producer sequence")
        row_coordinates(original)
        fields = object_value(original.get("fields"), "row.fields")
        boolean(fields.get("input_complete"), "row.input_complete")
        if lane == "fusion/computation":
            draft, complete = computation_report(source, observation, original,
                producer=producer, producer_status=producer_status,
                upstream_coverage=upstream_coverage, base_complete=base_complete)
            computed.append(draft)
            computed_completions.append(complete)
            raw_computed_rows.append(original)
            continue
        coordinates = (string(fields.get("source_id"), "row.fields.source_id"),
                       string(fields.get("incarnation"), "row.fields.incarnation"))
        if coordinates not in coverage_by_source:
            raise InvalidInput("Fusion row has no matching upstream source coverage")
        if lane == "fusion/status":
            run = object_value(fields.get("fusion_run"), "fusion_run")
            run_id = string(run.get("run_id"), "fusion_run.run_id")
            if not string(run.get("keeper"), "fusion_run.keeper").strip():
                raise InvalidInput("Fusion producer identity must not be blank")
            status = run_state(run.get("status"))
            if status is RunState.FAILED:
                string(run.get("failure_code"), "fusion_run.failure_code")
                string(run.get("error"), "fusion_run.error")
            elif run.get("failure_code") is not None or run.get("error") is not None:
                raise InvalidInput("Non-failed Fusion run contains failure metadata")
        else:
            if len(original["related_ids"]) != 1:
                raise InvalidInput("Fusion result must identify its status row")
            run_id = string(fields.get("fusion_run_id"), "fusion_run_id")
            status = run_state(fields.get("run_status"))
            post = object_value(fields.get("board_post"), "board_post")
            string(post.get("id"), "board_post.id")
            if not isinstance(post.get("body"), str):
                raise InvalidInput("board_post.body must be text")
            origin = object_value(post.get("origin"), "board_post.origin")
            if not string(origin.get("fusion_producer"), "board_post.origin.fusion_producer").strip():
                raise InvalidInput("Fusion producer identity must not be blank")
            if origin.get("source") != "fusion" or origin.get("fusion_run_id") != run_id:
                raise InvalidInput("Report evidence belongs to another Fusion run")
        if original["subject_id"] != run_id:
            raise InvalidInput("Fusion row subject does not identify its exact run")
        group = groups.setdefault(run_id, {})
        if lane in group:
            raise InvalidInput("Duplicate Fusion row for the same run and port")
        if group and next(iter(group.values()))[1] is not status:
            raise InvalidInput("Fusion status and result disagree")
        group[lane] = (original, status)

    result, completions = computed, computed_completions
    context = row(source, observation, lane="fusion/report-context",
                  subject=producer["instance_id"], title="Fusion report input provenance", kind="value",
                  fields={"producer": producer, "producer_status": producer_status,
                          "upstream_coverage": upstream_coverage,
                          "upstream_rows": [row_coordinates(value[0]) for group in groups.values()
                                            for value in group.values()],
                          "raw_computed_rows": raw_computed_rows,
                          "skipped_lanes": sorted(skipped), "input_complete": False,
                          "content_trust": "untrusted_source_text",
                          "scope": "supplied_fusion_output"})
    context["id"] = stable_id(context["id"], "context")
    context["actor"] = None
    for run_id, group in groups.items():
        status = next(iter(group.values()))[1]
        status_row = group.get("fusion/status")
        result_row = group.get("fusion/result")
        post = result_row[0]["fields"]["board_post"] if result_row else None
        if status_row and result_row:
            assert post is not None
            status_fields = status_row[0]["fields"]
            result_fields = result_row[0]["fields"]
            if result_row[0]["related_ids"] != [status_row[0]["id"]]:
                raise InvalidInput("Fusion result relation does not identify its paired status row")
            status_event = string(status_fields.get("source_event_id"), "status.source_event_id")
            if string(result_fields.get("source_event_id"), "result.source_event_id") != status_event:
                raise InvalidInput("Fusion status and result belong to different source events")
            if (status_fields.get("evidence_status") != "recorded"
                    or status_fields.get("board_post_id") != post["id"]
                    or status_fields["fusion_run"]["keeper"] != post["origin"]["fusion_producer"]):
                raise InvalidInput("Fusion status and result Board evidence disagree")
        complete = (base_complete and not skipped and status is not RunState.RUNNING
                    and post is not None
                    and (status is not RunState.FAILED or status_row is not None)
                    and all(item[0]["fields"]["input_complete"] for item in group.values()))
        # A failed run can have complete evidence. Completeness never means success.
        heading = {RunState.RUNNING: "분석 진행 중", RunState.COMPLETED: "분석 완료",
                   RunState.FAILED: "분석 실패"}[status]
        failure = None
        if status_row and status is RunState.FAILED:
            run = status_row[0]["fields"]["fusion_run"]
            failure = (run["failure_code"], run["error"])
        judge = canonical_judge(post) if post else None
        if status is RunState.COMPLETED and isinstance(judge, JudgeFailure):
            raise InvalidInput("Completed Fusion run cannot carry a failed canonical judge")
        content = ReportContent(run_id, heading, post["body"] if post else None, judge, failure)
        item = row(source, observation, lane="fusion/report", subject=run_id,
                   title=f"Fusion 보고서 · {heading}", kind="value", fields={
                       "format": "markdown", "fusion_run_id": run_id,
                       "run_status": status.value, "input_complete": complete,
                       "board_post_id": post["id"] if post else None,
                       "scope": "supplied_fusion_output", "content_trust": "untrusted_source_text",
                       "delivery_status": "not_attempted",
                       "delivery_label": "아직 전달하지 않음"})
        item["id"] = stable_id(item["id"], run_id, "report")
        item["actor"] = None
        item["evidence"] = []
        item["related_ids"] = [context["id"]]
        result.append(ReportDraft(item, content))
        completions.append(complete)
    complete = bool(result) and all(completions) and not skipped
    if result:
        context["fields"]["input_complete"] = complete
        for draft in result:
            draft.item["related_ids"] = [context["id"]]
        result.insert(0, ReportDraft(context, None))
    return result, complete, skipped


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    rows, statuses = [], []
    if not sources:
        return {"rows": [], "coverage": [{"source_id": "fusion-report/input",
                "incarnation": "unobserved", "cursor": None, "complete": False,
                "detail": "No Fusion output supplied; no report is available"}]}
    for source in sources:
        accepted = [obs for obs in source.observations if obs.get("kind") == "lane_output"]
        skipped = {str(obs.get("kind", "untyped")) for obs in source.observations
                   if obs.get("kind") != "lane_output"}
        source_rows, completions = [], []
        for obs in accepted:
            projected, complete, skipped_lanes = reports(source, obs, recognized=not skipped)
            source_rows.extend(projected)
            completions.append(complete)
            skipped.update(skipped_lanes)
        status = source.coverage(skipped)
        status["complete"] = bool(completions) and all(completions) and not skipped
        if not status["complete"]:
            status["detail"] = "; ".join(filter(None, (status["detail"],
                "Report input is partial; run success, delivery and reading are separate states")))
            for draft in source_rows:
                draft.item["fields"]["input_complete"] = False
        for draft in source_rows:
            if draft.content is not None:
                draft.item["fields"]["body"] = render_body(
                    draft.content, complete=draft.item["fields"]["input_complete"])
            rows.append(draft.item)
        statuses.append(status)
    return {"rows": rows, "coverage": statuses}


if __name__ == "__main__":
    manifest = tomllib.loads(Path(__file__).with_name("lane.toml").read_text())
    serve("masc-fusion-report", observe, version="0.2.0",
          text_summary=lambda output: (
              "Fusion reports and their retained input contexts are in structuredContent."
              if any(item["lane_id"] == "fusion/report" for item in output["rows"])
              else "No Fusion reports are available; inspect structuredContent coverage for missing inputs."),
          max_reply_bytes=manifest["resources"]["max_reply_bytes"])
