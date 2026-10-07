#!/usr/bin/env python3
"""Fixtures for review-refusal.py: a refusal must name the failing footer part."""
import importlib.util
import pathlib
import re
import unittest

spec = importlib.util.spec_from_file_location(
    "review_refusal", pathlib.Path(__file__).with_name("review-refusal.py"))
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

HEAD = "814bd3eae8541a2965c5e1339b81a001371343a4"
BASE = "b99c9d77b503fe53c1635712fae24d5e744bb180"
DIFF = "a" * 64
OTHER_DIFF = "b" * 64


def review(footer, *, assoc="COLLABORATOR", first=None):
    first = first or f"verdict: PASS head: {HEAD} by: goo-yang-bong"
    return {"author_association": assoc,
            "body": f"{first}\nindependent source review: details\n\n{footer}"}


def run(r):
    return rr.diagnose(r, head=HEAD, policy="source", base_sha=BASE, current_diff=DIFF)


GOOD_FOOTER = rr.expected_footer(HEAD, "source", BASE, DIFF)


class RefusalReasons(unittest.TestCase):
    def test_pr41487_review_5437395249_shape_names_prefix_and_tail(self):
        # Verbatim shape of the review that blocked #41487: no backticks, no tail.
        out = run(review(f"approve-guard: head {HEAD}"))
        joined = "\n".join(out)
        self.assertIn("last non-empty line must start with `approve-guard: head `" + HEAD + "` · `", joined)
        self.assertIn("expected last line (copy): " + GOOD_FOOTER, joined)

    def test_backticked_head_without_tail_names_missing_base_and_diff(self):
        out = run(review(f"approve-guard: head `{HEAD}` · source review"))
        self.assertTrue(any("lacks the ' · reviewed base" in line for line in out), out)
        self.assertIn("expected last line (copy): " + GOOD_FOOTER, out[-1])

    def test_stale_diff_hash_is_reported_with_current_diff(self):
        stale = rr.expected_footer(HEAD, "source", BASE, OTHER_DIFF)
        out = run(review(stale))
        self.assertTrue(any(OTHER_DIFF in line and DIFF in line for line in out), out)

    def test_untrusted_association_is_named(self):
        out = run(review(GOOD_FOOTER, assoc="CONTRIBUTOR"))
        self.assertTrue(any("author_association is CONTRIBUTOR" in line for line in out), out)

    def test_wrong_head_in_verdict_line_is_named(self):
        out = run(review(GOOD_FOOTER, first="verdict: PASS head: " + "c" * 40 + " by: x"))
        self.assertTrue(any("first line is not the exact-head verdict" in line for line in out), out)

    def test_fully_bound_review_yields_no_reasons(self):
        self.assertEqual(run(review(GOOD_FOOTER)), [])

    def test_diagnosis_agrees_with_guard_regexes_on_good_and_bad(self):
        # The guard's own tail test, restated: diagnostics must be empty exactly when it passes.
        tail = re.compile(r" · reviewed base `[0-9a-f]{40}` · diff sha256 `" + DIFF + r"`$")
        for footer, bound in ((GOOD_FOOTER, True),
                              (f"approve-guard: head `{HEAD}` · source review", False),
                              (f"approve-guard: head {HEAD}", False)):
            ok = footer.startswith(f"approve-guard: head `{HEAD}` · ") and bool(tail.search(footer))
            self.assertEqual(ok, bound)
            self.assertEqual(run(review(footer)) == [], bound)


if __name__ == "__main__":
    unittest.main()
