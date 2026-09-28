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
        self.next_message_id = 0
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
    if endpoint in fixtures.get('endpoints', {}):
        result = subprocess.run([os.environ['LEDGER_JQ'], '-r', query],
            input=json.dumps(fixtures['endpoints'][endpoint]), text=True)
        raise SystemExit(result.returncode)
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
        self.next_message_id += 1
        return dict(body=body, created_at=time, submitted_at=time,
                    id=fields.pop("id", self.next_message_id),
                    author_association=fields.pop("author_association", "COLLABORATOR"),
                    user={"login": "review-account"},
                    state=fields.pop("state", "COMMENTED"), **fields)

    def approval(self, head=None, time="2026-01-01T00:55:00Z", **fields):
        return self.message("LGTM", time, state="APPROVED",
                            commit_id=head or self.head, **fields)

    def ledger(self, comments=None, reviews=None, fail=None, mutate=lambda data: None,
               git_dir=None, row_count=1):
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
                      "created_at": RUN_TIME, "conclusion": "success",
                      "head_branch": "fixture-pr", "pull_requests": [{"number": 1}]}]},
            "run": {"id": 900, "head_sha": self.head, "status": "completed", "conclusion": "success",
                    "created_at": RUN_TIME, "event": "pull_request", "path": ".github/workflows/pr-check.yml", "head_branch": "fixture-pr",
                    "pull_requests": [{"number": 1}]},
            "pull": {"state": "open", "draft": False, "merged": False,
                     "head": {"sha": self.head, "ref": "fixture-pr"}, "base": {"ref": "main"}, "changed_files": 1},
            "main": {"sha": self.git("rev-parse", "main")}, "files": [{"filename": self.path}],
            "jobs": {"jobs": [{"conclusion": "success"}]}, "fail": fail,
        }
        mutate(data)
        self.fixtures.write_text(json.dumps(data))
        result = subprocess.run(["bash", str(SCRIPT), "--git-dir", str(git_dir or self.repo), "--repo", "o/r"],
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().splitlines()
        self.assertEqual(len(lines), row_count + 1, result.stdout)
        rows = [dict(zip(lines[0].split("\t"), line.split("\t"))) for line in lines[1:]]
        return rows[0] if row_count == 1 else rows

    def record_git_fetches(self):
        real_git = shutil.which("git")
        wrapper_dir = self.root / "bin"
        wrapper_dir.mkdir()
        log = self.root / "fetches.jsonl"
        wrapper = wrapper_dir / "git"
        wrapper.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if 'fetch' in args:
    with open(os.environ['LEDGER_FETCH_LOG'], 'a') as log:
        log.write(json.dumps(args[args.index('fetch') + 1:]) + '\\n')
os.execv(os.environ['LEDGER_REAL_GIT'], [os.environ['LEDGER_REAL_GIT'], *args])
""")
        wrapper.chmod(0o755)
        self.env.update(PATH=str(wrapper_dir) + os.pathsep + self.env["PATH"],
                        LEDGER_REAL_GIT=real_git, LEDGER_FETCH_LOG=str(log))
        return log

    def clone_only_main(self):
        clone = self.root / "main-only"
        subprocess.run(["git", "clone", "-q", "--no-local", "--single-branch",
                        "--branch", "main", str(self.remote), str(clone)], check=True)
        missing = subprocess.run(["git", "-C", str(clone), "cat-file", "-e",
                                  self.head + "^{commit}"], capture_output=True)
        self.assertNotEqual(missing.returncode, 0, "fixture must start without the PR head")
        return clone

    def test_missing_pr_heads_are_fetched_in_one_batch_before_rows(self):
        self.git("checkout", "-qb", "second-pr", self.base)
        self.write("lib/second.ml", "let second = 2\n")
        self.commit("second PR", "2026-01-01T00:11:00Z")
        second_head = self.git("rev-parse", "HEAD")
        self.git("push", "-q", "origin", "HEAD:refs/pull/2/head")
        self.git("checkout", "-q", "main")
        clone = self.clone_only_main()
        missing = subprocess.run(["git", "-C", str(clone), "cat-file", "-e",
                                  second_head + "^{commit}"], capture_output=True)
        self.assertNotEqual(missing.returncode, 0)
        log = self.record_git_fetches()

        def add_second_pr(data):
            second = json.loads(json.dumps(data))
            second["prs"][0].update(number=2, headRefOid=second_head,
                                    headRefName="second-pr", files=[{"path": "lib/second.ml"}])
            second["pull"]["head"].update(sha=second_head, ref="second-pr")
            second["files"] = [{"filename": "lib/second.ml"}]
            for run in [second["run"], *second["runs"]["workflow_runs"]]:
                run.update(id=901, head_sha=second_head, head_branch="second-pr",
                           pull_requests=[{"number": 2}])
            second["comments"][0]["body"] = self.verdict(head=second_head).replace("run: 900", "run: 901")
            second["reviews"] = [self.approval(head=second_head)]
            data["prs"].extend(second["prs"])
            data["endpoints"] = {
                "repos/o/r/pulls/2": second["pull"],
                "repos/o/r/pulls/2/files?per_page=100": second["files"],
                "repos/o/r/pulls/2/reviews": second["reviews"],
                "repos/o/r/issues/2/comments": second["comments"],
                f"repos/o/r/actions/runs?head_sha={second_head}&event=pull_request&per_page=100": second["runs"],
                "repos/o/r/actions/runs/901": second["run"],
                "repos/o/r/actions/runs/901/jobs": second["jobs"],
            }

        rows = self.ledger(reviews=[self.approval()], mutate=add_second_pr,
                           git_dir=clone, row_count=2)
        self.assertEqual([(row["pr"], row["waits_on"]) for row in rows],
                         [("1", "merge"), ("2", "merge")])
        fetches = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(fetches), 2, fetches)  # main, then all missing PR heads
        self.assertEqual(fetches[0][-2:], ["origin", "main"])
        self.assertEqual(fetches[1][-3:],
                         ["origin", "refs/pull/1/head", "refs/pull/2/head"])

    def test_present_heads_and_empty_queue_need_no_pr_fetch(self):
        log = self.record_git_fetches()
        self.assertEqual(self.ledger()["waits_on"], "review")
        self.assertEqual(self.ledger(mutate=lambda data: data.update(prs=[]), row_count=0), [])
        fetches = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual([args[-2:] for args in fetches], [["origin", "main"]] * 2)

    def test_standalone_freshness_still_fetches_missing_head(self):
        self.ledger()  # prepare API fixtures before observing standalone fetches
        clone = self.clone_only_main()
        log = self.record_git_fetches()
        result = subprocess.run(["python3", str(SCRIPT.with_name("ci-freshness.py")),
                                 "--repo", "o/r", "--pr", "1", "--head", self.head,
                                 "--run", "900", "--git-dir", str(clone)],
                                env=dict(self.env, GUARD_GH=str(self.fake)), text=True,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)["status"], "fresh")
        fetches = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual([args[-2:] for args in fetches], [["origin", self.head]])

    def test_failed_batch_does_not_print_partial_queue_or_retry_each_head(self):
        self.ledger()  # prepare fixtures; remove only the fixture server's PR ref
        clone = self.clone_only_main()
        subprocess.run(["git", "--git-dir", str(self.remote), "update-ref", "-d",
                        "refs/pull/1/head"], check=True)
        log = self.record_git_fetches()
        result = subprocess.run(["bash", str(SCRIPT), "--git-dir", str(clone),
                                 "--repo", "o/r"], env=self.env, text=True,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("git fetch PR heads failed", result.stderr)
        self.assertEqual(result.stdout, "")
        fetches = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual([args[-2:] for args in fetches],
                         [["origin", "main"], ["origin", "refs/pull/1/head"]])

    def test_valid_pass_and_other_head_hold(self):
        row = self.ledger(reviews=[self.message(self.verdict("HOLD", "a" * 40),
                                               "2026-01-01T00:50:00Z"),
                                   self.approval()])
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
                          reviews=[self.message(self.verdict(), "2026-01-01T00:50:00Z"),
                                   self.approval()])
        self.assertEqual(row["waits_on"], "merge")

    def test_edit_of_older_pass_does_not_replace_later_refusal(self):
        for state in ["HOLD", "FAIL"]:
            with self.subTest(state=state):
                old_pass = self.message(self.verdict(), "2026-01-01T00:40:00Z",
                                        updated_at="2026-01-01T00:59:00Z")
                refusal = self.message(self.verdict(state), "2026-01-01T00:50:00Z")
                for messages in [[old_pass, refusal], [refusal, old_pass]]:
                    row = self.ledger(comments=messages, reviews=[self.approval()])
                    self.assertEqual((row["waits_on"], row["verdict"]),
                                     ("review", "FAIL by reviewer" if state == "FAIL" else state))

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

    def test_docs_only_requires_unconditional_ocaml_build_inputs(self):
        self.make_pr("docs/example.md")
        for path in ["masc.opam.locked", "masc.opam", "dune", "dune-project",
                     "dune-workspace", "scripts/opam-pin-external-deps.sh",
                     ".github/actions/setup-ocaml-toolchain/action.yml",
                     ".github/actions/pin-ocaml-deps/action.yml",
                     ".github/actions/install-ocaml-deps/install.sh"]:
            with self.subTest(path=path):
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (2, [path]))
                self.assertEqual(receipt["overlap"], [])

    def test_stale_queue_reports_refresh_before_any_verdict(self):
        self.main_change(self.path)
        row = self.ledger(comments=[], reviews=[])
        self.assertEqual(row["waits_on"], "stale:1")

    def test_contained_main_commit_at_run_second_is_not_stale(self):
        self.main_change(self.path, RUN_TIME)
        self.git("checkout", "-q", "fixture-pr")
        self.git("merge", "--no-edit", "-s", "ours", "main")
        self.head = self.git("rev-parse", "HEAD")
        self.assertEqual(self.ledger(reviews=[self.approval()])["waits_on"], "merge")

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

    def test_dashboard_only_requires_unconditional_ocaml_build_inputs(self):
        self.make_pr("dashboard/src/fixture.ts")
        self.main_change("masc.opam.locked")
        self.assertEqual(self.ledger()["waits_on"], "dependency:masc.opam.locked")

    def test_indirect_lint_implementation_and_support_inputs_invalidate_evidence(self):
        self.make_pr("dashboard/src/fixture.ts")
        # Actual mandatory driver -> checker -> helper/baseline paths, plus a
        # new checker name: adding a checker must not require an allowlist edit.
        for path in ["scripts/check-ssot.sh", "scripts/audit-hardcoding-truth.sh",
                     "scripts/anti-fake-audit.sh", "scripts/lint/silent-skip-grandfather.txt",
                     "scripts/ci/count_ocaml_code_matches.py",
                     "scripts/lint/new-mandatory-checker.py",
                     "test/test_changelog_section.py"]:
            with self.subTest(path=path):
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (2, [path]))
                self.assertEqual(receipt["overlap"], [])

    def test_unconditional_fixture_data_and_source_inputs_invalidate_evidence(self):
        self.make_pr("dashboard/src/fixture.ts")
        for path in ["benchmarks/terminal_bench/driver/deps.sh",
                     "config/runtime.toml", "test/fixtures/new-data.json",
                     "docs/INSTALL.md", "README.ko.md",
                     "lib/masc_http_client/masc_http_client.ml"]:
            with self.subTest(path=path):
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (2, [path]))
                self.assertEqual(receipt["overlap"], [])

    def test_unrelated_product_changes_remain_fresh(self):
        self.make_pr("dashboard/src/fixture.ts")
        for path in ["lib/unrelated.ml", "bin/unrelated.ml"]:
            self.main_change(path)
        self.assertEqual(self.ledger(reviews=[self.approval()])["waits_on"], "merge")

    def test_tla_spec_inputs_invalidate_without_widening_document_scope(self):
        # Mandatory lint resolves Mirrors against source and checks the TLA
        # set/cfg pairs. A disjoint product PR's old run did not see new inputs.
        for path, shared in [
                ("specs/auth/AuthIdentityFSM.tla", True),
                ("specs/auth/AuthIdentityFSM.cfg", True),
                ("specs/Makefile", True),
                ("docs/evidence/tla-audit/README.md", False),
                ("specs-not-a-check-input/example.tla", False)]:
            with self.subTest(path=path):
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["status"]),
                                 (2, "stale") if shared else (0, "fresh"))
                self.assertEqual(receipt["dependencies"], [path] if shared else [])
                self.assertEqual(receipt["overlap"], [])

    def test_unrelated_documents_and_retained_artifacts_remain_fresh(self):
        for path in ["docs/evidence/another-pr/README.md",
                     "docs/evidence/another-pr/raw.tar.gz",
                     "docs/rfc/unrelated-proposal.md", "notes/meeting.txt"]:
            with self.subTest(path=path):
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["status"]), (0, "fresh"))
                self.assertEqual((receipt["overlap"], receipt["dependencies"]), ([], []))

    def test_distinct_release_fragments_preserve_ordinary_pr_evidence(self):
        # These are independent inputs to the actual required fragment check.
        # Verify each side and the union instead of assuming that disjoint
        # filenames make every aggregate validation compositional.
        fragment_dir = self.root / "fragments"
        fragment_dir.mkdir()
        checker = ROOT / "scripts/changelog-fragments.py"
        for number in [101, 102]:
            single_dir = self.root / f"fragment-{number}"
            single_dir.mkdir()
            fragment = single_dir / f"{number}.md"
            fragment.write_text(f"### Fixed\n\n- A separate change (#{number}).\n")
            result = subprocess.run(["python3", str(checker), "check", "--dir", str(single_dir)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            shutil.copy2(fragment, fragment_dir)
        result = subprocess.run(["python3", str(checker), "check", "--dir", str(fragment_dir)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.make_pr("changelog.d/101.md")
        self.main_change("changelog.d/102.md")
        code, receipt = self.freshness()
        self.assertEqual((code, receipt["dependencies"], receipt["overlap"]), (0, [], []))

    def test_same_document_or_release_fragment_still_requires_refresh(self):
        for path in ["docs/evidence/same-pr/README.md", "changelog.d/101.md"]:
            with self.subTest(path=path):
                self.make_pr(path)
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["overlap"]), (2, [path]))

    def test_fragment_consumer_changes_cannot_reuse_a_disjoint_fragment_run(self):
        # A main fragment may use a heading the candidate parser just removed.
        # Data-file disjointness is insufficient when its consumer changes.
        for consumer in ["scripts/changelog-fragments.py", "scripts/bump-version.sh",
                         "scripts/ci/run-lint-suite.sh", ".github/workflows/pr-check.yml"]:
            with self.subTest(consumer=consumer):
                self.make_pr(consumer)
                self.git("checkout", "-q", "-B", "main", self.base)
                self.main_change("changelog.d/102.md")
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (2, ["changelog.d/102.md"]))
                self.assertEqual(receipt["overlap"], [])

    def test_shared_inputs_still_invalidate_after_an_unrelated_document(self):
        # Each reader-backed family keeps a positive case beside the negative
        # control: excluding incidental docs must not exclude real fixture inputs.
        for path in ["README.md", "docs/INSTALL.md", "docs/spec/SPEC-INDEX.md",
                     "docs/PRODUCT-OPERATING-PLAN.md", "CHANGELOG.md",
                     "config/runtime.toml", "benchmarks/terminal_bench/driver/deps.sh",
                     "scripts/ci/run-lint-suite.sh", ".github/workflows/pr-check.yml",
                     "test/dune", "test/ci-known-failures.txt",
                     "test/stanzas/coverage_test_names.txt", "dashboard/package.json"]:
            with self.subTest(path=path):
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change("docs/evidence/another-pr/receipt.json")
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (0, []))
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (2, [path]))

    def test_rfc_numbering_and_consumer_changes_require_combined_evidence(self):
        # The index enforces numeric identity across different RFC paths.
        for candidate in ["docs/rfc/RFC-0101-candidate.md", "scripts/rfc-generate-index.py"]:
            with self.subTest(candidate=candidate):
                self.make_pr(candidate)
                self.git("checkout", "-q", "-B", "main", self.base)
                self.main_change("docs/rfc/RFC-0101-another.md")
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (2, ["docs/rfc/RFC-0101-another.md"]))
                self.assertEqual(receipt["overlap"], [])

    def test_structural_fixture_inputs_remain_shared(self):
        for path in ["connectors/browser/extension/background.js",
                     "packages/agent_core/scripts/check-exact-output-single-surface.sh",
                     "packages/agent_core/lib/llm_provider/types.mli"]:
            with self.subTest(path=path):
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change("docs/evidence/unrelated/receipt.json")
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (0, []))
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (2, [path]))

    def test_document_reference_target_removal_requires_combined_evidence(self):
        target = "docs/rfc/RFC-0101-target.md"
        self.write(target, "A prior document.\n")
        self.commit("reference target", "2026-01-01T00:02:00Z")
        self.base = self.git("rev-parse", "HEAD")
        self.make_pr("README.md")
        self.git("checkout", "-q", "fixture-pr")
        self.write("README.md", f"A new reference: [target]({target}).\n")
        self.commit("new document reference", "2026-01-01T00:10:00Z")
        self.head = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "main")
        self.git("rm", target)
        self.commit("remove previously unreferenced target", "2026-01-01T01:00:00Z")
        self.git("push", "-q", "origin", "main")
        code, receipt = self.freshness()
        self.assertEqual((code, receipt["dependencies"]), (2, [target]))
        self.assertEqual(receipt["overlap"], [])

    def test_document_reference_target_body_edit_remains_fresh(self):
        target = "docs/rfc/RFC-0101-target.md"
        self.write(target, "A prior document.\n")
        self.commit("reference target", "2026-01-01T00:02:00Z")
        self.base = self.git("rev-parse", "HEAD")
        self.make_pr("README.md")
        self.main_change(target)
        code, receipt = self.freshness()
        self.assertEqual((code, receipt["dependencies"]), (0, []))

    def test_unknown_fragment_layout_is_not_assumed_independent(self):
        self.main_change("changelog.d/new-format.json")
        code, receipt = self.freshness()
        self.assertEqual((code, receipt["dependencies"]), (2, ["changelog.d/new-format.json"]))

    def test_nested_dune_and_dashboard_build_inputs_invalidate_evidence(self):
        self.make_pr("dashboard/src/fixture.ts")
        for path in ["lib/server/dune", "test/stanzas/extra.inc",
                     "dashboard/package.json", "dashboard/pnpm-lock.yaml",
                     "dashboard/pnpm-workspace.yaml", "dashboard/tsconfig.json",
                     "dashboard/tsconfig.node.json", "dashboard/vite.config.ts",
                     "dashboard/vite.preview.config.ts",
                     "dashboard/vitest.config.ts", "dashboard/vitest-setup.ts",
                     "dashboard/dev/source-context-plugin.ts",
                     "dashboard/dev/nested/build-helper.ts"]:
            with self.subTest(path=path):
                self.git("checkout", "-q", "-B", "main", self.base)
                self.git("push", "-q", "--force", "origin", "main")
                self.main_change(path)
                code, receipt = self.freshness()
                self.assertEqual((code, receipt["dependencies"]), (2, [path]))
                self.assertEqual(receipt["overlap"], [])
        # Dashboard sources are product code, not build configuration.
        self.git("checkout", "-q", "-B", "main", self.base)
        self.git("push", "-q", "--force", "origin", "main")
        self.main_change("dashboard/src/other.ts")
        self.assertEqual(self.ledger(reviews=[self.approval()])["waits_on"], "merge")

    def test_direct_checker_and_fixture_changes_invalidate_all_languages(self):
        for candidate in ["dashboard/src/fixture.ts", "lib/example.ml"]:
            self.make_pr(candidate)
            for path in ["scripts/ci/check-source-text-integrity.sh",
                         "scripts/ci/check_env_reads_below_config.py",
                         "test/test_release_evidence_report.py"]:
                with self.subTest(candidate=candidate, path=path):
                    self.git("checkout", "-q", "-B", "main", self.base)
                    self.git("push", "-q", "--force", "origin", "main")
                    self.main_change(path)
                    code, receipt = self.freshness()
                    self.assertEqual((code, receipt["dependencies"]), (2, [path]))

    def test_newer_other_pr_run_does_not_replace_candidate_run(self):
        for associations, branch in [([{"number": 2}], "other-pr"),
                                      ([{"number": 1}, {"number": 2}], "other-pr"),
                                      ([{"number": 2}], "fixture-pr")]:
            with self.subTest(associations=associations, branch=branch):
                def other_run(d):
                    d["runs"]["workflow_runs"].append(dict(
                        d["runs"]["workflow_runs"][0], id=901, run_number=11,
                        head_branch=branch, pull_requests=associations,
                        conclusion=None))
                # Exercise the real queue, including its no-explicit-run read.
                self.assertEqual(self.ledger(mutate=other_run,
                                             reviews=[self.approval()])["waits_on"], "merge")
                code, receipt = self.freshness(other_run, run=None)
                self.assertEqual((code, receipt["run"]), (0, 900))

    def test_newer_candidate_run_still_refuses_queued_or_failed(self):
        for status, conclusion in [("queued", None), ("completed", "failure")]:
            def newer(d):
                d["runs"]["workflow_runs"].append(dict(
                    d["runs"]["workflow_runs"][0], id=901, run_number=11,
                    conclusion=conclusion))
                d["run"].update(id=901, status=status, conclusion=conclusion)
            with self.subTest(status=status, conclusion=conclusion):
                code, receipt = self.freshness(newer, run=None)
                self.assertEqual((code, receipt["reason"]),
                                 (1, "not_successful_exact_head_pr_check"))

    def test_explicit_other_branch_run_refuses_even_with_both_associations(self):
        code, receipt = self.freshness(lambda d: d["run"].update(
            head_branch="other-pr", pull_requests=[{"number": 1}, {"number": 2}]))
        self.assertEqual((code, receipt["reason"]), (1, "run_names_another_branch"))

    def test_dependency_before_run_and_unrelated_main_change(self):
        self.main_change("masc.opam.locked", "2026-01-01T00:20:00Z")
        code, receipt = self.freshness()
        self.assertEqual(code, 2)
        self.assertEqual(receipt["commits"][0]["reason"], "graph_overlap_unverified_tested_base")
        self.git("checkout", "-q", "fixture-pr")
        self.git("merge", "--no-edit", "main")
        self.head = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "main")
        self.main_change("lib/unrelated.ml")
        self.assertEqual(self.ledger(reviews=[self.approval()])["waits_on"], "merge")

    def test_structured_pass_without_formal_approval_waits_on_review(self):
        row = self.ledger()
        self.assertEqual((row["waits_on"], row["verdict"]), ("review", "PASS by reviewer"))
        row = self.ledger(reviews=[self.approval(author_association="NONE")])
        self.assertEqual(row["waits_on"], "review")
        row = self.ledger(reviews=[self.approval(head="b" * 40)])
        self.assertEqual(row["waits_on"], "review")

    def test_same_second_decisions_follow_review_ids_in_either_api_order(self):
        timestamp = "2026-01-01T00:55:00Z"
        cases = [
            ("APPROVED", "CHANGES_REQUESTED", "cr:review-account"),
            ("APPROVED", "DISMISSED", "review"),
            ("CHANGES_REQUESTED", "APPROVED", "merge"),
            ("DISMISSED", "APPROVED", "merge"),
            ("APPROVED", "COMMENTED", "merge"),
        ]
        for older_state, newer_state, expected in cases:
            older = self.message("older decision", timestamp, id=100,
                                 state=older_state, commit_id=self.head)
            newer = self.message("newer decision", timestamp, id=101,
                                 state=newer_state, commit_id=self.head)
            for reviews in ([older, newer], [newer, older]):
                with self.subTest(older=older_state, newer=newer_state,
                                  ids=[review["id"] for review in reviews]):
                    self.assertEqual(self.ledger(reviews=reviews)["waits_on"], expected)

    def test_truncated_option_refuses_instead_of_hanging(self):
        result = subprocess.run(["bash", str(SCRIPT), "--git-dir", str(self.repo),
                                 "--repo"],
                                env=self.env, capture_output=True, text=True,
                                timeout=20)
        self.assertEqual(result.returncode, 1)
        self.assertIn("requires a value", result.stderr)

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

    def freshness(self, mutate=lambda data: None, run=900):
        self.ledger()  # write the same API fixture used by the real ledger
        data = json.loads(self.fixtures.read_text())
        mutate(data)
        self.fixtures.write_text(json.dumps(data))
        result = subprocess.run(["python3", str(SCRIPT.with_name("ci-freshness.py")),
                                 "--repo", "o/r", "--pr", "1", "--head", self.head,
                                 *(["--run", str(run)] if run is not None else []),
                                 "--git-dir", str(self.repo)],
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
            d["suite"] = {"head_sha": self.head, "head_branch": "fixture-pr",
                          "pull_requests": [{"number": 1}]}
            d["checks"] = {"check_runs": [{"head_sha": self.head, "check_suite": {"id": 123}}]}
        self.assertEqual(self.freshness(linkage)[0], 0)
        def wrong(d):
            linkage(d)
            d["checks"]["check_runs"][0]["check_suite"]["id"] = 456
        self.assertEqual(self.freshness(wrong)[0], 1)

    def test_missing_association_requires_candidate_suite_identity(self):
        def linkage(suite_associations):
            def mutate(d):
                d["pull"]["head"]["ref"] = "fixture-pr"
                d["run"].update(pull_requests=[], head_branch="fixture-pr",
                               check_suite_id=123)
                d["suite"] = {"head_sha": self.head, "head_branch": "fixture-pr",
                              "pull_requests": suite_associations}
                d["checks"] = {"check_runs": [
                    {"head_sha": self.head, "check_suite": {"id": 123}}]}
            return mutate
        self.assertEqual(self.freshness(linkage([{"number": 1}]))[0], 0)
        for suite_associations in ([{"number": 2}], []):
            with self.subTest(suite_associations=suite_associations):
                code, receipt = self.freshness(linkage(suite_associations))
                self.assertEqual((code, receipt["status"]), (1, "unavailable"))

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
        self.main_change("lib/unrelated.ml")
        self.mark_shallow(old_root)
        code, receipt = self.freshness()
        self.assertEqual((code, receipt["status"]), (0, "fresh"))
        self.assertEqual(receipt["comparison_ancestor"], self.base)

    def test_shallow_boundary_inside_required_main_suffix_refuses(self):
        self.main_change("lib/unrelated.ml")
        missing_boundary = self.git("rev-parse", "main")
        self.main_change("lib/another.ml", "2026-01-01T01:10:00Z")
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
