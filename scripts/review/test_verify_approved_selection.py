#!/usr/bin/env python3
"""Approval-to-CI transition fixtures with actual source guards and Git trees."""
import importlib.util
import json
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
        self.preparation = preparation.ApprovedBatchTest()
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
