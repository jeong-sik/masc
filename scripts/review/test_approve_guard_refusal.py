#!/usr/bin/env python3
"""approve-guard --merge-check against a fake `gh`: admission is unchanged and
a refusal names the failing footer part. Offline; no network, no real PR."""
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
HEAD = "814bd3eae8541a2965c5e1339b81a001371343a4"
BASE = "b99c9d77b503fe53c1635712fae24d5e744bb180"
DIFF = "d" * 64
SCOPE = json.dumps({"base_ref": "main", "base_sha": BASE, "stack": None}, separators=(",", ":"))

FAKE_GH = r"""#!/usr/bin/env bash
# api [--paginate] <path> [--jq <expr>] over canned JSON in $FAKE_DIR.
shift
[ "$1" != --paginate ] || shift
path="$1"; shift
printf '%s\n' "$path" >> "$FAKE_DIR/calls.log"
expr="."
[ "$1" != --jq ] || expr="$2"
case "$path" in
  repos/*/pulls/*/reviews/*) f="$FAKE_DIR/review.json";;
  repos/*/pulls/*/reviews*) f="$FAKE_DIR/reviews.json";;
  repos/*/issues/*/comments*) f="$FAKE_DIR/comments.json";;
  repos/*/pulls/*) f="$FAKE_DIR/pr.json";;
  *) echo "fake gh: unexpected $path" >&2; exit 9;;
esac
exec jq -r "$expr" "$f"
"""


def footer_line(head=HEAD, diff=DIFF, tail=True):
    line = f"approve-guard: head `{head}` · source review"
    return line + (f" · reviewed base `{BASE}` · diff sha256 `{diff}`" if tail else "")


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="guard-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.scripts = self.tmp / "scripts"
        self.scripts.mkdir()
        for name in ("approve-guard.sh", "ci-checks.sh", "review-verdict.sh",
                     "review-scope.py", "review-refusal.py"):
            shutil.copy(HERE / name, self.scripts / name)
        # The real review-diff.py needs Git objects; the diff identity is a fixed fixture here.
        (self.scripts / "review-diff.py").write_text(f"#!/usr/bin/env python3\nprint('{DIFF}')\n")
        gh = self.tmp / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        self.data = self.tmp / "data"
        self.data.mkdir()
        (self.data / "pr.json").write_text(json.dumps({
            "state": "open", "draft": False, "merged": False,
            "base": {"ref": "main", "sha": BASE}, "head": {"sha": HEAD, "ref": "fix/x"},
            "user": {"login": "author-keeper"}}))
        (self.data / "comments.json").write_text("[]")

    def review(self, footer, *, assoc="COLLABORATOR", first_suffix="", scope=SCOPE):
        scope_line = f"review-scope: {scope}\n" if scope is not None else ""
        body = (f"verdict: PASS head: {HEAD} by: reviewer-keeper{first_suffix}\nsource review notes\n\n---\n"
                f"{scope_line}{footer}")
        rev = {"id": 77, "state": "APPROVED", "author_association": assoc, "body": body,
               "commit_id": HEAD, "user": {"login": "reviewer-keeper"},
               "submitted_at": "2026-10-07T03:45:54Z"}
        (self.data / "review.json").write_text(json.dumps(rev))
        (self.data / "reviews.json").write_text(json.dumps([rev]))

    def run_guard(self, *extra):
        env = dict(os.environ, GUARD_GH=str(self.tmp / "gh"), FAKE_DIR=str(self.data))
        return subprocess.run(
            ["bash", str(self.scripts / "approve-guard.sh"), "--repo", "o/r", "--pr", "41487",
             "--head", HEAD, *extra], env=env, capture_output=True, text=True)

    def test_exact_footer_still_passes_merge_check(self):
        self.review(footer_line())
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("MERGE-CHECK PASS #41487", r.stdout)

    def test_missing_tail_is_refused_and_named(self):
        self.review(footer_line(tail=False))
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("no trusted non-author approval bound to this head and complete diff", r.stderr)
        self.assertIn("lacks the ' · reviewed base", r.stderr)
        self.assertIn(footer_line(), r.stderr)  # copyable expected footer

    def test_unbackticked_footer_is_refused_and_names_both_parts(self):
        self.review(f"approve-guard: head {HEAD}")
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("must start with `approve-guard: head `", r.stderr)
        # The prefix failure must not shadow the missing tail.
        self.assertIn("lacks the ' · reviewed base", r.stderr)

    def test_cr_terminated_review_is_refused_and_names_the_cr(self):
        # A CRLF-written approval fails the exact-head verdict; the refusal
        # must show the real bytes, with the CR visible (escaped), not stripped.
        self.review(footer_line(), first_suffix="\r")
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not admitted", r.stderr)
        self.assertIn("first line is not the exact-head verdict", r.stderr)
        self.assertIn("\\r", r.stderr)

    def test_stale_diff_is_still_refused_and_says_diff_changed(self):
        self.review(footer_line(diff="e" * 64))
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("diff changed after the review", r.stderr)

    def test_untrusted_association_is_still_refused(self):
        self.review(footer_line(), assoc="CONTRIBUTOR")
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("latest structured verdict is UNTRUSTED", r.stderr)
        self.assertIn("author_association is CONTRIBUTOR", r.stderr)
        self.assertLess(r.stderr.index("author_association is CONTRIBUTOR"),
                        r.stderr.index("latest structured verdict is UNTRUSTED"))

    def test_bad_footer_also_reports_missing_scope(self):
        self.review(footer_line(tail=False), scope=None)
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("footer lacks", r.stderr)
        self.assertIn("review-scope stamp does not match", r.stderr)

    def test_bad_footer_also_reports_mismatched_scope(self):
        wrong_scope = json.dumps({"base_ref": "another-branch", "base_sha": BASE, "stack": None})
        self.review(footer_line(tail=False), scope=wrong_scope)
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("footer lacks", r.stderr)
        self.assertIn("review-scope stamp does not match", r.stderr)

    def test_valid_approval_does_not_diagnose_another_invalid_scope(self):
        old_scope = json.dumps({"base_ref": "main", "base_sha": "f" * 40, "stack": None})
        self.review(footer_line(tail=False), scope=old_scope)
        rejected = json.loads((self.data / "review.json").read_text())
        self.review(footer_line())
        admitted = json.loads((self.data / "review.json").read_text())
        admitted["id"] = 78
        admitted["user"]["login"] = "second-reviewer"
        (self.data / "review-78.json").write_text(json.dumps(admitted))
        (self.data / "review.json").write_text(json.dumps(rejected))
        (self.data / "reviews.json").write_text(json.dumps([rejected, admitted]))
        gh = self.tmp / "gh"
        gh.write_text(gh.read_text().replace(
            "  repos/*/pulls/*/reviews/*)",
            '  repos/*/pulls/*/reviews/78) f="$FAKE_DIR/review-78.json";;\n  repos/*/pulls/*/reviews/*)'))
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        calls = (self.data / "calls.log").read_text().splitlines()
        self.assertFalse(any("/compare/" in path for path in calls))


if __name__ == "__main__":
    unittest.main()
