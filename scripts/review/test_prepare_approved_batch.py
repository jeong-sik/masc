#!/usr/bin/env python3
"""Real Git composition and real source guard; fixture GitHub, no CI/builds."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

fixture_spec = importlib.util.spec_from_file_location(
    "approved_selection_fixture", Path(__file__).with_name("approved-selection-test-fixture.py"))
fixtures = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(fixtures)

spec = importlib.util.spec_from_file_location(
    "prepare_approved_batch", Path(__file__).with_name("prepare-approved-batch.py"))
P = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = P
spec.loader.exec_module(P)


class ApprovedSelectionTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.ApprovedSelectionFixture()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.approvals()
        for pr, head in self.fixture.heads.items():
            self.fixture.get(f"pulls/{pr}")["base"]["sha"] = self.fixture.base
            row = self.fixture.get(f"pulls/{pr}/reviews?per_page=100")[0]
            self.fixture.put(f"pulls/{pr}/reviews/{row['id']}", row)
        # CI evidence is deliberately absent. A source approval read must not
        # ask for it, and the fake gh refuses endpoints not present here.
        self.fixture.data = {key: value for key, value in self.fixture.data.items()
                             if "/actions/" not in key and "/check-" not in key}
        self.save()

    def save(self):
        self.fixture.fixture.write_text(json.dumps(self.fixture.data))

    def prepare(self, selected=None, approve=P.source_approval):
        selected = selected or tuple(P.Member(pr, head)
                                     for pr, head in self.fixture.heads.items())
        with patch.object(P, "api", self.fixture.api):
            return P.prepare(P, repo="o/r", leader="leader", selected=selected,
                             git_dir=str(self.fixture.repo), gh=str(self.fixture.fake),
                             approve=approve)

    def test_combines_only_selected_approved_heads_without_ci(self):
        receipt = self.prepare()
        self.assertEqual(receipt["base"], self.fixture.base)
        for name in ("one", "two"):
            self.assertEqual(self.fixture.git("show", receipt["candidate"] + f":lib/{name}.ml"),
                             f"let {name} = {1 if name == 'one' else 2}")
        self.assertEqual([m["pr"] for m in receipt["members"]], [1, 2])
        calls = (self.fixture.root / "requests.jsonl").read_text()
        self.assertNotIn("/actions/", calls)
        self.assertNotIn("/check-runs", calls)

    def test_unselected_source_never_enters_candidate(self):
        receipt = self.prepare((P.Member(1, self.fixture.heads[1]),))
        self.assertEqual(self.fixture.git("show", receipt["candidate"] + ":lib/one.ml"), "let one = 1")
        absent = subprocess.run(["git", "-C", str(self.fixture.repo), "cat-file", "-e",
                                 receipt["candidate"] + ":lib/two.ml"], capture_output=True)
        self.assertNotEqual(absent.returncode, 0)

    def test_revoked_approval_after_composition_refuses_candidate(self):
        calls = []
        def approve(repo, selected, *, gh):
            calls.append(selected.pr)
            if calls == [1, 2, 1]:
                self.fixture.put("pulls/1/reviews?per_page=100", [])
                self.save()
            return P.source_approval(repo, selected, gh=gh)
        with self.assertRaises(P.Rejected):
            self.prepare(approve=approve)

    def test_moving_main_after_composition_refuses_candidate(self):
        calls = []
        def approve(repo, selected, *, gh):
            calls.append(selected.pr)
            if calls == [1, 2, 1]:
                self.fixture.data["repos/o/r/commits/main"]["sha"] = self.fixture.heads[1]
            return P.source_approval(repo, selected, gh=gh)
        with self.assertRaises(P.Rejected) as error:
            self.prepare(approve=approve)
        self.assertEqual(error.exception.reason, P.Reason.MAIN_MOVED)

    def test_base_retarget_after_composition_refuses_candidate(self):
        calls = []
        def approve(repo, selected, *, gh):
            calls.append(selected.pr)
            if calls == [1, 2, 1]:
                self.fixture.get("pulls/1")["base"]["ref"] = "stack/unselected"
                self.save()
            return P.source_approval(repo, selected, gh=gh)
        with self.assertRaises(P.Rejected) as error:
            self.prepare(approve=approve)
        self.assertEqual(error.exception.reason, P.Reason.APPROVAL_UNAVAILABLE)

    def test_release_head_does_not_trigger_ci_reads_from_preparation(self):
        self.fixture.get("pulls/1")["head"]["ref"] = "release/v1.2.3"
        self.save()
        with self.assertRaises(P.Rejected) as error:
            self.prepare()
        self.assertEqual(error.exception.reason, P.Reason.INVALID_SELECTION)
        self.assertNotIn("/actions/", (self.fixture.root / "requests.jsonl").read_text())

    def test_unapproved_member_cannot_enter_combined_tree(self):
        self.fixture.put("pulls/2/reviews?per_page=100", [])
        self.save()
        with self.assertRaises(P.Rejected):
            self.prepare()

    def test_open_change_request_precedes_approval(self):
        rows = self.fixture.get("pulls/2/reviews?per_page=100")
        rows.append({"id": 500, "state": "CHANGES_REQUESTED", "user": {"login": "other"}})
        self.save()
        with self.assertRaises(P.Rejected):
            self.prepare()

    def test_head_push_after_approval_refuses_preparation(self):
        calls = []
        def approve(repo, selected, *, gh):
            calls.append(selected.pr)
            if calls == [1, 2, 1]:
                self.fixture.get("pulls/1")["head"]["sha"] = self.fixture.heads[2]
                self.save()
            return P.source_approval(repo, selected, gh=gh)
        with self.assertRaises(P.Rejected):
            self.prepare(approve=approve)

    def test_unselected_base_cannot_supply_unreviewed_changes(self):
        self.fixture.get("pulls/2")["base"]["sha"] = self.fixture.heads[1]
        with self.assertRaises(P.Rejected) as error:
            self.prepare()
        self.assertEqual(error.exception.reason, P.Reason.UNSELECTED_BASE)

    def set_scope(self, pr, base_ref, base_sha, stack=None):
        row = self.fixture.get(f"pulls/{pr}/reviews?per_page=100")[0]
        row["body"] = (f"verdict: PASS head: {self.fixture.heads[pr]} by: reviewer\n\n"
                       + "review-scope: " + json.dumps({"base_ref": base_ref, "base_sha": base_sha, "stack": stack})
                       + f"\napprove-guard: head `{self.fixture.heads[pr]}` · source review")
        self.fixture.put(f"pulls/{pr}/reviews/{row['id']}", row)
        self.save()

    def test_retargeted_upper_pr_does_not_import_unreviewed_parent(self):
        self.fixture.git('checkout', '-q', '-b', 'stacked', self.fixture.heads[1])
        (self.fixture.repo / 'lib/two.ml').write_text('let two = 2\n')
        self.fixture.git('add', 'lib/two.ml')
        self.fixture.git('commit', '-q', '-m', 'upper')
        self.fixture.heads[2] = self.fixture.git('rev-parse', 'HEAD')
        self.fixture.get('pulls/2')['head']['sha'] = self.fixture.heads[2]
        self.set_scope(2, 'feature/1', self.fixture.heads[1])
        with self.assertRaises(P.Rejected) as error:
            self.prepare((P.Member(2, self.fixture.heads[2]),))
        self.assertEqual(error.exception.reason, P.Reason.APPROVAL_UNAVAILABLE)

    def test_changed_diff_base_requires_reapproval_even_with_same_ref(self):
        self.set_scope(1, 'main', self.fixture.heads[1])
        with self.assertRaises(P.Rejected) as error:
            self.prepare()
        self.assertEqual(error.exception.reason, P.Reason.APPROVAL_UNAVAILABLE)

    def test_unrelated_main_advance_preserves_reviewed_diff(self):
        (self.fixture.repo / 'unrelated.txt').write_text('main advanced\n')
        self.fixture.git('add', 'unrelated.txt')
        self.fixture.git('commit', '-q', '-m', 'unrelated main change')
        base = self.fixture.git('rev-parse', 'HEAD')
        self.fixture.data['repos/o/r/commits/main']['sha'] = base
        for pr in self.fixture.heads:
            self.fixture.get(f'pulls/{pr}')['base']['sha'] = base
        self.save()
        self.assertEqual(self.prepare()['base'], base)

    def test_legacy_unscoped_approval_requires_reapproval(self):
        row = self.fixture.get('pulls/1/reviews?per_page=100')[0]
        row['body'] = '\n'.join(line for line in row['body'].splitlines()
                                if not line.startswith('review-scope: '))
        self.fixture.put(f"pulls/1/reviews/{row['id']}", row)
        self.save()
        with self.assertRaises(P.Rejected) as error:
            self.prepare()
        self.assertEqual(error.exception.reason, P.Reason.APPROVAL_UNAVAILABLE)

    def test_changed_native_stack_scope_requires_reapproval(self):
        self.fixture.get('pulls/1')['stack'] = {
            'number': 10, 'position': 1, 'base': {'ref': 'main'}}
        self.save()
        with self.assertRaises(P.Rejected) as error:
            self.prepare()
        self.assertEqual(error.exception.reason, P.Reason.APPROVAL_UNAVAILABLE)

    def test_fetch_uses_selected_repository_not_checkout_origin(self):
        checkout = self.fixture.root / 'fork-checkout'
        subprocess.run(['git', 'init', '-q', str(checkout)], check=True)
        subprocess.run(['git', '-C', str(checkout), 'remote', 'add', 'origin',
                        str(self.fixture.root / 'remote.git')], check=True)
        with patch.object(P, 'api', return_value={'clone_url': str(self.fixture.repo)}) as read:
            trees = P.Trees(P, str(checkout), 'upstream/project', str(self.fixture.fake))
            trees.ensure(self.fixture.heads[1])
            read.assert_called_once_with(str(self.fixture.fake), 'repos/upstream/project')
            self.assertEqual(trees.tree(self.fixture.heads[1]),
                             self.fixture.git('rev-parse', self.fixture.heads[1] + '^{tree}'))

    def check_close_failure(self, move_ref=False):
        receipt = self.prepare((P.Member(1, self.fixture.heads[1]),))
        output = self.fixture.root / 'failed-close.json'
        original_open = Path.open
        fixture = self.fixture
        class ClosingFailure:
            def __getattr__(self, name):
                return getattr(self.stream, name)
            def __enter__(self):
                self.stream = original_open(output, 'x')
                return self.stream
            def __exit__(self, *args):
                self.stream.close()
                with original_open(output) as saved:
                    self.saved = json.load(saved)
                if move_ref:
                    fixture.git('update-ref', 'refs/heads/ci/failed-close', fixture.base)
                raise OSError('delayed close failure')
        argv = ['prepare', '--repo', 'o/r', '--leader', 'leader',
                '--git-dir', str(self.fixture.repo), '--branch', 'ci/failed-close',
                '--output', str(output), '--member', f'1@{self.fixture.heads[1]}']
        stream = ClosingFailure()
        with patch.object(sys, 'argv', argv), patch.object(P, 'prepare', return_value=receipt), \
                patch.object(Path, 'open', return_value=stream):
            self.assertEqual(P.main(), 1)
        self.assertEqual(stream.saved['candidate'], receipt['candidate'])
        self.assertFalse(output.exists())
        if move_ref:
            self.assertEqual(self.fixture.git('rev-parse', 'refs/heads/ci/failed-close'), self.fixture.base)
            return
        result = subprocess.run(['git', '-C', str(self.fixture.repo), 'show-ref', '--verify',
                                 'refs/heads/ci/failed-close'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_close_failure_rolls_back_only_our_candidate_ref(self):
        self.check_close_failure()

    def test_close_failure_preserves_concurrently_moved_ref(self):
        self.check_close_failure(move_ref=True)

    def test_missing_receipt_directory_creates_no_branch(self):
        result = subprocess.run(
            [sys.executable, str(Path(P.__file__)), "--repo", "o/r", "--leader", "leader",
             "--git-dir", str(self.fixture.repo), "--branch", "ci/missing-receipt",
             "--output", str(self.fixture.root / "missing" / "selection.json"),
             "--member", f"1@{self.fixture.heads[1]}"],
            text=True, capture_output=True,
            env=os.environ | {"GUARD_GH": str(self.fixture.fake)})
        self.assertEqual(result.returncode, 1)
        found = subprocess.run(["git", "-C", str(self.fixture.repo), "show-ref", "--verify",
                                "refs/heads/ci/missing-receipt"], capture_output=True)
        self.assertNotEqual(found.returncode, 0)

    def test_cli_creates_local_candidate_and_receipt_without_push(self):
        output = self.fixture.root / "selection.json"
        result = subprocess.run(
            [sys.executable, str(Path(P.__file__)), "--repo", "o/r", "--leader", "leader",
             "--git-dir", str(self.fixture.repo), "--branch", "ci/selected",
             "--output", str(output), "--member", f"1@{self.fixture.heads[1]}"],
            text=True, capture_output=True,
            env=os.environ | {"GUARD_GH": str(self.fixture.fake)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = json.loads(output.read_text())
        self.assertEqual(self.fixture.git("rev-parse", "ci/selected"), receipt["candidate"])
        self.assertEqual(self.fixture.git("ls-remote", "origin", "refs/heads/ci/selected"), "")


if __name__ == "__main__":
    unittest.main()
