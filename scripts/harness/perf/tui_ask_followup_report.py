#!/usr/bin/env python3
"""Offline descriptive Ask follow-up cohorts from supplied Log.Ring artifacts.

Never starts TUI/server/provider processes. Declarations and hashed bytes do not
prove execution, installation, useful Task progress or a performance verdict.
"""
from __future__ import annotations

import argparse
from collections import Counter
from decimal import Decimal
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
import sys


class EvidenceError(ValueError):
    pass


def require(value, message):
    if not value:
        raise EvidenceError(message)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON member")
        result[key] = value
    return result


def load_json(value):
    def nonfinite(_value):
        raise EvidenceError("non-finite number")
    def finite(raw):
        result = float(raw)
        require(math.isfinite(result), "non-finite number")
        return result
    def valid_strings(item):
        if type(item) is str:
            item.encode("utf-8")
        elif type(item) is list:
            for child in item:
                valid_strings(child)
        elif type(item) is dict:
            for key, child in item.items():
                valid_strings(key); valid_strings(child)
    try:
        result = json.loads(value, object_pairs_hook=unique, parse_constant=nonfinite, parse_float=finite)
        valid_strings(result)
        return result
    except (ValueError, UnicodeError, RecursionError) as error:
        raise EvidenceError("invalid JSON or UTF-8") from error


def fields(value, names):
    require(type(value) is dict and set(value) == set(names), "unsupported object fields")


def text(value, nonempty=True):
    require(type(value) is str and (value or not nonempty), "invalid string fact")
    return value


def integer(value, maximum=None):
    require(type(value) is int and value >= 0 and (maximum is None or value <= maximum), "invalid integer fact")
    return value


def ns(value):
    return integer(value, 2**63-1)  # Producer Int64 contract; JSON integer, not startup's string clock.


def digest(value, length=64):
    require(type(value) is str and len(value) == length and set(value) <= set("0123456789abcdef"), "invalid digest")
    return value


CONDITIONS = {"fixture_sha256", "workspace_snapshot_sha256", "action_sha256", "server_binary_sha256", "terminal_sha256"}
ARM_FIELDS = {"instances", "attempts", "admissions", "conditions", "source_commit", "binary", "logs"}
ENVELOPE = {"seq", "ts", "level", "source", "module", "keeper_name", "turn_id", "message", "details", "category"}
DETAILS = {"event", "keeper", "ask_id", "request", "origin", "read_admission_started_ns", "submission_started_ns",
           "question_source_turn_ref", "phase", "source", "received_ns", "observed_ns", "ui_admitted", "source_applied",
           "admitted_ns", "completion", "sources", "admission_capture"}
PHASES = {"started", "worker_entered", "producer_returned", "cancelled", "cancel_requested", "registration_released", "finished", "source_processed"}
OUTCOMES = {"complete", "failed", "cancelled", "not_started", "withdrawn"}
METRICS = {"admission_capture_ns": ("capture_started", "capture_returned"), "admission_to_start_log_ns": (None, "started"), "admission_to_worker_ns": (None, "worker_entered"),
           "worker_to_producer_ns": ("worker_entered", "producer"), "admission_to_ui_ns": (None, "finished"),
           "producer_to_ui_ns": ("producer", "finished"), "admission_to_registration_release_ns": (None, "registration_released")}
SOURCES = {"reaction_evidence": "Wake/turn observations", "tool_actions": "Tool result observations", "linked_task": "Original Task observation"}
SOURCE_METRICS = {"admission_to_source_received_ns": ("read_admission_started_ns", "received_ns", "Read admission to source receipt"),
                  "admission_to_source_processed_ns": ("read_admission_started_ns", "observed_ns", "Read admission to UI processing"),
                  "source_received_to_processed_ns": ("received_ns", "observed_ns", "Source receipt to UI processing")}
SOURCE_STATES = ("observed", "unobserved", "ambiguous", "invalid_attempt")


def artifact_bytes(root, name):
    name = text(name)
    require("\x00" not in name, "artifact path contains NUL")
    path = PurePosixPath(name)
    require(not path.is_absolute() and path.parts and all(p not in {".", ".."} for p in path.parts)
            and str(path) == name, "artifact path must be canonical and relative")
    try:
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except (OSError, ValueError) as error:
        raise EvidenceError("artifact root inaccessible") from error
    try:
        for part in path.parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        leaf = os.open(path.parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(leaf, "rb") as channel:
            before = os.fstat(channel.fileno())
            require(stat.S_ISREG(before.st_mode), "artifact is not a regular file")
            data = channel.read()
            after = os.fstat(channel.fileno())
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                    == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "artifact changed while reading")
    except OSError as error:
        raise EvidenceError("artifact missing, inaccessible or symlinked") from error
    finally:
        os.close(directory)
    return data


def artifact(root, declaration):
    fields(declaration, {"path", "sha256"})
    expected = digest(declaration["sha256"])
    data = artifact_bytes(root, declaration["path"])
    require(hashlib.sha256(data).hexdigest() == expected, "artifact digest mismatch")
    return data


def identity(value):
    fields(value, {"instance_id", "request", "read_admission_started_ns"})
    return text(value["instance_id"]), integer(value["request"]), ns(value["read_admission_started_ns"])


def origin(value):
    fields(value, {"tui_instance_id", "client", "workspace", "server_identity_at_admission"})
    text(value["tui_instance_id"])
    for key, names in (("client", {"reported_version"}), ("workspace", {"base_path", "masc_root"}),
                       ("server_identity_at_admission", {"reported_version", "reported_binary_commit"})):
        fields(value[key], names)
        for item in value[key].values():
            text(item, nonempty=key == "workspace")
    return value


def completion(value):
    if value is not None:
        fields(value, {"state"})
        require(value["state"] in OUTCOMES, "unsupported terminal cause")
        return value["state"]
    return None


def capture_receipt(value, admitted, observed):
    require(type(value) is dict, "invalid admission capture receipt")
    state = value.get("state")
    require(state in {"unavailable", "returned", "failed"}, "unsupported admission capture state")
    fields(value, {"state"} if state == "unavailable" else {"state", "capture_started_ns", "capture_returned_ns"})
    if state != "unavailable":
        require(admitted <= ns(value["capture_started_ns"]) <= ns(value["capture_returned_ns"]) <= observed,
                "invalid admission capture receipt clocks")
    return value


def record(entry):
    fields(entry, ENVELOPE)
    integer(entry["seq"]); text(entry["ts"]); text(entry["message"], False)
    if entry["turn_id"] is not None:
        integer(entry["turn_id"])
    require((entry["level"], entry["source"], entry["module"], entry["category"])
            == ("INFO", "structured", "Transport", "lifecycle"), "selected event has wrong logging channel")
    value = entry["details"]
    # Historical artifacts have no receipt field. Absence is unobserved,
    # whereas an explicit unavailable receipt says no store was attempted.
    fields(value, DETAILS if "admission_capture" in value else DETAILS-{"admission_capture"})
    context = origin(value["origin"])
    text(value["keeper"]); text(value["ask_id"])
    require(entry["keeper_name"] == value["keeper"], "keeper metadata disagrees with original capsule")
    key = context["tui_instance_id"], integer(value["request"]), ns(value["read_admission_started_ns"])
    require(ns(value["submission_started_ns"]) <= key[2] <= ns(value["observed_ns"]), "invalid original clock order")
    receipt = (capture_receipt(value["admission_capture"], key[2], value["observed_ns"])
               if "admission_capture" in value else {"state": "unobserved"})
    value = dict(value, admission_capture=receipt)
    phase = value["phase"]
    require(phase in PHASES, "unsupported phase")
    terminal = completion(value["completion"])
    require((phase in {"producer_returned", "cancelled", "finished"}) == (terminal is not None), "phase/terminal mismatch")
    if phase == "cancelled":
        require(terminal == "cancelled", "cancelled producer lost its cause")
    ui = phase in {"source_processed", "finished"}
    require(value["ui_admitted"] is (True if ui else None), "invalid UI admission fact")
    if ui:
        ns(value["admitted_ns"])
    require(value["admitted_ns"] == (value["observed_ns"] if ui else None), "invalid UI admission clock")
    if phase == "source_processed":
        require(value["source"] in {"started", "complete", *SOURCES}, "unsupported source")
        require(type(value["source_applied"]) is bool, "missing source decision")
        require(key[2] <= ns(value["received_ns"]) <= value["observed_ns"], "invalid source receipt order")
    else:
        require(all(value[name] is None for name in ("source", "source_applied", "received_ns")), "non-source phase has source facts")
    require(value["sources"] is None or type(value["sources"]) is dict, "invalid opaque source snapshot")
    return key, value


def capture_failure(entry):
    fields(entry, ENVELOPE)
    integer(entry["seq"]); text(entry["ts"]); text(entry["message"], False)
    if entry["keeper_name"] is not None:
        text(entry["keeper_name"])
    if entry["turn_id"] is not None:
        integer(entry["turn_id"])
    require((entry["level"], entry["source"], entry["module"], entry["category"])
            == ("WARN", "structured", "startup", "boundary"), "capture failure has wrong logging channel")
    value = entry["details"]
    fields(value, {"event", "schema_version", "origin", "request", "read_admission_started_ns",
                   "capture_started_ns", "observed_ns", "error"})
    require(type(value["schema_version"]) is int and value["schema_version"] == 1
            and value["event"] == "tui_ask_followup_admission_failed", "unsupported capture failure")
    context = origin(value["origin"])
    key = context["tui_instance_id"], integer(value["request"]), ns(value["read_admission_started_ns"])
    require(key[2] <= ns(value["capture_started_ns"]) <= ns(value["observed_ns"]), "invalid capture clock order")
    text(value["error"])
    return key, dict(value, capture_duration_ns=value["observed_ns"]-value["capture_started_ns"])


def source_observations(records):
    result = {}
    for source in SOURCES:
        rows = [row for row in records if row["phase"] == "source_processed" and row["source"] == source]
        metrics = dict.fromkeys(SOURCE_METRICS)
        if len(rows) == 1:
            metrics = {name: rows[0][end]-rows[0][start] for name, (start, end, _label) in SOURCE_METRICS.items()}
        result[source] = {"state": "observed" if len(rows) == 1 else "unobserved" if not rows else "ambiguous",
                          "observations": [{"received_ns": row["received_ns"], "processed_ns": row["observed_ns"],
                                            "source_applied": row["source_applied"], "evidence": row["evidence"]} for row in rows],
                          "metrics": metrics}
    return result


def invalidate_metrics(item):
    item["metrics"] = dict.fromkeys(METRICS)
    for source in item["source_observations"].values():
        source["state"] = "invalid_attempt"
        source["metrics"] = dict.fromkeys(SOURCE_METRICS)


def metric_summary(metrics, names, total):
    result = {}
    for name in names:
        values = [row[name] for row in metrics if row[name] is not None]
        result[name] = {"observed": len(values), "attempts": total, "sum_ns": sum(values),
                        "min_ns": min(values, default=None), "max_ns": max(values, default=None)}
    return result


def mean_delta(before, after):
    if not before["observed"] or not after["observed"]:
        return None
    return {"observed_mean_after_minus_before_ns": {
                "numerator": after["sum_ns"]*before["observed"]-before["sum_ns"]*after["observed"],
                "denominator": before["observed"]*after["observed"]},
            "before_observed": before["observed"], "after_observed": after["observed"]}


def attempt(key, records, declared):
    errors = []
    output = {"identity": dict(zip(("instance_id", "request", "read_admission_started_ns"), key)),
              "declared": declared, "records": records, "errors": errors, "metrics": dict.fromkeys(METRICS),
              "admission_capture": records[0]["admission_capture"] if records else {"state": "unobserved"},
              "source_observations": source_observations(records)}
    if not records:
        return dict(output, outcome="unobserved", producer_outcome=None, missing_stages=sorted({"started", "worker_entered", "producer", "registration_released", "finished"}))
    original = records[0]
    immutable = DETAILS-{"phase", "source", "received_ns", "observed_ns", "ui_admitted", "source_applied", "admitted_ns", "completion", "sources"}
    if any(any(row[k] != original[k] for k in immutable) for row in records):
        errors.append("original capsule changed within one read")
    stages = {}
    for row in sorted(records, key=lambda row: row["observed_ns"]):
        phase = row["phase"]
        if phase in {"source_processed", "cancel_requested"}:
            continue
        if phase in stages:
            errors.append("duplicate singleton stage: " + phase)
        stages[phase] = row
    if "cancelled" in stages and "producer_returned" in stages:
        errors.append("conflicting producer terminals")
    producer = stages.get("producer_returned", stages.get("cancelled"))
    producer_outcome = completion(producer["completion"]) if producer else None
    ui = stages.get("finished")
    outcome = completion(ui["completion"]) if ui else "unfinished"
    if outcome == "not_started" and "worker_entered" in stages:
        errors.append("unstarted read has worker entry")
    if producer_outcome == "not_started":
        errors.append("producer cannot return a dispatch-not-started outcome")
    clocks = {name: row["observed_ns"] for name, row in stages.items()}
    clocks[None] = key[2]
    receipt = original["admission_capture"]
    if receipt["state"] in {"returned", "failed"}:
        clocks["capture_started"] = receipt["capture_started_ns"]
        clocks["capture_returned"] = receipt["capture_returned_ns"]
    if producer:
        clocks["producer"] = producer["observed_ns"]
    for row in records:
        if row["phase"] != "source_processed" or row["source"] not in SOURCES:
            continue
        if outcome == "not_started":
            errors.append("unstarted read has a processed source")
        if "worker_entered" in clocks and row["received_ns"] < clocks["worker_entered"]:
            errors.append("source receipt precedes worker entry: " + row["source"])
        if producer and row["received_ns"] > clocks["producer"]:
            errors.append("source receipt follows producer return: " + row["source"])
        if "finished" in clocks and row["observed_ns"] > clocks["finished"]:
            errors.append("source processing follows UI settlement: " + row["source"])
    for name, (start, end) in METRICS.items():
        if start in clocks and end in clocks:
            interval = clocks[end]-clocks[start]
            if interval < 0:
                errors.append("negative interval: " + name)
            else:
                output["metrics"][name] = interval
    if errors:
        invalidate_metrics(output)
    return dict(output, outcome="invalid" if errors else outcome, producer_outcome=producer_outcome,
                missing_stages=sorted({"started", "worker_entered", "producer", "registration_released", "finished"}-set(clocks)),
                producer_ui_outcomes_differ=producer is not None and ui is not None and producer_outcome != outcome,
                original_provenance=original["origin"])


def analyze_arm(value, root):
    output = {"errors": [], "attempts": [], "store_initializations": [], "unselected_rows": 0, "execution_verified": False}
    errors = output["errors"]
    output["log_artifacts"] = []
    output["admission_artifacts"] = []
    output["unselected_admission_rows"] = 0
    groups = {}
    declared = set()
    admission_evidence = {}
    capture_failures = {}
    if type(value) is not dict:
        value = {}
    if set(value) != ARM_FIELDS:
        errors.append("unsupported cohort declaration fields")
    instances = []
    if type(value.get("instances")) is list:
        for item in value["instances"]:
            try:
                instance = text(item)
                require(instance not in instances, "duplicate selected instance")
                instances.append(instance)
            except EvidenceError as error:
                errors.append(str(error))
    if not instances:
        errors.append("missing selected instances")
    output["instances"] = instances
    declarations = value.get("attempts")
    if type(declarations) is not list:
        errors.append("missing declared attempt denominator")
        declarations = []
    output["declared_attempt_entries"] = len(declarations)
    for declaration in declarations:
        try:
            key = identity(declaration)
            if key[0] not in instances or key in declared:
                errors.append("foreign or duplicated declared attempt")
            declared.add(key); groups.setdefault(key, [])
        except EvidenceError as error:
            errors.append(str(error))
    admission_declarations = value.get("admissions")
    if type(admission_declarations) is not list:
        errors.append("missing admission artifact list")
        admission_declarations = []
    seen_admissions, seen_admission_artifacts = set(), set()
    for artifact_index, declaration in enumerate(admission_declarations):
        try:
            blob = artifact(root, declaration)
            output["admission_artifacts"].append(dict(declaration, verified=True))
            require(declaration["sha256"] not in seen_admission_artifacts, "reused admission artifact")
            seen_admission_artifacts.add(declaration["sha256"])
            lines = blob.decode("utf-8").splitlines()
        except (EvidenceError, UnicodeDecodeError) as error:
            errors.append("admission artifact %d: %s" % (artifact_index, str(error))); continue
        for index, line in enumerate(lines, 1):
            try:
                row = load_json(line)
                fields(row, {"schema_version", "event", "instance_id", "request", "read_admission_started_ns"})
                require(type(row["schema_version"]) is int and row["schema_version"] == 1
                        and row["event"] == "tui_ask_followup_admission", "unsupported admission record")
                key = identity({k: row[k] for k in ("instance_id", "request", "read_admission_started_ns")})
                if key[0] not in instances:
                    output["unselected_admission_rows"] += 1; continue
                require(key not in seen_admissions, "duplicate admitted attempt")
                seen_admissions.add(key)
                declared.add(key); groups.setdefault(key, [])
                admission_evidence[key] = [{"artifact": declaration["path"], "sha256": declaration["sha256"], "line": index}]
            except (EvidenceError, KeyError, TypeError) as error:
                errors.append("admission artifact %d line %d: %s" % (artifact_index, index,
                    str(error) if isinstance(error, EvidenceError) else "malformed admission evidence"))
    try:
        fields(value.get("conditions"), CONDITIONS)
        output["declared_conditions"] = {k: None if v is None else digest(v) for k, v in value["conditions"].items()}
        output["declared_source_commit"] = None if value.get("source_commit") is None else digest(value["source_commit"], 40)
    except EvidenceError as error:
        errors.append(str(error))
    if value.get("binary") is not None:
        try:
            output["binary_artifact_sha256"] = hashlib.sha256(artifact(root, value["binary"])).hexdigest()
        except EvidenceError as error:
            errors.append(str(error))
    log_declarations = value.get("logs")
    if type(log_declarations) is not list:
        errors.append("missing log artifact list")
        log_declarations = []
    seen_artifacts, seen_rows = set(), set()
    for artifact_index, declaration in enumerate(log_declarations):
        try:
            blob = artifact(root, declaration)
            output["log_artifacts"].append(dict(declaration, verified=True))
            require(declaration["sha256"] not in seen_artifacts, "reused artifact in one cohort")
            seen_artifacts.add(declaration["sha256"])
            lines = blob.decode("utf-8").splitlines()
        except (EvidenceError, UnicodeDecodeError) as error:
            errors.append("artifact %d: %s" % (artifact_index, str(error))); continue
        for index, line in enumerate(lines, 1):
            try:
                entry = load_json(line)
                details = entry.get("details") if type(entry) is dict else None
                event = details.get("event") if type(details) is dict else None
                if event == "tui_observation_store":
                    fields(details, {"event", "phase", "pid", "directory", "initialization_started_ns", "observed_ns"})
                    require(details["phase"] in {"initialized", "unavailable"}, "invalid store outcome")
                    fields(entry, ENVELOPE)
                    require((entry["source"], entry["module"], entry["level"], entry["category"])
                            == ("structured", "startup", "INFO" if details["phase"] == "initialized" else "WARN", None),
                            "store initialization has wrong logging channel")
                    integer(details["pid"])
                    require(ns(details["observed_ns"]) >= ns(details["initialization_started_ns"]), "invalid store clock span")
                    if details["phase"] == "initialized":
                        text(details["directory"])
                    else:
                        require(details["directory"] is None, "unavailable store has a location")
                    output["store_initializations"].append(dict(details, evidence={"artifact": declaration["path"],
                        "sha256": declaration["sha256"], "line": index}))
                    continue
                if event == "tui_ask_followup_admission_failed":
                    context = origin(details["origin"])
                    if context["tui_instance_id"] not in instances:
                        output["unselected_rows"] += 1; continue
                    key, row = capture_failure(entry)
                    row_id = key[0], entry["seq"], entry["ts"]
                    require(row_id not in seen_rows, "duplicate selected log row")
                    seen_rows.add(row_id)
                    groups.setdefault(key, [])
                    capture_failures.setdefault(key, []).append(dict(row, evidence={"artifact": declaration["path"],
                        "sha256": declaration["sha256"], "line": index, "seq": entry["seq"], "ts": entry["ts"]}))
                    continue
                if event != "tui_ask_followup":
                    output["unselected_rows"] += 1; continue
                context = origin(details["origin"])
                if context["tui_instance_id"] not in instances:
                    output["unselected_rows"] += 1; continue
                key, row = record(entry)
                group = groups.setdefault(key, [])
                row_id = key[0], entry["seq"], entry["ts"]
                require(row_id not in seen_rows, "duplicate selected log row")
                seen_rows.add(row_id)
                group.append(dict(row, evidence={"artifact": declaration["path"], "sha256": declaration["sha256"],
                    "line": index, "seq": entry["seq"], "ts": entry["ts"]}))
            except (EvidenceError, KeyError, TypeError) as error:
                errors.append("artifact %d line %d: %s" % (artifact_index, index, str(error) if isinstance(error, EvidenceError) else "malformed selected evidence"))
    output["attempts"] = [attempt(key, rows, key in declared) for key, rows in sorted(groups.items())]
    for item in output["attempts"]:
        key = identity(item["identity"])
        item["admission_evidence"] = admission_evidence.get(key, [])
        failures = capture_failures.get(key, [])
        item["capture_failures"] = failures
        if failures:
            original = item.get("original_provenance", failures[0]["origin"])
            item["original_provenance"] = original
            if any(row["origin"] != original for row in failures):
                item["errors"].append("original provenance changed within admission capture evidence")
            receipt = item["admission_capture"]
            if receipt["state"] != "unobserved" and (receipt["state"] != "failed" or any(
                    row["capture_started_ns"] != receipt["capture_started_ns"]
                    or row["observed_ns"] != receipt["capture_returned_ns"] for row in failures)):
                item["errors"].append("capture failure disagrees with original receipt")
            if item["errors"]:
                item["outcome"] = "invalid"
                invalidate_metrics(item)
    for item in output["attempts"]:
        errors.extend(item["errors"])
        if not item["declared"]:
            errors.append("observed attempt absent from declared denominator")
    output["declared_attempts"] = len(declared)
    output["summary"] = {"attempts": len(groups), "outcomes": dict(Counter(v["outcome"] for v in output["attempts"])), "metrics": {}}
    failures = [row for item in output["attempts"] for row in item["capture_failures"]]
    output["summary"]["admission_capture"] = {"receipt_states": dict(Counter(
        item["admission_capture"]["state"] for item in output["attempts"])), "observed_failures": len(failures),
        "attempts_with_observed_failures": sum(bool(item["capture_failures"]) for item in output["attempts"]),
        "observed_failed_capture_sum_ns": sum(row["capture_duration_ns"] for row in failures)}
    output["summary"]["metrics"] = metric_summary([item["metrics"] for item in output["attempts"]], METRICS, len(groups))
    output["summary"]["sources"] = {}
    for source in SOURCES:
        readings = [item["source_observations"][source] for item in output["attempts"]]
        states = Counter(reading["state"] for reading in readings)
        observed = [reading["observations"][0] for reading in readings if reading["state"] == "observed"]
        output["summary"]["sources"][source] = {
            "attempts": len(groups), "states": {state: states[state] for state in SOURCE_STATES},
            "processed_rows": sum(len(reading["observations"]) for reading in readings),
            "applied_attempts": sum(row["source_applied"] for row in observed),
            "rejected_attempts": sum(not row["source_applied"] for row in observed),
            "metrics": metric_summary([reading["metrics"] for reading in readings], SOURCE_METRICS, len(groups))}
    return output


def analyze(packet, root):
    fields(packet, {"schema_version", "cases"})
    require(type(packet["schema_version"]) is int and packet["schema_version"] == 2, "unsupported packet version")
    require(type(packet["cases"]) is list, "missing case denominator")
    cases = []
    labels = Counter(v.get("id") for v in packet["cases"] if type(v) is dict and type(v.get("id")) is str)
    for index, declaration in enumerate(packet["cases"]):
        errors = []
        if type(declaration) is not dict or set(declaration) != {"id", "before", "after"}:
            errors.append("invalid case declaration")
            declaration = declaration if type(declaration) is dict else {}
        label = declaration.get("id")
        if type(label) is not str or not label or labels[label] != 1:
            errors.append("absent or duplicated case identity")
        arms = {arm: analyze_arm(declaration.get(arm), root) for arm in ("before", "after")}
        cases.append(dict(case_index=index, case_id=label, errors=errors, **arms))
    ownership = Counter(v for case in cases for arm in ("before", "after") for v in case[arm].get("instances", []))
    for case in cases:
        for arm in ("before", "after"):
            if any(ownership[v] != 1 for v in case[arm].get("instances", [])):
                case[arm]["errors"].append("instance reused across cohorts")
        before, after = case["before"], case["after"]
        matched = before.get("declared_conditions") is not None and all(v is not None for v in before["declared_conditions"].values()) and before.get("declared_conditions") == after.get("declared_conditions")
        eligible = matched and not case["errors"] and not before["errors"] and not after["errors"]
        deltas = {}
        if eligible:
            for name in METRICS:
                a, b = before["summary"]["metrics"][name], after["summary"]["metrics"][name]
                deltas[name] = mean_delta(a, b)
        source_deltas = {source: {} for source in SOURCES}
        if eligible:
            for source in SOURCES:
                for name in SOURCE_METRICS:
                    source_deltas[source][name] = mean_delta(before["summary"]["sources"][source]["metrics"][name],
                                                            after["summary"]["sources"][source]["metrics"][name])
        case["comparison"] = {"declared_conditions_match": matched, "descriptive_delta_available": eligible,
                              "execution_verified": False, "metrics": deltas, "source_metrics": source_deltas}
    return {"schema_version": 2, "kind": "descriptive_original_ask_followup", "cases": cases,
            "limits": ["Declarations and artifact bytes do not prove execution/source/binary/install identity.",
                       "Only declared, journaled and observed attempts are known; capture failure or an unflushed interruption can still leave unknown attempts.",
                       "Admission journals bypass log severity; their bytes are not proof of exhaustive capture, dispatch or execution.",
                       "Capture warnings are original observation facts, not producer/UI outcomes; missing warnings do not prove capture success.",
                       "Durations describe observed subsets, with every attempt retained in denominators; no speed/readiness verdict.",
                       "Capture receipts cover one attempted append through return/error conversion before warning formatting, not fsync or complete capture; historical missing receipts remain unobserved.",
                       "Store initialization spans precede input-reader timing; they are retained separately, not a full cold-start duration.",
                       "Source receipts are client worker callbacks; processed/applicator results are UI handling facts, not source success, paint, useful Task work or server execution counts.",
                       "Each source contributes at most one interval per attempt; repeated source observations remain ambiguous with no invented first/latest timing.",
                       "Opaque source snapshots and read completion do not prove useful Task progress or visible UI."]}


def metric_display(metric):
    if not metric["observed"]:
        return "unobserved (0/%d)" % metric["attempts"]
    return "%s (%d/%d)" % (format(Decimal(metric["sum_ns"])/metric["observed"]/1_000_000, ".3f"),
                             metric["observed"], metric["attempts"])


def delta_display(delta):
    if delta is None:
        return "unavailable"
    ratio = delta["observed_mean_after_minus_before_ns"]
    return format(Decimal(ratio["numerator"])/ratio["denominator"]/1_000_000, "+.3f")


def markdown(report):
    lines = ["# Original Ask follow-up comparison", "", "Descriptive artifact report; execution and speedup are unverified.", ""]
    for case in report["cases"]:
        lines += ["## Case %d" % (case["case_index"]+1), "", "| Cohort | Attempts | Read outcomes | Capture failures observed | Evidence errors |", "|---|---:|---|---:|---:|"]
        for name in ("before", "after"):
            arm = case[name]; summary = arm["summary"]
            outcomes = ", ".join("%s: %d" % pair for pair in sorted(summary["outcomes"].items())) or "none observed"
            lines.append("| %s | %d | %s | %d | %d |" % (name, summary["attempts"], outcomes,
                summary["admission_capture"]["observed_failures"], len(arm["errors"])))
        lines += ["", "| Interval | Before mean ms (observed/all) | After mean ms (observed/all) | Observed mean delta ms |", "|---|---|---|---|"]
        for name in sorted(METRICS):
            values = [case[arm]["summary"]["metrics"][name] for arm in ("before", "after")]
            lines.append("| %s | %s | %s | %s |" % (name, *map(metric_display, values),
                delta_display(case["comparison"]["metrics"].get(name))))
        lines += ["", "Source handling is a client observation; applied does not mean a successful source or Task.", "",
                  "| Source | Cohort | Observed/all | Applied / rejected | Unobserved | Ambiguous / invalid |",
                  "|---|---|---:|---:|---:|---:|"]
        for source, label in SOURCES.items():
            for arm in ("before", "after"):
                reading = case[arm]["summary"]["sources"][source]
                states = reading["states"]
                lines.append("| %s | %s | %d/%d | %d / %d | %d | %d / %d |" %
                    (label, arm, states["observed"], reading["attempts"], reading["applied_attempts"],
                     reading["rejected_attempts"], states["unobserved"], states["ambiguous"], states["invalid_attempt"]))
        lines += ["", "| Source | Interval | Before mean ms (observed/all) | After mean ms (observed/all) | Observed mean delta ms |",
                  "|---|---|---|---|---|"]
        for source, label in SOURCES.items():
            for name, (_start, _end, interval) in SOURCE_METRICS.items():
                values = [case[arm]["summary"]["sources"][source]["metrics"][name] for arm in ("before", "after")]
                lines.append("| %s | %s | %s | %s | %s |" % (label, interval, *map(metric_display, values),
                    delta_display(case["comparison"]["source_metrics"][source].get(name))))
        lines += ["", "Case evidence errors: %d." % len(case["errors"]), "",
                  "Declared conditions match: %s. Full identities, missing stages, raw facts and errors are in JSON." % case["comparison"]["declared_conditions_match"], ""]
    lines += ["- "+limit for limit in report["limits"]]
    return "\n".join(lines)+"\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packet", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()
    if args.json.absolute() == args.markdown.absolute():
        parser.error("JSON and Markdown outputs must be different new files")
    try:
        packet_bytes = args.packet.read_bytes()
        report = analyze(load_json(packet_bytes), args.packet.resolve().parent)
        report["packet_sha256"] = hashlib.sha256(packet_bytes).hexdigest()
        report["analyzer_source_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    except (EvidenceError, OSError) as error:
        report = {"schema_version": 2, "kind": "invalid_packet", "errors": [str(error)]}
    try:
        with args.json.open("x", encoding="utf-8") as json_file, args.markdown.open("x", encoding="utf-8") as markdown_file:
            json_file.write(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
            markdown_file.write(markdown(report) if "cases" in report else "# Invalid comparison packet\n\nSee JSON errors.\n")
    except OSError:
        print("Report outputs must be writable new files; existing files were not overwritten.", file=sys.stderr)
        return 2
    return 2 if "cases" not in report or any(case["errors"] or case["before"]["errors"] or case["after"]["errors"] for case in report["cases"]) else 0


if __name__ == "__main__":
    sys.exit(main())
