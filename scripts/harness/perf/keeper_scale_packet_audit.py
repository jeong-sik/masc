#!/usr/bin/env python3
"""Audit evidence v3 only; never rewrites original workload receipts/verdicts."""
import argparse
import collections
from contextlib import closing
import datetime
import hashlib
import json
import math
import pathlib
import sqlite3


EVIDENCE_SCHEMA = "masc.keeper-scale-evidence.v3"
# Exit status when the workload validates but the last inventory coverage
# group is incomplete; every derived record is still written. 0 keeps meaning
# that every observed group covered every expected volume.
INCOMPLETE_INVENTORY_EXIT = 3


def read(path):
    return json.loads(path.read_text())


def lines(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def full_typed_digest(columns, rows):
    canonical = [[(column, type(row[column]).__name__, row[column].hex()
                   if isinstance(row[column], bytes) else repr(row[column])) for column in columns] for row in rows]
    return hashlib.sha256(json.dumps(canonical, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def stats(values):
    values = sorted(values)
    return {"count": len(values), **({key: values[math.ceil(q * len(values)) - 1]
            for key, q in [("p50", .5), ("p95", .95), ("p99", .99)]} if values else {}),
            "max": max(values) if values else None}


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)
    elif isinstance(value, str):
        for line in value.splitlines():
            try:
                child = json.loads(line)
            except ValueError:
                continue
            if not isinstance(child, str):
                yield from objects(child)


def rpc_result(request):
    body = request["body_utf8"]
    try:
        documents = [json.loads(body)]
    except ValueError:
        documents = [json.loads("\n".join(line[5:].lstrip() for line in block.splitlines()
            if line.startswith("data:"))) for block in body.replace("\r\n", "\n").split("\n\n")
            if any(line.startswith("data:") for line in block.splitlines())]
    matches = [item for item in documents if item.get("id") == request["payload"]["id"]]
    assert len(matches) == 1 and "error" not in matches[0]
    assert matches[0]["result"].get("isError", False) is False
    return matches[0]["result"]


def audit_original_payloads(packet, admitted, snapshots, public, terminal):
    workload = read(packet / "workload.json")
    assert read(packet / "principal.json") == {"actor": "dashboard", "role": "admin"}
    originals = {}
    requests = lines(packet / "requests.jsonl")
    enqueues = [item for item in requests
                if item.get("phase") == "enqueue" and item.get("status") == 200]
    assert len(enqueues) == len(admitted)
    for op, request in zip(admitted, enqueues):
        name, sequence = op["keeper"], op["sequence"]
        message = json.dumps({"schema": "masc.keeper-scale-input.v1", "marker": workload["marker"],
                              "keeper": name, "sequence": sequence}, sort_keys=True)
        assert request["payload"]["params"] == {"name": "masc_keeper_msg", "arguments": {"name": name, "message": message}}
        acceptances = [item for item in objects(rpc_result(request))
                       if set(item) == {"operation_id", "state", "queued_count", "existing"}]
        assert acceptances and all(item["operation_id"] == op["operation_id"] and item["existing"] is False
                                   for item in acceptances)
        thread = "keeper:" + name
        source = {"schema": "masc.keeper_chat_operation.source.v2", "submitted_by": "dashboard",
            "thread_id": thread, "continuation_channel": {"kind": "dashboard", "thread_id": thread},
            "surface": {"kind": "agent"}, "channel": "agent", "channel_user_id": "",
            "channel_user_name": "", "channel_workspace_id": "", "conversation_id": None,
            "external_message_id": None, "workspace_id": None, "extra_mentions": [],
            "sender_keeper": None, "user_row_origin": "needs_append"}
        input_ = {"schema": "masc.keeper_chat_operation.input.v1", "message": message,
                  "user_blocks": [], "attachments": [], "turn_instructions": None, "surface_context": None}
        originals[(name, op["operation_id"])] = {"source": source, "input": input_}
        assert op["original"] == originals[(name, op["operation_id"])]
    observations = collections.defaultdict(list)
    for request in requests:
        if request.get("phase") != ("settlement" if terminal else "queue-held") or request.get("status") != 200:
            continue
        arguments = request["payload"]["params"]["arguments"]
        assert request["payload"]["params"]["name"] == "masc_keeper_delegate_status"
        key = arguments["target"]["name"], arguments["operation_id"]
        observations[key].extend(item for item in objects(rpc_result(request))
            if item.get("schema") == "masc.keeper_chat_operation.v1")
    assert all(status in observations[key] for key, status in public.items())

    def encoded(value):
        # Only independently reconstructed ASCII/null/list/object fixture
        # values are encoded here; this is not a general Yojson codec.
        result = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        assert result.isascii()
        return result

    def hashed(value):
        return hashlib.sha256(encoded(value).encode()).hexdigest()

    seen = set()
    for entry in snapshots:
        name = entry["keeper"]
        tables = entry["snapshot"]
        if terminal:
            # Resolve the actual recorded owner path within the retained base.
            assert pathlib.Path(entry["source_path"]).is_relative_to(packet / "owned-base" / ".masc")
            retained = pathlib.Path(entry["source_path"])
            assert retained.parent.name == name
            for database in [retained, packet / "durable" / name / "chat-operations.sqlite3"]:
                with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as conn:
                    assert conn.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
                    conn.row_factory = sqlite3.Row
                    conn.execute("BEGIN")
                    for table, order in [("operations", "sequence"), ("operation_batch_members", "execution_id,position")]:
                        cursor = conn.execute("SELECT * FROM " + table + " ORDER BY " + order)
                        columns = [item[0] for item in cursor.description]
                        rows = [dict(row) for row in cursor]
                        assert columns == tables[table]["columns"]
                        assert full_typed_digest(columns, rows) == full_typed_digest(columns, tables[table]["rows"])
                    conn.rollback()
        rows = {row["operation_id"]: row for row in tables["operations"]["rows"]}
        assert len(rows) == len(tables["operations"]["rows"])
        owned = {key[1]: value for key, value in originals.items() if key[0] == name}
        assert set(rows) == set(owned)
        membership, groups = {}, collections.defaultdict(list)
        for member in tables["operation_batch_members"]["rows"]:
            opid = member["operation_id"]
            assert opid in rows and opid not in membership and member["execution_id"] in rows
            membership[opid] = member
            groups[member["execution_id"]].append(member)
            assert member["admitted_digest"] == hashed(owned[opid]["input"])
            assert member["admitted_input_json"] == (None if terminal else encoded(owned[opid]["input"]))
        executions = {opid: original["input"] for opid, original in owned.items()}
        for leader, group in groups.items():
            group.sort(key=lambda item: item["position"])
            assert len(group) >= 2 and group[0]["operation_id"] == leader
            assert [item["position"] for item in group] == list(range(len(group)))
            sequence = [rows[item["operation_id"]]["sequence"] for item in group]
            assert sequence == list(range(sequence[0], sequence[0] + len(group)))
            inputs = [owned[item["operation_id"]]["input"] for item in group]
            executions[leader] = {**inputs[0], "message": "\n\n".join(item["message"] for item in inputs),
                "user_blocks": [{"type": "text", "text": item["message"]} for item in inputs]}
        for opid, row in rows.items():
            key = name, opid
            assert key not in seen
            seen.add(key)
            original, status = owned[opid], public[key]
            member = membership.get(opid)
            projected_state = rows[member["execution_id"]]["state"] if member else row["state"]
            assert row["source_json"] == encoded(original["source"])
            assert row["admission_digest"] == hashed(original)
            assert row["execution_digest"] == hashed(executions[opid])
            assert row["input_json"] == (None if terminal else encoded(executions[opid]))
            assert status["source"] == original["source"] and status["input"] == (None if terminal else executions[opid])
            assert all(status[field] == row[field] for field in ["admission_digest", "execution_digest", "created_at"])
            assert status["sequence"] == str(row["sequence"]) and status["state"].lower() == projected_state
            assert status.get("batch_execution_id") == (None if member is None else member["execution_id"])
            assert status.get("batch_input_digest") == (None if member is None else member["admitted_digest"])
    assert seen == set(originals)


def classify_inventory(guards, base, expected_volumes):
    inventory = []
    unclassified = []
    for row in guards:
        argv = row["argv"]
        assert isinstance(argv, list) and argv and all(isinstance(arg, str) for arg in argv)
        assert type(row["time_ns"]) is int
        kind = pathlib.Path(argv[0]).name
        assert pathlib.Path(argv[0]).parent == pathlib.Path(base) / "deny-guest-commands"
        if (kind, argv[1:]) == ("container", ["list", "--all", "--format", "json"]):
            inventory.append(("container_list", row))
        elif kind == "nerdctl" and len(argv) == 6 and argv[1:5] == ["ps", "-a", "--no-trunc", "--format"]:
            inventory.append(("nerdctl_ps", row))
        elif kind == "container" and len(argv) == 4 and argv[1:3] == ["volume", "inspect"] and argv[3] in expected_volumes:
            inventory.append(("container_volume_inspect", row))
        else:
            unclassified.append(row)
    assert not unclassified, unclassified
    return inventory, unclassified


def inventory_coverage(inventory, expected_volumes, phase_starts):
    """Observed coverage groups; receipts do not contain producer sweep IDs."""
    assert expected_volumes
    inspections = [row for kind, row in inventory if kind == "container_volume_inspect"]
    sweeps = []
    for offset in range(0, len(inspections), len(expected_volumes)):
        selected = inspections[offset:offset + len(expected_volumes)]
        observed = collections.Counter(row["argv"][3] for row in selected)
        complete = len(selected) == len(expected_volumes)
        if complete:
            assert observed == {name: 1 for name in expected_volumes}
        else:
            assert set(observed) <= expected_volumes, "unknown volume in final partial segment"
            assert all(count == 1 for count in observed.values()), "duplicate volume in final partial segment"
        by_phase = collections.Counter(next((phase["phase"] for phase in reversed(phase_starts)
            if "wall_time_ns" in phase and phase["wall_time_ns"] <= row["time_ns"]), "unavailable") for row in selected)
        sweeps.append({"pass": len(sweeps)+1, "commands": len(selected), "complete": complete,
            "observed_volume_count": len(observed), "expected_volume_count": len(expected_volumes),
            "missing_volumes": sorted(expected_volumes - set(observed)),
            "exact_expected_volume_set": complete,
            "first_attempt_wall_time_ns": selected[0]["time_ns"], "last_attempt_wall_time_ns": selected[-1]["time_ns"],
            "attempt_timestamp_span_ms": (selected[-1]["time_ns"]-selected[0]["time_ns"])/1e6,
            "first_attempt_utc": datetime.datetime.fromtimestamp(selected[0]["time_ns"]/1e9, datetime.timezone.utc).isoformat(),
            "last_attempt_utc": datetime.datetime.fromtimestamp(selected[-1]["time_ns"]/1e9, datetime.timezone.utc).isoformat(),
            "commands_by_workload_phase": dict(by_phase)})
    return {"scope": "Observed coverage groups, not producer sweep IDs. A final unique known-volume subset is incomplete; missing volumes are unobserved coverage, not proven lost log records. Wrappers refuse126 by source authority, not per-attempt exit receipts. Spans include concurrency and scheduling, not isolated subprocess overhead.",
        "expected_volumes_per_segment": len(expected_volumes), "observed_inspection_commands": len(inspections),
        "complete_observed_segments": sum(row["complete"] for row in sweeps),
        "final_partial_segment": sweeps[-1] if sweeps and not sweeps[-1]["complete"] else None,
        "sweeps": sweeps}


def _audit(packet, output):
    identity = read(packet / "identity.json")
    assert identity["evidence_schema"] == EVIDENCE_SCHEMA, "reader requires explicitly versioned v3 evidence"
    assert sha(packet / "masc-installed-copy") == identity["sha256"]
    assert sha(packet / "keeper_scale_session.py") == identity["runner_sha256"]
    workload = read(packet / "workload.json")
    names = workload["keepers"]
    admitted = read(packet / "operations-admitted.json")
    terminal_document = read(packet / "terminal.json")
    assert terminal_document["schema"] == EVIDENCE_SCHEMA
    durable = read(packet / "durable-operations.json")
    expected = {(row["keeper"], row["operation_id"]): row for row in admitted}
    assert len(expected) == len(admitted) == len(names) * workload["messages_per_keeper"]
    terminal_entries = terminal_document["operations"]
    terminal = {(entry["keeper"], entry["operation_id"]): entry["status"] for entry in terminal_entries}
    assert len(terminal) == len(terminal_entries) == len(expected)
    assert set(terminal) == set(expected)
    assert all(entry["sequence"] == expected[(entry["keeper"], entry["operation_id"])]["sequence"]
               for entry in terminal_entries)
    assert len(durable) == len(names) and {x["keeper"] for x in durable} == set(names)
    assert collections.Counter((row["keeper"], row["sequence"]) for row in admitted) == {
        (name, sequence): 1 for name in names for sequence in range(1, workload["messages_per_keeper"] + 1)}
    operations = []
    for keeper in durable:
        rows = keeper["rows"]
        owned = {key for key in expected if key[0] == keeper["keeper"]}
        row_keys = [(keeper["keeper"], row["operation_id"]) for row in rows]
        assert len(row_keys) == len(set(row_keys)) and set(row_keys) == owned
        database = packet / "durable" / keeper["keeper"] / "chat-operations.sqlite3"
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as conn:
            assert conn.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
            conn.row_factory = sqlite3.Row
            actual = [dict(row) for row in conn.execute(
                "SELECT operation_id,state,started_at,completed_at,outcome_ref,failure_kind FROM operations ORDER BY sequence")]
            assert actual == rows
            cursor = conn.execute("SELECT * FROM operations ORDER BY sequence")
            columns = [entry[0] for entry in cursor.description]
            full_rows = [dict(row) for row in cursor]
            receipt = keeper["backup_validation"]
            assert receipt["read_only_reopened"] is True and receipt["source_connection_closed"] is True
            assert receipt["integrity_check"] == "ok" and receipt["exact_typed_rows_equal"] is True
            assert receipt["row_count"] == len(full_rows) and receipt["columns"] == columns
            assert receipt["typed_rows_sha256"] == full_typed_digest(columns, full_rows)
        for row in rows:
            op = row["operation_id"]
            key = keeper["keeper"], op
            target, public = expected[key], terminal[key]
            assert public["operation_id"] == op
            assert row["state"] == "succeeded" and public["state"] == "Succeeded"
            assert row["outcome_ref"] == public["outcome_ref"] and row["outcome_ref"]
            assert row["completed_at"] == public["completed_at"] and row["failure_kind"] is None
            replies = [obj for obj in objects(public["completed_reply"])
                       if obj.get("schema") == "masc.keeper-scale-reply.v1"]
            assert len(replies) == 1
            reply = replies[0]
            assert reply["keeper"] == target["keeper"] and reply["marker"] == workload["marker"]
            assert target["sequence"] in reply["sequences"]
            operations.append({"keeper": target["keeper"], "sequence": target["sequence"], "operation_id": op,
                "created_at": public["created_at"], "started_at": row["started_at"], "completed_at": row["completed_at"],
                "created_to_completed_ms": (row["completed_at"] - public["created_at"]) * 1000,
                "created_to_started_ms": (row["started_at"] - public["created_at"]) * 1000,
                "started_to_completed_ms": (row["completed_at"] - row["started_at"]) * 1000,
                "admission_success_wire_ms": target["admission_wire_ms"],
                "admission_first_attempt_to_accepted_ms": target["first_attempt_to_accepted_ms"]})
    models = lines(packet / "model-outcomes.jsonl")
    assert len(models) == len(lines(packet / "model-requests.jsonl"))
    coverage = collections.defaultdict(list)
    timeline = []
    for row in models:
        assert "error" not in row and row["end_ns"] >= row["start_ns"]
        typed_messages = [[obj for obj in objects(message.get("content"))
                           if obj.get("schema") == "masc.keeper-scale-input.v1"]
                          for message in row["request"]["messages"] if message.get("role") == "user"]
        typed_messages = [probes for probes in typed_messages if probes]
        assert typed_messages
        probes = typed_messages[-1]
        assert all(probe["marker"] == workload["marker"] and probe["keeper"] == row["keeper"] for probe in probes)
        sequences = [probe["sequence"] for probe in probes]
        assert all(type(sequence) is int and sequence > 0 for sequence in sequences)
        assert sequences == row["sequences"]
        coverage[row["keeper"]].extend(sequences)
        timeline.extend([(row["start_ns"], 1), (row["end_ns"], -1)])
    assert set(coverage) == set(names)
    assert all(sorted(sequences) == list(range(1, workload["messages_per_keeper"] + 1))
               for sequences in coverage.values())
    active = peak = 0
    for _, delta in sorted(timeline):
        active += delta
        peak = max(peak, active)
    assert active == 0 and peak == len(names)
    guards = read(packet / "guest-command-attempts.json")
    expected_volumes = {"masc-keeper-" + kind + "-" + name for kind in ["work", "build"] for name in names}
    inventory, unclassified = classify_inventory(guards, identity["base"], expected_volumes)
    cleanup = read(packet / "cleanup.json")
    assert cleanup == {"server_returncode": 0, "server_reaped": True, "forced_kill": False,
        "sampler_stopped": True, "model_server_stopped": True, "base_retained": True,
        "base_path": str(packet / "owned-base"),
        "provider_requests_drained": True, "active_provider_requests": 0, "provider_handler_threads": 0}
    assert pathlib.Path(identity["base"]) == packet / "owned-base"
    assert (packet / "owned-base").is_dir()
    audit_original_payloads(packet, admitted, read(packet / "admission-snapshots.json"),
        {(item["keeper"], item["status"]["operation_id"]): item["status"]
         for item in read(packet / "queue-held.json")}, terminal=False)
    audit_original_payloads(packet, admitted, durable, terminal, terminal=True)
    requests = lines(packet / "requests.jsonl")
    waits = lines(packet / "rate-limit-waits.jsonl")
    intervals = lines(packet / "rpc-intervals.jsonl")
    assert len(waits) == sum(row.get("status") == 429 for row in requests)
    assert sum(row["rejected_429_count"] for row in intervals) == len(waits)
    for request_id in {row["request_id"] for row in waits}:
        attempts = [row for row in requests if row.get("payload", {}).get("id") == request_id]
        assert attempts[-1].get("status") == 200 and all(row.get("status") == 429 for row in attempts[:-1])
        assert all(row["payload"] == attempts[0]["payload"] for row in attempts)
    samples = read(packet / "latency-samples.json")
    phase_stats = {}
    for phase in dict.fromkeys(row["workload_phase"] for row in samples):
        selected = [row for row in samples if row["workload_phase"] == phase]
        phase_stats[phase] = {"samples": len(selected), "failures": sum(not row.get("valid") for row in selected),
                              "successful_wire_ms": stats(row["wire_ms"] for row in selected if row.get("valid"))}
    phase_requests = {}
    for phase in dict.fromkeys(row["phase"] for row in requests):
        selected = [row for row in requests if row["phase"] == phase]
        phase_requests[phase] = {"attempts": len(selected), "status_counts": dict(collections.Counter(
            str(row.get("status", row.get("error"))) for row in selected)),
            "successful_wire_ms": stats(row["wire_ms"] for row in selected if row.get("status") == 200),
            "failed_attempt_elapsed_ms": stats((row["end_ns"]-row["start_ns"])/1e6
                                                 for row in selected if row.get("status") != 200)}
    original_failure = read(packet / "failure.json") if (packet / "failure.json").exists() else None
    phases = read(packet / "workload-phases.json")
    release_ns = next(row["at_ns"] for row in phases if row.get("event") == "provider_release")
    phase_starts = [row for row in phases if "phase" in row]
    phase_windows = [{"phase": row["phase"], "start_ns": row["started_ns"],
                     "end_ns": phase_starts[i + 1]["started_ns"],
                     "duration_ms": (phase_starts[i + 1]["started_ns"]-row["started_ns"])/1e6}
                    for i, row in enumerate(phase_starts[:-1])]
    release_event = next(row for row in phases if row.get("event") == "provider_release")
    inventory_audit = inventory_coverage(inventory, expected_volumes, phase_starts)
    (output / "inventory-sweep-audit.json").write_text(json.dumps({**inventory_audit, "packet": packet.name,
        "raw_receipt": "guest-command-attempts.json",
        "source_binding": {"source_commit": identity["source"], "identity_receipt": "identity.json"}}, indent=2)+"\n")
    if "wall_time_ns" in release_event:
        # This is an approximate cross-clock alignment, not a synchronized trace.
        clock_offset = release_event["wall_time_ns"] - release_event["at_ns"]
        aligned = []
        for request in requests:
            if request.get("phase") != "settlement" or not (request.get("error") or request.get("wire_ms", 0) > 1000):
                continue
            arguments = request["payload"]["params"]["arguments"]
            public = terminal[(arguments["target"]["name"], arguments["operation_id"])]
            aligned.append({"request_id": request["payload"]["id"], "keeper": arguments["target"]["name"],
                "operation_id": arguments["operation_id"], "start_from_release_s": (request["start_ns"]-release_ns)/1e9,
                "attempt_elapsed_ms": (request["end_ns"]-request["start_ns"])/1e6,
                "status_or_error": request.get("status", request.get("error")),
                "durable_operation_completion_minus_request_start_ms": public["completed_at"]*1000-(request["start_ns"]+clock_offset)/1e6,
                "caveat": "Cross-clock alignment uses adjacent wall/perf phase anchor, no exact synchronization guarantee."})
        (output / "slow-status-completion-alignment.json").write_text(json.dumps(aligned, indent=2)+"\n")
    report = {"evidence_schema": EVIDENCE_SCHEMA, "packet": packet.name,
        "source": identity["source"], "binary_sha256": identity["sha256"],
        "packet_auditor_sha256": sha(pathlib.Path(__file__)),
        "runner_sha256": identity["runner_sha256"], "original_run_failure_preserved": original_failure,
        "post_run_workload_validation": "PASS", "overall_original_run_verdict": "FAIL" if original_failure else "PASS",
        "inventory_final_segment_complete": inventory_audit["final_partial_segment"] is None,
        "keepers": len(names), "public_and_exact_owner_durable_succeeded_operations": len(operations),
        "real_model_calls": len(models), "max_provider_requests_in_flight": peak,
        "phase_windows": phase_windows,
        "provider_release_to_response_end_ms": stats((row["end_ns"]-release_ns)/1e6 for row in models),
        "guard_classification_audit": {"all_calls_were_denied_by_wrapper": True,
            "read_only_inventory_by_exact_argv": dict(collections.Counter(kind for kind, _ in inventory)),
            "unclassified_calls": len(unclassified), "inventory_coverage": inventory_audit,
            "scope": "Post-run classification only; original guard receipt and verdict unchanged. No daemon/guest executed or inspected."},
        "liveness_wire_ms_by_workload_phase": phase_stats, "mcp_attempts_by_request_phase": phase_requests,
        "read_only_observation_failures": lines(packet / "operation-observation-failures.jsonl"),
        "http_429": len(waits), "rate_limit_wait_s": sum((r["wait_finished_ns"]-r["wait_started_ns"])/1e9 for r in waits),
        "operation_wall_clock_ms": {field: stats(row[field] for row in operations) for field in [
            "created_to_completed_ms", "created_to_started_ms", "started_to_completed_ms",
            "admission_success_wire_ms", "admission_first_attempt_to_accepted_ms"]},
        "operation_wall_clock_ms_by_sequence": {str(seq): {field: stats(row[field] for row in operations if row["sequence"] == seq)
            for field in ["created_to_completed_ms", "created_to_started_ms", "started_to_completed_ms"]}
            for seq in range(1, workload["messages_per_keeper"]+1)},
        "cleanup_verified": cleanup,
        "limits": ["One admin producer; not independent HTTP actors.", "Loopback scripted text model; no external model throughput claim.",
            "First turns intentionally held until all owners called provider and both operation sets observed.",
            "Operation lifetimes include hold, queue, scheduler, I/O and runtime work; not CPU-only execution latency.",
            "Shared host, sequential one run per population; no causal scaling attribution.", "No guest, Addon, TUI or browser execution proof."]}
    (output / "post-run-audit.json").write_text(json.dumps(report, indent=2) + "\n")
    (output / "operation-wall-samples.json").write_text(json.dumps(operations, indent=2) + "\n")
    outliers = [{"request_log_line": i + 1, **{key: row[key] for key in [
        "start_ns", "end_ns", "phase", "payload", "wire_ms", "wire_bytes", "server_timing"] if key in row}}
        for i, row in sorted(enumerate(requests), key=lambda item: item[1].get("wire_ms", -1), reverse=True)[:20]]
    (output / "mcp-wire-outliers.json").write_text(json.dumps(outliers, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ["packet", "overall_original_run_verdict", "post_run_workload_validation",
        "inventory_final_segment_complete", "keepers",
        "public_and_exact_owner_durable_succeeded_operations", "real_model_calls", "max_provider_requests_in_flight", "http_429", "rate_limit_wait_s"]}))
    return report


def audit(packet, output):
    """Own a fresh external output; preserve originals and any original failure."""
    packet = pathlib.Path(packet).resolve(strict=True)
    assert packet.is_dir(), "packet must be a directory"
    requested = pathlib.Path(output)
    if requested.name in {"", ".", ".."} or requested.is_symlink():
        raise ValueError("output must be a fresh directory, not a symlink")
    output = requested.parent.resolve(strict=True) / requested.name
    if output.is_symlink() or output.is_relative_to(packet):
        raise ValueError("output must be outside the original packet and not a symlink")
    output.mkdir()  # Exclusive creation; existing files/directories are never reused.
    try:
        return _audit(packet, output)
    except BaseException as error:
        try:
            (output / "audit-failure.json").write_text(json.dumps({
                "evidence_schema": EVIDENCE_SCHEMA, "packet": packet.name,
                "error_type": type(error).__name__, "error": str(error),
                "packet_auditor_sha256": sha(pathlib.Path(__file__))}, indent=2) + "\n")
        except Exception as receipt_error:
            error.add_note("Could not retain audit-failure.json: " + repr(receipt_error))
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "exit 0: every observed inventory coverage group is complete; exit %d: the workload validates "
        "but the last group is incomplete (all records written); any other failure raises" % INCOMPLETE_INVENTORY_EXIT))
    parser.add_argument("packet", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True,
                        help="fresh external directory for derived records; never an original packet path")
    args = parser.parse_args(argv)
    report = audit(args.packet, args.output)
    return 0 if report["inventory_final_segment_complete"] else INCOMPLETE_INVENTORY_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
