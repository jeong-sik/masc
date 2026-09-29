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
PR_CHECK_NAMES = (
    "TLA model check", "lint suite", "dune build @check",
    "dune build --profile release @check", "dashboard typecheck",
    "PR required success",
)


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
    elif '/check-runs' in endpoint: key = 'checkruns'
    elif '/actions/runs?' in endpoint: key = 'runs'
    elif '/actions/runs/' in endpoint and '/jobs' in endpoint:
        run_id = endpoint.split('/actions/runs/', 1)[1].split('/', 1)[0]
        key = 'jobs:' + run_id if 'jobs:' + run_id in fixtures else 'jobs'
    elif '/actions/runs/' in endpoint:
        run_id = endpoint.split('/actions/runs/', 1)[1].split('?', 1)[0]
        key = 'run:' + run_id if 'run:' + run_id in fixtures else 'run'
    else: raise SystemExit('unexpected endpoint: ' + endpoint)
else: raise SystemExit('read-only fixture refuses: ' + repr(args))
if key == fixtures.get('fail'): raise SystemExit('injected read failure')
pages = fixtures.get('pages', {}).get(key)
if pages is not None and '--paginate' not in args:
    raise SystemExit('missing pagination for ' + key)
for page in pages if pages is not None else [fixtures[key]]:
    result = subprocess.run([os.environ['LEDGER_JQ'], '-r', query],
        input=json.dumps(page), text=True)
    if result.returncode:
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

    def ledger(self, comments=None, reviews=None, fail=None, change=None):
        data = {
            "prs": [{"number": 1, "author": {"login": "author"}, "baseRefName": "main",
                     "headRefOid": self.head, "headRefName": "fixture-pr", "isDraft": False,
                     "createdAt": "2026-01-01T00:10:00Z", "files": [{"path": self.path}],
                     "statusCheckRollup": [{"name": "dune build @check",
                                            "conclusion": "SUCCESS", "startedAt": RUN_TIME}]}],
            "comments": comments if comments is not None else [self.message(self.verdict())],
            "reviews": reviews or [],
            "runs": {"workflow_runs": [{"created_at": RUN_TIME, "conclusion": "success",
                                        "event": "pull_request"}]},
            "run": {"head_sha": self.head, "status": "completed", "conclusion": "success"},
            "jobs": {"jobs": [{"conclusion": "success"}]},
            "checkruns": {"check_runs": [{"name": "dune build @check", "status": "completed",
                                          "conclusion": "success", "started_at": RUN_TIME}]},
            "fail": fail,
        }
        if change is not None:
            change(data)
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

    def draft_race(self, data):
        """A later-numbered Draft snapshot beside a complete Ready run."""
        def run(run_id, number, suite, created):
            return {"id": run_id, "workflow_id": 100, "run_number": number,
                    "run_attempt": 1, "name": "PR check", "head_sha": self.head,
                    "head_branch": "fixture-pr", "check_suite_id": suite,
                    "path": ".github/workflows/pr-check.yml", "event": "pull_request",
                    "status": "completed", "conclusion": "success", "created_at": created}

        def jobs(run_id, suite, draft, conclusion, first_id, started):
            return [{"id": first_id + index, "run_id": run_id, "run_attempt": 1,
                     "head_sha": self.head,
                     # Observed skipped-job wire names in run 36514675023.
                     "name": (f"github.event.pull_request.draft == true && 'Draft snapshot / {name}' || '{name}'"
                              if draft else name),
                     "status": "completed", "conclusion": conclusion,
                     "started_at": started, "completed_at": started,
                     "check_run_url": f"https://api.github.com/repos/o/r/check-runs/{first_id + index}",
                     "check_suite": {"id": suite}}
                    for index, name in enumerate(PR_CHECK_NAMES)]

        ready = run(900, 10, 55, RUN_TIME)
        draft = run(901, 11, 56, "2026-01-01T00:05:00Z")
        ready_jobs = jobs(900, 55, False, "success", 100, RUN_TIME)
        draft_jobs = jobs(901, 56, True, "skipped", 200, draft["created_at"])
        data.update({"runs": {"workflow_runs": [ready, draft]},
                     "run": ready, "run:900": ready, "run:901": draft,
                     "jobs:900": {"jobs": ready_jobs}, "jobs:901": {"jobs": draft_jobs},
                     "checkruns": {"check_runs": ready_jobs + draft_jobs}})
        self.sync_rollup(data)

    def sync_rollup(self, data):
        data["prs"][0]["statusCheckRollup"] = [
            {"name": check["name"], "databaseId": check["id"],
             "status": check["status"].upper(), "conclusion": check["conclusion"].upper(),
             "startedAt": check["started_at"],
             "detailsUrl": f"https://github.com/o/r/actions/runs/{check['run_id']}/job/{check['id']}"}
            for check in data["checkruns"]["check_runs"]]

    def test_late_draft_does_not_hide_successful_ready(self):
        row = self.ledger(change=self.draft_race)
        self.assertEqual((row["checks"], row["waits_on"]), ("ok", "merge"))

    def test_draft_timestamp_does_not_make_ready_evidence_stale(self):
        self.main_change("lib/example.ml", "2026-01-01T00:20:00Z")
        self.assertEqual(self.ledger(change=self.draft_race)["waits_on"], "merge")

    def test_external_commit_status_survives_draft_check_exclusion(self):
        for state, expected in (("FAILURE", "ci:fail"), ("PENDING", "ci:pending"),
                                ("SUCCESS", "merge")):
            with self.subTest(state=state):
                def change(data):
                    self.draft_race(data)
                    data["prs"][0]["statusCheckRollup"].append({
                        "__typename": "StatusContext", "context": "external validation",
                        "state": state, "createdAt": RUN_TIME})
                self.assertEqual(self.ledger(change=change)["waits_on"], expected)

    def test_earlier_real_pr_run_still_sets_freshness_floor(self):
        self.main_change("lib/example.ml", "2026-01-01T00:20:00Z")

        def change(data):
            self.draft_race(data)
            earlier = dict(data["run"], id=899, run_number=9,
                           check_suite_id=54, created_at="2026-01-01T00:15:00Z")
            data["runs"]["workflow_runs"].append(earlier)
            data["jobs:899"] = {"jobs": [dict(j, id=j["id"] - 10, run_id=899,
                check_suite={"id": 54}) for j in data["jobs:900"]["jobs"]]}
        self.assertEqual(self.ledger(change=change)["waits_on"], "stale:1")

    def test_earlier_remaining_check_still_sets_freshness_floor(self):
        self.main_change("lib/example.ml", "2026-01-01T00:20:00Z")

        def change(data):
            self.draft_race(data)
            data["checkruns"]["check_runs"].append(dict(
                data["jobs:900"]["jobs"][0], name="other check", id=300,
                run_id=902, check_suite={"id": 57}, started_at="2026-01-01T00:15:00Z"))
            self.sync_rollup(data)
        self.assertEqual(self.ledger(change=change)["waits_on"], "stale:1")

    def test_draft_only_or_foreign_workflow_is_not_ready_proof(self):
        for foreign in (False, True):
            with self.subTest(foreign=foreign):
                def change(data):
                    self.draft_race(data)
                    if foreign:
                        data["run"]["path"] = ".github/workflows/other.yml"
                        data["run"]["workflow_id"] = 200
                    else:
                        data["runs"]["workflow_runs"] = [data["run:901"]]
                        data["checkruns"]["check_runs"] = data["jobs:901"]["jobs"]
                    self.sync_rollup(data)
                row = self.ledger(change=change)
                self.assertNotEqual(row["checks"], "ok")
                self.assertNotEqual(row["waits_on"], "merge")

    def test_malformed_or_wrong_provenance_draft_cannot_be_ignored(self):
        for fault in ("missing", "extra", "duplicate", "success", "wrong_path", "wrong_head", "wrong_name"):
            with self.subTest(fault=fault):
                def change(data):
                    self.draft_race(data)
                    jobs = data["jobs:901"]["jobs"]
                    if fault == "missing":
                        jobs.pop()
                    elif fault == "extra":
                        jobs.append(dict(jobs[0], id=299, name="extra check", conclusion="success"))
                    elif fault == "duplicate":
                        jobs[-1]["name"] = jobs[0]["name"]
                    elif fault == "success":
                        for job in jobs:
                            job["conclusion"] = "success"
                    elif fault == "wrong_name":
                        jobs[0]["name"] = jobs[0]["name"].replace("== true", "== false")
                    elif fault == "wrong_path":
                        data["run:901"]["path"] = ".github/workflows/other.yml"
                    else:
                        data["run:901"]["head_sha"] = "a" * 40
                    data["checkruns"]["check_runs"] = data["jobs:900"]["jobs"] + jobs
                    self.sync_rollup(data)
                row = self.ledger(change=change)
                self.assertNotEqual(row["checks"], "ok")
                self.assertNotEqual(row["waits_on"], "merge")

    def test_ready_checks_cannot_be_combined_across_suites(self):
        def change(data):
            self.draft_race(data)
            data["jobs:900"]["jobs"].pop()
            other = dict(data["run"], id=902, check_suite_id=57, workflow_id=200,
                         path=".github/workflows/other.yml")
            data["runs"]["workflow_runs"].append(other)
            misplaced = dict(data["checkruns"]["check_runs"][5], run_id=902,
                             check_suite={"id": 57})
            data["checkruns"]["check_runs"][5] = misplaced
            data["jobs:902"] = {"jobs": [misplaced]}
            self.sync_rollup(data)
        self.assertNotEqual(self.ledger(change=change)["waits_on"], "merge")

    def test_newer_real_ready_failure_or_pending_remains_blocking(self):
        for conclusion in ("failure", None):
            with self.subTest(conclusion=conclusion):
                def change(data):
                    self.draft_race(data)
                    newer = dict(data["run"], id=902, run_number=12, check_suite_id=57,
                                 status="in_progress" if conclusion is None else "completed",
                                 conclusion=conclusion)
                    data["runs"]["workflow_runs"].append(newer)
                    data["jobs:902"] = {"jobs": []}
                self.assertNotEqual(self.ledger(change=change)["waits_on"], "merge")

    def test_cancelled_draft_twin_does_not_hide_complete_ready(self):
        def change(data):
            self.draft_race(data)
            data["run:901"]["conclusion"] = "cancelled"
            data["jobs:901"] = {"jobs": []}
        self.assertEqual(self.ledger(change=change)["waits_on"], "merge")

    def test_only_cancelled_runs_cannot_grant_merge(self):
        def change(data):
            self.draft_race(data)
            data["run:901"]["conclusion"] = "cancelled"
            data["run:900"]["conclusion"] = "cancelled"
        self.assertNotEqual(self.ledger(change=change)["waits_on"], "merge")

    def test_draft_signature_and_checks_are_read_across_pages(self):
        def change(data):
            self.draft_race(data)
            data["pages"] = {
                "runs": [{"workflow_runs": [data["run:901"]]},
                         {"workflow_runs": [data["run:900"]]}],
                "jobs:901": [{"jobs": data["jobs:901"]["jobs"][:3]},
                             {"jobs": data["jobs:901"]["jobs"][3:]}],
                "checkruns": [{"check_runs": data["checkruns"]["check_runs"][:4]},
                              {"check_runs": data["checkruns"]["check_runs"][4:]}],
            }
        self.assertEqual(self.ledger(change=change)["waits_on"], "merge")

    def test_second_page_extra_draft_job_is_not_discarded(self):
        def change(data):
            self.draft_race(data)
            data["pages"] = {"jobs:901": [data["jobs:901"], {"jobs": [
                dict(data["jobs:901"]["jobs"][0], id=299, name="extra", conclusion="success")]}]}
        self.assertNotEqual(self.ledger(change=change)["waits_on"], "merge")

    def test_draft_classification_transport_failure_stays_unknown(self):
        row = self.ledger(change=self.draft_race, fail="jobs:901")
        self.assertTrue(row["waits_on"].startswith("unknown:"), row)


if __name__ == "__main__":
    unittest.main()
