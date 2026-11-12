#!/usr/bin/env python3
"""linked-issues.py against a recorded `graphql`: which issues a merge closes.

Offline; no network, no real issue.

Run: python3 -I scripts/review/test_linked_issues.py
"""
import importlib.util
import pathlib
import re
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('linked_issues', HERE / 'linked-issues.py')
assert SPEC is not None and SPEC.loader is not None
ISSUES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ISSUES)
REPO = 'owner/repo'
BEFORE_THE_MERGE = '2026-11-12T02:09:01Z'
THE_MERGE = '2026-11-12T02:09:02Z'
AFTER_THE_MERGE = '2026-11-12T02:09:03Z'
A_LATER_MERGE = '2026-11-12T02:09:04Z'


def sha(number):
    return f'{number:040x}'


def issue(number, state='OPEN'):
    return {'id': f'I_{number}', 'url': f'https://github.com/{REPO}/issues/{number}',
            'state': state}


def pull(number, *issues, merged=True, merged_at=THE_MERGE, base='main', total=None,
         has_commit=True):
    return {'merged': merged, 'mergedAt': merged_at if merged else None, 'baseRefName': base,
            'mergeCommit': {'oid': sha(number)} if has_commit else None,
            'closingIssuesReferences': {
                'totalCount': len(issues) if total is None else total, 'nodes': list(issues)}}


def only_named(value, names):
    if isinstance(value, dict):
        return {key: only_named(inner, names) for key, inner in value.items() if key in names}
    if isinstance(value, list):
        return [only_named(inner, names) for inner in value]
    return value


class FakeGitHub:
    """Answer the three documents by the variables they carry; keep every call.

    Like GitHub, it answers only the fields a document names, so a document
    that stops asking for a field the code reads fails here too.

    `ahead` gives, per layer, how many commits its merge commit is ahead of
    the default branch; None stands for a comparison GitHub could not make.
    `closed_at` gives the times an issue was closed, oldest first. `answers`
    gives what a close reports: a state, an error to raise, or a whole answer.
    `check` replaces the answer to the check document with an error or an
    answer.
    """

    def __init__(self, *pulls, ahead=None, closed_at=None, answers=None, check=None):
        self.pulls = pulls
        self.ahead = ahead or {}
        self.closed_at = closed_at or {}
        self.answers = answers or {}
        self.check = check
        self.reads, self.checks, self.closes, self.closed_as = [], [], [], {}

    def __call__(self, document, **variables):
        names = set(re.findall(r'[A-Za-z_][A-Za-z_0-9]*', document))
        return only_named(self.answer(document, variables), names)

    def answer(self, document, variables):
        if 'id' in variables:
            self.closes.append(variables['id'])
            answer = self.answers.get(variables['id'], 'CLOSED')
            if isinstance(answer, Exception):
                raise answer
            if isinstance(answer, dict):
                return answer
            if answer == 'CLOSED':
                reason = re.search(r'stateReason: ([A-Z_]+)', document)
                self.closed_as[variables['id']] = reason.group(1) if reason else None
            return {'closeIssue': {'issue': {'state': answer}}}
        if 'i0' in variables:
            self.checks.append(variables)
            if isinstance(self.check, Exception):
                raise self.check
            if self.check is not None:
                return self.check
            answer = {}
            end = re.search(r'itemTypes: \[CLOSED_EVENT\], (first|last): 1\)', document)
            for key, value in variables.items():
                if key[0] == 'i':
                    times = self.closed_at.get(value, [])
                    asked = times[-1:] if end and end.group(1) == 'last' else times[:1]
                    answer[key] = {'timelineItems': {
                        'nodes': [{'createdAt': when} for when in asked]}}
            if 'branch' in variables:
                answer['repository'] = {'ref': {
                    f'p{key[1:]}': None if count is None else {'aheadBy': count}
                    for key in variables if key[0] == 'c'
                    for count in [self.ahead[int(key[1:])]]}}
            return answer
        self.reads.append(variables)
        return {'repository': dict(
            {f'p{number}': row for number, row in self.pulls}, defaultBranchRef={'name': 'main'})}


def close(*pulls, **behaviour):
    github = FakeGitHub(*pulls, **behaviour)
    records = ISSUES.close_linked_issues(REPO, [number for number, _ in pulls], github)
    return records, github


def url(number):
    return issue(number)['url']


def decisions(records):
    return [(row['pr'], row.get('issue'), row['closed']) for row in records]


class ClosingLinkedIssues(unittest.TestCase):
    def test_a_merge_into_the_default_branch_closes_only_its_open_issues(self):
        records, github = close((101, pull(101, issue(7), issue(8, 'CLOSED'))))
        self.assertEqual(records, [{'pr': 101, 'issue': url(7), 'closed': True}])
        self.assertEqual(github.closed_as, {'I_7': 'COMPLETED'})
        self.assertEqual(github.reads, [{'owner': 'owner', 'name': 'repo'}])
        self.assertEqual(github.checks, [{'i0': 'I_7'}])

    def test_one_read_covers_every_member_of_a_scope(self):
        records, github = close((101, pull(101)), (102, pull(102)), (103, pull(103)))
        self.assertEqual(records, [])
        self.assertEqual((len(github.reads), github.checks, github.closes), (1, [], []))

    def test_a_stack_layer_closes_its_issue_only_when_its_merge_commit_is_on_the_default_branch(self):
        records, github = close(
            (102, pull(102, issue(7), base='feat/parent')),
            (103, pull(103, issue(8), base='feat/layer-2')),
            (104, pull(104, issue(9), base='feat/layer-3')),
            ahead={102: 0, 103: 3, 104: None})
        self.assertEqual(decisions(records), [
            (102, url(7), True), (103, url(8), False), (104, url(9), False)])
        self.assertEqual(github.closes, ['I_7'])
        self.assertEqual(github.checks, [{
            'owner': 'owner', 'name': 'repo', 'branch': 'refs/heads/main',
            'c102': sha(102), 'c103': sha(103), 'c104': sha(104),
            'i0': 'I_7', 'i1': 'I_8', 'i2': 'I_9'}])

    def test_a_layer_with_nothing_open_is_not_compared(self):
        records, github = close(
            (101, pull(101, issue(7))),
            (102, pull(102, issue(8, 'CLOSED'), base='feat/parent')))
        self.assertEqual(records, [{'pr': 101, 'issue': url(7), 'closed': True}])
        self.assertEqual(github.checks, [{'i0': 'I_7'}])

    def test_an_unmerged_pull_request_closes_nothing(self):
        records, github = close(
            (101, pull(101, issue(7), merged=False)),
            (102, pull(102, issue(8), merged=False, base='feat/parent')))
        self.assertEqual(decisions(records), [(101, url(7), False), (102, url(8), False)])
        self.assertEqual((github.closes, github.checks), ([], []))

    def test_a_layer_without_a_merge_commit_closes_nothing_and_the_rest_still_close(self):
        records, github = close(
            (101, pull(101, issue(7), base='feat/parent', has_commit=False)),
            (102, pull(102, issue(8))))
        self.assertEqual(decisions(records), [(101, url(7), False), (102, url(8), True)])
        self.assertEqual(github.closes, ['I_8'])

    def test_an_issue_closed_after_the_merge_and_open_again_stays_open(self):
        """A merge closes its issue once; a person who reopens it is not overruled."""
        records, github = close(
            (101, pull(101, issue(7), issue(8), issue(9), issue(10), issue(11))),
            closed_at={'I_7': [AFTER_THE_MERGE], 'I_8': [THE_MERGE], 'I_9': [BEFORE_THE_MERGE],
                       'I_11': [BEFORE_THE_MERGE, AFTER_THE_MERGE]})
        self.assertEqual(decisions(records), [
            (101, url(7), False), (101, url(8), False), (101, url(9), True), (101, url(10), True),
            (101, url(11), False)])
        self.assertEqual(github.closes, ['I_9', 'I_10'])

    def test_a_later_merge_closes_an_issue_reopened_after_an_earlier_merge(self):
        records, github = close(
            (101, pull(101, issue(7), merged_at=THE_MERGE)),
            (102, pull(102, issue(7), merged_at=A_LATER_MERGE)),
            closed_at={'I_7': [AFTER_THE_MERGE]})
        self.assertEqual(decisions(records), [(101, url(7), False), (102, url(7), True)])
        self.assertEqual(github.closes, ['I_7'])

    def test_a_close_that_fails_is_a_record_and_the_next_issue_still_closes(self):
        records, github = close(
            (101, pull(101, issue(7), issue(8), issue(9), issue(10))),
            answers={'I_7': ValueError('Resource not accessible by integration'), 'I_8': 'OPEN',
                     'I_9': {'closeIssue': None}})
        self.assertEqual(decisions(records), [
            (101, url(7), False), (101, url(8), False), (101, url(9), False), (101, url(10), True)])
        self.assertIn('Resource not accessible', records[0]['reason'])
        self.assertEqual(github.closes, ['I_7', 'I_8', 'I_9', 'I_10'])

    def test_an_issue_two_pull_requests_link_gets_one_close_and_a_record_each(self):
        records, github = close(
            (101, pull(101, issue(7), merged=False)),
            (102, pull(102, issue(7))),
            (103, pull(103, issue(7))))
        self.assertEqual(decisions(records), [
            (101, url(7), False), (102, url(7), True), (103, url(7), True)])
        self.assertEqual(github.closes, ['I_7'])
        records, github = close(
            (102, pull(102, issue(7))), (103, pull(103, issue(7))),
            answers={'I_7': ValueError('refused')})
        self.assertEqual(decisions(records), [(102, url(7), False), (103, url(7), False)])
        self.assertEqual(github.closes, ['I_7'])

    def test_a_check_that_fails_refuses_every_open_issue_and_keeps_the_earlier_records(self):
        for check in (ValueError('API rate limit exceeded'), {'i0': None, 'i1': None}):
            with self.subTest(check=check):
                records, github = close(
                    (101, pull(101, issue(6), merged=False)),
                    (102, pull(102, issue(7))),
                    (103, pull(103, issue(8))),
                    check=check)
                self.assertEqual(decisions(records), [
                    (101, url(6), False), (102, url(7), False), (103, url(8), False)])
                self.assertIn('could not check', records[1]['reason'])
                self.assertEqual(github.closes, [])

    def test_a_list_longer_than_one_page_is_reported_and_the_page_still_closes(self):
        records, github = close((101, pull(101, issue(7), total=ISSUES.LINKED_ISSUE_PAGE + 1)))
        self.assertEqual(decisions(records), [(101, None, False), (101, url(7), True)])
        self.assertEqual(github.closes, ['I_7'])

    def test_a_linked_issue_the_token_cannot_read_is_reported_and_the_rest_close(self):
        records, github = close((101, pull(101, None, issue(7))))
        self.assertEqual(decisions(records), [(101, None, False), (101, url(7), True)])
        self.assertEqual(github.closes, ['I_7'])

    def test_the_documents_name_only_pull_request_numbers(self):
        """Everything else travels as a variable, so no value is spliced into a document."""
        with self.assertRaises(ValueError):
            ISSUES.read_query(['101) { id } evil: pullRequest(number: 1'])
        with self.assertRaises(ValueError):
            ISSUES.check_query(['101'], 1)


if __name__ == '__main__':
    unittest.main()
