"""Authored offline packet/ownership scenarios. No candidate, PTY or server."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/harness/perf/tui_startup_report.py"
SPEC = importlib.util.spec_from_file_location("tui_startup_report", SCRIPT)
REPORT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = REPORT
SPEC.loader.exec_module(REPORT)

CONDITIONS = {key: "a" * 64 for key in
              ("fixture_sha256", "workspace_sha256", "terminal_sha256", "input_reply_sha256")}
UNKNOWN = {"palette_known": False, "theme_mode": None, "graphics": "unknown", "cell_pixels": None}


def complete(pid, base, delivery=0):
    """Independent fixture for the current OCaml writer's full snapshot wire."""
    return dict(phase="snapshot", pid=pid, dispatched_ns=str(base), observed_ns=str(base + 500),
                worker_started_ns=str(base + 10),
                capture_finished={"at_ns": str(base + 100), "value": {
                    "outcome": "captured", "reason": "input_ready", "bytes_read": 1, "replies": UNKNOWN}},
                caller_observed={"at_ns": str(base + 120), "value": "returned"},
                decoder_installed_ns=str(base + 130),
                capabilities_applied={"at_ns": str(base + 140), "value": UNKNOWN},
                first_input_decoded={"at_ns": str(base + 200), "value": "key"},
                first_input_received={"at_ns": str(base + 220 + delivery), "value": "key"},
                dispatch_to_worker_ns="10", capture_elapsed_ns="90", dispatch_to_caller_ns="120",
                capture_to_caller_ns="20", dispatch_to_decoder_installed_ns="130",
                dispatch_to_first_input_decoded_ns="200", dispatch_to_first_input_received_ns=str(220 + delivery),
                decoded_to_received_ns=str(20 + delivery))


def interrupted(pid):
    early = dict(phase="caller_observed", pid=pid, dispatched_ns="100", observed_ns="115",
                 worker_started_ns="110", capture_finished=None,
                 caller_observed={"at_ns": "115", "value": "interrupted"}, decoder_installed_ns=None,
                 capabilities_applied=None, first_input_decoded=None, first_input_received=None,
                 dispatch_to_worker_ns="10", capture_elapsed_ns=None, dispatch_to_caller_ns="15",
                 capture_to_caller_ns=None, dispatch_to_decoder_installed_ns=None,
                 dispatch_to_first_input_decoded_ns=None, dispatch_to_first_input_received_ns=None,
                 decoded_to_received_ns=None)
    late = copy.deepcopy(early)
    late.update(phase="capture_finished", observed_ns="140", capture_elapsed_ns="30",
                capture_finished={"at_ns": "140", "value": {
                    "outcome": "captured", "reason": "read_returned_no_byte", "bytes_read": 0, "replies": UNKNOWN}})
    return [late, early]  # Logging order is not the causal fact order.


def envelope(value, seq):
    return dict(seq=seq, ts=f"2026-10-19T00:00:{seq:02d}Z", level="INFO", source="server",
                module="Transport", keeper_name="system", turn_id=None, details=None, category=None,
                message="tui_startup_observation=" + json.dumps(value))


class Packet:
    def __init__(self, root):
        self.root = root
        self.binary = self.write("candidate.bin", b"unexecuted fixture bytes")

    def write(self, name, data):
        (self.root / name).write_bytes(data)
        return {"path": name, "sha256": hashlib.sha256(data).hexdigest()}

    def log(self, name, values):
        data = b"".join((json.dumps(envelope(value, seq)) + "\n").encode()
                        for seq, value in enumerate(values, 1))
        return self.write(name, data)

    def arm(self, log=None, pid=None, base=100):
        return dict(source_head="b" * 40, binary=self.binary, log=log,
                    capture=None if pid is None else {"pid": pid, "dispatched_ns": str(base)},
                    conditions=dict(CONDITIONS))

    def case(self, name, before, after):
        return dict(id=name, conditions=dict(CONDITIONS), before=before, after=after)

    def report(self, cases):
        path = self.root / "packet.json"
        path.write_text(json.dumps(dict(schema_version=1, cases=cases)))
        return REPORT.build_report(path)


class StartupReportScenario(unittest.TestCase):
    def test_invalid_file_paths_preserve_the_complete_cohort_and_independent_arms(self):
        with tempfile.TemporaryDirectory() as directory:
            packet = Packet(Path(directory))
            log = packet.log("paths.jsonl", [complete(pid, 100) for pid in range(70, 78)])
            nul_log = dict(log, path="bad\x00log")
            unencodable_log = dict(log, path="bad\ud800log")
            bad_binary = packet.arm(log, 74)
            bad_binary["binary"] = dict(packet.binary, path="bad\x00candidate")
            report = packet.report([
                packet.case("healthy", packet.arm(log, 70), packet.arm(log, 71)),
                packet.case("nul-log", packet.arm(nul_log, 72), packet.arm(log, 73)),
                packet.case("nul-binary", bad_binary, packet.arm(log, 75)),
                packet.case("unencodable-log", packet.arm(unencodable_log, 76), packet.arm(log, 77))])
            self.assertEqual(report["declared_cases"], 4)
            self.assertEqual(len(report["cases"]), 4)
            self.assertEqual(report["cases"][0]["before"]["input_state"], "received")
            self.assertEqual(report["cases"][1]["before"]["evidence_state"], "invalid")
            self.assertEqual(report["cases"][3]["before"]["evidence_state"], "invalid")
            self.assertTrue(all(case["after"]["evidence_state"] == "valid" for case in report["cases"]))
            self.assertEqual(report["cases"][2]["before"]["evidence_state"], "valid")
            self.assertFalse(report["cases"][2]["before"]["identity"]["binary_bytes_verified"])
            self.assertEqual(report["outcomes"]["before"]["evidence_state"]["invalid"], 2)
            self.assertEqual(report["paired_by_metric"]["dispatch_to_first_input_received_ns"], 1)
            self.assertTrue(all(case["comparison"]["dispatch_to_first_input_received_ns"]["after_minus_before_ns"] is None
                                for case in report["cases"][1:]))
            self.assertFalse(report["runtime_execution_verified"])
            self.assertIsNone(report["measured_speedup"])

    def test_full_denominator_retains_interrupted_late_and_absent_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            packet = Packet(Path(directory))
            before = packet.log("before.jsonl", [complete(1, 100)])
            after = packet.log("after.jsonl", [complete(2, 10000, delivery=10)])
            stopped_before = packet.log("stopped-before.jsonl", interrupted(3))
            stopped_after = packet.log("stopped-after.jsonl", interrupted(4))
            report = packet.report([
                packet.case("input", packet.arm(before, 1), packet.arm(after, 2, 10000)),
                packet.case("interrupted", packet.arm(stopped_before, 3), packet.arm(stopped_after, 4)),
                packet.case("absent", packet.arm(), packet.arm())])
            self.assertEqual(report["declared_cases"], 3)
            self.assertEqual(report["cases"][0]["comparison"]["dispatch_to_first_input_received_ns"]["after_minus_before_ns"], "10")
            self.assertEqual(report["outcomes"]["before"]["caller_state"]["interrupted"], 1)
            self.assertEqual(report["outcomes"]["before"]["evidence_state"]["missing"], 1)
            self.assertEqual(report["paired_by_metric"]["capture_elapsed_ns"], 2)
            self.assertEqual(report["paired_by_metric"]["dispatch_to_first_input_received_ns"], 1)
            self.assertIsNone(report["cases"][1]["before"]["facts"]["first_input_received"])
            self.assertFalse(report["runtime_execution_verified"])
            self.assertFalse(report["source_to_binary_verified"])
            self.assertIsNone(report["measured_speedup"])

    def test_conflicts_foreign_owners_duplicates_and_bad_digests_are_not_selected_away(self):
        with tempfile.TemporaryDirectory() as directory:
            packet = Packet(Path(directory))
            foreign = complete(20, 100)
            foreign["capture_elapsed_ns"] = "999"
            shared = packet.log("shared.jsonl", [foreign, complete(10, 100), complete(11, 100)])
            after = packet.log("after.jsonl", [complete(pid, 100) for pid in range(30, 35)])
            conflict = packet.log("conflict.jsonl", [complete(40, 100), complete(40, 100, delivery=5)])
            duplicated = json.dumps(envelope(complete(50, 100), 1)) + "\n"
            duplicate = packet.write("duplicate.jsonl", (duplicated * 2).encode())
            bad_binary = packet.arm(shared, 11)
            bad_binary["binary"] = dict(packet.binary, sha256="0" * 64)
            cases = [packet.case("foreign-isolation", packet.arm(shared, 10), packet.arm(after, 30)),
                     packet.case("invalid-owner", packet.arm(shared, 20), packet.arm(after, 31)),
                     packet.case("conflict", packet.arm(conflict, 40), packet.arm(after, 32)),
                     packet.case("duplicate", packet.arm(duplicate, 50), packet.arm(after, 33)),
                     packet.case("bad-binary", bad_binary, packet.arm(after, 34))]
            report = packet.report(cases)
            self.assertEqual(report["declared_cases"], len(cases))
            self.assertEqual(report["cases"][0]["before"]["evidence_state"], "valid")
            self.assertEqual(report["cases"][0]["before"]["coverage"]["foreign_rows"], 2)
            self.assertEqual([case["before"]["evidence_state"] for case in report["cases"][1:4]], ["invalid"] * 3)
            self.assertFalse(report["cases"][4]["before"]["identity"]["binary_bytes_verified"])
            self.assertEqual(report["paired_by_metric"]["dispatch_to_first_input_received_ns"], 1)
            self.assertTrue(all(case["comparison"]["dispatch_to_first_input_received_ns"]["after_minus_before_ns"] is None
                                for case in report["cases"][1:]))

    def test_large_same_process_clocks_and_invalid_case_metadata_remain_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            packet = Packet(Path(directory))
            base = 2**63 - 1000
            log = packet.log("large.jsonl", [complete(pid, base) for pid in range(60, 67)])
            mismatch = packet.arm(log, 62, base)
            mismatch["conditions"]["terminal_sha256"] = "c" * 64
            truncated = packet.write("truncated.jsonl", b'{"seq":')
            report = packet.report([
                packet.case("large", packet.arm(log, 60, base), packet.arm(log, 61, base)),
                packet.case("conditions", mismatch, packet.arm(log, 63, base)),
                packet.case("duplicate-id", packet.arm(), packet.arm()),
                packet.case("duplicate-id", packet.arm(), packet.arm()),
                packet.case("truncated", packet.arm(truncated, 60, base), packet.arm(log, 64, base)),
                packet.case("reused", packet.arm(log, 65, base), packet.arm(log, 65, base))])
            self.assertEqual(report["declared_cases"], 6)
            self.assertEqual(report["cases"][0]["before"]["facts"]["first_input_received"]["at_ns"], str(base + 220))
            self.assertEqual(report["cases"][0]["comparison"]["dispatch_to_first_input_received_ns"]["after_minus_before_ns"], "0")
            self.assertFalse(report["cases"][1]["before"]["identity"]["conditions_match_case"])
            self.assertEqual(report["cases"][2]["before"]["evidence_state"], "invalid")
            self.assertEqual(report["cases"][3]["after"]["evidence_state"], "invalid")
            self.assertEqual(report["cases"][4]["before"]["evidence_state"], "invalid")
            self.assertTrue(report["cases"][5]["after"]["identity"]["capture_artifact_reused"])
            self.assertEqual(report["paired_by_metric"]["dispatch_to_first_input_received_ns"], 1)
            self.assertIsNone(report["cases"][4]["comparison"]["dispatch_to_first_input_received_ns"]["after_minus_before_ns"])


if __name__ == "__main__":
    unittest.main()
