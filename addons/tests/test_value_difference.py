"""Real stdio metric/statistics workers with controlled host output envelopes."""
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
BINDING = {"field": "counter", "unit": "count"}


def reference(name):
    return {"uri": "artifact://fixture/" + name,
            "sha256": hashlib.sha256(name.encode()).hexdigest()}


def coverage(source, incarnation, cursor, complete=True):
    return {"source_id": source, "incarnation": incarnation, "cursor": cursor,
            "complete": complete, "detail": None}


def supplied(sequence, value, *, instance="dos-worker", source="guest"):
    producer = {"installation_id": "dos-demo", "instance_id": instance, "run_id": "world",
                "configuration_revision": "configuration-1", "package_revision": "package-1",
                "observation_seq": sequence, "output_id": "guest",
                "output_selection": {"lanes": ["dos/guest"]}, "coverage_scope": "whole_producer"}
    value_row = {"id": f"{instance}/{sequence}/value", "lane_id": f"{instance}/dos/guest",
                 "kind": "value", "subject_id": "guest-A", "title": "Guest counter",
                 "observed_at": 1000 + sequence, "actor": "recorded-controller",
                 "clock": {"domain": "dos/guest-A/capture", "value": str(sequence)},
                 "fields": {"counter": value}, "evidence": [reference(f"guest-{instance}-{sequence}")],
                 "related_ids": []}
    observation = {"id": f"{instance}/output/{sequence}", "kind": "lane_output",
                   "observed_at": 2000 + sequence, "actor": None,
                   "evidence": [reference(f"output-{instance}-{sequence}")], "producer": producer,
                   "producer_status": coverage(instance, instance, str(sequence)),
                   "output": {"rows": [value_row], "coverage": [coverage("guest-state", "guest-A", str(sequence))]}}
    return {**coverage(source, instance, str(sequence)), "observations": [observation]}


def exchange(package, calls, bindings=None):
    requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]
    for index, sources in enumerate(calls):
        requests.append({"jsonrpc": "2.0", "id": index + 3, "method": "tools/call", "params": {
            "name": "lane_observe", "arguments": {"binding": BINDING if bindings is None else bindings[index],
                                                   "sources": sources}}})
    with tempfile.TemporaryDirectory() as directory:
        process = subprocess.run([sys.executable, str(ADDONS / package / "server.py")], cwd=directory,
                                 input="".join(json.dumps(item) + "\n" for item in requests),
                                 capture_output=True, text=True, check=True, timeout=10)
    if process.stderr:
        raise AssertionError(process.stderr)
    replies = [json.loads(line) for line in process.stdout.splitlines()]
    if [reply["id"] for reply in replies] != list(range(1, len(calls) + 3)):
        raise AssertionError("Incorrect stdio response sequence")
    return [reply["result"] for reply in replies]


class ValueDifference(unittest.TestCase):
    def outputs(self, calls, bindings=None):
        outputs = []
        for result in exchange("value-difference", calls, bindings)[2:]:
            self.assertFalse(result["isError"], result)
            self.assertEqual(result["structuredContent"], json.loads(result["content"][0]["text"]))
            outputs.append(result["structuredContent"])
        return outputs

    def fields(self, calls, bindings=None):
        return [output["rows"][0]["fields"] for output in self.outputs(calls, bindings)]

    def test_toml_named_port_and_common_protocol(self):
        initialized, tools = exchange("value-difference", [])
        self.assertEqual(initialized["serverInfo"]["name"], "masc-value-difference")
        tool, = tools["tools"]
        self.assertEqual(tool["name"], "lane_observe")
        self.assertTrue(tool["annotations"]["readOnlyHint"])
        manifest = tomllib.loads((ADDONS / "value-difference/lane.toml").read_text())
        self.assertEqual(manifest["contributions"], ["derive"])
        self.assertEqual(manifest["world"]["outputs"], {"difference": {"all_lanes": True}})
        self.assertEqual(manifest["world"]["skills"]["directory"], "skills")
        examples = ADDONS.parent / "docs/examples/lane-addons"
        metric = tomllib.loads((examples / "dos-value-difference.toml").read_text())
        stats = tomllib.loads((examples / "dos-value-statistics.toml").read_text())
        dos = tomllib.loads((ADDONS / "dos-world/install.toml").read_text())
        self.assertEqual({metric["run_id"], stats["run_id"], dos["run_id"]}, {"dos-demo"})
        self.assertEqual(metric["binding"]["sources"][0]["installation_id"], dos["id"])
        self.assertEqual(metric["binding"]["sources"][0]["output_id"], "guest")
        self.assertEqual(stats["binding"]["sources"][0]["installation_id"], metric["id"])
        self.assertEqual(stats["binding"]["sources"][0]["output_id"], "difference")
        for declaration in (metric, stats):
            self.assertTrue((examples / declaration["manifest_path"]).resolve().is_file())

    def test_signed_change_retains_both_original_rows_and_sampled_direction(self):
        samples = [supplied(1, 5), supplied(4, 9), supplied(5, 2), supplied(6, 2)]
        outputs = self.outputs([[sample] for sample in samples])
        fields = [output["rows"][0]["fields"] for output in outputs]
        self.assertEqual([f["value"] for f in fields], [None, 4, -7, 0])
        self.assertEqual([f["direction"] for f in fields], [None, "up", "down", "unchanged"])
        self.assertEqual(fields[0]["state"], "baseline")
        self.assertTrue(fields[0]["input_complete"])
        row = outputs[1]["rows"][0]
        self.assertIsNone(row["actor"])
        self.assertEqual(row["related_ids"], [])
        self.assertEqual(row["clock"], samples[1]["observations"][0]["output"]["rows"][0]["clock"])
        self.assertEqual(fields[1]["unit"], "count")
        self.assertEqual(fields[1]["scope"], "between_supplied_values")
        for name, source in zip(("previous", "current"), samples):
            original = source["observations"][0]
            ref = fields[1][name]
            self.assertEqual(ref["row"], original["output"]["rows"][0])
            self.assertEqual(ref["producer"], original["producer"])
            self.assertEqual(ref["producer_status"], original["producer_status"])
            self.assertEqual(ref["upstream_coverage"], original["output"]["coverage"])
            self.assertEqual(ref["source"]["cursor"], source["cursor"])
            self.assertEqual(ref["row"]["actor"], "recorded-controller")
            for evidence in [*original["evidence"], *ref["row"]["evidence"]]:
                self.assertIn(evidence, row["evidence"])

    def test_repeated_cursor_keeps_interval_but_new_same_value_measures_zero(self):
        sample = supplied(2, 7)
        reread = copy.deepcopy(sample)
        reread["observations"][0]["observed_at"] = 9000
        outputs = self.outputs([[supplied(1, 2)], [sample], [sample], [reread], [supplied(3, 7)]])
        self.assertEqual(outputs[1], outputs[2])
        self.assertEqual(outputs[1], outputs[3])
        self.assertEqual(outputs[-1]["rows"][0]["fields"]["value"], 0)

    def test_producer_subject_lane_clock_and_metric_changes_start_new_pairs(self):
        for changed in ("installation_id", "run_id", "configuration_revision", "package_revision",
                        "output_id", "output_selection", "instance_id", "subject_id", "lane_id", "clock", "source_epoch"):
            with self.subTest(changed=changed):
                sample = supplied(2, 7, instance="replacement" if changed == "instance_id" else "dos-worker")
                observation = sample["observations"][0]
                if changed == "output_selection":
                    observation["producer"][changed] = {"all_lanes": True}
                elif changed in observation["producer"] and changed != "instance_id":
                    observation["producer"][changed] = "replacement"
                elif changed in ("subject_id", "lane_id", "clock"):
                    value_row = observation["output"]["rows"][0]
                    value_row[changed] = {"subject_id": "guest-B", "lane_id": "dos-worker/other/value", "clock": None}[changed]
                elif changed == "source_epoch":
                    observation["output"]["coverage"][0]["incarnation"] = "guest-B"
                fields = self.fields([[supplied(1, 2)], [sample]])
                self.assertEqual(fields[-1]["state"], "baseline")
                self.assertEqual(fields[-1]["reason"], "identity_changed")
                self.assertIsNone(fields[-1]["value"])
                self.assertIsNone(fields[-1]["previous"])
        sample = supplied(1, 3)
        sample["observations"][0]["output"]["rows"][0]["fields"]["temperature"] = 21.5
        fields = self.fields([[sample], [sample], [sample]],
                             [BINDING, {"field": "temperature", "unit": "C"}, {"field": "temperature", "unit": "F"}])
        self.assertEqual([f["state"] for f in fields], ["baseline"] * 3)
        self.assertTrue(all(f["previous"] is None for f in fields))

    def test_missing_sources_reset_while_coherent_incomplete_input_keeps_known_endpoint(self):
        missing = {**coverage("guest", "unobserved", None, False), "observations": []}
        for layer in ("missing", "deleted", "source", "producer_status", "upstream"):
            with self.subTest(layer=layer):
                sample = supplied(2, 4)
                if layer == "source": sample["complete"] = False
                elif layer == "producer_status": sample["observations"][0]["producer_status"]["complete"] = False
                elif layer == "upstream": sample["observations"][0]["output"]["coverage"][0]["complete"] = False
                gap = [] if layer == "deleted" else [missing] if layer == "missing" else [sample]
                outputs = self.outputs([[supplied(1, 2)], gap, [supplied(3, 7)], [supplied(4, 8)]])
                self.assertFalse(outputs[1]["coverage"][0]["complete"])
                expected = None if layer in ("missing", "deleted") else 5
                self.assertEqual(outputs[2]["rows"][0]["fields"]["value"], expected)
                self.assertEqual(outputs[2]["rows"][0]["fields"]["intervening_input_gap"], expected is not None)
                self.assertEqual(outputs[3]["rows"][0]["fields"]["value"], 1)
        other = supplied(1, 10, instance="other-worker", source="other")
        next_other = supplied(2, 12, instance="other-worker", source="other")
        outputs = self.outputs([[supplied(1, 2), other], [missing, next_other]])
        self.assertEqual(outputs[-1]["rows"][0]["fields"]["value"], 2)
        self.assertFalse(outputs[-1]["coverage"][0]["complete"])
        self.assertTrue(outputs[-1]["coverage"][1]["complete"])

    def test_observing_and_later_incomplete_sample_do_not_replace_complete_endpoint(self):
        first = supplied(1, 0)
        observing = copy.deepcopy(first)
        observing["complete"] = False
        observing["detail"] = "producer executing"
        observing["observations"][0]["producer_status"].update(complete=False, detail="observation pending")
        pending = supplied(2, 9)
        pending["complete"] = False
        outputs = self.outputs([[first], [observing], [pending], [supplied(3, 1)]])
        for output in outputs[1:3]:
            self.assertEqual(output["rows"][0]["fields"]["state"], "unknown")
            self.assertIsNone(output["rows"][0]["fields"]["value"])
            self.assertFalse(output["coverage"][0]["complete"])
        measured = outputs[-1]["rows"][0]
        fields = measured["fields"]
        self.assertEqual(fields["value"], 1)
        self.assertEqual(fields["direction"], "up")
        self.assertEqual(fields["previous"]["row"]["fields"]["counter"], 0)
        self.assertEqual(fields["current"]["row"]["fields"]["counter"], 1)
        self.assertTrue(fields["input_complete"])
        self.assertTrue(fields["intervening_input_gap"])
        self.assertEqual(fields["last_input_gap"]["producer"]["observation_seq"], 2)
        self.assertFalse(fields["last_input_gap"]["source"]["complete"])
        for ref in pending["observations"][0]["output"]["rows"][0]["evidence"]:
            self.assertIn(ref, measured["evidence"])

    def test_same_endpoint_recovery_keeps_previous_interval_and_last_seen_prevents_regression(self):
        endpoint = supplied(2, 5)
        partial = copy.deepcopy(endpoint)
        partial["observations"][0]["producer_status"]["complete"] = False
        outputs = self.outputs([[supplied(1, 0)], [endpoint], [partial], [endpoint], [endpoint]])
        recovered = outputs[3]["rows"][0]["fields"]
        self.assertEqual(recovered["value"], 5)
        self.assertEqual(recovered["previous"]["producer"]["observation_seq"], 1)
        self.assertEqual(recovered["current"]["producer"]["observation_seq"], 2)
        self.assertFalse(recovered["intervening_input_gap"])
        self.assertEqual(outputs[1], outputs[3])
        self.assertEqual(outputs[3], outputs[4])
        pending = supplied(3, 9)
        pending["complete"] = False
        fields = self.fields([[supplied(1, 0)], [pending], [supplied(2, 1)], [supplied(4, 2)]])
        self.assertEqual(fields[2]["reason"], "producer_cursor_regressed")
        self.assertIsNone(fields[3]["value"])
        contradictory = copy.deepcopy(partial)
        contradictory["observations"][0]["output"]["rows"][0]["fields"]["counter"] = 8
        fields = self.fields([[endpoint], [contradictory], [supplied(3, 9)]])
        self.assertEqual(fields[1]["reason"], "same_cursor_changed")
        self.assertIsNone(fields[2]["value"])
        changed = copy.deepcopy(partial)
        changed["observations"][0]["output"]["rows"][0]["subject_id"] = "new-guest"
        changed["observations"][0]["producer"]["observation_seq"] = 3
        changed["observations"][0]["id"] = "dos-worker/output/3"
        changed["observations"][0]["output"]["rows"][0]["id"] = "dos-worker/3/value"
        changed["cursor"] = changed["observations"][0]["producer_status"]["cursor"] = "3"
        confirmed = copy.deepcopy(changed)
        confirmed["observations"][0]["producer_status"]["complete"] = True
        fields = self.fields([[endpoint], [changed], [confirmed]])
        self.assertIsNone(fields[1]["previous"])
        self.assertEqual(fields[-1]["state"], "baseline")
        self.assertIsNone(fields[-1]["value"])
        self.assertIsNone(fields[-1]["previous"])

    def test_same_endpoint_recovery_leaves_old_row_unchanged_and_gap_for_next_interval(self):
        endpoint = supplied(2, 5)
        partial = copy.deepcopy(endpoint)
        partial["complete"] = False
        partial["observations"][0]["observed_at"] = 9000
        outputs = self.outputs([[supplied(1, 0)], [endpoint], [partial], [endpoint],
                                [endpoint], [supplied(3, 8)]])
        self.assertEqual(outputs[1], outputs[3])
        self.assertEqual(outputs[1], outputs[4])
        old = outputs[1]["rows"][0]
        self.assertFalse(old["fields"]["intervening_input_gap"])
        result = outputs[-1]["rows"][0]
        fields = result["fields"]
        self.assertEqual(fields["value"], 3)
        self.assertEqual(fields["previous"]["producer"]["observation_seq"], 2)
        self.assertEqual(fields["current"]["producer"]["observation_seq"], 3)
        self.assertTrue(fields["intervening_input_gap"])
        self.assertEqual(fields["last_input_gap"]["acquired_at"], 9000)
        self.assertEqual(fields["last_input_gap"]["row"]["observed_at"], 1002)
        self.assertNotIn("acquired_at", fields["previous"])
        for reference in fields["last_input_gap"]["output_evidence"]:
            self.assertIn(reference, result["evidence"])

    def test_non_numeric_or_ambiguous_input_cannot_produce_a_difference(self):
        for bad in (True, "7", None, float("inf"), float("nan")):
            with self.subTest(bad=bad):
                outputs = self.outputs([[supplied(1, 2)], [supplied(2, bad)], [supplied(3, 7)]])
                self.assertEqual(outputs[1]["rows"], [])
                self.assertFalse(outputs[1]["coverage"][0]["complete"])
                self.assertIsNone(outputs[2]["rows"][0]["fields"]["value"])
        for fault in ("source_cursor", "source_incarnation", "producer_status", "event_id",
                      "row_id", "row_lane", "row_kind", "clock", "ambiguous", "duplicate_coverage", "empty"):
            with self.subTest(fault=fault):
                sample = supplied(2, 7)
                observation = sample["observations"][0]
                value_row = observation["output"]["rows"][0]
                if fault == "source_cursor": sample["cursor"] = "1"
                elif fault == "source_incarnation": sample["incarnation"] = "other"
                elif fault == "producer_status": observation["producer_status"]["incarnation"] = "other"
                elif fault == "event_id": observation["id"] = "other/output/2"
                elif fault == "row_id": value_row["id"] = "dos-worker/1/value"
                elif fault == "row_lane": value_row["lane_id"] = "other/value"
                elif fault == "row_kind": value_row["kind"] = "event"
                elif fault == "clock": value_row["clock"] = {"domain": "dos/capture"}
                elif fault == "ambiguous": observation["output"]["rows"].append(copy.deepcopy(value_row))
                elif fault == "duplicate_coverage": observation["output"]["coverage"] *= 2
                else: observation["output"]["rows"] = []
                outputs = self.outputs([[supplied(1, 2)], [sample], [supplied(3, 7)]])
                self.assertEqual(outputs[1]["rows"], [])
                self.assertFalse(outputs[1]["coverage"][0]["complete"])
                self.assertIsNone(outputs[2]["rows"][0]["fields"]["value"])

    def test_cursor_regression_and_changed_same_cursor_are_unknown(self):
        for sample in (supplied(1, 7), supplied(2, 8)):
            fields = self.fields([[supplied(1, 2)], [supplied(2, 7)], [sample], [supplied(3, 9)]])
            self.assertEqual(fields[2]["state"], "unknown")
            self.assertIsNone(fields[2]["value"])
            self.assertIsNone(fields[3]["value"])
        sample = supplied(2, 7)
        sample["observations"][0]["output"]["rows"][0]["subject_id"] = "changed-same-cursor"
        self.assertEqual(self.fields([[supplied(1, 2)], [supplied(2, 7)], [sample]])[-1]["reason"], "same_cursor_changed")

    def test_integer_precision_and_finite_operands_with_overflow(self):
        large = 2 ** 80
        fields = self.fields([[supplied(1, large)], [supplied(2, large + 1)]])
        self.assertEqual(fields[-1]["value"], 1)
        self.assertIsInstance(fields[-1]["value"], int)
        for first, second in ((-1e308, 1e308), (2 ** 1024, 0.5)):
            outputs = self.outputs([[supplied(1, first)], [supplied(2, second)], [supplied(3, 2)], [supplied(4, 3)]])
            fields = [out["rows"][0]["fields"] for out in outputs]
            self.assertEqual(fields[1]["reason"], "difference_not_finite")
            self.assertEqual(fields[1]["state"], "unknown")
            self.assertFalse(outputs[1]["coverage"][0]["complete"])
            self.assertIsNone(fields[2]["value"])
            self.assertEqual(fields[3]["value"], 1)

    def test_worker_restart_requires_another_complete_pair(self):
        self.assertEqual(self.fields([[supplied(1, 2)], [supplied(2, 7)]])[-1]["value"], 5)
        restarted = self.fields([[supplied(3, 9)], [supplied(4, 8)]])
        self.assertIsNone(restarted[0]["previous"])
        self.assertEqual(restarted[0]["baseline_storage"], "worker_memory")
        self.assertEqual(restarted[1]["value"], -1)

    def test_metric_output_feeds_the_existing_statistics_worker(self):
        metric, = self.outputs([[supplied(1, 0)], [supplied(2, 1)]])[-1]["rows"]
        source = supplied(4, 0, instance="metric-worker", source="changes")
        observation = source["observations"][0]
        observation["producer"].update(installation_id="dos-value-difference", output_id="difference",
                                       output_selection={"all_lanes": True})
        metric["id"] = "metric-worker/4/" + metric["id"]
        metric["lane_id"] = "metric-worker/" + metric["lane_id"]
        observation["output"]["rows"] = [metric]
        result = exchange("output-statistics", [[source]])[-1]
        self.assertFalse(result["isError"])
        statistics, = result["structuredContent"]["rows"]
        self.assertEqual(statistics["fields"]["observed_row_count"], 1)
        self.assertTrue(statistics["fields"]["input_complete"])
        self.assertEqual(statistics["fields"]["producer"], observation["producer"])
        self.assertEqual(statistics["fields"]["upstream_rows"][0]["id"], metric["id"])
        self.assertEqual(statistics["fields"]["upstream_rows"][0]["evidence"], metric["evidence"])


if __name__ == "__main__":
    unittest.main()
