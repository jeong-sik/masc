#!/usr/bin/env python3
"""Real Git composition and real source guard; fixture GitHub, no CI/builds."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import test_batch_evidence as fixtures

spec = importlib.util.spec_from_file_location(
    "prepare_approved_batch", Path(__file__).with_name("prepare-approved-batch.py"))
P = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = P
spec.loader.exec_module(P)


class ApprovedBatchTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.BatchEvidenceTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.approvals()
        for pr, head in self.fixture.heads.items():
            self.fixture.get(f"pulls/{pr}")["base"]["sha"] = self.fixture.base
            row = self.fixture.get(f"pulls/{pr}/reviews?per_page=100")[0]
            row["body"] = (f"review: APPROVE head: {head} by: reviewer\n\n"
                           f"approve-guard: head `{head}` · source review by reviewer · CI evaluated at merge")
            self.fixture.put(f"pulls/{pr}/reviews/{row['id']}", row)
        # CI evidence is deliberately absent. A source approval read must not
        # ask for it, and the fake gh refuses endpoints not present here.
        self.fixture.data = {key: value for key, value in self.fixture.data.items()
                             if "/actions/" not in key and "/check-" not in key}
        self.save()

    def save(self):
        self.fixture.fixture.write_text(json.dumps(self.fixture.data))

    def prepare(self, selected=None, approve=P.source_approval):
        selected = selected or tuple(P.Member(pr, head)
                                     for pr, head in self.fixture.heads.items())
        with patch.object(fixtures.F, "api", self.fixture.api):
            return P.prepare(fixtures.F, repo="o/r", leader="leader", selected=selected,
                             git_dir=str(self.fixture.repo), gh=str(self.fixture.fake),
                             approve=approve)

    def test_combines_only_selected_approved_heads_without_ci(self):
        receipt = self.prepare()
        self.assertEqual(receipt["base"], self.fixture.base)
        for name in ("one", "two"):
            self.assertEqual(self.fixture.git("show", receipt["candidate"] + f":lib/{name}.ml"),
                             f"let {name} = {1 if name == 'one' else 2}")
        self.assertEqual([m["pr"] for m in receipt["members"]], [1, 2])
        calls = (self.fixture.root / "requests.jsonl").read_text()
        self.assertNotIn("/actions/", calls)
        self.assertNotIn("/check-runs", calls)

    def test_unapproved_member_cannot_enter_combined_tree(self):
        self.fixture.put("pulls/2/reviews?per_page=100", [])
        self.save()
        with self.assertRaises(P.Rejected):
            self.prepare()

    def test_open_change_request_precedes_approval(self):
        rows = self.fixture.get("pulls/2/reviews?per_page=100")
        rows.append({"id": 500, "state": "CHANGES_REQUESTED", "user": {"login": "other"}})
        self.save()
        with self.assertRaises(P.Rejected):
            self.prepare()

    def test_head_push_after_approval_refuses_preparation(self):
        calls = []
        def approve(repo, selected, *, gh):
            calls.append(selected.pr)
            if calls == [1, 2, 1]:
                self.fixture.get("pulls/1")["head"]["sha"] = self.fixture.heads[2]
                self.save()
            return P.source_approval(repo, selected, gh=gh)
        with self.assertRaises(P.Rejected):
            self.prepare(approve=approve)

    def test_unselected_base_cannot_supply_unreviewed_changes(self):
        self.fixture.get("pulls/2")["base"]["sha"] = self.fixture.heads[1]
        with self.assertRaises(P.Rejected) as error:
            self.prepare()
        self.assertEqual(error.exception.reason, P.Reason.UNSELECTED_BASE)

    def test_missing_receipt_directory_creates_no_branch(self):
        result = subprocess.run(
            [sys.executable, str(Path(P.__file__)), "--repo", "o/r", "--leader", "leader",
             "--git-dir", str(self.fixture.repo), "--branch", "ci/missing-receipt",
             "--output", str(self.fixture.root / "missing" / "selection.json"),
             "--member", f"1@{self.fixture.heads[1]}"],
            text=True, capture_output=True,
            env=os.environ | {"GUARD_GH": str(self.fixture.fake)})
        self.assertEqual(result.returncode, 1)
        found = subprocess.run(["git", "-C", str(self.fixture.repo), "show-ref", "--verify",
                                "refs/heads/ci/missing-receipt"], capture_output=True)
        self.assertNotEqual(found.returncode, 0)

    def test_cli_creates_local_candidate_and_receipt_without_push(self):
        output = self.fixture.root / "selection.json"
        result = subprocess.run(
            [sys.executable, str(Path(P.__file__)), "--repo", "o/r", "--leader", "leader",
             "--git-dir", str(self.fixture.repo), "--branch", "ci/selected",
             "--output", str(output), "--member", f"1@{self.fixture.heads[1]}"],
            text=True, capture_output=True,
            env=os.environ | {"GUARD_GH": str(self.fixture.fake)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = json.loads(output.read_text())
        self.assertEqual(self.fixture.git("rev-parse", "ci/selected"), receipt["candidate"])
        self.assertEqual(self.fixture.git("ls-remote", "origin", "refs/heads/ci/selected"), "")


if __name__ == "__main__":
    unittest.main()
