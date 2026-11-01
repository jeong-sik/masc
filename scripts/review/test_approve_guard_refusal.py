#!/usr/bin/env python3
"""Source receipts and merge admission against a fake `gh`.
Offline; no network, no real PR."""
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
set -o pipefail
shift
[ "$1" != --paginate ] || shift
slurp=0
if [ "$1" = --slurp ]; then slurp=1; shift; fi
path="$1"; shift
printf '%s\n' "$path" >> "$FAKE_DIR/calls.log"
expr="."
[ "$1" != --jq ] || expr="$2"
case "$path" in
  user) f="$FAKE_DIR/user.json";;
  repos/*/commits/*/status) f="$FAKE_DIR/status.json";;
  repos/*/compare/*)
    count_file="$FAKE_DIR/compare-count"
    count=0; [ ! -f "$count_file" ] || count=$(cat "$count_file")
    count=$((count + 1)); printf '%s' "$count" > "$count_file"
    f="$FAKE_DIR/compare-$count.json"; [ -f "$f" ] || f="$FAKE_DIR/compare.json";;
  repos/*/pulls/*/reviews/*) f="$FAKE_DIR/review.json";;
  repos/*/pulls/*/reviews*) f="$FAKE_DIR/reviews.json"; reviews_collection=1;;
  repos/*/issues/*/comments*) f="$FAKE_DIR/comments.json";;
  repos/*/actions/runs/*/jobs*) f="$FAKE_DIR/jobs.json";;
  repos/*/actions/runs*) f="$FAKE_DIR/runs.json";;
  repos/*/pulls/*) f="$FAKE_DIR/pr.json";;
  *) echo "fake gh: unexpected $path" >&2; exit 9;;
esac
if [ "$slurp" = 1 ] && [ "${reviews_collection:-0}" = 1 ]; then
  jq 'def uid: if .login == "author-keeper" then 10 elif .login == "reviewer-account" then 20 elif .login == "reviewer-keeper" then 30 elif .login == "second-reviewer" then 40 else 50 end;
      [walk(if type == "object" and (.login | type) == "string" and (has("id") | not) then .id = uid else . end)]' "$f"
else
  jq 'def uid: if .login == "author-keeper" then 10 elif .login == "reviewer-account" then 20 elif .login == "reviewer-keeper" then 30 elif .login == "second-reviewer" then 40 else 50 end;
      walk(if type == "object" and (.login | type) == "string" and (has("id") | not) then .id = uid else . end)' "$f" | jq -r "$expr"
fi
"""


def footer_line(head=HEAD, diff=DIFF, tail=True):
    line = f"approve-guard: head `{head}` · source review"
    return line + (f" · reviewed base `{BASE}` · diff sha256 `{diff}`" if tail else "")


def release_footer(head=HEAD, diff=DIFF):
    return (f"approve-guard: head `{head}` · release review"
            f" · release run {RELEASE_RUN}"
            f" · reviewed base `{BASE}` · diff sha256 `{diff}`")


RELEASE_RUN = 5550001111
# Release reviews stamp the release branch as base, not main.
RELEASE_SCOPE = json.dumps({"base_ref": "release/v0.62.0", "base_sha": BASE, "stack": None}, separators=(",", ":"))


class GuardHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="guard-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.scripts = self.tmp / "scripts"
        self.scripts.mkdir()
        for name in ("approve-guard.sh", "ci-checks.sh", "review-verdict.sh", "review-decisions.py",
                     "review-scope.py", "review-refusal.py", "_gh_merge_base.py",
                     "prepare-approved-batch.py", "review-commit-accounts.py", "review-cr-ownership.py",
                     "review-formal-order.py"):
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
        (self.data / "user.json").write_text(json.dumps({"login": "reviewer-account"}))
        (self.data / "compare.json").write_text(json.dumps([{
            "base_commit": {"sha": BASE}, "total_commits": 1,
            "commits": [{"sha": HEAD, "author": {"login": "content-author", "id": 555},
                         "committer": {"login": "content-author", "id": 555}}]}]))
        (self.data / "status.json").write_text(json.dumps({"statuses": []}))
        (self.data / "reviews.json").write_text("[]")
        (self.data / "comments.json").write_text("[]")
        # Release policy fixtures: a completed successful RC run and its jobs.
        self.rc_run_id = 5550001111
        (self.data / "runs.json").write_text(json.dumps({"workflow_runs": [{
            "id": self.rc_run_id, "status": "completed", "conclusion": "success",
            "head_sha": HEAD, "head_branch": "release/v0.62.0",
            "path": ".github/workflows/release-candidate.yml"}]}))
        (self.data / "jobs.json").write_text(json.dumps({"jobs": [
            {"name": "compile / Release checks passed", "status": "completed", "conclusion": "success", "id": 1},
            {"name": "behavior / test suite", "status": "completed", "conclusion": "success", "id": 2},
            {"name": "installation / release", "status": "completed", "conclusion": "success", "id": 3},
            {"name": "Record candidate verification", "status": "completed", "conclusion": "success", "id": 4}]}))

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


class Case(GuardHarness):
    pass


class ReadFailureNaming(GuardHarness):
    # run 39404586810: a gh read failure inside check_reviews ended as a bare
    # exit 1 and became an unreadable evidence_read_failed one level up. The
    # guard must name the failed read on stderr and keep exit 1.
    def test_source_receipt_names_the_failed_review_read(self):
        (self.data / "reviews.json").unlink()
        r = self.run_guard("--source-receipt")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("approve-guard: review rows read failed", r.stderr)
        self.assertIn("repos/o/r/pulls/41487/reviews", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_merge_check_names_the_failed_verdict_read(self):
        self.review(footer_line())
        (self.data / "comments.json").unlink()
        r = self.run_guard("--merge-check")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("approve-guard: verdict read failed", r.stderr)

    def test_healthy_receipt_path_still_admits(self):
        self.review(footer_line())
        r = self.run_guard("--source-receipt")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["pr"], 41487)


class CommitIndependence(GuardHarness):
    def set_pages(self, pages, name="compare.json"):
        (self.data / name).write_text(json.dumps(pages))

    def page(self, commits, total=None):
        return {"base_commit": {"sha": BASE},
                "total_commits": len(commits) if total is None else total, "commits": commits}

    def commit(self, sha, author, committer):
        return {"sha": sha, "author": author, "committer": committer}

    def test_unknown_commit_role_refuses_publication_and_receipt(self):
        self.review(footer_line())
        author = {"login": "content-author", "id": 555}
        for author_role, committer_role in ((None, author), (author, None)):
            self.set_pages([self.page([self.commit(HEAD, author_role, committer_role)])])
            for mode in ("--check", "--source-receipt"):
                with self.subTest(author=author_role, committer=committer_role, mode=mode):
                    result = self.run_guard(mode)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("identity is incomplete", result.stderr)
                    self.assertIn(f"{HEAD} {'author' if author_role is None else 'committer'} account unavailable", result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_diagnostic_reports_omitted_identity_problems(self):
        self.review(footer_line())
        author = {"login": "content-author", "id": 555}
        commits = [self.commit(f"{n:040x}", None, author) for n in range(1, 7)]
        self.set_pages([self.page(commits, total=7)])
        result = self.run_guard("--source-receipt")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("comparison returned 6 of 7 commits", result.stderr)
        self.assertIn(f"{1:040x} author account unavailable", result.stderr)
        self.assertIn("2 more identity problems", result.stderr)

    def test_matching_account_is_not_admitted_or_allowed_to_publish(self):
        self.review(footer_line())
        # Different spelling cannot defeat matching the immutable account id.
        person = {"login": "content-alias", "id": 30}
        self.set_pages([self.page([self.commit(HEAD, person, person)])])
        receipt = self.run_guard("--source-receipt")
        self.assertEqual(receipt.returncode, 2, receipt.stderr)
        self.assertIn("content commit account", receipt.stderr)
        self.set_pages([self.page([self.commit(HEAD, {"login": "reviewer-account", "id": 20}, person)])])
        publication = self.run_guard("--check")
        self.assertEqual(publication.returncode, 2, publication.stderr)
        self.assertIn("content commit author or committer", publication.stderr)

    def test_later_compare_page_is_included(self):
        self.review(footer_line())
        other = {"login": "content-author", "id": 555}
        reviewer = {"login": "reviewer-keeper", "id": 30}
        self.set_pages([self.page([self.commit("1" * 40, other, other)], total=2),
                        self.page([self.commit(HEAD, other, reviewer)], total=2)])
        result = self.run_guard("--source-receipt")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("content commit account", result.stderr)

    def test_incomplete_pagination_and_failed_read_do_not_admit(self):
        self.review(footer_line())
        other = {"login": "content-author", "id": 555}
        self.set_pages([self.page([self.commit(HEAD, other, other)], total=2)])
        incomplete = self.run_guard("--source-receipt")
        self.assertEqual(incomplete.returncode, 2, incomplete.stderr)
        (self.data / "compare.json").unlink()
        unavailable = self.run_guard("--source-receipt")
        self.assertEqual(unavailable.returncode, 1, unavailable.stderr)
        self.assertIn("commit identities unavailable", unavailable.stderr)

    def test_identity_mapping_change_before_consumption_is_refused(self):
        self.review(footer_line())
        changed = {"login": "content-author", "id": 556}
        self.set_pages([self.page([self.commit(HEAD, changed, changed)])], "compare-2.json")
        result = self.run_guard("--source-receipt")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("identities changed", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_unknown_existing_reviewer_does_not_prevent_another_publication(self):
        self.review(footer_line())
        review = json.loads((self.data / "review.json").read_text())
        review["user"]["id"] = None
        (self.data / "review.json").write_text(json.dumps(review))
        (self.data / "reviews.json").write_text(json.dumps([review]))
        receipt = self.run_guard("--source-receipt")
        self.assertEqual(receipt.returncode, 2, receipt.stderr)
        self.assertIn("reviewer account identity unavailable", receipt.stderr)
        publication = self.run_guard("--check")
        self.assertEqual(publication.returncode, 0, publication.stderr)
        self.assertIn("WOULD APPROVE", publication.stdout)


class Case(GuardHarness):
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
        # Commit-account checks compare the live base to head. They must not
        # trigger the rejected review's separate old-base scope diagnostic.
        self.assertFalse(any(f"/compare/{'f' * 40}..." in path for path in calls))


class ReleaseSecondApprover(GuardHarness):
    """A second release reviewer publishing against a head that already has a
    release approval previously died with `release_run: unbound variable`
    because check_verdict read $release_run before check_current_ci ran."""

    def setUp(self):
        super().setUp()
        # Release policy engages when the PR base branch is release/v*.
        (self.data / "pr.json").write_text(json.dumps({
            "state": "open", "draft": False, "merged": False,
            "base": {"ref": "release/v0.62.0", "sha": BASE},
            "head": {"sha": HEAD, "ref": "release/v0.62.0"},
            "user": {"login": "author-keeper"}}))

    def release_review(self, *, who="reviewer-keeper", run=RELEASE_RUN):
        body = (f"verdict: PASS head: {HEAD} run: {run} by: {who}\nrelease notes\n\n---\n"
                f"review-scope: {RELEASE_SCOPE}\n{release_footer()}")
        return {"id": 77, "state": "APPROVED", "author_association": "COLLABORATOR",
                "body": body, "commit_id": HEAD, "user": {"login": who},
                "submitted_at": "2026-10-22T20:00:00Z"}

    def test_second_release_approver_does_not_hit_unbound_release_run(self):
        # Publish mode (no --merge-check, no --source-receipt): the guard must
        # establish release_run via check_current_ci before parsing the verdict.
        rev = self.release_review()
        (self.data / "review.json").write_text(json.dumps(rev))
        (self.data / "reviews.json").write_text(json.dumps([rev]))
        r = self.run_guard("--check")
        # The guard runs the RC CI read and either admits or refuses by policy;
        # it must never die on an unbound release_run variable.
        self.assertNotIn("release_run: unbound variable", r.stderr)
        self.assertIn(r.returncode, (0, 2), r.stderr)

    def test_second_release_approver_check_only_admits_with_footer(self):
        rev = self.release_review()
        (self.data / "review.json").write_text(json.dumps(rev))
        (self.data / "reviews.json").write_text(json.dumps([rev]))
        (self.data / "user.json").write_text(json.dumps({"login": "second-reviewer"}))
        r = self.run_guard("--check", "--review-base", BASE, "--review-diff", DIFF,
                           "--body", str(self._body_file()))
        self.assertEqual(r.returncode, 0, r.stderr)

    def _body_file(self):
        p = self.tmp / "body.txt"
        p.write_text(f"verdict: PASS head: {HEAD} run: {RELEASE_RUN} by: second-keeper\nrelease notes")
        return p


class SourceReceiptCase(GuardHarness):
    def test_diff_read_failure_is_unavailable_at_initial_and_final_read(self):
        self.review(footer_line())
        for fail_at in (1, 2):
            with self.subTest(fail_at=fail_at):
                counter = self.scripts / "review-diff.calls"
                counter.unlink(missing_ok=True)
                (self.scripts / "review-diff.py").write_text(
                    "import pathlib,sys\n"
                    "p=pathlib.Path(__file__).with_suffix('.calls')\n"
                    "n=int(p.read_text())+1 if p.exists() else 1\n"
                    "p.write_text(str(n))\n"
                    f"sys.exit(1) if n=={fail_at} else print({DIFF!r})\n")
                result = self.run_guard("--source-receipt")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("diff unavailable", result.stderr)
                self.assertEqual(result.stdout, "")

    def pin(self, state):
        (self.data / "status.json").write_text(json.dumps({"statuses": [{
            "context": "leader-selected-ci", "state": state,
            "target_url": "https://ci.example/run/1", "description": "selected check"}]}))

    def test_selection_rechecks_source_while_its_own_ci_pin_remains(self):
        self.review(footer_line())
        for state in ("pending", "failure", "error"):
            with self.subTest(state=state):
                self.pin(state)
                # Exercise the actual selector call into the actual guard,
                # including the runpy-loaded scope reader. No CI is executed.
                code = ("import json,runpy,sys; m=runpy.run_path(sys.argv[1]); "
                        "a=m['source_approval']('o/r',m['Member'](41487,sys.argv[3]),gh=sys.argv[2]); "
                        "print(json.dumps(a.ids))")
                result = subprocess.run(
                    ["python3", "-c", code, str(self.scripts / "prepare-approved-batch.py"),
                     str(self.tmp / "gh"), HEAD],
                    env=dict(os.environ, FAKE_DIR=str(self.data)), capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), [77])
                merge = self.run_guard("--merge-check", "--receipt-json")
                self.assertEqual(merge.returncode, 2)
                self.assertIn("leader-selected CI", merge.stderr)
                self.assertEqual(merge.stdout, "")

    def test_source_receipt_keeps_source_approval_requirements(self):
        self.pin("pending")
        for label, footer, assoc, scope in (
            ("stale diff", footer_line(diff="e" * 64), "COLLABORATOR", SCOPE),
            ("bad footer", footer_line(tail=False), "COLLABORATOR", SCOPE),
            ("untrusted", footer_line(), "CONTRIBUTOR", SCOPE),
            ("scope missing", footer_line(), "COLLABORATOR", None),
        ):
            with self.subTest(label=label):
                self.review(footer, assoc=assoc, scope=scope)
                r = self.run_guard("--source-receipt")
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertEqual(r.stdout, "")
        (self.data / "reviews.json").write_text("[]")
        self.assertEqual(self.run_guard("--source-receipt").returncode, 2)

    def test_source_receipt_refuses_author_approval_and_change_requests(self):
        self.review(footer_line())
        review = json.loads((self.data / "review.json").read_text())
        review["user"]["login"] = "author-keeper"
        (self.data / "review.json").write_text(json.dumps(review))
        (self.data / "reviews.json").write_text(json.dumps([review]))
        self.assertEqual(self.run_guard("--source-receipt").returncode, 2)
        review["user"]["login"] = "reviewer-keeper"
        review["state"] = "CHANGES_REQUESTED"
        (self.data / "reviews.json").write_text(json.dumps([review]))
        r = self.run_guard("--source-receipt")
        self.assertEqual(r.returncode, 2)
        self.assertIn("open CHANGES_REQUESTED", r.stderr)

    def test_source_receipt_refuses_latest_negative_verdict(self):
        self.review(footer_line())
        for verdict in ("FAIL", "HOLD"):
            with self.subTest(verdict=verdict):
                (self.data / "comments.json").write_text(json.dumps([{
                    "id": 88, "body": f"verdict: {verdict} head: {HEAD} by: reviewer-keeper",
                    "user": {"login": "reviewer-keeper"}, "author_association": "COLLABORATOR",
                    "created_at": "2026-10-08T03:45:54Z", "updated_at": "2026-10-08T03:45:54Z"}]))
                r = self.run_guard("--source-receipt")
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn(f"latest structured verdict is {verdict}", r.stderr)

    def test_source_receipt_is_not_a_release_or_publication_mode(self):
        for extra in (["--check"], ["--merge-check"], ["--print-footer"],
                      ["--receipt-json"], ["--body", "b"], ["--run", "1"],
                      ["--replace-own-cr", "7"], ["--review-base", BASE], ["--review-diff", DIFF]):
            with self.subTest(extra=extra):
                r = self.run_guard("--source-receipt", *extra)
                self.assertEqual(r.returncode, 2)
                self.assertEqual(r.stdout, "")
        self.review(footer_line())
        pr = json.loads((self.data / "pr.json").read_text())
        pr["head"]["ref"] = "release/v0.50.0"
        (self.data / "pr.json").write_text(json.dumps(pr))
        r = self.run_guard("--source-receipt")
        self.assertEqual(r.returncode, 2)
        self.assertIn("cannot admit a release", r.stderr)

    def test_source_receipt_refuses_moved_head_or_nonready_pr(self):
        self.review(footer_line())
        path = self.data / "pr.json"
        original = json.loads(path.read_text())
        for change in ({"draft": True}, {"state": "closed"},
                       {"head": {"sha": "a" * 40, "ref": "fix/x"}}):
            with self.subTest(change=change):
                path.write_text(json.dumps(original | change))
                r = self.run_guard("--source-receipt")
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertEqual(r.stdout, "")

    def test_source_receipt_refuses_diff_moving_at_consumption(self):
        self.review(footer_line())
        (self.scripts / "review-diff.py").write_text(
            "import pathlib\n"
            "p=pathlib.Path(__file__).with_suffix('.calls')\n"
            f"print({'e' * 64!r} if p.exists() else {DIFF!r})\n"
            "p.touch()\n")
        r = self.run_guard("--source-receipt")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("complete diff moved during consumption", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_source_receipt_does_not_require_caller_identity_or_write(self):
        self.review(footer_line())
        r = self.run_guard("--source-receipt")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), {"pr": 41487, "head": HEAD, "approval_ids": [77],
                         "scope": {"base_ref": "main", "base_sha": BASE, "stack": None}, "policy": "source"})
        calls = (self.data / "calls.log").read_text().splitlines()
        self.assertNotIn("user", calls)
        self.assertFalse(any("/status" in path for path in calls))


class CheckOnlyCase(GuardHarness):
    def test_source_publication_does_not_wait_for_selected_ci(self):
        body = self.tmp / "body.md"
        body.write_text(f"verdict: PASS head: {HEAD} by: reviewer-keeper\nsource review notes\n")
        for state in ("pending", "failure", "error"):
            with self.subTest(state=state):
                (self.data / "status.json").write_text(json.dumps({"statuses": [{
                    "context": "leader-selected-ci", "state": state,
                    "target_url": "https://ci.example/run/1", "description": "selected check"}]}))
                r = self.run_guard("--check", "--review-base", BASE,
                                   "--review-diff", DIFF, "--body", str(body))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("WOULD APPROVE", r.stdout)
        self.assertNotIn("/status", (self.data / "calls.log").read_text())

    def test_check_refuses_self_approval(self):
        (self.data / "user.json").write_text(json.dumps({"login": "author-keeper"}))
        r = self.run_guard("--check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("the PR author cannot approve their own change", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_check_refuses_malformed_verdict_body_when_supplied(self):
        body = self.tmp / "body.md"
        body.write_text(f"verdict: PASS head: {HEAD} by: reviewer-keeper · source review\n")
        r = self.run_guard("--check", "--body", str(body))
        self.assertEqual(r.returncode, 2)
        self.assertIn("source review requires a runless exact-head verdict", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_check_refuses_when_verdict_by_names_caller_login(self):
        body = self.tmp / "body.md"
        body.write_text(f"verdict: PASS head: {HEAD} by: reviewer-account\nsource review notes\n")
        r = self.run_guard("--check", "--body", str(body))
        self.assertEqual(r.returncode, 2)
        self.assertIn("by must name the reviewing Keeper", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_check_refuses_mismatched_review_diff_when_supplied(self):
        r = self.run_guard("--check", "--review-base", BASE, "--review-diff", "e" * 64)
        self.assertEqual(r.returncode, 2)
        self.assertIn("current complete diff differs from the reviewed change", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_check_passes_with_valid_body_and_diff(self):
        body = self.tmp / "body.md"
        body.write_text(f"verdict: PASS head: {HEAD} by: reviewer-keeper\nsource review notes\n")
        r = self.run_guard("--check", "--review-base", BASE, "--review-diff", DIFF, "--body", str(body))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"WOULD APPROVE #41487 head {HEAD} policy source", r.stdout)


class VerdictWithdrawalCase(GuardHarness):
    def negative_review(self, *, rid=88, state="CHANGES_REQUESTED",
                        login="reviewer-account", submitted="2026-10-08T03:45:54Z"):
        return {"id": rid, "state": state, "author_association": "COLLABORATOR",
                "body": f"verdict: FAIL head: {HEAD} by: reviewer-keeper\nsource findings",
                "commit_id": HEAD, "user": {"login": login}, "submitted_at": submitted}

    def reviews(self, *reviews):
        (self.data / "reviews.json").write_text(json.dumps(reviews))

    def replacement_check(self, *, replace_id="88", diff=DIFF, body_head=HEAD):
        body = self.tmp / "replacement.md"
        body.write_text(f"verdict: PASS head: {body_head} by: reviewer-keeper\nsource review notes\n")
        args = ["--check", "--review-base", BASE, "--review-diff", diff, "--body", str(body)]
        if replace_id is not None:
            args += ["--replace-own-cr", replace_id]
        return self.run_guard(*args)

    def test_dismissed_fail_does_not_block_a_bound_approval(self):
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        self.reviews(approval, self.negative_review(state="DISMISSED", login="withdrawn-reviewer"))
        for mode in ("--source-receipt", "--merge-check"):
            with self.subTest(mode=mode):
                r = self.run_guard(mode)
                self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads((self.data / "comments.json").read_text()), [])

    def test_exact_owned_open_request_can_be_replaced_without_a_pass_comment(self):
        request = self.negative_review()
        self.reviews(request)
        r = self.replacement_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"WOULD APPROVE #41487 head {HEAD} policy source", r.stdout)
        self.assertEqual(json.loads((self.data / "reviews.json").read_text()), [request])
        self.assertEqual(json.loads((self.data / "comments.json").read_text()), [])

    def test_owned_request_requires_an_explicit_replacement(self):
        self.reviews(self.negative_review())
        r = self.replacement_check(replace_id=None)
        self.assertEqual(r.returncode, 2)
        self.assertIn("open CHANGES_REQUESTED", r.stderr)

    def test_same_account_different_keeper_cannot_replace_request(self):
        request = self.negative_review()
        request["body"] = f"verdict: FAIL head: {HEAD} by: other-keeper\nsource findings"
        self.reviews(request)
        result = self.replacement_check()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("signer is unknown or differs", result.stderr)

    def test_unsigned_request_cannot_be_claimed_by_same_account(self):
        request = self.negative_review()
        request["body"] = "Please fix the issue."
        self.reviews(request)
        result = self.replacement_check()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("signer is unknown or differs", result.stderr)

    def test_shared_account_approval_does_not_clear_other_keeper_request(self):
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        approval.update(id=89, submitted_at="2026-10-08T04:00:00Z")
        approval["user"]["login"] = "reviewer-account"
        (self.data / "review.json").write_text(json.dumps(approval))
        request = self.negative_review()
        request["body"] = f"verdict: FAIL head: {HEAD} by: other-keeper\nsource findings"
        self.reviews(request, approval)
        for mode in ("--source-receipt", "--merge-check"):
            result = self.run_guard(mode)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("unresolved change requests", result.stderr)

    def test_source_receipt_uses_submission_order_when_review_ids_are_reversed(self):
        footer = footer_line().replace(" · reviewed base", " · replaces own CHANGES_REQUESTED 90 · reviewed base")
        self.review(footer)
        approval = json.loads((self.data / "review.json").read_text())
        approval.update(id=77, submitted_at="2026-10-10T03:45:54Z")
        approval["user"]["login"] = "reviewer-account"
        (self.data / "review.json").write_text(json.dumps(approval))
        request = self.negative_review(rid=90, submitted="2026-10-08T03:45:54Z")
        request["body"] = f"verdict: FAIL head: {'a' * 40} by: reviewer-keeper\nold-head finding"
        self.reviews(request, approval)
        result = self.run_guard("--source-receipt")
        self.assertEqual(result.returncode, 0, result.stderr)
        request["submitted_at"] = "2026-10-11T03:45:54Z"
        self.reviews(request, approval)
        result = self.run_guard("--source-receipt")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("open CHANGES_REQUESTED", result.stderr)

    def test_old_tied_approvals_do_not_block_a_unique_latest_approval(self):
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        old1 = dict(approval, id=77, submitted_at="2026-10-07T03:45:54Z")
        old2 = dict(approval, id=78, submitted_at="2026-10-07T03:45:54Z")
        latest = dict(approval, id=79, submitted_at="2026-10-08T03:45:54Z")
        self.reviews(old1, old2, latest)
        (self.data / "review.json").write_text(json.dumps(latest))
        for mode in ("--check", "--source-receipt", "--merge-check"):
            with self.subTest(mode=mode):
                result = self.run_guard(mode)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_tied_latest_request_and_approval_still_refuse(self):
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        older = dict(approval, id=77, submitted_at="2026-10-07T03:45:54Z")
        latest = dict(approval, id=79, submitted_at="2026-10-08T03:45:54Z")
        request = self.negative_review(rid=78, login="reviewer-keeper")
        self.reviews(older, request, latest)
        (self.data / "review.json").write_text(json.dumps(latest))
        for mode in ("--check", "--source-receipt"):
            with self.subTest(mode=mode):
                result = self.run_guard(mode)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("ambiguous submission times", result.stderr)

    def test_old_tied_request_stays_open_until_later_explicit_replacement(self):
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        request = self.negative_review(rid=88, login="reviewer-keeper",
                                       submitted="2026-10-07T03:45:54Z")
        tied = dict(approval, id=77, submitted_at="2026-10-07T03:45:54Z")
        tied["body"] = tied["body"].replace(
            " · reviewed base", " · replaces own CHANGES_REQUESTED 88 · reviewed base")
        latest = dict(approval, id=79, submitted_at="2026-10-08T03:45:54Z")
        self.reviews(request, tied, latest)
        (self.data / "review.json").write_text(json.dumps(latest))
        publication = self.run_guard("--check")
        self.assertEqual(publication.returncode, 0, publication.stderr)
        for mode in ("--source-receipt", "--merge-check"):
            with self.subTest(mode=mode):
                result = self.run_guard(mode)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("unresolved change requests (review IDs 88)", result.stderr)
        latest["body"] = latest["body"].replace(
            " · reviewed base", " · replaces own CHANGES_REQUESTED 88 · reviewed base")
        self.reviews(request, tied, latest)
        (self.data / "review.json").write_text(json.dumps(latest))
        result = self.run_guard("--source-receipt")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_replacement_requires_the_signed_body_in_check_mode(self):
        self.reviews(self.negative_review())
        result = self.run_guard("--check", "--replace-own-cr", "88")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("signed review body", result.stderr)

    def test_foreign_or_missing_replacement_id_is_refused(self):
        for request in (self.negative_review(login="another-reviewer"),
                        self.negative_review(rid=89)):
            with self.subTest(request=request):
                self.reviews(request)
                r = self.replacement_check()
                self.assertEqual(r.returncode, 2)
                self.assertIn("does not name this account", r.stderr)
                self.assertEqual(r.stdout, "")

    def test_other_change_requests_do_not_block_recording_an_independent_review(self):
        for head in (HEAD, "a" * 40):
            with self.subTest(head=head):
                request = self.negative_review(login="another-reviewer")
                request["commit_id"] = head
                request["body"] = f"verdict: FAIL head: {head} by: another-keeper"
                self.reviews(request)
                r = self.replacement_check(replace_id=None)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("WOULD APPROVE", r.stdout)
                self.assertIn("remain merge blockers: another-reviewer:88", r.stderr)
                self.assertEqual(json.loads((self.data / "reviews.json").read_text()), [request])

    def install_publication_fake(self):
        # Exercise the real publication and readback path. The fake records
        # APPROVE as a new review; no dismissal operation is implemented.
        post = self.tmp / "post.py"
        post.write_text('''import json, os, pathlib, sys
p = pathlib.Path(os.environ["FAKE_DIR"])
args = sys.argv[1:]
assert args[:3] == ["-X", "POST", "repos/o/r/pulls/41487/reviews"], args
assert "event=APPROVE" in args and "body=@-" in args, args
reviews = json.loads((p / "reviews.json").read_text())
rid = max((r["id"] for r in reviews), default=0) + 1
review = {"id": rid, "state": "APPROVED", "author_association": "COLLABORATOR",
          "body": sys.stdin.read(), "commit_id": next(a.split("=", 1)[1] for a in args if a.startswith("commit_id=")),
          "user": json.loads((p / "user.json").read_text()), "submitted_at": f"2026-10-10T03:45:{rid % 60:02d}Z"}
reviews.append(review)
(p / "reviews.json").write_text(json.dumps(reviews))
(p / f"review-{rid}.json").write_text(json.dumps(review))
with (p / "calls.log").open("a") as calls:
    calls.write("POST " + args[2] + "\\n")
print(f'{rid}\\tAPPROVED\\t{review["commit_id"]}')
''')
        gh = self.tmp / "gh"
        gh.write_text(gh.read_text().replace(
            'shift\n[ "$1" != --paginate ] || shift',
            'shift\nif [ "$1" = -X ]; then exec python3 "' + str(post) + '" "$@"; fi\n'
            '[ "$1" != --paginate ] || shift').replace(
            'repos/*/pulls/*/reviews/*) f="$FAKE_DIR/review.json";;',
            'repos/*/pulls/*/reviews/*) f="$FAKE_DIR/review-${path##*/}.json";;'))

    def publish(self, *replace_ids, keeper="reviewer-keeper"):
        body = self.tmp / "replacement.md"
        body.write_text(f"verdict: PASS head: {HEAD} by: {keeper}\nindependent source review\n")
        args = ["--review-base", BASE, "--review-diff", DIFF, "--body", str(body)]
        for rid in replace_ids:
            args += ["--replace-own-cr", str(rid)]
        return self.run_guard(*args)

    def test_identity_change_after_post_reports_posted_review_for_reconciliation(self):
        self.install_publication_fake()
        changed = {"login": "content-author", "id": 556}
        (self.data / "compare-3.json").write_text(json.dumps([{
            "base_commit": {"sha": BASE}, "total_commits": 1,
            "commits": [{"sha": HEAD, "author": changed, "committer": changed}]}]))
        result = self.publish()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("was posted but account identities changed", result.stderr)
        self.assertEqual(len(json.loads((self.data / "reviews.json").read_text())), 1)
        self.assertEqual(sum(line.startswith("POST ") for line in (self.data / "calls.log").read_text().splitlines()), 1)

    def test_body_with_guard_metadata_is_refused_before_post(self):
        self.install_publication_fake()
        body = self.tmp / "body.md"
        for marker in (f"review-scope: {SCOPE}", footer_line(),
                       f"notes\rreview-scope: {SCOPE}",
                       f"notes\u2028review-scope: {SCOPE}"):
            for check in (False, True):
                with self.subTest(marker=marker, check=check):
                    body.write_text(f"verdict: PASS head: {HEAD} by: reviewer-keeper\n"
                                    f"independent source review\n{marker}\n")
                    args = ["--review-base", BASE, "--review-diff", DIFF, "--body", str(body)]
                    if check:
                        args.append("--check")
                    result = self.run_guard(*args)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("guard adds", result.stderr)
                    self.assertNotIn("POST", (self.data / "calls.log").read_text())

    def test_publication_scope_is_accepted_by_source_receipt(self):
        self.install_publication_fake()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        review = json.loads((self.data / "reviews.json").read_text())[0]
        self.assertEqual(sum(line.startswith("review-scope: ") for line in review["body"].splitlines()), 1)
        receipt = self.run_guard("--source-receipt")
        self.assertEqual(receipt.returncode, 0, receipt.stderr)
        self.assertEqual(json.loads(receipt.stdout)["approval_ids"], [review["id"]])

    def test_duplicate_scope_in_post_readback_does_not_report_success(self):
        self.install_publication_fake()
        post = self.tmp / "post.py"
        tamper = ("review['body'] = review['body'].replace("
                  "'\\nreview-scope: ', " + repr("\nreview-scope: " + SCOPE + "\nreview-scope: ") + ", 1)\n")
        post.write_text(post.read_text().replace("reviews.append(review)\n", tamper + "reviews.append(review)\n"))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("APPROVED #41487", result.stdout)
        self.assertIn("posted", result.stderr)
        self.assertIn("scope", result.stderr)
        self.assertIn("before retry", result.stderr)
        self.assertIn("POST repos/o/r/pulls/41487/reviews", (self.data / "calls.log").read_text())
        receipt = self.run_guard("--source-receipt")
        self.assertEqual(receipt.returncode, 2, receipt.stderr)

    def test_publication_does_not_report_success_for_a_different_actor(self):
        self.install_publication_fake()
        post = self.tmp / "post.py"
        post.write_text(post.read_text().replace(
            "reviews.append(review)\n", "review['user'] = {'login': 'other-account'}\nreviews.append(review)\n"))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("APPROVED #41487", result.stdout)
        self.assertIn("other-account", result.stderr)
        self.assertIn("reviewer-account", result.stderr)
        self.assertIn("before retry", result.stderr)
        self.assertIn("POST repos/o/r/pulls/41487/reviews", (self.data / "calls.log").read_text())

    def test_malformed_author_readback_reports_that_review_was_posted(self):
        self.install_publication_fake()
        post = self.tmp / "post.py"
        post.write_text(post.read_text().replace(
            "reviews.append(review)\n", "review['user'] = 'corrupt'\nreviews.append(review)\n"))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("APPROVED #41487", result.stdout)
        self.assertIn("was posted", result.stderr)
        self.assertIn("author could not be read", result.stderr)
        self.assertIn("before retry", result.stderr)

    def test_pr_moving_after_publication_does_not_report_success(self):
        self.install_publication_fake()
        post = self.tmp / "post.py"
        move = ("pr = json.loads((p / 'pr.json').read_text())\n"
                "pr['head']['sha'] = 'a' * 40\n"
                "(p / 'pr.json').write_text(json.dumps(pr))\n")
        post.write_text(post.read_text().replace("reviews.append(review)\n", move + "reviews.append(review)\n"))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("APPROVED #41487", result.stdout)
        self.assertIn("posted", result.stderr)
        self.assertIn("before retry", result.stderr)
        self.assertEqual(json.loads((self.data / "reviews.json").read_text())[0]["commit_id"], HEAD)

    def test_lost_publication_response_requires_inspection_before_retry(self):
        self.install_publication_fake()
        post = self.tmp / "post.py"
        post.write_text(post.read_text().replace(
            "print(f'{rid}\\tAPPROVED\\t{review[\"commit_id\"]}')", "sys.exit(9)"))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("APPROVED #41487", result.stdout)
        self.assertIn("outcome is unknown", result.stderr)
        self.assertIn("before retry", result.stderr)
        reviews = json.loads((self.data / "reviews.json").read_text())
        self.assertEqual(len(reviews), 1)  # Fake accepted the write before losing the reply.
        self.assertEqual(self.run_guard("--source-receipt").returncode, 0)

    def test_two_reviewers_can_replace_their_crs_without_dismissing_each_other(self):
        self.reviews(self.negative_review(), self.negative_review(rid=89, login="another-reviewer"))
        self.install_publication_fake()
        def approve(rid):
            return self.publish(rid)

        first = approve(88)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("APPROVED #41487", first.stdout)
        for mode in ("--merge-check", "--source-receipt"):
            blocked = self.run_guard(mode)
            self.assertEqual(blocked.returncode, 2, blocked.stderr)
            self.assertIn("open CHANGES_REQUESTED from another-reviewer", blocked.stderr)

        (self.data / "user.json").write_text(json.dumps({"login": "another-reviewer"}))
        second = approve(89)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("APPROVED #41487", second.stdout)
        for mode in ("--merge-check", "--source-receipt"):
            admitted = self.run_guard(mode)
            self.assertEqual(admitted.returncode, 0, admitted.stderr)
        reviews = json.loads((self.data / "reviews.json").read_text())
        self.assertEqual([r["state"] for r in reviews],
                         ["CHANGES_REQUESTED", "CHANGES_REQUESTED", "APPROVED", "APPROVED"])
        calls = (self.data / "calls.log").read_text()
        self.assertEqual(calls.count("POST repos/o/r/pulls/41487/reviews"), 2)
        self.assertNotIn("dismiss", calls)

    def test_shared_account_keepers_replace_their_requests_separately(self):
        first_request = self.negative_review()
        second_request = self.negative_review(rid=89, submitted="2026-10-09T03:45:54Z")
        second_request["body"] = second_request["body"].replace(
            "by: reviewer-keeper", "by: other-keeper")
        self.reviews(first_request, second_request)
        self.install_publication_fake()

        first = self.publish(88)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("APPROVED #41487", first.stdout)
        for mode in ("--source-receipt", "--merge-check"):
            blocked = self.run_guard(mode)
            self.assertEqual(blocked.returncode, 2, blocked.stderr)
            # A later stack layer may reject the same current-head review first
            # as a structured FAIL; either diagnostic must identify request 89.
            self.assertTrue(
                "unresolved change requests (review IDs 89)" in blocked.stderr
                or "unresolved FAIL by reviewer-account at review:89" in blocked.stderr,
                blocked.stderr,
            )

        second = self.publish(89, keeper="other-keeper")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("APPROVED #41487", second.stdout)
        self.assertNotIn("SKIP", second.stdout)
        for mode in ("--source-receipt", "--merge-check"):
            admitted = self.run_guard(mode)
            self.assertEqual(admitted.returncode, 0, admitted.stderr)
        reviews = json.loads((self.data / "reviews.json").read_text())
        self.assertEqual([r["state"] for r in reviews],
                         ["CHANGES_REQUESTED", "CHANGES_REQUESTED", "APPROVED", "APPROVED"])
        self.assertIn("replaces own CHANGES_REQUESTED 88", reviews[2]["body"])
        self.assertIn("replaces own CHANGES_REQUESTED 89", reviews[3]["body"])
        calls = (self.data / "calls.log").read_text()
        self.assertEqual(calls.count("POST repos/o/r/pulls/41487/reviews"), 2)
        self.assertNotIn("dismiss", calls)

    def test_shared_account_stale_request_remains_until_its_owner_replaces_it(self):
        stale = self.negative_review(rid=89, submitted="2026-10-09T03:45:54Z")
        stale["commit_id"] = "a" * 40
        stale["body"] = (f"verdict: FAIL head: {'a' * 40} by: other-keeper\nsource findings")
        self.reviews(self.negative_review(), stale)
        self.install_publication_fake()

        first = self.publish(88)
        self.assertEqual(first.returncode, 0, first.stderr)
        receipt = self.run_guard("--source-receipt")
        self.assertEqual(receipt.returncode, 2, receipt.stderr)
        self.assertIn("unresolved change requests (review IDs 89)", receipt.stderr)
        wrong_owner = self.publish(89)
        self.assertEqual(wrong_owner.returncode, 2, wrong_owner.stderr)
        self.assertIn("signer is unknown or differs", wrong_owner.stderr)
        second = self.publish(89, keeper="other-keeper")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("APPROVED #41487", second.stdout)
        receipt = self.run_guard("--source-receipt")
        self.assertEqual(receipt.returncode, 0, receipt.stderr)

    def test_older_request_is_replaced_after_same_account_approval(self):
        request = self.negative_review()
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        approval.update(id=89, submitted_at="2026-10-09T03:45:54Z")
        approval["user"]["login"] = "reviewer-account"
        approval["body"] = approval["body"].replace("by: reviewer-keeper", "by: other-keeper")
        self.reviews(request, approval)
        (self.data / "review-89.json").write_text(json.dumps(approval))
        self.install_publication_fake()

        result = self.publish(88)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("APPROVED #41487", result.stdout)
        self.assertNotIn("SKIP", result.stdout)
        reviews = json.loads((self.data / "reviews.json").read_text())
        self.assertIn("replaces own CHANGES_REQUESTED 88", reviews[-1]["body"])
        receipt = self.run_guard("--source-receipt")
        self.assertEqual(receipt.returncode, 0, receipt.stderr)

    def test_unsigned_same_account_request_stays_blocked_after_owned_replacement(self):
        unsigned = self.negative_review(rid=89, submitted="2026-10-09T03:45:54Z")
        unsigned["body"] = "Please fix this"
        self.reviews(self.negative_review(), unsigned)
        self.install_publication_fake()

        first = self.publish(88)
        self.assertEqual(first.returncode, 0, first.stderr)
        receipt = self.run_guard("--source-receipt")
        self.assertEqual(receipt.returncode, 2, receipt.stderr)
        self.assertIn("unresolved change requests (review IDs 89)", receipt.stderr)
        claim = self.publish(89)
        self.assertEqual(claim.returncode, 2, claim.stderr)
        self.assertIn("signer is unknown or differs", claim.stderr)

    def test_recording_a_new_review_does_not_clear_a_different_reviewers_findings(self):
        for login in ("reviewer-account", "another-reviewer"):
            with self.subTest(login=login):
                self.reviews(self.negative_review(), self.negative_review(
                    rid=89, state="COMMENTED", login=login, submitted="2026-10-09T03:45:54Z"))
                self.install_publication_fake()
                r = self.replacement_check()
                self.assertEqual(r.returncode, 0, r.stderr)
                published = self.publish(88)
                self.assertEqual(published.returncode, 0, published.stderr)
                merged = self.run_guard("--merge-check")
                self.assertEqual(merged.returncode, 0 if login == "reviewer-account" else 2, merged.stderr)
                if login != "reviewer-account":
                    self.assertIn("structured verdict is FAIL", merged.stderr)

    def test_edited_fail_comment_can_be_superseded_by_its_authors_new_publication(self):
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        self.reviews(approval, self.negative_review())
        # Creation predates PASS; the negative edit must still outrank it.
        (self.data / "comments.json").write_text(json.dumps([{
            "id": 88, "body": f"verdict: FAIL head: {HEAD} by: reviewer-keeper",
            "user": {"login": "reviewer-account"}, "author_association": "COLLABORATOR",
            "created_at": "2026-10-06T03:45:54Z", "updated_at": "2026-10-09T03:45:54Z"}]))
        r = self.replacement_check()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_multiple_own_crs_can_be_replaced_by_a_new_bound_approval(self):
        self.install_publication_fake()
        for ids in ((88,), (89,), (88, 89)):
            with self.subTest(ids=ids):
                self.reviews(self.negative_review(), self.negative_review(
                    rid=89, submitted="2026-10-09T03:45:54Z"))
                published = self.publish(*ids)
                if len(ids) == 1:
                    self.assertEqual(published.returncode, 2, published.stderr)
                    self.assertIn("unresolved change requests", published.stderr)
                    continue
                self.assertEqual(published.returncode, 0, published.stderr)
                for mode in ("--merge-check", "--source-receipt"):
                    result = self.run_guard(mode)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_replacement_id_must_belong_to_the_authenticated_reviewer(self):
        self.reviews(self.negative_review(), self.negative_review(rid=89, login="someone-else"))
        self.install_publication_fake()
        result = self.publish(88, 89)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("--replace-own-cr 89 does not name this account", result.stderr)
        self.assertNotIn("POST", (self.data / "calls.log").read_text())

    def test_new_review_can_supersede_own_fail_comment_without_cr(self):
        self.install_publication_fake()
        (self.data / "comments.json").write_text(json.dumps([{
            "id": 88, "body": f"verdict: FAIL head: {HEAD} by: reviewer-keeper",
            "user": {"login": "reviewer-account"}, "author_association": "COLLABORATOR",
            "created_at": "2026-10-08T03:45:54Z", "updated_at": "2026-10-08T03:45:54Z"}]))
        published = self.publish()
        self.assertEqual(published.returncode, 0, published.stderr)
        self.assertEqual(self.run_guard("--merge-check").returncode, 0)

    def test_prior_own_approval_does_not_skip_a_new_verdict_after_own_fail(self):
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        approval["user"]["login"] = "reviewer-account"
        self.reviews(approval)
        (self.data / "review-77.json").write_text(json.dumps(approval))
        (self.data / "comments.json").write_text(json.dumps([{
            "id": 88, "body": f"verdict: FAIL head: {HEAD} by: reviewer-keeper",
            "user": {"login": "reviewer-account"}, "author_association": "COLLABORATOR",
            "created_at": "2026-10-08T03:45:54Z", "updated_at": "2026-10-08T03:45:54Z"}]))
        self.install_publication_fake()
        self.assertEqual(self.run_guard("--merge-check").returncode, 2)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("APPROVED #41487", result.stdout)
        self.assertEqual(self.run_guard("--merge-check").returncode, 0)
        # Once the new account-owned PASS is effective, identical publication
        # remains idempotent and does not create another formal review.
        repeated = self.publish()
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertIn("SKIP #41487", repeated.stdout)
        self.assertEqual((self.data / "calls.log").read_text().count("POST "), 1)

    def test_replacement_requires_one_numeric_id_per_option(self):
        for invalid in ("88 89", "88\n89", "0", "88x"):
            with self.subTest(invalid=invalid):
                result = self.replacement_check(replace_id=invalid)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse((self.data / "calls.log").exists())

    def test_unrelated_and_author_pass_cannot_clear_another_reviewers_hold(self):
        self.review(footer_line())
        hold = {"id": 88, "body": f"verdict: HOLD head: {HEAD} by: held-keeper",
                "user": {"login": "held-account"}, "author_association": "COLLABORATOR",
                "created_at": "2026-10-08T03:45:54Z", "updated_at": "2026-10-08T03:45:54Z"}
        for actor in ("author-keeper", "reviewer-keeper", "someone-else"):
            with self.subTest(actor=actor):
                passed = {"id": 89, "body": f"verdict: PASS head: {HEAD} by: held-keeper",
                          "user": {"login": actor}, "author_association": "COLLABORATOR",
                          "created_at": "2026-10-09T03:45:54Z", "updated_at": "2026-10-09T03:45:54Z"}
                (self.data / "comments.json").write_text(json.dumps([hold, passed]))
                for mode in ("--merge-check", "--source-receipt"):
                    result = self.run_guard(mode)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("structured verdict is HOLD", result.stderr)
                    self.assertIn("held-account", result.stderr)

    def test_merge_pin_refusal_preserves_the_actual_run_link(self):
        self.review(footer_line())
        (self.data / "status.json").write_text(json.dumps({"statuses": [{
            "context": "leader-selected-ci", "state": "pending",
            "target_url": "https://ci.example/run/1", "description": "selected check"}]}))
        result = self.run_guard("--merge-check")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("https://ci.example/run/1", result.stderr)

    def test_dismissing_a_review_does_not_withdraw_its_matching_issue_comment(self):
        self.review(footer_line())
        approval = json.loads((self.data / "review.json").read_text())
        self.reviews(approval, self.negative_review(state="DISMISSED"))
        (self.data / "comments.json").write_text(json.dumps([{
            "id": 88, "body": f"verdict: FAIL head: {HEAD} by: reviewer-keeper",
            "user": {"login": "reviewer-account"}, "author_association": "COLLABORATOR",
            "created_at": "2026-10-08T03:45:54Z", "updated_at": "2026-10-08T03:45:54Z"}]))
        r = self.run_guard("--source-receipt")
        self.assertEqual(r.returncode, 2)
        self.assertIn("latest structured verdict is FAIL", r.stderr)

    def test_replacement_does_not_relax_reviewed_diff_or_body_binding(self):
        self.reviews(self.negative_review())
        for kwargs, reason in (({"diff": "e" * 64}, "current complete diff differs"),
                               ({"body_head": "a" * 40}, "verdict names another head")):
            with self.subTest(kwargs=kwargs):
                r = self.replacement_check(**kwargs)
                self.assertEqual(r.returncode, 2)
                self.assertIn(reason, r.stderr)

    def test_replacement_never_authorizes_merge_or_source_receipt(self):
        self.reviews(self.negative_review())
        for mode in ("--merge-check", "--source-receipt"):
            with self.subTest(mode=mode):
                r = self.run_guard(mode, "--replace-own-cr", "88")
                self.assertEqual(r.returncode, 2)
                self.assertEqual(r.stdout, "")

    def test_replacement_still_refuses_unreadable_comments(self):
        self.reviews(self.negative_review())
        (self.data / "comments.json").unlink()
        r = self.replacement_check()
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("approve-guard: verdict read failed", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_replacement_still_refuses_failed_review_read_after_validation(self):
        self.reviews(self.negative_review())
        gh = self.tmp / "gh"
        gh.write_text(gh.read_text().replace(
            '  repos/*/pulls/*/reviews*) f="$FAKE_DIR/reviews.json"; reviews_collection=1;;',
            '''  repos/*/pulls/*/reviews*)
    [ ! -f "$FAKE_DIR/reviews-already-read" ] || exit 7
    touch "$FAKE_DIR/reviews-already-read"
    f="$FAKE_DIR/reviews.json"; reviews_collection=1;;'''))
        r = self.replacement_check()
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("approve-guard: verdict read failed", r.stderr)
        self.assertEqual(r.stdout, "")


class QueueAdmissionDiagnosticCase(GuardHarness):
    def test_unstructured_formal_cr_names_the_actor_and_record(self):
        shutil.copy(HERE / "queue-ledger.sh", self.scripts / "queue-ledger.sh")
        request = {"id": 88, "state": "CHANGES_REQUESTED",
                   "body": "Please fix the unresolved finding.",
                   "user": {"login": "blocked-reviewer"},
                   "submitted_at": "2026-10-08T03:45:54Z"}
        (self.data / "reviews.json").write_text(json.dumps([request]))
        gh = self.tmp / "gh"
        gh.write_text(gh.read_text().replace('shift\n',
            f'if [ "$1" = pr ]; then printf "41487\\tauthor-keeper\\tmain\\t{HEAD}\\tfix/x\\tfalse\\n"; exit 0; fi\nshift\n', 1))
        result = subprocess.run(
            ["bash", str(self.scripts / "queue-ledger.sh"), "--repo", "o/r"],
            env=dict(os.environ, LEDGER_GH=str(gh), FAKE_DIR=str(self.data)),
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("open CHANGES_REQUESTED from blocked-reviewer (review 88)", result.stdout)


class PrintFooterCase(GuardHarness):
    def setUp(self):
        super().setUp()
        # Same fixture the diff helper returns; the expected footer must name it.
        self.expected = (f"approve-guard: head `{HEAD}` · source review · "
                         f"reviewed base `{BASE}` · diff sha256 `{DIFF}`")

    def test_print_footer_outputs_exact_tail_for_live_pr(self):
        r = self.run_guard("--print-footer")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, self.expected + "\n")
        self.assertEqual(r.stderr, "")

    def test_print_footer_names_release_policy_for_release_branch(self):
        pr = json.loads((self.data / "pr.json").read_text())
        pr["head"]["ref"] = "release/v0.50.0"
        (self.data / "pr.json").write_text(json.dumps(pr))
        r = self.run_guard("--print-footer")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(" · release review · ", r.stdout)

    def test_print_footer_refuses_when_pr_is_not_on_head(self):
        pr = json.loads((self.data / "pr.json").read_text())
        pr["head"]["sha"] = "a" * 40
        (self.data / "pr.json").write_text(json.dumps(pr))
        r = self.run_guard("--print-footer")
        self.assertEqual(r.returncode, 2)
        self.assertIn("require open, ready PR on exact head", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_print_footer_refuses_mutation_flags(self):
        for extra in (["--check"], ["--merge-check"], ["--receipt-json"],
                      ["--body", "b"], ["--run", "1"], ["--replace-own-cr", "7"],
                      ["--review-base", BASE], ["--review-diff", DIFF]):
            with self.subTest(extra=extra):
                r = self.run_guard("--print-footer", *extra)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertEqual(r.stdout, "")


if __name__ == "__main__":
    unittest.main()
