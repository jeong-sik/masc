#!/usr/bin/env python3
"""Opt-in Keeper explicit-cycle preparation harness.

The driver owns Runtime/SDK/tools. This coordinator never interprets or executes
model tool calls. It preallocates the full denominator before fixture setup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time
import tomllib


def save(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".writing")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def decode_json(text: str):
    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError("non-finite JSON number")
        return number

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON field: {key}")
            value[key] = item
        return value
    return json.loads(text, object_pairs_hook=unique, parse_float=finite_float,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def load(path: Path) -> dict:
    return decode_json(path.read_text(encoding="utf-8"))


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def validate(experiment: dict) -> None:
    if (not isinstance(experiment, dict) or type(experiment.get("schema_version")) is not int
            or experiment["schema_version"] != 1 or experiment.get("case") not in ("upstream_inline", "named_inline")):
        raise ValueError("schema 1 upstream_inline or named_inline required")
    if type(experiment["pairs"]) is not int or experiment["pairs"] <= 0:
        raise ValueError("pairs must be an explicit positive integer")
    runtime = experiment["runtime"]
    if runtime["mode"] == "configured_http":
        if set(experiment) != {"schema_version", "case", "pairs", "runtime"} or set(runtime) != {"mode", "configuration"}:
            raise ValueError("closed configured HTTP experiment fields required")
        # Before persisting any input, refuse credential values. The native
        # Runtime parser owns the actual configuration/protocol contract.
        configuration = tomllib.loads(runtime["configuration"])
        for provider in configuration.get("providers", {}).values():
            credential = provider.get("credentials")
            if credential is not None and (set(credential) != {"type", "key"} or credential["type"] != "env"):
                raise ValueError("experiment credentials must name an existing environment variable")
            if provider.get("headers"):
                raise ValueError("experiment authentication must not persist inline headers")
        return
    if set(experiment) != {"schema_version", "case", "pairs", "runtime", "synthetic_outcome"}:
        raise ValueError("closed synthetic experiment fields required")
    if set(runtime) != {"mode", "model_id", "max_context_tokens", "max_output_tokens"}:
        raise ValueError("explicit closed synthetic model capabilities required")
    if runtime["mode"] != "synthetic_streaming":
        raise ValueError("unsupported preparation Runtime mode")
    model = runtime["model_id"]
    if not isinstance(model, str) or not model or model != model.strip():
        raise ValueError("model_id must be explicit and nonblank")
    for name in ("max_context_tokens", "max_output_tokens"):
        if type(runtime[name]) is not int or runtime[name] <= 0:
            raise ValueError(f"{name} must be an explicit positive capability")
    if experiment["synthetic_outcome"] not in ("success", "provider_refusal", "malformed_final", "fixed_child"):
        raise ValueError("unsupported synthetic outcome")


def inventory(root: Path) -> dict:
    """No symlink traversal or secret-bearing external configuration imports."""
    root_mode = root.stat()
    directories = {".": {"device": root_mode.st_dev, "inode": root_mode.st_ino,
                          "uid": root_mode.st_uid, "permissions": stat.S_IMODE(root_mode.st_mode)}}
    files = {}
    for directory, names, filenames in os.walk(root, followlinks=False):
        for name in names:
            path = Path(directory) / name
            mode = path.lstat()
            if not stat.S_ISDIR(mode.st_mode):
                raise ValueError(f"non-directory fixture entry: {path.relative_to(root)}")
            directories[str(path.relative_to(root))] = {"device": mode.st_dev, "inode": mode.st_ino,
                                                             "uid": mode.st_uid, "permissions": stat.S_IMODE(mode.st_mode)}
        for name in filenames:
            path = Path(directory) / name
            mode = path.lstat()
            if not stat.S_ISREG(mode.st_mode) or mode.st_nlink != 1:
                raise ValueError(f"non-private regular fixture input: {path.relative_to(root)}")
            files[str(path.relative_to(root))] = {"bytes": mode.st_size, "sha256": digest(path)}
    return {"directories": directories, "files": files}


def restore(base: Path, snapshot: Path, frozen: dict, pair_root: Path) -> None:
    # base is allocated by this process under one brand-new experiment. Keep
    # original directory inodes: owned-job backend authority freezes them.
    if base != pair_root / "base" or snapshot != pair_root / "snapshot":
        raise ValueError("restore escaped the experiment-owned pair")
    for name, identity in frozen["directories"].items():
        path = base if name == "." else base / name
        mode = path.lstat()
        if not stat.S_ISDIR(mode.st_mode) or (mode.st_dev, mode.st_ino) != (identity["device"], identity["inode"]):
            raise ValueError("original fixture directory identity changed: " + name)
    for directory, names, filenames in os.walk(base, topdown=False, followlinks=False):
        for name in filenames:
            path = Path(directory) / name
            relative = str(path.relative_to(base))
            if relative not in frozen["files"]:
                path.unlink()
        for name in names:
            path = Path(directory) / name
            relative = str(path.relative_to(base))
            if relative not in frozen["directories"]:
                if path.is_symlink():
                    path.unlink()
                else:
                    path.rmdir()  # contents were removed above; no broad rmtree
    for name, expected in frozen["files"].items():
        source, target = snapshot / name, base / name
        if digest(source) != expected["sha256"]:
            raise ValueError("frozen snapshot changed: " + name)
        if target.is_symlink() or (target.exists() and not stat.S_ISREG(target.lstat().st_mode)):
            raise ValueError("fixture file became non-regular: " + name)
        shutil.copyfile(source, target, follow_symlinks=False)
        shutil.copystat(source, target, follow_symlinks=False)
    actual = inventory(base)
    if actual != frozen:
        raise ValueError("restored common fixture differs from frozen input")


def invoke(driver: Path, experiment_path: Path, prompts: Path, base: Path,
           receipt: Path, mode: str, strategy: str | None = None) -> int:
    command = [str(driver), "--mode", mode, "--base", str(base),
               "--experiment", str(experiment_path), "--receipt", str(receipt),
               "--prompt-root", str(prompts)]
    if strategy is not None:
        command += ["--strategy", strategy]
    # No timeout/retry or Python-side tool scheduler. A killed process retains
    # its preallocated unfinished receipt. No HTTP headers are captured here.
    return subprocess.run(command, check=False).returncode


def declared_attempts(pairs: int) -> list[dict]:
    return [{"pair": pair, "strategy": arm,
             "path": f"pair-{pair:04d}/{arm}/attempt.json"}
            for pair in range(pairs)
            for arm in (("direct", "exact_skill") if pair % 2 == 0 else ("exact_skill", "direct"))]


def capture_bytes(root: Path, relative: str):
    path = root
    parts = Path(relative).parts
    for index, part in enumerate(parts):
        if part in (".", "..") or not part or Path(relative).is_absolute():
            raise ValueError("capture path is not relative")
        path = path / part
        mode = path.lstat().st_mode
        expected = stat.S_ISREG if index == len(parts) - 1 else stat.S_ISDIR
        if not expected(mode):
            raise ValueError("capture entry is not a regular file/directory: " + relative)
    raw = path.read_bytes()
    return raw, hashlib.sha256(raw).hexdigest()


def capture_json(root: Path, relative: str):
    raw, digest_value = capture_bytes(root, relative)
    return decode_json(raw.decode("utf-8")), digest_value


def same_json(first, second) -> bool:
    # JSON true and 1 are different input declarations, despite Python equality.
    pending = [(first, second)]
    while pending:
        first, second = pending.pop()
        if type(first) is not type(second):
            return False
        if isinstance(first, dict):
            if first.keys() != second.keys():
                return False
            pending.extend((first[key], second[key]) for key in first)
        elif isinstance(first, list):
            if len(first) != len(second):
                return False
            pending.extend(zip(first, second))
        elif first != second:
            return False
    return True


def clock_point(value, clock_ref: str) -> int:
    if (not isinstance(value, dict) or not clock_ref or value.get("clock_domain") != "driver_counter"
            or value.get("clock_ref") != clock_ref):
        raise ValueError("clock_domain_or_owner_mismatch")
    text = value.get("monotonic_ns")
    if (type(text) is not str or not text or not text.isascii() or not text.isdecimal()
            or len(text) > 20 or str(int(text)) != text or int(text) > 2**64 - 1):
        raise ValueError("invalid_exact_counter_timestamp")
    return int(text)


def reported_interval(start, end, clock_ref, unavailable_reason=None) -> dict:
    if unavailable_reason is not None:
        return {"state": "unavailable", "reason": unavailable_reason}
    if start is None or end is None:
        return {"state": "unavailable", "reason": "endpoint_unobserved"}
    try:
        first, last = clock_point(start, clock_ref), clock_point(end, clock_ref)
        if last < first:
            raise ValueError("counter_time_regression")
    except ValueError as error:
        return {"state": "unavailable", "reason": str(error)}
    return {"state": "available", "clock_domain": "driver_counter", "clock_ref": clock_ref,
            "start_ns": str(first), "end_ns": str(last), "duration_ns": str(last - first)}


def useful_identity(root: Path, attempt: dict, receipt: dict) -> dict:
    """Join recorded metadata only; not SDK execution, stdout or model verification."""
    if receipt.get("receipt_state") != "read":
        return {"state": "unavailable", "reason": "receipt_not_admitted"}
    timing = receipt.get("timing", {})
    leaf = timing.get("first_useful_leaf", {}) if isinstance(timing, dict) else {}
    if not isinstance(leaf, dict) or leaf.get("state") != "observed":
        return {"state": "unobserved", "reason": "useful_leaf_not_reported"}
    hashes = {}
    def read_json(relative):
        raw, digest_value = capture_bytes(root, relative)
        hashes[relative] = digest_value
        return decode_json(raw.decode("utf-8"))
    def require(condition):
        if not condition:
            raise ValueError("recorded_identity_mismatch")
    def text(value):
        return type(value) is str and bool(value.strip())
    prefix = str(Path(attempt["path"]).parent)
    pair_prefix = f"pair-{attempt['pair']:04d}"
    try:
        frozen = read_json(pair_prefix + "/common-inputs.json")
        fixture_path = pair_prefix + "/snapshot/preparation-fixture.json"
        fixture = read_json(fixture_path)
        require(hashes[fixture_path] == receipt.get("fixture_sha256")
                == frozen["files"]["preparation-fixture.json"]["sha256"])
        turn = read_json(prefix + "/turn-record.json")
        admission = read_json(prefix + "/admission.json")
        marker_path = prefix + "/turn-entry-manifest.json"
        marker = read_json(marker_path)
        intake = timing["intake_turn_entry"]
        require(text(receipt.get("turn_ref")) and receipt["turn_ref"] == turn["turn_ref"]
                and text(fixture["keeper"]) and fixture["keeper"] == turn["keeper"]
                and text(fixture["task_id"]) and fixture["task_id"] == leaf.get("task_id")
                and text(fixture["trace_id"]) and fixture["trace_id"] == turn["trace_id"] == leaf.get("trace_id")
                and type(turn["absolute_turn"]) is int and turn["absolute_turn"] >= 0
                and same_json(turn["absolute_turn"], leaf.get("keeper_turn_id")))
        source_keys = ("stimulus_id", "source_snapshot_ref", "admitted_revision", "first_admitted_at")
        sources = [{key: admission[key] for key in source_keys}]
        require(all(text(admission[key]) for key in source_keys[:3])
                and type(admission["first_admitted_at"]) in (int, float)
                and same_json(admission, timing["admission"])
                and intake["state"] == "observed" and intake["manifest_sha256"] == hashes[marker_path]
                and intake["trace_id"] == turn["trace_id"]
                and same_json(intake["keeper_turn_id"], turn["absolute_turn"])
                and marker["event"] == "turn_started" and marker["trace_id"] == turn["trace_id"]
                and marker["keeper_name"] == fixture["keeper"]
                and same_json(marker["keeper_turn_id"], turn["absolute_turn"])
                and text(intake["ts"]) and intake["ts"] == marker["ts"]
                and same_json(intake["sources"], sources)
                and same_json(marker["decision"]["intake_sources"], sources)
                and same_json(intake["clock_refs"], marker["decision"]["clock_refs"])
                and intake["clock_refs"]["source_clock"] == "wall")
        metrics = receipt["tool_commit_observation"]
        raw, events_hash = capture_bytes(root, prefix + "/tool-commit-events.jsonl")
        hashes[prefix + "/tool-commit-events.jsonl"] = events_hash
        events = [decode_json(line) for line in raw.decode("utf-8").splitlines() if line.strip()]
        calls = read_json(prefix + "/tool-calls.json")
        require(type(calls) is list and all(isinstance(row, dict) for row in calls))
        calls = [row for row in calls if row.get("record_kind") == "tool_call"]
        require(metrics["boundary"] == leaf["boundary"] == "durable_tool_call_commit"
                and metrics["mode"] == "scoped_synchronous_commit" and metrics["coverage"] == "complete"
                and type(metrics["delivery_failures"]) is int and metrics["delivery_failures"] == 0
                and type(metrics["events"]) is int and metrics["events"] == len(events) == len(calls)
                and metrics["events_sha256"] == events_hash)
        identity = ("keeper", "tool", "execution_id", "tool_use_id", "trace_id", "task_id",
                    "keeper_turn_id", "composition_node_id", "parent_tool_use_id")
        def record_key(row):
            values = tuple(row.get(key) for key in identity)
            for key, value in zip(identity, values):
                if key == "keeper_turn_id":
                    require(value is None or (type(value) is int and value >= 0))
                else:
                    require(value is None or type(value) is str)
            require(all(text(row.get(key)) for key in ("keeper", "tool", "execution_id")))
            return values
        indexed = {}
        for call in calls:
            key = record_key(call)
            require(key not in indexed)
            indexed[key] = call
        seen = set()
        joined = None
        for event in events:
            require(isinstance(event, dict) and all(key in event for key in identity)
                    and type(event.get("schema_version")) is int and event["schema_version"] == 1
                    and event["boundary"] == metrics["boundary"])
            execution = event["execution_id"]
            key = record_key(event)
            require(key in indexed and key not in seen)
            seen.add(key)
            call = indexed[key]
            require(all(same_json(event[key], call.get(key)) for key in identity))
            if execution == leaf.get("execution_id"):
                require(joined is None and event["tool"] == "keeper_artifact_read"
                        and event["keeper"] == fixture["keeper"]
                        and all(key in leaf and same_json(event[key], leaf[key])
                                for key in identity if key not in ("keeper", "tool"))
                        and same_json(event["observed"], leaf["observed"])
                        and text(fixture["selection_sha256"])
                        and call["input"]["sha256"] == fixture["selection_sha256"]
                        == receipt["input"]["_blob"]["sha256"])
                joined = execution
        require(joined is not None)
        return {"state": "matched", "scope": "recorded_metadata_only", "artifact_sha256": hashes,
                "turn_ref": turn["turn_ref"], "task_id": leaf["task_id"], "trace_id": leaf["trace_id"],
                "execution_id": joined, "source": sources[0], "physical_execution_verified": False}
    except FileNotFoundError:
        return {"state": "missing", "reason": "identity_artifact_unavailable", "artifact_sha256": hashes}
    except (OSError, ValueError, KeyError, TypeError, RecursionError):
        return {"state": "invalid", "reason": "identity_artifact_invalid_or_mismatched", "artifact_sha256": hashes}


def attempt_timing(root: Path, attempt: dict, receipt: dict) -> dict:
    timing = receipt.get("timing")
    timing = timing if isinstance(timing, dict) else {}
    admission = timing.get("admission")
    admission = admission if isinstance(admission, dict) else {}
    identity = useful_identity(root, attempt, receipt)
    leaf = timing.get("first_useful_leaf")
    leaf = leaf if isinstance(leaf, dict) else {}
    reason = None if identity["state"] == "matched" else "useful_identity_not_joined"
    clock_ref = receipt.get("clock_ref")
    clock_ref = clock_ref if type(clock_ref) is str and clock_ref.strip() else ""
    admission_reason = None if receipt.get("receipt_state") == "read" else "receipt_not_admitted"
    if admission_reason is not None:
        timing, admission, leaf, reason = {}, {}, {}, "receipt_not_admitted"
    elif reason is None:
        try:
            entered = clock_point(timing.get("cycle_entered"), clock_ref)
            observed = clock_point(leaf.get("observed"), clock_ref)
            returned = clock_point(timing.get("cycle_returned"), clock_ref)
            if not entered <= observed <= returned:
                raise ValueError("useful_commit_outside_reported_cycle")
        except ValueError as error:
            reason = str(error)
    intervals = {
        "source_enqueue": reported_interval(admission.get("enqueue_entered"), admission.get("enqueue_returned"), clock_ref, admission_reason),
        "cycle": reported_interval(timing.get("cycle_entered"), timing.get("cycle_returned"), clock_ref, admission_reason),
        "cycle_to_validation": reported_interval(timing.get("cycle_returned"), timing.get("validation_finished"), clock_ref, admission_reason),
        "enqueue_to_reported_useful_commit": reported_interval(admission.get("enqueue_entered"), leaf.get("observed"), clock_ref, reason),
        "cycle_to_reported_useful_commit": reported_interval(timing.get("cycle_entered"), leaf.get("observed"), clock_ref, reason)}
    return {"scope": "receipt_reported_driver_counter_intervals", "identity": identity,
            "intervals": intervals, "wall_clock_arithmetic": False, "execution_verified": False}


def record_observation(root: Path, relative: str) -> dict:
    """Read one declared artifact without interpreting execution or liveness."""
    record, record_hash, state, reason = None, None, "read", None
    try:
        raw, record_hash = capture_bytes(root, relative)
        record = decode_json(raw.decode("utf-8"))
        if not isinstance(record, dict):
            raise ValueError("record must be an object")
    except FileNotFoundError:
        state, reason = "missing", "record_unavailable"
    except (OSError, ValueError, RecursionError):
        state, reason = "invalid", "record_cannot_be_admitted"
    return {"path": relative, "state": state, "sha256": record_hash,
            "reported_record": record, "reason": reason,
            "current_liveness_verified": False, "execution_verified": False}


def process_observation(root: Path, attempt: dict) -> dict:
    """Preserve recorded closeout separately from native outcome/current liveness."""
    relative = Path(attempt["path"]).with_name("process.json").as_posix()
    observation = record_observation(root, relative)
    observation["kind"] = None
    if observation["state"] != "read":
        return observation
    record = observation["reported_record"]
    if (set(record) == {"returncode", "observed_epoch"}
            and type(record["returncode"]) is int
            and type(record["observed_epoch"]) in (int, float)):
        observation["kind"] = "driver_returned"
    elif (set(record) == {"returncode", "observation", "detail"}
            and record["returncode"] is None
            and record["observation"] == "fixture_or_driver_unavailable"
            and type(record["detail"]) is str):
        observation["kind"] = "fixture_or_driver_unavailable"
    else:
        observation.update(state="invalid", reason="process_record_shape_unrecognized")
    return observation


def reported_pair_timing(paired: list[dict], mismatched_fields: list[str], declared_case: str) -> dict:
    """Compare reported durations, never absolute counters or verified latency."""
    arms = {result["declared_attempt"]["strategy"]: result for result in paired}
    before, after = arms["direct"], arms["exact_skill"]
    unadmitted = [name for name, result in arms.items() if result["receipt_state"] != "read"]
    blockers = [{"reason": "receipt_not_admitted", "strategy": name,
                 "receipt_state": arms[name]["receipt_state"]} for name in unadmitted]
    if not unadmitted and mismatched_fields:
        blockers.append({"reason": "common_input_mismatch", "fields": mismatched_fields})
    for name, result in arms.items():
        if result["receipt_state"] != "read":
            continue
        if result.get("case") != declared_case:
            blockers.append({"reason": "declared_case_mismatch", "strategy": name})
        owner = result.get("clock_ref")
        if type(owner) is not str or not owner.strip():
            blockers.append({"reason": "counter_owner_unobserved", "strategy": name})
        for field in ("fixture_sha256", "first_offered_tools_sha256", "common_instruction_sha256"):
            value = result.get(field)
            if type(value) is not str or not value.strip():
                blockers.append({"reason": "common_hash_unreported", "strategy": name, "field": field})
    owner = before.get("clock_ref")
    if type(owner) is str and owner.strip() and owner == after.get("clock_ref"):
        blockers.append({"reason": "shared_counter_owner"})
    intervals = {}
    for name, first in before["timing_report"]["intervals"].items():
        second = after["timing_report"]["intervals"][name]
        unavailable = [{"strategy": strategy, "reason": span["reason"]}
                       for strategy, span in (("direct", first), ("exact_skill", second))
                       if span["state"] == "unavailable"]
        comparable = not blockers and not unavailable
        intervals[name] = {
            "state": "available" if comparable else "unavailable",
            "direct": first, "exact_skill": second,
            # Both durations were derived within their own validated counter.
            # Signed integer strings retain precision and handle a zero baseline.
            "exact_skill_minus_direct_ns":
                str(int(second["duration_ns"]) - int(first["duration_ns"])) if comparable else None,
            "unavailable_arms": unavailable}
    return {"scope": "receipt_reported_duration_comparison",
            "baseline_strategy": "direct", "comparison_strategy": "exact_skill",
            "reported_input_agreement": {
                "state": "unavailable" if unadmitted else "mismatch" if mismatched_fields else "matched",
                "mismatched_fields": mismatched_fields if not unadmitted else [],
                "unadmitted_strategies": unadmitted},
            "arms": {name: {"receipt_state": result["receipt_state"],
                            "reported_outcome": result["reported_outcome"],
                            "receipt_sha256": result["receipt_sha256"],
                            "clock_ref": result.get("clock_ref"),
                            "process_observation": result["process_observation"]}
                     for name, result in arms.items()},
            "blockers": blockers, "intervals": intervals,
            "wall_clock_arithmetic": False, "cross_owner_counter_subtraction": False,
            "execution_verified": False, "source_build_verified": False}


def report_capture(directory: Path) -> dict:
    """Read a declared capture without invoking a driver or changing evidence."""
    root = directory.resolve(strict=True)
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise ValueError("capture root must be a directory")
    manifest, _ = capture_json(root, "manifest.json")
    experiment, experiment_hash = capture_json(root, "experiment.json")
    validate(experiment)
    attempts = declared_attempts(experiment["pairs"])
    if (not isinstance(manifest, dict) or type(manifest.get("schema_version")) is not int
            or manifest["schema_version"] != 1
            or manifest.get("experiment_sha256") != experiment_hash
            or not same_json(manifest.get("expected_attempts"), attempts)):
        raise ValueError("capture manifest does not bind the complete declared experiment")
    setup = {pair: record_observation(root, f"pair-{pair:04d}/setup.json")
             for pair in range(experiment["pairs"])}
    results, by_pair = [], {}
    for attempt in attempts:
        result, receipt_hash, state, error = {}, None, "read", None
        try:
            raw, receipt_hash = capture_bytes(root, attempt["path"])
            result = decode_json(raw.decode("utf-8"))
            if not isinstance(result, dict):
                result = {}
                raise ValueError("attempt receipt must be an object")
            if (type(result.get("schema_version")) is not int or result["schema_version"] != 1
                    or result.get("strategy") != attempt["strategy"]
                    or ("pair" in result and not same_json(result["pair"], attempt["pair"]))
                    or result.get("outcome") not in ("correct", "explicit_failure", "unfinished")):
                raise ValueError("attempt receipt identity or reported outcome is invalid")
            if result["outcome"] == "correct" and result.get("case") != experiment["case"]:
                raise ValueError("correct receipt does not name the declared case")
        except FileNotFoundError:
            state, error = "missing", "attempt receipt unavailable"
        except (OSError, ValueError, RecursionError):
            state, error = "invalid", "attempt receipt cannot be admitted"
        result = dict(result)
        result.update(reported_outcome=result.get("outcome"), receipt_state=state,
                      receipt_sha256=receipt_hash, declared_attempt=dict(attempt))
        if state != "read":
            result.update(outcome="unfinished", receipt_error=error)
        result["process_observation"] = process_observation(root, attempt)
        result["timing_report"] = attempt_timing(root, attempt, result)
        results.append(result)
        by_pair.setdefault(attempt["pair"], []).append(result)
    matching, comparisons = [], []
    for pair in range(experiment["pairs"]):
        paired = by_pair[pair]
        first, second = paired
        mismatch = [key for key in ("case", "fixture_sha256", "skill_reference", "input", "runtime",
                                   "first_offered_tools_sha256", "common_instruction_sha256")
                    if key not in first or key not in second or not same_json(first[key], second[key])]
        timing = reported_pair_timing(paired, mismatch, experiment["case"])
        if not all(result["outcome"] == "correct" for result in paired):
            comparisons.append({"pair": pair, "state": "incomplete", "mismatched_fields": [],
                                "reported_timing": timing, "setup_observation": setup[pair]})
            continue
        comparisons.append({"pair": pair, "state": "mismatch" if mismatch else "matched",
                            "mismatched_fields": mismatch, "reported_timing": timing,
                            "setup_observation": setup[pair]})
        if mismatch:
            for result in paired:
                result.update(outcome="explicit_failure", comparison_errors=mismatch)
        else:
            matching.append({"pair": pair, "first_offered_inventory_reported":
                             all(result["first_offered_tools_sha256"] is not None for result in paired)})
    counts = {name: sum(result["outcome"] == name for result in results)
              for name in ("correct", "explicit_failure", "unfinished")}
    synthetic = experiment["runtime"]["mode"] == "synthetic_streaming"
    return {"case": experiment["case"], "expected": len(attempts), "outcomes": counts,
            "strategy_compliant": sum(result.get("strategy_compliant") is True for result in results),
            "strategy_compliant_scope": "receipt_reported",
            "attempts": results, "synthetic_only": synthetic, "latency_percentiles": None,
            "speedup": None, "matching": matching, "pair_comparisons": comparisons,
            "receipt_states": {state: sum(result["receipt_state"] == state for result in results)
                               for state in ("read", "missing", "invalid")},
            "process_states": {state: sum(result["process_observation"]["state"] == state for result in results)
                               for state in ("read", "missing", "invalid")},
            "setup_states": {state: sum(observation["state"] == state for observation in setup.values())
                             for state in ("read", "missing", "invalid")},
            "comparison_scope": "receipt_reported_common_inputs_only",
            "execution_verified": False, "source_build_verified": False,
            "reason": ("functional protocol samples, no real model performance evidence" if synthetic else
                       "reported input agreement does not verify execution or response-reported model identity"),
            "fixture_hashes": [result.get("fixture_sha256") for result in results if result["outcome"] == "correct"]}


def run(args) -> None:
    experiment = load(args.experiment)
    validate(experiment)
    synthetic = experiment["runtime"]["mode"] == "synthetic_streaming"
    if len(args.source_head) != 40 or any(c not in "0123456789abcdef" for c in args.source_head):
        raise ValueError("--source-head requires an explicit 40-character commit identity")
    driver, prompts, output = args.driver.resolve(strict=True), args.prompts.resolve(strict=True), args.output.resolve()
    if not driver.is_file() or not os.access(driver, os.X_OK):
        raise ValueError("--driver must be an explicitly built executable")
    if not (prompts / "keeper.md").is_file():
        raise ValueError("--prompts must contain the frozen keeper.md")
    output.mkdir(mode=0o700)  # refuses an existing/live output root
    experiment_path = output / "experiment.json"
    save(experiment_path, experiment)
    attempts = declared_attempts(experiment["pairs"])
    for attempt in attempts:
        path = output / attempt["path"]
        path.parent.mkdir(parents=True, mode=0o700)
        save(path, {"schema_version": 1, "outcome": "unfinished", "strategy": attempt["strategy"],
                    "pair": attempt["pair"], "reason": "preallocated_before_fixture_setup"})
    frozen_prompts = output / "prompts"
    frozen_prompts.mkdir(mode=0o700)
    # Prompt_registry scans only direct *.md entries. Copy precisely those
    # source documents, never arbitrary credential/config directories.
    for source in prompts.iterdir():
        if source.suffix == ".md":
            if not stat.S_ISREG(source.lstat().st_mode):
                raise ValueError("prompt source must be a regular file: " + source.name)
            shutil.copy2(source, frozen_prompts / source.name)
    prompts = frozen_prompts
    prompt_files = {path.name: digest(path) for path in prompts.iterdir()}
    manifest = {"schema_version": 1, "scope": ("synthetic_isolated_keeper_explicit_cycle_preparation" if synthetic
                                              else "configured_http_isolated_keeper_explicit_cycle_preparation"),
                "source_head_supplied": args.source_head, "source_head_is_build_proof": False,
                "driver_sha256": digest(driver), "keeper_prompt_sha256": digest(prompts / "keeper.md"),
                "experiment_sha256": digest(experiment_path), "expected_attempts": attempts,
                "prompt_files": prompt_files,
                "claims": {"real_model": False if synthetic else None, "speedup": False, "fleet_latency": False,
                           "synthetic_docker_cli": True, "same_canonical_fixture_base": True}}
    save(output / "manifest.json", manifest)
    for pair in range(experiment["pairs"]):
        pair_root = output / f"pair-{pair:04d}"
        base, snapshot = pair_root / "base", pair_root / "snapshot"
        setup_receipt = pair_root / "setup.json"
        save(setup_receipt, {"outcome": "unfinished", "reason": "before_setup"})
        if invoke(driver, experiment_path, prompts, base, setup_receipt, "setup") != 0:
            continue  # both declared attempts remain unfinished, never omitted
        frozen = inventory(base)
        save(pair_root / "common-inputs.json", frozen)
        shutil.copytree(base, snapshot, symlinks=False)
        for attempt in (value for value in attempts if value["pair"] == pair):
            receipt = output / attempt["path"]
            try:
                restore(base, snapshot, frozen, pair_root)
                code = invoke(driver, experiment_path, prompts, base, receipt, "run", attempt["strategy"])
            except (OSError, ValueError) as error:
                save(receipt.parent / "process.json", {"returncode": None,
                     "observation": "fixture_or_driver_unavailable", "detail": str(error)})
            else:
                # A failure persisting a known return is not an invocation failure.
                save(receipt.parent / "process.json", {"returncode": code, "observed_epoch": time.time()})
    save(output / "summary.json", report_capture(output))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-from", type=Path, help="read an existing capture; print JSON without execution or writes")
    parser.add_argument("--driver", type=Path)
    parser.add_argument("--source-head")
    parser.add_argument("--experiment", type=Path)
    parser.add_argument("--prompts", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        run_arguments = (args.driver, args.source_head, args.experiment, args.prompts, args.output)
        if args.report_from is not None:
            if any(value is not None for value in run_arguments):
                parser.error("--report-from cannot be combined with run arguments")
            print(json.dumps(report_capture(args.report_from), indent=2, ensure_ascii=False, allow_nan=False))
            return 0
        if any(value is None for value in run_arguments):
            parser.error("run requires --driver, --source-head, --experiment, --prompts and --output")
        run(args)
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
