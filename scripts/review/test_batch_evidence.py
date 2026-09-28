#!/usr/bin/env python3
"""Combined-tree evidence controls: real Git, fake GitHub, no builds/network."""
import copy
from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


F = load("batch_test_freshness", HERE / "ci-freshness.py")
B = load("batch_test_evidence", HERE / "batch_evidence.py")
REQUIRED = ("lint suite", "dune build @check", "dune build --profile release @check",
            "dashboard typecheck", "TLA model check")
PREFIX = "repos/o/r"


class BatchEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="batch-evidence-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "core.hooksPath", str(self.root / "no-hooks"))
        self.git("config", "commit.gpgSign", "false")
        self.git("config", "user.name", "Batch fixture")
        self.git("config", "user.email", "batch@example.invalid")
        remote = self.root / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        self.git("remote", "add", "origin", str(remote))
        self.base = self.change(None, "lib/base.ml", "let base = 1\n")
        self.heads = {1: self.change(self.base, "lib/one.ml", "let one = 1\n"),
                      2: self.change(self.base, "lib/two.ml", "let two = 2\n")}
        # Construct ROLL with ordinary Git merges, independently of Trees.merge.
        self.git("checkout", "-q", "--detach", self.base)
        for head in self.heads.values():
            self.git("merge", "-q", "--no-ff", "--no-edit", head)
        self.roll = self.git("rev-parse", "HEAD")
        self.main = self.base
        self.data = {}
        self.responses = {}
        self.calls = []
        self.run_ids = {1: 901, 2: 902, 99: 900}
        for pr, head in [*self.heads.items(), (99, self.roll)]:
            branch = f"branch-{pr}"
            self.put(f"pulls/{pr}", {
                "number": pr, "state": "open", "draft": False, "merged": False,
                "merge_commit_sha": None, "user": {"login": f"author-{pr}"},
                "base": {"ref": "main"}, "head": {"sha": head, "ref": branch}})
            run_id = self.run_ids[pr]
            run = {"id": run_id, "run_number": 10, "workflow_id": 70,
                   "name": "PR Check", "head_sha": head, "head_branch": branch,
                   "event": "pull_request", "path": ".github/workflows/pr-check.yml",
                   "status": "completed", "conclusion": "success",
                   "check_suite_id": run_id + 1000, "pull_requests": [{"number": pr}]}
            self.put(f"actions/runs/{run_id}", run)
            self.put(f"actions/runs?head_sha={head}&event=pull_request&per_page=100",
                     {"workflow_runs": [copy.deepcopy(run)]})
            self.put(f"actions/runs?head_sha={head}&per_page=100",
                     {"workflow_runs": [copy.deepcopy(run)]})
            self.put(f"check-suites/{run_id + 1000}", {
                "head_sha": head, "head_branch": branch, "pull_requests": [{"number": pr}]})
            self.put(f"actions/runs/{run_id}/jobs?per_page=100", {"jobs": [
                {"id": run_id * 10 + n, "name": name, "status": "completed", "conclusion": "success"}
                for n, name in enumerate(REQUIRED)]})
            self.put(f"commits/{head}/check-runs?per_page=100", {"check_runs": [
                {"id": run_id * 10 + n, "name": name, "status": "completed",
                 "conclusion": "success", "check_suite": {"id": run_id + 1000}}
                for n, name in enumerate(REQUIRED)]})
            self.put(f"pulls/{pr}/reviews?per_page=100", [])
        self.set_line()
        self.put("commits/main", {"sha": self.main})
        self.fixture = self.root / "api.json"
        self.fake = self.root / "gh"
        self.fake.write_text("""#!/usr/bin/env python3
import json, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with Path(__file__).with_name('requests.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\\n')
if not args or args[0] != 'api':
    raise SystemExit('fixture refuses non-API operation')
if any(arg in {'-X', '--method', '-f', '-F', '--field', '--raw-field'} for arg in args):
    raise SystemExit('fixture refuses API writes')
endpoint = next(a for a in args[1:] if a == 'user' or a.startswith('repos/'))
data = json.loads(Path(__file__).with_name('api.json').read_text())
if endpoint not in data:
    raise SystemExit('unknown fixture endpoint: ' + endpoint)
responses = data.get('__responses', {}).get(endpoint)
if responses:
    selected = responses.pop(0) if len(responses) > 1 else responses[0]
    Path(__file__).with_name('api.json').write_text(json.dumps(data))
else:
    selected = data[endpoint]
value = json.dumps(selected)
if '--jq' in args:
    raise SystemExit(subprocess.run(['jq', '-r', args[args.index('--jq') + 1]],
                                   input=value, text=True).returncode)
print(value)
""")
        self.fake.chmod(0o755)

    def git(self, *args, input=None):
        result = subprocess.run(["git", "-C", str(self.repo), *args], input=input,
                                text=True, capture_output=True, check=True)
        return result.stdout.strip()

    def change(self, parent, path, content):
        if parent:
            self.git("checkout", "-q", "--detach", parent)
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        self.git("add", path)
        self.git("commit", "-q", "-m", "fixture " + path)
        return self.git("rev-parse", "HEAD")

    def put(self, path, value):
        self.data[PREFIX + "/" + path] = value
        if path.endswith("?per_page=100"):
            self.data[PREFIX + "/" + path.removesuffix("?per_page=100")] = value

    def get(self, path):
        return self.data[PREFIX + "/" + path]

    def api(self, _gh, endpoint):
        self.calls.append(endpoint)
        values = self.responses.get(endpoint)
        if values:
            value = values.pop(0) if len(values) > 1 else values[0]
        else:
            value = self.data[endpoint]
        return copy.deepcopy(value)

    def later(self, path, value):
        key = PREFIX + "/" + path
        self.responses[key] = [copy.deepcopy(self.data[key]), value]

    def set_line(self, members=None):
        members = members or list(self.heads)
        self.line = (f"batch: PASS roll: {self.roll} base: {self.base} run: 900 members: "
                     + ",".join(f"{pr}@{self.heads[pr]}" for pr in members) + " by: keeper")
        for pr in [1, 2, 99]:
            comments = [{"id": pr * 10, "body": self.line,
                         "author_association": "COLLABORATOR", "user": {"login": "publisher"},
                         "created_at": "2026-01-01T00:40:00Z"}]
            if pr in self.heads:
                comments.append({"id": pr * 10 + 1,
                    "body": f"verdict: PASS head: {self.heads[pr]} run: {self.run_ids[pr]} by: reviewer",
                    "author_association": "MEMBER", "user": {"login": "reviewer"},
                    "created_at": "2026-01-01T00:41:00Z"})
            self.put(f"issues/{pr}/comments?per_page=100", comments)

    def evaluate(self, pr=1, *, landing=False, real_gates=False):
        self.fixture.write_text(json.dumps(self.data))
        with ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, {"GUARD_GH": str(self.fake)}))
            stack.enter_context(patch.object(F, "api", self.api))
            stack.enter_context(patch.object(F, "api_pages", lambda gh, endpoint: [self.api(gh, endpoint)]))
            if not real_gates:
                stack.enter_context(patch.object(B, "current_checks"))
                stack.enter_context(patch.object(B, "verdict", side_effect=lambda _f, _g, _r, m: self.run_ids[m.pr]))
            return B.evaluate(F, line=self.line, repo="o/r", pr=pr, head=self.heads[pr],
                              run=self.run_ids[pr], git_dir=str(self.repo),
                              gh=str(self.fake), landing=landing)

    def approvals(self):
        for pr, head in self.heads.items():
            review = {"id": 100 + pr, "state": "APPROVED",
                      "user": {"login": "independent-reviewer"},
                      "author_association": "MEMBER", "commit_id": head,
                      "submitted_at": "2026-01-01T00:42:00Z",
                      "body": f"verdict: PASS head: {head} run: {self.run_ids[pr]} by: reviewer\n\n"
                              f"approve-guard: head `{head}` · fixture evidence"}
            self.put(f"pulls/{pr}/reviews?per_page=100", [review])
            self.put(f"pulls/{pr}/reviews/{review['id']}", review)

    def refusal(self, reason, **kwargs):
        with self.assertRaisesRegex(F.Unavailable, "^" + reason + "$"):
            self.evaluate(**kwargs)

    def land(self, pr, parent=None, *, wrong=False):
        parent = parent or self.main
        if wrong:
            commit = self.change(parent, f"lib/{'one' if pr == 1 else 'two'}.ml", "wrong landing\n")
        else:
            tree = self.git("merge-tree", "--write-tree", parent, self.heads[pr]).splitlines()[0]
            commit = self.git("commit-tree", tree, "-p", parent, input=f"Squash member {pr}\n")
        self.get(f"pulls/{pr}").update(state="closed", merged=True, merge_commit_sha=commit)
        self.main = commit
        self.put("commits/main", {"sha": commit})
        return commit

    def run_landing(self, mode="success", *, check_only=False):
        """Keep Git/evaluate/exact_run/approval real; stub CI and merge writes.

        The current_checks stub forbids closed-prefix CI calls. Actual CI gates
        and --batch wrappers have separate subprocess controls. The mutating
        merge-guard command becomes local Git/API-state changes, never an API
        write or a build.
        """
        self.fixture.write_text(json.dumps(self.data))
        batch = self.root / "landing.txt"
        batch.write_text(self.line + "\n")
        self.writes = []
        self.write_read_offsets = []
        original_command = F.command
        def command(args):
            if len(args) > 1 and Path(args[1]).name == "merge-guard.sh":
                self.assertNotIn("--check", args)
                pr = int(args[args.index("--pr") + 1])
                self.assertEqual(args[args.index("--head") + 1], self.heads[pr])
                self.assertEqual(Path(args[args.index("--batch") + 1]).read_text().strip(), self.line)
                self.writes.append(pr)
                if mode != "pending":
                    parent = self.main
                    if mode == "wrong-parent":
                        parent = self.change(parent, "docs/racing.md", "Concurrent main arrival\n")
                    self.land(pr, parent, wrong=mode == "wrong-tree")
                    self.fixture.write_text(json.dumps(self.data))
                self.write_read_offsets.append(len(self.calls))
                return '{"submitted": true}'
            return original_command(args)
        def checks(_f, _gh, _repo, pr, _head, _git_dir, **_kwargs):
            self.assertFalse(self.get(f"pulls/{pr}")["merged"],
                             "closed prefix must not rerun the open-PR CI gate")
        with patch.dict(os.environ, {"GUARD_GH": str(self.fake)}), \
             patch.object(F, "api", self.api), \
             patch.object(F, "api_pages", lambda gh, endpoint: [self.api(gh, endpoint)]), \
             patch.object(F, "command", side_effect=command), \
             patch.object(B, "current_checks", side_effect=checks):
            return B.land(F, batch_file=str(batch), repo="o/r", git_dir=str(self.repo),
                          gh=str(self.fake), check_only=check_only)

    def test_combined_tree_and_two_member_landing_reuse_one_roll_run(self):
        self.approvals()
        first = self.evaluate(landing=True)
        self.assertEqual((first["status"], first["landed"], first["roll_run"]), ("fresh", [], 900))
        self.assertEqual(first["tree"], self.git("rev-parse", self.roll + "^{tree}"))
        for path, content in [("lib/one.ml", "let one = 1"), ("lib/two.ml", "let two = 2")]:
            self.assertEqual(self.git("show", first["tree"] + ":" + path), content)
        self.land(1)
        second = self.evaluate(pr=2, landing=True)
        self.assertEqual((second["landed"], second["roll_run"], second["tree"]),
                         ([1], 900, first["tree"]))
        self.land(2)
        self.assertEqual(self.git("rev-parse", self.main + "^{tree}"), first["tree"])
        self.refusal("batch_candidate_already_merged", pr=2)

    def test_non_next_member_cannot_land(self):
        self.refusal("batch_candidate_not_next_member", pr=2, landing=True)

    def test_landing_requires_second_members_real_bound_approval(self):
        self.approvals()
        self.put("pulls/2/reviews?per_page=100", [])
        self.refusal("evidence_read_failed", landing=True)

    def test_red_roll_or_member_run_refuses(self):
        for run in [900, 901, 902]:
            with self.subTest(run=run):
                self.get(f"actions/runs/{run}")["conclusion"] = "failure"
                self.refusal("batch_run_not_current_successful_exact_pr_check")
                self.get(f"actions/runs/{run}")["conclusion"] = "success"

    def test_foreign_run_identity_refuses(self):
        original = copy.deepcopy(self.get("actions/runs/900"))
        for field, value in [("head_sha", self.heads[1]), ("event", "workflow_dispatch"),
                             ("head_branch", "foreign"), ("pull_requests", [{"number": 1}])]:
            with self.subTest(field=field):
                self.get("actions/runs/900")[field] = value
                with self.assertRaises(F.Unavailable):
                    self.evaluate()
                self.put("actions/runs/900", copy.deepcopy(original))

    def test_newer_queued_run_invalidates_completed_roll(self):
        newer = copy.deepcopy(self.get("actions/runs/900"))
        newer.update(id=999, run_number=11, status="queued", conclusion=None)
        self.get(f"actions/runs?head_sha={self.roll}&event=pull_request&per_page=100")["workflow_runs"].append(newer)
        self.refusal("batch_run_not_current_successful_exact_pr_check")

    def test_absent_run_association_requires_matching_suite(self):
        self.get("actions/runs/901")["pull_requests"] = []
        self.assertEqual(self.evaluate()["status"], "fresh")
        self.get("check-suites/1901")["pull_requests"] = [{"number": 7}]
        self.refusal("batch_run_suite_not_linked_to_pr")

    def test_cancelled_newer_twin_does_not_replace_valid_run(self):
        cancelled = copy.deepcopy(self.get("actions/runs/900"))
        cancelled.update(id=999, run_number=11, conclusion="cancelled")
        self.get(f"actions/runs?head_sha={self.roll}&event=pull_request&per_page=100")["workflow_runs"].append(cancelled)
        self.assertEqual(self.evaluate()["roll_run"], 900)

    def test_missing_or_skipped_required_job_refuses(self):
        jobs = self.get("actions/runs/900/jobs?per_page=100")["jobs"]
        missing = jobs.pop()
        self.refusal("batch_required_jobs_not_all_successful")
        jobs.append(missing)
        jobs[-1]["conclusion"] = "skipped"
        self.refusal("batch_required_jobs_not_all_successful")

    def test_member_head_move_refuses(self):
        self.get("pulls/2")["head"]["sha"] = self.base
        self.refusal("batch_member_head_or_base_changed")

    def test_outsider_publication_refuses(self):
        for pr in [1, 99]:
            with self.subTest(pr=pr):
                self.get(f"issues/{pr}/comments?per_page=100")[0]["author_association"] = "NONE"
                self.refusal("batch_line_not_published_by_trusted_participant")
                self.get(f"issues/{pr}/comments?per_page=100")[0]["author_association"] = "COLLABORATOR"

    def test_formal_change_request_refuses(self):
        self.put("pulls/2/reviews?per_page=100", [
            {"id": 1, "state": "CHANGES_REQUESTED", "user": {"login": "reviewer"}}])
        self.refusal("batch_member_has_open_change_request")

    def test_roll_formal_change_request_refuses_initial_and_late(self):
        reviews = [{"id": 1, "state": "CHANGES_REQUESTED", "user": {"login": "reviewer"}}]
        self.put("pulls/99/reviews?per_page=100", reviews)
        self.refusal("batch_member_has_open_change_request")
        self.put("pulls/99/reviews?per_page=100", [])
        self.later("pulls/99/reviews?per_page=100", reviews)
        self.refusal("batch_member_has_open_change_request")

    def test_late_roll_structured_refusal_cannot_reuse_batch_publication(self):
        endpoint = PREFIX + "/issues/99/comments"
        original = copy.deepcopy(self.get("issues/99/comments"))
        for state, run in [("FAIL", 900), ("HOLD", 900), ("PASS", 999)]:
            with self.subTest(state=state, run=run):
                refusal = {"id": 999, "created_at": "2026-01-01T00:50:00Z",
                           "author_association": "MEMBER", "user": {"login": "reviewer"},
                           "body": f"verdict: {state} head: {self.roll} run: {run} by: reviewer"}
                # The batch line remains intact and trusted. Only the later
                # review decision changes during the final evidence reads.
                self.data["__responses"] = {endpoint: [original, original + [refusal]]}
                self.refusal("batch_roll_review_refuses_evidence")

    def test_landed_head_current_and_late_refusals_stop_remaining_member(self):
        self.land(1)
        original = copy.deepcopy(self.data)
        for state in ["CHANGES_REQUESTED", "FAIL", "HOLD"]:
            for late in [False, True]:
                with self.subTest(state=state, late=late):
                    self.data = copy.deepcopy(original)
                    self.responses.clear()
                    self.calls.clear()
                    if state == "CHANGES_REQUESTED":
                        reviews = [{"id": 1003, "state": state, "user": {"login": "reviewer"}}]
                        if late:
                            self.later("pulls/1/reviews?per_page=100", reviews)
                        else:
                            self.put("pulls/1/reviews?per_page=100", reviews)
                        reason = "batch_member_has_open_change_request"
                    else:
                        path = "issues/1/comments"
                        comments = copy.deepcopy(self.get(path))
                        refusal = {"id": 1004, "created_at": "2026-01-01T00:50:00Z",
                                   "author_association": "MEMBER", "user": {"login": "reviewer"},
                                   "body": f"verdict: {state} head: {self.heads[1]} run: 901 by: reviewer"}
                        if late:
                            self.data["__responses"] = {PREFIX + "/" + path: [comments, comments + [refusal]]}
                        else:
                            self.put(path + "?per_page=100", comments + [refusal])
                        reason = "batch_landed_member_review_refuses_evidence"
                    self.refusal(reason, pr=2)
                    self.assertNotIn(PREFIX + "/actions/runs/901", self.calls)

    def test_external_shared_and_overlap_changes_refuse(self):
        for path in ["config/runtime.toml", "specs/auth/AuthIdentityFSM.tla", "lib/one.ml"]:
            with self.subTest(path=path):
                self.put("commits/main", {"sha": self.change(self.base, path, "external change\n")})
                self.refusal("batch_nonmember_main_change_invalidates_roll")

    def test_external_unrelated_document_is_retained(self):
        self.approvals()
        self.main = self.change(self.base, "docs/unrelated.md", "External note\n")
        self.put("commits/main", {"sha": self.main})
        self.land(1)
        result = self.evaluate(pr=2, landing=True)
        self.assertEqual(result["external_paths"], ["docs/unrelated.md"])
        self.assertEqual(self.git("show", result["tree"] + ":docs/unrelated.md"), "External note")

    def test_forged_roll_tree_refuses(self):
        forged = self.change(self.roll, "lib/forged.ml", "unreviewed extra\n")
        old = self.roll
        self.roll = forged
        self.get("pulls/99")["head"]["sha"] = forged
        self.get("actions/runs/900")["head_sha"] = forged
        self.put(f"actions/runs?head_sha={forged}&event=pull_request&per_page=100",
                 self.get(f"actions/runs?head_sha={old}&event=pull_request&per_page=100"))
        self.get(f"actions/runs?head_sha={forged}&event=pull_request&per_page=100")["workflow_runs"][0]["head_sha"] = forged
        self.set_line()
        self.refusal("batch_roll_tree_does_not_match_members")

    def test_out_of_order_or_wrong_squash_refuses(self):
        self.land(2)
        self.refusal("batch_landed_out_of_order")
        self.get("pulls/2").update(state="open", merged=False, merge_commit_sha=None)
        self.main = self.base
        self.land(1, wrong=True)
        self.refusal("batch_member_landing_tree_mismatch", pr=2)

    def test_api_landing_must_exist_in_main_history(self):
        self.land(1)
        self.put("commits/main", {"sha": self.base})
        self.refusal("batch_member_merge_not_in_main_history", pr=2)

    def test_resumed_landing_rejects_two_parent_merge_with_correct_tree(self):
        tree = self.git("merge-tree", "--write-tree", self.base, self.heads[1]).splitlines()[0]
        merged = self.git("commit-tree", tree, "-p", self.base, "-p", self.heads[1],
                          input="Normal merge, not the required squash\n")
        self.get("pulls/1").update(state="closed", merged=True, merge_commit_sha=merged)
        self.put("commits/main", {"sha": merged})
        self.assertEqual(self.git("rev-parse", merged + "^{tree}"), tree)
        self.refusal("batch_member_landing_is_not_a_squash", pr=2)

    def test_missing_history_refuses(self):
        self.main = self.change(self.base, "docs/unrelated.md", "External note\n")
        self.put("commits/main", {"sha": self.main})
        (self.repo / ".git/shallow").write_text(self.main + "\n")
        self.refusal("batch_base_not_in_available_main_history")

    def test_late_member_and_main_state_changes_refuse(self):
        moved = copy.deepcopy(self.get("pulls/2"))
        moved["head"]["sha"] = self.base
        self.later("pulls/2", moved)
        self.refusal("batch_member_moved_during_check")
        self.responses.clear()
        self.later("commits/main", {"sha": self.roll})
        self.refusal("batch_roll_or_main_moved_during_check")

    def test_late_publication_or_change_request_refuses(self):
        self.later("issues/2/comments?per_page=100", [])
        self.refusal("batch_line_not_published_by_trusted_participant")
        self.responses.clear()
        self.later("pulls/2/reviews?per_page=100", [
            {"id": 2, "state": "CHANGES_REQUESTED", "user": {"login": "reviewer"}}])
        self.refusal("batch_member_has_open_change_request")

    def test_late_roll_draft_change_refuses(self):
        moved = copy.deepcopy(self.get("pulls/99"))
        moved["draft"] = True
        self.later("pulls/99", moved)
        self.refusal("batch_roll_or_main_moved_during_check")

    def test_late_structured_verdict_run_change_refuses(self):
        counts = {1: 0, 2: 0}
        def verdict(_f, _gh, _repo, member):
            counts[member.pr] += 1
            return 999 if member.pr == 2 and counts[2] > 1 else self.run_ids[member.pr]
        # Supply this gate directly so evaluate does not replace our sequence.
        with patch.object(B, "current_checks"), patch.object(B, "verdict", side_effect=verdict):
            self.refusal("batch_member_verdict_changed_during_check", real_gates=True)

    def test_late_newer_success_invalidates_cited_roll_run(self):
        endpoint = f"actions/runs?head_sha={self.roll}&event=pull_request&per_page=100"
        newer = copy.deepcopy(self.get("actions/runs/900"))
        newer.update(id=999, run_number=11)
        self.later(endpoint, {"workflow_runs": [newer]})
        self.refusal("batch_run_not_current_successful_exact_pr_check")

    def test_real_shell_verdict_and_ci_gate_accept_complete_evidence(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        self.assertEqual(self.evaluate(real_gates=True)["status"], "fresh")

    def test_real_shell_gate_rejects_check_failure_hidden_by_green_run(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        self.get(f"commits/{self.heads[2]}/check-runs?per_page=100")["check_runs"][0]["conclusion"] = "failure"
        self.refusal("evidence_read_failed", real_gates=True)

    def test_real_shell_verdict_rejects_outsider_pass(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        self.get("issues/2/comments?per_page=100")[1]["author_association"] = "NONE"
        self.refusal("batch_member_without_current_pass", real_gates=True)

    def test_real_shell_final_ci_gate_rejects_late_check_failure(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        endpoint = f"commits/{self.heads[2]}/check-runs?per_page=100"
        good = copy.deepcopy(self.get(endpoint))
        failed = copy.deepcopy(good)
        failed["check_runs"][0]["conclusion"] = "failure"
        self.data["__responses"] = {PREFIX + "/" + endpoint: [good, failed]}
        self.refusal("evidence_read_failed", real_gates=True)

    def test_main_move_during_final_roll_check_refuses(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        moved = self.change(self.base, "docs/late.md", "Late main change\n")
        actual_checks = B.current_checks
        roll_reads = 0
        def check_then_move(f, gh, repo, pr, head, git_dir, **kwargs):
            nonlocal roll_reads
            actual_checks(f, gh, repo, pr, head, git_dir, **kwargs)
            if pr == 99:
                roll_reads += 1
                if roll_reads == 2:
                    self.put("commits/main", {"sha": moved})
        with patch.object(B, "current_checks", side_effect=check_then_move):
            self.refusal("batch_roll_or_main_moved_during_check", real_gates=True)
        self.assertEqual(roll_reads, 2, "mutation must occur during the finishing CI read")

    def test_actual_batch_argument_wrappers_accept_and_reject_without_writes(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        self.approvals()
        self.data["user"] = {"login": "operator"}
        for run_id in self.run_ids.values():
            self.get(f"actions/runs/{run_id}")["created_at"] = "2026-01-01T00:30:00Z"
        original = copy.deepcopy(self.data)
        batch = self.root / "batch.txt"
        batch.write_text(self.line + "\n")
        for script, marker in [("approve-guard.sh", "WOULD APPROVE"),
                               ("merge-guard.sh", "WOULD MERGE")]:
            for state in ["valid", "roll-fail", "roll-cr"]:
                with self.subTest(script=script, state=state):
                    self.data = copy.deepcopy(original)
                    if state == "roll-fail":
                        self.get("issues/99/comments?per_page=100").append({
                            "id": 1001, "created_at": "2026-01-01T00:50:00Z",
                            "author_association": "MEMBER", "user": {"login": "reviewer"},
                            "body": f"verdict: FAIL head: {self.roll} run: 900 by: reviewer"})
                    elif state == "roll-cr":
                        self.put("pulls/99/reviews?per_page=100", [{
                            "id": 1002, "state": "CHANGES_REQUESTED", "body": "Fix the roll",
                            "submitted_at": "2026-01-01T00:50:00Z",
                            "author_association": "MEMBER", "user": {"login": "reviewer"}}])
                    self.fixture.write_text(json.dumps(self.data))
                    result = subprocess.run([
                        "bash", str(HERE / script), "--check", "--repo", "o/r", "--pr", "1",
                        "--head", self.heads[1], "--run", "901", "--git-dir", str(self.repo),
                        "--batch", str(batch)], env=dict(os.environ, GUARD_GH=str(self.fake)),
                        capture_output=True, text=True, timeout=120)
                    if state == "valid":
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn(marker, result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        reason = ("batch_roll_review_refuses_evidence" if state == "roll-fail"
                                  else "batch_member_has_open_change_request")
                        self.assertIn(reason, result.stdout + result.stderr)
        requests = [json.loads(line) for line in (self.root / "requests.jsonl").read_text().splitlines()]
        self.assertTrue(requests)
        self.assertFalse(any(set(row) & {"-X", "--method", "-f", "-F", "--field", "--raw-field"}
                             for row in requests), "check wrappers must never attempt an API write")

    def test_land_entry_proves_ordered_squashes_and_final_arrival(self):
        self.approvals()
        result = self.run_landing()
        self.assertEqual(self.writes, [1, 2])
        self.assertEqual((result["status"], result["landed"], result["roll_run"]),
                         ("fresh", [1, 2], 900))
        self.assertEqual(result["tree"], self.git("rev-parse", self.roll + "^{tree}"))
        first = self.get("pulls/1")["merge_commit_sha"]
        second = self.get("pulls/2")["merge_commit_sha"]
        self.assertEqual(self.git("show", "--no-patch", "--format=%P", first), self.base)
        self.assertEqual(self.git("show", "--no-patch", "--format=%P", second), first)

    def test_land_entry_returns_pending_after_one_read_without_second_write(self):
        self.approvals()
        result = self.run_landing("pending")
        self.assertEqual((result["status"], result["pr"], self.writes), ("pending", 1, [1]))
        self.assertEqual(self.calls[self.write_read_offsets[0]:], [PREFIX + "/pulls/1"])
        self.assertEqual(self.get("commits/main")["sha"], self.base)

    def test_land_entry_stops_after_wrong_parent_or_tree(self):
        self.approvals()
        original = copy.deepcopy(self.data)
        for mode, reason in [("wrong-parent", "batch_main_changed_at_merge_write"),
                             ("wrong-tree", "batch_member_landing_tree_mismatch")]:
            with self.subTest(mode=mode):
                self.data = copy.deepcopy(original)
                self.main = self.base
                with self.assertRaisesRegex(F.Unavailable, "^" + reason + "$"):
                    self.run_landing(mode)
                self.assertEqual(self.writes, [1], "failed arrival must stop before member 2")

    def test_land_entry_missing_second_approval_refuses_before_any_write(self):
        self.approvals()
        self.put("pulls/2/reviews?per_page=100", [])
        with self.assertRaisesRegex(F.Unavailable, "^evidence_read_failed$"):
            self.run_landing()
        self.assertEqual(self.writes, [])

    def cli(self, *, line=None):
        batch = self.root / "cli-batch.txt"
        batch.write_text(self.line + "\n" if line is None else line)
        self.fixture.write_text(json.dumps(self.data))
        # Override only the executable under test for the disposable mutation
        # control. The fixture still runs the complete public shell entry.
        entry = Path(os.environ.get("BATCH_TEST_LAND_SCRIPT", HERE / "land-batch.sh"))
        result = subprocess.run(["bash", str(entry), "--repo", "o/r", "--batch", str(batch),
                                 "--git-dir", str(self.repo), "--check-only"],
                                env=dict(os.environ, GUARD_GH=str(self.fake)),
                                capture_output=True, text=True, timeout=45)
        receipt = json.loads(result.stdout)
        requests = [json.loads(line) for line in (self.root / "requests.jsonl").read_text().splitlines()] \
            if (self.root / "requests.jsonl").exists() else []
        self.assertFalse(any(set(row) & {"-X", "--method", "-f", "-F", "--field", "--raw-field"}
                             for row in requests), "CLI controls must not attempt writes")
        return result.returncode, receipt

    def test_cli_budget_exhausted_roll_refuses_even_with_supplemental_success(self):
        self.approvals()
        self.get("actions/runs/900")["conclusion"] = "failure"
        jobs = self.get("actions/runs/900/jobs?per_page=100")["jobs"]
        dev = next(job for job in jobs if job["name"] == "dune build @check")
        dev.update(conclusion="failure", steps=[{
            "name": "Run the tests this pull request edits", "status": "completed", "conclusion": "failure"}])
        self.put(f"check-runs/{dev['id']}/annotations?per_page=100", [{
            "annotation_level": "failure", "message": "not run: the step budget ran out"}])
        # A successful diagnostic Test run cannot replace the red PR check.
        diagnostic = copy.deepcopy(self.get("actions/runs/900"))
        diagnostic.update(id=999, workflow_id=71, run_number=11, event="workflow_dispatch",
                          path=".github/workflows/test.yml", status="completed", conclusion="success")
        self.get(f"actions/runs?head_sha={self.roll}&per_page=100")["workflow_runs"].append(diagnostic)
        code, receipt = self.cli()
        self.assertEqual((code, receipt["status"]), (3, "unavailable"), receipt)
        self.assertEqual(receipt["reason"], "batch_run_not_current_successful_exact_pr_check")

    def test_cli_roll_job_failure_is_three_and_member_run_failure_is_six(self):
        jobs = self.get("actions/runs/900/jobs?per_page=100")["jobs"]
        jobs[0]["conclusion"] = "failure"
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (3, "batch_required_jobs_not_all_successful"))
        jobs[0]["conclusion"] = "success"
        self.get("actions/runs/901")["conclusion"] = "failure"
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (6, "batch_run_not_current_successful_exact_pr_check"))
        self.get("actions/runs/901")["conclusion"] = "success"
        self.get(f"actions/runs?head_sha={self.heads[1]}&event=pull_request&per_page=100")["workflow_runs"] = []
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (6, "pr_check_run_unavailable"))

    def test_cli_wrong_landing_tree_is_four(self):
        self.land(1, wrong=True)
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (4, "batch_member_landing_tree_mismatch"))

    def test_cli_external_shared_input_is_five(self):
        self.main = self.change(self.base, "config/runtime.toml", "external shared input\n")
        self.put("commits/main", {"sha": self.main})
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (5, "batch_nonmember_main_change_invalidates_roll"))

    def test_cli_moved_head_and_missing_bound_approval_are_six(self):
        self.get("pulls/2")["head"]["sha"] = self.base
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (6, "batch_member_head_or_base_changed"))
        self.get("pulls/2")["head"]["sha"] = self.heads[2]
        self.approvals()
        self.put("pulls/2/reviews?per_page=100", [])
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (6, "evidence_read_failed"))

    def test_cli_invalid_input_and_infrastructure_are_distinct(self):
        code, receipt = self.cli(line="not a batch line\n")
        self.assertEqual((code, receipt["reason"]), (2, "invalid_evidence"))
        del self.data[PREFIX + "/actions/runs/900"]
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (1, "evidence_read_failed"))

    def test_cli_status_keeps_success_and_pending_distinct(self):
        # The asynchronous pending transition itself uses the real-Git land
        # control above; here hold its result fixed at the public CLI boundary.
        for status, code in [("checked", 0), ("pending", 7), ("unexpected", 2)]:
            with self.subTest(status=status), patch.object(sys, "argv", [
                    "batch_evidence.py", "--repo", "o/r", "--batch", "unused",
                    "--git-dir", str(self.repo)]), \
                 patch.object(B, "land", return_value={"status": status}), redirect_stdout(io.StringIO()) as output:
                self.assertEqual(B.main(), code)
                self.assertEqual(json.loads(output.getvalue())["status"], status)


if __name__ == "__main__":
    unittest.main()
