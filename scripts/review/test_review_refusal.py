#!/usr/bin/env python3
"""Fixtures for review-refusal.py: a refusal must name the failing footer part."""
import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location(
    "review_refusal", pathlib.Path(__file__).with_name("review-refusal.py"))
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

HEAD = "814bd3eae8541a2965c5e1339b81a001371343a4"
BASE = "b99c9d77b503fe53c1635712fae24d5e744bb180"
DIFF = "a" * 64
OTHER_DIFF = "b" * 64


def review(footer, *, assoc="COLLABORATOR", first=None, state="APPROVED"):
    first = first or f"verdict: PASS head: {HEAD} by: goo-yang-bong"
    return {"id": 5437395249, "state": state, "author_association": assoc,
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

    def test_prefix_and_tail_both_broken_are_both_named(self):
        # One footer can miss both parts; the refusal must name each failing
        # part, not let the prefix failure shadow the missing tail.
        out = run(review(f"approve-guard: head {HEAD}"))
        joined = "\n".join(out)
        self.assertIn("must start with `approve-guard: head `", joined)
        self.assertIn("lacks the ' · reviewed base", joined)

    def test_trailing_cr_in_verdict_line_shows_real_bytes(self):
        out = run(review(GOOD_FOOTER, first=f"verdict: PASS head: {HEAD} by: goo-yang-bong\r"))
        verdict_reason = next(line for line in out if "first line is not the exact-head verdict" in line)
        self.assertIn("\\r", verdict_reason, out)

    def test_trailing_cr_in_footer_tail_is_named_with_bytes(self):
        out = run(review(GOOD_FOOTER + "\r"))
        joined = "\n".join(out)
        self.assertIn("footer tail must end with", joined)
        # short() cuts the preview at 160 chars, so the \r itself can sit past
        # the cut; the reason must still name the carriage return in words.
        self.assertIn("trailing carriage return", joined)

    def test_control_bytes_in_echoed_lines_are_escaped(self):
        out = run(review(f"approve-guard: head {HEAD}\x1b[2J"))
        joined = "\n".join(out)
        self.assertNotIn("\x1b", joined)
        self.assertIn("\\x1b[2J", joined)

    def test_non_approved_state_is_refused(self):
        out = run(review(GOOD_FOOTER, state="COMMENTED"))
        self.assertTrue(any("review state is COMMENTED" in line for line in out), out)

    def test_cli_prints_id_when_admitted_and_exits_zero(self):
        proc = self.cli(review(GOOD_FOOTER))
        self.assertEqual((proc.returncode, proc.stdout.strip()), (rr.EXIT_ADMITTED, "5437395249"))

    def test_cli_exits_one_with_reasons_when_refused(self):
        proc = self.cli(review(f"approve-guard: head {HEAD}"))
        self.assertEqual(proc.returncode, rr.EXIT_REFUSED)
        self.assertIn("expected last line (copy): " + GOOD_FOOTER, proc.stdout)

    def cli(self, rev):
        return subprocess.run(
            [sys.executable, "-I", str(pathlib.Path(rr.__file__)), "--head", HEAD, "--policy", "source",
             "--base-sha", BASE, "--current-diff", DIFF],
            input=json.dumps(rev), capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
