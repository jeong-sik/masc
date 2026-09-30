"""Feature tests through the actual package MCP stdio, with host-shaped captures."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

ADDONS = Path(__file__).resolve().parents[1]
RUN = "fusion-request-1"


def detail(status="completed", evidence_state="recorded"):
    run = {"run_id": RUN, "keeper": "example", "preset": "default",
           "roster": {}, "topology": "refine", "started_at": 100.0,
           "finished_at": None if status == "running" else 110.0,
           "status": status, "stage": status, "progress": None}
    if status == "completed":
        run.update(decision="bounded preview", summary="summary")
    if status == "failed":
        run.update(error="provider unavailable", failure_code="provider_error")
    post = {"id": "p-" + "a" * 32, "body": "Untrusted retained evidence text",
            "origin": {"source": "fusion", "fusion_run_id": RUN}}
    return {"generated_at": "2026-09-30T00:00:00Z", "run": run,
            "evidence": {"status": evidence_state,
                         "post": post if evidence_state == "recorded" else None}}


def source(value, complete=True):
    snapshot = {"source_id": "fusion", "incarnation": RUN, "cursor": "capture",
                "complete": complete, "detail": None, "observations": [{
                    "id": "capture", "kind": "fusion_run", "observed_at": 120,
                    "actor": "exporter", "evidence": [], "detail": value}]}
    raw = json.dumps(snapshot).encode()
    digest = hashlib.sha256(raw).hexdigest()
    snapshot["observations"][0]["evidence"] = [
        {"uri": "lane-evidence:" + digest, "sha256": digest}]
    return snapshot


def call(package, sources):
    requests = [{"jsonrpc": "2.0", "id": 0, "method": "initialize"},
                {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                 "params": {"name": "lane_observe",
                            "arguments": {"binding": {"sources": []}, "sources": sources}}}]
    # Requests are prepared as a batch. A file-backed stdin avoids duplex
    # pipe backpressure while retaining the actual worker and wire bytes.
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as wire:
        wire.write("".join(json.dumps(item) + "\n" for item in requests))
        wire.seek(0)
        proc = subprocess.run([sys.executable, str(ADDONS / package / "server.py")],
                              stdin=wire, capture_output=True, text=True, check=True)
    assert not proc.stderr, proc.stderr
    results = [json.loads(line)["result"] for line in proc.stdout.splitlines()]
    assert results[1]["tools"][0]["name"] == "lane_observe"
    return results[-1]


class FusionResults(unittest.TestCase):
    def test_retained_result_composes_with_generic_downstream(self):
        result = call("fusion-results", [source(detail())])
        self.assertFalse(result["isError"])
        output = result["structuredContent"]
        status, evidence = output["rows"]
        self.assertEqual(evidence["related_ids"], [status["id"]])
        self.assertEqual(evidence["fields"]["decision_preview"], "bounded preview")
        self.assertTrue(output["coverage"][0]["complete"])
        self.assertIsNone(evidence["actor"])
        selected = copy.deepcopy(output)
        lanes = tomllib.loads((ADDONS / "fusion-results" / "lane.toml").read_text())["world"]["outputs"]["result"]["lanes"]
        selected["rows"] = [row for row in output["rows"] if row["lane_id"] in lanes]
        producer = {"installation_id": "fusion-results", "instance_id": "worker-1",
                    "run_id": "fusion-report", "configuration_revision": "config",
                    "package_revision": "0.1.0", "observation_seq": 1, "output_id": "result"}
        upstream = {"source_id": "result", "incarnation": "worker-1", "cursor": "1",
                    "complete": True, "detail": None, "observations": [{
                        "id": "worker-1/output/1", "kind": "lane_output", "observed_at": 130,
                        "actor": None, "evidence": evidence["evidence"], "producer": producer,
                        "producer_status": {"source_id": "worker-1", "incarnation": "worker-1",
                                            "cursor": "1", "complete": True, "detail": None},
                        "output": selected}]}
        statistics = call("output-statistics", [upstream])["structuredContent"]
        self.assertEqual(statistics["rows"][0]["fields"]["observed_row_count"], 2)
        self.assertEqual([row["id"] for row in statistics["rows"][0]["fields"]["upstream_rows"]],
                         [status["id"], evidence["id"]])

    def test_named_result_port_retains_failure_cause_and_relation(self):
        output = call("fusion-results", [source(detail("failed"))])["structuredContent"]
        lanes = tomllib.loads((ADDONS / "fusion-results" / "lane.toml").read_text())["world"]["outputs"]["result"]["lanes"]
        selected = [row for row in output["rows"] if row["lane_id"] in lanes]
        status, result = selected
        self.assertTrue(output["coverage"][0]["complete"])
        self.assertEqual(status["fields"]["fusion_run"]["failure_code"], "provider_error")
        self.assertEqual(status["fields"]["fusion_run"]["error"], "provider unavailable")
        self.assertEqual(result["related_ids"], [status["id"]])
        self.assertTrue(set(result["related_ids"]).issubset({row["id"] for row in selected}))

    def test_running_absent_and_partial_never_claim_complete_result(self):
        for value in (detail("running", "pending"), detail("completed", "absent"),
                      detail("failed", "absent")):
            with self.subTest(value=value):
                result = call("fusion-results", [source(value)])["structuredContent"]
                self.assertEqual(len(result["rows"]), 1)
                self.assertFalse(result["coverage"][0]["complete"])
        output = call("fusion-results", [source(detail(), complete=False)])["structuredContent"]
        self.assertFalse(output["coverage"][0]["complete"])
        failure = call("fusion-results", [source(detail("failed"))])["structuredContent"]
        self.assertEqual(failure["rows"][0]["fields"]["fusion_run"]["status"], "failed")
        self.assertTrue(failure["coverage"][0]["complete"])

    def test_wrong_origin_and_malformed_known_inputs_are_errors(self):
        bad = []
        value = detail()
        value["evidence"]["post"]["origin"]["fusion_run_id"] = "another-run"
        bad.append(value)
        value = detail()
        value["run"]["status"] = "unknown"
        bad.append(value)
        value = detail()
        value["run"]["topology"] = "unknown"
        bad.append(value)
        value = detail()
        value["run"]["finished_at"] = 99
        bad.append(value)
        value = detail()
        del value["run"]["summary"]
        bad.append(value)
        for value in bad:
            self.assertTrue(call("fusion-results", [source(value)])["isError"])
        missing = source(detail())
        missing["observations"][0]["evidence"] = []
        self.assertTrue(call("fusion-results", [missing])["isError"])

    def test_empty_and_mixed_sources_preserve_coverage_gaps(self):
        self.assertFalse(call("fusion-results", [])["structuredContent"]["coverage"][0]["complete"])
        mixed = source(detail())
        mixed["observations"].append({"kind": "unrelated"})
        output = call("fusion-results", [mixed])["structuredContent"]
        self.assertFalse(output["coverage"][0]["complete"])
        self.assertIn("unrelated", output["coverage"][0]["detail"])

    def test_source_incarnation_must_match_detail_run(self):
        snapshot = source(detail())
        snapshot["incarnation"] = "another-run"
        result = call("fusion-results", [snapshot])
        self.assertTrue(result["isError"])
        self.assertNotIn("structuredContent", result)
        self.assertIn("incarnation", result["content"][0]["text"])
        output = call("fusion-results", [source(detail())])["structuredContent"]
        for row in output["rows"]:
            self.assertEqual(row["subject_id"], RUN)
            self.assertEqual(row["fields"]["incarnation"], RUN)
        self.assertEqual(output["coverage"][0]["incarnation"], RUN)

    def test_evidence_lifecycle_matches_run_state(self):
        for run_state in ("running", "completed", "failed"):
            for evidence_state in ("recorded", "pending", "absent"):
                with self.subTest(run=run_state, evidence=evidence_state):
                    result = call("fusion-results", [source(detail(run_state, evidence_state))])
                    invalid = ((evidence_state == "pending" and run_state != "running")
                               or (evidence_state == "absent" and run_state == "running"))
                    self.assertEqual(result["isError"], invalid)
                    if invalid:
                        self.assertNotIn("structuredContent", result)
                    else:
                        output = result["structuredContent"]
                        self.assertEqual(len(output["rows"]), 2 if evidence_state == "recorded" else 1)
                        self.assertEqual(output["coverage"][0]["complete"],
                                         run_state != "running" and evidence_state == "recorded")

    def test_export_identity_changes_with_evidence_and_keeps_run(self):
        sys.path.insert(0, str(ADDONS / "fusion-results"))
        spec = importlib.util.spec_from_file_location("fusion_export", ADDONS / "fusion-results/export_snapshot.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        first = module.snapshot(detail(), "fusion")
        self.assertEqual(first, module.snapshot(detail(), "fusion"))
        changed = detail()
        changed["evidence"]["post"]["body"] = "new evidence"
        second = module.snapshot(changed, "fusion")
        self.assertNotEqual(first["cursor"], second["cursor"])
        self.assertEqual(first["incarnation"], second["incarnation"])


if __name__ == "__main__":
    unittest.main()
