#!/usr/bin/env python3
"""Exercise the sweep's selection and its stop rules without contacting GitHub."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
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

    def test_a_pull_request_in_no_stack_has_no_stack_field(self):
        with patch.object(SWEEP, 'gh', return_value={'number': 1}):
            self.assertFalse(SWEEP.in_native_stack('owner/repo', 1))
        with patch.object(SWEEP, 'gh', return_value={'number': 1, 'stack': None}):
            self.assertFalse(SWEEP.in_native_stack('owner/repo', 1))
        with patch.object(SWEEP, 'gh', return_value={'number': 1, 'stack': {'number': 9}}):
            self.assertTrue(SWEEP.in_native_stack('owner/repo', 1))

    def test_branches_that_name_each_other_end_the_walk(self):
        rows = [row(1), row(2, 'b1'), row(3, 'b2', headRefName='b1')]
        self.assertEqual(SWEEP.select(rows, never), [1])


def ref(name, tip=1, *pulls, truncated=False, protected=False, ruled=0):
    return {'name': name, 'target': {'oid': sha(tip)},
            'branchProtectionRule': {'id': 'r'} if protected else None,
            'rules': {'totalCount': ruled},
            'associatedPullRequests': {'pageInfo': {'hasNextPage': truncated}, 'nodes': [
                {'state': state, 'headRefOid': sha(head), 'isCrossRepository': fork,
                 'mergedBy': None if merger is None else {'login': merger}}
                for state, head, fork, merger in pulls]}}


WORKER = ('MERGED', 1, False, 'github-actions')


class MergedLeftovers(unittest.TestCase):
    def test_a_branch_whose_worker_merge_ended_at_its_tip_goes(self):
        self.assertEqual(SWEEP.merged_leftovers([ref('b1', 1, WORKER)], []), [('b1', sha(1))])

    def test_everything_else_stays(self):
        refs = [ref('main', 1, WORKER),
                ref('release/v1', 1, WORKER),
                ref('moved', 2, WORKER),                      # a commit after the merge
                ref('reused', 1, WORKER, ('OPEN', 1, False, None)),
                ref('base-of-open', 1, WORKER),
                ref('head-of-open', 1, WORKER),               # its open pull request was not listed
                ref('too-many-pull-requests', 1, WORKER, truncated=True),
                ref('develop', 1, WORKER, protected=True),
                ref('staging', 1, WORKER, ruled=1),
                ref('merged-by-a-person', 1, ('MERGED', 1, False, 'someone')),
                ref('merger-unknown', 1, ('MERGED', 1, False, None)),
                ref('fork', 1, ('MERGED', 1, True, 'github-actions')),
                ref('no-pull-request', 1)]
        rows = [row(9, 'base-of-open'), row(8, headRefName='head-of-open')]
        self.assertEqual(SWEEP.merged_leftovers(refs, rows), [])

    def test_deleting_carries_a_lease_on_the_tip(self):
        done = subprocess.CompletedProcess([], 0, '', '')
        with patch.object(SWEEP.subprocess, 'run', return_value=done) as run:
            self.assertIsNone(SWEEP.delete_branch('owner/repo', 'b1', sha(1)))
        command = run.call_args.args[0]
        self.assertIn(f'--force-with-lease=refs/heads/b1:{sha(1)}', command)
        self.assertEqual(command[-2:], ['https://github.com/owner/repo.git', ':refs/heads/b1'])

    def test_a_refusal_and_an_unreadable_listing_are_records(self):
        refused = subprocess.CompletedProcess([], 1, '', 'stale info')
        with patch.object(SWEEP, 'walk', return_value=[ref('b1', 1, WORKER)]), \
             patch.object(SWEEP, 'open_pulls', return_value=[]), \
             patch.object(SWEEP.subprocess, 'run', return_value=refused):
            record = SWEEP.clean_branches('owner/repo', SWEEP.time.monotonic(), False)
        self.assertEqual(record, {'found': 1, 'deleted': 0, 'not_reached': 0,
                                  'refused': [{'branch': 'b1', 'reason': 'stale info'}]})
        with patch.object(SWEEP, 'walk', side_effect=ValueError('refused')):
            self.assertEqual(SWEEP.clean_branches('owner/repo', 0, False),
                             {'error': 'refused'})

    def test_a_pull_request_opened_during_the_sweep_keeps_its_base(self):
        with patch.object(SWEEP, 'walk', return_value=[ref('b1', 1, WORKER)]), \
             patch.object(SWEEP, 'open_pulls', return_value=[row(9, 'b1')]) as listing, \
             patch.object(SWEEP.subprocess, 'run') as run:
            record = SWEEP.clean_branches('owner/repo', SWEEP.time.monotonic(), False)
        listing.assert_called_once()
        run.assert_not_called()
        self.assertEqual(record['found'], 0)

    def test_a_dry_run_deletes_nothing(self):
        with patch.object(SWEEP, 'walk', return_value=[ref('b1', 1, WORKER)]), \
             patch.object(SWEEP, 'open_pulls', return_value=[]), \
             patch.object(SWEEP.subprocess, 'run') as run:
            record = SWEEP.clean_branches('owner/repo', SWEEP.time.monotonic(), True)
        run.assert_not_called()
        self.assertEqual((record['found'], record['not_reached']), (1, 1))


class Sweeping(unittest.TestCase):
    def sweep(self, exits, *, clock=None):
        runs = []
        def run(command, **kwargs):
            runs.append((command[-1], kwargs['env']['DISPATCH_PR'],
                         kwargs['env']['GITHUB_EVENT_NAME']))
            return subprocess.CompletedProcess(command, exits[len(runs) - 1])
        patches = [patch.object(SWEEP, 'open_pulls', return_value=[row(1), row(2), row(3)]),
                   patch.object(SWEEP, 'quota', return_value=None),
                   patch.object(SWEEP, 'clean_branches', return_value={'found': 0}),
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
        errors = io.StringIO()
        with patch.object(SWEEP, 'open_pulls', side_effect=ValueError('refused')), \
             patch.object(SWEEP, 'quota', return_value={'core': {'remaining': 0}}), \
             patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/repo'}), \
             patch.object(SWEEP.sys, 'argv', ['sweep']), redirect_stderr(errors):
            self.assertEqual(SWEEP.main(), 1)
        self.assertIn('refused', errors.getvalue())
        self.assertIn('"quota_before": {"core": {"remaining": 0}}', errors.getvalue())

    def test_the_quota_record_keeps_limit_and_reset(self):
        budget = {'remaining': 7, 'limit': 9, 'reset': 11, 'used': 2}
        answer = {'resources': {'core': budget, 'graphql': budget, 'search': budget}}
        with patch.object(SWEEP, 'gh', return_value=answer):
            self.assertEqual(SWEEP.quota(), {
                name: {'remaining': 7, 'limit': 9, 'reset': 11} for name in ('core', 'graphql')})
        with patch.object(SWEEP, 'gh', side_effect=ValueError('refused')):
            self.assertIsNone(SWEEP.quota())

    def test_a_refusal_is_recorded_from_its_start(self):
        refused = subprocess.CompletedProcess([], 1, '', 'API rate limit exceeded' + 'x' * 900)
        with patch.object(SWEEP.subprocess, 'run', return_value=refused), \
             self.assertRaisesRegex(ValueError, '^API rate limit exceeded'):
            SWEEP.gh(['api', 'graphql'])

    def test_the_exit_status_matches_the_worker(self):
        spec = importlib.util.spec_from_file_location('worker', HERE / 'approval-auto-merge.py')
        worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(worker)
        self.assertEqual(SWEEP.QUOTA_EXIT, worker.QUOTA_EXIT)
        self.assertEqual(SWEEP.REQUIRED_APPROVALS, worker.REQUIRED_APPROVALS)


if __name__ == '__main__':
    unittest.main()
