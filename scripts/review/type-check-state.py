#!/usr/bin/env python3
# pyright: strict
"""Read GitHub's answers about the `type-check` of one commit into closed types.

The merge worker (approval-auto-merge.py) goes on only from a run that
succeeded, or from a skipped run on a scope that changes no source. Every
other state holds the merge, and so does an answer that cannot be read.
Nothing here contacts GitHub: the worker reads, these functions decide.

Status and conclusion values are the ones GitHub documents for a check run
(https://docs.github.com/en/rest/checks/runs, read 2026-11-14). A value outside
them is `Unreadable`, never a guess.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Literal, assert_never, cast

TYPE_CHECK = 'type-check'  # the job name in .github/workflows/pr-type-check.yml
ACTIONS_APP = 'github-actions'
CHECK_RUN_PAGE = 100
# GitHub lists at most this many files in one comparison. A list this long
# may be cut, so it cannot show that a scope changes no source.
COMPARE_FILE_LIMIT = 300

type Pending = Literal['queued', 'in_progress', 'waiting', 'requested', 'pending']
type Unsuccessful = Literal['action_required', 'cancelled', 'failure', 'neutral', 'stale',
                            'timed_out']


@dataclass(frozen=True, slots=True)
class Absent:
    """GitHub Actions has reported no `type-check` run on the commit."""


@dataclass(frozen=True, slots=True)
class Unfinished:
    """The newest run has not ended. It can still end `skipped`."""

    run: int
    status: Pending


@dataclass(frozen=True, slots=True)
class Succeeded:
    """The newest run compiled the commit."""

    run: int


@dataclass(frozen=True, slots=True)
class Skipped:
    """The newest run ended without compiling anything."""

    run: int


@dataclass(frozen=True, slots=True)
class Refused:
    """The newest run ended, and neither compiled the commit nor skipped it."""

    run: int
    conclusion: Unsuccessful


@dataclass(frozen=True, slots=True)
class Unreadable:
    """The answer does not have the shape or the values GitHub documents."""

    reason: str


type CheckState = Absent | Unfinished | Succeeded | Skipped | Refused | Unreadable


@dataclass(frozen=True, slots=True)
class Ancestry:
    """One page of `compare/{lower}...{top}`."""

    behind_by: int  # commits of `lower` that `top` does not hold
    commits: frozenset[str]  # commits of `top` that `lower` does not hold, this page


def _fields(value: object) -> dict[str, object] | None:
    """A JSON object as a dict, or None for any other JSON value."""
    if not isinstance(value, dict):
        return None
    return {key: item for key, item in cast('dict[object, object]', value).items()
            if isinstance(key, str)}


def _items(value: object) -> list[object] | None:
    return cast('list[object]', value) if isinstance(value, list) else None


def _integer(value: object) -> int | None:
    """A JSON integer. `True` is an int in Python; refuse it."""
    return None if isinstance(value, bool) or not isinstance(value, int) else value


def classify(listing: object, head: str) -> CheckState:
    """The state of the newest `type-check` run GitHub Actions reported on `head`.

    `listing` is the answer of `commits/{head}/check-runs`. A commit can carry
    several runs: one per pull request event, and one per workflow_dispatch
    run of the same workflow on the branch. A run of another name, commit or
    app is not ours and is passed over; a run whose fields cannot be read
    makes the whole listing unreadable, because it could be the newest.
    """
    fields = _fields(listing)
    runs = _items(fields.get('check_runs')) if fields is not None else None
    total = _integer(fields.get('total_count')) if fields is not None else None
    if runs is None or total is None:
        return Unreadable('the check-run listing has no check_runs list or total_count')
    if total > len(runs):
        return Unreadable(f'{head[:12]} has more than {CHECK_RUN_PAGE} {TYPE_CHECK} runs')
    newest: tuple[int, object, object] | None = None
    for row in runs:
        run = _fields(row)
        app = _fields(run.get('app')) if run is not None else None
        if run is None or app is None:
            return Unreadable('a check run is not an object that names its app')
        number, name, commit, slug = (_integer(run.get('id')), run.get('name'),
                                      run.get('head_sha'), app.get('slug'))
        if (number is None or not isinstance(name, str) or not isinstance(commit, str) or
                not isinstance(slug, str)):
            return Unreadable('a check run lacks its id, name, head_sha or app slug')
        if name != TYPE_CHECK or commit != head or slug != ACTIONS_APP:
            continue
        if newest is None or number > newest[0]:
            newest = (number, run.get('status'), run.get('conclusion'))
    if newest is None:
        return Absent()
    number, status, conclusion = newest
    if not isinstance(status, str):
        return Unreadable(f'run {number} has the status {status!r}')
    match status:
        case 'completed':
            pass
        case 'queued' | 'in_progress' | 'waiting' | 'requested' | 'pending':
            return Unfinished(number, status)
        case _:
            return Unreadable(f'run {number} has the status {status!r}')
    if not isinstance(conclusion, str):
        return Unreadable(f'completed run {number} has the conclusion {conclusion!r}')
    match conclusion:
        case 'success':
            return Succeeded(number)
        case 'skipped':
            return Skipped(number)
        case 'action_required' | 'cancelled' | 'failure' | 'neutral' | 'stale' | 'timed_out':
            return Refused(number, conclusion)
        case _:
            return Unreadable(f'completed run {number} has the conclusion {conclusion!r}')


def _unproven_skip(compared: object, head: str, is_source: Callable[[str], bool]) -> str | None:
    """Why the files of `compare/{destination}...{head}` do not show a scope
    without sources, or None when they do. A moved file counts under both of
    its names."""
    remedy = (f'run the pr-type-check workflow on the branch with workflow_dispatch; '
              f'it compiles {head[:12]} without asking what changed')
    fields = _fields(compared)
    files = _items(fields.get('files')) if fields is not None else None
    if files is None:
        return f'{TYPE_CHECK} was skipped and the comparison lists no files; {remedy}'
    if len(files) >= COMPARE_FILE_LIMIT:
        return (f'{TYPE_CHECK} was skipped and the scope changes {COMPARE_FILE_LIMIT} files '
                f'or more, too many to list; {remedy}')
    for row in files:
        changed = _fields(row)
        name = changed.get('filename') if changed is not None else None
        previous = changed.get('previous_filename') if changed is not None else None
        if not isinstance(name, str) or not (previous is None or isinstance(previous, str)):
            return f'{TYPE_CHECK} was skipped and a changed file has no readable name; {remedy}'
        for path in (name, previous):
            if path is not None and is_source(path):
                return f'{TYPE_CHECK} was skipped but the scope changes {path}; {remedy}'
    return None


def hold_reason(state: CheckState, head: str, compared: Callable[[], object],
                is_source: Callable[[str], bool]) -> str | None:
    """Why the worker must not reserve or request a merge of `head`, or None.

    `skipped` satisfies the required check, and it has two meanings: this
    scope changes no source, or the pull request was a lower layer of a native
    stack and left the check to the stack's top. The second meaning stops being
    true when the pull request leaves the stack, and no event runs the check
    again. So a skipped check is trusted only when the worker sees for itself
    that the scope changes no source; `compared` reads that scope and is
    called for a skipped run only.

    A run that has not ended can still end `skipped`, and GitHub would then
    merge a reservation on it. The worker therefore waits for the end itself;
    the scheduled sweep runs it again.
    """
    match state:
        case Succeeded():
            return None
        case Skipped():
            return _unproven_skip(compared(), head, is_source)
        case Absent():
            return f'{TYPE_CHECK} has not been reported on {head[:12]}'
        case Unfinished(status=status):
            return f'{TYPE_CHECK} is {status} on {head[:12]}; it can still end skipped'
        case Refused(conclusion=conclusion):
            return f'{TYPE_CHECK} ended {conclusion} on {head[:12]}'
        case Unreadable(reason=reason):
            return f'{TYPE_CHECK} on {head[:12]} cannot be read: {reason}'
        case _:
            assert_never(state)


def ancestry(compared: object) -> Ancestry | None:
    """One page of a comparison, or None when it cannot be read."""
    fields = _fields(compared)
    behind = _integer(fields.get('behind_by')) if fields is not None else None
    commits = _items(fields.get('commits')) if fields is not None else None
    if behind is None or commits is None:
        return None
    listed: set[str] = set()
    for row in commits:
        commit = _fields(row)
        name = commit.get('sha') if commit is not None else None
        if not isinstance(name, str):
            return None
        listed.add(name)
    return Ancestry(behind, frozenset(listed))
