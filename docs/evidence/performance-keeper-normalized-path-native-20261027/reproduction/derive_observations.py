#!/usr/bin/env python3
"""Describe all six closed, audited plan cells; never launches or edits a run."""
import argparse
import collections
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_bytes())


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def allocation_snapshot(health):
    gc = health["gc"]
    return (gc["minor_words"] + gc["major_words"] - gc["promoted_words"]) * 8


def describe(cell, plan, qualification, inputs):
    assert cell in plan["order"] and cell["role"] in ("candidate", "control")
    packet = Path(cell["output"])
    names = ["identity.json", "post-run-audit.json", "health-before.json",
             "health-after.json", "owned-process.json", "requests.jsonl",
             "workload-phases.jsonl", "cleanup.json"]
    for name in names:
        inputs[str(Path(packet.name) / name)] = digest(packet / name)
    identity, report = read(packet / names[0]), read(packet / names[1])
    before, after = read(packet / "health-before.json"), read(packet / "health-after.json")
    owner = read(packet / "owned-process.json")
    role, keepers = cell["role"], cell["keepers"]
    expected_base = str(packet / "owned-base")
    expected_masc_root = str(packet / "owned-base/.masc")
    expected_executable = str(packet / "masc-installed-copy")
    binary_sha = (qualification["candidate_server_sha256"] if role == "candidate"
                  else plan["native_paths"]["control_binary_sha256"])
    source = plan[role + "_application_source"]
    assert qualification[role + "_source"] == source
    assert qualification[role + "_server_sha256"] == binary_sha
    assert report["packet"] == packet.name
    assert identity["source"] == report["source"] == source
    assert identity["sha256"] == report["binary_sha256"] == binary_sha
    assert identity["original_binary"] == plan["native_paths"][role + "_binary"]
    assert identity["copied_binary"] == expected_executable
    assert identity["base"] == owner["base"] == expected_base
    assert owner["source"] == source and owner["binary_sha256"] == binary_sha
    assert type(owner["pid"]) is int and owner["pid"] > 0
    assert identity["runner_sha256"] == report["runner_sha256"] == plan["runner"]["sha256"]
    assert report["packet_auditor_sha256"] == plan["reader"]["sha256"]
    assert identity["runtime_fixture_sha256"] == plan["fixture_sha256"]
    assert report["evidence_schema"] == "masc.keeper-scale-evidence.v3"
    assert report["overall_original_run_verdict"] == report["post_run_workload_validation"] == "PASS"
    assert report["keepers"] == keepers
    assert report["public_and_exact_owner_durable_succeeded_operations"] == keepers * plan["fixed_parameters"]["messages_per_keeper"]
    assert before["keeper_fibers"] == 0 and after["keeper_fibers"] == keepers
    instance = before["build"]["runtime_instance_id"]
    assert isinstance(instance, str) and instance.strip()
    for health in [before, after]:
        assert health["build"]["binary_commit"] == source
        assert health["build"]["executable_sha256"] == binary_sha
        assert health["build"]["executable_path"] == expected_executable
        assert health["build"]["runtime_instance_id"] == instance
        assert health["paths"]["effective_base_path"] == expected_base
        assert health["paths"]["effective_masc_root"] == expected_masc_root
        assert type(health["process_memory"]["pid"]) is int
        assert health["process_memory"]["pid"] == owner["pid"]
    requests = [json.loads(line) for line in (packet / "requests.jsonl").read_text().splitlines()]
    initialization = [row for row in requests if row["phase"] == "initialize"]
    creation = [row for row in requests if row["phase"] == "create"]
    assert len(initialization) == 1 and len(creation) >= keepers
    assert type(owner["started_ns"]) is int and owner["started_ns"] >= 0
    for request in initialization + creation:
        assert type(request["start_ns"]) is type(request["end_ns"]) is int
        assert owner["started_ns"] <= request["start_ns"] <= request["end_ns"]
    assert min(row["start_ns"] for row in creation) >= initialization[0]["end_ns"]
    cleanup = read(packet / "cleanup.json")
    assert cleanup == report["cleanup_verified"] and cleanup["base_path"] == expected_base
    delta = allocation_snapshot(after) - allocation_snapshot(before)
    assert delta >= 0 and delta.is_integer()
    failures = collections.Counter(row["error"] for row in report["read_only_observation_failures"])
    return {
        "packet": packet.name, "role": role, "keepers": keepers,
        "source": source, "binary_sha256": binary_sha,
        "runtime_instance_id": instance, "server_pid": owner["pid"],
        "effective_base_path": expected_base, "effective_masc_root": expected_masc_root,
        "runner_sha256": identity["runner_sha256"],
        "packet_auditor_sha256": report["packet_auditor_sha256"],
        "runtime_fixture_sha256": identity["runtime_fixture_sha256"],
        "original_verdict": report["overall_original_run_verdict"],
        "offline_validation": report["post_run_workload_validation"],
        "succeeded_operations": report["public_and_exact_owner_durable_succeeded_operations"],
        "actual_scripted_model_calls": report["real_model_calls"],
        "provider_peak": report["max_provider_requests_in_flight"],
        "health_quick_stat_derived_allocation_snapshot_delta_bytes": int(delta),
        "gc_before": before["gc"], "gc_after": after["gc"],
        "process_memory_after": after["process_memory"],
        "post_spawn_receipt_to_initialize_request_envelope_ms": (initialization[0]["start_ns"] - owner["started_ns"]) / 1e6,
        "creation_attempt_envelope_ms": (max(row["end_ns"] for row in creation) - min(row["start_ns"] for row in creation)) / 1e6,
        "mcp_attempts_by_phase": report["mcp_attempts_by_request_phase"],
        "liveness_by_phase": report["liveness_wire_ms_by_workload_phase"],
        "read_observation_failures": dict(failures),
        "http429": report["http_429"], "rate_wait_s": report["rate_limit_wait_s"],
        "readiness_after": {key: after[key] for key in ["overall_status", "operator_action_required", "overall_status_reasons"]},
        "phase_windows": report["phase_windows"],
        "cleanup": cleanup,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    plan, qualification = read(directory / "plan.json"), read(directory / "execution-qualification.json")
    assert digest(directory / "plan.json") == qualification["plan_sha256"]
    inputs = {name: digest(directory / name) for name in ["plan.json", "execution-qualification.json"]}
    rows = [describe(cell, plan, qualification, inputs) for cell in plan["order"]]
    report = {
        "schema": "masc.normalized-path-copy-native-observations.v1",
        "rows": rows, "input_sha256": inputs, "deriver_sha256": digest(Path(__file__)),
        "limits": [
            "Descriptive six-cell record; fixed 300-owner ABBA has two cohorts per role on a shared host, without stable SLO or confidence claim.",
            "Allocation is a 64-bit health Gc.quick_stat snapshot-counter derivative; it may lag collections and is neither Gc.allocated_bytes() nor function-exclusive allocation or exact phase allocation.",
            "Successful wire distributions accompany separate failures, 429 waits and degraded full readiness.",
            "Startup is post-Popen receipt-to-initialize request preparation including polling/auth; it excludes preceding Popen work and is not exact ready transition or UI paint.",
            "Loopback scripted text model and deliberately held queues; no real model, peer business, broadcast, guest/Add-on or TUI proof.",
        ],
    }
    with args.output.open("x") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
    print(json.dumps({"output": str(args.output), "cohorts": len(rows), "sha256": digest(args.output)}))


if __name__ == "__main__":
    main()
