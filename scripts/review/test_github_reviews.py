#!/usr/bin/env python3
"""Exercise native review evidence and the paginated gh boundary."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("github_reviews", HERE / "github-reviews.py")
reviews = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reviews)
HEAD = "a" * 40
OLD_HEAD = "b" * 40
T1 = "2026-10-08T03:45:54Z"
T2 = "2026-10-09T03:45:54Z"
T3 = "2026-10-10T03:45:54Z"


def pr():
    return {"number": 42, "user": {"id": 1, "login": "author"}, "head": {"sha": HEAD}}


def review(rid, state="APPROVED", *, account=2, login="reviewer", when=T1, commit=HEAD):
    return {"id": rid, "state": state, "submitted_at": when, "commit_id": commit,
            "user": {"id": account, "login": login}, "body": "",
            "author_association": "COLLABORATOR"}


class ReviewEvaluationCases(unittest.TestCase):
    def evaluate(self, rows):
        return reviews.evaluate(pr(), rows, head=HEAD)

    def test_plain_approvals_accept_empty_or_missing_body(self):
        without_body = review(11, account=3, login="other")
        del without_body["body"]
        actual = self.evaluate([review(10), without_body])
        self.assertEqual(actual, {"pr": 42, "head": HEAD, "approval_ids": [10, 11],
                                  "change_requests": [], "superseded_change_requests": [],
                                  "ambiguous_review_ids": [],
                                  "provenance": "github_review_commit_id"})

    def test_approval_counts_for_any_or_missing_association(self):
        owner = review(10, account=2, login="owner") | {"author_association": "OWNER"}
        member = review(11, account=3, login="member") | {"author_association": "MEMBER"}
        collaborator = review(12, account=4, login="collaborator")
        outsider = review(13, account=5, login="outsider") | {"author_association": "CONTRIBUTOR"}
        missing = review(14, account=6, login="missing")
        del missing["author_association"]
        actual = self.evaluate([owner, member, collaborator, outsider, missing])
        self.assertEqual(actual["approval_ids"], [10, 11, 12, 13, 14])

    def test_other_account_change_request_is_not_hidden(self):
        outsider = review(11, "CHANGES_REQUESTED", account=3, login="outsider")
        outsider["author_association"] = "NONE"
        actual = self.evaluate([review(10), outsider])
        self.assertEqual(actual["approval_ids"], [10])
        self.assertEqual(actual["change_requests"], [{"id": 11, "login": "outsider"}])

    def test_old_head_and_pr_author_are_not_approvals(self):
        rows = [review(10, commit=OLD_HEAD), review(11, account=1, login="author")]
        self.assertEqual(self.evaluate(rows)["approval_ids"], [])

    def test_same_account_later_change_request_supersedes_approval(self):
        rows = [review(90), review(30, "CHANGES_REQUESTED", when=T2, commit=OLD_HEAD)]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [])
        self.assertEqual(actual["change_requests"], [{"id": 30, "login": "reviewer"}])

    def test_same_account_later_approval_supersedes_change_request(self):
        rows = [review(90, "CHANGES_REQUESTED"), review(30, when=T2)]
        actual = self.evaluate(list(reversed(rows)))
        self.assertEqual(actual["approval_ids"], [30])
        self.assertEqual(actual["change_requests"], [])
        self.assertEqual(actual["superseded_change_requests"], [{"id": 90, "login": "reviewer"}])

    def test_multiple_superseded_requests_are_preserved_per_account(self):
        rows = [review(10, "CHANGES_REQUESTED"), review(11, "CHANGES_REQUESTED", when=T2),
                review(12, when=T3), review(13, "CHANGES_REQUESTED", account=3, login="other")]
        actual = self.evaluate(list(reversed(rows)))
        self.assertEqual(actual["approval_ids"], [12])
        self.assertEqual(actual["change_requests"], [{"id": 13, "login": "other"}])
        self.assertEqual(actual["superseded_change_requests"], [{"id": 10, "login": "reviewer"},
                                                                 {"id": 11, "login": "reviewer"}])

    def test_new_request_does_not_erase_previously_superseded_request(self):
        rows = [review(10, "CHANGES_REQUESTED"), review(11, when=T2),
                review(12, "CHANGES_REQUESTED", when=T3)]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [])
        self.assertEqual(actual["change_requests"], [{"id": 12, "login": "reviewer"}])
        self.assertEqual(actual["superseded_change_requests"], [{"id": 10, "login": "reviewer"}])

    def test_equal_older_times_do_not_prove_a_request_was_superseded(self):
        rows = [review(10, "CHANGES_REQUESTED"), review(11),
                review(12, "CHANGES_REQUESTED", when=T2)]
        actual = self.evaluate(rows)
        self.assertEqual(actual["change_requests"], [{"id": 12, "login": "reviewer"}])
        self.assertEqual(actual["superseded_change_requests"], [])

    def test_superseded_history_does_not_imply_approval_on_current_head(self):
        old_request = review(10, "CHANGES_REQUESTED")
        latest = review(11, when=T2, commit=OLD_HEAD)
        actual = self.evaluate([old_request, latest])
        self.assertEqual(actual["approval_ids"], [])
        self.assertEqual(actual["superseded_change_requests"], [{"id": 10, "login": "reviewer"}])

    def test_only_latest_approval_yields_superseded_history(self):
        for state in ("CHANGES_REQUESTED", "DISMISSED"):
            with self.subTest(state=state):
                actual = self.evaluate([review(10, "CHANGES_REQUESTED"), review(11, state, when=T2)])
                self.assertEqual(actual["superseded_change_requests"], [])

    def test_other_account_request_remains_and_author_request_is_visible(self):
        rows = [review(10), review(11, "CHANGES_REQUESTED", account=1, login="author"),
                review(12, "CHANGES_REQUESTED", account=3, login="another")]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [10])
        self.assertEqual(actual["change_requests"], [{"id": 11, "login": "author"},
                                                     {"id": 12, "login": "another"}])

    def test_comment_and_unsubmitted_review_do_not_replace_formal_state(self):
        rows = [review(10, "CHANGES_REQUESTED"), review(11, "COMMENTED", when=T2),
                {"id": 12, "state": "PENDING"}]
        self.assertEqual(self.evaluate(rows)["change_requests"], [{"id": 10, "login": "reviewer"}])
        rows[0] = review(10)
        self.assertEqual(self.evaluate(rows)["approval_ids"], [10])

    def test_latest_dismissed_review_clears_formal_state(self):
        rows = [review(10), review(11, "DISMISSED", when=T2)]
        self.assertEqual(self.evaluate(rows)["approval_ids"], [])
        rows[0] = review(10, "CHANGES_REQUESTED")
        self.assertEqual(self.evaluate(rows)["change_requests"], [])

    def test_dismissed_then_new_approval_counts(self):
        rows = [review(10, "DISMISSED"), review(11, when=T2)]
        self.assertEqual(self.evaluate(rows)["approval_ids"], [11])

    def test_inconsistent_history_is_not_silently_accepted(self):
        cases = [
            [review(10), review(10, "COMMENTED", when=T2)],
            [review(10, when=None)],
            [review(10, when="2026-10-08T03:45:54")],
            [review(10, commit="not-a-sha")],
            [{"id": 10, "state": "UNRECOGNIZED"}],
            [{"id": 10, "state": "APPROVED", "user": {"login": "reviewer"},
              "submitted_at": T1, "commit_id": HEAD}],
        ]
        for rows in cases:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.evaluate(rows)

    def test_only_conflicting_tie_at_latest_time_is_ambiguous(self):
        rows = [review(10), review(11, "CHANGES_REQUESTED"), review(12, when=T3)]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [12])
        self.assertEqual(actual["ambiguous_review_ids"], [])
        rows[0]["submitted_at"] = T3
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [10, 12])
        self.assertEqual(actual["ambiguous_review_ids"], [])
        rows[1]["submitted_at"] = T3
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [])
        self.assertEqual(actual["ambiguous_review_ids"], [10, 11, 12])
        self.assertEqual(actual["change_requests"], [{"id": 11, "login": "reviewer"}])

    def test_conflicting_same_time_preserves_other_account_approval_and_request(self):
        rows = [review(10), review(11, "CHANGES_REQUESTED"),
                review(12, account=3, login="other")]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [12])
        self.assertEqual(actual["ambiguous_review_ids"], [10, 11])
        self.assertEqual(actual["change_requests"], [{"id": 11, "login": "reviewer"}])

    def test_tied_approvals_on_different_heads_are_ambiguous(self):
        rows = [review(10), review(11, commit=OLD_HEAD)]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [])
        self.assertEqual(actual["ambiguous_review_ids"], [10, 11])
        self.assertEqual(actual["change_requests"], [])

    def test_equivalent_instants_with_different_timezones_are_tied(self):
        rows = [review(10), review(11, when="2026-10-08T12:45:54+09:00")]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [10, 11])
        self.assertEqual(actual["ambiguous_review_ids"], [])

    def test_tied_requests_preserve_every_possible_request(self):
        rows = [review(10, "CHANGES_REQUESTED"),
                review(11, "CHANGES_REQUESTED", commit=OLD_HEAD)]
        actual = self.evaluate(rows)
        self.assertEqual(actual["ambiguous_review_ids"], [10, 11])
        self.assertEqual(actual["change_requests"], [{"id": 10, "login": "reviewer"},
                                                     {"id": 11, "login": "reviewer"}])

    def test_equivalent_tied_requests_and_dismissals_are_not_ambiguous(self):
        for state in ("CHANGES_REQUESTED", "DISMISSED"):
            with self.subTest(state=state):
                actual = self.evaluate([review(10, state), review(11, state)])
                self.assertEqual(actual["ambiguous_review_ids"], [])
                expected = ([{"id": 10, "login": "reviewer"}, {"id": 11, "login": "reviewer"}]
                            if state == "CHANGES_REQUESTED" else [])
                self.assertEqual(actual["change_requests"], expected)

    def test_account_id_tracks_login_change(self):
        rows = [review(90, "CHANGES_REQUESTED", login="old"),
                review(30, login="new", when=T2)]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [30])
        self.assertEqual(actual["change_requests"], [])
        self.assertEqual(actual["superseded_change_requests"], [{"id": 90, "login": "old"}])

    def test_distinct_account_ids_do_not_collapse_to_a_login(self):
        rows = [review(10), review(11, "CHANGES_REQUESTED", account=3, when=T2)]
        actual = self.evaluate(rows)
        self.assertEqual(actual["approval_ids"], [10])
        self.assertEqual(actual["change_requests"], [{"id": 11, "login": "reviewer"}])

    def test_changed_pr_head_is_refused(self):
        snapshot = pr()
        snapshot["head"]["sha"] = OLD_HEAD
        with self.assertRaises(reviews.Refused):
            reviews.evaluate(snapshot, [review(10)], head=HEAD)


FAKE_GH = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

fixture = json.loads(Path(os.environ["FAKE_GH_FIXTURE"]).read_text())
log = Path(os.environ["FAKE_GH_LOG"])
calls = json.loads(log.read_text()) if log.exists() else []
args = sys.argv[1:]
calls.append(args)
log.write_text(json.dumps(calls))
if args == ["api", "repos/example/project/pulls/42"]:
    count = sum(call == args for call in calls)
    if fixture.get("fail_pr") == count:
        print("PR read failed", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(fixture["after"] if count > 1 and "after" in fixture else fixture["pr"]))
elif args == ["api", "--paginate", "--slurp", "repos/example/project/pulls/42/reviews"]:
    if fixture.get("fail_reviews"):
        print("reviews read failed", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(fixture["pages"]))
else:
    print("unexpected invocation", file=sys.stderr)
    sys.exit(1)
'''


class GhCliCases(unittest.TestCase):
    def run_cli(self, fixture):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "gh"
            fake.write_text(FAKE_GH)
            fake.chmod(0o755)
            fixture_path = root / "fixture.json"
            fixture_path.write_text(json.dumps(fixture))
            log = root / "calls.json"
            env = dict(os.environ, FAKE_GH_FIXTURE=str(fixture_path), FAKE_GH_LOG=str(log))
            result = subprocess.run([sys.executable, str(HERE / "github-reviews.py"),
                                     "--repo", "example/project", "--pr", "42", "--head", HEAD,
                                     "--gh", str(fake)], capture_output=True, text=True, env=env)
            return result, json.loads(log.read_text()) if log.exists() else []

    def test_paginated_plain_approval_reads_all_pages(self):
        fixture = {"pr": pr(), "pages": [[review(90, "CHANGES_REQUESTED")],
                                          [review(30, when=T2)]]}
        result, calls = self.run_cli(fixture)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads(result.stdout)
        self.assertEqual(actual["approval_ids"], [30])
        self.assertEqual(actual["change_requests"], [])
        self.assertEqual(actual["superseded_change_requests"], [{"id": 90, "login": "reviewer"}])
        self.assertEqual(calls, [["api", "repos/example/project/pulls/42"],
                                 ["api", "--paginate", "--slurp", "repos/example/project/pulls/42/reviews"],
                                 ["api", "repos/example/project/pulls/42"]])

    def test_unmet_conditions_are_exit_2_with_evidence(self):
        for rows in ([review(10, commit=OLD_HEAD)], [review(10, account=1, login="author")],
                     [review(10), review(11, "CHANGES_REQUESTED", account=3, login="other")]):
            with self.subTest(rows=rows):
                result, _ = self.run_cli({"pr": pr(), "pages": [rows]})
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("approval_ids", json.loads(result.stdout))

    def test_contributor_approval_counts(self):
        outsider = review(10) | {"author_association": "NONE"}
        result, _ = self.run_cli({"pr": pr(), "pages": [[outsider]]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["approval_ids"], [10])

    def test_missing_approval_association_still_counts(self):
        row = review(10)
        del row["author_association"]
        result, _ = self.run_cli({"pr": pr(), "pages": [[row]]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["approval_ids"], [10])

    def test_failed_reads_and_malformed_pages_are_exit_1(self):
        for extra in ({"fail_pr": 1}, {"fail_reviews": True}, {"fail_pr": 2}, {"pages": [None]}):
            with self.subTest(extra=extra):
                fixture = {"pr": pr(), "pages": [[review(10)]]} | extra
                result, _ = self.run_cli(fixture)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr)

    def test_duplicate_page_records_are_errors(self):
        result, _ = self.run_cli({"pr": pr(), "pages": [[review(10)], [review(10)]]})
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_tied_same_head_approvals_across_pages_are_accepted(self):
        result, _ = self.run_cli({"pr": pr(), "pages": [[review(10)], [review(11)]]})
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads(result.stdout)
        self.assertEqual(actual["approval_ids"], [10, 11])
        self.assertEqual(actual["ambiguous_review_ids"], [])

    def test_tied_approval_and_change_request_are_reported(self):
        pages = [[review(10)], [review(11, "CHANGES_REQUESTED"),
                                review(12, account=3, login="other")]]
        result, _ = self.run_cli({"pr": pr(), "pages": pages})
        self.assertEqual(result.returncode, 2, result.stderr)
        actual = json.loads(result.stdout)
        self.assertEqual(actual["approval_ids"], [12])
        self.assertEqual(actual["ambiguous_review_ids"], [10, 11])
        self.assertEqual(actual["change_requests"], [{"id": 11, "login": "reviewer"}])

    def test_ambiguity_without_request_does_not_block_other_account_approval(self):
        pages = [[review(10), review(11, "DISMISSED")],
                 [review(12, account=3, login="other")]]
        result, _ = self.run_cli({"pr": pr(), "pages": pages})
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads(result.stdout)
        self.assertEqual(actual["approval_ids"], [12])
        self.assertEqual(actual["ambiguous_review_ids"], [10, 11])
        self.assertEqual(actual["change_requests"], [])

    def test_head_changed_during_reads_is_refused(self):
        after = copy.deepcopy(pr())
        after["head"]["sha"] = OLD_HEAD
        result, _ = self.run_cli({"pr": pr(), "after": after, "pages": [[review(10)]]})
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("changed", result.stderr)


if __name__ == "__main__":
    unittest.main()
