#!/usr/bin/env python3
"""Exercise automatic merge admission and receipts without contacting GitHub."""
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('approval_auto_merge', HERE / 'approval-auto-merge.py')
assert SPEC is not None and SPEC.loader is not None
MERGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MERGE)
REPO = 'owner/repo'
PREFIX = f'repos/{REPO}'
UUID = '17c973b1-a544-47b3-bb56-86176f096620'
T1 = '2026-11-09T01:00:00Z'
T2 = '2026-11-09T02:00:00Z'


def sha(number):
    return f'{number:040x}'


def review(rid, account=2, state='APPROVED', *, head=sha(101), when=T1):
    return {'id': rid, 'state': state, 'commit_id': head, 'submitted_at': when,
            'user': {'id': account, 'login': f'reviewer-{account}'}, 'body': ''}


class FakeGitHub:
    """Only the gh process boundary is replaced; both source helpers run."""

    def __init__(self, states=None):
        self.pulls, self.reviews, self.counts = {}, {}, {}
        self.hook = lambda path, count: None
        self.rules = [{'type': 'pull_request', 'parameters': {
            'required_approving_review_count': 2, 'dismiss_stale_reviews_on_push': True}}]
        self.stack = None
        states = states or ['open']
        for position, state in enumerate(states, 1):
            number = 100 + position
            self.pulls[number] = {
                'number': number, 'user': {'id': 100, 'login': 'author'},
                'state': 'open' if state == 'open' else 'closed',
                'draft': False, 'merged': state == 'merged',
                'base': {'ref': 'main' if position == 1 else f'layer-{number - 1}',
                         'sha': sha(number - 1), 'repo': {'full_name': REPO}},
                'head': {'ref': f'layer-{number}', 'sha': sha(number),
                         'repo': {'full_name': REPO}},
                'stack': None if len(states) == 1 else {
                    'id': 7, 'number': 900, 'base': {'ref': 'main'},
                    'position': position, 'size': len(states)}}
            self.reviews[number] = [review(number * 10, head=sha(number)),
                                    review(number * 10 + 1, 3, head=sha(number))]
        if len(states) > 1:
            self.stack = {'id': 7, 'number': 900, 'base': {'ref': 'main'},
                          'pull_requests': [
                              {'number': number, 'state': row['state'],
                               'head': {'sha': row['head']['sha']}}
                              for number, row in self.pulls.items()]}

    def output(self, command):
        if command[:2] != ['gh', 'api']:
            raise AssertionError(f'unexpected command: {command}')
        path = next(part for part in command[2:] if part.startswith(PREFIX + '/'))
        self.counts[path] = self.counts.get(path, 0) + 1
        self.hook(path, self.counts[path])
        if path == PREFIX + '/rules/branches/main':
            value = self.rules
        elif path == PREFIX + '/stacks/900':
            value = self.stack
        else:
            suffix = path.removeprefix(PREFIX + '/pulls/').split('/')
            number = int(suffix[0])
            if len(suffix) == 1:
                value = self.pulls[number]
            else:
                assert suffix[1] == 'reviews?per_page=100', path
                # Multiple pages exercise the production pagination flattening.
                history = self.reviews[number]
                value = [history[:1], history[1:]]
        return json.dumps(value)

    def run(self, command, **kwargs):
        return subprocess.CompletedProcess(command, 0, self.output(command), '')

    def check_output(self, command, **kwargs):
        return self.output(command)

    def __enter__(self):
        self.patches = ExitStack()
        self.patches.enter_context(patch.object(MERGE.subprocess, 'run', side_effect=self.run))
        self.patches.enter_context(patch.object(MERGE.subprocess, 'check_output',
                                               side_effect=self.check_output))
        return self

    def __exit__(self, *args):
        return self.patches.__exit__(*args)


class AutomaticMergeAdmission(unittest.TestCase):
    def test_two_distinct_accounts_admit_the_current_head(self):
        with FakeGitHub():
            selected, head, scope = MERGE.prepare(REPO, 101)
        self.assertEqual((selected, head, scope['stack']), (101, sha(101), None))

    def test_duplicate_stale_dismissed_author_and_blocking_reviews_do_not_admit(self):
        cases = {
            'same account': [review(1), review(2)],
            'stale head': [review(1), review(2, 3, head=sha(99))],
            'dismissed': [review(1), review(2, 3), review(3, 3, 'DISMISSED', when=T2)],
            'author': [review(1), review(2, 100)],
            'remaining request': [review(1), review(2, 3), review(3, 4, 'CHANGES_REQUESTED')],
            'ambiguous decision': [review(1), review(2, 3), review(3, 3, 'CHANGES_REQUESTED')],
        }
        for label, history in cases.items():
            with self.subTest(label), FakeGitHub() as github:
                github.reviews[101] = history
                with self.assertRaises(MERGE.Hold):
                    MERGE.prepare(REPO, 101)

    def test_lower_review_selects_the_top_and_every_unmerged_member_needs_two(self):
        with FakeGitHub(['merged', 'open', 'open']) as github:
            github.reviews[101] = []
            second = github.reviews[102].pop()
            with self.assertRaisesRegex(MERGE.Hold, '#102 has 1/2'):
                MERGE.prepare(REPO, 102)
            github.reviews[102].append(second)
            selected, _, scope = MERGE.prepare(REPO, 102)
        self.assertEqual(selected, 103)
        self.assertEqual([member['number'] for member in scope['scope']], [101, 102, 103])

    def test_closed_unmerged_middle_and_top_block_the_whole_stack(self):
        for states in (['open', 'closed', 'open'], ['open', 'open', 'closed']):
            with self.subTest(states=states), FakeGitHub(states):
                with self.assertRaises(ValueError):
                    MERGE.prepare(REPO, 101)

    def test_retarget_between_the_first_read_and_snapshot_does_not_merge_elsewhere(self):
        with FakeGitHub() as github:
            def retarget(path, count):
                if path == PREFIX + '/pulls/101' and count == 2:
                    github.pulls[101]['base'] = {
                        'ref': 'release/v9.9.9', 'sha': sha(9), 'repo': {'full_name': REPO}}
            github.hook = retarget
            with self.assertRaisesRegex(MERGE.Hold, 'only scopes targeting main'):
                MERGE.prepare(REPO, 101)

    def test_head_membership_and_review_changes_during_admission_refuse(self):
        for changed in ('head', 'membership', 'review'):
            with self.subTest(changed=changed), FakeGitHub(['open', 'open']) as github:
                def change(path, count):
                    if changed == 'membership' and path == PREFIX + '/stacks/900' and count == 3:
                        assert github.stack is not None
                        github.stack['pull_requests'].append(
                            {'number': 103, 'state': 'open', 'head': {'sha': sha(103)}})
                    if path != PREFIX + '/pulls/101/reviews?per_page=100' or count != 2:
                        return
                    if changed == 'head':
                        assert github.stack is not None
                        github.pulls[101]['head']['sha'] = sha(9001)
                        github.stack['pull_requests'][0]['head']['sha'] = sha(9001)
                    elif changed == 'review':
                        github.reviews[101].append(review(9001, 4, 'CHANGES_REQUESTED', when=T2))
                github.hook = change
                with self.assertRaises(ValueError):
                    MERGE.prepare(REPO, 101)

    def test_release_heads_and_missing_server_review_rules_stay_manual(self):
        for reason in ('release', 'missing server rule'):
            with self.subTest(reason=reason), FakeGitHub() as github:
                if reason == 'release':
                    github.pulls[101]['head']['ref'] = 'release/v1.2.3'
                else:
                    github.rules = []
                with self.assertRaises(MERGE.Hold):
                    MERGE.prepare(REPO, 101)


class AutomaticMergeReceipts(unittest.TestCase):
    def setUp(self):
        self.scope = {'stack': {'number': 900},
                      'scope': [{'number': 101}, {'number': 102}]}
        self.receipt = {'status': 'pending', 'details': {'uuid': UUID}}

    def operation(self, returncode=0):
        return subprocess.CompletedProcess([], returncode, json.dumps(self.receipt), '')

    def test_pending_conflict_observes_the_existing_receipt_without_resubmitting(self):
        with patch.object(MERGE.subprocess, 'run', return_value=self.operation(1)) as command, \
             patch.object(MERGE, 'read', return_value={'status': 'pending'}) as read, \
             patch.object(MERGE, 'pull', return_value={'merged': False}), \
             redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertEqual(command.call_count, 1)
        self.assertIn(PREFIX + '/pulls/102/merge-async', command.call_args.args[0])
        self.assertIn('-F', command.call_args.args[0])
        self.assertIn('bypass_rules=false', command.call_args.args[0])
        read.assert_called_once_with(PREFIX + f'/pulls/102/merge-async/{UUID}')
        self.assertIn(UUID, json.dumps(result))

    def test_receipt_is_visible_before_a_readback_failure(self):
        output = io.StringIO()
        def unavailable(path):
            self.assertIn(UUID, output.getvalue())
            raise ValueError('result readback unavailable')
        with patch.object(MERGE.subprocess, 'run', return_value=self.operation()), \
             patch.object(MERGE, 'read', side_effect=unavailable), \
             patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': ''}), \
             redirect_stdout(output):
            try:
                MERGE.submit(REPO, 102, sha(102), self.scope)
            except ValueError:
                pass
        self.assertIn(UUID, output.getvalue())

    def test_terminal_failed_merge_is_not_a_successful_worker_exit(self):
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': ''}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'prepare', return_value=(102, sha(102), self.scope)), \
             patch.object(MERGE.subprocess, 'run', return_value=self.operation()), \
             patch.object(MERGE, 'read', return_value={'status': 'failed',
                                                      'details': {'message': 'rules rejected'}}), \
             patch.object(MERGE, 'pull', return_value={'merged': False}), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = MERGE.main()
        self.assertNotEqual(code, 0)


if __name__ == '__main__':
    unittest.main()
