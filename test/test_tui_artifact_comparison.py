"""Reject incomplete or inconsistent repeated-input evidence receipts."""
import copy
import importlib.util
from pathlib import Path
import unittest

SOURCE_MODULES = (
    "scripts/harness/perf/compare_tui_artifacts.py",
    "test/test_tui_input_frame_pty.py",
)

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("compare_tui_artifacts", root / SOURCE_MODULES[0])
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


def receipt():
    return {"preflight": {"metadata_sha256": "a" * 64,
                          "visible_keepers": ["alpha", "beta"]},
            "cycles": 2, "samples": [
        {"cycle": cycle, "action": f"action {action}", "input_hex": f"{action:02x}",
         "preceding_ack_to_input_ms": None if cycle == 1 and action in (0, 6) else 0.2,
         "complete_frame_ms": 0.5}
        for actions in (range(6), range(6, 10)) for cycle in (1, 2) for action in actions
    ], "session_resources": {
        "child_user_seconds": 0.1, "child_system_seconds": 0.2,
        "child_cpu_seconds": 0.3, "wall_seconds": 1.0,
    }}


class ReceiptTests(unittest.TestCase):
    def test_reject_unacknowledged_workspace(self):
        for key, value in (("visible_keepers", []), ("visible_keepers", ["alpha"]),
                           ("metadata_sha256", "a" * 63), ("metadata_sha256", "g" * 64)):
            malformed = receipt()
            malformed["preflight"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                comparison.validate_observation(malformed, cycles=2)

    def test_complete_repetitions_preserve_all_samples(self):
        inputs, actions = comparison.validate_observation(receipt(), cycles=2)
        self.assertEqual(len(inputs), 20)
        self.assertEqual(len(actions), 10)

    def test_reject_incomplete_duplicate_or_different_cycles(self):
        incomplete = receipt()
        incomplete["samples"].pop()
        duplicate = receipt()
        duplicate["samples"][-1] = copy.deepcopy(duplicate["samples"][0])
        different = receipt()
        different["samples"][-1]["input_hex"] = "ff"
        invalid_cycle = receipt()
        invalid_cycle["samples"][-1]["cycle"] = 3
        for malformed in (incomplete, duplicate, different, invalid_cycle):
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                comparison.validate_observation(malformed, cycles=2)
        with self.assertRaises(ValueError):
            comparison.validate_observation(receipt(), cycles=3)

    def test_reject_invalid_latency_and_resources(self):
        for value in (float("nan"), float("inf"), -1.0):
            malformed = receipt()
            malformed["samples"][0]["complete_frame_ms"] = value
            with self.subTest(latency=value), self.assertRaises(ValueError):
                comparison.validate_observation(malformed, cycles=2)
            for key in receipt()["session_resources"]:
                malformed = receipt()
                malformed["session_resources"][key] = value
                with self.subTest(resource=key, value=value), self.assertRaises(ValueError):
                    comparison.validate_observation(malformed, cycles=2)

    def test_reject_inconsistent_resource_totals(self):
        for key, value in (("child_cpu_seconds", 4.0), ("wall_seconds", 0.0)):
            malformed = receipt()
            malformed["session_resources"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                comparison.validate_observation(malformed, cycles=2)

    def test_require_complete_and_valid_gap_evidence(self):
        malformed = receipt()
        del malformed["samples"][1]["preceding_ack_to_input_ms"]
        with self.assertRaises(KeyError):
            comparison.validate_observation(malformed, cycles=2)
        for value in (None, float("nan"), float("inf"), -1.0, "0.2", True):
            malformed = receipt()
            malformed["samples"][1]["preceding_ack_to_input_ms"] = value
            with self.subTest(gap=value), self.assertRaises(ValueError):
                comparison.validate_observation(malformed, cycles=2)
        for index in (0, 12):
            malformed = receipt()
            malformed["samples"][index]["preceding_ack_to_input_ms"] = 0.2
            with self.subTest(phase=index), self.assertRaises(ValueError):
                comparison.validate_observation(malformed, cycles=2)


if __name__ == "__main__":
    unittest.main()
