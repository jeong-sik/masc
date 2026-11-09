#!/usr/bin/env python3
"""Merge ordinary main-targeted scopes with two current-head account approvals.

Only trusted default-branch Actions code executes this worker. The downloaded
request is an untrusted PR number, never executable code or merge evidence.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


def sibling(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    if spec is None or spec.loader is None:
        raise ImportError(f'cannot load review helper {name}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REVIEWS = sibling('github-reviews')
STACKS = sibling('stack-scope')
REQUIRED_APPROVALS = 2  # Operator-requested distinct GitHub accounts.


class Hold(ValueError):
    """Known unmet merge condition; another review/event can recheck it."""


def read(path):
    return REVIEWS.gh_json('gh', path)


def pages(path):
    result = REVIEWS.gh_json('gh', '--paginate', '--slurp', path)
    if not isinstance(result, list) or not all(isinstance(page, list) for page in result):
        raise ValueError('expected paginated arrays')
    return [row for page in result for row in page]


def pull(repo, number):
    return read(f'repos/{repo}/pulls/{number}')


def top_pull(repo, number):
    seed = pull(repo, number)
    stack = seed.get('stack')
    if stack is None:
        return seed
    live = read(f'repos/{repo}/stacks/{stack["number"]}')
    # Include a closed, unmerged top as a blocker. Never silently merge just
    # the lower open portion of a stack whose top was closed.
    for member in reversed(live['pull_requests']):
        current = pull(repo, member['number'])
        if current['merged'] is not True:
            return current
    raise Hold('the stack has already merged')


def require_server_reviews(repo):
    rules = read(f'repos/{repo}/rules/branches/main')
    if not any(rule['type'] == 'pull_request' and
               rule['parameters']['required_approving_review_count'] >= REQUIRED_APPROVALS and
               rule['parameters']['dismiss_stale_reviews_on_push'] is True
               for rule in rules):
        raise Hold('main must enforce two reviews and dismiss stale approvals on GitHub')


def disable_reservation(repo, current):
    if current['state'] == 'open' and current.get('auto_merge') is not None:
        subprocess.run(['gh', 'pr', 'merge', str(current['number']), '--repo', repo,
                        '--disable-auto'], check=True)


def auto_merge_default(repo, number):
    """Arm ordinary Ready PRs; native stacks use the whole-scope worker."""
    current = pull(repo, number)
    stack = current.get('stack')
    if stack is not None:
        live = read(f'repos/{repo}/stacks/{stack["number"]}')
        for member in live['pull_requests']:
            row = pull(repo, member['number'])
            # A reservation on a lower PR could land only part of this
            # stack. The worker submits the current whole scope instead.
            disable_reservation(repo, row)
        return None
    if (current['state'] != 'open' or current['draft'] is not False or
            current['base']['ref'] != 'main' or current['head']['ref'].startswith('release/')):
        disable_reservation(repo, current)
        return None
    require_server_reviews(repo)
    selected, _, head = REVIEWS.pr_identity(current)
    before = STACKS.snapshot(repo, selected, head)
    if before['stack'] is not None or before['scope'][0]['identity']['base']['ref'] != 'main':
        raise Hold('merge scope changed before enabling auto-merge')
    if STACKS.snapshot(repo, selected, head) != before:
        raise Hold('PR identity changed before enabling auto-merge')
    attempt = None
    if current.get('auto_merge') is None:
        emit({'status': 'enabling_auto_merge', 'pr': selected, 'head': head})
        attempt = subprocess.run(['gh', 'pr', 'merge', str(selected), '--repo', repo,
                                  '--auto', '--squash', '--match-head-commit', head],
                                 capture_output=True, text=True, check=False)
    after = pull(repo, selected)
    if after['merged'] is True:
        return {'status': 'merged', 'pr': selected, 'merge_commit_sha': after['merge_commit_sha']}
    if after.get('auto_merge') is None:
        if attempt is not None and attempt.returncode:
            raise ValueError(attempt.stderr.strip() or 'gh could not enable auto-merge')
        raise ValueError('GitHub has not confirmed auto-merge is enabled')
    return {'status': 'auto_merge_enabled', 'pr': selected, 'head': after['head']['sha'],
            'auto_merge': after['auto_merge']}


def review_evidence(repo, current):
    number, _, head = REVIEWS.pr_identity(current)
    history = pages(f'repos/{repo}/pulls/{number}/reviews?per_page=100')
    verdict = REVIEWS.evaluate(current, history, head=head)
    approved_ids = set(verdict['approval_ids'])
    accounts = {review['user']['id'] for review in history if review['id'] in approved_ids}
    if verdict['change_requests'] or verdict['ambiguous_review_ids']:
        raise Hold(f'#{number} has a change request or ambiguous review history')
    if len(accounts) < REQUIRED_APPROVALS:
        raise Hold(f'#{number} has {len(accounts)}/{REQUIRED_APPROVALS} current-head account approvals')
    return history


def prepare(repo, number):
    require_server_reviews(repo)
    top = top_pull(repo, number)
    selected, _, head = REVIEWS.pr_identity(top)
    if top['state'] != 'open' or top['draft'] is not False or top['merged'] is not False:
        raise Hold(f'#{selected} is not open and ready')
    before = STACKS.snapshot(repo, selected, head)
    selected_identity = next(member['identity'] for member in before['scope']
                             if member['number'] == selected)
    destination = (before['stack']['base']['ref'] if before['stack'] else
                   selected_identity['base']['ref'])
    if destination != 'main':
        raise Hold('only scopes targeting main are automatic; land a non-native parent first')
    histories = {}
    for member in before['scope']:
        identity = member['identity']
        if identity['merged'] is True:
            continue
        if identity['head']['ref'].startswith('release/'):
            raise Hold('Release/Tag candidates retain manual full-CI admission')
        if identity['state'] != 'open' or identity['draft'] is not False:
            raise Hold(f'#{member["number"]} is not open and ready')
        current = pull(repo, member['number'])
        if current['head']['sha'] != identity['head']['sha']:
            raise Hold(f'#{member["number"]} head changed')
        histories[member['number']] = review_evidence(repo, current)
    # Membership, all head/base identities and review histories must still
    # match. GitHub independently enforces the two-review rule during merge.
    for pr, history in histories.items():
        if pages(f'repos/{repo}/pulls/{pr}/reviews?per_page=100') != history:
            raise Hold(f'#{pr} reviews changed during admission')
    if STACKS.snapshot(repo, selected, head) != before:
        raise Hold('stack membership, head or base changed during admission')
    return selected, head, before


def submit(repo, selected, head, scope):
    endpoint = f'repos/{repo}/pulls/{selected}'
    if scope['stack'] is None:
        subprocess.run(['gh', 'pr', 'merge', str(selected), '--repo', repo,
                        '--squash', '--match-head-commit', head], check=True)
        current = pull(repo, selected)
        if current['merged'] is not True:
            raise ValueError('GitHub has not confirmed the pull request merged')
        return {'status': 'merged', 'merge_commit_sha': current['merge_commit_sha']}
    operation = subprocess.run(
        ['gh', 'api', '--method', 'PUT', f'{endpoint}/merge-async',
         '-f', 'merge_method=squash', '-f', f'sha={head}', '-F', 'bypass_rules=false'],
        capture_output=True, text=True, check=False)
    response = json.loads(operation.stdout)
    uuid = response.get('details', {}).get('uuid')
    # HTTP 409 returns the existing pending request. Observe that receipt;
    # never cancel or blindly resubmit an operation whose effect is unknown.
    if operation.returncode and not (response.get('status') == 'pending' and uuid):
        raise ValueError(f'GitHub refused the merge: {response}')
    result_endpoint = f'{endpoint}/merge-async/{uuid}' if uuid else None
    receipt = {'status': 'submitted' if operation.returncode == 0 else 'existing_request',
               'request': response, 'result_endpoint': result_endpoint}
    emit(receipt)  # Preserve the external effect before any fallible readback.
    try:
        observation = read(result_endpoint) if result_endpoint else response
        states = {member['number']: pull(repo, member['number'])['merged']
                  for member in scope['scope']}
    except (ValueError, KeyError, TypeError, OSError) as error:
        return dict(receipt, status='observation_unavailable', error=str(error))
    if observation['status'] == 'merged' and not all(states.values()):
        return dict(receipt, status='observation_unavailable', observation=observation,
                    members_merged=states, error='not all member merge states are confirmed')
    return dict(receipt, status=observation['status'], observation=observation,
                members_merged=states)


def requested_pr():
    if os.environ['GITHUB_EVENT_NAME'] == 'workflow_dispatch':
        raw = os.environ['DISPATCH_PR']
        if not raw.isascii() or not raw.isdecimal():
            raise ValueError('pr must be a positive integer')
        return REVIEWS.positive_id(int(raw), 'PR number')
    with open(os.environ['REQUEST_FILE']) as source:
        request = json.load(source)
    if not isinstance(request, dict) or set(request) != {'pr'}:
        raise ValueError('invalid merge request data')
    return REVIEWS.positive_id(request['pr'], 'PR number')


def emit(result):
    output = json.dumps(result, ensure_ascii=False, indent=2)
    print(output, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('```json\n' + output + '\n```\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', help='read admission without merging')
    args = parser.parse_args()
    exit_code = 0
    try:
        repo = os.environ['GITHUB_REPOSITORY']
        if REVIEWS.REPO.fullmatch(repo) is None:
            raise ValueError('invalid repository')
        number = requested_pr()
        if not args.dry_run:
            automatic = auto_merge_default(repo, number)
            if automatic is not None:
                emit(automatic)
                return 0
        selected, head, scope = prepare(repo, number)
        if not args.dry_run:
            emit({'status': 'admitted', 'pr': selected, 'head': head, 'scope': scope})
        outcome = ({'status': 'eligible_dry_run'} if args.dry_run else
                   submit(repo, selected, head, scope))
        result = {'pr': selected, 'head': head, 'scope': scope, 'result': outcome}
        if outcome.get('status') in ('failed', 'observation_unavailable'):
            exit_code = 1
    except Hold as error:
        result = {'status': 'held', 'reason': str(error)}
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f'approval-auto-merge: cannot establish or submit merge: {error}', file=sys.stderr)
        return 1
    emit(result)
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
