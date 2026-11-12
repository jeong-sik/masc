"""Close the issues that merged pull requests name as closing references.

GitHub closes a linked issue when its pull request merges into the default
branch. It leaves the issue open when the merge is made with the Actions
token: of 19 open issues linked from pull requests the merge worker landed on
main, none closed within a minute of the merge (#51498). The worker therefore
closes them itself.

The decisions live here and the one I/O path comes in as an argument:
`graphql(document, **variables)` returns the response's `data` and raises
ValueError when the call fails.
"""

# One page of a pull request's closing references. A pull request that links
# more is reported instead of being read further.
LINKED_ISSUE_PAGE = 100
CLOSED = 'CLOSED'
CLOSE_ISSUE = ('mutation($id: ID!) { closeIssue(input: {issueId: $id, stateReason: COMPLETED}) '
               '{ issue { state } } }')


def read_query(numbers):
    """One document reads every pull request, so the cost does not grow per member."""
    pulls = ' '.join(
        f'p{number:d}: pullRequest(number: {number:d}) {{ merged baseRefName mergeCommit {{ oid }} '
        f'closingIssuesReferences(first: {LINKED_ISSUE_PAGE}) '
        '{ totalCount nodes { id url state } } }'
        for number in numbers)
    return ('query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) '
            f'{{ defaultBranchRef {{ name }} {pulls} }} }}')


def landed_query(numbers):
    """Compare each pull request's merge commit, passed as `c<number>`, with one branch."""
    declared = ''.join(f', $c{number:d}: String!' for number in numbers)
    compared = ' '.join(f'p{number:d}: compare(headRef: $c{number:d}) {{ aheadBy }}'
                        for number in numbers)
    return (f'query($owner: String!, $name: String!, $branch: String!{declared}) '
            '{ repository(owner: $owner, name: $name) { ref(qualifiedName: $branch) '
            f'{{ {compared} }} }} }}')


def close_linked_issues(repo, numbers, graphql):
    """Close the open issues that landed pull requests link; return one record per decision.

    A pull request has landed when it is merged and its base is the default
    branch or its merge commit is on that branch. A layer of a native stack
    keeps its parent branch as base after the stack lands on main, so the
    base alone would leave the issues of every such layer open. The commit
    comparison is asked only for layers that still have an open issue.
    """
    owner, name = repo.split('/')
    repository = graphql(read_query(numbers), owner=owner, name=name)['repository']
    default = repository['defaultBranchRef']['name']
    records, waiting = [], {}
    for number in numbers:
        pull = repository[f'p{number:d}']
        linked = pull['closingIssuesReferences']
        if linked['totalCount'] > len(linked['nodes']):
            records.append({'pr': number, 'closed': False,
                            'reason': f'{linked["totalCount"]} linked issues; only the first '
                                      f'{len(linked["nodes"])} were read'})
        opened = [issue for issue in linked['nodes'] if issue['state'] == 'OPEN']
        if opened:
            waiting[number] = (pull, opened)
    off_base = [number for number, (pull, _) in waiting.items()
                if pull['merged'] is True and pull['baseRefName'] != default]
    compared = {}
    if off_base:
        commits = {f'c{number:d}': waiting[number][0]['mergeCommit']['oid'] for number in off_base}
        compared = graphql(landed_query(off_base), owner=owner, name=name,
                           branch=f'refs/heads/{default}', **commits)['repository']['ref']
    attempted = set()
    for number, (pull, opened) in waiting.items():
        kept = None
        if pull['merged'] is not True:
            kept = 'GitHub does not report the pull request as merged'
        elif number in off_base:
            comparison = compared[f'p{number:d}']
            # A commit on the branch is never ahead of it; no answer proves nothing.
            if comparison is None or comparison['aheadBy'] != 0:
                kept = f'the merge commit is not on {default}'
        for issue in opened:
            record = {'pr': number, 'issue': issue['url']}
            if kept is not None:
                records.append(dict(record, closed=False, reason=kept))
            elif issue['id'] not in attempted:
                # Two layers can link one issue; the first landed layer closes it.
                attempted.add(issue['id'])
                try:
                    state = graphql(CLOSE_ISSUE, id=issue['id'])['closeIssue']['issue']['state']
                except ValueError as error:
                    records.append(dict(record, closed=False, reason=str(error)[:300]))
                else:
                    records.append(dict(record, closed=True) if state == CLOSED else
                                   dict(record, closed=False, reason=f'GitHub answered {state}'))
    return records
