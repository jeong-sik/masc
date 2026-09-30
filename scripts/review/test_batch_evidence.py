#!/usr/bin/env python3
"""Combined-tree evidence controls: real Git, fake GitHub, no builds/network."""
import copy
import ast
from contextlib import ExitStack, contextmanager, redirect_stdout
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
RI = load("batch_test_roll_input", HERE / "roll_input.py")
E = B.ExitCode
R = B.Reason
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
            self.install_pr(pr, head)
        self.set_line()
        self.put("commits/main", {"sha": self.main})
        self.fixture = self.root / "api.json"
        self.fake = self.root / "gh"
        real_jq = shutil.which("jq")
        if real_jq is None:
            self.fail("fake GitHub responses require jq on the test host")
        # Keep the fixture's dependency available when a scenario removes jq
        # from the guard's PATH. Discover it on this host before that change.
        self.fake.write_text("#!/usr/bin/env python3\nJQ = "
                             + repr(str(Path(real_jq).resolve())) + "\n" + """
import json, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with Path(__file__).with_name('requests.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\\n')
data = json.loads(Path(__file__).with_name('api.json').read_text())
if args[:2] == ['run', 'download']:
    target = Path(args[args.index('--dir') + 1])
    target.mkdir(parents=True, exist_ok=True)
    (target / 'roll-evidence.json').write_text(json.dumps(data['__roll_receipt']))
    raise SystemExit(0)
if not args or args[0] != 'api':
    raise SystemExit('fixture refuses non-API operation')
endpoint = next(a for a in args[1:] if a == 'user' or a.startswith('repos/'))
if any(arg in {'-X', '--method', '-f', '-F', '--field', '--raw-field'} for arg in args):
    if args[1:3] == ['-X', 'PUT'] and endpoint.endswith('/merge-async') and '__write_exit' in data:
        raise SystemExit(data['__write_exit'])
    raise SystemExit('fixture refuses API writes')
if endpoint not in data:
    raise SystemExit('unknown fixture endpoint: ' + endpoint)
responses = data.get('__responses', {}).get(endpoint)
if responses:
    selected = responses.pop(0) if len(responses) > 1 else responses[0]
    Path(__file__).with_name('api.json').write_text(json.dumps(data))
else:
    selected = data[endpoint]
mutation = data.get('__after_reads', {}).get(endpoint)
if mutation:
    mutation['remaining'] -= 1
    if mutation['remaining'] == 0:
        data.update(mutation['values'])
        del data['__after_reads'][endpoint]
    Path(__file__).with_name('api.json').write_text(json.dumps(data))
value = json.dumps(selected)
if '--jq' in args:
    raise SystemExit(subprocess.run([JQ, '-r', args[args.index('--jq') + 1]],
                                   input=value, text=True).returncode)
print(value)
""")
        self.fake.chmod(0o755)

    def install_pr(self, pr, head):
        branch = f"branch-{pr}"
        self.put(f"pulls/{pr}", {
            "number": pr, "state": "open", "draft": False, "merged": False,
            "merge_commit_sha": None, "user": {"login": f"author-{pr}"},
            "base": {"ref": "main", "sha": self.base}, "head": {"sha": head, "ref": branch}})
        run_id = self.run_ids[pr]
        run = {"id": run_id, "run_number": 10, "run_attempt": 1, "workflow_id": 70,
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
            if endpoint not in self.data:
                raise F.Unavailable("evidence_read_failed")
            value = self.data[endpoint]
        return copy.deepcopy(value)

    def later(self, path, value):
        key = PREFIX + "/" + path
        self.responses[key] = [copy.deepcopy(self.data[key]), value]

    def set_line(self, members=None):
        members = members or list(self.heads)
        self.line = (f"batch: PASS landing: ROLL roll: {self.roll} base: {self.base} run: 900 members: "
                     + ",".join(f"{pr}@{self.heads[pr]}" for pr in members) + " by: keeper")
        fields = {"base": self.base, "members": [
            {"pr": pr, "head": self.heads[pr],
             "review_base": self.get(f"pulls/{pr}")["base"]["sha"]}
            for pr in members]}
        body = "<!-- masc-roll-input-v1\n" + json.dumps(fields) + "\n-->"
        self.get("pulls/99")["body"] = body
        roll_tree = self.git("rev-parse", self.roll + "^{tree}")
        checkout = self.git("commit-tree", roll_tree, "-p", self.base,
                            "-p", self.roll, input="PR merge checkout\n")
        self.put(f"git/commits/{checkout}", {
            "sha": checkout, "tree": {"sha": roll_tree},
            "parents": [{"sha": self.base}, {"sha": self.roll}]})
        self.data["__roll_receipt"] = {
            "schema": "masc.roll.run.v1", "input_digest": RI.parse_body(body)["digest"],
            "base": self.base, "members": fields["members"],
            "roll_pr": 99, "roll_head": self.roll, "roll_tree": roll_tree,
            "checkout_commit": checkout, "run_id": 900, "run_attempt": 1,
            "required_suites": ["test/suite_a.py"],
            "executed_suites": ["test/suite_a.py"],
            "missing_suites": [], "unexpected_suites": [],
            "runner_exit": 0, "result": "success"}
        for pr in [*self.heads, 99]:
            comments = [{"id": pr * 10, "body": self.line,
                         "author_association": "COLLABORATOR", "user": {"login": "publisher"},
                         "created_at": "2026-01-01T00:40:00Z"}]
            if pr == 99:
                comments.append({"id": pr * 10 + 1,
                    "body": f"verdict: PASS head: {self.roll} run: {self.run_ids[pr]} by: reviewer",
                    "author_association": "MEMBER", "user": {"login": "reviewer"},
                    "created_at": "2026-01-01T00:41:00Z"})
            self.put(f"issues/{pr}/comments?per_page=100", comments)
            if pr != 99:
                member_base = self.get(f"pulls/{pr}")["base"]["sha"]
                self.put(f"pulls/{pr}/reviews?per_page=100", [{
                    "id": 100 + pr, "state": "COMMENTED", "author_association": "MEMBER",
                    "user": {"login": "independent-reviewer"},
                    "commit_id": self.heads[pr],
                    "submitted_at": "2026-01-01T00:42:00Z",
                    "body": (f"member-review: COMPLETE pr: {pr} "
                             f"base: {member_base} "
                             f"head: {self.heads[pr]} scope: full-delta by: reviewer")
                }])

    def evaluate(self, pr=1, *, landing=False, real_gates=False, run_override=None):
        self.fixture.write_text(json.dumps(self.data))
        with ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, {"GUARD_GH": str(self.fake)}))
            stack.enter_context(patch.object(F, "api", self.api))
            stack.enter_context(patch.object(F, "api_pages", lambda gh, endpoint: [self.api(gh, endpoint)]))
            if not real_gates:
                def checks(_f, _gh, _repo, checked_pr, _head, _git_dir, **_kwargs):
                    self.assertFalse(self.get(f"pulls/{checked_pr}")["merged"],
                                     "published batch must not invoke open-PR CI gates")
                stack.enter_context(patch.object(B, "current_checks", side_effect=checks))
            return B.evaluate(F, line=self.line, repo="o/r", pr=pr, head=self.roll if pr == 99 else self.heads[pr],
                              run=run_override if run_override is not None else (self.run_ids[pr] if pr == 99 else None),
                              git_dir=str(self.repo),
                              gh=str(self.fake), landing=landing)

    def approvals(self):
        for pr, head in [(99, self.roll)]:
            review = {"id": 100 + pr, "state": "APPROVED",
                      "user": {"login": "independent-reviewer"},
                      "author_association": "MEMBER", "commit_id": head,
                      "submitted_at": "2026-01-01T00:42:00Z",
                      "body": f"verdict: PASS head: {head} run: {self.run_ids[pr]} by: reviewer\n\n"
                              f"approve-guard: head `{head}` · fixture evidence"}
            self.put(f"pulls/{pr}/reviews?per_page=100", [review])
            self.put(f"pulls/{pr}/reviews/{review['id']}", review)

    @contextmanager
    def refused(self, reason, code):
        """Expect a batch Refusal with receipt token `reason` and exit `code`."""
        with self.assertRaises(B.Refusal) as caught:
            yield
        self.assertEqual((caught.exception.reason, caught.exception.code), (B.Reason(reason), code))

    def refusal(self, reason, code, **kwargs):
        with self.refused(reason, code):
            self.evaluate(**kwargs)

    def publish_roll(self, parent=None, *, wrong=False):
        parent = parent or self.main
        if wrong:
            commit = self.change(parent, "lib/one.ml", "wrong landing\n")
        else:
            tree = self.git("merge-tree", "--write-tree", parent, self.roll).splitlines()[0]
            commit = self.git("commit-tree", tree, "-p", parent, input="Squash ROLL\n")
        self.get("pulls/99").update(state="closed", merged=True, merge_commit_sha=commit)
        self.main = commit
        self.put("commits/main", {"sha": commit})
        return commit

    def run_landing(self, mode="success", *, check_only=False):
        """Keep Git/evaluate/exact_run/approval real; stub CI and the single ROLL write.

        The current_checks stub forbids published-batch CI calls. Actual CI gates
        and --batch wrappers have separate subprocess controls. The mutating
        merge-guard command becomes local Git/API-state changes, never a live API
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
                self.assertEqual(pr, 99, "only ROLL may be published")
                self.assertEqual(args[args.index("--head") + 1], self.roll)
                self.assertEqual(Path(args[args.index("--batch") + 1]).read_text().strip(), self.line)
                self.writes.append(pr)
                if mode != "pending":
                    parent = self.main
                    if mode == "wrong-parent":
                        parent = self.change(parent, "docs/racing.md", "Concurrent main arrival\n")
                    self.publish_roll(parent, wrong=mode == "wrong-tree")
                    self.fixture.write_text(json.dumps(self.data))
                self.write_read_offsets.append(len(self.calls))
                return '{"submitted": true}'
            return original_command(args)
        def checks(_f, _gh, _repo, pr, _head, _git_dir, **_kwargs):
            self.assertFalse(self.get(f"pulls/{pr}")["merged"],
                             "published batch must not rerun the open-PR CI gate")
        with patch.dict(os.environ, {"GUARD_GH": str(self.fake)}), \
             patch.object(F, "api", self.api), \
             patch.object(F, "api_pages", lambda gh, endpoint: [self.api(gh, endpoint)]), \
             patch.object(F, "command", side_effect=command), \
             patch.object(B, "merge_guard", side_effect=lambda args: command(args)), \
             patch.object(B, "current_checks", side_effect=checks):
            landed = B.land(F, batch_file=str(batch), repo="o/r", git_dir=str(self.repo),
                            gh=str(self.fake), check_only=check_only)
        self.assertIsInstance(landed.status, B.LandStatus)
        self.assertEqual(landed.receipt["status"], landed.status.value)
        return landed.receipt




    def test_roll_input_parser_is_exact_and_digest_is_stable(self):
        body = self.get("pulls/99")["body"]
        first = RI.parse_body(body)
        fields = {"members": list(reversed(first["members"])), "base": first["base"]}
        reordered_keys = "<!-- masc-roll-input-v1\n" + json.dumps(fields) + "\n-->"
        self.assertNotEqual(first["digest"], RI.parse_body(reordered_keys)["digest"])
        with self.assertRaisesRegex(ValueError, "exactly one"):
            RI.parse_body(body + "\n" + body)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            RI.parse_body('<!-- masc-roll-input-v1\n{"base":"'
                          + self.base + '","base":"' + self.base
                          + '","members":[]}\n-->')
        with self.assertRaisesRegex(ValueError, "invalid ROLL member fields"):
            RI.parse_body(body.replace('"review_base":', '"partial_base":'))

    def test_roll_body_and_run_receipt_must_match_current_inputs(self):
        original = copy.deepcopy(self.data)
        self.get("pulls/99")["body"] = self.get("pulls/99")["body"].replace(
            self.base, self.heads[1], 1)
        self.refusal("batch_roll_input_mismatch", E.ROLL)
        self.data = copy.deepcopy(original)
        for field, value in [
            ("input_digest", "sha256:" + "0" * 64),
            ("base", self.heads[1]),
            ("members", []),
            ("roll_head", self.heads[1]),
            ("roll_tree", self.base),
            ("checkout_commit", self.base),
            ("run_id", 901),
            ("run_attempt", 2),
            ("result", "failure"),
            ("runner_exit", 1),
            ("missing_suites", ["test/suite_a.py"]),
            ("unexpected_suites", ["test/extra.py"]),
            ("required_suites", []),
            ("executed_suites", []),
            ("executed_suites", ["test/suite_b.py"]),
            ("required_suites", ["test/suite_b.py", "test/suite_a.py"]),
            ("executed_suites", ["../test/suite_a.py"])]:
            with self.subTest(field=field, value=value):
                self.data["__roll_receipt"][field] = value
                self.refusal("batch_roll_run_receipt_mismatch", E.ROLL)
                self.data = copy.deepcopy(original)

    def test_run_rerun_attempt_during_final_admission_refuses(self):
        endpoint = PREFIX + "/actions/runs/900"
        current = copy.deepcopy(self.get("actions/runs/900"))
        rerun = copy.deepcopy(current)
        rerun["run_attempt"] = 2
        self.responses[endpoint] = [current, current, rerun]
        self.refusal("batch_roll_run_receipt_mismatch", E.ROLL)

    def test_run_checkout_commit_must_bind_base_and_roll(self):
        checkout = self.data["__roll_receipt"]["checkout_commit"]
        commit = self.get(f"git/commits/{checkout}")
        original = copy.deepcopy(commit)
        commit["parents"][0]["sha"] = self.heads[1]
        self.refusal("batch_roll_run_receipt_mismatch", E.ROLL)
        self.put(f"git/commits/{checkout}", copy.deepcopy(original))
        self.get(f"git/commits/{checkout}")["tree"]["sha"] = self.base
        self.refusal("batch_roll_run_receipt_mismatch", E.ROLL)

    def test_roll_body_change_during_final_admission_refuses(self):
        moved = copy.deepcopy(self.get("pulls/99"))
        moved["body"] = moved["body"].replace(self.heads[1], self.base, 1)
        self.later("pulls/99", moved)
        self.refusal("batch_roll_input_mismatch", E.ROLL)

    def test_divergent_main_uses_merge_base_for_first_member_review(self):
        source_base = self.base
        new_base = self.change(source_base, "lib/main_new.ml", "let main_new = 1\n")
        self.git("checkout", "-q", "--detach", new_base)
        self.git("merge", "-q", "--no-ff", "--no-edit", self.heads[1])
        self.base = new_base
        self.main = new_base
        self.roll = self.git("rev-parse", "HEAD")
        self.install_pr(99, self.roll)
        self.put("commits/main", {"sha": new_base})
        # Source review still covers the original branch delta, not new main.
        self.set_line([1])
        self.approvals()
        receipt = self.evaluate(pr=99, landing=True)
        self.assertEqual(receipt["status"], "fresh")
        self.assertEqual(receipt["members"][0]["base"], source_base)
        self.get("pulls/1/reviews?per_page=100")[0]["body"] = (
            self.get("pulls/1/reviews?per_page=100")[0]["body"].replace(
                f"base: {source_base}", f"base: {new_base}"))
        self.refusal("batch_member_without_current_review", E.MEMBER, pr=99, landing=True)

    def test_stacked_members_use_roll_ci_without_member_runs(self):
        parent = self.heads[1]
        child = self.change(parent, "lib/two.ml", "let two = 2\n")
        self.git("checkout", "-q", "--detach", self.base)
        self.git("merge", "-q", "--no-ff", "--no-edit", child)
        self.heads[2] = child
        self.roll = self.git("rev-parse", "HEAD")
        self.install_pr(2, child)
        self.install_pr(99, self.roll)
        self.get("pulls/2")["base"] = {"ref": "branch-1", "sha": parent}
        self.set_line()
        self.approvals()
        for member in (1, 2):
            head = self.heads[member]
            run = self.run_ids[member]
            for endpoint in (f"actions/runs/{run}",
                             f"actions/runs?head_sha={head}&event=pull_request&per_page=100",
                             f"actions/runs?head_sha={head}&per_page=100",
                             f"actions/runs/{run}/jobs?per_page=100",
                             f"commits/{head}/check-runs?per_page=100"):
                self.data.pop(PREFIX + "/" + endpoint, None)
        receipt = self.evaluate(pr=99, landing=True)
        self.assertEqual(receipt["status"], "fresh")
        self.assertEqual(receipt["roll_run"], 900)
        self.assertEqual([(row["pr"], row["base"], row["review_id"])
                          for row in receipt["members"]],
                         [(1, self.base, 101), (2, parent, 102)])
        self.assertTrue(all("run" not in row for row in receipt["members"]))
        landed = self.run_landing()
        self.assertEqual((landed["status"], landed["absorption_candidates"]),
                         ("published", [1, 2]))

    def test_stacked_child_base_or_review_commit_change_refuses(self):
        self.get("pulls/2")["base"] = {"ref": "branch-1", "sha": self.heads[1]}
        self.refusal("batch_member_head_or_base_changed", E.MEMBER)
        self.get("pulls/2")["base"] = {"ref": "main", "sha": self.base}
        self.get("pulls/2/reviews?per_page=100")[0]["commit_id"] = self.base
        self.refusal("batch_member_without_current_review", E.MEMBER)

    def test_member_run_number_cannot_impersonate_roll_receipt(self):
        self.refusal("batch_member_run_not_applicable", E.MEMBER, run_override=901)

    def test_member_late_fail_or_hold_refuses_without_member_ci(self):
        for verdict in ("FAIL", "HOLD"):
            with self.subTest(verdict=verdict):
                self.get("issues/2/comments?per_page=100").append({
                    "id": 999, "created_at": "2026-01-01T00:50:00Z",
                    "author_association": "MEMBER", "user": {"login": "reviewer"},
                    "body": f"verdict: {verdict} head: {self.heads[2]} run: 902 by: reviewer"})
                self.refusal("batch_member_has_late_fail", E.MEMBER)
                self.get("issues/2/comments?per_page=100").pop()

    def test_three_members_publish_only_tested_complete_tree(self):
        base = self.base
        for flag in "abc":
            base = self.change(base, f"flags/{flag}", "0\n")
        self.base = base
        self.heads = {n: self.change(base, f"flags/{flag}", "1\n")
                      for n, flag in enumerate("abc", 1)}
        self.run_ids[3] = 903
        self.git("checkout", "-q", "--detach", base)
        prefixes = []
        for head in self.heads.values():
            self.git("merge", "-q", "--no-ff", "--no-edit", head)
            prefixes.append(self.git("rev-parse", "HEAD"))
        self.roll = prefixes[-1]
        self.main = base
        self.put("commits/main", {"sha": base})
        for pr, head in [*self.heads.items(), (99, self.roll)]:
            self.install_pr(pr, head)
        self.set_line()
        self.approvals()
        def healthy(commit):
            a, b, c = (self.git("show", f"{commit}:flags/{flag}") == "1" for flag in "abc")
            return not (a and b and not c)
        self.assertTrue(all(healthy(head) for head in self.heads.values()))
        self.assertFalse(healthy(prefixes[1]), "A+B is an untested failing intermediate state")
        self.assertTrue(healthy(self.roll))
        result = self.run_landing()
        self.assertEqual(self.writes, [99], "member prefixes must never be written to main")
        self.assertEqual((result["status"], result["absorption_candidates"]), ("published", [1, 2, 3]))
        self.assertEqual(result["tree"], self.git("rev-parse", self.roll + "^{tree}"))
        self.assertEqual(self.git("show", "--no-patch", "--format=%P", result["merge_commit"]), base)
        self.assertTrue(healthy(self.main))
        self.assertTrue(all(self.get(f"pulls/{pr}")["state"] == "open" for pr in self.heads))

    def test_pending_roll_resume_proves_arrival_before_absorption(self):
        self.approvals()
        result = self.run_landing("pending")
        self.assertEqual((result["status"], result["pr"], self.writes), ("pending", 99, [99]))
        observation = result["preflight_observation"]
        self.assertEqual(observation["scope"], "preflight_before_merge_guard_not_write_boundary")
        self.assertEqual([(row["pr"], row["approval_ids"]) for row in observation["approvals"]],
                         [(99, [199])])
        self.assertEqual(observation["members"],
                         [{"pr": pr, "head": head, "base": self.base, "review_id": 100 + pr}
                          for pr, head in self.heads.items()])
        self.assertNotIn("absorption_candidates", result)
        self.assertEqual(self.calls[self.write_read_offsets[0]:], [PREFIX + "/pulls/99"])
        self.assertEqual(self.main, self.base)
        repeated = self.run_landing("pending")
        self.assertEqual((repeated["status"], self.writes, self.main), ("pending", [99], self.base))
        self.assertNotIn("absorption_candidates", repeated)
        self.publish_roll()
        result = self.run_landing()
        self.assertEqual(self.writes, [], "resume must not submit another merge")
        self.assertEqual(result["absorption_candidates"], [1, 2])
        self.assertNotIn("preflight_observation", result)
        self.assertEqual(result["historical_approval_mapping"], "unavailable_without_saved_preflight_receipt")
        # Metadata closure is a separate Keeper action, not a code merge.
        self.get("pulls/1")["state"] = "closed"
        result = self.run_landing()
        self.assertEqual((self.writes, result["absorption_candidates"]), ([], [2]))

    def test_resume_proves_landing_after_later_member_path_edit(self):
        self.approvals()
        pending = self.run_landing("pending")
        self.assertEqual((pending["status"], self.writes), ("pending", [99]))
        landed = self.publish_roll()
        later = self.change(landed, "lib/one.ml", "let one = 42\n")
        self.main = later
        self.put("commits/main", {"sha": later})
        result = self.run_landing()
        self.assertEqual(self.writes, [], "resume must not submit another merge")
        self.assertEqual((result["status"], result["absorption_candidates"]),
                         ("published", [1, 2]))
        self.assertEqual(result["merge_commit"], landed)
        self.assertEqual(result["landing_parent"], self.base)
        self.assertEqual(result["main"], later)
        self.assertEqual(result["tree"], self.git("rev-parse", landed + "^{tree}"))
        self.assertNotEqual(result["tree"], self.git("rev-parse", later + "^{tree}"))
        self.assertEqual(result["post_landing_commits"], [later])

    def test_resume_still_rejects_member_path_change_before_landing(self):
        self.approvals()
        before = self.change(self.base, "lib/one.ml", "let one = 1\n")
        self.publish_roll(parent=before)
        with self.refused("batch_nonmember_main_change_invalidates_roll", E.MAIN_OVERLAP):
            self.run_landing()
        self.assertEqual(self.writes, [])

    def test_roll_arrival_rejects_wrong_parent_tree_and_missing_main_ancestry(self):
        self.approvals()
        original = copy.deepcopy(self.data)
        for mode, reason in [("wrong-parent", "batch_main_changed_at_merge_write"),
                             ("wrong-tree", "batch_roll_landing_tree_mismatch")]:
            with self.subTest(mode=mode):
                self.data = copy.deepcopy(original)
                self.main = self.base
                with self.refused(reason, E.LANDING):
                    self.run_landing(mode)
                self.assertEqual(self.writes, [99])
        self.data = copy.deepcopy(original)
        self.main = self.base
        self.publish_roll()
        self.put("commits/main", {"sha": self.base})
        with self.refused("batch_roll_merge_not_in_main_history", E.LANDING):
            self.run_landing()
        self.assertEqual(self.writes, [])

    def test_roll_resume_rejects_two_parent_merge_with_correct_tree(self):
        tree = self.git("rev-parse", self.roll + "^{tree}")
        merged = self.git("commit-tree", tree, "-p", self.base, "-p", self.roll, input="Not a squash\n")
        self.get("pulls/99").update(state="closed", merged=True, merge_commit_sha=merged)
        self.put("commits/main", {"sha": merged})
        with self.refused("batch_roll_landing_is_not_a_squash", E.LANDING):
            self.run_landing()
        self.assertEqual(self.writes, [])

    def test_direct_member_landing_and_implicit_manifest_refuse(self):
        self.approvals()
        self.refusal("batch_landing_requires_roll", E.MEMBER, landing=True)
        with self.assertRaisesRegex(ValueError, "^invalid_batch_line$"):
            B.parse(self.line.replace("landing: ROLL ", ""))

    def test_roll_needs_own_pass_and_independent_bound_approval(self):
        self.approvals()
        original = copy.deepcopy(self.data)
        self.put("issues/99/comments?per_page=100", self.get("issues/99/comments?per_page=100")[:1])
        self.put("pulls/99/reviews?per_page=100", [])
        self.refusal("batch_roll_review_refuses_evidence", E.ROLL, pr=99, landing=True)
        self.data = copy.deepcopy(original)
        review = self.get("pulls/99/reviews?per_page=100")[0]
        review["user"]["login"] = "author-99"
        self.refusal("evidence_read_failed", E.MEMBER, pr=99, landing=True)

    def test_cli_final_member_source_review_dismissal_refuses_without_write(self):
        self.approvals()
        review = copy.deepcopy(self.get("pulls/2/reviews?per_page=100")[0])
        review["state"] = "DISMISSED"
        # The last main read follows all CI/tree/verdict snapshots. A later
        # A member loses its source review immediately before admission.
        self.data["__after_reads"] = {PREFIX + "/commits/main": {
            "remaining": 2, "values": {
                PREFIX + "/pulls/2/reviews": [review],
                PREFIX + "/pulls/2/reviews?per_page=100": [review],
                PREFIX + f"/pulls/2/reviews/{review['id']}": review}}}
        code, receipt = self.cli(check_only=False)
        self.assertEqual((code, receipt["status"], receipt["reason"]),
                         (6, "unavailable", "evidence_read_failed"))
        saved = json.loads(self.fixture.read_text())
        self.assertFalse(saved["__after_reads"], "dismissal must occur at the final boundary")

    def test_approval_json_receipt_is_read_only_and_requires_merge_check(self):
        self.approvals()
        self.fixture.write_text(json.dumps(self.data))
        args = ["bash", str(HERE / "approve-guard.sh"), "--repo", "o/r", "--pr", "1",
                "--head", self.heads[1], "--git-dir", str(self.repo), "--receipt-json"]
        for extra in [[], ["--check"], ["--check", "--merge-check"]]:
            with self.subTest(extra=extra):
                result = subprocess.run(args + extra, env=dict(os.environ, GUARD_GH=str(self.fake)),
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse((self.root / "requests.jsonl").exists(), "invalid modes must stop before API reads")
        nojq = self.root / "nojq"
        nojq.mkdir()
        (nojq / "jq").write_text("#!/bin/sh\nexit 127\n")
        (nojq / "jq").chmod(0o755)
        result = subprocess.run(args + ["--merge-check"], env=dict(os.environ, GUARD_GH=str(self.fake),
                                PATH=str(nojq) + os.pathsep + os.environ["PATH"]),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("no non-author APPROVED review", result.stdout + result.stderr)
        requests = [json.loads(line) for line in (self.root / "requests.jsonl").read_text().splitlines()]
        self.assertFalse(any(set(row) & {"-X", "--method", "-f", "-F", "--field", "--raw-field"}
                             for row in requests))

    def test_published_batch_member_freshness_refuses_in_json_and_ledger(self):
        self.approvals()
        self.publish_roll()
        self.get("actions/runs/901")["created_at"] = "2026-01-01T00:30:00Z"
        self.fixture.write_text(json.dumps(self.data))
        batch = self.root / "arrived-batch.txt"
        batch.write_text(self.line + "\n")
        args = [sys.executable, str(HERE / "ci-freshness.py"), "--repo", "o/r", "--pr", "1",
                "--head", self.heads[1], "--run", "901", "--git-dir", str(self.repo), "--batch", str(batch)]
        for output in ["json", "ledger"]:
            with self.subTest(output=output):
                result = subprocess.run(args + ["--format", output],
                                        env=dict(os.environ, GUARD_GH=str(self.fake)),
                                        capture_output=True, text=True, timeout=20)
                self.assertNotIn("Traceback", result.stderr)
                if output == "json":
                    self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
                    receipt = json.loads(result.stdout)
                    self.assertEqual((receipt["status"], receipt["reason"]),
                                     ("unavailable", "batch_roll_already_merged"))
                    self.assertNotIn("absorption_candidates", receipt)
                else:
                    self.assertEqual((result.returncode, result.stdout.strip()), (0, "unknown:freshness\t?"))

    def test_freshness_cli_roll_failure_code_and_landing_requires_batch(self):
        self.approvals()
        manifest = self.root / "batch.txt"
        manifest.write_text(self.line)
        args = [sys.executable, str(HERE / "ci-freshness.py"), "--repo", "o/r",
                "--pr", "99", "--head", self.roll, "--run", "900", "--git-dir", str(self.repo)]
        for status, conclusion in [("completed", "failure"), ("queued", None)]:
            self.get("actions/runs/900").update(status=status, conclusion=conclusion)
            self.fixture.write_text(json.dumps(self.data))
            result = subprocess.run(args + ["--batch", str(manifest)],
                env=dict(os.environ, GUARD_GH=str(self.fake)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        result = subprocess.run(args + ["--landing"],
            env=dict(os.environ, GUARD_GH=str(self.fake)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["reason"], "landing_requires_batch")

    def test_red_roll_or_member_run_refuses(self):
        self.get("actions/runs/900")["conclusion"] = "failure"
        self.refusal("batch_run_not_current_successful_exact_pr_check", E.ROLL)
        self.get("actions/runs/900")["conclusion"] = "success"
        for run in [901, 902]:
            self.get(f"actions/runs/{run}")["conclusion"] = "failure"
        self.assertEqual(self.evaluate()["status"], "fresh")

    def test_foreign_run_identity_refuses(self):
        original = copy.deepcopy(self.get("actions/runs/900"))
        for field, value in [("head_sha", self.heads[1]), ("event", "workflow_dispatch"),
                             ("head_branch", "foreign"), ("pull_requests", [{"number": 1}])]:
            with self.subTest(field=field):
                self.get("actions/runs/900")[field] = value
                with self.assertRaises(B.Refusal):
                    self.evaluate()
                self.put("actions/runs/900", copy.deepcopy(original))

    def test_newer_queued_run_invalidates_completed_roll(self):
        newer = copy.deepcopy(self.get("actions/runs/900"))
        newer.update(id=999, run_number=11, status="queued", conclusion=None)
        self.get(f"actions/runs?head_sha={self.roll}&event=pull_request&per_page=100")["workflow_runs"].append(newer)
        self.refusal("batch_run_not_current_successful_exact_pr_check", E.ROLL)

    def test_absent_run_association_requires_matching_suite(self):
        self.get("actions/runs/900")["pull_requests"] = []
        self.assertEqual(self.evaluate()["status"], "fresh")
        self.get("check-suites/1900")["pull_requests"] = [{"number": 7}]
        self.put("pulls/7", copy.deepcopy(self.get("pulls/1")))
        self.refusal("batch_roll_pr_identity_unavailable", E.ROLL)

    def test_empty_run_association_rejects_ambiguous_suite(self):
        run = self.get("actions/runs/900")
        run["pull_requests"] = []
        self.put(f"check-suites/{run['check_suite_id']}", {
            "head_sha": self.roll, "head_branch": "branch-99",
            "pull_requests": [{"number": 99}, {"number": 100}]})
        self.put("pulls/100", copy.deepcopy(self.get("pulls/1")))
        self.refusal("batch_run_suite_not_linked_to_pr", E.ROLL)

    def test_cancelled_newer_twin_does_not_replace_valid_run(self):
        cancelled = copy.deepcopy(self.get("actions/runs/900"))
        cancelled.update(id=999, run_number=11, conclusion="cancelled")
        self.get(f"actions/runs?head_sha={self.roll}&event=pull_request&per_page=100")["workflow_runs"].append(cancelled)
        self.assertEqual(self.evaluate()["roll_run"], 900)

    def test_missing_or_skipped_required_job_refuses(self):
        jobs = self.get("actions/runs/900/jobs?per_page=100")["jobs"]
        missing = jobs.pop()
        self.refusal("batch_required_jobs_not_all_successful", E.ROLL)
        jobs.append(missing)
        jobs[-1]["conclusion"] = "skipped"
        self.refusal("batch_required_jobs_not_all_successful", E.ROLL)

    def test_member_head_move_refuses(self):
        self.get("pulls/2")["head"]["sha"] = self.base
        self.refusal("batch_member_head_or_base_changed", E.MEMBER)

    def test_outsider_publication_refuses(self):
        for pr in [1, 99]:
            with self.subTest(pr=pr):
                self.get(f"issues/{pr}/comments?per_page=100")[0]["author_association"] = "NONE"
                self.refusal("batch_line_not_published_by_trusted_participant",
                             E.ROLL if pr == 99 else E.MEMBER)
                self.get(f"issues/{pr}/comments?per_page=100")[0]["author_association"] = "COLLABORATOR"

    def test_formal_change_request_refuses(self):
        self.get("pulls/2/reviews?per_page=100").append(
            {"id": 200, "state": "CHANGES_REQUESTED", "user": {"login": "reviewer"}})
        self.refusal("batch_member_has_open_change_request", E.MEMBER)

    def test_roll_formal_change_request_refuses_initial_and_late(self):
        reviews = [{"id": 1, "state": "CHANGES_REQUESTED", "user": {"login": "reviewer"}}]
        self.put("pulls/99/reviews?per_page=100", reviews)
        self.refusal("batch_member_has_open_change_request", E.ROLL)
        self.put("pulls/99/reviews?per_page=100", [])
        self.later("pulls/99/reviews?per_page=100", reviews)
        self.refusal("batch_member_has_open_change_request", E.ROLL)

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
                self.refusal("batch_roll_review_refuses_evidence", E.ROLL)


    def test_external_shared_and_overlap_changes_refuse(self):
        for path in ["config/runtime.toml", "specs/auth/AuthIdentityFSM.tla", "lib/one.ml"]:
            with self.subTest(path=path):
                self.put("commits/main", {"sha": self.change(self.base, path, "external change\n")})
                self.refusal("batch_nonmember_main_change_invalidates_roll", E.MAIN_OVERLAP)

    def test_external_unrelated_document_is_retained(self):
        self.approvals()
        self.main = self.change(self.base, "docs/unrelated.md", "External note\n")
        self.put("commits/main", {"sha": self.main})
        result = self.evaluate(pr=99, landing=True)
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
        self.refusal("batch_roll_tree_does_not_match_members", E.LANDING)




    def test_missing_history_refuses(self):
        self.main = self.change(self.base, "docs/unrelated.md", "External note\n")
        self.put("commits/main", {"sha": self.main})
        (self.repo / ".git/shallow").write_text(self.main + "\n")
        self.refusal("batch_base_not_in_available_main_history", E.INFRASTRUCTURE)

    def test_late_member_and_main_state_changes_refuse(self):
        moved = copy.deepcopy(self.get("pulls/2"))
        moved["head"]["sha"] = self.base
        self.later("pulls/2", moved)
        self.refusal("batch_member_moved_during_check", E.MEMBER)
        self.responses.clear()
        self.later("commits/main", {"sha": self.roll})
        self.refusal("batch_roll_or_main_moved_during_check", E.INVALID)

    def test_late_publication_or_change_request_refuses(self):
        self.later("issues/2/comments?per_page=100", [])
        self.refusal("batch_line_not_published_by_trusted_participant", E.MEMBER)
        self.responses.clear()
        self.later("pulls/2/reviews?per_page=100", [
            {"id": 2, "state": "CHANGES_REQUESTED", "user": {"login": "reviewer"}}])
        self.refusal("batch_member_has_open_change_request", E.MEMBER)

    def test_late_roll_draft_change_refuses(self):
        moved = copy.deepcopy(self.get("pulls/99"))
        moved["draft"] = True
        self.later("pulls/99", moved)
        self.refusal("batch_roll_or_main_moved_during_check", E.INVALID)

    def test_late_source_review_change_refuses(self):
        actual = B.member_review
        counts = {1: 0, 2: 0}
        def review(f, gh, prefix, member, base, author):
            result = actual(f, gh, prefix, member, base, author)
            counts[member.pr] += 1
            if member.pr == 2 and counts[2] > 1:
                result["id"] = 999
            return result
        with patch.object(B, "member_review", side_effect=review):
            self.refusal("batch_member_review_changed_during_check", E.MEMBER)

    def test_late_newer_success_invalidates_cited_roll_run(self):
        endpoint = f"actions/runs?head_sha={self.roll}&event=pull_request&per_page=100"
        newer = copy.deepcopy(self.get("actions/runs/900"))
        newer.update(id=999, run_number=11)
        self.later(endpoint, {"workflow_runs": [newer]})
        self.refusal("batch_run_not_current_successful_exact_pr_check", E.ROLL)

    def test_real_shell_verdict_and_ci_gate_accept_complete_evidence(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        self.assertEqual(self.evaluate(real_gates=True)["status"], "fresh")

    def test_real_shell_gate_rejects_check_failure_hidden_by_green_run(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        self.get(f"commits/{self.roll}/check-runs?per_page=100")["check_runs"][0]["conclusion"] = "failure"
        self.refusal("evidence_read_failed", E.ROLL, real_gates=True)

    def test_source_review_rejects_outsider(self):
        self.get("pulls/2/reviews?per_page=100")[0]["author_association"] = "NONE"
        self.refusal("batch_member_without_current_review", E.MEMBER)

    def test_real_shell_final_ci_gate_rejects_late_check_failure(self):
        if not shutil.which("jq"):
            self.skipTest("real shell gates require jq")
        endpoint = f"commits/{self.roll}/check-runs?per_page=100"
        good = copy.deepcopy(self.get(endpoint))
        failed = copy.deepcopy(good)
        failed["check_runs"][0]["conclusion"] = "failure"
        self.data["__responses"] = {PREFIX + "/" + endpoint: [good, failed]}
        self.refusal("evidence_read_failed", E.ROLL, real_gates=True)

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
            self.refusal("batch_roll_or_main_moved_during_check", E.INVALID, real_gates=True)
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
                        "bash", str(HERE / script), "--check", "--repo", "o/r", "--pr", "99",
                        "--head", self.roll,
                        "--run", "900", "--git-dir", str(self.repo),
                        "--batch", str(batch)], env=dict(os.environ, GUARD_GH=str(self.fake)),
                        capture_output=True, text=True, timeout=120)
                    if state == "valid":
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn(marker, result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        reason = ("batch_roll_review_refuses_evidence" if state == "roll-fail"
                                  else "batch_member_has_open_change_request")
                        if state == "roll-cr":
                            reason = "open CHANGES_REQUESTED"
                        self.assertIn(reason, result.stdout + result.stderr)
        requests = [json.loads(line) for line in (self.root / "requests.jsonl").read_text().splitlines()]
        self.assertTrue(requests)
        self.assertFalse(any(set(row) & {"-X", "--method", "-f", "-F", "--field", "--raw-field"}
                             for row in requests), "check wrappers must never attempt an API write")




    def test_land_entry_missing_second_approval_refuses_before_any_write(self):
        self.approvals()
        self.put("pulls/2/reviews?per_page=100", [])
        with self.refused("batch_member_without_current_review", E.MEMBER):
            self.run_landing()
        self.assertEqual(self.writes, [])

    def cli(self, *, line=None, check_only=True):
        batch = self.root / "cli-batch.txt"
        batch.write_text(self.line + "\n" if line is None else line)
        self.data["user"] = {"login": "operator"}
        for run_id in self.run_ids.values():
            row = self.data.get(PREFIX + f"/actions/runs/{run_id}")
            if row:
                row.setdefault("created_at", "2026-01-01T00:30:00Z")
        self.fixture.write_text(json.dumps(self.data))
        # Override only the executable under test for the disposable mutation
        # control. The fixture still runs the complete public shell entry.
        entry = Path(os.environ.get("BATCH_TEST_LAND_SCRIPT", HERE / "land-batch.sh"))
        result = subprocess.run(["bash", str(entry), "--repo", "o/r", "--batch", str(batch),
                                 "--git-dir", str(self.repo)] + (["--check-only"] if check_only else []),
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

    def test_cli_roll_job_failure_and_member_run_irrelevance(self):
        self.approvals()
        jobs = self.get("actions/runs/900/jobs?per_page=100")["jobs"]
        jobs[0]["conclusion"] = "failure"
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (3, "batch_required_jobs_not_all_successful"))
        jobs[0]["conclusion"] = "success"
        self.get("actions/runs/901")["conclusion"] = "failure"
        member_runs = self.get(f"actions/runs?head_sha={self.heads[1]}&event=pull_request&per_page=100")
        member_runs["workflow_runs"] = []
        code, receipt = self.cli()
        self.assertEqual((code, receipt["status"]), (0, "checked"), receipt)
        self.get(f"actions/runs?head_sha={self.roll}&event=pull_request&per_page=100")["workflow_runs"] = []
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (3, "pr_check_run_unavailable"))

    def test_cli_wrong_landing_tree_is_four(self):
        self.publish_roll(wrong=True)
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (4, "batch_roll_landing_tree_mismatch"))

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
        self.assertEqual((code, receipt["reason"]), (6, "batch_member_without_current_review"))

    def test_cli_invalid_input_and_infrastructure_are_distinct(self):
        code, receipt = self.cli(line="not a batch line\n")
        self.assertEqual((code, receipt["reason"]), (2, "invalid_evidence"))
        del self.data[PREFIX + "/actions/runs/900"]
        code, receipt = self.cli()
        self.assertEqual((code, receipt["reason"]), (1, "evidence_read_failed"))

    # Exit codes each Reason may leave with. A shared ROLL/member reader takes
    # its caller's role; a failing git or shell step can give INFRASTRUCTURE.
    ALLOWED_CODES = {
        R.EVIDENCE_READ_FAILED: {E.INFRASTRUCTURE, E.ROLL, E.MEMBER, E.LANDING, E.MAIN_OVERLAP},
        R.INVALID_APPROVAL_RECEIPT: {E.INFRASTRUCTURE},
        R.LINE_NOT_PUBLISHED_BY_TRUSTED_PARTICIPANT: {E.ROLL, E.MEMBER},
        R.MEMBER_WITHOUT_CURRENT_REVIEW: {E.MEMBER},
        R.MEMBER_HAS_LATE_FAIL: {E.MEMBER},
        R.ROLL_REVIEW_REFUSES_EVIDENCE: {E.ROLL},
        R.MEMBER_HAS_OPEN_CHANGE_REQUEST: {E.ROLL, E.MEMBER},
        R.PR_CHECK_RUN_UNAVAILABLE: {E.ROLL, E.MEMBER},
        R.RUN_NOT_CURRENT_SUCCESSFUL_EXACT_PR_CHECK: {E.ROLL, E.MEMBER},
        R.RUN_SUITE_NOT_LINKED_TO_PR: {E.ROLL, E.MEMBER},
        R.REQUIRED_JOBS_NOT_ALL_SUCCESSFUL: {E.ROLL, E.MEMBER},
        R.ROLL_PR_IDENTITY_UNAVAILABLE: {E.ROLL},
        R.ROLL_PR_IS_A_MEMBER: {E.INVALID},
        R.CANDIDATE_NOT_IN_BATCH: {E.MEMBER},
        R.LANDING_REQUIRES_ROLL: {E.MEMBER},
        R.ROLL_ALREADY_MERGED: {E.MEMBER},
        R.ROLL_NOT_YET_MERGED: {E.MEMBER},
        R.ROLL_VERDICT_NAMES_ANOTHER_RUN: {E.ROLL},
        R.MEMBER_RUN_NOT_APPLICABLE: {E.MEMBER},
        R.ROLL_INPUT_MISMATCH: {E.ROLL},
        R.ROLL_RUN_RECEIPT_MISMATCH: {E.ROLL},
        R.MEMBER_HEAD_OR_BASE_CHANGED: {E.MEMBER},
        R.MEMBER_NO_LONGER_OPEN: {E.MEMBER},
        R.TREE_MERGE_CONFLICT_OR_UNAVAILABLE: {E.LANDING, E.INFRASTRUCTURE},
        R.TREE_COMMIT_UNAVAILABLE: {E.INFRASTRUCTURE},
        R.ROLL_TREE_DOES_NOT_MATCH_MEMBERS: {E.LANDING},
        R.ROLL_HAS_NO_CHANGES: {E.INVALID},
        R.BASE_NOT_IN_AVAILABLE_MAIN_HISTORY: {E.INFRASTRUCTURE},
        R.ROLL_LANDING_IS_NOT_A_SQUASH: {E.LANDING},
        R.MAIN_CHANGED_AT_MERGE_WRITE: {E.LANDING},
        R.ROLL_LANDING_TREE_MISMATCH: {E.LANDING},
        R.NONMEMBER_MAIN_CHANGE_INVALIDATES_ROLL: {E.MAIN_OVERLAP},
        R.ROLL_MERGE_NOT_IN_MAIN_HISTORY: {E.LANDING},
        R.FINAL_LANDING_TREE_MISMATCH: {E.LANDING},
        R.MEMBER_MOVED_DURING_CHECK: {E.MEMBER},
        R.PUBLICATION_CHANGED_DURING_CHECK: {E.MEMBER},
        R.MEMBER_REVIEW_CHANGED_DURING_CHECK: {E.MEMBER},
        R.ROLL_OR_MAIN_MOVED_DURING_CHECK: {E.INVALID},
    }

    def test_every_reason_is_raised_with_a_contract_code(self):
        tree = ast.parse((HERE / "batch_evidence.py").read_text())
        self.assertEqual(set(self.ALLOWED_CODES), set(B.Reason))
        for reason in B.Reason:
            self.assertEqual(reason.name, reason.value.removeprefix("batch_").upper())
        raised_calls, raised = set(), set()
        for node in ast.walk(tree):
            if not isinstance(node, ast.Raise) or node.exc is None:
                continue
            names = {sub.attr for sub in ast.walk(node.exc) if isinstance(sub, ast.Attribute)}
            self.assertFalse(names & {"Unavailable", "NoPrCheckRun"}, ast.unparse(node))
            call = node.exc
            if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
                    and call.func.id == "Refusal"):
                continue
            raised_calls.add(id(call))
            with self.subTest(site=ast.unparse(node)):
                self.assertEqual(len(call.args), 2)
                first, code = call.args
                self.assertTrue(isinstance(first, ast.Attribute) and isinstance(first.value, ast.Name)
                                and first.value.id == "Reason")
                raised.add(first.attr)
                allowed = self.ALLOWED_CODES[B.Reason[first.attr]]
                # The values the code expression can take: ExitCode literals,
                # or a variable (a role or guard status chosen at run time).
                leaves, pending = [], [code]
                while pending:
                    expr = pending.pop()
                    if isinstance(expr, ast.IfExp):
                        pending.extend((expr.body, expr.orelse))
                    else:
                        leaves.append(expr)
                for leaf in leaves:
                    if isinstance(leaf, ast.Attribute) and ast.unparse(leaf.value) == "ExitCode":
                        self.assertIn(E[leaf.attr], allowed)
                    else:
                        self.assertIsInstance(leaf, ast.Name)
                        self.assertGreaterEqual(allowed, {E.ROLL, E.MEMBER})
        self.assertEqual(raised, {reason.name for reason in B.Reason}, "every Reason needs a raise site")
        bare = [ast.unparse(node) for node in ast.walk(tree) if isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name) and node.func.id == "Refusal"
                and id(node) not in raised_calls]
        self.assertEqual(bare, [], "a Refusal that is built but not raised refuses nothing")

    def test_failure_code_follows_exception_type_never_reason_text(self):
        for reason in B.Reason:
            for code in (B.ExitCode.ROLL, B.ExitCode.MEMBER, B.ExitCode.LANDING):
                with self.subTest(reason=reason, code=code):
                    error = B.Refusal(reason, code)
                    self.assertEqual(str(error), reason.value)
                    self.assertIs(B.failure_code(F, error), code)
            with self.subTest(parent=reason):
                # The same token from a parent read is a read failure: the
                # code follows the exception type, not its message.
                self.assertIs(B.failure_code(F, F.Unavailable(reason.value)), B.ExitCode.INFRASTRUCTURE)
        self.assertIs(B.failure_code(F, F.NoPrCheckRun()), B.ExitCode.INFRASTRUCTURE)
        self.assertIs(B.failure_code(F, OSError("gone")), B.ExitCode.INFRASTRUCTURE)
        for error in (ValueError("x"), KeyError("x"), TypeError("x")):
            with self.subTest(error=type(error).__name__):
                self.assertIs(B.failure_code(F, error), B.ExitCode.INVALID)
        with self.assertRaisesRegex(TypeError, "^unclassified batch failure: RuntimeError$"):
            B.failure_code(F, RuntimeError("unexpected"))

    def test_cli_status_keeps_success_and_pending_distinct(self):
        # The asynchronous pending transition itself uses the real-Git land
        # control above; here hold its result fixed at the public CLI boundary.
        self.assertEqual(set(B.LAND_EXIT_CODES), set(B.LandStatus))
        for status, code in [(B.LandStatus.CHECKED, 0), (B.LandStatus.PUBLISHED, 0),
                             (B.LandStatus.PENDING, 7)]:
            with self.subTest(status=status), patch.object(sys, "argv", [
                    "batch_evidence.py", "--repo", "o/r", "--batch", "unused",
                    "--git-dir", str(self.repo)]), \
                 patch.object(B, "land", return_value=B.landing(status, {})), \
                 redirect_stdout(io.StringIO()) as output:
                self.assertEqual(B.main(), code)
                self.assertEqual(json.loads(output.getvalue())["status"], status.value)



    def test_ordinary_approval_check_refusal_keeps_exit_two(self):
        self.get(f"commits/{self.heads[1]}/check-runs?per_page=100")["check_runs"][0]["conclusion"] = "failure"
        self.fixture.write_text(json.dumps(self.data))
        result = subprocess.run(["bash", str(HERE / "approve-guard.sh"), "--check", "--repo", "o/r",
                                 "--pr", "1", "--head", self.heads[1], "--run", "901",
                                 "--git-dir", str(self.repo)], env=dict(os.environ, GUARD_GH=str(self.fake)),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_merge_api_auth_exit_is_infra_only_for_batch(self):
        self.approvals()
        self.data['user'] = {"login": "operator"}
        self.data['__write_exit'] = 4  # gh help exit-codes: authentication required.
        self.get("pulls/1")["changed_files"] = 1
        self.put("issues/1/comments?per_page=100",
                 self.get("issues/1/comments?per_page=100") + [{
                     "id": 12, "created_at": "2026-01-01T00:50:00Z",
                     "author_association": "MEMBER", "user": {"login": "reviewer"},
                     "body": f"verdict: PASS head: {self.heads[1]} run: 901 by: reviewer"}])
        member_approval = {
            "id": 101, "state": "APPROVED", "author_association": "MEMBER",
            "user": {"login": "independent-reviewer"}, "commit_id": self.heads[1],
            "submitted_at": "2026-01-01T00:52:00Z",
            "body": f"verdict: PASS head: {self.heads[1]} run: 901 by: reviewer\n\n"
                    f"approve-guard: head `{self.heads[1]}` · fixture evidence"}
        self.get("pulls/1/reviews?per_page=100").append(member_approval)
        self.put("pulls/1/reviews/101", member_approval)
        self.put("pulls/1/files?per_page=100", [{"filename": "lib/one.ml"}])
        self.get("actions/runs/901")["created_at"] = "2026-01-01T00:30:00Z"
        self.get("actions/runs/900")["created_at"] = "2026-01-01T00:30:00Z"
        batch = self.root / "auth-batch.txt"
        batch.write_text(self.line + "\n")
        for use_batch, expected in [(True, 1), (False, 4)]:
            with self.subTest(batch=use_batch):
                self.fixture.write_text(json.dumps(self.data))
                (self.root / "requests.jsonl").write_text("")
                args = ["bash", str(HERE / "merge-guard.sh"), "--repo", "o/r", "--pr", "99" if use_batch else "1",
                        "--head", self.roll if use_batch else self.heads[1],
                        "--run", "900" if use_batch else "901", "--git-dir", str(self.repo)]
                if use_batch:
                    args.extend(["--batch", str(batch)])
                result = subprocess.run(args, env=dict(os.environ, GUARD_GH=str(self.fake)),
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                writes = [json.loads(line) for line in (self.root / "requests.jsonl").read_text().splitlines()
                          if '-X' in json.loads(line)]
                self.assertEqual(len(writes), 1, "all guards must pass before the simulated API refusal")
                self.assertIn(PREFIX + f"/pulls/{99 if use_batch else 1}/merge-async", writes[0])


    def test_restored_member_path_still_blocks_external_main_change(self):
        content = "let a = 0\n" + "".join(f"let pad{i} = 0\n" for i in range(12)) + "let z = 0\n"
        self.base = self.change(self.base, "lib/base.ml", content)
        first = self.change(self.base, "lib/base.ml", content.replace("let a = 0", "let a = 1"))
        restored = self.change(first, "lib/base.ml", content)
        second = self.change(restored, "lib/two.ml", "let two = 2\n")
        self.git("checkout", "-q", "--detach", self.base)
        for head in [first, second]:
            self.git("merge", "-q", "--no-ff", "--no-edit", head)
        roll = self.git("rev-parse", "HEAD")
        for pr, head in [(1, first), (2, second), (99, roll)]:
            old = self.get(f"pulls/{pr}")["head"]["sha"]
            self.get(f"pulls/{pr}")["head"]["sha"] = head
            self.get(f"pulls/{pr}")["base"]["sha"] = self.base
            self.get(f"actions/runs/{self.run_ids[pr]}")["head_sha"] = head
            for suffix in ["&event=pull_request&per_page=100", "&per_page=100"]:
                runs = copy.deepcopy(self.get(f"actions/runs?head_sha={old}" + suffix))
                for row in runs["workflow_runs"]:
                    row["head_sha"] = head
                self.put(f"actions/runs?head_sha={head}" + suffix, runs)
            self.get(f"check-suites/{self.run_ids[pr] + 1000}")["head_sha"] = head
            self.put(f"commits/{head}/check-runs?per_page=100",
                     copy.deepcopy(self.get(f"commits/{old}/check-runs?per_page=100")))
        self.heads = {1: first, 2: second}
        self.roll = roll
        self.main = self.base
        self.put("commits/main", {"sha": self.main})
        self.set_line()
        self.assertEqual(self.git("diff", "--name-only", self.base, roll), "lib/two.ml",
                         "ROLL must remain nonempty while the restored path disappears from its net diff")
        self.assertEqual(self.evaluate()["status"], "fresh")
        self.put("commits/main", {"sha": self.change(self.base, "lib/base.ml",
                                                  content.replace("let z = 0", "let z = 1"))})
        self.refusal("batch_nonmember_main_change_invalidates_roll", E.MAIN_OVERLAP)




if __name__ == "__main__":
    unittest.main()
