"""Exercise the MSX observer -> frame metric through real stdio workers.

Capture and host lane_output envelopes are fixtures, not a running emulator.
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


def reference(name):
    return {"uri": f"artifact://fixture/{name}", "sha256": hashlib.sha256(name.encode()).hexdigest()}


def status(source, incarnation, cursor="0", complete=True):
    return {"source_id": source, "incarnation": incarnation,
            "cursor": cursor, "complete": complete, "detail": None}


def exchange(package, calls, binding):
    requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]
    for identity, sources in enumerate(calls, start=3):
        requests.append({"jsonrpc": "2.0", "id": identity, "method": "tools/call", "params": {
            "name": "lane_observe", "arguments": {"binding": binding, "sources": sources}}})
    with tempfile.TemporaryDirectory() as directory:
        result = subprocess.run([sys.executable, str(ADDONS / package / "server.py")], cwd=directory,
            input="".join(json.dumps(item) + "\n" for item in requests),
            capture_output=True, text=True, check=True, timeout=10)
    if result.stderr:
        raise AssertionError(result.stderr)
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    if [reply["id"] for reply in replies] != list(range(1, len(calls) + 3)):
        raise AssertionError("Wrong response sequence")
    return replies[0]["result"], replies[1]["result"], [reply["result"] for reply in replies[2:]]


def supplied(seq, frame, *, machine="workspace-msx", incarnation="machine-A",
             instance="observer-instance", installation="msx-frames", source_id="msx-captures"):
    capture = {"id": f"capture-{incarnation}-{seq}", "kind": "capture", "observed_at": 1000 + seq,
               "actor": None, "evidence": [reference(f"raw-capture-{incarnation}-{seq}")],
               "machine_id": machine, "incarnation": incarnation, "frame": frame,
               "screen": reference(f"screen-{incarnation}-{seq}"), "input_cursor": "0"}
    captured = {**status("existing-machine", incarnation), "observations": [capture]}
    _, _, responses = exchange("msx-observer", [[captured]], {"machine_id": machine})
    output = responses[0]["structuredContent"]
    # The host assigns installation/sequence row coordinates before lane_output.
    for item in output["rows"]:
        item["id"] = f"{instance}/{seq}/{item['id']}"
        item["lane_id"] = f"{instance}/{item['lane_id']}"
    producer = {"installation_id": installation, "instance_id": instance, "run_id": "test-world",
                "configuration_revision": "configuration-A", "package_revision": "observer-A",
                "observation_seq": seq}
    observation = {"id": f"{instance}/output/{seq}", "kind": "lane_output", "observed_at": 2000 + seq,
                   "actor": None, "evidence": [reference(f"output-{instance}-{seq}")],
                   "producer": producer, "producer_status": status(instance, instance, str(seq)), "output": output}
    return {**status(source_id, instance, str(seq)), "observations": [observation]}


class FrameProgress(unittest.TestCase):
    def outputs(self, calls):
        _, _, results = exchange("frame-progress", calls, {"machine_id": "workspace-msx"})
        outputs = []
        for result in results:
            self.assertFalse(result["isError"], result)
            output = result["structuredContent"]
            self.assertEqual(output, json.loads(result["content"][0]["text"]))
            outputs.append(output)
        return outputs

    def fields(self, calls):
        return [output["rows"][0]["fields"] for output in self.outputs(calls)]

    def test_common_protocol_and_toml_select_existing_observer(self):
        initialized, listed, _ = exchange("frame-progress", [], {"machine_id": "workspace-msx"})
        self.assertEqual(initialized["serverInfo"]["name"], "masc-frame-progress")
        tool, = listed["tools"]
        self.assertEqual(tool["name"], "lane_observe")
        self.assertTrue(tool["annotations"]["readOnlyHint"])
        self.assertEqual(set(tool["outputSchema"]["properties"]), {"rows", "coverage"})
        manifest = tomllib.loads((ADDONS / "frame-progress/lane.toml").read_text())
        self.assertEqual(manifest["contributions"], ["derive"])
        examples = ADDONS.parent / "docs/examples/lane-addons"
        declaration = tomllib.loads((examples / "frame-progress.toml").read_text())
        producer = tomllib.loads((examples / "msx-frames.toml").read_text())
        self.assertEqual(declaration["run_id"], producer["run_id"])
        source, = declaration["binding"]["sources"]
        self.assertEqual(source["kind"], "lane_output")
        self.assertEqual(source["installation_id"], producer["id"])
        self.assertEqual(source["selection"], "latest_completed")
        self.assertEqual((examples / declaration["manifest_path"]).resolve(),
                         ADDONS / "frame-progress/lane.toml")

    def test_actual_observer_output_yields_frame_difference_and_both_evidence(self):
        before, after = supplied(1, 10), supplied(4, 25)
        baseline, measured = self.outputs([[before], [after]])
        self.assertEqual(baseline["rows"][0]["fields"]["state"], "baseline")
        self.assertIsNone(baseline["rows"][0]["fields"]["value"])
        metric, = measured["rows"]
        self.assertEqual(metric["fields"]["value"], 15)
        self.assertEqual(metric["fields"]["state"], "measured")
        self.assertEqual(metric["fields"]["unit"], "frames")
        self.assertEqual(metric["clock"], {"domain": "msx/workspace-msx/machine-A/frame", "value": "25"})
        self.assertIsNone(metric["actor"])
        self.assertEqual(metric["related_ids"], [])
        for key, source in (("previous", before), ("current", after)):
            retained = metric["fields"][key]
            original, = source["observations"]
            self.assertEqual(retained["producer"], original["producer"])
            self.assertEqual(retained["source"]["cursor"], source["cursor"])
            self.assertEqual(retained["capture"], original["output"]["rows"][0])
            self.assertEqual(retained["producer_status"], original["producer_status"])
            self.assertEqual(retained["upstream_coverage"], original["output"]["coverage"])
            self.assertEqual(retained["capture"]["fields"]["input_cursor"], "0")
            for evidence in [*original["evidence"], *retained["capture"]["evidence"]]:
                self.assertIn(evidence, metric["evidence"])

    def test_same_cursor_retains_interval_and_does_not_accumulate(self):
        before, after, still = supplied(1, 10), supplied(2, 25), supplied(3, 25)
        reread = copy.deepcopy(after)
        reread["observations"][0]["observed_at"] = 9000
        outputs = self.outputs([[before], [after], [after], [reread], [still]])
        self.assertEqual(outputs[1], outputs[2])
        self.assertEqual(outputs[1], outputs[3])
        self.assertEqual([out["rows"][0]["fields"]["value"] for out in outputs], [None, 15, 15, 15, 0])

    def test_restore_and_frame_regression_start_a_new_pair(self):
        fields = self.fields([[supplied(1, 100)], [supplied(2, 5, incarnation="restored")],
                              [supplied(3, 8, incarnation="restored")],
                              [supplied(4, 2, incarnation="restored")],
                              [supplied(5, 7, incarnation="restored")]])
        self.assertEqual([item["value"] for item in fields], [None, None, 3, None, 5])
        self.assertEqual(fields[1]["reason"], "machine_incarnation_changed")
        self.assertEqual(fields[3]["reason"], "frame_regressed")
        self.assertEqual(fields[1]["previous"]["capture"]["fields"]["frame"], 100)

    def test_each_producer_identity_change_resets_the_pair(self):
        for field in ("installation_id", "instance_id", "run_id", "configuration_revision", "package_revision"):
            with self.subTest(field=field):
                changed = supplied(2, 25)
                item = changed["observations"][0]
                item["producer"][field] = "replacement"
                if field == "instance_id":
                    changed["incarnation"] = "replacement"
                    item["id"] = "replacement/output/2"
                    item["producer_status"]["source_id"] = "replacement"
                    item["producer_status"]["incarnation"] = "replacement"
                    capture = item["output"]["rows"][0]
                    capture["id"] = capture["id"].replace("observer-instance/", "replacement/", 1)
                    capture["lane_id"] = "replacement/msx/frame"
                fields = self.fields([[supplied(1, 10)], [changed]])
                self.assertEqual(fields[1]["state"], "baseline")
                self.assertEqual(fields[1]["reason"], "producer_changed")
                self.assertIsNone(fields[1]["value"])

    def test_missing_deleted_and_incomplete_inputs_clear_baseline(self):
        missing = {**status("msx-captures", "unobserved", None, False), "observations": []}
        for gap in ([missing], [], [supplied(2, 15)]):
            if gap and gap[0]["observations"]:
                gap[0]["complete"] = False
            with self.subTest(gap=gap):
                outputs = self.outputs([[supplied(1, 10)], gap, [supplied(3, 25)], [supplied(4, 28)]])
                self.assertFalse(outputs[1]["coverage"][0]["complete"])
                self.assertIsNone(outputs[2]["rows"][0]["fields"]["value"])
                self.assertEqual(outputs[3]["rows"][0]["fields"]["value"], 3)
        for layer in ("producer_status", "upstream"):
            incomplete = supplied(2, 15)
            item = incomplete["observations"][0]
            target = item["producer_status"] if layer == "producer_status" else item["output"]["coverage"][0]
            target["complete"] = False
            outputs = self.outputs([[supplied(1, 10)], [incomplete], [supplied(3, 25)]])
            self.assertEqual(outputs[1]["rows"][0]["fields"]["state"], "unknown")
            self.assertIsNone(outputs[2]["rows"][0]["fields"]["value"])

    def test_new_worker_cannot_claim_restart_continuous_difference(self):
        first = self.fields([[supplied(1, 10)], [supplied(2, 25)]])
        restarted = self.fields([[supplied(3, 40)], [supplied(4, 45)]])
        self.assertEqual(first[-1]["value"], 15)
        self.assertEqual(restarted[0]["state"], "baseline")
        self.assertIsNone(restarted[0]["previous"])
        self.assertEqual(restarted[0]["baseline_storage"], "worker_memory")
        self.assertEqual(restarted[1]["value"], 5)

    def test_invalid_coordinates_or_binding_never_become_progress(self):
        faults = ("string_frame", "boolean_frame", "clock", "subject", "machine", "matches_binding",
                  "source_cursor", "source_incarnation", "producer_status", "status_source", "status_cursor",
                  "capture_lane", "capture_id", "capture_seq", "capture_coverage", "capture_incarnation",
                  "ambiguous", "empty", "missing_screen")
        for fault in faults:
            with self.subTest(fault=fault):
                invalid = supplied(2, 25)
                capture = invalid["observations"][0]["output"]["rows"][0]
                if fault == "string_frame": capture["fields"]["frame"] = "25"
                elif fault == "boolean_frame": capture["fields"]["frame"] = True
                elif fault == "clock": capture["clock"]["value"] = "26"
                elif fault == "subject": capture["subject_id"] = "other"
                elif fault == "machine": capture["fields"]["machine_id"] = "other"
                elif fault == "matches_binding": capture["fields"]["matches_binding"] = False
                elif fault == "source_cursor": invalid["cursor"] = "1"
                elif fault == "source_incarnation": invalid["incarnation"] = "other"
                elif fault == "producer_status": invalid["observations"][0]["producer_status"]["incarnation"] = "other"
                elif fault == "status_source": invalid["observations"][0]["producer_status"]["source_id"] = "other"
                elif fault == "status_cursor": invalid["observations"][0]["producer_status"]["cursor"] = "1"
                elif fault == "capture_lane": capture["lane_id"] = "other/msx/frame"
                elif fault == "capture_id": capture["id"] = "other/2/frame"
                elif fault == "capture_seq": capture["id"] = "observer-instance/1/frame"
                elif fault == "capture_coverage": invalid["observations"][0]["output"]["coverage"][0]["incarnation"] = "other"
                elif fault == "capture_incarnation": capture["fields"]["incarnation"] = "other"
                elif fault == "ambiguous": invalid["observations"][0]["output"]["rows"].append(copy.deepcopy(capture))
                elif fault == "empty": invalid["observations"][0]["output"]["rows"] = []
                else: capture["evidence"] = []
                outputs = self.outputs([[supplied(1, 10)], [invalid], [supplied(3, 30)]])
                self.assertEqual(outputs[1]["rows"], [])
                self.assertFalse(outputs[1]["coverage"][0]["complete"])
                self.assertIn("unknown", outputs[1]["coverage"][0]["detail"])
                self.assertIsNone(outputs[2]["rows"][0]["fields"]["value"])

    def test_regressed_or_changed_same_cursor_is_unknown(self):
        for invalid in (supplied(1, 25), supplied(2, 30), supplied(2, 0, incarnation="changed-same-cursor")):
            outputs = self.outputs([[supplied(1, 10)], [supplied(2, 25)], [invalid], [supplied(3, 35)]])
            metric = outputs[2]["rows"][0]["fields"]
            self.assertEqual(metric["state"], "unknown")
            self.assertIsNone(metric["value"])
            self.assertIsNone(outputs[3]["rows"][0]["fields"]["value"])

    def test_multiple_sources_progress_and_fail_independently(self):
        first = supplied(1, 10)
        second = supplied(1, 100, instance="observer-B", installation="msx-B", source_id="source-B")
        missing = {**status("msx-captures", "unobserved", None, False), "observations": []}
        next_second = supplied(2, 125, instance="observer-B", installation="msx-B", source_id="source-B")
        outputs = self.outputs([[first, second], [missing, next_second]])
        metric, = outputs[1]["rows"]
        self.assertEqual(metric["fields"]["value"], 25)
        self.assertEqual(metric["fields"]["current"]["producer"]["installation_id"], "msx-B")
        self.assertFalse(outputs[1]["coverage"][0]["complete"])
        self.assertTrue(outputs[1]["coverage"][1]["complete"])


if __name__ == "__main__":
    unittest.main()
