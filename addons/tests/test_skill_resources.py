"""Execute the bundled helper, separately from Skill publication and reading."""

import json
from pathlib import Path
import subprocess
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "msx-observer/skills/msx-observe/scripts/summarize.py"


def capture(identity, incarnation, frame):
    return {
        "id": identity, "lane_id": "installed/msx/frame", "kind": "value",
        "subject_id": "workspace-msx", "observed_at": 123.0, "actor": None,
        "clock": {"domain": f"msx/workspace-msx/{incarnation}/frame", "value": str(frame)},
        "fields": {"machine_id": "workspace-msx", "machine_incarnation": incarnation,
                   "frame": frame, "matches_binding": True, "input_cursor": "2", "input_ledger": None},
        "evidence": [{"uri": "lane-evidence:" + "a" * 64, "sha256": "a" * 64}],
    }


class SkillResourceTests(unittest.TestCase):
    def invoke(self, document, *identities):
        args = [sys.executable, str(SCRIPT)]
        for identity in identities:
            args.extend(["--row-id", identity])
        return subprocess.run(args, input=json.dumps(document), capture_output=True, text=True, check=False)

    def test_selected_capture_clocks_and_partial_coverage_remain_distinct(self):
        coverage = [{"source_id": "machine", "incarnation": "load-b", "cursor": "2",
                     "complete": False, "detail": "An observation is pending"}]
        document = {"rows": [capture("first", "load-a", 20), capture("second", "load-b", 20),
                             capture("not-selected", "load-b", 21)], "coverage": coverage}
        inputs = {"format": "msx-input-jsonl-sequence", "entry_count": 2,
                  "evidence": {"uri": "lane-sequence:" + "b" * 64, "sha256": "b" * 64}}
        document["rows"][0]["fields"]["input_ledger"] = inputs
        document["rows"][0]["evidence"].append(inputs["evidence"])
        result = self.invoke(document, "first", "second")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual([row["row_id"] for row in output["captures"]], ["first", "second"])
        self.assertEqual([row["machine_incarnation"] for row in output["captures"]], ["load-a", "load-b"])
        self.assertEqual(output["coverage"], coverage)
        self.assertEqual(output["captures"][0]["evidence"], document["rows"][0]["evidence"])
        self.assertEqual(output["captures"][0]["input_ledger"], inputs)
        self.assertIsNone(output["captures"][1]["input_ledger"])

    def test_absent_selection_is_an_error(self):
        result = self.invoke({"rows": [capture("known", "load-a", 20)], "coverage": []}, "absent")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("selected row is absent", result.stderr)

    def test_inconsistent_clock_is_an_error(self):
        row = capture("known", "load-a", 20)
        row["clock"]["value"] = "21"
        result = self.invoke({"rows": [row], "coverage": []}, "known")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("clock does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
