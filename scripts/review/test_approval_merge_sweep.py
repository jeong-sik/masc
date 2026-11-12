#!/usr/bin/env python3
"""Exercise the sweep's selection and its stop rules without contacting GitHub."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('approval_merge_sweep',
                                              HERE / 'approval-merge-sweep.py')
assert SPEC is not None and SPEC.loader is not None
SWEEP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SWEEP)


def sha(number):
    return f'{number:040x}'


def approval(login, number, state='APPROVED'):
    return {'state': state, 'author': {'login': login}, 'commit': {'oid': sha(number)}}


def row(number, base='main', *, approvals=2, **changes):
    value = {'number': number, 'isDraft': False, 'mergeable': 'MERGEABLE',
             'isCrossRepository': False, 'baseRefName': base, 'headRefName': f'b{number}',
             'headRefOid': sha(number), 'autoMergeRequest': None,
             'latestOpinionatedReviews': {'nodes': [
                 approval(f'reviewer-{n}', number) for n in range(approvals)]}}
    return dict(value, **changes)


def never(number):
    raise AssertionError(f'#{number} needed no stack lookup')


class Selection(unittest.TestCase):
    def test_a_ready_pull_request_on_main_is_selected(self):
        self.assertEqual(SWEEP.select([row(1)], never), [1])

    def test_what_the_worker_would_certainly_hold_is_not_selected(self):
        stale = row(6)
        stale['latestOpinionatedReviews']['nodes'][1]['commit']['oid'] = sha(999)
        same_account = row(7)
        same_account['latestOpinionatedReviews']['nodes'][1]['author']['login'] = 'reviewer-0'
        refused = row(8)
        refused['latestOpinionatedReviews']['nodes'].append(
            approval('reviewer-9', 8, 'CHANGES_REQUESTED'))
        rows = [row(1, approvals=1), row(2, isDraft=True), row(3, headRefName='release/v1'),
                row(4, mergeable='CONFLICTING'), row(5, 'other-branch'), stale, same_account,
                refused, row(9, isCrossRepository=True)]
        self.assertEqual(SWEEP.select(rows, never), [])

    def test_a_reserved_pull_request_is_left_to_github(self):
        self.assertEqual(SWEEP.select([row(1, autoMergeRequest={'enabledAt': 't'})], never), [])

    def test_a_fully_ready_stack_is_selected_once_and_after_single_pull_requests(self):
        rows = [row(1), row(2, 'b1'), row(3, 'b2'), row(9)]
        self.assertEqual(SWEEP.select(rows, never), [9, 1])

    def test_a_native_stack_with_an_unready_layer_waits(self):
        rows = [row(1), row(2, 'b1', approvals=0)]
        asked = []
        self.assertEqual(SWEEP.select(rows, lambda n: asked.append(n) or True), [])
        self.assertEqual(asked, [1])

    def test_an_ordinary_pull_request_merges_without_the_branch_built_on_it(self):
        rows = [row(1), row(2, 'b1', approvals=0)]
        self.assertEqual(SWEEP.select(rows, lambda n: False), [1])

    def test_branches_that_name_each_other_end_the_walk(self):
        rows = [row(1), row(2, 'b1'), row(3, 'b2', headRefName='b1')]
        self.assertEqual(SWEEP.select(rows, never), [1])


class Sweeping(unittest.TestCase):
    def sweep(self, exits, *, clock=None):
        runs = []
        def run(command, **kwargs):
            runs.append((command[-1], kwargs['env']['DISPATCH_PR'],
                         kwargs['env']['GITHUB_EVENT_NAME']))
            return subprocess.CompletedProcess(command, exits[len(runs) - 1])
        patches = [patch.object(SWEEP, 'open_pulls', return_value=[row(1), row(2), row(3)]),
                   patch.object(SWEEP, 'quota', return_value=None),
                   patch.object(SWEEP.subprocess, 'run', side_effect=run),
                   patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/repo'}),
                   patch.object(SWEEP.sys, 'argv', ['sweep'])]
        if clock is not None:
            patches.append(patch.object(SWEEP.time, 'monotonic', side_effect=clock))
        output = io.StringIO()
        for item in patches:
            item.start()
        try:
            with redirect_stdout(output):
                code = SWEEP.main()
        finally:
            for item in reversed(patches):
                item.stop()
        return code, runs, output.getvalue()

    def test_each_candidate_gets_one_worker_run_that_hands_its_receipt_off(self):
        code, runs, output = self.sweep([0, 1, 0])
        self.assertEqual(code, 0)  # a held or failed scope does not fail the sweep
        self.assertEqual(runs, [('--hand-off-now', n, 'workflow_dispatch') for n in '123'])
        self.assertIn('"stopped": null', output)

    def test_a_quota_exit_stops_the_sweep(self):
        code, runs, output = self.sweep([SWEEP.QUOTA_EXIT])
        self.assertEqual((code, len(runs)), (0, 1))
        self.assertIn('"stopped": "quota reached"', output)
        self.assertIn('"not_reached": [\n    2,\n    3\n  ]', output)

    def test_no_worker_starts_after_the_sweep_time(self):
        ticks = iter([0, 0, SWEEP.SWEEP_SECONDS, SWEEP.SWEEP_SECONDS])
        code, runs, output = self.sweep([0], clock=lambda: next(ticks))
        self.assertEqual((code, len(runs)), (0, 1))
        self.assertIn('"stopped": "sweep time used up"', output)

    def test_an_unreadable_listing_is_the_only_red_sweep(self):
        with patch.object(SWEEP, 'open_pulls', side_effect=ValueError('refused')), \
             patch.object(SWEEP, 'quota', return_value=None), \
             patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/repo'}), \
             patch.object(SWEEP.sys, 'argv', ['sweep']):
            self.assertEqual(SWEEP.main(), 1)

    def test_the_exit_status_matches_the_worker(self):
        spec = importlib.util.spec_from_file_location('worker', HERE / 'approval-auto-merge.py')
        worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(worker)
        self.assertEqual(SWEEP.QUOTA_EXIT, worker.QUOTA_EXIT)
        self.assertEqual(SWEEP.REQUIRED_APPROVALS, worker.REQUIRED_APPROVALS)


if __name__ == '__main__':
    unittest.main()
