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
import re
import subprocess
import sys
import time
from urllib.parse import quote


def sibling(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    if spec is None or spec.loader is None:
        raise ImportError(f'cannot load review helper {name}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REVIEWS = sibling('github-reviews')
STACKS = sibling('stack-scope')
GET = sibling('github-get')
ISSUES = sibling('linked-issues')
CLIENT = GET.Client(
    run=lambda *args, **kwargs: subprocess.run(*args, **kwargs),
    clock=lambda: time.time(), sleep=lambda seconds: time.sleep(seconds),
    on_quota=lambda failure: emit(dict(failure.details, status='rate_limited',
                                       retry_at=failure.retry_at)))
REQUIRED_APPROVALS = 2  # Operator-requested distinct GitHub accounts.
# One worker run follows its own receipt for at most this long. A longer
# queue is reported as still_pending with the receipt; a rerun observes the
# same request (HTTP 409) instead of submitting another.
WAIT_SECONDS = 600
POLL_SECONDS = 10
# A run that outlives its wait hands the receipt to a fresh run of the same
# workflow instead of ending the follow-up. There is no elapsed-time cutoff:
# the chain ends only on a terminal answer (landed, failed, request gone, a
# member closed without merging) or an explicit dispatch failure, all visible.
# Only `pending` is still being decided. `enqueued` and `merged` are final
# answers about the request; whether the pull requests landed is read from the
# members themselves, because the receipt never changes afterwards.
IN_FLIGHT = frozenset({'pending'})
ACCEPTED = frozenset({'merged', 'enqueued'})
SUCCESS = frozenset({'merged', 'eligible_dry_run', 'resume_dispatched', 'following_elsewhere'})
# A hand-off that cannot dispatch is tried once more after this pause. The chain
# is the only reader of its receipt, so one lost dispatch would leave it unread.
HAND_OFF_RETRY_SECONDS = 5
UNSETTLED = frozenset({'still_pending', 'observation_unavailable'})
COMMIT_PAGE = 100  # commits GitHub lists on one page of a comparison
UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
SHA = re.compile(r'[0-9a-f]{40}')


def registered(name, path):
    """Load a module that declares dataclasses. They look their module up by
    name, so it is registered before it runs."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f'cannot load {path}')
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# The source patterns of the pull request type-check, read from the one file
# that holds them.
SOURCES = registered('pr_source_changes',
                     Path(__file__).resolve().parents[1] / 'ci' / 'pr_source_changes.py')
CHECKS = registered('type_check_state', Path(__file__).with_name('type-check-state.py'))


class Hold(ValueError):
    """Known unmet merge condition; another review/event can recheck it."""


# A run started by an event ends at a quota instead of sleeping on a runner
# until the server's reset time: on 2026-11-12 runs that met the quota held
# 28, 13 and 37 runners at once for half an hour or more. The scheduled sweep
# (approval-merge-sweep.py) finds the scope such a run left unmerged. Only
# admission reads end this way. Once a merge request is accepted, `follow`
# keeps its own wait: the receipt must not be dropped.
_ADMISSION = {'ends_at_quota': False}
# Exit status of a run that ended at a quota during admission. The sweep reads
# it to stop: every later candidate would meet the same quota.
QUOTA_EXIT = 75


def read(path):
    return CLIENT.read(path)


def pages(path):
    return CLIENT.pages(path)


def scope_snapshot(repo, selected, head):
    return STACKS.snapshot(repo, selected, head, get=read)


def stable_reads(action):
    """A quota pause discards read evidence, never repeats a write."""
    if _ADMISSION['ends_at_quota']:
        CLIENT.deadline = CLIENT.clock()
    try:
        while True:
            pauses = CLIENT.pauses
            try:
                result = action()
            except GET.ApiFailure:
                raise
            except ValueError:
                if CLIENT.pauses == pauses:
                    raise
                continue
            if CLIENT.pauses == pauses:
                return result
    finally:
        CLIENT.deadline = None


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
        # The listing dates each merged layer, so only a layer it does not
        # call merged is read. Reading every layer cost one request per layer
        # in every run that woke for a stack that had already landed: 86 for
        # stack #51256, in each of the runs its last push had queued.
        if member['state'] == 'closed' and member.get('merged_at') is not None:
            continue
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


def reservation_reads(repo, number, seen):
    """Plan a reservation using only reads, so a quota pause can restart it.

    `seen` receives the requested pull request as soon as it is read. When a
    later read fails, the caller still knows whose reservation to drop.
    """
    current = pull(repo, number)
    seen[number] = current
    stack = current.get('stack')
    if stack is not None:
        live = read(f'repos/{repo}/stacks/{stack["number"]}')
        members = {member['number'] for member in live['pull_requests']}
        # One walk of the open list carries each member's state and
        # reservation, so the cost does not grow with the number of layers.
        # `disable_reservation` acts only on an open pull request, so a
        # merged or closed layer that the list omits needs no read at all.
        opened = pages(f'repos/{repo}/pulls?state=open&per_page=100')
        return None, [row for row in opened if row['number'] in members]
    if (current['state'] != 'open' or current['draft'] is not False or
            current['base']['ref'] != 'main' or current['head']['ref'].startswith('release/')):
        return None, [current]
    require_server_reviews(repo)
    selected, _, head = REVIEWS.pr_identity(current)
    before = scope_snapshot(repo, selected, head)
    if before['stack'] is not None or before['scope'][0]['identity']['base']['ref'] != 'main':
        raise Hold('merge scope changed before enabling auto-merge')
    if scope_snapshot(repo, selected, head) != before:
        raise Hold('PR identity changed before enabling auto-merge')
    # A reservation lets GitHub merge on the required checks alone, and a
    # skipped type-check satisfies them. Do not make one, and drop one made
    # earlier, unless the type-check lets this scope merge now; `prepare`
    # then reports why.
    if type_check_hold(repo, head, current['base']['ref']) is not None:
        return None, [current]
    return (current, selected, head), []


def auto_merge_default(repo, number):
    """Arm ordinary Ready PRs; native stacks use the whole-scope worker."""
    seen = {}
    try:
        reservation, disabled = stable_reads(lambda: reservation_reads(repo, number, seen))
    except (ValueError, KeyError, TypeError, OSError):
        # A reservation is GitHub's own promise to merge on the required
        # checks. It must not outlive a run that could not confirm the
        # type-check, whatever ended the reads: a hold, an HTTP error, an
        # answer that cannot be read, or a quota.
        for row in seen.values():
            disable_reservation(repo, row)
        raise
    for row in disabled:
        # A lower layer's reservation could land only part of a native stack.
        disable_reservation(repo, row)
    if reservation is None:
        return None
    current, selected, head = reservation
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


def type_check_hold(repo, head, destination):
    """Why the type-check of `head` does not let this scope merge, or None.

    The scope is `destination...head`; it is read only for a skipped run.
    """
    listing = read(f'repos/{repo}/commits/{head}/check-runs?check_name={CHECKS.TYPE_CHECK}'
                   f'&filter=all&per_page={CHECKS.CHECK_RUN_PAGE}')
    return CHECKS.hold_reason(
        CHECKS.classify(listing, head), head,
        lambda: read(f'repos/{repo}/compare/{destination}...{head}'), SOURCES.is_source)


def layers_outside(repo, top, lower):
    """Numbers of the lower layers whose current head `top` does not hold.

    `lower` pairs each unmerged layer below the selected pull request with its
    head, bottom first. A layer pushed after the layers above it is not part
    of the tree the top's type-check compiled, and its own check was skipped.

    One comparison from the lowest head lists the commits `top` adds to it,
    and every other lower head must be among them. The cost is one read for
    every 100 commits of the stack, not one for every layer.
    """
    if not lower:
        return []
    lowest = lower[0][1]
    missing = {head: number for number, head in lower[1:] if head != lowest}
    page = 1
    while True:
        compared = CHECKS.ancestry(read(f'repos/{repo}/compare/{lowest}...{top}'
                                        f'?per_page={COMMIT_PAGE}&page={page}'))
        if compared is None:
            raise Hold(f'GitHub did not list the commits between {lowest[:12]} and {top[:12]}')
        if compared.behind_by:
            return [lower[0][0]]
        for commit in compared.commits:
            missing.pop(commit, None)
        if not missing or not compared.commits:
            return sorted(missing.values())
        page += 1


def prepare_reads(repo, number):
    require_server_reviews(repo)
    top = top_pull(repo, number)
    selected, _, head = REVIEWS.pr_identity(top)
    if top['state'] != 'open' or top['draft'] is not False or top['merged'] is not False:
        raise Hold(f'#{selected} is not open and ready')
    # The rows are the scope's own read of each member, so review evidence
    # needs no second read of a layer; the closing snapshot below still
    # refuses a head that moved in between.
    before, rows = STACKS.read_scope(repo, selected, head, get=read)
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
        histories[member['number']] = review_evidence(repo, rows[member['number']])
    hold = type_check_hold(repo, head, destination)
    if hold is not None:
        raise Hold(f'#{selected}: {hold}')
    # That type-check ran on the head of the selected pull request. It covers
    # a lower layer only while that head holds the layer's current head.
    outside = layers_outside(repo, head, [
        (member['number'], member['identity']['head']['sha']) for member in before['scope']
        if member['number'] != selected and member['identity']['merged'] is not True])
    if outside:
        raise Hold(f'#{selected} does not hold the current head of '
                   f'{", ".join(f"#{n}" for n in outside)}; push the layers above again so '
                   f'that the type-check of the top compiles them')
    # Membership, all head/base identities and review histories must still
    # match. GitHub independently enforces the two-review rule during merge.
    for pr, history in histories.items():
        if pages(f'repos/{repo}/pulls/{pr}/reviews?per_page=100') != history:
            raise Hold(f'#{pr} reviews changed during admission')
    if scope_snapshot(repo, selected, head) != before:
        raise Hold('stack membership, head or base changed during admission')
    return selected, head, before


def prepare(repo, number):
    return stable_reads(lambda: prepare_reads(repo, number))


def member_states(repo, scope):
    """Read every scope member; merge evidence is per member, not per receipt."""
    states = {}
    for member in scope['scope']:
        row = pull(repo, member['number'])
        states[member['number']] = {'merged': row['merged'] is True,
                                    'state': row.get('state'),
                                    'merge_commit_sha': row.get('merge_commit_sha')}
    return states


def open_pulls(repo):
    return pages(f'repos/{repo}/pulls?state=open&per_page=100')


def watched_member_states(repo, scope, settled):
    """Poll a scope with one walk of the open list instead of one read per member.

    A member still on the open list is not merged. Only a member that left the
    list is read, once; a closed or merged answer is final and is kept in
    `settled` so no later poll reads it again. The cost of a poll no longer
    grows with the number of layers.
    """
    opened = {row['number'] for row in open_pulls(repo)}
    states = {}
    for member in scope['scope']:
        number = member['number']
        if number in settled:
            states[number] = settled[number]
        elif number in opened:
            states[number] = {'merged': False, 'state': 'open', 'merge_commit_sha': None}
        else:
            row = pull(repo, number)
            states[number] = {'merged': row['merged'] is True, 'state': row.get('state'),
                              'merge_commit_sha': row.get('merge_commit_sha')}
            final = row.get('state') == 'closed' and (
                row['merged'] is not True or bool(row.get('merge_commit_sha')))
            if final:
                settled[number] = states[number]
    return states


def all_landed(states):
    return bool(states) and all(row['merged'] and row['merge_commit_sha']
                                for row in states.values())


def follow(repo, result_endpoint, receipt, scope):
    """Follow one accepted request until it lands, fails, or the wait ends.

    Read failures never resubmit: the receipt already names the effect, so the
    same endpoint is read again. Success needs every scope member to be merged
    with a merge commit. A `pending` answer is still undecided; `merged` and
    `enqueued` are final answers about the request, so the members decide.
    Only the request endpoint can establish that its receipt is gone; member
    read failures leave that request unsettled.
    A quota wait past the budget returns here with the receipt instead of
    sleeping inside the transport: the handoff keeps the UUID and no GET
    goes out before the server time.
    """
    deadline = time.monotonic() + WAIT_SECONDS
    CLIENT.deadline = CLIENT.clock() + WAIT_SECONDS
    receipt = dict(receipt)
    retry_at = receipt.pop('retry_at', None)
    try:
        observation = states = None
        error = None
        settled = {}  # members whose closed or merged answer is already final
        if retry_at is not None:
            try:
                CLIENT.wait_for_quota(GET.QuotaLimited(
                    result_endpoint, None, {}, 'quota retry time from the merge receipt', retry_at))
            except GET.QuotaWaitCutShort as failure:
                return dict(receipt, status='observation_unavailable', error=str(failure),
                            retry_at=failure.retry_at, observation=observation, member_states=states)
        while True:
            try:
                observation = read(result_endpoint)
                status = observation['status']
            except GET.QuotaWaitCutShort as failure:
                return dict(receipt, status='observation_unavailable', error=str(failure),
                            retry_at=failure.retry_at, observation=observation, member_states=states)
            except (ValueError, KeyError, TypeError, OSError) as failure:
                error = str(failure)
                if isinstance(failure, GET.ApiFailure) and failure.status in (404, 410):
                    return dict(receipt, status='request_not_found', error=error)
            else:
                if status not in IN_FLIGHT and status not in ACCEPTED:
                    return dict(receipt, status=status, observation=observation,
                                member_states=states, reason=observation.get('details'))
                try:
                    states = watched_member_states(repo, scope, settled)
                except GET.QuotaWaitCutShort as failure:
                    return dict(receipt, status='observation_unavailable', error=str(failure),
                                retry_at=failure.retry_at, observation=observation, member_states=states)
                except (ValueError, KeyError, TypeError, OSError) as failure:
                    error = str(failure)
                else:
                    error = None
                    abandoned = [n for n, row in states.items()
                                 if row.get('state') == 'closed' and not row['merged']]
                    if abandoned:
                        return dict(receipt, status='member_closed_unmerged', members_closed=abandoned,
                                    observation=observation, member_states=states)
                    if status in ACCEPTED and all_landed(states):
                        return dict(receipt, status='merged', observation=observation,
                                    member_states=states)
            if time.monotonic() >= deadline:
                break
            time.sleep(POLL_SECONDS)
        if error is not None:
            return dict(receipt, status='observation_unavailable', error=error,
                        observation=observation, member_states=states)
        return dict(receipt, status='still_pending', observation=observation, member_states=states)
    finally:
        CLIENT.deadline = None


def hand_off(repo, outcome):
    """Continue an unsettled receipt in a new run; never submit a merge again."""
    receipt = {key: outcome[key] for key in ('uuid', 'pr', 'head', 'members', 'since')}
    if 'retry_at' in outcome:
        receipt['retry_at'] = outcome['retry_at']
    command = ['gh', 'workflow', 'run', 'approval-auto-merge.yml', '--repo', repo,
               '--ref', 'main', '-f', f'pr={receipt["pr"]}',
               '-f', f'receipt={json.dumps(receipt, separators=(",", ":"))}']
    for attempt in range(2):
        try:
            subprocess.run(command, check=True, capture_output=True, text=True)
            break
        except (subprocess.CalledProcessError, OSError) as error:
            if attempt == 0:
                time.sleep(HAND_OFF_RETRY_SECONDS)
                continue
            return dict(outcome, resume=f'dispatch_failed: {error}')
    return dict(outcome, status='resume_dispatched', previous=outcome['status'],
                resume='dispatched')


def parse_receipt(raw):
    """Untrusted dispatch input: shape-checked data that is only ever read."""
    try:
        receipt = json.loads(raw)
    except ValueError as error:
        raise ValueError(f'invalid receipt: {error}') from error
    if (not isinstance(receipt, dict) or
            set(receipt) - {'retry_at'} != {'uuid', 'pr', 'head', 'members', 'since'} or
            not isinstance(receipt['uuid'], str) or UUID.fullmatch(receipt['uuid']) is None or
            not isinstance(receipt['head'], str) or SHA.fullmatch(receipt['head']) is None or
            isinstance(receipt['pr'], bool) or not isinstance(receipt['pr'], int) or
            receipt['pr'] <= 0 or not isinstance(receipt['members'], list) or
            not receipt['members'] or len(receipt['members']) > 100 or
            not all(isinstance(n, int) and not isinstance(n, bool) and n > 0
                    for n in receipt['members']) or receipt['pr'] not in receipt['members'] or
            isinstance(receipt['since'], bool) or not isinstance(receipt['since'], (int, float))):
        raise ValueError('invalid receipt shape')
    if 'retry_at' in receipt and (isinstance(receipt['retry_at'], bool) or
            not isinstance(receipt['retry_at'], (int, float)) or
            not 0 < receipt['retry_at'] < float('inf')):
        raise ValueError('invalid receipt retry_at')
    return receipt


def resume(repo, receipt, dispatch=True):
    """Read the original request again; no admission and no new merge request."""
    endpoint = f'repos/{repo}/pulls/{receipt["pr"]}/merge-async/{receipt["uuid"]}'
    scope = {'scope': [{'number': n} for n in receipt['members']]}
    outcome = follow(repo, endpoint, dict(receipt, status='resumed', result_endpoint=endpoint),
                     scope)
    if outcome['status'] in UNSETTLED and dispatch:
        outcome = hand_off(repo, outcome)
    return outcome


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
    try:
        response = json.loads(operation.stdout)
        uuid = response.get('details', {}).get('uuid')
    except (ValueError, AttributeError):
        response, uuid = None, None
    if uuid is None:
        # A lost or unreadable answer does not prove nothing was accepted.
        # Check the real state and never send the request a second time.
        request = {'pr': selected, 'head': head,
                   'members': [member['number'] for member in scope['scope']]}
        try:
            states = member_states(repo, scope)
        except (ValueError, KeyError, TypeError, OSError) as error:
            return {'status': 'submission_unknown', 'request': request, 'error': str(error),
                    'exit_code': operation.returncode}
        status = 'merged' if all_landed(states) else 'submission_unknown'
        return {'status': status, 'request': request, 'member_states': states,
                'exit_code': operation.returncode, 'stderr': operation.stderr.strip()[:500],
                'response': response}
    # HTTP 409 returns the existing pending request. Observe that receipt;
    # never cancel or blindly resubmit an operation whose effect is unknown.
    if operation.returncode and not (response.get('status') == 'pending' and uuid):
        raise ValueError(f'GitHub refused the merge: {response}')
    result_endpoint = f'{endpoint}/merge-async/{uuid}'
    receipt = {'status': 'submitted' if operation.returncode == 0 else 'existing_request',
               'request': response, 'uuid': uuid, 'pr': selected, 'head': head,
               'members': [member['number'] for member in scope['scope']],
               'since': time.time(), 'result_endpoint': result_endpoint}
    emit(receipt)  # Preserve the external effect before any fallible readback.
    if operation.returncode:
        # HTTP 409: an earlier run owns this request and follows it, and its
        # hand-off chain carries the receipt until a terminal answer. A second
        # chain would poll the same members for nothing, and every event that
        # arrives while the merge is pending would start another one.
        return dict(receipt, status='following_elsewhere')
    outcome = follow(repo, result_endpoint, receipt, scope)
    return hand_off(repo, outcome) if outcome['status'] in UNSETTLED else outcome


MAIN_BUILD_WORKFLOW = 'main-minimal-build.yml'


def wake_main_build(repo):
    """A bot merge emits no push event, so the main build never starts.

    Dispatch it here. A failed dispatch must not change the merge verdict:
    the merge already happened and this call cannot undo it.
    """
    try:
        operation = subprocess.run(
            ['gh', 'api', '--method', 'POST',
             f'repos/{repo}/actions/workflows/{MAIN_BUILD_WORKFLOW}/dispatches',
             '-f', 'ref=main'],
            capture_output=True, text=True, check=False, timeout=120)
    except (OSError, subprocess.SubprocessError) as error:
        # The merge already happened; a wake that cannot run must stay a
        # recorded miss and never escape into the merge verdict.
        return {'dispatched': False, 'exit_code': None,
                'stderr': f'{type(error).__name__}: {error}'[:300]}
    return {'dispatched': operation.returncode == 0,
            'exit_code': operation.returncode,
            'stderr': (operation.stderr or '').strip()[:300]}


_WAKE = {'repo': None, 'enabled': False}


def reports_a_completed_merge(result):
    '''True when this emit payload reports a merge that actually happened.

    Three paths reach a merged verdict: submit() after `gh pr merge`, the
    auto-merge arming readback, and a resumed Native Stack receipt whose
    follow() saw every member merged. All three must wake the main build; a
    dry run and an unsettled receipt must not.
    '''
    if not isinstance(result, dict):
        return False
    if result.get('status') == 'merged':
        return True
    inner = result.get('result')
    return isinstance(inner, dict) and inner.get('status') == 'merged'


def wake_if_already_merged(repo, number):
    '''Wake the main build for a merge that finished before this run looked.

    An auto-merge reservation lets GitHub merge on its own schedule. This run
    then finds the pull request already closed and holds with "is not open and
    ready", so `reports_a_completed_merge` stays false and nothing dispatches.
    A bot merge emits no push event either, so the merge commit reaches main
    with no build run at all.

    The merge is real regardless of which check noticed it, so read the pull
    request back and dispatch for it. A read that cannot run, and a pull
    request that is not merged, record nothing: holding is still not a merge.
    '''
    try:
        current = pull(repo, number)
    except (ValueError, TypeError, KeyError, OSError,
            subprocess.SubprocessError) as error:
        # This runs while unwinding a hold. An unreadable pull request must
        # stay a recorded miss and never replace the hold with a crash.
        return {'dispatched': False, 'exit_code': None,
                'stderr': f'{type(error).__name__}: {error}'[:300]}
    if current.get('merged') is not True:
        return None
    return wake_main_build(repo)


def delete_merged_head(repo, number):
    """Delete the head branch of one merged pull request, if nothing needs it.

    GitHub's delete-branch-on-merge setting does not act on a merge made with
    the Actions token: of 400 recently merged pull requests, all 244 merged by
    this worker kept their branch and 155 of 156 merged by a user account lost
    it (#51366). The worker therefore removes the branch itself.

    The branch stays when the pull request is not merged, comes from a fork,
    is a release branch, or is the base of an open pull request. The push
    carries a lease on the merged head, so a branch that received a commit
    after the merge is refused by the server and kept.
    """
    current = pull(repo, number)
    ref, head = current['head']['ref'], current['head']['sha']
    record = {'pr': number, 'branch': ref}
    if current.get('merged') is not True:
        return dict(record, deleted=False, reason='not merged')
    if current['head']['repo'] is None or current['head']['repo']['full_name'] != repo:
        return dict(record, deleted=False, reason='head is in another repository')
    if ref == 'main' or ref.startswith('release/'):
        return dict(record, deleted=False, reason='protected branch name')
    if read(f'repos/{repo}/pulls?state=open&base={quote(ref, safe="")}&per_page=1'):
        return dict(record, deleted=False, reason='an open pull request uses it as base')
    operation = subprocess.run(
        ['git', '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential',
         'push', f'--force-with-lease=refs/heads/{ref}:{head}',
         f'https://github.com/{repo}.git', f':refs/heads/{ref}'],
        capture_output=True, text=True, check=False, timeout=120)
    if operation.returncode:
        return dict(record, deleted=False, reason=(operation.stderr or '').strip()[-300:])
    return dict(record, deleted=True)


def delete_merged_heads(repo, numbers):
    """Branch cleanup never changes a merge verdict: every failure is a record."""
    records = []
    for number in numbers:
        try:
            records.append(delete_merged_head(repo, number))
        except (ValueError, TypeError, KeyError, OSError,
                subprocess.SubprocessError) as error:
            records.append({'pr': number, 'deleted': False,
                            'reason': f'{type(error).__name__}: {error}'[:300]})
    return records


def merged_numbers(result):
    """Pull requests a merged payload covers: the scope, the receipt, or itself."""
    if 'scope' in result:
        return [member['number'] for member in result['scope']['scope']]
    inner = result.get('result')
    if isinstance(inner, dict) and 'members' in inner:
        return list(inner['members'])
    return [result['pr']]


GRAPHQL_TIMEOUT_SECONDS = 120


def graphql(document, **variables):
    """Run one GraphQL document through gh and return its data.

    Every failure is a ValueError: a process that cannot start or outlives the
    timeout, a refused call, and an answer that carries errors.
    """
    command = ['gh', 'api', 'graphql', '-f', f'query={document}']
    for key, value in variables.items():
        command += ['-f', f'{key}={value}']
    try:
        operation = subprocess.run(command, capture_output=True, text=True, check=False,
                                   timeout=GRAPHQL_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f'{type(error).__name__}: {error}') from error
    if operation.returncode:
        raise ValueError((operation.stderr or operation.stdout).strip()[-300:] or
                         f'gh api graphql exited {operation.returncode}')
    return json.loads(operation.stdout)['data']


def close_linked_issues(repo, numbers):
    """Close the issues the merged pull requests link (#51498).

    GitHub does not close a linked issue for a merge made with the Actions
    token, so the worker closes it. Like branch cleanup, this never changes a
    merge verdict: a read that fails is one record naming the pull requests.
    """
    try:
        return ISSUES.close_linked_issues(repo, numbers, graphql)
    except (ValueError, TypeError, KeyError) as error:
        return [{'prs': list(numbers), 'closed': False,
                 'reason': f'{type(error).__name__}: {error}'[:300]}]


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
    if _WAKE['enabled'] and reports_a_completed_merge(result):
        numbers = merged_numbers(result)
        result['main_build'] = wake_main_build(_WAKE['repo'])
        result['head_branches'] = delete_merged_heads(_WAKE['repo'], numbers)
        result['linked_issues'] = close_linked_issues(_WAKE['repo'], numbers)
    output = json.dumps(result, ensure_ascii=False, indent=2)
    print(output, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('```json\n' + output + '\n```\n')


def main():
    global WAIT_SECONDS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', help='read admission without merging')
    parser.add_argument('--hand-off-now', action='store_true',
                        help='hand an accepted stack request to a fresh run instead of '
                             'following it here')
    args = parser.parse_args()
    exit_code = 0
    try:
        repo = os.environ['GITHUB_REPOSITORY']
        if REVIEWS.REPO.fullmatch(repo) is None:
            raise ValueError('invalid repository')
        _WAKE['repo'] = repo
        _WAKE['enabled'] = not args.dry_run
        _ADMISSION['ends_at_quota'] = not args.dry_run
        if args.hand_off_now:
            WAIT_SECONDS = 0
        number = requested_pr()
        raw_receipt = os.environ.get('DISPATCH_RECEIPT', '')
        if raw_receipt and os.environ['GITHUB_EVENT_NAME'] == 'workflow_dispatch':
            receipt = parse_receipt(raw_receipt)
            if receipt['pr'] != number:
                raise ValueError('receipt does not belong to the requested pull request')
            outcome = resume(repo, receipt, dispatch=not args.dry_run)
            emit({'pr': number, 'result': outcome})
            return 0 if outcome.get('status') in SUCCESS else 1
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
        if outcome.get('status') not in SUCCESS:
            exit_code = 1  # merged is the only success; everything else is visible red
    except Hold as error:
        result = {'status': 'held', 'reason': str(error)}
        if _WAKE['enabled']:
            if _ADMISSION['ends_at_quota']:
                CLIENT.deadline = CLIENT.clock()  # this read must not sleep either
            woken = wake_if_already_merged(_WAKE['repo'], number)
            if woken is not None:
                result['main_build'] = woken
                result['head_branches'] = delete_merged_heads(_WAKE['repo'], [number])
                result['linked_issues'] = close_linked_issues(_WAKE['repo'], [number])
    except GET.QuotaWaitCutShort as error:
        # `on_quota` already emitted status=rate_limited with retry_at.
        print(f'approval-auto-merge: ended at a quota during admission, no merge was '
              f'requested: {error}', file=sys.stderr)
        return QUOTA_EXIT
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f'approval-auto-merge: cannot establish or submit merge: {error}', file=sys.stderr)
        return 1
    finally:
        _ADMISSION['ends_at_quota'] = False
    emit(result)
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
