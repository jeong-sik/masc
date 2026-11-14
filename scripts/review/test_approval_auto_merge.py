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
from unittest.mock import call, patch


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


# A pull request names its repository by id and full name. The stack listing
# names the same repository by id, name and url, and never by full name.
HOME = {'id': 1, 'full_name': REPO}


def listed(row):
    """The entry of the stack listing for one pull request row."""
    def side(ref):
        return {'ref': ref['ref'], 'sha': ref['sha'],
                'repo': {'id': ref['repo']['id'], 'name': 'r', 'url': 'https://api.github.test/r'}}
    return {'number': row['number'], 'state': row['state'], 'draft': row['draft'],
            'merged_at': T1 if row['merged'] else None, 'user': row['user'],
            'base': side(row['base']), 'head': side(row['head'])}


def sha(number):
    return f'{number:040x}'


def review(rid, account=2, state='APPROVED', *, head=sha(101), when=T1):
    return {'id': rid, 'state': state, 'commit_id': head, 'submitted_at': when,
            'user': {'id': account, 'login': f'reviewer-{account}'}, 'body': ''}


def type_check(rid, head, conclusion='skipped', *, status='completed', app='github-actions'):
    return {'id': rid, 'name': 'type-check', 'head_sha': head, 'status': status,
            'conclusion': conclusion if status == 'completed' else None, 'app': {'slug': app}}


class FakeGitHub:
    """Only the gh process boundary is replaced; both source helpers run."""

    def __init__(self, states=None):
        self.pulls, self.reviews, self.counts = {}, {}, {}
        # Head SHA -> its type-check runs, and -> the files `main...head` lists.
        # A comparison no test prepared is a read the worker should not make.
        self.type_checks, self.compared = {}, {}
        self.mutations = []
        self.list_page_size = 100
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
                         'sha': sha(number - 1), 'repo': HOME},
                'head': {'ref': f'layer-{number}', 'sha': sha(number),
                         'repo': HOME},
                'stack': None if len(states) == 1 else {
                    'id': 7, 'number': 900, 'base': {'ref': 'main'},
                    'position': position, 'size': len(states)}}
            self.reviews[number] = [review(number * 10, head=sha(number)),
                                    review(number * 10 + 1, 3, head=sha(number))]
        if len(states) > 1:
            self.stack = {'id': 7, 'number': 900, 'base': {'ref': 'main'},
                          'pull_requests': [listed(row) for row in self.pulls.values()]}

    def output(self, command):
        if command[:2] != ['gh', 'api']:
            raise AssertionError(f'unexpected command: {command}')
        path = next(part for part in command[2:] if part.startswith(PREFIX + '/'))
        self.counts[path] = self.counts.get(path, 0) + 1
        self.hook(path, self.counts[path])
        link = ''
        if path == PREFIX + '/rules/branches/main':
            value = self.rules
        elif path == PREFIX + '/stacks/900':
            value = self.stack
        elif path.startswith(PREFIX + '/commits/'):
            head, rest = path.removeprefix(PREFIX + '/commits/').split('/', 1)
            assert rest == 'check-runs?check_name=type-check&filter=all&per_page=100', path
            runs = self.type_checks.get(head, [])
            value = {'total_count': len(runs), 'check_runs': runs}
        elif path.startswith(PREFIX + '/compare/'):
            base, head = path.removeprefix(PREFIX + '/compare/').split('...')
            assert base == 'main', path
            value = {'files': [{'filename': name} if isinstance(name, str) else name
                               for name in self.compared[head]]}
        elif path.startswith(PREFIX + '/pulls?'):
            query = dict(part.split('=') for part in path.split('?', 1)[1].split('&'))
            assert query['state'] == 'open' and query['per_page'] == '100', path
            page = int(query.get('page', '1'))
            opened = [row for _, row in sorted(self.pulls.items()) if row['state'] == 'open']
            value = opened[(page - 1) * self.list_page_size:page * self.list_page_size]
            if page * self.list_page_size < len(opened):
                link = ('\nLink: <https://api.github.com/' + PREFIX + '/pulls?state=open'
                        f'&per_page=100&page={page + 1}>; rel="next"')
        else:
            suffix = path.removeprefix(PREFIX + '/pulls/').split('/')
            number = int(suffix[0])
            if len(suffix) == 1:
                value = self.pulls[number]
            else:
                assert suffix[1] == 'reviews?per_page=100', path
                value = self.reviews[number]
        body = json.dumps(value)
        return ('HTTP/2.0 200 OK\nContent-Type: application/json' + link + '\n\n' + body
                if '--include' in command else body)

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

    def test_a_landed_stack_is_recognized_without_reading_its_layers(self):
        with FakeGitHub(['merged', 'merged', 'merged']) as github:
            with self.assertRaisesRegex(MERGE.Hold, 'already merged'):
                MERGE.prepare(REPO, 102)
        member_reads = {path: count for path, count in github.counts.items()
                        if path.startswith(PREFIX + '/pulls/')}
        self.assertEqual(member_reads, {PREFIX + '/pulls/102': 1})

    def test_only_the_first_unmerged_layer_from_the_top_is_read_to_find_the_top(self):
        with FakeGitHub(['merged', 'open', 'open']) as github:
            top = MERGE.top_pull(REPO, 102)
        self.assertEqual(top['number'], 103)
        self.assertNotIn(PREFIX + '/pulls/101', github.counts)

    def test_a_layer_that_merged_after_the_listing_is_passed_over(self):
        with FakeGitHub(['open', 'open']) as github:
            assert github.stack is not None
            github.pulls[102].update(state='closed', merged=True)
            top = MERGE.top_pull(REPO, 101)
        self.assertEqual(top['number'], 101)

    def test_an_admitted_stack_reads_only_its_top_pull_request(self):
        with FakeGitHub(['merged', 'open', 'open', 'open']) as github:
            selected, _, scope = MERGE.prepare(REPO, 104)
        self.assertEqual((selected, scope['members']), (104, [101, 102, 103, 104]))
        lower = {path: count for path, count in github.counts.items()
                 if path in {PREFIX + f'/pulls/{number}' for number in (101, 102, 103)}}
        self.assertEqual(lower, {})
        # Each unmerged layer's reviews: once for evidence, once to see that
        # they did not change during admission. A merged layer has none read.
        self.assertEqual({number: github.counts.get(PREFIX + f'/pulls/{number}/reviews?per_page=100', 0)
                          for number in (101, 102, 103, 104)}, {101: 0, 102: 2, 103: 2, 104: 2})

    def test_a_lower_layer_is_judged_at_the_head_the_listing_gives(self):
        with FakeGitHub(['open', 'open']) as github:
            assert github.stack is not None
            github.stack['pull_requests'][0]['head']['sha'] = sha(9001)
            with self.assertRaisesRegex(MERGE.Hold, '#101 has 0/2 current-head account approvals'):
                MERGE.prepare(REPO, 102)

    def test_a_draft_lower_layer_in_the_listing_holds_the_stack(self):
        with FakeGitHub(['open', 'open']) as github:
            assert github.stack is not None
            github.stack['pull_requests'][0]['draft'] = True
            with self.assertRaisesRegex(MERGE.Hold, '#101 is not open and ready'):
                MERGE.prepare(REPO, 102)

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
                        'ref': 'release/v9.9.9', 'sha': sha(9), 'repo': HOME}
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


class SkippedTypeCheck(unittest.TestCase):
    """`skipped` satisfies the required check. The worker trusts it only when
    the scope it is about to merge changes no source."""

    CHECKS = PREFIX + f'/commits/{sha(101)}/check-runs?check_name=type-check&filter=all&per_page=100'
    COMPARE = PREFIX + f'/compare/main...{sha(101)}'
    ARM = ['gh', 'pr', 'merge', '101', '--repo', REPO,
           '--auto', '--squash', '--match-head-commit', sha(101)]

    def test_a_skip_on_a_scope_without_sources_is_admitted_and_armed(self):
        with FakeGitHub() as github, redirect_stdout(io.StringIO()):
            github.type_checks[sha(101)] = [type_check(1, sha(101))]
            github.compared[sha(101)] = ['dashboard/a.ts', 'docs/evidence/run/a.ml', 'changelog.d/101.md']
            MERGE.prepare(REPO, 101)
            MERGE.auto_merge_default(REPO, 101)
        self.assertEqual(github.mutations, [self.ARM])

    def test_a_skip_on_a_scope_with_sources_is_held_and_never_armed(self):
        scopes = {
            'source file': ['dashboard/a.ts', 'lib/a.ml'],
            'build file': ['test/dune'],
            'moved away from a source path': [
                {'filename': 'docs/old.ml', 'previous_filename': 'lib/old.ml'}],
        }
        for label, files in scopes.items():
            with self.subTest(label), FakeGitHub() as github, redirect_stdout(io.StringIO()):
                github.type_checks[sha(101)] = [type_check(1, sha(101))]
                github.compared[sha(101)] = files
                with self.assertRaisesRegex(MERGE.Hold, 'type-check was skipped but the scope changes'):
                    MERGE.prepare(REPO, 101)
                self.assertIsNone(MERGE.auto_merge_default(REPO, 101))
                self.assertEqual(github.mutations, [])

    def test_an_earlier_reservation_is_dropped_when_the_skip_is_unproven(self):
        with FakeGitHub() as github:
            github.pulls[101]['auto_merge'] = {'merge_method': 'squash'}
            github.type_checks[sha(101)] = [type_check(1, sha(101))]
            github.compared[sha(101)] = ['lib/a.ml']
            self.assertIsNone(MERGE.auto_merge_default(REPO, 101))
        self.assertEqual(github.mutations, [
            ['gh', 'pr', 'merge', '101', '--repo', REPO, '--disable-auto']])

    def test_a_file_list_at_the_comparison_limit_proves_nothing(self):
        with FakeGitHub() as github:
            github.type_checks[sha(101)] = [type_check(1, sha(101))]
            github.compared[sha(101)] = [f'dashboard/{n}.ts' for n in range(MERGE.COMPARE_FILE_LIMIT)]
            with self.assertRaisesRegex(MERGE.Hold, 'too many to list'):
                MERGE.prepare(REPO, 101)
            github.compared[sha(101)].pop()
            MERGE.prepare(REPO, 101)

    def test_only_a_completed_skip_makes_the_worker_read_the_scope(self):
        left_to_github = {
            'no run yet': [],
            'queued': [type_check(1, sha(101), status='queued')],
            'running': [type_check(1, sha(101), status='in_progress')],
            'success': [type_check(1, sha(101), 'success')],
            'failure': [type_check(1, sha(101), 'failure')],
            'a later dispatched run compiled it': [
                type_check(1, sha(101)), type_check(2, sha(101), 'success')],
            'a skip reported by another app': [type_check(1, sha(101), app='someone-else')],
            'a skip of another commit': [type_check(1, sha(99))],
        }
        for label, runs in left_to_github.items():
            with self.subTest(label), FakeGitHub() as github, redirect_stdout(io.StringIO()):
                github.type_checks[sha(101)] = runs
                MERGE.prepare(REPO, 101)
                MERGE.auto_merge_default(REPO, 101)
                self.assertNotIn(self.COMPARE, github.counts)
                self.assertEqual(github.mutations, [self.ARM])

    def test_the_newest_run_decides_when_a_skip_follows_a_success(self):
        with FakeGitHub() as github:
            github.type_checks[sha(101)] = [type_check(2, sha(101)), type_check(1, sha(101), 'success')]
            github.compared[sha(101)] = ['lib/a.ml']
            with self.assertRaisesRegex(MERGE.Hold, 'type-check was skipped'):
                MERGE.prepare(REPO, 101)

    def test_more_runs_than_one_page_are_not_guessed_at(self):
        with FakeGitHub() as github:
            github.type_checks[sha(101)] = [type_check(1, sha(101), 'success')]
            real = github.output

            def cut(command):
                body = real(command)
                return body.replace('"total_count": 1', '"total_count": 101')
            with patch.object(github, 'output', side_effect=cut):
                with self.assertRaisesRegex(MERGE.Hold, 'more than 100 type-check runs'):
                    MERGE.prepare(REPO, 101)

    def test_a_stack_is_read_once_at_the_head_of_its_top(self):
        top = sha(103)
        with FakeGitHub(['merged', 'open', 'open']) as github:
            github.type_checks[top] = [type_check(1, top)]
            # The lower layer was skipped because the top checks the stack.
            github.type_checks[sha(102)] = [type_check(2, sha(102))]
            github.compared[top] = ['dashboard/a.ts', 'lib/a.ml']
            with self.assertRaisesRegex(MERGE.Hold, '#103: type-check was skipped'):
                MERGE.prepare(REPO, 102)
            github.type_checks[top].append(type_check(3, top, 'success'))
            selected, _, _ = MERGE.prepare(REPO, 102)
        self.assertEqual(selected, 103)
        self.assertFalse(any(sha(102) in path for path in github.counts if '/commits/' in path))

    def test_a_scope_change_during_the_reads_still_refuses(self):
        with FakeGitHub() as github:
            github.type_checks[sha(101)] = [type_check(1, sha(101))]
            github.compared[sha(101)] = ['dashboard/a.ts']

            def push(path, count):
                if path == self.COMPARE:
                    github.pulls[101]['head']['sha'] = sha(9001)
            github.hook = push
            with self.assertRaises(ValueError):
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

    def test_stack_reads_do_not_grow_with_the_number_of_layers(self):
        reads = {}
        for layers in (3, 12):
            with self.subTest(layers=layers), FakeGitHub(['open'] * layers) as github:
                self.assertIsNone(MERGE.auto_merge_default(REPO, 101 + layers - 1))
                reads[layers] = sum(github.counts.values())
                single = [path for path in github.counts if path.startswith(PREFIX + '/pulls/')]
                self.assertEqual(single, [f'{PREFIX}/pulls/{100 + layers}'])
                self.assertEqual(github.counts[PREFIX + '/pulls?state=open&per_page=100'], 1)
        self.assertEqual(reads[3], reads[12])

    def test_reservations_on_every_page_of_the_open_list_are_disabled(self):
        with FakeGitHub(['open'] * 5) as github:
            github.list_page_size = 2
            for number in (102, 105):
                github.pulls[number]['auto_merge'] = {'merge_method': 'squash'}
            self.assertIsNone(MERGE.auto_merge_default(REPO, 103))
        self.assertEqual(github.mutations, [
            ['gh', 'pr', 'merge', '102', '--repo', REPO, '--disable-auto'],
            ['gh', 'pr', 'merge', '105', '--repo', REPO, '--disable-auto']])
        pages_read = [path for path in github.counts if path.startswith(PREFIX + '/pulls?')]
        self.assertEqual(len(pages_read), 3)

    def test_merged_and_closed_layers_are_never_read_or_disabled(self):
        with FakeGitHub(['merged', 'open', 'closed', 'open']) as github:
            for number in (102, 103, 104):
                github.pulls[number]['auto_merge'] = {'merge_method': 'squash'}
            self.assertIsNone(MERGE.auto_merge_default(REPO, 104))
        self.assertEqual(github.mutations, [
            ['gh', 'pr', 'merge', '102', '--repo', REPO, '--disable-auto'],
            ['gh', 'pr', 'merge', '104', '--repo', REPO, '--disable-auto']])
        self.assertNotIn(PREFIX + '/pulls/101', github.counts)
        self.assertNotIn(PREFIX + '/pulls/103', github.counts)

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

    def test_a_workflow_file_refusal_is_a_distinct_answer_not_an_exception(self):
        class WorkflowRefusalGitHub(FakeGitHub):
            def run(self, command, **kwargs):
                if command[:3] == ['gh', 'pr', 'merge'] and '--auto' in command:
                    self.mutations.append(command)
                    return subprocess.CompletedProcess(command, 1, '',
                        'refusing to allow a GitHub App to create or update workflow '
                        '`scripts/review/approval-merge-sweep.yml` without `workflow` scope')
                return super().run(command, **kwargs)

        with WorkflowRefusalGitHub() as github, redirect_stdout(io.StringIO()):
            github.reviews[101] = []
            result = MERGE.auto_merge_default(REPO, 101)
        assert result is not None
        self.assertEqual(result['status'], 'workflow_merge_needs_human')
        self.assertIn('create or update workflow', result['reason'])
        self.assertEqual(result['pr'], 101)


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

    def test_pending_conflict_reports_the_existing_receipt_without_following_or_resubmitting(self):
        with patch.object(MERGE.subprocess, 'run', return_value=self.operation(1)) as command, \
             patch.object(MERGE, 'read') as read, \
             patch.object(MERGE, 'pull') as pull, \
             patch.object(MERGE, 'follow') as follow, \
             patch.object(MERGE, 'hand_off') as hand_off, \
             redirect_stdout(io.StringIO()) as output:
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        self.assertEqual(command.call_count, 1)
        self.assertIn(PREFIX + '/pulls/102/merge-async', command.call_args.args[0])
        self.assertIn('-F', command.call_args.args[0])
        self.assertIn('bypass_rules=false', command.call_args.args[0])
        for forbidden in (read, pull, follow, hand_off):
            forbidden.assert_not_called()
        self.assertEqual(result['status'], 'following_elsewhere')
        self.assertEqual(result['uuid'], UUID)
        self.assertIn(UUID, output.getvalue())

    def test_a_fresh_acceptance_still_follows_its_own_receipt(self):
        with patch.object(MERGE.subprocess, 'run', return_value=self.operation(0)), \
             patch.object(MERGE, 'follow', return_value={'status': 'merged'}) as follow, \
             redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), self.scope)
        follow.assert_called_once()
        self.assertEqual(result['status'], 'merged')

    def test_following_elsewhere_is_not_a_red_run(self):
        self.assertIn('following_elsewhere', MERGE.SUCCESS)
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': ''}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'auto_merge_default', return_value=None), \
             patch.object(MERGE, 'prepare', return_value=(102, sha(102), self.scope)), \
             patch.object(MERGE.subprocess, 'run', return_value=self.operation(1)), \
             patch.object(MERGE, 'follow') as follow, \
             redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()):
            code = MERGE.main()
        follow.assert_not_called()
        self.assertEqual(code, 0)
        self.assertIn('following_elsewhere', output.getvalue())

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
        # An empty open list means every member is read once, as before.
        self.open_list = []
        self.open_reads = 0
        def listing(repo):
            self.open_reads += 1
            return self.open_list
        patcher = patch.object(MERGE, 'open_pulls', side_effect=listing)
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

    def receipt_for(self, members):
        return {'uuid': UUID, 'pr': members[-1], 'head': sha(members[-1]),
                'members': members, 'since': 1.0}

    def test_a_poll_reads_the_open_list_and_no_member_while_every_layer_is_open(self):
        reads = {}
        for layers in (3, 12):
            members = list(range(101, 101 + layers))
            self.now, self.open_reads = 0.0, 0
            self.open_list = [{'number': number} for number in members]
            with self.subTest(layers=layers), \
                 patch.object(MERGE, 'read', return_value={'status': 'pending'}) as read, \
                 patch.object(MERGE, 'pull') as pull, patch.object(MERGE, 'WAIT_SECONDS', 30):
                result = MERGE.resume(REPO, self.receipt_for(members), dispatch=False)
            self.assertEqual(result['status'], 'still_pending')
            pull.assert_not_called()
            reads[layers] = (self.open_reads, read.call_count)
        self.assertGreaterEqual(reads[3][0], 3)
        self.assertEqual(reads[3], reads[12])

    def test_only_a_member_that_left_the_open_list_is_read_and_only_once(self):
        lists = [[{'number': 101}, {'number': 102}], [{'number': 102}], [], []]
        seen = []
        def pull(repo, number):
            seen.append(number)
            if number == 102 and seen.count(102) < 2:  # the first read of 102 is not final yet
                return {'merged': False, 'state': 'open'}
            return {'merged': True, 'state': 'closed', 'merge_commit_sha': sha(number + 5000)}
        with patch.object(MERGE, 'open_pulls', side_effect=lists) as listing, \
             patch.object(MERGE, 'read', return_value={'status': 'enqueued'}), \
             patch.object(MERGE, 'pull', side_effect=pull):
            result = MERGE.resume(REPO, self.receipt_for([101, 102]), dispatch=False)
        self.assertEqual(result['status'], 'merged')
        self.assertEqual(listing.call_count, 4)
        # 101 left the list on poll 2 and was settled; it is never read again.
        # 102 is read on every poll after it left until its closed answer is final.
        self.assertEqual(seen, [101, 102, 102])

    def test_a_member_missing_from_a_stale_list_but_still_open_is_read_again(self):
        seen = []
        def pull(repo, number):
            seen.append(number)
            if seen.count(number) < 3:
                return {'merged': False, 'state': 'open'}
            return {'merged': True, 'state': 'closed', 'merge_commit_sha': sha(number + 5000)}
        with patch.object(MERGE, 'read', return_value={'status': 'enqueued'}), \
             patch.object(MERGE, 'pull', side_effect=pull):
            result = MERGE.resume(REPO, self.receipt_for([101]), dispatch=False)
        self.assertEqual(result['status'], 'merged')
        self.assertEqual(seen, [101, 101, 101])

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

    def test_a_member_not_found_does_not_end_a_live_merge_request(self):
        for detail in ('gh: Not Found (HTTP 404)', 'gh: Gone (HTTP 410)'):
            with self.subTest(detail=detail):
                self.puts.clear()
                missing = True

                def pull(repo, number):
                    nonlocal missing
                    if missing:
                        missing = False
                        raise ValueError(detail)
                    return self.landed(number)

                with self.accepted(), patch.object(MERGE, 'read', return_value={'status': 'enqueued'}) as read, \
                     patch.object(MERGE, 'pull', side_effect=pull), redirect_stdout(io.StringIO()):
                    result = MERGE.submit(REPO, 102, sha(102), self.scope)
                self.assertEqual(result['status'], 'merged')
                self.assertEqual(result['uuid'], UUID)
                self.assertEqual(len(self.puts), 1)
                self.assertEqual(read.call_args_list, [
                    call(PREFIX + f'/pulls/102/merge-async/{UUID}')
                ] * 2)

    def test_a_member_read_failure_hands_off_the_original_receipt(self):
        receipt = json.loads(self.resume_environment()['DISPATCH_RECEIPT'])
        with patch.dict(os.environ, self.resume_environment()), \
             patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'auto_merge_default') as arm, \
             patch.object(MERGE, 'prepare') as admit, \
             patch.object(MERGE, 'read', return_value={'status': 'enqueued'}), \
             patch.object(MERGE, 'pull', side_effect=ValueError('gh: Not Found (HTTP 404)')), \
             patch.object(MERGE.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 0, '', '')) as run, \
             patch.object(MERGE, 'WAIT_SECONDS', 0), redirect_stdout(io.StringIO()) as output:
            code = MERGE.main()
        result = json.loads(output.getvalue())['result']
        self.assertEqual(code, 0)
        self.assertEqual(result['status'], 'resume_dispatched')
        self.assertEqual(result['previous'], 'observation_unavailable')
        self.assertEqual(run.call_count, 1)
        command = run.call_args.args[0]
        self.assertEqual(command[:3], ['gh', 'workflow', 'run'])
        continued = next(value.removeprefix('receipt=') for value in command
                         if value.startswith('receipt='))
        self.assertEqual(json.loads(continued), receipt)
        arm.assert_not_called()
        admit.assert_not_called()

    def test_a_failed_request_keeps_its_reason_even_if_members_are_unreadable(self):
        failure = {'status': 'failed', 'details': {'message': 'rules rejected'}}
        receipt = json.loads(self.resume_environment()['DISPATCH_RECEIPT'])
        with patch.object(MERGE, 'read', return_value=failure), \
             patch.object(MERGE, 'pull', side_effect=ValueError('gh: Not Found (HTTP 404)')) as pull, \
             patch.object(MERGE.subprocess, 'run') as run:
            result = MERGE.resume(REPO, receipt)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], failure['details'])
        pull.assert_not_called()
        run.assert_not_called()

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
        with patch.object(MERGE.subprocess, 'run', side_effect=OSError('gh missing')) as run, \
             patch.object(MERGE.time, 'sleep') as pause:
            failed = MERGE.hand_off(REPO, outcome)
        self.assertEqual(failed['status'], 'still_pending')
        self.assertIn('dispatch_failed', failed['resume'])
        # One bounded retry after a pause, never an open loop.
        self.assertEqual(run.call_count, 2)
        pause.assert_called_once_with(MERGE.HAND_OFF_RETRY_SECONDS)

    def test_a_dispatch_that_fails_once_is_retried_and_lands(self):
        outcome = {'status': 'still_pending', 'uuid': UUID, 'pr': 102, 'head': sha(102),
                   'members': [101, 102], 'since': 0}
        ok = subprocess.CompletedProcess([], 0, '', '')
        with patch.object(MERGE.subprocess, 'run', side_effect=[OSError('flaky'), ok]) as run, \
             patch.object(MERGE.time, 'sleep') as pause:
            result = MERGE.hand_off(REPO, outcome)
        self.assertEqual(result['status'], 'resume_dispatched')
        self.assertEqual((run.call_count, pause.call_count), (2, 1))

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
        with patch.object(MERGE, 'read', side_effect=MERGE.GET.ApiFailure(
                'result', 404, {}, 'unavailable')), \
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
        # This case watches re-submission. A merged verdict now also asks the
        # main build to wake, which reaches the same `subprocess.run` mock, so
        # separate that call here and keep `run` for the re-submit question.
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'auto_merge_default') as arm, patch.object(MERGE, 'prepare') as admit, \
             patch.object(MERGE.subprocess, 'run') as run, \
             patch.object(MERGE, 'wake_main_build', return_value={'dispatched': True}) as wake, \
             patch.object(MERGE, 'delete_merged_heads', return_value=[]) as cleanup, \
             patch.object(MERGE, 'close_linked_issues', return_value=[]) as closing, \
             patch.object(MERGE, 'read', return_value={'status': 'enqueued'}) as read, \
             patch.object(MERGE, 'pull', side_effect=lambda r, n: self.landed(n)), \
             redirect_stdout(io.StringIO()) as output:
            code = MERGE.main()
        self.assertEqual(code, 0)
        arm.assert_not_called(); admit.assert_not_called(); run.assert_not_called()
        wake.assert_called_once_with(REPO)
        cleanup.assert_called_once_with(REPO, [101, 102])
        closing.assert_called_once_with(REPO, [101, 102])
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


def http_response(status, value, headers=None):
    lines = [f'HTTP/2.0 {status} response']
    lines.extend(f'{key}: {value}' for key, value in (headers or {}).items())
    return subprocess.CompletedProcess([], int(status >= 400),
                                       '\n'.join(lines) + '\n\n' + json.dumps(value), '')


class QuotaGetIntegration(unittest.TestCase):
    def quota_client(self, github, path, attempt, on_pause=lambda: None):
        clock = types.SimpleNamespace(now=1000.0, sleeps=[])
        counts = {}
        def sleep(seconds):
            clock.sleeps.append(seconds)
            on_pause()
            clock.now += seconds
        def run(command, **kwargs):
            endpoint = command[-1]
            counts[endpoint] = counts.get(endpoint, 0) + 1
            if endpoint == path and counts[endpoint] == attempt:
                return http_response(403, {'message': 'limited'},
                                     {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1030'})
            return github.run(command, **kwargs)
        return (MERGE.GET.Client(run=run, clock=lambda: clock.now, sleep=sleep), clock, counts)

    def test_a_quota_pause_rechecks_head_base_and_later_reviews_before_admission(self):
        for changed in ('head', 'base', 'review'):
            with self.subTest(changed=changed), FakeGitHub() as github:
                def change():
                    if changed == 'head':
                        github.pulls[101]['head']['sha'] = sha(9001)
                    elif changed == 'base':
                        github.pulls[101]['base']['ref'] = 'other'
                    else:
                        github.reviews[101].append(review(9001, 4, 'CHANGES_REQUESTED', when=T2))
                # The last snapshot is after both review reads: resuming just
                # that GET would otherwise approve the old review history.
                client, clock, counts = self.quota_client(github, PREFIX + '/pulls/101', 3, change)
                with patch.object(MERGE, 'CLIENT', client), self.assertRaises(ValueError):
                    MERGE.prepare(REPO, 101)
                self.assertEqual(clock.sleeps, [30])
                self.assertEqual(github.mutations, [])
                self.assertEqual(counts[PREFIX + '/rules/branches/main'], 2)
                if changed == 'review':
                    self.assertGreaterEqual(counts[PREFIX + '/pulls/101/reviews?per_page=100'], 3)

    def run_main(self, client, *arguments):
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '101', 'GITHUB_STEP_SUMMARY': ''}
        output = io.StringIO()
        with patch.dict(os.environ, environment), \
             patch.object(sys, 'argv', ['auto-merge', *arguments]), \
             patch.object(MERGE, 'CLIENT', client), patch.object(MERGE, 'WAIT_SECONDS', 600), \
             patch.dict(MERGE._ADMISSION), patch.dict(MERGE._WAKE), \
             patch.object(MERGE, 'emit', side_effect=lambda result: print(json.dumps(result))), \
             redirect_stdout(output), redirect_stderr(io.StringIO()):
            client.on_quota = lambda failure: MERGE.emit(
                dict(failure.details, status='rate_limited', retry_at=failure.retry_at))
            code = MERGE.main()
            return code, output.getvalue(), MERGE.WAIT_SECONDS

    def test_an_event_run_ends_at_a_quota_instead_of_sleeping(self):
        for path in (PREFIX + '/pulls/101', PREFIX + '/rules/branches/main'):
            with self.subTest(path=path), FakeGitHub() as github:
                client, clock, _ = self.quota_client(github, path, 1)
                code, output, _ = self.run_main(client)
                self.assertEqual(code, MERGE.QUOTA_EXIT)
                self.assertEqual(clock.sleeps, [])
                self.assertEqual(github.mutations, [])
                self.assertIn('"status": "rate_limited"', output)
                self.assertIn('"retry_at": 1030', output)
                self.assertIsNone(client.deadline)

    def test_a_dry_run_still_waits_out_a_quota(self):
        with FakeGitHub() as github:
            client, clock, _ = self.quota_client(github, PREFIX + '/rules/branches/main', 1)
            code, _, _ = self.run_main(client, '--dry-run')
        self.assertEqual((code, clock.sleeps), (0, [30]))

    def test_hand_off_now_leaves_no_time_to_follow_in_this_run(self):
        with FakeGitHub() as github:
            client, _, _ = self.quota_client(github, PREFIX + '/none', 1)
            _, _, wait = self.run_main(client, '--dry-run', '--hand-off-now')
        self.assertEqual(wait, 0)

    def test_a_new_head_with_its_own_two_reviews_is_admitted_only_after_fresh_reads(self):
        with FakeGitHub() as github:
            def change():
                github.pulls[101]['head']['sha'] = sha(9001)
                github.reviews[101] = [review(9001, 2, head=sha(9001)), review(9002, 3, head=sha(9001))]
            client, _, counts = self.quota_client(github, PREFIX + '/pulls/101', 3, change)
            with patch.object(MERGE, 'CLIENT', client):
                selected, head, _ = MERGE.prepare(REPO, 101)
        self.assertEqual((selected, head), (101, sha(9001)))
        self.assertEqual(counts[PREFIX + '/rules/branches/main'], 2)
        self.assertEqual(github.mutations, [])

    def test_an_auth_failure_after_a_quota_pause_is_not_restarted_or_held(self):
        clock, calls = types.SimpleNamespace(now=1000.0), []
        def run(command, **kwargs):
            calls.append(command)
            return http_response(403, {'message': 'refused'},
                {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1030'} if len(calls) == 1 else {})
        client = MERGE.GET.Client(run=run, clock=lambda: clock.now,
                                 sleep=lambda seconds: setattr(clock, 'now', clock.now + seconds))
        with patch.object(MERGE, 'CLIENT', client), self.assertRaises(MERGE.GET.ApiFailure):
            MERGE.prepare(REPO, 101)
        self.assertEqual(len(calls), 2)

    def test_native_snapshot_uses_the_same_get_transport(self):
        with FakeGitHub(['open', 'open']) as github:
            # The second read of the listing is the snapshot's own.
            client, clock, _ = self.quota_client(github, PREFIX + '/stacks/900', 2)
            with patch.object(MERGE, 'CLIENT', client), \
                 patch.object(MERGE.subprocess, 'check_output') as legacy:
                selected, _, scope = MERGE.prepare(REPO, 101)
            legacy.assert_not_called()
        self.assertEqual((selected, scope['members'], client.pauses), (102, [101, 102], 1))
        self.assertEqual(clock.sleeps, [30])

    def test_a_quota_on_post_reservation_readback_never_replays_the_write(self):
        with FakeGitHub() as github, redirect_stdout(io.StringIO()):
            client, clock, _ = self.quota_client(github, PREFIX + '/pulls/101', 4)
            with patch.object(MERGE, 'CLIENT', client):
                result = MERGE.auto_merge_default(REPO, 101)
        self.assertEqual(result['status'], 'auto_merge_enabled')
        self.assertEqual((len(github.mutations), clock.sleeps), (1, [30]))

    def test_an_accepted_uuid_survives_a_quota_pause_without_another_put(self):
        clock = types.SimpleNamespace(now=1000.0)
        puts, reads = [], []
        endpoint = PREFIX + f'/pulls/102/merge-async/{UUID}'
        def run(command, **kwargs):
            if command[:2] == ['gh', 'api'] and command[command.index('--method') + 1] == 'PUT':
                puts.append(command)
                return subprocess.CompletedProcess(command, 0,
                    json.dumps({'status': 'pending', 'details': {'uuid': UUID}}), '')
            reads.append(command[-1])
            if '/pulls?state=open' in command[-1]:
                return http_response(200, [])  # nobody is on the open list: read each member once
            if command[-1] == endpoint:
                return (http_response(429, {'message': 'limited'}, {'Retry-After': '12'})
                        if reads.count(endpoint) == 1 else http_response(200, {'status': 'enqueued'}))
            return http_response(200, {'merged': True, 'state': 'closed', 'merge_commit_sha': sha(9999)})
        client = MERGE.GET.Client(run=run, clock=lambda: clock.now,
                                 sleep=lambda seconds: setattr(clock, 'now', clock.now + seconds))
        scope = {'stack': {'number': 900}, 'scope': [{'number': 101}, {'number': 102}]}
        with patch.object(MERGE, 'CLIENT', client), \
             patch.object(MERGE.subprocess, 'run', side_effect=run), redirect_stdout(io.StringIO()):
            result = MERGE.submit(REPO, 102, sha(102), scope)
        self.assertEqual((result['status'], result['uuid'], len(puts)), ('merged', UUID, 1))
        self.assertEqual(reads.count(endpoint), 2)
        self.assertEqual(clock.now, 1012)

    def test_only_a_typed_result_endpoint_404_or_410_means_the_request_is_gone(self):
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102), 'members': [101, 102], 'since': 1}
        endpoint = PREFIX + f'/pulls/102/merge-async/{UUID}'
        scope = {'scope': [{'number': 101}, {'number': 102}]}
        for status in (403, 404, 410, 500):
            with self.subTest(status=status), patch.object(MERGE, 'WAIT_SECONDS', 0), \
                 patch.object(MERGE, 'read', side_effect=MERGE.GET.ApiFailure(
                     endpoint, status, {}, 'hidden' if status in (404, 410) else 'Not Found')):
                result = MERGE.follow(REPO, endpoint, receipt, scope)
            self.assertEqual(result['status'], 'request_not_found' if status in (404, 410)
                             else 'observation_unavailable')
            self.assertEqual(result['uuid'], UUID)

    def test_a_typed_member_404_keeps_the_request_unsettled(self):
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102), 'members': [101, 102], 'since': 1}
        endpoint = PREFIX + f'/pulls/102/merge-async/{UUID}'
        scope = {'scope': [{'number': 101}, {'number': 102}]}
        with patch.object(MERGE, 'WAIT_SECONDS', 0), \
             patch.object(MERGE, 'read', return_value={'status': 'enqueued'}), \
             patch.object(MERGE, 'pull', side_effect=MERGE.GET.ApiFailure('member', 404, {}, 'gone')):
            result = MERGE.follow(REPO, endpoint, receipt, scope)
        self.assertEqual((result['status'], result['uuid']), ('observation_unavailable', UUID))

    def test_a_quota_wait_past_the_follow_budget_hands_off_the_same_uuid(self):
        for quota_path in ('endpoint', 'member'):
            with self.subTest(quota_path=quota_path):
                clock = types.SimpleNamespace(now=1000.0, sleeps=[])
                puts, reads = [], []
                endpoint = PREFIX + f'/pulls/102/merge-async/{UUID}'
                member = PREFIX + '/pulls/101'
                def run(command, **kwargs):
                    if command[:2] == ['gh', 'api'] and command[command.index('--method') + 1] == 'PUT':
                        puts.append(command)
                        return subprocess.CompletedProcess(command, 0,
                            json.dumps({'status': 'pending', 'details': {'uuid': UUID}}), '')
                    reads.append(command[-1])
                    if '/pulls?state=open' in command[-1]:
                        return http_response(200, [])  # nobody is on the open list: read each member once
                    limited = ((quota_path == 'endpoint' and command[-1] == endpoint) or
                               (quota_path == 'member' and command[-1] == member))
                    if limited:
                        return http_response(429, {'message': 'limited'}, {'Retry-After': '3600'})
                    if command[-1] == endpoint:
                        return http_response(200, {'status': 'pending'})
                    return http_response(200, {'merged': False, 'state': 'open'})
                def sleep(seconds):
                    clock.sleeps.append(seconds)
                    clock.now += seconds
                client = MERGE.GET.Client(run=run, clock=lambda: clock.now, sleep=sleep)
                scope = {'stack': {'number': 900}, 'scope': [{'number': 101}, {'number': 102}]}
                with patch.object(MERGE, 'CLIENT', client), \
                     patch.object(MERGE.subprocess, 'run', side_effect=run), \
                     patch.object(MERGE, 'hand_off',
                                  side_effect=lambda repo, outcome: outcome) as hand, \
                     redirect_stdout(io.StringIO()):
                    result = MERGE.submit(REPO, 102, sha(102), scope)
                self.assertEqual(result['status'], 'observation_unavailable')
                self.assertEqual(result['uuid'], UUID)
                self.assertEqual(len(puts), 1)
                self.assertEqual(reads.count(endpoint if quota_path == 'endpoint' else member), 1)
                self.assertEqual(clock.sleeps, [MERGE.WAIT_SECONDS])
                self.assertEqual(client.pauses, 1)
                self.assertIsNone(client.deadline)
                hand.assert_called_once()
                self.assertIn('cut short', result['error'])

    def test_quota_retry_times_survive_fresh_runs_for_result_and_member_reads(self):
        for quota_path in ('endpoint', 'member'):
            with self.subTest(quota_path=quota_path):
                clock = types.SimpleNamespace(now=1000.0, sleeps=[])
                resets = (4600.0, 8200.0)
                puts, reads, quotas, handed, clients = [], [], [], [], []
                endpoint = PREFIX + f'/pulls/102/merge-async/{UUID}'
                member = PREFIX + '/pulls/101'

                def run(command, **kwargs):
                    if command[:3] == ['gh', 'workflow', 'run']:
                        handed.append(json.loads(next(v.removeprefix('receipt=')
                            for v in command if v.startswith('receipt='))))
                        return subprocess.CompletedProcess(command, 0, '', '')
                    method = command[command.index('--method') + 1]
                    if method == 'PUT':
                        puts.append(command)
                        return subprocess.CompletedProcess(command, 0,
                            json.dumps({'status': 'pending', 'details': {'uuid': UUID}}), '')
                    self.assertEqual(method, 'GET')
                    if '/pulls?state=open' in command[-1]:
                        return http_response(200, [])  # nobody is on the open list
                    if quotas:
                        self.assertGreaterEqual(clock.now, quotas[-1]['retry_at'])
                    reads.append((clock.now, command[-1]))
                    limited = command[-1] == (endpoint if quota_path == 'endpoint' else member)
                    if limited:
                        for retry_at in resets:
                            if clock.now < retry_at:
                                quotas.append({'at': clock.now, 'retry_at': retry_at})
                                return http_response(403, {'message': 'limited'},
                                    {'X-RateLimit-Remaining': '0',
                                     'X-RateLimit-Reset': str(int(retry_at))})
                    if command[-1] == endpoint:
                        return http_response(200, {'status': 'enqueued'})
                    return http_response(200, {'merged': True, 'state': 'closed',
                                               'merge_commit_sha': sha(9999)})

                def sleep(seconds):
                    clock.sleeps.append(seconds)
                    clock.now += seconds

                def fresh_client():
                    client = MERGE.GET.Client(run=run, clock=lambda: clock.now, sleep=sleep)
                    clients.append(client)
                    return client

                scope = {'stack': {'number': 900}, 'scope': [{'number': 101}, {'number': 102}]}
                time = types.SimpleNamespace(time=lambda: clock.now,
                    monotonic=lambda: clock.now - 1000, sleep=sleep)
                with patch.object(MERGE, 'time', time), \
                     patch.object(MERGE.subprocess, 'run', side_effect=run), \
                     patch.object(MERGE, 'prepare') as admission, redirect_stdout(io.StringIO()):
                    with patch.object(MERGE, 'CLIENT', fresh_client()):
                        outcome = MERGE.submit(REPO, 102, sha(102), scope)
                    while outcome['status'] == 'resume_dispatched':
                        receipt = MERGE.parse_receipt(json.dumps(handed[-1]))
                        with patch.object(MERGE, 'CLIENT', fresh_client()):
                            outcome = MERGE.resume(REPO, receipt)
                admission.assert_not_called()
                self.assertEqual((outcome['status'], outcome['uuid'], len(puts)), ('merged', UUID, 1))
                self.assertEqual(quotas, [{'at': 1000, 'retry_at': 4600},
                                         {'at': 4600, 'retry_at': 8200}])
                self.assertTrue(all(row['uuid'] == UUID and row['head'] == sha(102) and
                                    row['members'] == [101, 102] and row['since'] == 1000 and
                                    row['retry_at'] in resets for row in handed))
                self.assertTrue(all(seconds <= MERGE.WAIT_SECONDS for seconds in clock.sleeps))
                self.assertTrue(all(client.deadline is None for client in clients))
                self.assertEqual((clock.now, reads[-1][0]), (8200, 8200))
                self.assertNotIn('retry_at', outcome)

    def test_retry_metadata_keeps_saved_receipts_and_rejects_untrusted_shapes(self):
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102), 'members': [101, 102], 'since': 1}
        self.assertEqual(MERGE.parse_receipt(json.dumps(receipt)), receipt)
        deferred = dict(receipt, retry_at=4600)
        self.assertEqual(MERGE.parse_receipt(json.dumps(deferred)), deferred)
        for retry_at in (True, None, '4600', -1, 0, float('inf'), float('-inf'), float('nan')):
            with self.subTest(retry_at=retry_at), self.assertRaises(ValueError):
                MERGE.parse_receipt(json.dumps(dict(receipt, retry_at=retry_at)))
        with self.assertRaises(ValueError):
            MERGE.parse_receipt(json.dumps(dict(deferred, extra=True)))

class WakingTheMainBuild(unittest.TestCase):
    """Every path that reaches a merged verdict wakes the main build once.

    A bot merge emits no push event, so `Main minimal build` never starts by
    itself. Three paths reach a merged verdict and each one must dispatch; a
    dry run and an unsettled receipt must not.
    """

    def setUp(self):
        self.addCleanup(MERGE._WAKE.update, {'repo': None, 'enabled': False})
        self.dispatched = []
        patcher = patch.object(
            MERGE, 'wake_main_build',
            side_effect=lambda repo: self.dispatched.append(repo) or {'dispatched': True})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.cleaned = []
        cleanup = patch.object(
            MERGE, 'delete_merged_heads',
            side_effect=lambda repo, numbers: self.cleaned.append(list(numbers)) or [])
        cleanup.start()
        self.addCleanup(cleanup.stop)
        self.closed = []
        closing = patch.object(
            MERGE, 'close_linked_issues',
            side_effect=lambda repo, numbers: self.closed.append(list(numbers)) or [])
        closing.start()
        self.addCleanup(closing.stop)

    def test_the_auto_merge_arming_readback_wakes_the_main_build(self):
        """`gh pr merge --auto` followed by a merged readback returns at 468."""
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': ''}
        automatic = {'status': 'merged', 'pr': 102, 'merge_commit_sha': sha(102)}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'auto_merge_default', return_value=automatic), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = MERGE.main()
        self.assertEqual(code, 0)
        self.assertEqual(self.dispatched, [REPO])
        self.assertEqual(self.cleaned, [[102]])
        self.assertEqual(self.closed, [[102]])

    def test_a_resumed_receipt_that_reports_a_merge_wakes_the_main_build(self):
        """follow() reaches merged without ever calling submit(), then returns."""
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102),
                   'members': [101, 102], 'since': 1}
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': '',
                       'DISPATCH_RECEIPT': json.dumps(receipt)}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'resume', return_value={'status': 'merged'}), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = MERGE.main()
        self.assertEqual(code, 0)
        self.assertEqual(self.dispatched, [REPO])

    def test_an_unsettled_receipt_does_not_wake_the_build(self):
        """Nothing merged yet, so no build request and a visible red exit."""
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102),
                   'members': [101, 102], 'since': 1}
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': '',
                       'DISPATCH_RECEIPT': json.dumps(receipt)}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'resume', return_value={'status': 'still_pending'}), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = MERGE.main()
        self.assertNotEqual(code, 0)
        self.assertEqual(self.dispatched, [])
        self.assertEqual(self.cleaned, [])
        self.assertEqual(self.closed, [])

    def test_a_dry_run_reports_the_merge_without_waking_the_build(self):
        """--dry-run reads admission; it must never dispatch anything."""
        receipt = {'uuid': UUID, 'pr': 102, 'head': sha(102),
                   'members': [101, 102], 'since': 1}
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': '',
                       'DISPATCH_RECEIPT': json.dumps(receipt)}
        with patch.dict(os.environ, environment), \
             patch.object(sys, 'argv', ['auto-merge', '--dry-run']), \
             patch.object(MERGE, 'resume', return_value={'status': 'merged'}), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            MERGE.main()
        self.assertEqual(self.dispatched, [])
        self.assertEqual(self.closed, [])

    def test_a_hold_on_an_already_merged_pull_request_wakes_the_build(self):
        """A reservation let GitHub merge first, so the run holds on a closed PR.

        The merge is real even though this run never saw a merged verdict, and
        a bot merge emits no push event, so the commit would reach main with no
        build. Reading the pull request back must find the merge and dispatch.
        """
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': ''}
        merged = {'number': 102, 'state': 'closed', 'merged': True,
                  'merge_commit_sha': sha(102)}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'auto_merge_default', return_value=None), \
             patch.object(MERGE, 'pull', return_value=merged), \
             patch.object(MERGE, 'prepare',
                          side_effect=MERGE.Hold('#102 is not open and ready')), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            MERGE.main()
        self.assertEqual(self.dispatched, [REPO])
        self.assertEqual(self.cleaned, [[102]])
        self.assertEqual(self.closed, [[102]])

    def test_a_hold_on_an_unmerged_pull_request_does_not_wake_the_build(self):
        """Holding for any other reason is still not a merge."""
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': ''}
        still_open = {'number': 102, 'state': 'open', 'merged': False}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['auto-merge']), \
             patch.object(MERGE, 'auto_merge_default', return_value=None), \
             patch.object(MERGE, 'pull', return_value=still_open), \
             patch.object(MERGE, 'prepare',
                          side_effect=MERGE.Hold('#102 has 1/2 current-head account approvals')), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            MERGE.main()
        self.assertEqual(self.dispatched, [])
        self.assertEqual(self.cleaned, [])
        self.assertEqual(self.closed, [])

    def test_a_dry_run_does_not_wake_for_an_already_merged_pull_request(self):
        """--dry-run must not dispatch even when the merge already happened."""
        environment = {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                       'DISPATCH_PR': '102', 'GITHUB_STEP_SUMMARY': ''}
        merged = {'number': 102, 'state': 'closed', 'merged': True,
                  'merge_commit_sha': sha(102)}
        with patch.dict(os.environ, environment), \
             patch.object(sys, 'argv', ['auto-merge', '--dry-run']), \
             patch.object(MERGE, 'pull', return_value=merged), \
             patch.object(MERGE, 'prepare',
                          side_effect=MERGE.Hold('#102 is not open and ready')), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            MERGE.main()
        self.assertEqual(self.dispatched, [])
        self.assertEqual(self.closed, [])


class DeletingMergedHeadBranches(unittest.TestCase):
    """A merge made with the Actions token leaves its branch behind (#51366)."""

    def merged(self, **changes):
        row = {'number': 102, 'state': 'closed', 'merged': True,
               'head': {'ref': 'feat/x#1', 'sha': sha(102), 'repo': HOME}}
        row['head'].update(changes.pop('head', {}))
        return dict(row, **changes)

    def delete(self, row, dependants=(), returncode=0, stderr=''):
        result = subprocess.CompletedProcess([], returncode, '', stderr)
        with patch.object(MERGE, 'pull', return_value=row), \
             patch.object(MERGE, 'read', return_value=list(dependants)) as read, \
             patch.object(MERGE.subprocess, 'run', return_value=result) as run:
            return MERGE.delete_merged_head(REPO, 102), read, run

    def test_the_push_is_leased_on_the_merged_head(self):
        record, read, run = self.delete(self.merged())
        self.assertEqual(record, {'pr': 102, 'branch': 'feat/x#1', 'deleted': True})
        read.assert_called_once_with(
            PREFIX + '/pulls?state=open&base=feat%2Fx%231&per_page=1')
        command = run.call_args.args[0]
        self.assertEqual(command[-3:], [
            f'--force-with-lease=refs/heads/feat/x#1:{sha(102)}',
            f'https://github.com/{REPO}.git', ':refs/heads/feat/x#1'])

    def test_branches_something_still_needs_are_kept_without_a_push(self):
        cases = {
            'not merged': self.merged(merged=False, state='open'),
            'head is in another repository': self.merged(head={'repo': {'full_name': 'fork/repo'}}),
            'head is in another repository ': self.merged(head={'repo': None}),
            'protected branch name': self.merged(head={'ref': 'release/v1.2.3'}),
            'protected branch name ': self.merged(head={'ref': 'main'}),
        }
        for reason, row in cases.items():
            with self.subTest(reason=reason):
                record, _, run = self.delete(row)
                self.assertEqual((record['deleted'], record['reason']), (False, reason.strip()))
                run.assert_not_called()
        record, _, run = self.delete(self.merged(), dependants=[{'number': 103}])
        self.assertEqual(record['reason'], 'an open pull request uses it as base')
        run.assert_not_called()

    def test_a_refused_push_and_a_failed_read_are_records_not_errors(self):
        record, _, _ = self.delete(self.merged(), returncode=1, stderr='! [rejected] (stale info)')
        self.assertEqual((record['deleted'], record['reason']),
                         (False, '! [rejected] (stale info)'))
        with patch.object(MERGE, 'pull', side_effect=[OSError('gh missing'), self.merged()]), \
             patch.object(MERGE, 'read', return_value=[]), \
             patch.object(MERGE.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 0, '', '')):
            records = MERGE.delete_merged_heads(REPO, [101, 102])
        self.assertEqual([row['deleted'] for row in records], [False, True])
        self.assertIn('gh missing', records[0]['reason'])

    def test_a_merged_payload_names_every_member_it_covers(self):
        scope = {'scope': [{'number': 101}, {'number': 102}]}
        self.assertEqual(MERGE.merged_numbers({'pr': 102, 'scope': scope, 'result': {}}), [101, 102])
        self.assertEqual(MERGE.merged_numbers(
            {'pr': 102, 'result': {'status': 'merged', 'members': [101, 102]}}), [101, 102])
        self.assertEqual(MERGE.merged_numbers({'status': 'merged', 'pr': 102}), [102])


class ClosingLinkedIssues(unittest.TestCase):
    """A merge made with the Actions token leaves its linked issues open (#51498).

    Which issue closes is decided in linked-issues.py and covered by
    test_linked_issues.py. These cases cover what the worker adds: the gh
    transport, and a failure that stays a record.
    """

    def test_a_document_goes_out_with_every_variable_as_a_raw_field(self):
        answer = subprocess.CompletedProcess([], 0, json.dumps({'data': {'ok': 1}}), '')
        with patch.object(MERGE.subprocess, 'run', return_value=answer) as run:
            data = MERGE.graphql('query { ok }', owner='o', name='r')
        self.assertEqual(data, {'ok': 1})
        self.assertEqual(run.call_args.args[0], [
            'gh', 'api', 'graphql', '-f', 'query=query { ok }', '-f', 'owner=o', '-f', 'name=r'])
        self.assertEqual(run.call_args.kwargs['timeout'], MERGE.GRAPHQL_TIMEOUT_SECONDS)

    def test_a_refused_unstartable_or_slow_call_is_a_value_error(self):
        refused = subprocess.CompletedProcess([], 1, '{"errors": []}', 'gh: not accessible')
        failures = {
            'refused': {'return_value': refused},
            'unstartable': {'side_effect': OSError('gh missing')},
            'slow': {'side_effect': subprocess.TimeoutExpired('gh', 1)},
        }
        for name, behaviour in failures.items():
            with self.subTest(name), patch.object(MERGE.subprocess, 'run', **behaviour), \
                 self.assertRaises(ValueError):
                MERGE.graphql('query { ok }')

    def test_a_merged_pull_request_closes_its_open_issue_through_gh(self):
        linked = {'totalCount': 1, 'nodes': [
            {'id': 'I_7', 'url': f'https://github.com/{REPO}/issues/7', 'state': 'OPEN'}]}
        read = {'repository': {'defaultBranchRef': {'name': 'main'}, 'p102': {
            'merged': True, 'mergedAt': '2026-11-12T02:09:02Z', 'baseRefName': 'main',
            'mergeCommit': {'oid': sha(102)}, 'closingIssuesReferences': linked}}}
        never_reopened = {'i0': {'state': 'OPEN', 'timelineItems': {'nodes': []}}}
        close = {'closeIssue': {'issue': {'state': 'CLOSED'}}}
        commands = []

        def gh(command, **_):
            commands.append(command)
            data = close if 'id=I_7' in command else never_reopened if 'i0=I_7' in command else read
            return subprocess.CompletedProcess(command, 0, json.dumps({'data': data}), '')

        with patch.object(MERGE.subprocess, 'run', side_effect=gh):
            records = MERGE.close_linked_issues(REPO, [102])
        self.assertEqual(records, [
            {'pr': 102, 'issue': f'https://github.com/{REPO}/issues/7', 'closed': True}])
        self.assertEqual([command[-4:] for command in commands], [
            ['-f', 'owner=owner', '-f', 'name=repo'],
            ['-f', f'query={MERGE.ISSUES.check_query([], 1)}', '-f', 'i0=I_7'],
            ['-f', f'query={MERGE.ISSUES.CLOSE_ISSUE}', '-f', 'id=I_7']])

    def test_a_read_that_fails_or_answers_nothing_is_one_record_that_names_the_pull_requests(self):
        failures = {'refused': {'side_effect': ValueError('rate limited')},
                    'empty': {'return_value': {'repository': None}},
                    'without the default branch': {'return_value': {'repository': {}}}}
        for name, behaviour in failures.items():
            with self.subTest(name), patch.object(MERGE, 'graphql', **behaviour):
                records = MERGE.close_linked_issues(REPO, [101, 102])
                self.assertEqual([(row['prs'], row['closed']) for row in records],
                                 [([101, 102], False)])
        with patch.object(MERGE, 'graphql', side_effect=ValueError('rate limited')):
            self.assertIn('rate limited', MERGE.close_linked_issues(REPO, [101])[0]['reason'])


class SweepBudgetCleanup(unittest.TestCase):
    '''The sweep budget protects the outcome emit and the hand-off (#51479 family 2).'''

    def test_an_exhausted_budget_skips_the_poll_and_still_hands_off(self):
        receipt = {'uuid': 'u1', 'pr': 101, 'head': sha(101), 'members': [101],
                   'since': 1.0, 'status': 'submitted'}
        reads = []
        done = subprocess.CompletedProcess([], 0, '', '')
        with patch.object(MERGE, 'read', side_effect=lambda path: reads.append(path) or {}), \
             patch.object(MERGE.time, 'monotonic', return_value=10 ** 9), \
             patch.object(MERGE.subprocess, 'run', return_value=done), \
             patch.object(MERGE, '_FOLLOW_DEADLINE', 10 ** 9 - 1):
            result = MERGE.resume('owner/repo', dict(receipt), dispatch=True)
        self.assertEqual(reads, [])
        self.assertEqual(result['status'], 'resume_dispatched')

    def test_without_a_budget_the_poll_reads_the_request_and_the_members(self):
        receipt = {'uuid': 'u1', 'pr': 101, 'head': sha(101), 'members': [101],
                   'since': 1.0, 'status': 'submitted'}
        reads = []
        def fake_read(path):
            reads.append(path)
            if path.endswith('/merge-async/u1'):
                return {'status': 'merged'}
            return {'merged': True, 'state': 'closed', 'merge_commit_sha': 'c1'}
        with patch.object(MERGE, 'read', side_effect=fake_read), \
             patch.object(MERGE, 'open_pulls', return_value=[]), \
             patch.object(MERGE.subprocess, 'run') as run:
            result = MERGE.resume('owner/repo', dict(receipt), dispatch=False)
        self.assertEqual(reads, ['repos/owner/repo/pulls/101/merge-async/u1',
                                 'repos/owner/repo/pulls/101'])
        self.assertEqual(result['status'], 'merged')
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
