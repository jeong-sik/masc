#!/usr/bin/env python3
"""Exercise queue reporting using native GitHub review records, offline."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
HEAD = "a" * 40


class QueueLedgerCase(unittest.TestCase):
    def run_queue(self, records, output_format="tsv", *, current_base="main", status_error=False,
                  branch="fix/example"):
        with tempfile.TemporaryDirectory(prefix="review-ledger-") as directory:
            root = Path(directory)
            (root / "reviews.json").write_text(json.dumps(records))
            (root / "pr.json").write_text(json.dumps({
                "number": 7, "user": {"login": "author", "id": 1},
                "state": "open", "draft": False, "merged": False,
                "base": {"ref": current_base, "sha": "b" * 40},
                "head": {"ref": branch, "sha": HEAD}, "stack": None,
            }))
            fake = root / "gh"
            fake.write_text('''#!/usr/bin/env bash
set -eu
if [ "$1" = pr ]; then
  printf '7\\tauthor\\tmain\\t%s\\t%s\\tfalse\\n' "$LEDGER_TEST_HEAD" "$LEDGER_BRANCH"
  exit 0
fi
shift
slurp=0
if [ "$1" = --paginate ]; then shift; fi
if [ "$1" = --slurp ]; then slurp=1; shift; fi
path="$1"; shift
case "$path" in
  */pulls/*/reviews) [ "$slurp" = 0 ] || { jq -s '.' "$LEDGER_TEST_ROOT/reviews.json"; exit; }
                     cat "$LEDGER_TEST_ROOT/reviews.json";;
  */pulls/*) if [ "${1:-}" = --jq ]; then jq -r "$2" "$LEDGER_TEST_ROOT/pr.json"; else cat "$LEDGER_TEST_ROOT/pr.json"; fi;;
  */commits/*/status) [ "$LEDGER_STATUS_ERROR" = 0 ] || exit 9;;
  *) echo "unexpected API: $path" >&2; exit 9;;
esac
''')
            fake.chmod(0o755)
            env = dict(os.environ, LEDGER_GH=str(fake), LEDGER_TEST_HEAD=HEAD,
                       LEDGER_TEST_ROOT=str(root), LEDGER_STATUS_ERROR=str(int(status_error)),
                       LEDGER_BRANCH=branch)
            return subprocess.run(
                ["bash", str(HERE / "queue-ledger.sh"), "--repo", "o/r",
                 "--format", output_format], env=env, text=True,
                capture_output=True, check=True)

    @staticmethod
    def review(rid, login, uid, state, minute, body=""):
        return {"id": rid, "user": {"login": login, "id": uid},
                "state": state, "author_association": "COLLABORATOR",
                "body": body, "commit_id": HEAD,
                "submitted_at": f"2026-10-26T10:{minute:02d}:00Z"}

    def test_other_accounts_change_requests_remain_after_plain_approval(self):
        reviews = [self.review(1, "reviewer-a", 2, "CHANGES_REQUESTED", 1),
                   self.review(2, "reviewer-b", 3, "CHANGES_REQUESTED", 2),
                   self.review(3, "reviewer-c", 4, "APPROVED", 3, "Looks good")]
        for output_format in ("tsv", "md"):
            with self.subTest(output_format=output_format):
                result = self.run_queue(reviews, output_format)
                self.assertIn("open CHANGES_REQUESTED from reviewer-a (review 1)", result.stdout)
                self.assertIn("open CHANGES_REQUESTED from reviewer-b (review 2)", result.stdout)
                self.assertIn("APPROVED 3", result.stdout)

    def test_later_same_account_plain_approval_supersedes_request(self):
        reviews = [self.review(1, "reviewer-a", 2, "CHANGES_REQUESTED", 1),
                   self.review(2, "reviewer-a", 2, "APPROVED", 2)]
        result = self.run_queue(reviews)
        self.assertIn("\tmerge\t", result.stdout)
        self.assertIn("APPROVED 2", result.stdout)
        self.assertNotIn("CHANGES_REQUESTED", result.stdout)

    def test_changed_base_is_not_reported_as_merge_ready(self):
        result = self.run_queue([self.review(1, "reviewer", 2, "APPROVED", 1)],
                                current_base="feature/parent")
        self.assertIn("unknown:PR base or branch changed during read", result.stdout)
        self.assertNotIn("\tmerge\t", result.stdout)

    def test_failed_ci_read_is_reported_as_unknown(self):
        result = self.run_queue([self.review(1, "reviewer", 2, "APPROVED", 1)],
                                status_error=True, branch="release/v1.0.0")
        self.assertIn("unknown:CI or PR read failed", result.stdout)


if __name__ == "__main__":
    unittest.main()
