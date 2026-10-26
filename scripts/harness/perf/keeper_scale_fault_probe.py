#!/usr/bin/env python3
"""Fault probes for evidence identity/backup checks; never starts MASC."""
import argparse
import copy
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
from unittest import mock

import keeper_scale_session as harness


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cases = []

    def reject(name, action):
        try:
            action()
        except (harness.ProbeError, sqlite3.Error) as error:
            cases.append({"case": name, "result": "rejected", "error": type(error).__name__, "detail": str(error)})
        else:
            raise AssertionError("fault was accepted: " + name)

    def operation(owner, sequence=1, operation_id="same-owner-scoped-id"):
        return {"keeper": owner, "sequence": sequence, "operation_id": operation_id}

    def public(op):
        return {"operation_id": op["operation_id"], "state": "Succeeded", "completed_at": 2.0,
            "outcome_ref": op["keeper"] + "#1", "completed_reply": {"replies": [{"text": json.dumps({
                "schema": "masc.keeper-scale-reply.v1", "marker": "fixture", "keeper": op["keeper"],
                "sequences": [op["sequence"]]})}]}}

    def row(op):
        return {"operation_id": op["operation_id"], "state": "succeeded", "started_at": 1.0,
                "completed_at": 2.0, "outcome_ref": op["keeper"] + "#1", "failure_kind": None}

    a, b = operation("owner-a"), operation("owner-b")
    reject("two original inputs sharing one owner-scoped admission ID",
           lambda: harness.index_operations([a, operation("owner-a", 2)]))
    reject("duplicate original input with two operation IDs",
           lambda: harness.index_operations([a, operation("owner-a", 1, "other-id")]))
    indexed = harness.index_operations([a, b])
    terminal = {harness.operation_key(op): public(op) for op in [a, b]}
    receipt = harness.terminal_receipt([a, b], terminal)
    assert len(indexed) == len(receipt["operations"]) == 2
    assert {entry["keeper"] for entry in receipt["operations"]} == {"owner-a", "owner-b"}
    durable = [{"keeper": op["keeper"], "rows": [row(op)]} for op in [a, b]]
    assert len(harness.validate_durable_operations([a, b], ["owner-a", "owner-b"], durable, terminal, "fixture")) == 2
    cases.append({"case": "same operation ID under two distinct owners", "result": "preserved through pending/terminal/durable join"})
    reject("reply missing second original sequence",
           lambda: harness.validate_completed_operation(operation("owner-a", 2), public(a), "fixture"))
    reject("reply belongs to other owner", lambda: harness.validate_completed_operation(a, public(b), "fixture"))
    wrong_id = public(a)
    wrong_id["operation_id"] = "other-id"
    reject("public receipt has different operation ID", lambda: harness.validate_completed_operation(a, wrong_id, "fixture"))
    duplicate_rows = copy.deepcopy(durable)
    duplicate_rows[0]["rows"].append(row(a))
    reject("duplicate durable rows do not collapse into a set", lambda: harness.validate_durable_operations(
        [a, b], ["owner-a", "owner-b"], duplicate_rows, terminal, "fixture"))

    originals = [operation("owner-a", sequence, "op-" + str(sequence)) for sequence in (1, 2, 3)]
    snapshot = {"operations": {"columns": [], "rows": []},
                "operation_batch_members": {"columns": [], "rows": []}}
    public_held = {}
    for sequence, op in enumerate(originals):
        op["original"] = harness.original_payload(op["keeper"], "fixture-" + str(op["sequence"]))
        payload = op["original"]
        snapshot["operations"]["rows"].append({"operation_id": op["operation_id"], "sequence": sequence,
            "created_at": 0.0, "state": "queued", "source_json": harness.canonical_payload(payload["source"]),
            "input_json": harness.canonical_payload(payload["input"]),
            "admission_digest": harness.payload_digest(payload), "execution_digest": harness.payload_digest(payload["input"])})
    # A running batch leader has a merged execution input while every member
    # retains its original admission digest. A third operation is unbatched.
    merged = {**originals[0]["original"]["input"], "message": "fixture-1\n\nfixture-2",
        "user_blocks": [{"type": "text", "text": "fixture-1"}, {"type": "text", "text": "fixture-2"}]}
    snapshot["operations"]["rows"][0].update(state="running", input_json=harness.canonical_payload(merged),
        execution_digest=harness.payload_digest(merged))
    for position, op in enumerate(originals[:2]):
        snapshot["operation_batch_members"]["rows"].append({"operation_id": op["operation_id"],
            "execution_id": "op-1", "position": position,
            "admitted_digest": harness.payload_digest(op["original"]["input"]),
            "admitted_input_json": harness.canonical_payload(op["original"]["input"])})
    for op, stored in zip(originals, snapshot["operations"]["rows"]):
        status = {"operation_id": op["operation_id"], "source": op["original"]["source"],
            "input": json.loads(stored["input_json"]), "sequence": str(stored["sequence"]),
            "created_at": stored["created_at"], "state": stored["state"].capitalize(),
            "admission_digest": stored["admission_digest"], "execution_digest": stored["execution_digest"]}
        if op in originals[:2]:
            status.update(state="Running", batch_execution_id="op-1",
                batch_input_digest=harness.payload_digest(op["original"]["input"]))
        public_held[harness.operation_key(op)] = status
    snapshots = [{"keeper": "owner-a", "snapshot": snapshot}]
    harness.validate_original_payloads(originals, snapshots, public_held, terminal=False)
    cases.append({"case": "held original payloads with merged leader and independent member digests", "result": "accepted"})
    wrong_projection = copy.deepcopy(public_held)
    wrong_projection[harness.operation_key(originals[1])]["state"] = "Queued"
    reject("batch follower public state must project its Running leader", lambda: harness.validate_original_payloads(
        originals, snapshots, wrong_projection, terminal=False))
    for label, change in [
        ("source route drift", lambda data: data[0]["snapshot"]["operations"]["rows"][0].update(source_json='{}')),
        ("admission digest drift", lambda data: data[0]["snapshot"]["operations"]["rows"][0].update(admission_digest="0" * 64)),
        ("leader digest incorrectly replaced by original digest", lambda data: data[0]["snapshot"]["operations"]["rows"][0].update(
            execution_digest=harness.payload_digest(originals[0]["original"]["input"]))),
        ("member original input drift", lambda data: data[0]["snapshot"]["operation_batch_members"]["rows"][1].update(admitted_input_json='{}')),
        ("member position drift", lambda data: data[0]["snapshot"]["operation_batch_members"]["rows"][1].update(position=0))]:
        damaged = copy.deepcopy(snapshots)
        change(damaged)
        reject(label, lambda: harness.validate_original_payloads(originals, damaged, public_held, terminal=False))
    terminal_snapshot, public_terminal = copy.deepcopy(snapshots), copy.deepcopy(public_held)
    for stored in terminal_snapshot[0]["snapshot"]["operations"]["rows"]:
        stored.update(state="succeeded", input_json=None)
    for member in terminal_snapshot[0]["snapshot"]["operation_batch_members"]["rows"]:
        member["admitted_input_json"] = None
    for status in public_terminal.values():
        status.update(state="Succeeded", input=None)
    harness.validate_original_payloads(originals, terminal_snapshot, public_terminal, terminal=True)
    cases.append({"case": "terminal cleared inputs preserve original admission and member digests", "result": "accepted"})
    reject("canonicalizer refuses non-ASCII extensions", lambda: harness.canonical_payload({"text": "한글"}))
    reject("canonicalizer refuses float encoding assumptions", lambda: harness.canonical_payload({"value": 1.0}))

    with tempfile.TemporaryDirectory(prefix="keeper-scale-evidence-fault-") as directory:
        base = Path(directory)
        source, backup = base / "source.sqlite3", base / "backup.sqlite3"
        connection = sqlite3.connect(source)
        try:
            connection.execute("CREATE TABLE operations (sequence INTEGER, operation_id TEXT, state TEXT, started_at REAL, completed_at REAL, outcome_ref TEXT, failure_kind TEXT, extra)")
            connection.execute("INSERT INTO operations VALUES (0,?,?,?,?,?,?,?)", (a["operation_id"], "succeeded", 1.0, 2.0, "owner-a#1", None, 1))
            connection.commit()
        finally:
            connection.close()
        selected, validation = harness.copy_operation_store(source, backup)
        assert selected == [row(a)] and validation["read_only_reopened"] and validation["exact_typed_rows_equal"]
        columns, source_rows = harness.read_operation_store(source)
        cases.append({"case": "closed writable backup reopened read-only and exact full typed rows checked",
                      "result": "accepted", "validation": validation})
        connection = sqlite3.connect(backup)
        try:
            connection.execute("UPDATE operations SET outcome_ref='other-outcome'")
            connection.commit()
        finally:
            connection.close()
        reject("structurally valid backup with mismatched row", lambda: harness.verify_operation_backup(columns, source_rows, backup))
        harness.copy_operation_store(source, backup)
        connection = sqlite3.connect(backup)
        try:
            connection.execute("UPDATE operations SET extra=1.0")
            connection.commit()
        finally:
            connection.close()
        _, changed_rows = harness.read_operation_store(backup)
        assert changed_rows == source_rows  # Ordinary Python equality cannot detect this type drift.
        assert type(changed_rows[0]["extra"]) is float and type(source_rows[0]["extra"]) is int
        reject("equal numeric value with different SQLite type in unselected column",
               lambda: harness.verify_operation_backup(columns, source_rows, backup))
        backup.write_bytes(b"not a SQLite database\n")
        reject("corrupt closed backup", lambda: harness.verify_operation_backup(columns, source_rows, backup))

        existing_out = base / "existing-packet"
        existing_out.mkdir()
        sentinel_summary = existing_out / "summary.json"
        sentinel_failure = existing_out / "failure.json"
        sentinel_summary.write_bytes(b'{"overall_original_run_verdict":"PASS"}\n')
        sentinel_failure.write_bytes(b'{"type":"OriginalError","message":"preserve-me"}\n')
        before_files = {p.name: p.read_bytes() for p in sorted(existing_out.iterdir())}
        def run_main_with_argv(output_path):
            with mock.patch.object(
                sys,
                "argv",
                [
                    "keeper_scale_session.py",
                    "--output",
                    str(output_path),
                    "--binary",
                    str(base / "missing-binary"),
                    "--repo",
                    str(base),
                ],
            ):
                harness.main()

        try:
            run_main_with_argv(existing_out)
        except FileExistsError as error:
            after_files = {p.name: p.read_bytes() for p in sorted(existing_out.iterdir())}
            assert after_files == before_files
            cases.append({"case": "existing --output directory rejected without writing failure.json or cleanup.json",
                          "result": "rejected", "error": type(error).__name__, "preserved_files": sorted(after_files)})
        else:
            raise AssertionError("existing --output directory was accepted")

        symlink_out = base / "symlink-packet"
        symlink_out.symlink_to(existing_out)
        reject("symlink --output rejected without touching target packet",
               lambda: run_main_with_argv(symlink_out))
        assert {p.name: p.read_bytes() for p in sorted(existing_out.iterdir())} == before_files

        owned_out = base / "owned-failed-packet"
        try:
            run_main_with_argv(owned_out)
        except FileNotFoundError:
            assert (owned_out / "failure.json").is_file() and (owned_out / "cleanup.json").is_file()
            cases.append({"case": "owned --output directory receives fallback failure.json and cleanup.json on post-mkdir failure",
                          "result": "accepted"})
        else:
            raise AssertionError("missing --binary was accepted")

        failed_out = base / "owned-database-failure"
        evidence = {"chat-operations.sqlite3": b"damaged database", "chat-operations.sqlite3-wal": b"wal bytes",
                    "runtime.log": b"original runtime evidence"}

        def damaged_store_run(args, owner):
            args.output.mkdir()
            owner["output"] = args.output
            owned_base = args.output / "owned-base"
            owned_base.mkdir()
            owner["base"] = owned_base
            for name, content in evidence.items():
                (owned_base / name).write_bytes(content)
            raise sqlite3.DatabaseError("injected integrity/copy failure")

        with mock.patch.object(harness, "run", damaged_store_run):
            try:
                run_main_with_argv(failed_out)
            except sqlite3.DatabaseError:
                assert {p.name: p.read_bytes() for p in (failed_out / "owned-base").iterdir()} == evidence
                assert json.loads((failed_out / "cleanup.json").read_text())["base_retained"] is True
                assert json.loads((failed_out / "failure.json").read_text())["type"] == "DatabaseError"
                cases.append({"case": "fallback on database failure preserves original DB/WAL/log bytes", "result": "preserved"})
            else:
                raise AssertionError("database failure was swallowed")

    report = {"schema": harness.EVIDENCE_SCHEMA, "harness_sha256": harness.digest(Path(harness.__file__)),
              "fault_probe_sha256": harness.digest(Path(__file__)), "masc_processes_started": 0, "cases": cases, "passed": True}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    harness.write_json(args.output, report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
