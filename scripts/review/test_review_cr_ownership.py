#!/usr/bin/env python3
"""Exercise change-request ownership reduction without GitHub access."""
import importlib.util
import json
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("review_cr_ownership", HERE / "review-cr-ownership.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
HEAD, BASE, DIFF = "a" * 40, "b" * 40, "d" * 64


def request(rid=10, account=2, keeper="one", submitted="2026-10-08T03:45:54Z"):
    return {"id": rid, "state": "CHANGES_REQUESTED", "user": {"id": account},
            "submitted_at": submitted,
            "body": f"verdict: FAIL head: {HEAD} by: {keeper}\nproblem"}


def approval(rid=20, account=2, keeper="one", replaces="10", submitted="2026-10-09T03:45:54Z"):
    footer = (f"approve-guard: head `{HEAD}` · source review · replaces own CHANGES_REQUESTED {replaces}"
              f" · reviewed base `{BASE}` · diff sha256 `{DIFF}`")
    scope = json.dumps({"base_ref": "main", "base_sha": BASE, "stack": None})
    return {"id": rid, "state": "APPROVED", "user": {"id": account},
            "author_association": "COLLABORATOR", "submitted_at": submitted,
            "body": f"verdict: PASS head: {HEAD} by: {keeper}\nreview-scope: {scope}\n{footer}"}


class OwnershipReduction(unittest.TestCase):
    def test_submission_time_not_review_id_controls_replacement(self):
        # Review objects can be created as drafts before they are submitted.
        later_id_cr = request(rid=30)
        earlier_id_pass = approval(rid=20, replaces="30")
        self.assertEqual(M.outstanding([[later_id_cr, earlier_id_pass]]), ())

        later_cr = request(submitted="2026-10-10T03:45:54Z")
        earlier_pass = approval(submitted="2026-10-09T03:45:54Z")
        self.assertEqual(M.outstanding([[later_cr, earlier_pass]]), ((10, 2, "one"),))

    def test_same_or_unknown_submission_times_never_resolve_a_request(self):
        same = "2026-10-09T03:45:54Z"
        self.assertEqual(M.outstanding([[request(submitted=same), approval(submitted=same)]]),
                         ((10, 2, "one"),))
        for cr_time, pass_time in ((None, same), ("invalid", same),
                                   ("2026-10-08T03:45:54Z", None),
                                   ("2026-10-08T03:45:54Z", "2026-10-09T03:45:54")):
            with self.subTest(cr_time=cr_time, pass_time=pass_time):
                self.assertEqual(M.outstanding([[request(submitted=cr_time),
                                                 approval(submitted=pass_time)]]),
                                 ((10, 2, "one"),))

    def test_later_unrelated_approval_does_not_clear_older_tied_request(self):
        same = "2026-10-09T03:45:54Z"
        reviews = [request(submitted=same), approval(submitted=same),
                   approval(rid=30, replaces="999", submitted="2026-10-10T03:45:54Z")]
        self.assertEqual(M.outstanding([reviews]), ((10, 2, "one"),))

    def test_only_same_account_and_claimed_keeper_can_replace_explicit_id(self):
        cr = request()
        for other in (approval(account=3), approval(keeper="two"), approval(replaces="100")):
            with self.subTest(other=other):
                self.assertEqual(M.outstanding([[cr], [other]]), ((10, 2, "one"),))
        self.assertEqual(M.outstanding([[cr], [approval()]]), ())

    def test_multiple_requests_require_explicit_replacement_of_each(self):
        self.assertEqual(M.outstanding([[request(), request(rid=11), approval()]]),
                         ((11, 2, "one"),))
        self.assertEqual(M.outstanding([[request(), request(rid=11), approval(replaces="10 11")]]), ())

    def test_missing_signer_or_incomplete_footer_does_not_clear(self):
        unsigned = request()
        unsigned["body"] = "Please change this"
        self.assertEqual(M.outstanding([[unsigned, approval()]]), ((10, 2, None),))
        bad = approval()
        bad["body"] = bad["body"].replace('"base_ref": "main"', '"base_ref": null')
        self.assertEqual(M.outstanding([[request(), bad]]), ((10, 2, "one"),))

    def test_carriage_return_in_pass_header_or_footer_does_not_clear(self):
        for transform in (lambda body: body.replace("\n", "\r\n", 1),
                          lambda body: body + "\r\n"):
            with self.subTest(transform=transform):
                bad = approval()
                bad["body"] = transform(bad["body"])
                self.assertEqual(M.outstanding([[request(), bad]]), ((10, 2, "one"),))

    def test_dismissed_request_is_not_pending(self):
        cr = request()
        cr["state"] = "DISMISSED"
        self.assertEqual(M.outstanding([[cr]]), ())

    def test_release_replacement_binds_the_same_run_in_header_and_footer(self):
        good = approval()
        good["body"] = (good["body"].replace(f"head: {HEAD} by:", f"head: {HEAD} run: 123 by:")
                        .replace("source review ·", "release review · release run 123 ·"))
        self.assertEqual(M.outstanding([[request(), good]]), ())
        bad = dict(good)
        bad["body"] = good["body"].replace("release run 123", "release run 124")
        self.assertEqual(M.outstanding([[request(), bad]]), ((10, 2, "one"),))

    def test_invalid_or_duplicate_pages_are_unavailable(self):
        for pages in ([], [None], [[request(), request()]], [[{"id": None}]]):
            with self.subTest(pages=pages), self.assertRaises(ValueError):
                M.outstanding(pages)


if __name__ == "__main__":
    unittest.main()
