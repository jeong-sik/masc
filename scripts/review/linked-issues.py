"""Close the issues that merged pull requests name as closing references.

GitHub closes a linked issue when its pull request merges into the default
branch. It leaves the issue open when the merge is made with the Actions
token: of 19 open issues linked from pull requests the merge worker landed on
main, none closed within a minute of the merge (#51498). The worker therefore
closes them itself.

A merge closes its issues once. The worker meets the same merged pull request
again: on a recheck, after a run that died before this step, and in a stack
whose lower layers landed earlier. An issue that was reopened after the merge
stays open, whoever reopened it.

The decisions live here and the one I/O path comes in as an argument:
`graphql(document, **variables)` returns the response's `data` and raises
ValueError when the call fails.
"""
import dataclasses
import datetime

# One page of a pull request's closing references. A pull request that links
# more is reported instead of being read further.
LINKED_ISSUE_PAGE = 100
OPEN = 'OPEN'
CLOSED = 'CLOSED'
CLOSE_ISSUE = ('mutation($id: ID!) { closeIssue(input: {issueId: $id, stateReason: COMPLETED}) '
               '{ issue { state } } }')


@dataclasses.dataclass(frozen=True, slots=True)
class Issue:
    """A linked issue that the read reports as open."""
    id: str
    url: str


@dataclasses.dataclass(frozen=True, slots=True)
class Merged:
    """A merged pull request with open linked issues.

    `commit` is the merge commit to look for on the default branch. It is None
    when that branch is the base, which needs no look.
    """
    number: int
    merged_at: datetime.datetime
    commit: str | None
    issues: tuple[Issue, ...]


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

    For each pull request in `layers`, how far its merge commit (`c<number>`)
    is ahead of the branch. For each of `issues` issues (`i<index>`), its
    state now and when it was last reopened.
    """
    declared = [f'$i{index:d}: ID!' for index in range(issues)]
    selected = [f'i{index:d}: node(id: $i{index:d}) {{ ... on Issue {{ state timelineItems('
                'itemTypes: [REOPENED_EVENT], last: 1) { nodes { ... on ReopenedEvent { createdAt } } } '
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
    return {'pr': number, 'issue': issue.url, 'closed': False, 'reason': reason}


def read(repository, numbers):
    """Take from the read's answer what the later steps use.

    Returns the default branch, the records the read already decides, and the
    merged pull requests whose open issues are still to decide. An answer of
    another shape raises here, before anything is sent. Only subscripts, `len`
    and loops touch the answer, so what it raises is a KeyError, TypeError or
    ValueError.
    """
    default = repository['defaultBranchRef']['name']
    records, merged = [], []
    for number in numbers:
        pull = repository[f'p{number:d}']
        linked = pull['closingIssuesReferences']
        nodes = linked['nodes']
        if linked['totalCount'] > len(nodes):
            records.append({'pr': number, 'closed': False,
                            'reason': f'{linked["totalCount"]} linked issues; only the first '
                                      f'{len(nodes)} were read'})
        # The schema lets an entry of the list be null. Such an issue cannot be decided.
        unreadable = sum(1 for node in nodes if node is None)
        if unreadable:
            records.append({'pr': number, 'closed': False,
                            'reason': f'{unreadable} linked issues are not readable'})
        issues = tuple(Issue(node['id'], node['url']) for node in nodes
                       if node is not None and node['state'] == OPEN)
        if not issues:
            continue
        layer = pull['baseRefName'] != default
        if pull['merged'] is not True:
            kept = 'GitHub does not report the pull request as merged'
        elif layer and pull['mergeCommit'] is None:
            kept = f'GitHub reports no merge commit to look for on {default}'
        else:
            merged.append(Merged(number, instant(pull['mergedAt']),
                                 pull['mergeCommit']['oid'] if layer else None, issues))
            continue
        records += [refused(number, issue, kept) for issue in issues]
    return default, records, merged


def check(owner, name, default, merged, graphql):
    """Ask what decides the open issues of merged pull requests.

    Returns the layers whose merge commit is on the default branch, and for
    each issue its state now with the time it was last reopened, or None when
    it never was.
    """
    layers = {pull.number: pull.commit for pull in merged if pull.commit is not None}
    ids = list(dict.fromkeys(issue.id for pull in merged for issue in pull.issues))
    variables = {f'i{index:d}': issue_id for index, issue_id in enumerate(ids)}
    if layers:
        variables.update(owner=owner, name=name, branch=f'refs/heads/{default}')
        variables.update({f'c{number:d}': commit for number, commit in layers.items()})
    checked = graphql(check_query(list(layers), len(ids)), **variables)
    # A commit on the branch is never ahead of it.
    landed = {number for number in layers
              if checked['repository']['ref'][f'p{number:d}']['aheadBy'] == 0}
    now = {}
    for index, issue_id in enumerate(ids):
        node = checked[f'i{index:d}']
        reopened = node['timelineItems']['nodes']
        now[issue_id] = (node['state'], instant(reopened[0]['createdAt']) if reopened else None)
    return landed, now


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

    An issue is left open when it was reopened at or after the merge. GitHub
    keeps times to the second, and the same second counts as after: closing
    an issue someone reopened costs more than leaving one open.

    Only the read can raise, and it raises before anything is sent. After it
    every pull request and issue gets its own record. A check that fails
    refuses every open issue of the call; a close that fails is the record
    of that issue alone.
    """
    owner, name = repo.split('/')
    default, records, merged = read(
        graphql(read_query(numbers), owner=owner, name=name)['repository'], numbers)
    if not merged:
        return records

    try:
        landed, now = check(owner, name, default, merged, graphql)
    except (ValueError, TypeError, KeyError) as error:
        reason = f'could not check the merge and the issue: {type(error).__name__}: {error}'[:300]
        return records + [refused(pull.number, issue, reason)
                          for pull in merged for issue in pull.issues]

    outcome = {}
    for pull in merged:
        for issue in pull.issues:
            state, reopened_at = now[issue.id]
            if pull.commit is not None and pull.number not in landed:
                kept = f'the merge commit is not on {default}'
            elif state != OPEN:
                # Another run or a person closed it between the read and the check.
                kept = 'the issue is no longer open'
            elif reopened_at is not None and reopened_at >= pull.merged_at:
                kept = 'the issue was reopened after the merge'
            else:
                # Two pull requests can link one issue; it gets one close.
                if issue.id not in outcome:
                    outcome[issue.id] = close(issue.id, graphql)
                records.append({'pr': pull.number, 'issue': issue.url, **outcome[issue.id]})
                continue
            records.append(refused(pull.number, issue, kept))
    return records
