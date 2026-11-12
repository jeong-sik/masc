"""Close the issues that merged pull requests name as closing references.

GitHub closes a linked issue when its pull request merges into the default
branch. It leaves the issue open when the merge is made with the Actions
token: of 19 open issues linked from pull requests the merge worker landed on
main, none closed within a minute of the merge (#51498). The worker therefore
closes them itself.

A merge closes its issues once. The worker meets the same merged pull request
again: on a recheck, after a run that died before this step, and in a stack
whose lower layers landed earlier. An issue that was closed after the merge
and is open now was reopened by a person, so it stays open.

The decisions live here and the one I/O path comes in as an argument:
`graphql(document, **variables)` returns the response's `data` and raises
ValueError when the call fails.
"""
import datetime

# One page of a pull request's closing references. A pull request that links
# more is reported instead of being read further.
LINKED_ISSUE_PAGE = 100
CLOSED = 'CLOSED'
CLOSE_ISSUE = ('mutation($id: ID!) { closeIssue(input: {issueId: $id, stateReason: COMPLETED}) '
               '{ issue { state } } }')


def read_query(numbers):
    """One document reads every pull request, so the cost does not grow per member."""
    pulls = ' '.join(
        f'p{number:d}: pullRequest(number: {number:d}) '
        '{ merged mergedAt baseRefName mergeCommit { oid } '
        f'closingIssuesReferences(first: {LINKED_ISSUE_PAGE}) '
        '{ totalCount nodes { id url state } } }'
        for number in numbers)
    return ('query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) '
            f'{{ defaultBranchRef {{ name }} {pulls} }} }}')


def check_query(layers, issues):
    """One document asks what the read cannot tell about the issues still open.

    For each pull request in `layers`, whether its merge commit (`c<number>`)
    is on the branch; for each of `issues` issues (`i<index>`), when it was
    last closed.
    """
    declared = [f'$i{index:d}: ID!' for index in range(issues)]
    selected = [f'i{index:d}: node(id: $i{index:d}) {{ ... on Issue {{ timelineItems('
                'itemTypes: [CLOSED_EVENT], last: 1) { nodes { ... on ClosedEvent { createdAt } } } '
                '} }' for index in range(issues)]
    if layers:
        declared += ['$owner: String!', '$name: String!', '$branch: String!']
        declared += [f'$c{number:d}: String!' for number in layers]
        compared = ' '.join(f'p{number:d}: compare(headRef: $c{number:d}) {{ aheadBy }}'
                            for number in layers)
        selected.append('repository(owner: $owner, name: $name) { ref(qualifiedName: $branch) '
                        f'{{ {compared} }} }}')
    return f'query({", ".join(declared)}) {{ {" ".join(selected)} }}'


def instant(value):
    """GitHub writes a time as 2026-11-12T02:09:02Z; anything else is refused."""
    return datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')


def refused(number, issue, reason):
    return {'pr': number, 'issue': issue['url'], 'closed': False, 'reason': reason}


def check(owner, name, default, undecided, graphql):
    """Ask what decides the open issues of merged pull requests.

    Returns the layers whose merge commit is on the default branch, and for
    each issue the time it was last closed, or None when it never was.
    """
    layers = {number: pull['mergeCommit']['oid'] for number, pull, _ in undecided
              if pull['baseRefName'] != default}
    ids = list(dict.fromkeys(issue['id'] for _, _, opened in undecided for issue in opened))
    variables = {f'i{index:d}': issue_id for index, issue_id in enumerate(ids)}
    if layers:
        variables.update(owner=owner, name=name, branch=f'refs/heads/{default}')
        variables.update({f'c{number:d}': oid for number, oid in layers.items()})
    checked = graphql(check_query(list(layers), len(ids)), **variables)
    landed = set()
    for number in layers:
        comparison = checked['repository']['ref'][f'p{number:d}']
        # A commit on the branch is never ahead of it; no answer proves nothing.
        if comparison is not None and comparison['aheadBy'] == 0:
            landed.add(number)
    last_closed = {}
    for index, issue_id in enumerate(ids):
        events = checked[f'i{index:d}']['timelineItems']['nodes']
        last_closed[issue_id] = instant(events[0]['createdAt']) if events else None
    return landed, last_closed


def close(issue_id, graphql):
    """Send one close. A refusal and an answer that cannot be read are both its outcome."""
    try:
        state = graphql(CLOSE_ISSUE, id=issue_id)['closeIssue']['issue']['state']
    except (ValueError, TypeError, KeyError) as error:
        return {'closed': False, 'reason': f'{type(error).__name__}: {error}'[:300]}
    if state != CLOSED:
        return {'closed': False, 'reason': f'GitHub answered {state}'}
    return {'closed': True}


def close_linked_issues(repo, numbers, graphql):
    """Close the open issues that landed pull requests link; return one record per decision.

    A pull request has landed when it is merged and its base is the default
    branch or its merge commit is on that branch. A layer of a native stack
    keeps its parent branch as base after the stack lands on main, so the
    base alone would leave the issues of every such layer open.

    Only the first read can raise. After it, every pull request and issue gets
    its own record, so one that cannot be decided does not hide the others.
    """
    owner, name = repo.split('/')
    repository = graphql(read_query(numbers), owner=owner, name=name)['repository']
    default = repository['defaultBranchRef']['name']
    records, undecided = [], []
    for number in numbers:
        pull = repository[f'p{number:d}']
        linked = pull['closingIssuesReferences']
        if linked['totalCount'] > len(linked['nodes']):
            records.append({'pr': number, 'closed': False,
                            'reason': f'{linked["totalCount"]} linked issues; only the first '
                                      f'{len(linked["nodes"])} were read'})
        # GitHub answers null for an issue this token may not read.
        unreadable = linked['nodes'].count(None)
        if unreadable:
            records.append({'pr': number, 'closed': False,
                            'reason': f'{unreadable} linked issues are not readable'})
        opened = [issue for issue in linked['nodes']
                  if issue is not None and issue['state'] == 'OPEN']
        if not opened:
            continue
        if pull['merged'] is not True:
            kept = 'GitHub does not report the pull request as merged'
        elif pull['baseRefName'] != default and pull['mergeCommit'] is None:
            kept = f'GitHub reports no merge commit to look for on {default}'
        else:
            undecided.append((number, pull, opened))
            continue
        records += [refused(number, issue, kept) for issue in opened]
    if not undecided:
        return records

    try:
        landed, last_closed = check(owner, name, default, undecided, graphql)
        merged_at = {number: instant(pull['mergedAt']) for number, pull, _ in undecided}
    except (ValueError, TypeError, KeyError) as error:
        reason = f'could not check the merge and the issue: {type(error).__name__}: {error}'[:300]
        return records + [refused(number, issue, reason)
                          for number, _, opened in undecided for issue in opened]

    outcome = {}
    for number, pull, opened in undecided:
        for issue in opened:
            closed_at = last_closed[issue['id']]
            if pull['baseRefName'] != default and number not in landed:
                records.append(refused(number, issue, f'the merge commit is not on {default}'))
            elif closed_at is not None and closed_at >= merged_at[number]:
                records.append(refused(number, issue,
                                       'the issue was closed after the merge and reopened'))
            else:
                # Two pull requests can link one issue; it gets one close.
                if issue['id'] not in outcome:
                    outcome[issue['id']] = close(issue['id'], graphql)
                records.append(dict({'pr': number, 'issue': issue['url']}, **outcome[issue['id']]))
    return records
