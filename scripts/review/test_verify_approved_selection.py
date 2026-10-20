#!/usr/bin/env python3
"""Selection identity refusals with injected source reads; no GitHub/CI calls."""
import copy
from pathlib import Path
import runpy
import unittest

VERIFY = runpy.run_path(str(Path(__file__).with_name("verify-approved-selection.py")))
P = VERIFY["P"]


class SelectionIdentityCase(unittest.TestCase):
    def setUp(self):
        self.receipt = {
            "schema_version": 1, "status": "prepared", "repo": "o/r",
            "leader": "reviewer", "base": "a" * 40, "candidate": "b" * 40,
            "tree": "c" * 40,
            "members": [{"pr": 7, "head": "d" * 40, "approval_ids": [77]}],
        }

    def verify(self, current):
        return VERIFY["verify"](
            self.receipt, repo="o/r", candidate=self.receipt["candidate"],
            git_dir="unused", gh="unused", prepare=lambda *args, **kwargs: current)

    def test_same_candidate_and_approval_is_verified(self):
        self.assertEqual(self.verify(copy.deepcopy(self.receipt)), self.receipt)

    def test_each_identity_mismatch_keeps_typed_refusal_and_values(self):
        for field in ("base", "candidate", "tree"):
            with self.subTest(field=field):
                current = copy.deepcopy(self.receipt)
                current[field] = "e" * 40
                with self.assertRaises(P.Rejected) as caught:
                    self.verify(current)
                error = caught.exception
                self.assertEqual(error.reason, P.Reason.INVALID_SELECTION)
                detail = f"{field}: receipt={self.receipt[field]} computed={current[field]}"
                self.assertEqual(error.details, (detail,))
                self.assertEqual(str(error), "invalid_selection: " + detail)

    def test_all_mismatches_survive_in_one_refusal(self):
        current = self.receipt | {name: "e" * 40 for name in ("base", "candidate", "tree")}
        with self.assertRaises(P.Rejected) as caught:
            self.verify(current)
        self.assertEqual(caught.exception.reason, P.Reason.INVALID_SELECTION)
        self.assertEqual(len(caught.exception.details), 3)

    def test_revoked_approval_remains_blocking(self):
        current = copy.deepcopy(self.receipt)
        current["members"][0]["approval_ids"] = [88]
        with self.assertRaises(P.Rejected) as caught:
            self.verify(current)
        self.assertEqual(caught.exception.reason, P.Reason.APPROVAL_CHANGED)
        self.assertEqual(caught.exception.details, ())

    def test_receipt_for_another_candidate_is_refused_before_source_reads(self):
        with self.assertRaises(P.Rejected) as caught:
            VERIFY["verify"](
                self.receipt, repo="o/r", candidate="f" * 40,
                git_dir="unused", gh="unused",
                prepare=lambda *args, **kwargs: self.fail("source reads must not start"))
        self.assertEqual(caught.exception.reason, P.Reason.INVALID_SELECTION)


if __name__ == "__main__":
    unittest.main()
