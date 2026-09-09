#!/usr/bin/env python3
"""The acceptance receipt must reject incomplete or unrelated tool evidence."""
import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/harness/workload"))
from standalone_verifier_skill_acceptance import assess


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.proof_root = Path("/tmp/standalone-verifier-test-proof").resolve()
        self.expected_content = '{"revision":"fixture-sha","passed":3,"total":3}\n'
        self.goal = {"id": "goal-probe", "phase": "completed", "verification": {
            "completion": {"state": "proof_proven", "verdict": {"verification_run_id": "run-1"}}}}
        self.run = {"run_id": "run-1", "goal_id": "goal-probe", "status": "committed", "tools": [
            {"tool_name": "keeper_skill", "disposition": "completed", "finished_at": 1,
             "input": {"identity": {"name": "evidence-review"}}},
            {"tool_name": "tool_read_file", "disposition": "completed", "finished_at": 2,
             "input": {"file_path": "probe/matching.json"}, "output_truncated": False,
             "output_excerpt": json.dumps({"ok": True, "truncated": False,
                 "path": str(self.proof_root / "probe/matching.json"),
                 "content": self.expected_content})},
            {"tool_name": "report_review_verdict", "disposition": "completed", "finished_at": 3,
             "input": {"verdict": "APPROVE"}},
        ]}

    def passed(self, run):
        return assess(self.goal, run, "proof_proven", "probe/matching.json",
                      evidence_readable=True, proof_root=self.proof_root,
                      expected_content=self.expected_content)["passed"]

    def test_correlated_complete_trace(self):
        self.assertTrue(self.passed(self.run))

    def test_file_path_resolves_against_explicit_cwd_and_proof_root(self):
        for arguments in (
            {"cwd": "probe", "file_path": "matching.json"},
            {"cwd": str(self.proof_root / "probe"), "file_path": "matching.json"},
            {"file_path": str(self.proof_root / "probe/matching.json")},
            {"cwd": "probe/../probe", "file_path": "./matching.json"},
        ):
            with self.subTest(arguments=arguments):
                run = copy.deepcopy(self.run)
                run["tools"][1]["input"] = arguments
                self.assertTrue(self.passed(run))

    def test_other_root_or_non_schema_path_does_not_match_fixture(self):
        for arguments in (
            {"cwd": "../other", "file_path": "probe/matching.json"},
            {"file_path": str(self.proof_root.parent / "other/probe/matching.json")},
            {"cwd": "other", "file_path": "matching.json"},
            {"path": "probe/matching.json"},
            {"file_path": ""},
        ):
            with self.subTest(arguments=arguments):
                run = copy.deepcopy(self.run)
                run["tools"][1]["input"] = arguments
                self.assertFalse(self.passed(run))

    def test_partial_empty_or_different_returned_content_cannot_pass(self):
        for content in ("{\n", "", '{"passed":3}', self.expected_content + "extra"):
            with self.subTest(content=content):
                run = copy.deepcopy(self.run)
                payload = json.loads(run["tools"][1]["output_excerpt"])
                payload["content"] = content
                run["tools"][1]["output_excerpt"] = json.dumps(payload)
                self.assertFalse(self.passed(run))

    def test_failed_truncated_or_foreign_output_cannot_pass(self):
        for field, value in (("ok", False), ("truncated", True), ("path", "/tmp/other.json")):
            with self.subTest(field=field):
                run = copy.deepcopy(self.run)
                payload = json.loads(run["tools"][1]["output_excerpt"])
                payload[field] = value
                run["tools"][1]["output_excerpt"] = json.dumps(payload)
                self.assertFalse(self.passed(run))
        for excerpt in ("", "not json", "[]", "null"):
            run = copy.deepcopy(self.run)
            run["tools"][1]["output_excerpt"] = excerpt
            self.assertFalse(self.passed(run))
        run = copy.deepcopy(self.run)
        run["tools"][1]["output_truncated"] = True
        self.assertFalse(self.passed(run))

    def test_verdict_alone_does_not_prove_skill_workflow(self):
        for removed in (0, 1):
            with self.subTest(removed=removed):
                run = copy.deepcopy(self.run)
                del run["tools"][removed]
                self.assertFalse(self.passed(run))

    def test_foreign_run_or_goal_is_not_accepted(self):
        for field in ("run_id", "goal_id"):
            with self.subTest(field=field):
                run = dict(self.run, **{field: "unrelated"})
                self.assertFalse(self.passed(run))

    def test_failed_read_or_another_file_is_not_positive_evidence(self):
        for field, value in (("disposition", "failed"), ("input", {"file_path": "unrelated.json"})):
            with self.subTest(field=field):
                run = copy.deepcopy(self.run)
                run["tools"][1][field] = value
                self.assertFalse(self.passed(run))

    def test_skill_after_verdict_does_not_prove_guided_review(self):
        run = copy.deepcopy(self.run)
        run["tools"][0]["finished_at"] = 4
        self.assertFalse(self.passed(run))

    def test_other_skill_and_duplicate_verdict_do_not_pass(self):
        run = copy.deepcopy(self.run)
        run["tools"][0]["input"]["identity"]["name"] = "unrelated"
        self.assertFalse(self.passed(run))
        run = copy.deepcopy(self.run)
        run["tools"].append(copy.deepcopy(run["tools"][-1]))
        self.assertFalse(self.passed(run))

    def test_missing_artifact_rejection_can_record_failed_read(self):
        self.goal["phase"] = "executing"
        self.goal["verification"]["completion"]["state"] = "proof_refuted"
        self.run["tools"][1]["disposition"] = "failed"
        self.run["tools"][2]["input"]["verdict"] = "REJECT"
        self.run["tools"][1]["input"]["file_path"] = "probe/missing.json"
        self.assertTrue(assess(self.goal, self.run, "proof_refuted", "probe/missing.json",
                               evidence_readable=False, proof_root=self.proof_root)["passed"])

    def test_wrong_revision_rejection_requires_successful_exact_read(self):
        self.goal["phase"] = "executing"
        self.goal["verification"]["completion"]["state"] = "proof_refuted"
        self.run["tools"][1]["input"]["file_path"] = "probe/wrong-revision.json"
        payload = json.loads(self.run["tools"][1]["output_excerpt"])
        payload["path"] = str(self.proof_root / "probe/wrong-revision.json")
        self.run["tools"][1]["output_excerpt"] = json.dumps(payload)
        self.run["tools"][2]["input"]["verdict"] = "REJECT"

        def assessed(run):
            return assess(self.goal, run, "proof_refuted", "probe/wrong-revision.json",
                          evidence_readable=True, proof_root=self.proof_root,
                      expected_content=self.expected_content)["passed"]

        self.assertTrue(assessed(self.run))
        for field, value in (("disposition", "failed"), ("input", {"file_path": "unrelated.json"})):
            with self.subTest(field=field):
                run = copy.deepcopy(self.run)
                run["tools"][1][field] = value
                self.assertFalse(assessed(run))

        run = copy.deepcopy(self.run)
        run["tools"][1]["disposition"] = "failed"
        late_read = copy.deepcopy(self.run["tools"][1])
        late_read["finished_at"] = 4
        run["tools"].append(late_read)
        self.assertFalse(assessed(run))


if __name__ == "__main__":
    unittest.main()
