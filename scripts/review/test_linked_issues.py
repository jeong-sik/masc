#!/usr/bin/env python3
"""linked-issues.py against a small model of GitHub: which issues a merge closes.

Offline; no network, no real issue.

Run: python3 -I scripts/review/test_linked_issues.py
"""
import copy
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
# A name, an argument list as one piece, a brace, an alias colon or a fragment spread.
TOKEN = re.compile(r'\.\.\.|[A-Za-z_]\w*|\([^()]*\)|[{}:]')


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


def selection_set(tokens, position, on=None):
    """The selections of the set that opens at `position`, and where the set ends.

    A selection is (key, field, arguments, its own selections or None, the
    type its fragment is for or None).
    """
    assert tokens[position] == '{', tokens[position:position + 3]
    position += 1
    selections = []
    while tokens[position] != '}':
        if tokens[position] == '...':
            assert tokens[position + 1] == 'on', tokens[position:position + 3]
            inner, position = selection_set(tokens, position + 3, on=tokens[position + 2])
            selections += inner
            continue
        key = field = tokens[position]
        position += 1
        if tokens[position] == ':':
            field = tokens[position + 1]
            position += 2
        arguments = ''
        if tokens[position].startswith('('):
            arguments = tokens[position]
            position += 1
        inner = None
        if tokens[position] == '{':
            inner, position = selection_set(tokens, position)
        selections.append((key, field, arguments, inner, on))
    return selections, position + 1


def parse(document):
    """The operation word of a document and its selections."""
    tokens = TOKEN.findall(document)
    selections, end = selection_set(tokens, 2 if tokens[1].startswith('(') else 1)
    assert end == len(tokens), document
    return tokens[0], selections


def argument(arguments, name, variables):
    """What a field is given for `name`: a variable's value, or the literal as written."""
    given = re.search(rf'\b{name}: (\$\w+|\[[^\]]*\]|\w+)', arguments)
    assert given, f'{name} is not given in {arguments!r}'
    value = given.group(1)
    return variables[value[1:]] if value.startswith('$') else value


def resolve(model, selections, variables):
    """Answer the selections from the model the way GitHub answers a document.

    Only what is asked comes back, under the key it is asked by. Asking for a
    field the model does not have at that place fails the test, and so does
    asking for an object without selections of its own. These are assertions,
    which the code under test does not catch.
    """
    if isinstance(model, list):
        return [resolve(entry, selections, variables) for entry in model]
    if model is None:
        return None
    assert isinstance(model, dict), f'{model!r} takes no selections'
    answer = {}
    for key, field, arguments, inner, on in selections:
        if on is not None and model['__typename'] != on:
            continue
        assert field in model, f'{field} is not a field of {sorted(model)}'
        value = model[field]
        if callable(value):
            value = value(arguments, variables)
        if inner is None:
            assert not isinstance(value, (dict, list)), f'{field} needs selections'
            answer[key] = value
        else:
            answer[key] = resolve(value, inner, variables)
    return answer


class FakeGitHub:
    """Answer the three documents from a small model of a repository; keep every call.

    Each document is parsed and answered by `resolve`, so a document that
    drops or misplaces a field the code reads fails here as it does at GitHub.

    `ahead`: per layer, how many commits its merge commit is ahead of main.
    `reopened_at`: the times an issue was reopened, oldest first.
    `now`: the state of an issue at the check, where it differs from the read.
    `answers`: what a close reports: a state, an error to raise, or None for
    an answer without the issue.
    `read`, `check`: an error or a whole answer in place of the model's.
    """

    def __init__(self, *pulls, ahead=None, reopened_at=None, now=None, answers=None,
                 read=None, check=None):
        self.pulls = dict(pulls)
        self.ahead = ahead or {}
        self.reopened_at = reopened_at or {}
        self.now = now or {}
        self.answers = answers or {}
        self.read, self.check = read, check
        self.reads, self.checks, self.closes, self.closed_as = [], [], [], {}

    def __call__(self, document, **variables):
        operation, selections = parse(document)
        if operation == 'mutation':
            return resolve({'closeIssue': self.close_issue}, selections, variables)
        asks_nodes = any(field == 'node' for _, field, _, _, _ in selections)
        (self.checks if asks_nodes else self.reads).append(variables)
        replaced = self.check if asks_nodes else self.read
        if isinstance(replaced, Exception):
            raise replaced
        if replaced is not None:
            return replaced
        return resolve({'repository': self.repository, 'node': self.node}, selections, variables)

    def repository(self, arguments, variables):
        assert (argument(arguments, 'owner', variables),
                argument(arguments, 'name', variables)) == tuple(REPO.split('/')), arguments
        return {
            'defaultBranchRef': {'name': 'main'},
            'pullRequest': lambda arguments, variables: self.pulls[
                int(argument(arguments, 'number', variables))],
            'ref': lambda arguments, variables: (
                {'compare': self.compare}
                if argument(arguments, 'qualifiedName', variables) == 'refs/heads/main' else None)}

    def compare(self, arguments, variables):
        return {'aheadBy': self.ahead[int(argument(arguments, 'headRef', variables), 16)]}

    def node(self, arguments, variables):
        issue_id = argument(arguments, 'id', variables)
        return {'__typename': 'Issue', 'state': self.now.get(issue_id, 'OPEN'),
                'timelineItems': lambda arguments, variables: {
                    'nodes': self.events(issue_id, arguments, variables)}}

    def events(self, issue_id, arguments, variables):
        """The model keeps reopenings only; any other kind of event has none."""
        times = (self.reopened_at.get(issue_id, [])
                 if argument(arguments, 'itemTypes', variables) == '[REOPENED_EVENT]' else [])
        events = [{'__typename': 'ReopenedEvent', 'createdAt': when} for when in times]
        ends = re.findall(r'\b(first|last): (\d+)', arguments)
        assert len(ends) == 1, arguments
        (end, count), = ends
        return events[-int(count):] if end == 'last' else events[:int(count)]

    def close_issue(self, arguments, variables):
        issue_id = argument(arguments, 'issueId', variables)
        self.closes.append(issue_id)
        answer = self.answers.get(issue_id, 'CLOSED')
        if isinstance(answer, Exception):
            raise answer
        if answer is None:
            return None
        if answer == 'CLOSED':
            self.closed_as[issue_id] = argument(arguments, 'stateReason', variables)
        return {'issue': {'state': answer}}


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
            ahead={102: 0, 103: 3, 104: 1})
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

    def test_an_issue_reopened_after_the_merge_stays_open(self):
        """A merge closes its issue once.

        A reopening after the merge is not overruled, whether the merge had
        closed the issue or it was closed before the merge. The second of the
        merge counts as after it.
        """
        records, github = close(
            (101, pull(101, issue(7), issue(8), issue(9), issue(10), issue(11))),
            reopened_at={'I_7': [AFTER_THE_MERGE], 'I_8': [THE_MERGE], 'I_9': [BEFORE_THE_MERGE],
                         'I_11': [BEFORE_THE_MERGE, AFTER_THE_MERGE]})
        self.assertEqual(decisions(records), [
            (101, url(7), False), (101, url(8), False), (101, url(9), True), (101, url(10), True),
            (101, url(11), False)])
        self.assertEqual(github.closes, ['I_9', 'I_10'])
        self.assertEqual({row['reason'] for row in records if not row['closed']},
                         {'the issue was reopened after the merge'})

    def test_a_later_merge_closes_an_issue_reopened_after_an_earlier_merge(self):
        records, github = close(
            (101, pull(101, issue(7), merged_at=THE_MERGE)),
            (102, pull(102, issue(7), merged_at=A_LATER_MERGE)),
            reopened_at={'I_7': [AFTER_THE_MERGE]})
        self.assertEqual(decisions(records), [(101, url(7), False), (102, url(7), True)])
        self.assertEqual(github.closes, ['I_7'])

    def test_an_issue_closed_since_the_read_gets_no_close(self):
        """Two runs can meet one merge; the later one finds the issue closed."""
        records, github = close((101, pull(101, issue(7), issue(8))), now={'I_7': 'CLOSED'})
        self.assertEqual(decisions(records), [(101, url(7), False), (101, url(8), True)])
        self.assertEqual(records[0]['reason'], 'the issue is no longer open')
        self.assertEqual(github.closes, ['I_8'])

    def test_a_close_that_fails_is_a_record_and_the_next_issue_still_closes(self):
        records, github = close(
            (101, pull(101, issue(7), issue(8), issue(9), issue(10))),
            answers={'I_7': ValueError('Resource not accessible by integration'), 'I_8': 'OPEN',
                     'I_9': None})
        self.assertEqual(decisions(records), [
            (101, url(7), False), (101, url(8), False), (101, url(9), False), (101, url(10), True)])
        self.assertIn('Resource not accessible', records[0]['reason'])
        self.assertEqual(github.closes, ['I_7', 'I_8', 'I_9', 'I_10'])

    def test_an_issue_two_pull_requests_link_gets_one_check_one_close_and_a_record_each(self):
        records, github = close(
            (101, pull(101, issue(7), merged=False)),
            (102, pull(102, issue(7))),
            (103, pull(103, issue(7))))
        self.assertEqual(decisions(records), [
            (101, url(7), False), (102, url(7), True), (103, url(7), True)])
        self.assertEqual((github.checks, github.closes), ([{'i0': 'I_7'}], ['I_7']))
        records, github = close(
            (102, pull(102, issue(7))), (103, pull(103, issue(7))),
            answers={'I_7': ValueError('refused')})
        self.assertEqual(decisions(records), [(102, url(7), False), (103, url(7), False)])
        self.assertEqual(github.closes, ['I_7'])

    def test_a_check_that_fails_refuses_every_open_issue_and_keeps_the_earlier_records(self):
        for check in (ValueError('API rate limit exceeded'), {}):
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

    def test_a_linked_issue_that_comes_back_null_is_reported_and_the_rest_close(self):
        records, github = close((101, pull(101, None, issue(7))))
        self.assertEqual(decisions(records), [(101, None, False), (101, url(7), True)])
        self.assertEqual(github.closes, ['I_7'])

    def test_a_read_of_another_shape_raises_before_anything_is_sent(self):
        """The worker turns what the read raises into one record; nothing is half done."""
        good = FakeGitHub((101, pull(101, issue(7))))(
            ISSUES.read_query([101]), owner='owner', name='repo')
        assert isinstance(good, dict)
        shapes = {
            'a time in another format': (
                lambda row: row.update(mergedAt='2026-11-12T02:09:02+00:00'), ValueError),
            'an issue without its url': (
                lambda row: row['closingIssuesReferences']['nodes'][0].pop('url'), KeyError),
            'issues that are not a list': (
                lambda row: row['closingIssuesReferences'].update(nodes={'I_7': None}), TypeError),
        }
        for name, (change, error) in shapes.items():
            with self.subTest(name):
                answer = copy.deepcopy(good)
                change(answer['repository']['p101'])
                github = FakeGitHub(read=answer)
                with self.assertRaises(error):
                    ISSUES.close_linked_issues(REPO, [101], github)
                self.assertEqual((github.checks, github.closes), ([], []))

    def test_the_documents_name_only_pull_request_numbers(self):
        """Everything else travels as a variable, so no value is spliced into a document."""
        with self.assertRaises(ValueError):
            ISSUES.read_query(['101) { id } evil: pullRequest(number: 1'])
        with self.assertRaises(ValueError):
            ISSUES.check_query(['101'], 1)


if __name__ == '__main__':
    unittest.main()
