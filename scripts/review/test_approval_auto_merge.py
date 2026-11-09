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
import types
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
        self.mutations = []
        self.merge_returncode = 0
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
                'draft': False, 'merged': state == 'merged', 'auto_merge': None,
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
        if command[:3] == ['gh', 'pr', 'merge']:
            self.mutations.append(command)
            number = int(command[3])
            if '--disable-auto' in command:
                self.pulls[number]['auto_merge'] = None
            elif '--auto' in command:
                self.pulls[number]['auto_merge'] = {'merge_method': 'squash'}
            else:
                raise AssertionError(f'unexpected mutation: {command}')
            result = subprocess.CompletedProcess(command, self.merge_returncode, '', '')
            if kwargs.get('check'):
                result.check_returncode()
            return result
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


class DefaultAutoMergeReservation(unittest.TestCase):
    def test_ready_standalone_is_armed_before_any_approval(self):
        with FakeGitHub() as github, redirect_stdout(io.StringIO()):
            github.reviews[101] = []
            result = MERGE.auto_merge_default(REPO, 101)
        self.assertEqual(github.mutations, [
            ['gh', 'pr', 'merge', '101', '--repo', REPO,
             '--auto', '--squash', '--match-head-commit', sha(101)]])
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result['status'], 'auto_merge_enabled')
        self.assertFalse(any('/reviews' in path for path in github.counts))

    def test_an_existing_reservation_does_not_repeat_the_cli_mutation(self):
        with FakeGitHub() as github:
            github.pulls[101]['auto_merge'] = {'merge_method': 'squash'}
            result = MERGE.auto_merge_default(REPO, 101)
        self.assertEqual(github.mutations, [])
        assert result is not None
        self.assertEqual(result['status'], 'auto_merge_enabled')

    def test_draft_non_main_and_release_prs_are_not_armed(self):
        for excluded in ('draft', 'non-main', 'release'):
            with self.subTest(excluded=excluded), FakeGitHub() as github:
                row = github.pulls[101]
                if excluded == 'draft':
                    row['draft'] = True
                elif excluded == 'non-main':
                    row['base']['ref'] = 'parent-branch'
                else:
                    row['head']['ref'] = 'release/v1.2.3'
                self.assertIsNone(MERGE.auto_merge_default(REPO, 101))
                self.assertEqual(github.mutations, [])

    def test_native_members_disable_lower_reservations_and_never_arm_a_layer(self):
        with FakeGitHub(['open', 'open']) as github:
            github.pulls[101]['auto_merge'] = {'merge_method': 'squash'}
            self.assertIsNone(MERGE.auto_merge_default(REPO, 102))
        self.assertEqual(github.mutations, [
            ['gh', 'pr', 'merge', '101', '--repo', REPO, '--disable-auto']])
        self.assertFalse(any('--auto' in command for command in github.mutations))

    def test_excluded_prs_drop_an_existing_reservation(self):
        for excluded in ('draft', 'non-main', 'release'):
            with self.subTest(excluded=excluded), FakeGitHub() as github:
                row = github.pulls[101]
                row['auto_merge'] = {'merge_method': 'squash'}
                if excluded == 'draft':
                    row['draft'] = True
                elif excluded == 'non-main':
                    row['base']['ref'] = 'parent-branch'
                else:
                    row['head']['ref'] = 'release/v1.2.3'
                self.assertIsNone(MERGE.auto_merge_default(REPO, 101))
                self.assertIsNone(row['auto_merge'])
                self.assertEqual(github.mutations, [
                    ['gh', 'pr', 'merge', '101', '--repo', REPO, '--disable-auto']])

    def test_concurrent_enable_confirms_the_server_reservation_after_cli_failure(self):
        with FakeGitHub() as github, redirect_stdout(io.StringIO()):
            github.merge_returncode = 1
            result = MERGE.auto_merge_default(REPO, 101)
        assert result is not None
        self.assertEqual(result['status'], 'auto_merge_enabled')
        self.assertEqual(len(github.mutations), 1)

    def test_identity_changes_before_arming_refuse_without_a_mutation(self):
        for changed in ('head', 'base', 'draft'):
            with self.subTest(changed=changed), FakeGitHub() as github:
                def change(path, count):
                    if path != PREFIX + '/pulls/101' or count != 3:
                        return
                    if changed == 'head':
                        github.pulls[101]['head']['sha'] = sha(9999)
                    elif changed == 'base':
                        github.pulls[101]['base']['ref'] = 'different-target'
                    else:
                        github.pulls[101]['draft'] = True
                github.hook = change
                with self.assertRaises(ValueError):
                    MERGE.auto_merge_default(REPO, 101)
                self.assertEqual(github.mutations, [])


class AutomaticMergeReceipts(unittest.TestCase):
    def setUp(self):
        self.scope = {'stack': {'number': 900},
                      'scope': [{'number': 101}, {'number': 102}]}
        self.receipt = {'status': 'pending', 'details': {'uuid': UUID}}
        # Receipt tests read once unless they install a clock.
        for patcher in (patch.object(MERGE, 'WAIT_SECONDS', 0),
                        patch.object(MERGE, 'hand_off', side_effect=lambda repo, outcome: outcome)):
            patcher.start()
            self.addCleanup(patcher.stop)

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
             patch.object(MERGE, 'auto_merge_default', return_value=None), \
             patch.object(MERGE, 'prepare', return_value=(102, sha(102), self.scope)), \
             patch.object(MERGE.subprocess, 'run', return_value=self.operation()), \
             patch.object(MERGE, 'read', return_value={'status': 'failed',
                                                      'details': {'message': 'rules rejected'}}), \
             patch.object(MERGE, 'pull', return_value={'merged': False}), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = MERGE.main()
        self.assertNotEqual(code, 0)


class FollowingAcceptedMerges(unittest.TestCase):
    """Follow the original receipt to a verified result; never resend."""

    def setUp(self):
        self.scope = {'stack': {'number': 900},
                      'scope': [{'number': 101}, {'number': 102}]}
        self.now = 0.0
        clock = types.SimpleNamespace(monotonic=lambda: self.now, sleep=self.advance,
                                      time=lambda: 1000.0 + self.now)
        patcher = patch.object(MERGE, 'time', clock)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.puts = []

    def advance(self, seconds):
        self.now += seconds

    def accepted(self, returncode=0, body=None):
        body = {'status': 'pending', 'details': {'uuid': UUID}} if body is None else body
        def run(command, **kwargs):
            self.puts.append(command)
            return subprocess.CompletedProcess(command, returncode,
                                               body if isinstance(body, str) else json.dumps(body), '')
        return patch.object(MERGE.subprocess, 'run', side_effect=run)

    @staticmethod
    def landed(number):
        return {'merged': True, 'merge_commit_sha': sha(number + 5000)}

    def test_pending_then_enqueued_is_final_and_members_decide_completion(self):
        statuses = iter([{'status': 'pending'}, {'status': 'pending'}, {'status': 'enqueued'}])
        merged_after = {'count': 0}
        def pull(repo, number):
            merged_after['count'] += 1
            done = merged_after['count'] > 4  # first two polls: members still open
            return self.landed(number) if done else {'merged': False}
        with self.accepted(), patch.object(MERGE, 'read', side_effect=lambda path: next(statuses)), \
             patch.object(MERGE, 'pull', side_effect=pull), redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertEqual(result['status'], 'merged')
        self.assertEqual(result['uuid'], UUID)
        self.assertEqual(result['head'], sha(102))
        self.assertEqual(sorted(result['member_states']), [101, 102])
        self.assertTrue(all(row['merge_commit_sha'] for row in result['member_states'].values()))
        self.assertEqual(len(self.puts), 1)

    def test_transient_read_failures_retry_the_same_receipt_without_resubmitting(self):
        calls = {'n': 0}
        def read(path):
            calls['n'] += 1
            self.assertEqual(path, PREFIX + f'/pulls/102/merge-async/{UUID}')
            if calls['n'] < 3:
                raise ValueError('temporary gateway error')
            return {'status': 'merged'}
        with self.accepted(), patch.object(MERGE, 'read', side_effect=read), \
             patch.object(MERGE, 'pull', side_effect=lambda r, n: self.landed(n)), \
             redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertEqual(result['status'], 'merged')
        self.assertEqual(len(self.puts), 1)

    def test_merged_receipt_is_not_success_until_every_member_has_a_commit(self):
        for partial in ({'merged': False}, {'merged': True, 'merge_commit_sha': None}):
            with self.subTest(partial=partial), self.accepted(), \
                 patch.object(MERGE, 'read', return_value={'status': 'merged'}), \
                 patch.object(MERGE, 'pull', side_effect=lambda r, n: (
                     self.landed(n) if n == 101 else partial)), \
                 redirect_stdout(io.StringIO()):
                result = MERGE.submit(REPO, 102, sha(102), self.scope)
            self.assertEqual(result['status'], 'resume_dispatched')
            self.assertEqual(result['previous'], 'still_pending')

    def test_a_queue_that_outlasts_the_wait_is_handed_off_with_its_receipt(self):
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': ''}
        output = io.StringIO()
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'auto_merge_default', return_value=None), \
             patch.object(MERGE, 'prepare', return_value=(102, sha(102), self.scope)), \
             self.accepted(), patch.object(MERGE, 'read', return_value={'status': 'pending'}), \
             patch.object(MERGE, 'pull', return_value={'merged': False}), \
             redirect_stdout(output), redirect_stderr(io.StringIO()):
            code = MERGE.main()
        self.assertEqual(code, 0)  # handed off, not a merge confirmation
        self.assertIn('resume_dispatched', output.getvalue())
        self.assertIn('still_pending', output.getvalue())
        self.assertIn(UUID, output.getvalue())
        self.assertEqual(len([c for c in self.puts if '--method' in c]), 1)
        self.assertGreaterEqual(self.now, MERGE.WAIT_SECONDS)

    def test_terminal_failure_keeps_the_reason(self):
        failure = {'status': 'failed', 'details': {'message': 'rules rejected'}}
        with self.accepted(), patch.object(MERGE, 'read', return_value=failure), \
             patch.object(MERGE, 'pull', return_value={'merged': False}), \
             redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], {'message': 'rules rejected'})

    def test_an_unreadable_answer_checks_state_and_never_resends(self):
        for body in ('', 'not json', '[]'):
            self.puts.clear()
            with self.subTest(body=body), self.accepted(1, body), \
                 patch.object(MERGE, 'pull', return_value={'merged': False}):
                result = MERGE.submit(REPO, 102, sha(102), self.scope)
            self.assertEqual(result['status'], 'submission_unknown')
            self.assertEqual(result['request']['head'], sha(102))
            self.assertEqual(len(self.puts), 1)

    def test_an_unreadable_answer_after_a_real_merge_is_confirmed_from_the_members(self):
        with self.accepted(0, 'lost'), \
             patch.object(MERGE, 'pull', side_effect=lambda r, n: self.landed(n)):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertEqual(result['status'], 'merged')
        self.assertEqual(len(self.puts), 1)

    def test_enqueued_never_becomes_merged_so_member_state_completes_it(self):
        calls = {'n': 0}
        def pull(repo, number):
            calls['n'] += 1
            return self.landed(number) if calls['n'] > 6 else {'merged': False}
        with self.accepted(), patch.object(MERGE, 'read', return_value={'status': 'enqueued'}), \
             patch.object(MERGE, 'pull', side_effect=pull), redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertEqual(result['status'], 'merged')
        self.assertLess(self.now, MERGE.WAIT_SECONDS)

    def test_enqueued_with_unmerged_members_is_not_success(self):
        with self.accepted(), patch.object(MERGE, 'read', return_value={'status': 'enqueued'}), \
             patch.object(MERGE, 'pull', return_value={'merged': False}), \
             patch.object(MERGE.subprocess, 'run', side_effect=lambda c, **k: (
                 subprocess.CompletedProcess(c, 0, json.dumps(self.receipt_body()), '')
                 if 'merge-async' in ' '.join(c) and '--method' in c else
                 subprocess.CompletedProcess(c, 0, '', ''))), \
             redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertNotEqual(result['status'], 'merged')

    @staticmethod
    def receipt_body():
        return {'status': 'pending', 'details': {'uuid': UUID}}

    def test_a_long_wait_hands_the_original_receipt_to_a_new_run_without_a_new_merge(self):
        runs = []
        def run(command, **kwargs):
            runs.append(command)
            if command[:3] == ['gh', 'workflow', 'run']:
                return subprocess.CompletedProcess(command, 0, '', '')
            return subprocess.CompletedProcess(command, 0, json.dumps(self.receipt_body()), '')
        with patch.object(MERGE.subprocess, 'run', side_effect=run), \
             patch.object(MERGE, 'read', return_value={'status': 'pending'}), \
             patch.object(MERGE, 'pull', return_value={'merged': False}), \
             patch.object(MERGE.time, 'time', create=True, return_value=1000.0), \
             redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertEqual(result['status'], 'resume_dispatched')
        puts = [c for c in runs if '--method' in c]
        dispatches = [c for c in runs if c[:3] == ['gh', 'workflow', 'run']]
        self.assertEqual((len(puts), len(dispatches)), (1, 1))
        receipt = json.loads(dispatches[0][dispatches[0].index('-f') + 3].removeprefix('receipt='))
        self.assertEqual((receipt['uuid'], receipt['head'], receipt['pr'], receipt['members']),
                         (UUID, sha(102), 102, [101, 102]))

    def test_a_failed_dispatch_stays_red_and_age_never_ends_the_chain(self):
        outcome = {'status': 'still_pending', 'uuid': UUID, 'pr': 102, 'head': sha(102),
                   'members': [101, 102], 'since': 0}
        with patch.object(MERGE.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
            old = MERGE.hand_off(REPO, outcome)  # submitted 50 hours ago in this test
        self.assertEqual(old['status'], 'resume_dispatched')
        self.assertEqual(run.call_count, 1)
        with patch.object(MERGE.subprocess, 'run', side_effect=OSError('gh missing')):
            failed = MERGE.hand_off(REPO, outcome)
        self.assertEqual(failed['status'], 'still_pending')
        self.assertIn('dispatch_failed', failed['resume'])

    def resume_environment(self, **extra):
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102), 'members': [101, 102], 'since': 1.0}
        return dict({'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                     'DISPATCH_PR': '102', 'DISPATCH_RECEIPT': json.dumps(receipt),
                     'GITHUB_STEP_SUMMARY': ''}, **extra)

    def test_dry_run_with_a_receipt_reads_but_never_dispatches_or_writes(self):
        with patch.dict(os.environ, self.resume_environment()), \
             patch.object(sys, 'argv', ['auto-merge', '--dry-run']), \
             patch.object(MERGE, 'read', return_value={'status': 'pending'}), \
             patch.object(MERGE, 'pull', return_value={'merged': False, 'state': 'open'}), \
             patch.object(MERGE.subprocess, 'run') as run, \
             patch.object(MERGE.time, 'sleep'), patch.object(MERGE, 'WAIT_SECONDS', 0), \
             redirect_stdout(io.StringIO()) as output:
            code = MERGE.main()
        run.assert_not_called()
        self.assertEqual(code, 1)
        self.assertIn('still_pending', output.getvalue())
        self.assertNotIn('resume_dispatched', output.getvalue())

    def test_a_request_that_is_gone_or_a_closed_member_ends_the_chain_visibly(self):
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102), 'members': [101, 102], 'since': 1.0}
        with patch.object(MERGE, 'read', side_effect=ValueError('gh: Not Found (HTTP 404)')), \
             patch.object(MERGE.subprocess, 'run') as run:
            gone = MERGE.resume(REPO, receipt)
        self.assertEqual(gone['status'], 'request_not_found')
        run.assert_not_called()
        with patch.object(MERGE, 'read', return_value={'status': 'pending'}), \
             patch.object(MERGE, 'pull', return_value={'merged': False, 'state': 'closed'}), \
             patch.object(MERGE.subprocess, 'run') as run:
            closed = MERGE.resume(REPO, receipt)
        self.assertEqual(closed['status'], 'member_closed_unmerged')
        run.assert_not_called()
        self.assertNotIn(gone['status'], MERGE.SUCCESS)
        self.assertNotIn(closed['status'], MERGE.SUCCESS)

    def test_resume_reads_only_the_recorded_receipt_and_completes(self):
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102), 'members': [101, 102], 'since': 1.0}
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'DISPATCH_RECEIPT': json.dumps(receipt),
                       'GITHUB_STEP_SUMMARY': ''}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'auto_merge_default') as arm, patch.object(MERGE, 'prepare') as admit, \
             patch.object(MERGE.subprocess, 'run') as run, \
             patch.object(MERGE, 'read', return_value={'status': 'enqueued'}) as read, \
             patch.object(MERGE, 'pull', side_effect=lambda r, n: self.landed(n)), \
             redirect_stdout(io.StringIO()) as output:
            code = MERGE.main()
        self.assertEqual(code, 0)
        arm.assert_not_called(); admit.assert_not_called(); run.assert_not_called()
        read.assert_called_once_with(PREFIX + f'/pulls/102/merge-async/{UUID}')
        self.assertIn('"status": "merged"', output.getvalue())

    def test_untrusted_receipts_are_rejected_before_any_read(self):
        good = {'uuid': UUID, 'pr': 102, 'head': sha(102), 'members': [101, 102], 'since': 1.0}
        bad = [dict(good, uuid='../../x'), dict(good, head='abc'), dict(good, pr=True),
               dict(good, members=[]), dict(good, members=[1, 'x', 102]), dict(good, extra=1),
               dict(good, pr=999), 'not json', []]
        for case in bad:
            with self.subTest(case=case), patch.object(MERGE, 'read') as read:
                raw = case if isinstance(case, str) else json.dumps(case)
                with self.assertRaises(ValueError):
                    MERGE.parse_receipt(raw)
                read.assert_not_called()


if __name__ == '__main__':
    unittest.main()
