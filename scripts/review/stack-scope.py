#!/usr/bin/env python3
"""Read the native merge scope and freeze identities; never mutate GitHub.

The REST stack order, not branch names, defines downstack membership. Already
merged members remain in the snapshot; closed unmerged prerequisites block it,
and so does an open member above the selected PR: only the top open PR is
merged, taking the whole stack with it.
"""
import json
import os
import re
import subprocess
import sys


def read_scope(repo, selected, expected_head, *, get=None):
    """The snapshot of the merge scope, and each member's row keyed by number.

    A row holds what a reader of the member's reviews needs: number, user and
    head. Only the selected pull request is read by itself. Every other layer
    comes from the stack listing, which carries the same state, draft, merge
    date, branches, commits and author (compared field by field on stacks
    #51445 and #51256, 2026-11-12). Reading each layer again cost one request
    per layer on every admission, out of the 1,000 an hour that all workflows
    of the repository share.
    """
    if get is None:
        def get(path):
            return json.loads(subprocess.check_output(
                [os.environ.get('MASC_REVIEW_GH', 'gh'), 'api', path, '--jq', '.'], text=True))

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def identity(pr, repository, stack):
        value = {key: pr[key] for key in ('state', 'draft')}
        # Freeze review-relevant identity, not volatile repository statistics.
        for side in ('base', 'head'):
            ref = pr[side]
            require(isinstance(ref['ref'], str) and ref['ref'], 'missing branch')
            require(re.fullmatch('[0-9a-f]{40}', ref['sha']) is not None, 'invalid SHA')
            value[side] = {key: ref[key] for key in ('ref', 'sha')}
            value[side]['repo'] = repository(ref.get('repo'))
        value['author'] = pr['user']['login']
        require(bool(value['author']), 'missing author')
        value['stack'] = stack
        return value

    def named(repo_object):
        return (repo_object or {}).get('full_name')

    row = get(f'repos/{repo}/pulls/{selected}')
    require(row['state'] == 'open' and row['draft'] is False and row['merged'] is False,
            f'#{selected} is not open and ready')
    require(row['head']['sha'] == expected_head, f'#{selected} head moved')
    stack = row.get('stack')
    if stack is None:
        return ({'stack': None, 'members': [selected],
                 'scope': [{'number': selected,
                            'identity': dict(identity(row, named, None), merged=False)}]},
                {selected: row})
    number = stack['number']
    require(type(number) is int and number > 0, 'invalid stack number')
    live = get(f'repos/{repo}/stacks/{number}')
    members = [item['number'] for item in live['pull_requests']]
    require(all(type(n) is int and n > 0 for n in members), 'invalid stack member')
    require(len(set(members)) == len(members) and selected in members, 'invalid stack membership')
    require(live['id'] == stack['id'] and live['number'] == number and
            live['base']['ref'] == stack['base']['ref'] and
            len(members) == stack['size'] and members.index(selected) + 1 == stack['position'],
            'stack membership changed or inconsistent')
    # A native stack lands whole through its top open PR. Selecting a lower
    # one lands only the layers up to it, main moves, and every layer left
    # above it has to be restacked again.
    above = live['pull_requests'][members.index(selected) + 1:]
    require(all(member['state'] in ('open', 'closed') for member in above), 'unknown member state')
    open_above = [member['number'] for member in above if member['state'] == 'open']
    if open_above:
        raise ValueError(
            f"#{selected} is not the top of native stack #{number}: "
            f"{', '.join(f'#{n}' for n in open_above)} above it are open; "
            f"the stack lands whole through #{open_above[-1]}")

    # The listing names a repository by id, name and url, not by full name.
    # The selected pull request names both of its repositories in full, and a
    # stack member in any other repository is refused.
    full_names = {side['repo']['id']: side['repo']['full_name']
                  for side in (row['base'], row['head']) if side.get('repo')}

    def listed(repo_object):
        if repo_object is None:
            return None
        require(repo_object['id'] in full_names, 'stack member in another repository')
        return full_names[repo_object['id']]

    scope, rows = [], {}
    for position, member in enumerate(live['pull_requests'][:members.index(selected) + 1], 1):
        require(member['state'] in ('open', 'closed'), 'unknown member state')
        merged = member['merged_at'] is not None
        require(type(member['draft']) is bool, 'invalid draft flag')
        require(member['state'] != 'closed' or merged,
                f"#{member['number']} is closed without merging and blocks the selected stack")
        require(member['state'] != 'open' or not merged, 'open member has a merge date')
        value = dict(identity(member, listed, dict(stack, position=position)), merged=merged)
        if member['number'] == selected:
            # The listing and the pull request's own answer must agree on the
            # one layer that is read both ways.
            require(value == dict(identity(row, named, row.get('stack')), merged=row['merged']),
                    f'#{selected} changed while reading stack')
        scope.append({'number': member['number'], 'identity': value})
        rows[member['number']] = {key: member[key] for key in ('number', 'user', 'head')}
    return {'stack': stack, 'members': members, 'scope': scope}, rows


def snapshot(repo, selected, expected_head, *, get=None):
    return read_scope(repo, selected, expected_head, get=get)[0]


if __name__ == '__main__':
    try:
        print(json.dumps(snapshot(sys.argv[1], int(sys.argv[2]), sys.argv[3]), sort_keys=True))
    except (ValueError, KeyError, TypeError, IndexError, subprocess.CalledProcessError) as error:
        print(f'REFUSED: cannot establish merge scope: {error}', file=sys.stderr)
        sys.exit(2)
