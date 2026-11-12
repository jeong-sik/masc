#!/usr/bin/env python3
# pyright: strict
"""Decide whether a pull request needs `dune build @check`.

The `changes` job of .github/workflows/pr-type-check.yml runs this against a
blobless fetch of the pull request's merge commit. It prints `true` or `false`
on stdout and the reason on stderr. Any git failure exits non-zero, so the job
goes red instead of skipping the type-check.

A native stack is type-checked once, at its top pull request (RFC
stack-type-check-runs-at-the-top):

  no stack in the payload   the files this pull request changes decide
  position < size           false; the top pull request checks the stack
  position == size          the files the whole stack changes decide
  stack of an unknown shape as if there were no stack

Only "position < size" checks less than a pull request on its own would.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable, assert_never, cast

_SHA = re.compile(r"[0-9a-f]{40}")
_SOURCE_SUFFIXES = (".ml", ".mli", ".inc", ".opam")
_SOURCE_PREFIXES = (".github/actions/",)
# The workflow, this script and its tests are sources too: the type-check job
# is the one pull request job with a checkout, so it runs these tests, and a
# change to any of the three must start it.
_SOURCE_PATHS = frozenset({
    "dune-project",
    ".github/workflows/pr-type-check.yml",
    "scripts/ci/pr_source_changes.py",
    "scripts/ci/test_pr_source_changes.py",
})
_DUNE = "dune"
# docs/evidence keeps .ml snapshots as data. No dune file under docs/ builds
# them, so a docs-only change needs no type-check.
_DATA_PREFIX = "docs/"


@dataclass(frozen=True, slots=True)
class Alone:
    """No usable stack: this pull request's own changes decide."""

    reason: str


@dataclass(frozen=True, slots=True)
class Lower:
    """A layer below the top of a stack: the top pull request checks it."""

    stack: int


@dataclass(frozen=True, slots=True)
class Top:
    """The top of a stack: everything since the stack's base decides."""

    stack: int
    base_sha: str


type Plan = Alone | Lower | Top


def is_source(path: str) -> bool:
    """True when a change to `path` can change what `dune build @check` reads.

    The root `dune` file builds every tracked directory, so sources are matched
    repository-wide (#48323). A change to the reusable actions, to the
    workflow or to this script must be checked by the workflow.
    """
    if path.startswith(_DATA_PREFIX):
        return False
    return (
        path.endswith(_SOURCE_SUFFIXES)
        or path.startswith(_SOURCE_PREFIXES)
        or path in _SOURCE_PATHS
        or path.rsplit("/", 1)[-1] == _DUNE
    )


def needs_type_check(paths: Iterable[str]) -> bool:
    return any(is_source(path) for path in paths)


def _field(value: object, name: str) -> object:
    """`value[name]` when `value` is a JSON object that has it, else None."""
    if not isinstance(value, dict):
        return None
    for key, item in cast("dict[object, object]", value).items():
        if key == name:
            return item
    return None


def _count(value: object) -> int | None:
    """A JSON integer of at least 1. `True` is an int in Python; refuse it."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        return None
    return value


def plan(raw_stack: str) -> Plan:
    """Read the payload's `stack` (JSON text; empty or `null` when absent)."""
    if raw_stack.strip() in ("", "null"):
        return Alone("the payload has no stack")
    try:
        stack: object = json.loads(raw_stack)
    except json.JSONDecodeError:
        return Alone("the payload stack is not JSON")
    number = _count(_field(stack, "number"))
    position = _count(_field(stack, "position"))
    size = _count(_field(stack, "size"))
    if number is None or position is None or size is None or position > size:
        return Alone("the payload stack has no usable number, position and size")
    if position < size:
        return Lower(number)
    sha = _field(_field(stack, "base"), "sha")
    if not isinstance(sha, str) or _SHA.fullmatch(sha) is None:
        return Alone("the payload stack has no base.sha")
    return Top(number, sha)


def _git(git_dir: str, *args: str) -> str:
    done = subprocess.run(
        ["git", "-C", git_dir, *args], check=True, stdout=subprocess.PIPE, text=True
    )
    return done.stdout


def changed_paths(git_dir: str, old: str, new: str) -> tuple[str, ...]:
    """Paths that differ between two trees. --no-renames lists a moved file
    under both names and needs no file contents, which a blobless fetch does
    not have."""
    out = _git(git_dir, "diff", "--name-only", "--no-renames", "-z", old, new)
    return tuple(path for path in out.split("\0") if path)


def fetch_commit(git_dir: str, remote: str, sha: str) -> None:
    _git(git_dir, "fetch", "-q", "--depth=1", "--filter=blob:none", remote, sha)


def decide(git_dir: str, remote: str, merge: str, chosen: Plan) -> tuple[bool, str]:
    match chosen:
        case Alone(reason):
            paths = changed_paths(git_dir, f"{merge}^1", merge)
            return needs_type_check(paths), f"{reason}; {len(paths)} files in this pull request"
        case Lower(stack):
            return False, f"stack #{stack}: the top pull request checks every layer"
        case Top(stack, base_sha):
            fetch_commit(git_dir, remote, base_sha)
            paths = changed_paths(git_dir, base_sha, merge)
            return needs_type_check(paths), (
                f"top of stack #{stack}; {len(paths)} files since {base_sha[:12]}"
            )
        case _:
            assert_never(chosen)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git-dir", required=True, help="repository holding the merge commit")
    parser.add_argument("--remote", required=True, help="remote to fetch the stack base from")
    parser.add_argument("--merge", required=True, help="the pull request's merge commit")
    args = parser.parse_args()
    git_dir: str = args.git_dir
    remote: str = args.remote
    merge: str = args.merge
    if _SHA.fullmatch(merge) is None:
        parser.error("--merge must be a full commit sha")
    src, reason = decide(git_dir, remote, merge, plan(os.environ.get("STACK_JSON", "")))
    print(f"src={'true' if src else 'false'}: {reason}", file=sys.stderr)
    print("true" if src else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
