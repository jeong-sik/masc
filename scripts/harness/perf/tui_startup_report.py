#!/usr/bin/env python3
"""Compare supplied startup records offline. Never launches a candidate or PTY.

File digests and matching declarations do not prove source-to-binary or runtime
execution identity. Report descriptive intervals, not a speed/readiness verdict.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass, field
import hashlib
import html
import json
from pathlib import Path, PurePosixPath
import stat
import sys


class EvidenceError(ValueError):
    pass


class MissingArtifact(EvidenceError):
    pass


def require(condition, detail):
    if not condition:
        raise EvidenceError(detail)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON member")
        result[key] = value
    return result


def load_json(text):
    def nonfinite(_value):
        raise EvidenceError("non-finite JSON number")
    try:
        return json.loads(text, object_pairs_hook=unique, parse_constant=nonfinite)
    except EvidenceError:
        raise
    except (ValueError, UnicodeDecodeError, RecursionError) as error:
        raise EvidenceError("invalid JSON/UTF-8") from error


def keys(value, expected, detail):
    require(type(value) is dict and set(value) == set(expected), detail)


def digest(value, length=64):
    require(type(value) is str and len(value) == length
            and set(value) <= set("0123456789abcdef"), "invalid digest identity")
    return value


def integer(value, minimum=0):
    require(type(value) is int and value >= minimum, "invalid integer fact")
    return value


def ns(value):
    require(type(value) is str and value.isascii() and value.isdecimal()
            and len(value) <= len(str(2**63 - 1))
            and str(int(value)) == value, "invalid canonical monotonic timestamp")
    parsed = int(value)
    require(parsed <= 2**63 - 1, "timestamp exceeds the producer Int64 contract")
    return parsed


def member(value, allowed):
    require(type(value) is str and value in allowed, "unsupported discriminant")
    return value


CONDITIONS = {"fixture_sha256", "workspace_sha256", "terminal_sha256", "input_reply_sha256"}
FACTS = ("worker_started_ns", "capture_finished", "caller_observed", "decoder_installed_ns",
         "capabilities_applied", "first_input_decoded", "first_input_received")
METRICS = ("dispatch_to_worker_ns", "capture_elapsed_ns", "dispatch_to_caller_ns",
           "capture_to_caller_ns", "dispatch_to_decoder_installed_ns",
           "dispatch_to_first_input_decoded_ns", "dispatch_to_first_input_received_ns",
           "decoded_to_received_ns")
PHASE_FIELDS = {"worker_started": "worker_started_ns", "capture_finished": "capture_finished",
                "caller_observed": "caller_observed", "handed_off": "decoder_installed_ns",
                "capabilities_applied": "capabilities_applied",
                "first_input_decoded": "first_input_decoded", "first_input_received": "first_input_received"}
ENVELOPE = {"seq", "ts", "level", "source", "module", "keeper_name", "turn_id", "message", "details", "category"}


def conditions(value):
    keys(value, CONDITIONS, "invalid condition declarations")
    return {key: digest(value[key]) for key in sorted(CONDITIONS)}


def replies(value):
    keys(value, {"palette_known", "theme_mode", "graphics", "cell_pixels"}, "invalid reply availability")
    require(type(value["palette_known"]) is bool, "invalid palette availability")
    if value["theme_mode"] is not None:
        member(value["theme_mode"], {"dark", "light"})
    member(value["graphics"], {"unknown", "supported", "refused"})
    if value["cell_pixels"] is not None:
        keys(value["cell_pixels"], {"width", "height"}, "invalid cell dimensions")
        integer(value["cell_pixels"]["width"], 1)
        integer(value["cell_pixels"]["height"], 1)
    return value


def capture_outcome(value):
    require(type(value) is dict and "outcome" in value, "missing capture outcome")
    outcome = member(value["outcome"], {"captured", "raised", "interrupted"})
    if outcome == "captured":
        keys(value, {"outcome", "reason", "bytes_read", "replies"}, "invalid returned capture")
        member(value["reason"], {"input_ready", "replies_ready", "deadline_reached",
                                "read_returned_no_byte", "byte_cap_reached"})
        replies(value["replies"])
    else:
        keys(value, {"outcome", "bytes_read"}, "invalid failed capture")
    integer(value["bytes_read"])
    return value


def capabilities_follow(old, new):
    require(not old["palette_known"] or new["palette_known"], "palette availability regressed")
    for key, unknown in (("graphics", "unknown"), ("cell_pixels", None)):
        require(old[key] == unknown or old[key] == new[key], "first-answer capability changed")
    require(old["theme_mode"] is None or new["theme_mode"] is not None, "theme availability regressed")


def timed(value, parse):
    if value is None:
        return None
    keys(value, {"at_ns", "value"}, "invalid timed fact")
    return {"at_ns": ns(value["at_ns"]), "value": parse(value["value"])}


def at(value):
    return None if value is None else value["at_ns"]


def elapsed(start, end):
    if start is None or end is None:
        return None
    require(end >= start, "negative interval within one capture")
    return end - start


def metrics(facts, dispatched):
    capture, caller = facts["capture_finished"], facts["caller_observed"]
    returned = caller is not None and caller["value"] == "returned"
    pairs = ((dispatched, facts["worker_started_ns"]), (facts["worker_started_ns"], at(capture)),
             (dispatched, at(caller)), (at(capture), at(caller) if returned else None),
             (dispatched, facts["decoder_installed_ns"]), (dispatched, at(facts["first_input_decoded"])),
             (dispatched, at(facts["first_input_received"])),
             (at(facts["first_input_decoded"]), at(facts["first_input_received"])))
    return {key: elapsed(*pair) for key, pair in zip(METRICS, pairs, strict=True)}


def causal_facts(facts, dispatched):
    capture, caller = facts["capture_finished"], facts["caller_observed"]
    installed = facts["decoder_installed_ns"]
    if capture is not None:
        require(facts["worker_started_ns"] is not None, "capture result has no worker-entry fact")
    if caller is not None and caller["value"] == "returned":
        require(capture is not None and capture["value"]["outcome"] == "captured", "caller return lacks returned capture")
    if installed is not None:
        require(caller is not None and caller["value"] == "returned", "installation lacks caller return")
        elapsed(at(caller), installed)
    for key in ("capabilities_applied", "first_input_decoded"):
        if facts[key] is not None:
            require(installed is not None, "input/capability fact lacks decoder installation")
            elapsed(installed, at(facts[key]))
    if facts["first_input_received"] is not None:
        require(facts["first_input_decoded"] is not None and
                facts["first_input_decoded"]["value"] == facts["first_input_received"]["value"],
                "input reception lacks its original decoded kind")
    if capture is not None and capture["value"]["outcome"] == "captured" and facts["capabilities_applied"] is not None:
        capabilities_follow(capture["value"]["replies"], facts["capabilities_applied"]["value"])
    for key in FACTS:
        value = facts[key]
        elapsed(dispatched, value if key in {"worker_started_ns", "decoder_installed_ns"} else at(value))
    return metrics(facts, dispatched)


def parse_record(value):
    keys(value, {"phase", "pid", "dispatched_ns", "observed_ns", *FACTS, *METRICS}, "unsupported startup schema")
    integer(value["pid"], 1)
    dispatched, observed = ns(value["dispatched_ns"]), ns(value["observed_ns"])
    elapsed(dispatched, observed)
    member(value["phase"], {"dispatched", "snapshot", *PHASE_FIELDS})
    facts = {key: None for key in FACTS}
    for key in ("worker_started_ns", "decoder_installed_ns"):
        facts[key] = None if value[key] is None else ns(value[key])
    facts["capture_finished"] = timed(value["capture_finished"], capture_outcome)
    facts["caller_observed"] = timed(value["caller_observed"], lambda x: member(x, {"returned", "raised", "interrupted"}))
    facts["capabilities_applied"] = timed(value["capabilities_applied"], replies)
    for key in ("first_input_decoded", "first_input_received"):
        facts[key] = timed(value[key], lambda x: member(x, {"key", "paste", "pointer"}))
    derived = causal_facts(facts, dispatched)
    for key in METRICS:
        recorded = None if value[key] is None else ns(value[key])
        require(recorded == derived[key], "recorded interval disagrees with its endpoints")
    if value["phase"] in PHASE_FIELDS:
        field = PHASE_FIELDS[value["phase"]]
        require(facts[field] is not None, "phase has no corresponding fact")
        point = facts[field] if field in {"worker_started_ns", "decoder_installed_ns"} else at(facts[field])
        require(point == observed, "phase timestamp disagrees with its fact")
    return facts


def merge_records(records, dispatched):
    merged = {key: None for key in FACTS}
    applications = {}
    for _line, _value, facts in records:
        for key in FACTS:
            fact = facts[key]
            if fact is None:
                continue
            if key == "capabilities_applied":
                prior = applications.get(at(fact))
                require(prior is None or prior == fact, "conflicting capability application at the same time")
                applications[at(fact)] = fact
            else:
                require(merged[key] is None or merged[key] == fact, "conflicting immutable startup fact")
                merged[key] = fact
    previous = None
    for point in sorted(applications):
        current = applications[point]
        if previous is not None:
            capabilities_follow(previous["value"], current["value"])
        previous = current
    merged["capabilities_applied"] = previous
    return merged, causal_facts(merged, dispatched)


@dataclass(frozen=True)
class Blob:
    data: bytes
    sha256: str


@dataclass
class CaptureRows:
    records: list = field(default_factory=list)
    errors: list = field(default_factory=list)
    identities: set = field(default_factory=set)
    singleton_phases: set = field(default_factory=set)
    count: int = 0


@dataclass
class LogIndex:
    captures: dict = field(default_factory=dict)
    errors: list = field(default_factory=list)
    other_rows: int = 0
    startup_rows: int = 0


class Artifacts:
    """One frozen read per declared path within this report invocation."""
    def __init__(self, root):
        self.root = root
        self.blobs = {}
        self.indexes = {}

    def read(self, reference):
        keys(reference, {"path", "sha256"}, "invalid artifact reference")
        expected = digest(reference["sha256"])
        name = reference["path"]
        require(type(name) is str and name, "missing artifact path")
        require("\x00" not in name, "artifact path contains NUL")
        path = PurePosixPath(name)
        require(not path.is_absolute() and path.as_posix() == name
                and all(part not in {".", ".."} for part in path.parts), "artifact path must be canonical and packet-relative")
        if name not in self.blobs:
            try:
                actual = self.root.joinpath(*path.parts)
                require(stat.S_ISREG(actual.lstat().st_mode), "artifact must be a regular file")
                data = actual.read_bytes()
            except FileNotFoundError as error:
                raise MissingArtifact("artifact file missing") from error
            except (OSError, UnicodeEncodeError) as error:
                raise EvidenceError("artifact could not be read") from error
            self.blobs[name] = Blob(data, hashlib.sha256(data).hexdigest())
        blob = self.blobs[name]
        require(blob.sha256 == expected, "artifact digest mismatch")
        return blob

    def index(self, blob):
        if blob.sha256 not in self.indexes:
            self.indexes[blob.sha256] = index_log(blob)
        return self.indexes[blob.sha256]


def index_log(blob):
    index = LogIndex()
    try:
        lines = blob.data.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise EvidenceError("log is not UTF-8") from error
    for line_number, line in enumerate(lines, 1):
        group = None
        try:
            entry = load_json(line)
            keys(entry, ENVELOPE, "unsupported Log.Ring envelope")
            require(type(entry["message"]) is str, "non-string log message")
            tag, separator, payload = entry["message"].partition("=")
            if tag != "tui_startup_observation" or not separator:
                index.other_rows += 1
                continue
            require(entry["module"] == "Transport" and entry["level"] == "INFO", "startup record has the wrong channel")
            value = load_json(payload)
            require(type(value) is dict and {"pid", "dispatched_ns"} <= set(value), "startup record lacks capture identity")
            identity = integer(value["pid"], 1), ns(value["dispatched_ns"])
            group = index.captures.get(identity)
            if group is None:
                group = CaptureRows()
                index.captures[identity] = group
            group.count += 1
            index.startup_rows += 1
            facts = parse_record(value)
            integer(entry["seq"])
            require(type(entry["ts"]) is str and entry["ts"], "missing log timestamp")
            row_id = entry["seq"], entry["ts"]
            require(row_id not in group.identities, "duplicate selected log row")
            group.identities.add(row_id)
            phase = value["phase"]
            if phase not in {"capabilities_applied", "snapshot"}:
                require(phase not in group.singleton_phases, "duplicate singleton lifecycle event")
                group.singleton_phases.add(phase)
            group.records.append((line_number, value, facts))
        except EvidenceError as error:
            errors = index.errors if group is None else group.errors
            errors.append(f"log line {line_number}: {error}")
    return index


def selected_records(index, selector):
    keys(selector, {"pid", "dispatched_ns"}, "invalid capture selector")
    target = integer(selector["pid"], 1), ns(selector["dispatched_ns"])
    group = index.captures.get(target)
    if group is None:
        group = CaptureRows()
    coverage = {"selected_rows": group.count, "foreign_rows": index.startup_rows - group.count,
                "other_rows": index.other_rows, "unattributed_rows": len(index.errors)}
    return group.records, coverage, [*index.errors, *group.errors]


def empty_arm(error, state="invalid"):
    return {"evidence_state": state, "errors": [error], "identity": None,
            "facts": None, "metrics_ns": {key: None for key in METRICS},
            "caller_state": "unobserved", "capture_state": "unobserved", "input_state": "unobserved"}


def wire_facts(facts):
    encoded = {}
    for key, value in facts.items():
        if value is None:
            encoded[key] = None
        elif key in {"worker_started_ns", "decoder_installed_ns"}:
            encoded[key] = str(value)
        else:
            encoded[key] = {"at_ns": str(at(value)), "value": value["value"]}
    return encoded


def analyze_arm(arm, expected_conditions, artifacts):
    try:
        keys(arm, {"source_head", "binary", "log", "capture", "conditions"}, "invalid arm declarations")
        declared = conditions(arm["conditions"])
        head = None if arm["source_head"] is None else digest(arm["source_head"], 40)
    except EvidenceError as error:
        return empty_arm(str(error))
    result = empty_arm("startup evidence absent", "missing")
    result["errors"] = []
    identity = {"declared_source_head": head, "declared_conditions": declared,
                "conditions_match_case": declared == expected_conditions, "binary_bytes_verified": False,
                "source_to_binary_verified": False, "execution_binding_verified": False}
    result["identity"] = identity
    if arm["binary"] is not None:
        try:
            identity["binary_sha256"] = artifacts.read(arm["binary"]).sha256
            identity["binary_bytes_verified"] = True
        except EvidenceError as error:
            result["errors"].append("binary: " + str(error))
    if arm["log"] is None:
        return result
    try:
        require(arm["capture"] is not None, "log has no declared capture selector")
        blob = artifacts.read(arm["log"])
        records, coverage, errors = selected_records(artifacts.index(blob), arm["capture"])
        result.update(log_sha256=blob.sha256, coverage=coverage,
                      capture=arm["capture"],
                      observed_phases=sorted({value["phase"] for _, value, _ in records}))
        require(not errors, "; ".join(errors))
        if not records:
            return result
        facts, measured = merge_records(records, ns(arm["capture"]["dispatched_ns"]))
        capture, caller = facts["capture_finished"], facts["caller_observed"]
        result.update(evidence_state="valid", facts=wire_facts(facts),
                      metrics_ns={key: None if value is None else str(value) for key, value in measured.items()},
                      caller_state="unobserved" if caller is None else caller["value"],
                      capture_state="unobserved" if capture is None else capture["value"]["outcome"],
                      input_state="received" if facts["first_input_received"] is not None else
                                  "decoded_only" if facts["first_input_decoded"] is not None else "unobserved")
    except MissingArtifact as error:
        result["errors"].append(str(error))
    except EvidenceError as error:
        result.update(evidence_state="invalid", facts=None)
        result["errors"].append(str(error))
    return result


def compare_metric(before, after, key):
    reused = any(arm["identity"] is not None and arm["identity"].get("capture_artifact_reused", False)
                 for arm in (before, after))
    eligible = all(arm["evidence_state"] == "valid" and arm["identity"] is not None
                   and arm["identity"]["binary_bytes_verified"] and arm["identity"]["declared_source_head"] is not None
                   and arm["identity"]["conditions_match_case"] for arm in (before, after))
    left, right = before["metrics_ns"][key], after["metrics_ns"][key]
    if reused:
        reason = "reused_capture_artifact"
    elif not eligible:
        reason = "unmatched_or_unverified_artifacts"
    elif left is None or right is None:
        reason = "missing_endpoint"
    else:
        reason = "declared_matched_records"
    return {"before_ns": left, "after_ns": right,
            "after_minus_before_ns": str(int(right) - int(left)) if reason == "declared_matched_records" else None,
            "basis": reason}


def build_report(packet_path):
    require(stat.S_ISREG(packet_path.lstat().st_mode), "packet must be a regular file")
    packet_bytes = packet_path.read_bytes()
    packet = load_json(packet_bytes)
    keys(packet, {"schema_version", "cases"}, "invalid packet envelope")
    require(type(packet["schema_version"]) is int and packet["schema_version"] == 1, "unsupported packet version")
    require(type(packet["cases"]) is list, "case denominator must be a declared list")
    artifacts = Artifacts(packet_path.parent)
    ids = Counter(case.get("id") for case in packet["cases"] if type(case) is dict and type(case.get("id")) is str)
    cases = []
    for index, case in enumerate(packet["cases"]):
        label = case.get("id") if type(case) is dict and type(case.get("id")) is str else None
        expected = None
        try:
            keys(case, {"id", "conditions", "before", "after"}, "invalid case declarations")
            require(label is not None and label and ids[label] == 1, "case identity is absent or duplicated")
            expected = conditions(case["conditions"])
            before = analyze_arm(case["before"], expected, artifacts)
            after = analyze_arm(case["after"], expected, artifacts)
        except EvidenceError as error:
            before, after = empty_arm(str(error)), empty_arm(str(error))
        cases.append({"case_index": index, "case_id": label, "declared_case_conditions": expected,
                      "before": before, "after": after})
    def capture_key(arm):
        if "log_sha256" not in arm or "capture" not in arm or "coverage" not in arm or arm["coverage"]["selected_rows"] == 0:
            return None
        return arm["log_sha256"], arm["capture"]["pid"], arm["capture"]["dispatched_ns"]
    owners = Counter(capture_key(case[arm]) for case in cases for arm in ("before", "after")
                     if capture_key(case[arm]) is not None)
    for case in cases:
        for arm in ("before", "after"):
            value = case[arm]
            if value["identity"] is not None:
                key = capture_key(value)
                value["identity"]["capture_artifact_reused"] = key is not None and owners[key] > 1
        case["comparison"] = {key: compare_metric(case["before"], case["after"], key) for key in METRICS}
    counts = {arm: {axis: dict(Counter(case[arm][axis] for case in cases))
                    for axis in ("evidence_state", "caller_state", "capture_state", "input_state")}
              for arm in ("before", "after")}
    return {"schema_version": 1, "scope": "supplied startup records; descriptive declared-condition comparison",
            "packet_sha256": hashlib.sha256(packet_bytes).hexdigest(),
            "declared_cases": len(packet["cases"]), "outcomes": counts,
            "paired_by_metric": {key: sum(case["comparison"][key]["after_minus_before_ns"] is not None for case in cases)
                                 for key in METRICS},
            "source_to_binary_verified": False, "runtime_execution_verified": False,
            "paint_or_useful_work_verified": False, "measured_speedup": None, "cases": cases}


def markdown(report):
    lines = ["Recorded startup comparison", "", f"Declared cases: {report['declared_cases']}.", "",
             "Source-to-binary, execution binding, paint and useful work are unverified. Deltas describe supplied records only.", "",
             "| Case | Metric | Before ns | After ns | After - Before ns | Basis |", "|---|---|---:|---:|---:|---|"]
    for case in report["cases"]:
        label = str(case["case_index"]) + ": " + html.escape(json.dumps(case["case_id"], ensure_ascii=False))
        label = label.replace("|", "\\|").replace("\n", " ").replace("\r", " ")
        for key in ("dispatch_to_worker_ns", "capture_elapsed_ns", "dispatch_to_first_input_received_ns"):
            row = case["comparison"][key]
            values = [row[field] if row[field] is not None else "missing" for field in
                      ("before_ns", "after_ns", "after_minus_before_ns")]
            lines.append("| " + " | ".join([label, key, *values, row["basis"]]) + " |")
    lines += ["", "All outcome counts (including invalid, missing and interrupted records):", "",
              "```json", json.dumps(report["outcomes"], sort_keys=True, indent=2), "```", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packet", type=Path)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args()
    try:
        report = build_report(args.packet)
    except (EvidenceError, OSError) as error:
        print(json.dumps({"packet_state": "invalid", "errors": [str(error)]}), file=sys.stderr)
        return 2
    print(markdown(report) if args.format == "markdown" else json.dumps(report, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
