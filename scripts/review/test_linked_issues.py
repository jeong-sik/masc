#!/usr/bin/env python3
"""linked-issues.py against a recorded `graphql`: which issues a merge closes.

Offline; no network, no real issue.

Run: python3 -I scripts/review/test_linked_issues.py
"""
import importlib.util
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('linked_issues', HERE / 'linked-issues.py')
assert SPEC is not None and SPEC.loader is not None
ISSUES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ISSUES)
REPO = 'owner/repo'


def sha(number):
    return f'{number:040x}'


def issue(number, state='OPEN'):
    return {'id': f'I_{number}', 'url': f'https://github.com/{REPO}/issues/{number}',
            'state': state}


def pull(number, *issues, merged=True, base='main', total=None):
    return {'merged': merged, 'baseRefName': base, 'mergeCommit': {'oid': sha(number)},
            'closingIssuesReferences': {
                'totalCount': len(issues) if total is None else total, 'nodes': list(issues)}}


class FakeGitHub:
    """Answer the three documents by the variables they carry; keep every call.

    `ahead` gives, per pull request, how many commits its merge commit is
    ahead of the default branch; None stands for a comparison GitHub could
    not make. `answers` gives the state a close reports, or an error to raise.
    """

    def __init__(self, *pulls, ahead=None, answers=None):
        self.pulls = pulls
        self.ahead = ahead or {}
        self.answers = answers or {}
        self.reads, self.comparisons, self.closes = [], [], []

    def __call__(self, document, **variables):
        if 'id' in variables:
            self.closes.append(variables['id'])
            answer = self.answers.get(variables['id'], 'CLOSED')
            if isinstance(answer, Exception):
                raise answer
            return {'closeIssue': {'issue': {'state': answer}}}
        if 'branch' in variables:
            self.comparisons.append(variables)
            return {'repository': {'ref': {
                f'p{number}': None if count is None else {'aheadBy': count}
                for number, count in self.ahead.items()}}}
        self.reads.append(variables)
        return {'repository': dict(
            {f'p{number}': row for number, row in self.pulls}, defaultBranchRef={'name': 'main'})}


def close(*pulls, **behaviour):
    github = FakeGitHub(*pulls, **behaviour)
    records = ISSUES.close_linked_issues(REPO, [number for number, _ in pulls], github)
    return records, github


def url(number):
    return issue(number)['url']


class ClosingLinkedIssues(unittest.TestCase):
    def test_a_merge_into_the_default_branch_closes_only_its_open_issues(self):
        records, github = close((101, pull(101, issue(7), issue(8, 'CLOSED'))))
        self.assertEqual(records, [{'pr': 101, 'issue': url(7), 'closed': True}])
        self.assertEqual(github.closes, ['I_7'])
        self.assertEqual(github.reads, [{'owner': 'owner', 'name': 'repo'}])
        self.assertEqual(github.comparisons, [])

    def test_one_read_covers_every_member_of_a_scope(self):
        records, github = close((101, pull(101)), (102, pull(102)), (103, pull(103)))
        self.assertEqual(records, [])
        self.assertEqual((len(github.reads), github.comparisons, github.closes), (1, [], []))

    def test_a_stack_layer_closes_its_issue_only_when_its_merge_commit_is_on_the_default_branch(self):
        records, github = close(
            (102, pull(102, issue(7), base='feat/parent')),
            (103, pull(103, issue(8), base='feat/layer-2')),
            (104, pull(104, issue(9), base='feat/layer-3')),
            ahead={102: 0, 103: 3, 104: None})
        self.assertEqual([(row['pr'], row['issue'], row['closed']) for row in records], [
            (102, url(7), True), (103, url(8), False), (104, url(9), False)])
        self.assertEqual(github.closes, ['I_7'])
        self.assertEqual(github.comparisons, [{
            'owner': 'owner', 'name': 'repo', 'branch': 'refs/heads/main',
            'c102': sha(102), 'c103': sha(103), 'c104': sha(104)}])

    def test_a_layer_with_nothing_open_asks_for_no_comparison(self):
        records, github = close(
            (101, pull(101, issue(7))),
            (102, pull(102, issue(8, 'CLOSED'), base='feat/parent')))
        self.assertEqual(records, [{'pr': 101, 'issue': url(7), 'closed': True}])
        self.assertEqual(github.comparisons, [])

    def test_an_unmerged_pull_request_closes_nothing(self):
        records, github = close(
            (101, pull(101, issue(7), merged=False)),
            (102, pull(102, issue(8), merged=False, base='feat/parent')))
        self.assertEqual([(row['pr'], row['closed']) for row in records], [(101, False), (102, False)])
        self.assertEqual((github.closes, github.comparisons), ([], []))

    def test_a_refused_close_is_a_record_and_the_next_issue_still_closes(self):
        records, github = close(
            (101, pull(101, issue(7), issue(8), issue(9))),
            answers={'I_7': ValueError('Resource not accessible by integration'), 'I_8': 'OPEN'})
        self.assertEqual([(row['issue'], row['closed']) for row in records], [
            (url(7), False), (url(8), False), (url(9), True)])
        self.assertIn('Resource not accessible', records[0]['reason'])
        self.assertEqual(github.closes, ['I_7', 'I_8', 'I_9'])

    def test_an_issue_two_layers_link_is_closed_once_by_the_first_that_landed(self):
        records, github = close(
            (101, pull(101, issue(7), merged=False)),
            (102, pull(102, issue(7))),
            (103, pull(103, issue(7))))
        self.assertEqual([(row['pr'], row['closed']) for row in records], [(101, False), (102, True)])
        self.assertEqual(github.closes, ['I_7'])

    def test_a_list_longer_than_one_page_is_reported_and_the_page_still_closes(self):
        records, github = close((101, pull(101, issue(7), total=ISSUES.LINKED_ISSUE_PAGE + 1)))
        self.assertEqual([(row['pr'], row.get('issue'), row['closed']) for row in records], [
            (101, None, False), (101, url(7), True)])
        self.assertEqual(github.closes, ['I_7'])

    def test_the_documents_name_only_pull_request_numbers(self):
        """Everything else travels as a variable, so no value is spliced into a document."""
        with self.assertRaises(ValueError):
            ISSUES.read_query(['101) { id } evil: pullRequest(number: 1'])
        with self.assertRaises(ValueError):
            ISSUES.landed_query(['101'])


if __name__ == '__main__':
    unittest.main()
