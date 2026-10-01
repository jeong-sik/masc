"""Render supplied Fusion outputs as reports with explicit coverage and lineage.

No model calls, publication, credentials or delivery claims live in this worker.
The host retains and delivers reports through its existing evidence surface.
"""
from __future__ import annotations

from enum import Enum
from dataclasses import dataclass
from pathlib import Path
import sys
import tomllib

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, Source, boolean, evidence, object_value,
                      number, optional_string, row, serve, stable_id, string)


class RunState(Enum):
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


@dataclass(frozen=True)
class ReportContent:
    run_id: str
    heading: str
    post_body: str | None
    failure: tuple[str, str] | None


@dataclass(frozen=True)
class ReportDraft:
    item: dict
    content: ReportContent | None


def render_body(content: ReportContent, *, complete: bool) -> str:
    body = f"# Fusion 보고서 · {content.heading}\n\n실행: {content.run_id}\n"
    body += "\n입력 범위: " + ("기록된 실행 결과" if complete else "불완전한 결과") + "\n"
    if content.failure is not None:
        code, error = content.failure
        body += f"\n실패: {code} · {error}\n"
    if content.post_body is not None:
        body += f"\n## 보존된 분석 내용\n\n{content.post_body}\n"
    else:
        body += "\n보존된 분석 내용이 아직 없습니다.\n"
    return body + "\n전달 상태: 이 보고서의 전달·열람은 별도 기록으로 확인합니다.\n"


def run_state(value):
    try:
        return RunState(value)
    except (ValueError, TypeError) as error:
        raise InvalidInput("Unknown Fusion run status") from error


def coverage(value, label):
    value = object_value(value, label)
    for key in ("source_id", "incarnation"):
        string(value.get(key), f"{label}.{key}")
    for key in ("cursor", "detail"):
        if key not in value:
            raise InvalidInput(f"{label}.{key} is required")
        optional_string(value[key], f"{label}.{key}")
    boolean(value.get("complete"), f"{label}.complete")
    return value


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


def output_selection(producer):
    selected = object_value(producer.get("output_selection"), "producer.output_selection")
    if set(selected) == {"all_lanes"} and selected["all_lanes"] is True:
        return None
    lanes = selected.get("lanes")
    if (set(selected) != {"lanes"} or not isinstance(lanes, list) or not lanes
            or any(not isinstance(lane, str) or not lane.strip() for lane in lanes)
            or len(lanes) != len(set(lanes))):
        raise InvalidInput("Invalid producer output selection")
    return set(lanes)


def reports(source: Source, observation: dict, *, recognized: bool):
    producer = object_value(observation.get("producer"), "producer")
    for key in ("installation_id", "instance_id", "run_id",
                "configuration_revision", "package_revision"):
        string(producer.get(key), f"producer.{key}")
    sequence = producer.get("observation_seq")
    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 1:
        raise InvalidInput("producer.observation_seq must be a positive completed sequence")
    if producer.get("coverage_scope") != "whole_producer":
        raise InvalidInput("Report input requires whole-producer coverage")
    selected_lanes = output_selection(producer)
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
    board_post_owners = {}
    skipped = set()
    ports = {f"{producer['instance_id']}/fusion/status": "fusion/status",
             f"{producer['instance_id']}/fusion/result": "fusion/result"}
    for original in output["rows"]:
        original = object_value(original, "upstream row")
        lane = string(original.get("lane_id"), "row.lane_id")
        if lane not in ports:
            skipped.add(lane)
            continue
        lane = ports[lane]
        if selected_lanes is not None and lane not in selected_lanes:
            raise InvalidInput("Fusion row is excluded by producer output selection")
        identity = string(original.get("id"), "row.id")
        if not identity.startswith(f"{producer['instance_id']}/{sequence}/"):
            raise InvalidInput("Fusion row identity disagrees with the producer sequence")
        row_coordinates(original)
        fields = object_value(original.get("fields"), "row.fields")
        coordinates = (string(fields.get("source_id"), "row.fields.source_id"),
                       string(fields.get("incarnation"), "row.fields.incarnation"))
        if coordinates not in coverage_by_source:
            raise InvalidInput("Fusion row has no matching upstream source coverage")
        boolean(fields.get("input_complete"), "row.input_complete")
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
            post_id = string(post.get("id"), "board_post.id")
            previous_run = board_post_owners.setdefault(post_id, run_id)
            if previous_run != run_id:
                raise InvalidInput("One Board post cannot identify two Fusion runs")
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

    result, completions = [], []
    context = row(source, observation, lane="fusion/report-context",
                  subject=producer["instance_id"], title="Fusion report input provenance", kind="value",
                  fields={"producer": producer, "producer_status": producer_status,
                          "upstream_coverage": upstream_coverage,
                          "upstream_rows": [row_coordinates(value[0]) for group in groups.values()
                                            for value in group.values()],
                          "skipped_lanes": sorted(skipped), "input_complete": False,
                          "scope": "supplied_fusion_output"})
    context["id"] = stable_id(context["id"], "context")
    context["actor"] = None
    for run_id, group in groups.items():
        status = next(iter(group.values()))[1]
        status_row = group.get("fusion/status")
        result_row = group.get("fusion/result")
        post = result_row[0]["fields"]["board_post"] if result_row else None
        if status_row and result_row:
            status_fields = status_row[0]["fields"]
            result_fields = result_row[0]["fields"]
            if any(status_fields[key] != result_fields[key] for key in ("source_id", "incarnation")):
                raise InvalidInput("Fusion status and result belong to different source coordinates")
            if result_row[0]["related_ids"] != [status_row[0]["id"]]:
                raise InvalidInput("Fusion result relation does not identify its paired status row")
            if evidence(status_row[0]["evidence"]) != evidence(result_row[0]["evidence"]):
                raise InvalidInput("Fusion status and result cite different snapshots")
            status_event = string(status_fields.get("source_event_id"), "status.source_event_id")
            if string(result_fields.get("source_event_id"), "result.source_event_id") != status_event:
                raise InvalidInput("Fusion status and result belong to different source events")
            if (status_fields.get("evidence_status") != "recorded"
                    or status_fields.get("board_post_id") != post["id"]
                    or status_fields["fusion_run"]["keeper"] != post["origin"]["fusion_producer"]):
                raise InvalidInput("Fusion status and result Board evidence disagree")
        complete = (base_complete and not skipped and status is not RunState.RUNNING
                    and post is not None
                    and status_row is not None
                    and all(item[0]["fields"]["input_complete"] for item in group.values()))
        # A failed run can have complete evidence. Completeness never means success.
        heading = {RunState.RUNNING: "분석 진행 중", RunState.COMPLETED: "분석 완료",
                   RunState.FAILED: "분석 실패"}[status]
        failure = None
        if status_row and status is RunState.FAILED:
            run = status_row[0]["fields"]["fusion_run"]
            failure = (run["failure_code"], run["error"])
        content = ReportContent(run_id, heading, post["body"] if post else None, failure)
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
        result.insert(0, ReportDraft(context, None))
    return result, complete, skipped


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    aliases = [source.source_id for source in sources]
    if len(set(aliases)) != len(aliases):
        raise InvalidInput("Fusion report source aliases must be distinct")
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
    serve("masc-fusion-report", observe,
          text_summary=lambda output: (
              "Fusion reports are retained in structuredContent with exact upstream coordinates and evidence."
              if any(item["lane_id"] == "fusion/report" for item in output["rows"])
              else "No Fusion reports are available; inspect structuredContent coverage for missing inputs."),
          max_reply_bytes=manifest["resources"]["max_reply_bytes"])
