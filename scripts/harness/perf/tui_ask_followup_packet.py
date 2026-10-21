#!/usr/bin/env python3
"""Freeze explicitly supplied files into a descriptive Ask follow-up packet.

No TUI, server, provider or input artifact is executed. Stable individual reads
do not prove an atomic cohort snapshot, exhaustive capture or execution identity.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time

import tui_ask_followup_report as report


CONDITION_FILES = {"fixture": "fixture_sha256", "workspace_snapshot": "workspace_snapshot_sha256",
                   "action": "action_sha256", "server_binary": "server_binary_sha256", "terminal": "terminal_sha256"}


def validate_plan(plan):
    report.fields(plan, {"schema_version", "cases"})
    report.require(type(plan["schema_version"]) is int and plan["schema_version"] == 1, "unsupported plan version")
    report.require(type(plan["cases"]) is list, "missing planned cases")
    labels, owners = set(), set()
    for case in plan["cases"]:
        report.fields(case, {"id", "before", "after"})
        label = report.text(case["id"])
        report.require(label not in labels, "duplicate case identity")
        labels.add(label)
        for name in ("before", "after"):
            arm = case[name]
            report.fields(arm, report.ARM_FIELDS-{"conditions"} | {"condition_files"})
            report.require(type(arm["instances"]) is list and arm["instances"], "missing selected instances")
            instances = [report.text(value) for value in arm["instances"]]
            report.require(len(set(instances)) == len(instances) and not owners.intersection(instances), "instance reused across cohorts")
            owners.update(instances)
            report.require(type(arm["attempts"]) is list, "missing independent supplied roster")
            attempts = [report.identity(value) for value in arm["attempts"]]
            report.require(len(set(attempts)) == len(attempts) and all(value[0] in instances for value in attempts), "duplicate or foreign supplied attempt")
            if arm["source_commit"] is not None:
                report.digest(arm["source_commit"], 40)
            report.fields(arm["condition_files"], CONDITION_FILES)
            for value in [arm["binary"], *arm["condition_files"].values()]:
                if value is not None:
                    report.text(value)
            for role in ("admissions", "logs"):
                report.require(type(arm[role]) is list, "missing planned artifact list")
                for value in arm[role]:
                    report.text(value)


def write_bytes(path, data):
    with path.open("xb") as channel:
        channel.write(data)


def write_json(path, value):
    write_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2)+"\n").encode("utf-8"))


def materialize(plan, source_root, output, receipt):
    validate_plan(plan)
    (output/"artifacts").mkdir(mode=0o700)
    inputs, written = {}, set()
    errors = receipt["errors"]

    def capture(name):
        if name in inputs:
            return inputs[name]
        try:
            # Resolve only for overlap refusal; actual reads still use the
            # original pinned no-symlink root/path reader, never this target.
            data = report.artifact_bytes(source_root, name)
            target = Path(os.path.realpath(source_root/name))
            report.require(not target.is_relative_to(Path(os.path.realpath(output))), "input belongs to newly created output")
        except (report.EvidenceError, OSError) as error:
            errors.append({"source_path": name, "error": str(error)})
            inputs[name] = None
            return None
        digest = hashlib.sha256(data).hexdigest()
        relative = "artifacts/"+digest
        if digest not in written:
            write_bytes(output/relative, data)
            written.add(digest)
        declaration = {"path": relative, "sha256": digest}
        inputs[name] = declaration
        receipt["copied_artifacts"].append({"source_path": name, **declaration, "bytes": len(data)})
        return declaration

    def arm(value):
        conditions = {}
        for source, destination in CONDITION_FILES.items():
            name = value["condition_files"][source]
            item = capture(name) if name is not None else None
            conditions[destination] = item["sha256"] if item is not None else None
        binary = capture(value["binary"]) if value["binary"] is not None else None
        artifacts = {}
        for role in ("admissions", "logs"):
            artifacts[role] = [item for name in value[role] if (item := capture(name)) is not None]
        return {"instances": value["instances"], "attempts": value["attempts"], "conditions": conditions,
                "source_commit": value["source_commit"], "binary": binary, **artifacts}

    packet = {"schema_version": 2, "cases": [{"id": case["id"], "before": arm(case["before"]), "after": arm(case["after"])}
                                            for case in plan["cases"]]}
    validation = report.analyze(packet, output)
    if errors:
        validation["materialization_errors"] = list(errors)
        for case in validation["cases"]:
            case["errors"].append("packet materialization incomplete")
            case["comparison"] = report.comparison_without_deltas(case["comparison"]["declared_conditions_match"])
    for case in validation["cases"]:
        for scope in ("case", "before", "after"):
            for error in (case if scope == "case" else case[scope])["errors"]:
                errors.append({"case_index": case["case_index"], "scope": scope, "error": error})
    write_json(output/"validation.json", validation)
    if not errors:
        write_json(output/"packet.json", packet)
        receipt["status"] = "materialized"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    started_ns = time.perf_counter_ns()
    try:
        original = args.plan.read_bytes()
        # mkdir reserves a new output atomically; existing empty directories,
        # symlinks and files are refused rather than replaced or reused.
        args.output.mkdir(mode=0o700)
    except OSError:
        print("Plan must be readable and output must be a new directory below an existing parent.", file=sys.stderr)
        return 2
    receipt = {"schema_version": 1, "kind": "descriptive_ask_followup_materialization", "status": "failed",
               "original_plan": "source-plan.json", "plan_sha256": hashlib.sha256(original).hexdigest(),
               "source_root": str(args.source_root.absolute()), "copied_artifacts": [], "errors": [],
               "execution_verified": False, "complete_capture_verified": False, "atomic_cohort_snapshot_verified": False,
               "clock": "python_perf_counter_ns", "materialization_started_ns": started_ns}
    try:
        write_bytes(args.output/"source-plan.json", original)
        receipt["materializer_source_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        receipt["reader_source_sha256"] = hashlib.sha256(Path(report.__file__).read_bytes()).hexdigest()
        materialize(report.load_json(original), args.source_root, args.output, receipt)
    except (report.EvidenceError, OSError) as error:
        receipt["errors"].append({"error": str(error)})
    receipt["observed_ns"] = time.perf_counter_ns()
    try:
        write_json(args.output/"materialization.json", receipt)
    except OSError:
        print("Materialization receipt could not be written; output is incomplete.", file=sys.stderr)
        return 2
    if receipt["status"] != "materialized":
        print("Packet not published; see " + str(args.output/"materialization.json"), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
