#!/usr/bin/env python3
"""Release approval evidence must bind the selected run in the same review."""
import json
import unittest

from test_approve_guard_refusal import BASE, DIFF, HEAD, RELEASE_RUN, RELEASE_SCOPE, GuardHarness


class ReleaseReceiptBinding(GuardHarness):
    def test_later_pass_comment_cannot_rebind_an_older_run_approval(self):
        pr = json.loads((self.data / "pr.json").read_text())
        pr["base"]["ref"] = "release/v0.62.0"
        pr["head"]["ref"] = "release/v0.62.0"
        (self.data / "pr.json").write_text(json.dumps(pr))
        old_run = "111"
        binding = (f"approve-guard: head `{HEAD}` · release review · release run {old_run}"
                   f" · reviewed base `{BASE}` · diff sha256 `{DIFF}`")
        approval = {
            "id": 77, "state": "APPROVED", "author_association": "COLLABORATOR",
            "body": (f"verdict: PASS head: {HEAD} run: {old_run} by: reviewer-keeper\n"
                     f"review-scope: {RELEASE_SCOPE}\n{binding}"),
            "commit_id": HEAD, "user": {"login": "reviewer-keeper"},
            "submitted_at": "2026-10-22T20:00:00Z",
        }
        comment = {
            "id": 88, "author_association": "COLLABORATOR",
            "body": f"verdict: PASS head: {HEAD} run: {RELEASE_RUN} by: second-keeper",
            "user": {"login": "second-reviewer"},
            "created_at": "2026-10-22T21:00:00Z", "updated_at": "2026-10-22T21:00:00Z",
        }
        (self.data / "review.json").write_text(json.dumps(approval))
        (self.data / "reviews.json").write_text(json.dumps([approval]))
        (self.data / "comments.json").write_text(json.dumps([comment]))

        result = self.run_guard("--merge-check")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(f"verdict cites release run {old_run}, not selected run {RELEASE_RUN}", result.stderr)
        self.assertIn(f"binding line cites release run {old_run}, not selected run {RELEASE_RUN}", result.stderr)


if __name__ == "__main__":
    unittest.main()
