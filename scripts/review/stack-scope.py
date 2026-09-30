#!/usr/bin/env python3
"""Read the native merge scope and freeze identities; never mutate GitHub.

The REST stack order, not branch names, defines downstack membership. Closed
members remain in the membership snapshot but are not admitted for merging.
"""
import json
import os
import re
import subprocess
import sys


def snapshot(repo, selected, expected_head):
    def get(path):
        return json.loads(subprocess.check_output(
            [os.environ.get('GUARD_GH', 'gh'), 'api', path, '--jq', '.'], text=True))

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def identity(pr):
        value = {key: pr[key] for key in ('state', 'draft', 'merged', 'base', 'head')}
        # Freeze review-relevant identity, not volatile repository statistics.
        for side in ('base', 'head'):
            ref = pr[side]
            require(isinstance(ref['ref'], str) and ref['ref'], 'missing branch')
            require(re.fullmatch('[0-9a-f]{40}', ref['sha']) is not None, 'invalid SHA')
            value[side] = {key: ref[key] for key in ('ref', 'sha')}
            value[side]['repo'] = (ref.get('repo') or {}).get('full_name')
        value['author'] = pr['user']['login']
        require(bool(value['author']), 'missing author')
        value['stack'] = pr.get('stack')
        return value

    row = get(f'repos/{repo}/pulls/{selected}')
    require(row['state'] == 'open' and row['draft'] is False and row['merged'] is False,
            f'#{selected} is not open and ready')
    require(row['head']['sha'] == expected_head, f'#{selected} head moved')
    stack = row.get('stack')
    if stack is None:
        return {'stack': None, 'members': [selected],
                'scope': [{'number': selected, 'identity': identity(row)}]}
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
    scope = []
    for position, member in enumerate(live['pull_requests'][:members.index(selected) + 1], 1):
        require(member['state'] in ('open', 'closed'), 'unknown member state')
        current = row if member['number'] == selected else get(f"repos/{repo}/pulls/{member['number']}")
        require(current['state'] == member['state'] and current['head']['sha'] == member['head']['sha'],
                f"#{member['number']} changed while reading stack")
        expected_stack = dict(stack, position=position)
        require(current.get('stack') == expected_stack, f"#{member['number']} stack identity changed")
        scope.append({'number': member['number'], 'identity': identity(current)})
    return {'stack': stack, 'members': members, 'scope': scope}


if __name__ == '__main__':
    try:
        print(json.dumps(snapshot(sys.argv[1], int(sys.argv[2]), sys.argv[3]), sort_keys=True))
    except (ValueError, KeyError, TypeError, IndexError, subprocess.CalledProcessError) as error:
        print(f'REFUSED: cannot establish merge scope: {error}', file=sys.stderr)
        sys.exit(2)
