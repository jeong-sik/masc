"""Real stdio tests of output composition using explicit producer fixtures.

No Docker image, live host, game, or Keeper is exercised by these tests.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


ADDONS = Path(__file__).resolve().parents[1]
PACKAGE = ADDONS / "output-statistics"


def reference(name):
    return {"uri": f"artifact://fixture/{name}", "sha256": hashlib.sha256(name.encode()).hexdigest()}


def coverage(source="upstream-source", incarnation="source-incarnation", complete=True):
    return {"source_id": source, "incarnation": incarnation,
            "cursor": "source-cursor", "complete": complete, "detail": None}


def upstream_row(index, kind):
    return {"id": f"producer-instance/7/row-{index}", "lane_id": f"producer-instance/lane-{index}",
            "kind": kind, "title": "Producer row", "observed_at": 995 + index,
            "subject_id": f"subject-{index}", "actor": "actual-producer/executor" if index == 0 else None,
            "clock": None if index == 2 else {"domain": f"original-domain-{index}", "value": f"{index}:7"},
            "fields": {"original_payload": index}, "evidence": [reference(f"row-{index}")],
            "related_ids": []}


def observation():
    return {"id": "producer-instance/output/7", "kind": "lane_output", "observed_at": 1000,
            "actor": None, "evidence": [reference("retained-output")],
            "producer": {"installation_id": "producer-installation", "instance_id": "producer-instance",
                         "run_id": "same-world-run", "configuration_revision": "configuration-4",
                         "package_revision": "package-2", "observation_seq": 7},
            "output": {"rows": [upstream_row(index, kind) for index, kind in enumerate(("event", "value", "relation"))],
                       "coverage": [coverage()]},
            "producer_status": coverage("producer-instance", "producer-instance")}


def source(item=None):
    item = observation() if item is None else item
    return {"source_id": "producer-output-source", "incarnation": item["producer"]["instance_id"],
            "cursor": str(item["producer"]["observation_seq"]), "complete": True,
            "detail": None, "observations": [item]}


class OutputStatistics(unittest.TestCase):
    def exchange(self, calls):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "clientInfo": {"name": "output-fixture", "version": "1"},
                "capabilities": {}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ]
        for ident, sources in enumerate(calls, start=3):
            requests.append({"jsonrpc": "2.0", "id": ident, "method": "tools/call", "params": {
                "name": "lane_observe", "arguments": {"binding": {}, "sources": sources}}})
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(PACKAGE / "server.py")], cwd=directory,
                                    input="".join(json.dumps(item) + "\n" for item in requests),
                                    capture_output=True, text=True, check=True, timeout=10)
        self.assertEqual(result.stderr, "")
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([item["id"] for item in responses], list(range(1, len(calls) + 3)))
        return responses[0]["result"], responses[1]["result"], [item["result"] for item in responses[2:]]

    def outputs(self, calls):
        _, _, results = self.exchange(calls)
        outputs = []
        for result in results:
            self.assertFalse(result["isError"], result)
            output = result["structuredContent"]
            self.assertEqual(output, json.loads(result["content"][0]["text"]))
            outputs.append(output)
        return outputs

    def test_package_negotiates_common_read_only_protocol(self):
        initialized, listed, results = self.exchange([[source()]])
        self.assertEqual(initialized["protocolVersion"], "2025-06-18")
        self.assertEqual(initialized["serverInfo"]["name"], "masc-output-statistics")
        self.assertEqual(len(listed["tools"]), 1)
        tool = listed["tools"][0]
        self.assertEqual(tool["name"], "lane_observe")
        self.assertTrue(tool["annotations"]["readOnlyHint"])
        self.assertFalse(tool["annotations"]["destructiveHint"])
        self.assertEqual(set(tool["outputSchema"]["properties"]), {"rows", "coverage"})
        self.assertFalse(results[0]["isError"])
        manifest = tomllib.loads((PACKAGE / "lane.toml").read_text())
        self.assertEqual(manifest["id"], "output-statistics")
        self.assertEqual(manifest["contributions"], ["derive"])
        self.assertEqual(manifest["image"], "masc-lane-output-statistics:0.1.0")

    def test_count_preserves_producer_clocks_and_original_evidence(self):
        original = observation()
        result = self.outputs([[source(original)]])[0]
        self.assertEqual(len(result["rows"]), 1)
        metric = result["rows"][0]
        fields = metric["fields"]
        self.assertEqual(fields["scope"], "supplied_latest_completed_output")
        self.assertEqual(fields["observed_row_count"], 3)
        self.assertEqual(fields["observed_by_kind"], {"event": 1, "value": 1, "relation": 1})
        self.assertTrue(fields["input_complete"])
        self.assertEqual(fields["producer"], original["producer"])
        self.assertEqual(fields["producer_status"], original["producer_status"])
        self.assertEqual(fields["upstream_coverage"], original["output"]["coverage"])
        self.assertEqual(metric["evidence"], original["evidence"])
        self.assertIsNone(metric["clock"])
        self.assertIsNone(metric["actor"])
        self.assertEqual(metric["related_ids"], [])
        for supplied, retained in zip(original["output"]["rows"], fields["upstream_rows"]):
            for key in ("id", "lane_id", "kind", "subject_id", "observed_at", "clock", "actor", "evidence"):
                self.assertEqual(retained[key], supplied[key])
        self.assertEqual(metric["observed_at"], original["observed_at"])

    def test_multiple_producers_keep_separate_snapshot_counts(self):
        first, second = source(), source()
        second["source_id"] = "other-output-source"
        second["incarnation"] = "other-instance"
        producer = second["observations"][0]
        producer["id"] = "other-instance/output/9"
        producer["producer"].update({"installation_id": "other-installation", "instance_id": "other-instance", "observation_seq": 9})
        producer["output"]["rows"] = producer["output"]["rows"][:1]
        producer["producer_status"] = coverage("other-instance", "other-instance")
        result = self.outputs([[first, second]])[0]
        metrics = {item["fields"]["producer"]["installation_id"]: item for item in result["rows"]}
        self.assertEqual(set(metrics), {"producer-installation", "other-installation"})
        self.assertEqual(metrics["producer-installation"]["fields"]["observed_row_count"], 3)
        self.assertEqual(metrics["other-installation"]["fields"]["observed_row_count"], 1)
        self.assertNotEqual(metrics["producer-installation"]["lane_id"], metrics["other-installation"]["lane_id"])

    def test_repeated_cursor_does_not_accumulate_even_in_one_process(self):
        first = source()
        reread = copy.deepcopy(first)
        reread["observations"][0]["observed_at"] = 1010
        next_output = copy.deepcopy(first)
        next_output["cursor"] = "8"
        changed = next_output["observations"][0]
        changed["id"] = "producer-instance/output/8"
        changed["producer"]["observation_seq"] = 8
        changed["output"]["rows"] = changed["output"]["rows"][:1]
        results = self.outputs([[first], [first], [reread], [next_output]])
        self.assertEqual(results[0], results[1])
        metrics = [result["rows"][0] for result in results]
        self.assertEqual([metric["fields"]["observed_row_count"] for metric in metrics], [3, 3, 3, 1])
        self.assertEqual(metrics[0]["id"], metrics[2]["id"])
        self.assertEqual(metrics[2]["observed_at"], 1010)
        self.assertNotEqual(metrics[0]["id"], metrics[3]["id"])
        self.assertEqual(metrics[3]["fields"]["producer"]["observation_seq"], 8)

    def test_incomplete_input_retains_known_counts_and_original_status(self):
        for layer in ("source", "producer", "upstream"):
            with self.subTest(layer=layer):
                envelope = source()
                original = envelope["observations"][0]
                target = (envelope if layer == "source" else original["producer_status"] if layer == "producer"
                          else original["output"]["coverage"][0])
                target.update({"complete": False, "detail": "source is catching up"})
                result = self.outputs([[envelope]])[0]
                fields = result["rows"][0]["fields"]
                self.assertEqual(fields["observed_row_count"], 3)
                self.assertEqual(fields["observed_by_kind"], {"event": 1, "value": 1, "relation": 1})
                self.assertFalse(fields["input_complete"])
                self.assertFalse(result["coverage"][0]["complete"])
                self.assertEqual(fields["producer_status"], original["producer_status"])
                self.assertEqual(fields["upstream_coverage"], original["output"]["coverage"])
                self.assertEqual(result["coverage"][0]["cursor"], envelope["cursor"])

    def test_explicit_empty_output_differs_from_missing_output(self):
        empty = source()
        empty["observations"][0]["output"]["rows"] = []
        missing = source()
        missing.update({"observations": [], "complete": False, "detail": "upstream unavailable"})
        supplied, unavailable, absent_sources = self.outputs([[empty], [missing], []])
        self.assertEqual(supplied["rows"][0]["fields"]["observed_row_count"], 0)
        self.assertEqual(supplied["rows"][0]["fields"]["observed_by_kind"], {"event": 0, "value": 0, "relation": 0})
        self.assertTrue(supplied["rows"][0]["fields"]["input_complete"])
        for result in (unavailable, absent_sources):
            self.assertEqual(result["rows"], [])
            self.assertTrue(result["coverage"])
            self.assertTrue(all(not item["complete"] for item in result["coverage"]))
        self.assertIn("upstream unavailable", unavailable["coverage"][0]["detail"])

    def test_unrecognized_kind_never_becomes_a_zero_or_world_event_count(self):
        unknown = source()
        unknown["observations"] = [{"kind": "unrecognized-domain-event"}]
        mixed = source()
        mixed["observations"].append({"kind": "unrecognized-domain-event"})
        ignored, retained = self.outputs([[unknown], [mixed]])
        self.assertEqual(ignored["rows"], [])
        self.assertFalse(ignored["coverage"][0]["complete"])
        self.assertIn("unrecognized-domain-event", ignored["coverage"][0]["detail"])
        self.assertEqual(retained["rows"][0]["fields"]["observed_row_count"], 3)
        self.assertFalse(retained["rows"][0]["fields"]["input_complete"])

    def test_known_output_with_missing_coordinates_or_malformed_rows_is_rejected(self):
        for fault in ("missing_instance", "boolean_sequence", "unknown_row_kind", "missing_clock", "missing_status"):
            with self.subTest(fault=fault):
                envelope = source()
                item = envelope["observations"][0]
                if fault == "missing_instance":
                    del item["producer"]["instance_id"]
                elif fault == "boolean_sequence":
                    item["producer"]["observation_seq"] = True
                elif fault == "unknown_row_kind":
                    item["output"]["rows"][0]["kind"] = "assumed-event"
                elif fault == "missing_clock":
                    del item["output"]["rows"][0]["clock"]
                else:
                    del item["producer_status"]
                _, _, results = self.exchange([[envelope]])
                self.assertTrue(results[0]["isError"])
                self.assertNotIn("structuredContent", results[0])


if __name__ == "__main__":
    unittest.main()
