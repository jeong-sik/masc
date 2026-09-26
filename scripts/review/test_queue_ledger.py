#!/usr/bin/env python3
"""Exercise the read-only ledger with real local Git history and fake GitHub."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(os.environ.get("LEDGER_TEST_SCRIPT", ROOT / "scripts/review/queue-ledger.sh"))
RUN_TIME = "2026-01-01T00:30:00Z"


class QueueLedgerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="queue-ledger-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.remote = self.root / "remote.git"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        # Fixtures are independent of the operator's global hooks and signing.
        self.git("config", "core.hooksPath", str(self.root / "empty-hooks"))
        self.git("config", "commit.gpgSign", "false")
        self.git("config", "user.name", "Ledger fixture")
        self.git("config", "user.email", "ledger@example.invalid")
        self.write("lib/example.ml", "let value = 1\n")
        self.write("docs/example.md", "A document.\n")
        self.write("masc.opam.locked", "version: 1\n")
        self.commit("base", "2026-01-01T00:00:00Z")
        self.base = self.git("rev-parse", "HEAD")
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True)
        self.git("remote", "add", "origin", str(self.remote))
        self.make_pr("lib/example.ml")
        self.fixtures = self.root / "fixtures.json"
        self.fake = self.root / "gh"
        jq = shutil.which("jq")
        self.assertIsNotNone(jq, "fixture harness requires jq, as gh uses --jq")
        self.fake.write_text("""#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
query = args[args.index('--jq') + 1]
fixtures = json.load(open(os.environ['LEDGER_FIXTURES']))
if args[:2] == ['pr', 'list']:
    key = 'prs'
elif args[0] == 'api':
    endpoint = next(a for a in args[1:] if a.startswith('repos/'))
    if endpoint.endswith('/reviews'): key = 'reviews'
    elif endpoint.endswith('/comments'): key = 'comments'
    elif '/actions/runs?' in endpoint: key = 'runs'
    elif endpoint.endswith('/jobs'): key = 'jobs'
    elif '/actions/runs/' in endpoint: key = 'run'
    else: raise SystemExit('unexpected endpoint: ' + endpoint)
else: raise SystemExit('read-only fixture refuses: ' + repr(args))
if key == fixtures.get('fail'): raise SystemExit('injected read failure')
result = subprocess.run([os.environ['LEDGER_JQ'], '-r', query],
    input=json.dumps(fixtures[key]), text=True)
raise SystemExit(result.returncode)
""")
        self.fake.chmod(0o755)
        self.env = dict(os.environ, LEDGER_GH=str(self.fake),
                        LEDGER_FIXTURES=str(self.fixtures), LEDGER_JQ=jq)

    def git(self, *args, env=None):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              text=True, capture_output=True, env=env).stdout.strip()

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message, date):
        self.git("add", ".")
        self.git("commit", "-qm", message,
                 env=dict(os.environ, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date))

    def make_pr(self, path):
        self.git("checkout", "-q", "-B", "fixture-pr", self.base)
        self.write(path, "let value = 2\n" if path.endswith(".ml") else "Updated document.\n")
        self.commit("PR", "2026-01-01T00:10:00Z")
        self.head = self.git("rev-parse", "HEAD")
        self.path = path
        self.git("push", "-q", "--force", "origin", "HEAD:refs/pull/1/head")
        self.git("checkout", "-q", "main")
        self.git("push", "-q", "origin", "main")

    def main_change(self, path, date="2026-01-01T01:00:00Z"):
        self.write(path, "Updated main input.\n")
        self.commit("main change", date)
        self.git("push", "-q", "origin", "main")

    def verdict(self, state="PASS", head=None):
        return f"verdict: {state} head: {head or self.head} run: 900 by: reviewer"

    def message(self, body, time="2026-01-01T00:40:00Z", **fields):
        return dict(body=body, created_at=time, submitted_at=time,
                    user={"login": "review-account"}, state="COMMENTED", **fields)

    def ledger(self, comments=None, reviews=None, fail=None):
        data = {
            "prs": [{"number": 1, "author": {"login": "author"}, "baseRefName": "main",
                     "headRefOid": self.head, "headRefName": "fixture-pr", "isDraft": False,
                     "createdAt": "2026-01-01T00:10:00Z", "files": [{"path": self.path}],
                     "statusCheckRollup": [{"name": "dune build @check",
                                            "conclusion": "SUCCESS", "startedAt": RUN_TIME}]}],
            "comments": comments if comments is not None else [self.message(self.verdict())],
            "reviews": reviews or [],
            "runs": {"workflow_runs": [{"created_at": RUN_TIME, "conclusion": "success"}]},
            "run": {"head_sha": self.head, "status": "completed", "conclusion": "success"},
            "jobs": {"jobs": [{"conclusion": "success"}]}, "fail": fail,
        }
        self.fixtures.write_text(json.dumps(data))
        result = subprocess.run(["bash", str(SCRIPT), "--git-dir", str(self.repo), "--repo", "o/r"],
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().splitlines()
        self.assertEqual(len(lines), 2, result.stdout)
        return dict(zip(lines[0].split("\t"), lines[1].split("\t")))

    def test_valid_pass_and_other_head_hold(self):
        row = self.ledger(reviews=[self.message(self.verdict("HOLD", "a" * 40),
                                               "2026-01-01T00:50:00Z")])
        self.assertEqual(row["waits_on"], "merge")

    def test_later_review_hold_replaces_comment_pass(self):
        row = self.ledger(reviews=[self.message(self.verdict("HOLD"), "2026-01-01T00:50:00Z")])
        self.assertEqual((row["waits_on"], row["verdict"]), ("review", "HOLD"))

    def test_later_comment_invalidates_review_pass(self):
        for first_line, verdict in [(self.verdict("COMMENT"), "COMMENT"),
                                    (f"verdict: COMMENT head: {self.head}", "COMMENT"),
                                    (f"verdict: PASS head: {self.head}", "INVALID"),
                                    (f"verdict: FAIL (P1) head: {self.head} run: 900 by: reviewer", "INVALID"),
                                    (f"verdict: PASS extra head: {self.head} run: 900 by: reviewer", "INVALID"),
                                    (self.verdict().replace("verdict: PASS", "verdict:  PASS"), "INVALID"),
                                    (self.verdict("UNRECOGNIZED"), "UNKNOWN"),
                                    (self.verdict() + " trailing text", "INVALID")]:
            with self.subTest(first_line=first_line):
                row = self.ledger(comments=[self.message(first_line, "2026-01-01T00:50:00Z")],
                                  reviews=[self.message(self.verdict())])
                self.assertEqual((row["waits_on"], row["verdict"]), ("review", verdict))

    def test_annotated_commented_failure_replaces_pass(self):
        row = self.ledger(reviews=[self.message(
            f"verdict: FAIL (P1) head: {self.head} run: 900 by: reviewer",
            "2026-01-01T00:50:00Z")])
        self.assertEqual((row["waits_on"], row["verdict"]), ("review", "INVALID"))

    def test_edit_and_same_timestamp_cannot_hide_hold(self):
        row = self.ledger(comments=[self.message(self.verdict("HOLD"),
                                                "2026-01-01T00:20:00Z",
                                                updated_at="2026-01-01T00:50:00Z")],
                          reviews=[self.message(self.verdict())])
        self.assertEqual(row["verdict"], "HOLD")
        row = self.ledger(reviews=[self.message(self.verdict("HOLD"))])
        self.assertEqual(row["verdict"], "HOLD")

    def test_new_pass_after_hold_counts(self):
        row = self.ledger(comments=[self.message(self.verdict("HOLD"))],
                          reviews=[self.message(self.verdict(), "2026-01-01T00:50:00Z")])
        self.assertEqual(row["waits_on"], "merge")

    def test_shared_pin_invalidates_ocaml_run_without_direct_overlap(self):
        self.main_change("masc.opam.locked")
        row = self.ledger()
        self.assertEqual(row["waits_on"], "dependency:masc.opam.locked")
        self.assertEqual(row["stale_files"], "0")

    def test_workflow_consumed_action_is_dependency(self):
        self.main_change(".github/actions/install-ocaml-deps/install.sh")
        self.assertEqual(self.ledger()["waits_on"],
                         "dependency:.github/actions/install-ocaml-deps/install.sh")

    def test_root_dune_policy_invalidates_ocaml_run(self):
        self.main_change("dune")
        self.assertEqual(self.ledger()["waits_on"], "dependency:dune")

    def test_root_dune_workspace_invalidates_ocaml_run(self):
        self.main_change("dune-workspace")
        self.assertEqual(self.ledger()["waits_on"], "dependency:dune-workspace")

    def test_docs_only_does_not_inherit_ocaml_pin_dependency(self):
        self.make_pr("docs/example.md")
        self.main_change("masc.opam.locked")
        self.assertEqual(self.ledger()["waits_on"], "merge")

    def test_dependency_before_run_and_unrelated_main_change(self):
        self.main_change("masc.opam.locked", "2026-01-01T00:20:00Z")
        self.main_change("docs/unrelated.md")
        self.assertEqual(self.ledger()["waits_on"], "merge")

    def test_direct_overlap_and_read_failure_still_block(self):
        self.assertEqual(self.ledger(fail="comments")["waits_on"], "unknown:verdict")
        self.main_change("lib/example.ml")
        self.assertEqual(self.ledger()["waits_on"], "stale:1")


if __name__ == "__main__":
    unittest.main()
