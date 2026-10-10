"""Executable checks for the admission export collector's two modes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/experiments/collect-admission-exports.py"
spec = importlib.util.spec_from_file_location("collector", SCRIPT)
assert spec is not None and spec.loader is not None
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def compact(value):
    return json.dumps(value, separators=(",", ":"))


def export(cohort, followup=False):
    """A synthetic export whose hashes match its own wire bytes."""
    candidates = [{"request_id": f"r{index}", "sequence": index, "claim": f"claim {index}"}
                  for index in (1, 2)]
    scenario = ({"predecessor_fixture": "independent_200.json",
                 "predecessor_response_sha256": "b" * 64,
                 "proposed_claims": ["R-015 now requires two approvals."]}
                if followup else {"cohort": cohort})
    value = {"cohort": cohort, "semantic_judgment_performed": False,
             "prompt": "prompt", "system_prompt": "system", "keeper_instructions": "instructions",
             "schema": {"type": "object"}, "candidates": candidates,
             "initial_current_facts": [], "scenario_input": scenario,
             "candidate_receipts": [{"queue_generation": "g1", "request_id": row["request_id"],
                                     "sequence": row["sequence"], "input_sha256": sha(compact(row))}
                                    for row in candidates]}
    if followup:
        value.update({"phase": collector.FOLLOWUP_PHASE,
                      "predecessor_fixture": "independent_200.json",
                      "predecessor_response_sha256": "b" * 64,
                      "state_bundle": {name: {"present": True, "bytes": "{}", "sha256": sha("{}")}
                                       for name in collector.FOLLOWUP_STATE}})
    value["input_hashes"] = {
        "prompt_sha256": sha("prompt"), "system_prompt_sha256": sha("system"),
        "keeper_instructions_sha256": sha("instructions"),
        "schema_sha256": sha(compact(value["schema"])),
        "candidates_sha256": sha(compact(candidates)),
        "initial_current_facts_sha256": sha(compact([])),
        "scenario_input_sha256": sha(compact(scenario))}
    return value


class Collector(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def collect(self, lines, *flags):
        log = self.root / "run.log"
        log.write_text("\n".join(lines) + "\n")
        out = self.root / "exports"
        argv = ["collect", *flags, str(log), str(out)]
        saved, sys.argv = sys.argv, argv
        try:
            collector.main()
        finally:
            sys.argv = saved
        return out

    def test_followup_mode_writes_the_verified_followup(self):
        line = collector.FOLLOWUP_MARKER + compact(export("independent_200_followup", followup=True))
        out = self.collect(["noise", line], "--followup")
        self.assertEqual([path.name for path in out.iterdir()], ["independent_200_followup.json"])

    def test_default_mode_ignores_followup_lines_and_keeps_its_cohorts(self):
        lines = [collector.BASE_MARKER + compact(export(cohort)) for cohort in sorted(collector.BASE_COHORTS)]
        lines.append(collector.FOLLOWUP_MARKER + compact(export("independent_200_followup", followup=True)))
        out = self.collect(lines)
        self.assertEqual(sorted(path.stem for path in out.iterdir()), sorted(collector.BASE_COHORTS))

    def test_followup_mode_refuses_a_missing_followup(self):
        with self.assertRaisesRegex(ValueError, "missing cohorts"):
            self.collect([collector.BASE_MARKER + compact(export("independent_200"))], "--followup")

    def test_followup_mode_refuses_changed_state_bytes(self):
        value = export("independent_200_followup", followup=True)
        value["state_bundle"]["current_snapshot"]["bytes"] = "{\"changed\":true}"
        with self.assertRaisesRegex(ValueError, "state bundle current_snapshot hash mismatch"):
            self.collect([collector.FOLLOWUP_MARKER + compact(value)], "--followup")

    def test_followup_mode_refuses_a_missing_or_absent_store(self):
        for change in ("drop", "absent"):
            value = export("independent_200_followup", followup=True)
            if change == "drop":
                del value["state_bundle"]["memory_journal"]
            else:
                value["state_bundle"]["memory_journal"] = {"present": False}
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.collect([collector.FOLLOWUP_MARKER + compact(value)], "--followup")

    def test_followup_mode_refuses_another_predecessor(self):
        value = export("independent_200_followup", followup=True)
        value["predecessor_fixture"] = "repeated_200.json"
        with self.assertRaisesRegex(ValueError, "predecessor identity mismatch"):
            self.collect([collector.FOLLOWUP_MARKER + compact(value)], "--followup")


if __name__ == "__main__":
    unittest.main()
