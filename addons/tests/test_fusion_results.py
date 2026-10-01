"""Feature tests through the actual package MCP stdio, with host-shaped captures."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

from test_packages import ProtocolCase

ADDONS = Path(__file__).resolve().parents[1]
RUN = "fusion-request-1"


def detail(status="completed", evidence_state="recorded"):
    run = {"run_id": RUN, "keeper": "example", "preset": "default",
           "roster": {}, "topology": "refine", "started_at": 100.0,
           "finished_at": None if status == "running" else 110.0,
           "status": status, "stage": "accepted" if status == "running" else status,
           "progress": {} if status == "running" else None}
    if status == "completed":
        run.update(decision="bounded preview", summary="summary")
    if status == "failed":
        run.update(error="provider unavailable", failure_code="provider_error")
    post = {"id": "p-" + "a" * 32, "body": "Untrusted retained evidence text",
            "origin": {"source": "fusion", "fusion_run_id": RUN, "fusion_producer": "example"}}
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


def call(package, sources, sizes=None):
    requests = [{"jsonrpc": "2.0", "id": 0, "method": "initialize"},
                {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                 "params": {"name": "lane_observe",
                            "arguments": {"binding": {"sources": []}, "sources": sources}}}]
    responses = exchange(package, requests, sizes)
    results = [response["result"] for response in responses]
    assert results[1]["tools"][0]["name"] == "lane_observe"
    return results[-1]


def exchange(package, requests, sizes=None):
    # Requests are prepared as a batch. A file-backed stdin avoids duplex
    # pipe backpressure while retaining the actual worker and wire bytes.
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as wire:
        serialized = "".join(json.dumps(item) + "\n" for item in requests)
        wire.write(serialized)
        wire.seek(0)
        proc = subprocess.run([sys.executable, str(ADDONS / package / "server.py")],
                              stdin=wire, capture_output=True, text=True, check=True)
    assert not proc.stderr, proc.stderr
    lines = proc.stdout.splitlines(keepends=True)
    if sizes is not None:
        sizes.update(input_bytes=len(serialized.encode("utf-8")),
                     output_bytes=len(lines[-1].encode("utf-8")))
    return [json.loads(line) for line in lines]


class FusionResults(unittest.TestCase):
    def test_oversized_integer_timestamps_do_not_terminate_worker(self):
        requests = []
        for index, field in enumerate(("started_at", "finished_at"), 1):
            value = detail()
            value["run"][field] = 10 ** 400
            requests.append({"jsonrpc": "2.0", "id": index, "method": "tools/call",
                "params": {"name": "lane_observe", "arguments": {
                    "binding": {"sources": []}, "sources": [source(value)]}}})
        requests.append({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "lane_observe", "arguments": {
                "binding": {"sources": []}, "sources": [source(detail())]}}})
        responses = exchange("fusion-results", requests)
        self.assertEqual([item["id"] for item in responses], [1, 2, 3])
        self.assertTrue(responses[0]["result"]["isError"])
        self.assertTrue(responses[1]["result"]["isError"])
        self.assertFalse(responses[2]["result"]["isError"])
        self.assertEqual(len(responses[2]["result"]["structuredContent"]["rows"]), 2)

    def test_retained_result_composes_with_generic_downstream(self):
        result = call("fusion-results", [source(detail())])
        self.assertFalse(result["isError"])
        output = result["structuredContent"]
        self.assertEqual(output, ProtocolCase().call("fusion-results", {"sources": []}, [source(detail())],
            expected_summary="Fusion status and retained Board evidence are available in structuredContent with exact run identity."))
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
        statistics_result = call("output-statistics", [upstream])
        statistics = statistics_result["structuredContent"]
        self.assertEqual(statistics, json.loads(statistics_result["content"][0]["text"]))
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
                reply = call("fusion-results", [source(value)])
                self.assertIn("no retained Board evidence is available", reply["content"][0]["text"])
                result = reply["structuredContent"]
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
        empty = call("fusion-results", [])
        self.assertIn("No Fusion snapshot rows are available", empty["content"][0]["text"])
        self.assertFalse(empty["structuredContent"]["coverage"][0]["complete"])
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

    def test_run_stage_progress_matches_authoritative_status_contract(self):
        stages = ("accepted", "panel", "judge", "computed", "recording_evidence", "completed", "failed")
        for status in ("running", "completed", "failed"):
            for stage in stages:
                with self.subTest(status=status, stage=stage):
                    value = detail(status)
                    progress = ({} if stage == "accepted" else {"panel_expected": 3}
                                if stage == "panel" else {"panel_expected": 3, "panel_answered": 2, "panel_failed": 1}
                                if stage in ("judge", "computed", "recording_evidence") else None)
                    value["run"].update(stage=stage, progress=progress)
                    valid = ((status == "running" and stage in stages[:5]) or status == stage)
                    result = call("fusion-results", [source(value)])
                    self.assertEqual(result["isError"], not valid)
                    if valid:
                        output = result["structuredContent"]
                        self.assertEqual(output["rows"][0]["fields"]["fusion_run"], value["run"])
                        self.assertEqual(output["coverage"][0]["complete"], status != "running")
                    else:
                        self.assertNotIn("structuredContent", result)
        bad = []
        for stage in stages[:5]:
            value = detail("running")
            value["run"].update(stage=stage, progress=None)
            bad.append(value)
        for stage in ("panel", "judge", "computed", "recording_evidence"):
            for count in (True, -1, 1.5, "3"):
                value = detail("running")
                value["run"].update(stage=stage, progress={"panel_expected": count, "panel_answered": 2, "panel_failed": 1})
                bad.append(value)
        for stage in ("judge", "computed", "recording_evidence"):
            for progress in ({"panel_expected": 3},
                             {"panel_expected": 3, "panel_answered": 2, "panel_failed": 0},
                             {"panel_expected": 3, "panel_answered": True, "panel_failed": 2},
                             {"panel_expected": 3, "panel_answered": 4, "panel_failed": -1}):
                value = detail("running")
                value["run"].update(stage=stage, progress=progress)
                bad.append(value)
        for key in ("stage", "progress"):
            value = detail("running")
            del value["run"][key]
            bad.append(value)
        for value in bad:
            with self.subTest(run=value["run"]):
                result = call("fusion-results", [source(value)])
                self.assertTrue(result["isError"])
                self.assertNotIn("structuredContent", result)

    def test_failure_fields_and_exact_producer_are_required_in_their_own_state(self):
        bad = []
        for status in ("running", "completed"):
            for key in ("error", "failure_code"):
                value = detail(status)
                value["run"][key] = "contradictory failure"
                bad.append(value)
        for producer in (None, "", " ", "another-producer", 7):
            value = detail()
            value["evidence"]["post"]["origin"]["fusion_producer"] = producer
            bad.append(value)
        value = detail()
        del value["evidence"]["post"]["origin"]["fusion_producer"]
        bad.append(value)
        for value in bad:
            result = call("fusion-results", [source(value)])
            self.assertTrue(result["isError"])
            self.assertNotIn("structuredContent", result)

    def test_recorded_post_requires_body_without_changing_legal_body_bytes(self):
        for body in (None, 3, [], {}):
            value = detail()
            value["evidence"]["post"]["body"] = body
            self.assertTrue(call("fusion-results", [source(value)])["isError"])
        value = detail()
        del value["evidence"]["post"]["body"]
        self.assertTrue(call("fusion-results", [source(value)])["isError"])
        for body in ("", "\n\t한글 retained body\n"):
            value = detail()
            value["evidence"]["post"]["body"] = body
            output = call("fusion-results", [source(value)])["structuredContent"]
            self.assertEqual(output["rows"][1]["fields"]["board_post"]["body"], body)
            self.assertTrue(output["coverage"][0]["complete"])

    def test_large_post_keeps_exact_body_once_inside_declared_mcp_envelope(self):
        limit = tomllib.loads((ADDONS / "fusion-results" / "lane.toml").read_text())["resources"]["max_reply_bytes"]
        value = detail()
        body = "x" * 2_200_000 + "한글 exact tail"
        value["evidence"]["post"]["body"] = body
        sizes = {}
        result = call("fusion-results", [source(value)], sizes)
        self.assertFalse(result["isError"])
        self.assertLessEqual(sizes["input_bytes"], limit)
        self.assertLessEqual(sizes["output_bytes"], limit)
        self.assertEqual(result["structuredContent"]["rows"][1]["fields"]["board_post"]["body"], body)
        self.assertTrue(result["structuredContent"]["coverage"][0]["complete"])
        self.assertIn("structuredContent", result["content"][0]["text"])
        self.assertNotIn("exact tail", result["content"][0]["text"])
        # Fill the accepted request envelope with exact source data. Row metadata
        # makes its response larger; return an explicit bounded error, never trim.
        small = detail()
        baseline_sizes = {}
        call("fusion-results", [source(small)], baseline_sizes)
        old_body = small["evidence"]["post"]["body"]
        small["evidence"]["post"]["body"] = "x" * (limit - baseline_sizes["input_bytes"] + len(old_body))
        refused_sizes = {}
        refused = call("fusion-results", [source(small)], refused_sizes)
        self.assertLessEqual(refused_sizes["input_bytes"], limit)
        self.assertLessEqual(refused_sizes["output_bytes"], limit)
        self.assertTrue(refused["isError"])
        self.assertNotIn("structuredContent", refused)
        self.assertIn("declared reply envelope", refused["content"][0]["text"])

    def test_non_tool_replies_share_the_envelope_guard_and_rpc_error_shape(self):
        limit = tomllib.loads((ADDONS / "fusion-results" / "lane.toml").read_text())["resources"]["max_reply_bytes"]
        baseline = {}
        unknown = exchange("fusion-results", [{"jsonrpc": "2.0", "id": "", "method": "unknown"}], baseline)[0]
        self.assertEqual(unknown["error"]["code"], -32601)
        # The ordinary unknown-method reply would exceed by one byte. Its
        # shorter bounded JSON-RPC error must fit and preserve the exact id.
        request_id = "x" * (limit - baseline["output_bytes"] + 1)
        sizes = {}
        response = exchange("fusion-results", [{"jsonrpc": "2.0", "id": request_id, "method": "unknown"}], sizes)[0]
        self.assertLessEqual(sizes["input_bytes"], limit)
        self.assertLessEqual(sizes["output_bytes"], limit)
        self.assertEqual(response["id"], request_id)
        self.assertEqual(response["error"], {"code": -32603, "message": "Reply too large"})
        self.assertNotIn("result", response)
        # Initialization is another non-tool path: its normal server metadata
        # is larger than the bounded error for the same valid request id.
        sizes = {}
        response = exchange("fusion-results", [{"jsonrpc": "2.0", "id": request_id, "method": "initialize"}], sizes)[0]
        self.assertLessEqual(sizes["input_bytes"], limit)
        self.assertLessEqual(sizes["output_bytes"], limit)
        self.assertEqual(response["id"], request_id)
        self.assertEqual(response["error"]["code"], -32603)
        self.assertNotIn("result", response)

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

    def test_nested_nonfinite_input_is_refused_without_stopping_worker(self):
        for bad in (float("nan"), float("inf"), float("-inf")):
            for location in ("post", "roster"):
                with self.subTest(bad=bad, location=location):
                    value = detail()
                    if location == "post":
                        value["evidence"]["post"]["created_at"] = bad
                    else:
                        value["run"]["roster"] = {"panel": [bad]}
                    responses = exchange("fusion-results", [
                        {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
                            "name": "lane_observe", "arguments": {"binding": {}, "sources": [source(value)]}}},
                        {"jsonrpc": "2.0", "id": 2, "method": "ping"},
                    ])
                    self.assertTrue(responses[0]["result"]["isError"])
                    self.assertNotIn("structuredContent", responses[0]["result"])
                    self.assertEqual(responses[1], {"jsonrpc": "2.0", "id": 2, "result": {}})

    def test_export_is_private_and_never_replaces_an_existing_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            detail_path, output = root / "detail.json", root / "capture.json"
            detail_path.write_text(json.dumps(detail()))
            command = [sys.executable, str(ADDONS / "fusion-results/export_snapshot.py"),
                       str(detail_path), str(output), "--source-id", "fusion"]
            previous = os.umask(0o022)
            try:
                first = subprocess.run(command, capture_output=True, text=True)
            finally:
                os.umask(previous)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            original = output.read_bytes()
            refused = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(output.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
