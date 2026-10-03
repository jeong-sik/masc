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
    elapsed = run.get("elapsed_s")
    if isinstance(elapsed, bool) or not isinstance(elapsed, (int, float)):
        raise ValueError("elapsed_s must be numeric")
    if not math.isfinite(elapsed) or elapsed < 0:
        raise ValueError("elapsed_s must be finite and nonnegative")
    payload = obj(run.get("input"), "input").get("payload")
    actual_input = obj(
        obj(payload, "input payload").get("actual_input"), "actual_input"
    )
    prompt = obj(actual_input.get("prompt"), "prompt")
    sha(prompt.get("rendered_sha256"), "rendered prompt hash")
    return run, payload, output, float(elapsed)


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
        manifest = cast(Json, json.loads(path.read_text()))
        report = compare(manifest)
    except (OSError, ValueError) as error:
        print(f"preflight measurement refused: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
