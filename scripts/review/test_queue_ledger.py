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
query = args[args.index('--jq') + 1] if '--jq' in args else '.'
fixtures = json.load(open(os.environ['LEDGER_FIXTURES']))
if args[:2] == ['pr', 'list']:
    key = 'prs'
elif args[0] == 'api':
    endpoint = next(a for a in args[1:] if a.startswith('repos/'))
    if '/check-suites/' in endpoint: key = 'suite'
    elif '/check-runs?' in endpoint: key = 'checks'
    elif endpoint.endswith('/commits/main'): key = 'main'
    elif '/files?' in endpoint: key = 'files'
    elif endpoint.endswith('/pulls/1'): key = 'pull'
    elif endpoint.endswith('/reviews'): key = 'reviews'
    elif endpoint.endswith('/comments'): key = 'comments'
    elif '/actions/runs?' in endpoint: key = 'runs'
    elif endpoint.endswith('/jobs'): key = 'jobs'
    elif '/actions/runs/' in endpoint: key = 'run'
    else: raise SystemExit('unexpected endpoint: ' + endpoint)
else: raise SystemExit('read-only fixture refuses: ' + repr(args))
if key == fixtures.get('fail'): raise SystemExit('injected read failure')
if key == 'main' and 'main_after_read' in fixtures:
    old = fixtures['main']
    fixtures['main'] = fixtures.pop('main_after_read')
    json.dump(fixtures, open(os.environ['LEDGER_FIXTURES'], 'w'))
    print(json.dumps(old)); raise SystemExit(0)
if key == 'files' and 'files_pages' in fixtures:
    for page in fixtures['files_pages']: print(json.dumps(page))
    raise SystemExit(0)
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
                    author_association=fields.pop("author_association", "COLLABORATOR"),
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
            "runs": {"workflow_runs": [{"id":900,"run_number":10,"head_sha":self.head,
                      "event":"pull_request","path":".github/workflows/pr-check.yml",
                      "created_at": RUN_TIME, "conclusion": "success"}]},
            "run": {"id": 900, "head_sha": self.head, "status": "completed", "conclusion": "success",
                    "created_at": RUN_TIME, "event": "pull_request", "path": ".github/workflows/pr-check.yml", "pull_requests": [{"number": 1}]},
            "pull": {"state": "open", "draft": False, "merged": False,
                     "head": {"sha": self.head}, "base": {"ref": "main"}, "changed_files": 1},
            "main": {"sha": self.git("rev-parse", "main")}, "files": [{"filename": self.path}],
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

    def test_outsider_or_unknown_pass_cannot_clear_trusted_hold(self):
        for association in ["NONE", "CONTRIBUTOR", "UNKNOWN", None]:
            with self.subTest(association=association):
                row = self.ledger(
                    reviews=[self.message(self.verdict()), self.message(
                        self.verdict("HOLD"), "2026-01-01T00:45:00Z")],
                    comments=[self.message(self.verdict(), "2026-01-01T00:50:00Z",
                                           author_association=association)])
                self.assertEqual((row["waits_on"], row["verdict"]), ("review", "UNTRUSTED by reviewer"))

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

    def test_selected_test_runner_is_a_build_evidence_dependency(self):
        self.main_change("scripts/ci/run-edited-tests.sh")
        self.assertEqual(self.ledger()["waits_on"], "dependency:scripts/ci/run-edited-tests.sh")

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

    def test_stale_queue_reports_refresh_before_any_verdict(self):
        self.main_change(self.path)
        row = self.ledger(comments=[], reviews=[])
        self.assertEqual(row["waits_on"], "stale:1")

    def test_contained_main_commit_at_run_second_is_not_stale(self):
        self.main_change(self.path, RUN_TIME)
        self.git("checkout", "-q", "fixture-pr")
        self.git("merge", "--no-edit", "-s", "ours", "main")
        self.head = self.git("rev-parse", "HEAD")
        self.assertEqual(self.ledger()["waits_on"], "merge")

    def test_dashboard_only_shared_workflow_and_lint_driver_changes_refuse(self):
        self.make_pr("dashboard/src/fixture.ts")
        for path in [".github/workflows/pr-check.yml", "scripts/ci/run-lint-suite.sh",
                     "scripts/ci/run-edited-tests.sh", "scripts/review/ci-freshness.py"]:
            with self.subTest(path=path):
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual(code, 2)
                self.assertEqual(receipt["dependencies"], [path])
                self.assertEqual(receipt["commits"][0]["reason"], "post_run_overlap")

    def test_dashboard_only_keeps_proven_ocaml_dependency_scope(self):
        self.make_pr("dashboard/src/fixture.ts")
        self.main_change("masc.opam.locked")
        self.assertEqual(self.ledger()["waits_on"], "merge")

    def test_dependency_before_run_and_unrelated_main_change(self):
        self.main_change("masc.opam.locked", "2026-01-01T00:20:00Z")
        code, receipt = self.freshness()
        self.assertEqual(code, 2)
        self.assertEqual(receipt["commits"][0]["reason"], "graph_overlap_unverified_tested_base")
        self.git("checkout", "-q", "fixture-pr")
        self.git("merge", "--no-edit", "main")
        self.head = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "main")
        self.main_change("docs/unrelated.md")
        self.assertEqual(self.ledger()["waits_on"], "merge")

    def test_direct_overlap_and_read_failure_still_block(self):
        self.assertEqual(self.ledger(fail="comments")["waits_on"], "unknown:verdict")
        self.main_change("lib/example.ml")
        self.assertEqual(self.ledger()["waits_on"], "stale:1")

    def test_distinct_add_only_dune_includes_still_require_new_run(self):
        registrations = "(test (name first))\n" + "; separate registrations\n" * 8 + "(test (name last))\n"
        self.write("test/dune", registrations)
        self.commit("base test registration", "2026-01-01T00:05:00Z")
        self.base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "-B", "fixture-pr", self.base)
        self.write("test/dune", registrations.replace("(name first))", "(name first))\n(include backend.inc)"))
        self.commit("PR include", "2026-01-01T00:10:00Z")
        self.head, self.path = self.git("rev-parse", "HEAD"), "test/dune"
        self.git("checkout", "-q", "main")
        self.write("test/dune", registrations + "(include asset-worker.inc)\n")
        self.commit("main include", "2026-01-01T01:00:00Z")
        # The historical exemption would admit this exact clean, add-only shape.
        self.git("merge-tree", "--write-tree", self.head, "main")
        for revision in (self.head, "main"):
            delta = self.git("diff", self.base, revision, "--", "test/dune")
            self.assertFalse(any(line.startswith("-") and not line.startswith("---")
                                 for line in delta.splitlines()))
        self.git("push", "-q", "origin", "main")
        self.assertEqual(self.ledger()["waits_on"], "stale:1")

    def freshness(self, mutate=lambda data: None):
        self.ledger()  # write the same API fixture used by the real ledger
        data = json.loads(self.fixtures.read_text())
        mutate(data)
        self.fixtures.write_text(json.dumps(data))
        result = subprocess.run(["python3", str(SCRIPT.with_name("ci-freshness.py")),
                                 "--repo", "o/r", "--pr", "1", "--head", self.head,
                                 "--run", "900", "--git-dir", str(self.repo)],
                                env=dict(self.env, GUARD_GH=str(self.fake)), text=True,
                                capture_output=True, timeout=20)
        return result.returncode, json.loads(result.stdout)

    def test_created_at_not_delayed_job_or_rerun_start(self):
        self.main_change("lib/example.ml")
        code, receipt = self.freshness(lambda d: d["run"].update(
            run_started_at="2026-01-01T02:00:00Z"))
        self.assertEqual(code, 2)
        self.assertEqual(receipt["created_at"], RUN_TIME)
        self.assertEqual(receipt["overlap"], ["lib/example.ml"])

    def test_merge_commit_cannot_hide_paths(self):
        self.git("checkout", "-qb", "later")
        self.write("lib/example.ml", "let value = 3\n")
        self.commit("old side commit", "2026-01-01T00:20:00Z")
        self.git("checkout", "-q", "main")
        self.git("merge", "--no-ff", "-m", "main integration", "later",
                 env=dict(os.environ, GIT_AUTHOR_DATE="2026-01-01T01:00:00Z",
                          GIT_COMMITTER_DATE="2026-01-01T01:00:00Z"))
        self.git("push", "-q", "origin", "main")
        code, receipt = self.freshness()
        self.assertEqual(code, 2)
        self.assertEqual(receipt["commits"][0]["sha"], self.git("rev-parse", "main"))

    def test_unavailable_or_wrong_run_cannot_grant_freshness(self):
        for mutation in [lambda d: d.update(fail="main"),
                         lambda d: d["run"].pop("created_at"),
                         lambda d: d["run"].update(event="workflow_dispatch"),
                         lambda d: d["run"].update(pull_requests=[{"number": 2}]),
                         lambda d: d["run"].update(path=".github/workflows/test.yml"),
                         lambda d: d["pull"].update(changed_files=101),
                         lambda d: d["pull"].update(state="closed")]:
            with self.subTest(mutation=mutation):
                code, receipt = self.freshness(mutation)
                self.assertEqual((code, receipt["status"]), (1, "unavailable"))

    def test_mutable_association_head_and_base_are_not_checkout_evidence(self):
        code, receipt = self.freshness(lambda d: d["run"].update(pull_requests=[{
            "number": 1, "head": {"sha": "a" * 40}, "base": {"sha": "b" * 40}}]))
        self.assertEqual((code, receipt["status"]), (0, "fresh"))

    def test_missing_association_requires_matching_suite_and_branch(self):
        def linkage(d):
            d["pull"]["head"]["ref"] = "fixture-pr"
            d["run"].update(pull_requests=[], head_branch="fixture-pr", check_suite_id=123)
            d["suite"] = {"head_sha": self.head}
            d["checks"] = {"check_runs": [{"head_sha": self.head, "check_suite": {"id": 123}}]}
        self.assertEqual(self.freshness(linkage)[0], 0)
        def wrong(d):
            linkage(d)
            d["checks"]["check_runs"][0]["check_suite"]["id"] = 456
        self.assertEqual(self.freshness(wrong)[0], 1)

    def test_main_move_during_read_refuses(self):
        code, receipt = self.freshness(lambda d: d.update(main_after_read={"sha": self.head}))
        self.assertEqual(code, 1)
        self.assertEqual(receipt["reason"], "pr_or_main_moved_during_check")

    def mark_shallow(self, identity):
        # This is Git's real shallow boundary file, not a mocked graph answer.
        path = Path(self.git("rev-parse", "--git-path", "shallow"))
        if not path.is_absolute():
            path = self.repo / path
        path.write_text(identity + "\n")
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository"), "true")

    def test_old_shallow_boundary_below_known_common_ancestor_is_allowed(self):
        old_root = self.base
        self.write("docs/common.md", "shared ancestor\n")
        self.commit("recent common ancestor", "2026-01-01T00:05:00Z")
        self.base = self.git("rev-parse", "HEAD")
        self.make_pr("lib/example.ml")
        self.main_change("docs/unrelated.md")
        self.mark_shallow(old_root)
        code, receipt = self.freshness()
        self.assertEqual((code, receipt["status"]), (0, "fresh"))
        self.assertEqual(receipt["comparison_ancestor"], self.base)

    def test_shallow_boundary_inside_required_main_suffix_refuses(self):
        self.main_change("docs/unrelated.md")
        missing_boundary = self.git("rev-parse", "main")
        self.main_change("docs/another.md", "2026-01-01T01:10:00Z")
        self.mark_shallow(missing_boundary)
        code, receipt = self.freshness()
        self.assertEqual((code, receipt["status"]), (1, "unavailable"))
        self.assertEqual(receipt["reason"], "required_main_history_unavailable")

    def test_common_ancestor_at_shallow_boundary_is_sufficient(self):
        self.main_change("lib/example.ml")
        self.mark_shallow(self.base)
        code, receipt = self.freshness()
        self.assertEqual((code, receipt["status"]), (2, "stale"))
        self.assertEqual(receipt["comparison_ancestor"], self.base)
        self.assertEqual(receipt["overlap"], ["lib/example.ml"])

    def test_all_api_file_pages_are_read(self):
        self.main_change("second.ml")
        def pages(d):
            d["pull"]["changed_files"] = 2
            d["files_pages"] = [[{"filename": self.path}], [{"filename": "second.ml"}]]
        code, receipt = self.freshness(pages)
        self.assertEqual(code, 2)
        self.assertEqual(receipt["overlap"], ["second.ml"])

    def test_rename_previous_path_is_not_lost(self):
        self.main_change("lib/old.ml")
        code, receipt = self.freshness(lambda d: d["files"][0].update(
            previous_filename="lib/old.ml"))
        self.assertEqual(code, 2)
        self.assertIn("lib/old.ml", receipt["overlap"])


if __name__ == "__main__":
    unittest.main()
