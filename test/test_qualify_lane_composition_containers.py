"""Reject vacuous qualification before invoking Docker."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from qualify_lane_composition_containers import validate_plan


def plan():
    def worker(name, role, sources):
        binding = {"sources": sources}
        if role is not None:
            binding["role"] = role
        return {"installation_id": name, "binding": binding}

    def result(name):
        return {"kind": "lane_output", "installation_id": name, "output_id": "result"}

    return {"run_id": "qualification", "declarations": [
        worker("panel", "panel", [{"kind": "snapshot_file"}]),
        worker("judge", "judge", [result("panel")]),
        worker("report", None, [result("judge")]),
    ]}


class QualificationPlanTests(unittest.TestCase):
    def test_accepts_connected_panel_judge_report(self):
        self.assertEqual(validate_plan(plan()), {"panel": "panel", "judge": "judge", "report": None})

    def test_empty_plan_fails_before_docker(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "plan.json").write_text(json.dumps({"run_id": "empty", "declarations": []}))
            result = subprocess.run([
                sys.executable, str(Path(__file__).with_name("qualify_lane_composition_containers.py")),
                "--plan", str(path / "plan.json"), "--compute-image", "unused",
                "--report-image", "unused", "--output-dir", str(path / "output"),
            ], capture_output=True, text=True, env={"PATH": ""})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Qualification requires panel, judge and report declarations", result.stderr)
            self.assertNotIn("Docker CLI", result.stderr)
            self.assertFalse((path / "output/summary.json").exists())

    def test_rejects_incomplete_or_disconnected_graph(self):
        original = plan()
        invalid = []
        missing_run = copy.deepcopy(original)
        del missing_run["run_id"]
        invalid.append(missing_run)
        for index in range(3):
            missing_worker = copy.deepcopy(original)
            del missing_worker["declarations"][index]
            invalid.append(missing_worker)
        duplicate = copy.deepcopy(original)
        duplicate["declarations"].append(duplicate["declarations"][-1])
        invalid.append(duplicate)
        disconnected = copy.deepcopy(original)
        disconnected["declarations"][-1]["binding"]["sources"] = []
        invalid.append(disconnected)
        wrong_report = copy.deepcopy(original)
        wrong_report["declarations"][-1]["binding"]["sources"][0]["installation_id"] = "panel"
        invalid.append(wrong_report)
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_plan(value)


if __name__ == "__main__":
    unittest.main()
