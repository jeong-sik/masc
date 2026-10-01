#!/usr/bin/env python3
"""Approval-to-CI transition fixtures with actual source guards and Git trees."""
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import sys
import unittest

import test_prepare_approved_batch as preparation

spec = importlib.util.spec_from_file_location(
    'verify_selection', Path(__file__).with_name('verify-approved-selection.py'))
V = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = V
spec.loader.exec_module(V)


class SelectionTest(unittest.TestCase):
    def setUp(self):
        self.preparation = preparation.ApprovedSelectionTest()
        self.preparation.setUp()
        self.addCleanup(self.preparation.doCleanups)
        self.receipt = self.preparation.prepare()

    def verify(self, candidate=None):
        def prepare(*args, **kwargs):
            return self.preparation.prepare(selected=kwargs['selected'])
        return V.verify(self.receipt, repo='o/r',
                        candidate=candidate or self.receipt['candidate'],
                        git_dir=str(self.preparation.fixture.repo),
                        gh=str(self.preparation.fixture.fake), prepare=prepare)

    def test_exact_candidate_can_enter_ci(self):
        self.assertEqual(self.verify()['candidate'], self.receipt['candidate'])

    def run_cli(self):
        selection = self.preparation.fixture.root / 'selection.json'
        selection.write_text(json.dumps(self.receipt))
        return subprocess.run(
            [sys.executable, V.__file__, '--selection', str(selection),
             '--repo', 'o/r', '--candidate', self.receipt['candidate'],
             '--git-dir', str(self.preparation.fixture.repo)],
            text=True, capture_output=True,
            env=os.environ | {'GUARD_GH': str(self.preparation.fixture.fake)})

    def test_cli_rechecks_actual_guard_without_deleted_dependencies(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['candidate'], self.receipt['candidate'])
        calls = (self.preparation.fixture.root / 'requests.jsonl').read_text()
        self.assertNotIn('/actions/', calls)
        self.assertNotIn('/check-runs', calls)

    def test_cli_revoked_approval_is_a_typed_refusal(self):
        self.preparation.fixture.put('pulls/1/reviews?per_page=100', [])
        self.preparation.save()
        result = self.run_cli()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'refused')

    def test_cli_unavailable_authority_is_not_a_refusal(self):
        del self.preparation.fixture.data['repos/o/r/commits/main']
        self.preparation.save()
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'unavailable')

    def installation_token_fixture(self):
        # Actions installation tokens can read the PR source-review endpoints,
        # but cannot use the authenticated-user endpoint.
        del self.preparation.fixture.data['user']
        self.preparation.save()
        (self.preparation.fixture.root / 'requests.jsonl').write_text('')

    def test_cli_installation_token_rechecks_exact_candidate_without_user(self):
        self.installation_token_fixture()
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['candidate'], self.receipt['candidate'])
        calls = (self.preparation.fixture.root / 'requests.jsonl').read_text().splitlines()
        self.assertNotIn('user', calls)
        self.assertTrue(any('/reviews' in call for call in calls))

    def test_cli_installation_token_still_refuses_revoked_approval(self):
        self.installation_token_fixture()
        self.preparation.fixture.put('pulls/1/reviews?per_page=100', [])
        self.preparation.save()
        result = self.run_cli()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'refused')
        self.assertNotIn('user', (self.preparation.fixture.root / 'requests.jsonl').read_text().splitlines())

    def test_check_and_review_still_require_user_identity(self):
        self.installation_token_fixture()
        guard = Path(__file__).with_name('approve-guard.sh')
        for mode in (['--check'], []):
            with self.subTest(mode=mode):
                result = subprocess.run(
                    ['bash', str(guard), '--repo', 'o/r', '--pr', '1',
                     '--head', self.preparation.fixture.heads[1], *mode],
                    text=True, capture_output=True,
                    env=os.environ | {'GUARD_GH': str(self.preparation.fixture.fake)})
                # Preserve the upstream identity-read failure (fake gh exits 3).
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn('unexpected endpoint user', result.stderr)

    def test_different_dispatch_commit_is_refused(self):
        with self.assertRaises(V.P.Rejected):
            self.verify(candidate=self.receipt['base'])

    def test_receipt_cannot_add_unselected_tree_content(self):
        self.receipt['tree'] = self.receipt['base']
        with self.assertRaises(V.P.Rejected):
            self.verify()

    def test_dismissed_approval_prevents_ci(self):
        self.preparation.fixture.put('pulls/1/reviews?per_page=100', [])
        self.preparation.save()
        with self.assertRaises(preparation.P.Rejected):
            self.verify()

    def test_unknown_approval_ids_are_refused(self):
        self.receipt['members'][0]['approval_ids'] = [99999]
        with self.assertRaises(V.P.Rejected):
            self.verify()

    def test_main_move_after_preparation_is_refused(self):
        self.preparation.fixture.put('commits/main', {'sha': self.preparation.fixture.heads[1]})
        with self.assertRaises(V.P.Rejected):
            self.verify()


if __name__ == '__main__':
    unittest.main()
