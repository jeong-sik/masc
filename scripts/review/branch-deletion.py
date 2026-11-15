"""Why a branch that a merge left behind stays, or nothing when it may go.

The merge worker deletes the head branch of a pull request it merged
(approval-auto-merge.py), and the sweep deletes the branches merges still
left behind (approval-merge-sweep.py). Both ask here, so a branch one of them
keeps, the other keeps too (#51677). Each reads the inputs its own way: the
sweep lists every branch once, the worker reads the one branch it merged.
"""
from __future__ import annotations

from collections.abc import Callable
from urllib.parse import quote


def kept_by_rule(name: str, default: str, protected: bool) -> str | None:
    """Why branch `name` stays whatever its pull requests are, or None.

    `default` is the repository's default branch and `protected` says whether
    a protection rule or a ruleset applies to the branch, both as GitHub
    answered the caller. A long-lived branch is never guessed from its name.
    """
    if name == default:
        return 'the default branch'
    if name == 'main' or name.startswith('release/'):
        return 'protected branch name'
    if protected:
        return 'a protection rule or a ruleset applies to it'
    return None


def kept_by_open_pull(repo: str, name: str, read: Callable[[str], object]) -> str | None:
    """Why branch `name` stays because an open pull request uses it, or None.

    `read` answers one REST path from GitHub at this moment. The open pull
    requests are asked by head (`owner:name`) and by base right before the
    delete: a listing read earlier misses a pull request opened since. A read
    that fails raises; it never stands for "no pull request".
    """
    owner = repo.split('/')[0]
    for side, value in (('head', f'{owner}:{name}'), ('base', name)):
        listed = read(f'repos/{repo}/pulls?state=open&{side}={quote(value, safe="")}'
                      '&per_page=1')
        if not isinstance(listed, list):
            raise ValueError(f'the open pull requests by {side} are not a list')
        if listed:
            return f'open pull request #{listed[0]["number"]} has it as {side}'
    return None
