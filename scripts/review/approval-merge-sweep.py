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

REQUIRED_APPROVALS = 1  # the worker's own rule; a lower count here only wastes a run
# (kept equal to approval-auto-merge.py's REQUIRED_APPROVALS by test_approval_merge_sweep)
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
        statusCheckRollup {
          contexts(first: 100) {
            nodes {
              __typename
              ... on CheckRun { name conclusion startedAt }
              ... on StatusContext { state }
            }
          }
        }
        files(first: 100) {
          totalCount
          nodes { path }
        }
        autoMergeRequest { enabledAt }
        labels(first: 20) { nodes { name } }
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
    defaultBranchRef { name }
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
KEEP = sibling('branch-deletion')  # the worker keeps the same branches
# task-4046: the release freeze lives in a repository variable, not in a file
# on main; only the value '1' freezes. The flag's name, precedence and
# loud/quiet read rules live in release-freeze.py, shared with the worker.
FREEZE = sibling('release-freeze')
FREEZE_VARIABLE = FREEZE.FREEZE_VARIABLE
FREEZE_LABEL = FREEZE.FREEZE_LABEL


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


def freeze_flag(repo):
    """'1' in the MASC_RELEASE_FREEZE repository variable.

    The shared reader in release-freeze.py owns the precedence and the
    loud/quiet rules. The sweep's gh wrapper reports a missing variable in
    GitHub's words ("gh: Not Found (HTTP 404)"), which the reader treats as
    the ordinary quiet off state; every other failed read is loud and still
    fails open (#54644 review).
    """
    return FREEZE.freeze_flag(repo, lambda path: gh(['api', path]),
                              missing=FREEZE.missing_from_gh)


def reclaim_armed(repo):
    """Take down the auto-merge reservations a freeze must stop merging.

    The freeze stops new submissions, but a reservation armed just before
    it would still let GitHub merge on the required checks, and this sweep
    is the only path that returns regularly without an event (#54644
    review). A row carrying freeze-exempt keeps its reservation: its scope
    is admitted despite the freeze, and the worker arms it again on the
    next review event. Every failure is one stderr line; a missed reclaim
    never stops the report.
    """
    try:
        rows = open_pulls(repo)
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f'approval-merge-sweep: cannot read the open pull requests to '
              f'reclaim reservations: {error}', file=sys.stderr)
        return {'reclaimed': [], 'not_reclaimed': []}
    reclaimed: list[int] = []
    not_reclaimed: list[int] = []
    for row in rows:
        if not row.get('autoMergeRequest'):
            continue
        labels = (row.get('labels') or {}).get('nodes') or []
        if any(label.get('name') == FREEZE_LABEL for label in labels):
            continue
        number = row.get('number')
        try:
            dropped = subprocess.run(['gh', 'pr', 'merge', str(number), '--repo', repo,
                                      '--disable-auto'], capture_output=True, text=True,
                                     check=False, timeout=GH_TIMEOUT_SECONDS)
        except (OSError, subprocess.SubprocessError) as error:
            not_reclaimed.append(number)
            print(f'approval-merge-sweep: could not reclaim the armed '
                  f'reservation on #{number}: {type(error).__name__}: {error}',
                  file=sys.stderr)
            continue
        if dropped.returncode:
            not_reclaimed.append(number)
            detail = (dropped.stderr or dropped.stdout or '').strip()[:200]
            print(f'approval-merge-sweep: could not reclaim the armed '
                  f'reservation on #{number}: {detail}', file=sys.stderr)
        else:
            reclaimed.append(number)
    return {'reclaimed': reclaimed, 'not_reclaimed': not_reclaimed}


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
    """Every node of one repository connection, 100 to a GraphQL call.

    The repository's other fields that the document reads come back beside
    the nodes, as the last page answered them.
    """
    owner, name = repo.split('/')
    rows, cursor = [], None
    while True:
        after = {} if cursor is None else {'cursor': cursor}
        repository = graphql(document, owner=owner, name=name, **after)['repository']
        page = repository[connection]
        rows.extend(page['nodes'])
        if not page['pageInfo']['hasNextPage']:
            return repository, rows
        cursor = page['pageInfo']['endCursor']


def open_pulls(repo):
    return walk(repo, OPEN_PULLS, 'pullRequests')[1]


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


def merged_leftovers(refs, rows, protected, default):
    """Branches a worker merge left behind, as (name, tip).

    The worker deletes a head branch when it sees the merge, and that misses
    the layers of a native stack: each layer is still the base of the open
    layer above it at that moment, and nothing looks again. On 2026-11-12 the
    worker had merged 87 pull requests whose branch was still there.

    A branch goes only when a pull request of this repository that the worker
    merged ended at exactly its tip, so no commit is lost. It stays for the
    rules the worker keeps it for too (branch-deletion.py), when an open pull
    request names it as head or base, or when its pull requests were not all
    read.
    GitHub deletes the branch itself after a merge made by a user account.
    """
    in_use = {row[side] for row in rows for side in ('baseRefName', 'headRefName')}
    leftovers = []
    for ref in refs:
        name, tip = ref['name'], ref['target']['oid']
        pulls = ref['associatedPullRequests']
        if (KEEP.kept_by_rule(name, default, name in protected) is not None or
                name in in_use or pulls['pageInfo']['hasNextPage'] or
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

    The open pull requests are read again here, and once more for each branch
    right before its delete. The listing the sweep began with can be 20
    minutes old by now, the deletes themselves take time, and a pull request
    opened since either read on a merged layer's branch would be closed by
    deleting that branch. A branch whose open pull requests cannot be read
    stays, and so does every branch when the default branch cannot be read.
    """
    try:
        repository, refs = walk(repo, BRANCHES, 'refs')
        default = repository['defaultBranchRef']
        if default is None:
            return {'error': 'the repository answered no default branch'}
        leftovers = merged_leftovers(refs, open_pulls(repo), protected_branches(repo),
                                     default['name'])
    except (ValueError, KeyError, TypeError) as error:
        return {'error': str(error)}
    record = {'found': len(leftovers), 'deleted': 0, 'refused': [], 'not_reached': 0}
    for position, (name, tip) in enumerate(leftovers):
        if dry_run or time.monotonic() - started >= SWEEP_SECONDS:
            record['not_reached'] = len(leftovers) - position
            break
        try:
            kept = KEEP.kept_by_open_pull(repo, name, lambda path: gh(['api', path]))
        except (ValueError, KeyError, TypeError) as error:
            record['refused'].append(
                {'branch': name, 'reason': f'its open pull requests were not read: {error}'})
            continue
        if kept is not None:
            record['refused'].append({'branch': name, 'reason': kept})
            continue
        refusal = delete_branch(repo, name, tip)
        if refusal is None:
            record['deleted'] += 1
        else:
            record['refused'].append({'branch': name, 'reason': refusal})
    return record


# A check run speaks about the code by failing, timing out, not starting, or
# needing a human. CANCELLED says nothing: Approval merge request cancels its
# own older runs (cancel-in-progress), and GitHub keeps the cancelled run in
# the rollup, whose aggregate state then reads FAILURE on a pull request with
# nothing wrong. A commit status speaks through its state.
DECISIVE_CHECK_RUN_CONCLUSIONS = frozenset(
    {'FAILURE', 'TIMED_OUT', 'STARTUP_FAILURE', 'ACTION_REQUIRED'})
DECISIVE_STATUS_STATES = frozenset({'FAILURE', 'ERROR'})


def decisively_failed(check):
    """A finished check that said no; a kind this does not know says nothing."""
    kind = check.get('__typename') if isinstance(check, dict) else None
    if kind == 'CheckRun':
        return check.get('conclusion') in DECISIVE_CHECK_RUN_CONCLUSIONS
    if kind == 'StatusContext':
        return check.get('state') in DECISIVE_STATUS_STATES
    return False


def started_order(check):
    """Sorts later runs after earlier ones; `startedAt` is UTC ISO-8601 text."""
    started = check.get('startedAt')
    return (started is None, started or '')


def newest_run_per_name(checks):
    """The checks GitHub still counts: of the runs sharing a name, the newest.

    The rollup lists every run of the head commit, and a run that a newer run
    of the same name replaced stays in it with its conclusion. A `type-check`
    that failed on a stale merge ref and then passed on the same head is both
    a FAILURE and a SUCCESS here, while GitHub judges the pull request by the
    newest run. A run that has not started has no `startedAt` and counts as
    the newest: only a re-run is created after the runs it replaces. A commit
    status is already one per context, and a check without a name (a kind
    this does not know) is kept as it is.

    The name is the only key. Runs of different workflows or apps that share a
    name are not told apart, and two runs of one name that started at the same
    time keep the later entry of the listing. The worst case is one extra
    worker run, since the worker decides admission.
    """
    newest = {}
    unnamed = []
    for check in checks:
        named = isinstance(check, dict) and check.get('__typename') == 'CheckRun'
        name = check.get('name') if named else None
        if name is None:
            unnamed.append(check)
            continue
        held = newest.get(name)
        if held is None or started_order(check) >= started_order(held):
            newest[name] = check
    return [*newest.values(), *unnamed]


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
        numbers, records = merged_closers(repo, walk(repo, OPEN_ISSUES, 'issues')[1])
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
    """Required accounts approve the current head and nothing certainly blocks it."""
    reviews = row['latestOpinionatedReviews']['nodes']
    approvers = {review['author']['login'] for review in reviews
                 if review['state'] == 'APPROVED' and review['author'] is not None and
                 review['commit'] is not None and review['commit']['oid'] == row['headRefOid']}
    # A finished check that failed is a merge refusal GitHub has already
    # decided; selecting the pull request again spends a worker run on the
    # same answer every 30 minutes (#51479 family 1). The checks are read one
    # by one because the rollup's own state also counts a cancelled run as
    # FAILURE, and only the newest run of each name is read because a run a
    # newer run replaced stays in the listing: #53686 was approved, CLEAN and
    # passing on its newest `type-check` while two replaced failures kept it
    # out of every sweep. Pending and expected checks stay selectable — the
    # worker still holds on them, but a later run can see them pass without new
    # evidence. The listing is capped at 100 checks; a failure past the cap
    # falls through and the worker's own answer still records the case.
    checks = ((row.get('statusCheckRollup') or {}).get('contexts') or {}).get('nodes') or []
    if any(decisively_failed(check) for check in newest_run_per_name(checks)):
        return False
    # Workflow-file pull requests cannot be merged by this token at all
    # (#51452 family 3): GitHub refuses the arming itself, and only the human
    # merge path owns them. Selecting one again spends a worker run on the
    # same refusal every 30 minutes. The listing is capped at 100 paths; a
    # truncated scope falls through and the worker's distinct refusal answer
    # still records the case.
    if any((changed.get('path') or '').startswith('.github/workflows/')
           for changed in (row.get('files', {}).get('nodes') or [])):
        return False
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


def sweep_target(arguments):
    """The pull request a dispatched sweep is scoped to (None = walk all).

    The quota re-dispatch names one pull request and the workflow passes it
    as --pr. An empty value (the scheduled sweep, or a dispatch without the
    input) walks every approved scope as before.
    """
    if '--pr' not in arguments:
        return None
    index = arguments.index('--pr')
    if index + 1 >= len(arguments):
        raise SystemExit('--pr needs a pull request number')
    raw = arguments[index + 1]
    if not raw:
        return None
    if not raw.isascii() or not raw.isdecimal():
        raise SystemExit('--pr needs a pull request number')
    return int(raw)


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    if REPO.fullmatch(repo) is None:
        raise SystemExit('invalid repository')
    dry_run = '--dry-run' in sys.argv[1:]
    # task-4046: a frozen repository gets no worker runs, branch cleanup or
    # issue closing from the sweep, but the sweep still takes down
    # reservations armed before the freeze — GitHub would merge those on
    # the required checks otherwise, and this is the only path that returns
    # regularly without an event (#54644 review). A dry run reads the open
    # list only and stays inspectable during a freeze.
    if not dry_run and freeze_flag(repo):
        report = {'status': 'freeze_skipped',
                  'reason': f'release freeze is on ({FREEZE_VARIABLE}=1): no '
                            f'worker runs, branch cleanup or issue closing ran',
                  'reservations': reclaim_armed(repo)}
        output = json.dumps(report, ensure_ascii=False, indent=2)
        print(output, flush=True)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
                summary.write('```json\n' + output + '\n```\n')
        return 0
    target = sweep_target(sys.argv[1:])
    started = time.monotonic()
    report: dict[str, object] = {'quota_before': quota()}
    try:
        rows = open_pulls(repo)
        candidates = select(rows, lambda number: in_native_stack(repo, number))
        if target is not None:
            # A quota re-dispatch walks exactly its own pull request, so the
            # payload's quota_retry count can never reach another worker.
            candidates = [number for number in candidates if number == target]
    except (ValueError, KeyError, TypeError) as error:
        # The quota read before the listing says which budget was empty.
        print(f'approval-merge-sweep: cannot read the open pull requests: {error}\n'
              f'{json.dumps(report)}', file=sys.stderr)
        return 1
    runs: list[dict[str, object]] = []
    not_reached: list[int] = []
    report.update(open=len(rows), candidates=candidates, scoped_to=target, runs=runs,
                  not_reached=not_reached)
    worker = Path(__file__).with_name('approval-auto-merge.py')
    environment = dict(os.environ, GITHUB_EVENT_NAME='workflow_dispatch', DISPATCH_RECEIPT='',
                       # The worker's kill budget, so its cleanup keeps a
                       # reserve inside it (#51479 family 2).
                       DISPATCH_WORKER_BUDGET_SECONDS=str(WORKER_TIMEOUT_SECONDS))
    environment.pop('GITHUB_STEP_SUMMARY', None)  # one summary for the sweep, not one per run
    stop = 'dry run' if dry_run else None
    for number in candidates:
        if stop is None and time.monotonic() - started >= SWEEP_SECONDS:
            stop = 'sweep time used up'
        if stop is not None:
            not_reached.append(number)
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
        runs.append({'pr': number, 'exit': code})
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
