#!/usr/bin/env python3
"""Find approved scopes that no event merged and run the merge worker on each.

An event is one chance: a worker that fails, or ends at a quota, leaves an
approved pull request unmerged until another event arrives. This sweep runs on
a schedule and gives every such scope another run of the same worker. It
decides nothing about merging. Its selection only avoids starting the worker
where the worker would certainly hold; admission stays in the worker.

One GraphQL walk of the open pull requests feeds the selection, so its cost
grows with pages of 100, not with pull requests.

It also deletes the branches merges left behind (see `merged_leftovers`) and
closes the issues they left open (see `close_merged_issues`).
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

REQUIRED_APPROVALS = 2  # the worker's own rule; a lower count here only wastes a run
QUOTA_EXIT = 75  # approval-auto-merge.py: ended at a quota during admission
# The schedule starts a sweep every 30 minutes. No worker starts after this
# long, so one sweep ends before the next begins.
SWEEP_SECONDS = 20 * 60
WORKER_TIMEOUT_SECONDS = 300
GH_TIMEOUT_SECONDS = 120
# GitHub names the refusal at the start of its message and ends it with
# boilerplate, so the record keeps the start.
ERROR_CHARACTERS = 300
REPO = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
OPEN_PULLS = '''
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number isDraft mergeable isCrossRepository
        baseRefName headRefName headRefOid
        autoMergeRequest { enabledAt }
        latestOpinionatedReviews(first: 20) {
          nodes { state author { login } commit { oid } }
        }
      }
    }
  }
}
'''
BRANCHES = '''
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    refs(refPrefix: "refs/heads/", first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        target { oid }
        associatedPullRequests(first: 20, states: [OPEN, MERGED]) {
          pageInfo { hasNextPage }
          nodes { state headRefOid isCrossRepository mergedBy { login } }
        }
      }
    }
  }
}
'''
OPEN_ISSUES = '''
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number url
        closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
          totalCount
          nodes { number merged repository { nameWithOwner } }
        }
      }
    }
  }
}
'''
PUSH_TIMEOUT_SECONDS = 120
MERGER = 'github-actions'  # the account the merge worker's token merges as


def sibling(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    if spec is None or spec.loader is None:
        raise ImportError(f'cannot load review helper {name}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ISSUES = sibling('linked-issues')


def gh(arguments):
    """Run gh and return its JSON answer; every failure is a ValueError."""
    try:
        operation = subprocess.run(['gh', *arguments], capture_output=True, text=True,
                                   check=False, timeout=GH_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f'{type(error).__name__}: {error}') from error
    if operation.returncode:
        raise ValueError((operation.stderr or operation.stdout).strip()[:ERROR_CHARACTERS] or
                         f'gh exited {operation.returncode}')
    return json.loads(operation.stdout)


def graphql(document, **variables):
    """Run one GraphQL document and return its data.

    A call gh refuses and an answer that carries errors are a ValueError.
    """
    arguments = ['api', 'graphql', '-f', f'query={document}']
    for key, value in variables.items():
        arguments += ['-f', f'{key}={value}']
    answer = gh(arguments)
    if answer.get('errors'):
        raise ValueError(json.dumps(answer['errors'])[:ERROR_CHARACTERS])
    return answer['data']


def walk(repo, document, connection):
    """Every node of one repository connection, 100 to a GraphQL call."""
    owner, name = repo.split('/')
    rows, cursor = [], None
    while True:
        after = {} if cursor is None else {'cursor': cursor}
        page = graphql(document, owner=owner, name=name, **after)['repository'][connection]
        rows.extend(page['nodes'])
        if not page['pageInfo']['hasNextPage']:
            return rows
        cursor = page['pageInfo']['endCursor']


def open_pulls(repo):
    return walk(repo, OPEN_PULLS, 'pullRequests')


def protected_branches(repo):
    """Names of the branches a protection rule or a ruleset applies to.

    The Actions token may not read `branchProtectionRule` through GraphQL
    ("Resource not accessible by integration"), so the REST listing is used.
    It marks a branch protected for either kind of rule.
    """
    names, page = set(), 1
    while True:
        listed = gh(['api', f'repos/{repo}/branches?protected=true&per_page=100&page={page}'])
        names.update(branch['name'] for branch in listed)
        if len(listed) < 100:
            return names
        page += 1


def merged_leftovers(refs, rows, protected):
    """Branches a worker merge left behind, as (name, tip).

    The worker deletes a head branch when it sees the merge, and that misses
    the layers of a native stack: each layer is still the base of the open
    layer above it at that moment, and nothing looks again. On 2026-11-12 the
    worker had merged 87 pull requests whose branch was still there.

    A branch goes only when a pull request of this repository that the worker
    merged ended at exactly its tip, so no commit is lost. It stays when an
    open pull request names it as head or base, when a protection rule or a
    ruleset applies to it, or when its pull requests were not all read.
    GitHub deletes the branch itself after a merge made by a user account.
    """
    in_use = {row[side] for row in rows for side in ('baseRefName', 'headRefName')}
    leftovers = []
    for ref in refs:
        name, tip = ref['name'], ref['target']['oid']
        pulls = ref['associatedPullRequests']
        if (name == 'main' or name.startswith('release/') or name in in_use or
                name in protected or pulls['pageInfo']['hasNextPage'] or
                any(pull['state'] == 'OPEN' for pull in pulls['nodes'])):
            continue
        if any(pull['state'] == 'MERGED' and pull['headRefOid'] == tip and
               pull['isCrossRepository'] is False and
               (pull['mergedBy'] or {}).get('login') == MERGER for pull in pulls['nodes']):
            leftovers.append((name, tip))
    return leftovers


def delete_branch(repo, name, tip):
    """Delete one branch under a lease on `tip`; a moved branch is refused."""
    try:
        operation = subprocess.run(
            ['git', '-c', 'credential.helper=', '-c',
             'credential.helper=!gh auth git-credential', 'push',
             f'--force-with-lease=refs/heads/{name}:{tip}',
             f'https://github.com/{repo}.git', f':refs/heads/{name}'],
            capture_output=True, text=True, check=False, timeout=PUSH_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError) as error:
        return f'{type(error).__name__}: {error}'[:ERROR_CHARACTERS]
    return (operation.stderr or '').strip()[-ERROR_CHARACTERS:] if operation.returncode else None


def clean_branches(repo, started, dry_run):
    """Never part of the sweep's verdict: every failure is a record.

    The open pull requests are read again here. The listing the sweep began
    with can be 20 minutes old by now, and a pull request opened since then
    on a merged layer's branch would be closed by deleting that branch.
    """
    try:
        leftovers = merged_leftovers(walk(repo, BRANCHES, 'refs'), open_pulls(repo),
                                     protected_branches(repo))
    except (ValueError, KeyError, TypeError) as error:
        return {'error': str(error)}
    record = {'found': len(leftovers), 'deleted': 0, 'refused': [], 'not_reached': 0}
    for position, (name, tip) in enumerate(leftovers):
        if dry_run or time.monotonic() - started >= SWEEP_SECONDS:
            record['not_reached'] = len(leftovers) - position
            break
        refusal = delete_branch(repo, name, tip)
        if refusal is None:
            record['deleted'] += 1
        else:
            record['refused'].append({'branch': name, 'reason': refusal})
    return record


def merged_closers(repo, issues):
    """The merged pull requests of `repo` that open issues name as closing.

    Returns their numbers and one record per issue whose closing pull
    requests were not all read. Whether a merge landed on the default branch
    and whether the issue was reopened after it is left to linked-issues: a
    layer of a native stack merges into its parent branch and lands on main
    only with the stack. A pull request of another repository is not passed,
    because linked-issues reads a number in `repo`.
    """
    numbers, records = set(), []
    for issue in issues:
        closers = issue['closedByPullRequestsReferences']
        nodes = closers['nodes']
        if closers['totalCount'] > len(nodes):
            records.append({'issue': issue['url'], 'closed': False,
                            'reason': f'{closers["totalCount"]} closing pull requests; only '
                                      f'the first {len(nodes)} were read'})
        # The schema lets an entry of the list be null, as for a pull request
        # of a repository the token cannot read.
        unreadable = sum(1 for node in nodes if node is None)
        if unreadable:
            records.append({'issue': issue['url'], 'closed': False,
                            'reason': f'{unreadable} closing pull requests are not readable'})
        numbers.update(node['number'] for node in nodes
                       if node is not None and node['merged'] is True and
                       node['repository']['nameWithOwner'] == repo)
    return sorted(numbers), records


def close_merged_issues(repo, started, dry_run):
    """Close the issues that merged pull requests left open (#52092).

    The worker closes them when it sees the merge. A pull request it only
    reserves for GitHub's auto-merge is merged later with the Actions token,
    which starts no workflow, so no run sees that merge. On 2026-11-15, 31
    of 600 open issues were left open this way. They are found by their
    state, with no time window, so a sweep that missed one leaves it to the
    next. Never part of the sweep's verdict: every failure is a record.
    """
    try:
        numbers, records = merged_closers(repo, walk(repo, OPEN_ISSUES, 'issues'))
    except (ValueError, KeyError, TypeError) as error:
        return {'error': str(error)}
    record = {'pull_requests': numbers, 'not_reached': 0, 'issues': records}
    if dry_run or time.monotonic() - started >= SWEEP_SECONDS:
        record['not_reached'] = len(numbers)
    elif numbers:
        try:
            record['issues'] += ISSUES.close_linked_issues(repo, numbers, graphql)
        except (ValueError, KeyError, TypeError) as error:
            # Only the read of linked-issues raises, and it raises before any close.
            record['issues'].append({
                'prs': numbers, 'closed': False,
                'reason': f'{type(error).__name__}: {error}'[:ERROR_CHARACTERS]})
    return record


def ready(row):
    """Two accounts approve the current head and nothing certainly blocks it."""
    reviews = row['latestOpinionatedReviews']['nodes']
    approvers = {review['author']['login'] for review in reviews
                 if review['state'] == 'APPROVED' and review['author'] is not None and
                 review['commit'] is not None and review['commit']['oid'] == row['headRefOid']}
    return (row['isDraft'] is False and not row['headRefName'].startswith('release/') and
            row['mergeable'] != 'CONFLICTING' and len(approvers) >= REQUIRED_APPROVALS and
            not any(review['state'] == 'CHANGES_REQUESTED' for review in reviews))


def select(rows, in_native_stack):
    """Pull requests to run the worker on, cheapest first.

    A candidate is a ready pull request based on main. The worker lands a
    native stack whole through its top, so a stack is a candidate only when
    every open pull request above its bottom is ready too.

    `in_native_stack(number)` is asked only for a ready bottom with an unready
    pull request above it: branch names cannot tell a native stack, which must
    wait, from an ordinary pull request another branch happens to build on,
    which merges alone.
    """
    above = {}
    for row in rows:
        if not row['isCrossRepository']:
            above.setdefault(row['baseRefName'], []).append(row)
    picked = []
    for bottom in above.get('main', []):
        if not ready(bottom):
            continue
        layers, pending, seen = [], [bottom], {bottom['number']}
        while pending:
            for row in above.get(pending.pop()['headRefName'], []):
                if row['number'] not in seen:
                    seen.add(row['number'])
                    layers.append(row)
                    pending.append(row)
        if not layers and bottom['autoMergeRequest'] is not None:
            continue  # GitHub merges a reserved pull request by itself
        if not all(ready(row) for row in layers) and in_native_stack(bottom['number']):
            continue
        picked.append((len(layers), bottom['number']))
    return [number for _, number in sorted(picked)]


def in_native_stack(repo, number):
    """GitHub leaves `stack` out of a pull request that is in no stack."""
    return gh(['api', f'repos/{repo}/pulls/{number}']).get('stack') is not None


def quota():
    """The token's REST and GraphQL budgets, for the record only.

    Reading them costs nothing. `limit` and `reset` are kept because the
    documented 1,000 an hour did not match what this token reported.
    """
    try:
        resources = gh(['api', 'rate_limit'])['resources']
        return {name: {key: resources[name][key] for key in ('remaining', 'limit', 'reset')}
                for name in ('core', 'graphql')}
    except (ValueError, KeyError, TypeError):
        return None


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    if REPO.fullmatch(repo) is None:
        raise SystemExit('invalid repository')
    dry_run = '--dry-run' in sys.argv[1:]
    started = time.monotonic()
    report = {'quota_before': quota()}
    try:
        rows = open_pulls(repo)
        candidates = select(rows, lambda number: in_native_stack(repo, number))
    except (ValueError, KeyError, TypeError) as error:
        # The quota read before the listing says which budget was empty.
        print(f'approval-merge-sweep: cannot read the open pull requests: {error}\n'
              f'{json.dumps(report)}', file=sys.stderr)
        return 1
    report.update(open=len(rows), candidates=candidates, runs=[], not_reached=[])
    worker = Path(__file__).with_name('approval-auto-merge.py')
    environment = dict(os.environ, GITHUB_EVENT_NAME='workflow_dispatch', DISPATCH_RECEIPT='')
    environment.pop('GITHUB_STEP_SUMMARY', None)  # one summary for the sweep, not one per run
    stop = 'dry run' if dry_run else None
    for number in candidates:
        if stop is None and time.monotonic() - started >= SWEEP_SECONDS:
            stop = 'sweep time used up'
        if stop is not None:
            report['not_reached'].append(number)
            continue
        print(f'::group::#{number}', flush=True)
        try:
            code = subprocess.run(
                [sys.executable, str(worker), '--hand-off-now'],
                env=dict(environment, DISPATCH_PR=str(number)), check=False,
                timeout=WORKER_TIMEOUT_SECONDS).returncode
        except subprocess.TimeoutExpired:
            code = 'timeout'
        print('::endgroup::', flush=True)
        report['runs'].append({'pr': number, 'exit': code})
        if code == QUOTA_EXIT:
            stop = 'quota reached'
    report['stopped'] = stop
    report['merged_branches'] = clean_branches(repo, started, dry_run)
    report['linked_issues'] = close_merged_issues(repo, started, dry_run)
    report['quota_after'] = quota()
    output = json.dumps(report, ensure_ascii=False, indent=2)
    print(output, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('```json\n' + output + '\n```\n')
    # A worker that held or failed is that scope's own answer and stays in the
    # record. The sweep is red only when it could not look at all.
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
