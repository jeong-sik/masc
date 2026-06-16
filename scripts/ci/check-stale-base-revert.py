#!/usr/bin/env python3
"""Stale-base revert guard (RFC-0235).

Fails a PR when it is about to *silently revert* recently-merged work
because it was computed against a stale base.

Background (the defect this blocks)
-----------------------------------
On 2026-06-12, PR #20869 (titled "test(otel): fix ...") was branched
from a base that predated three sibling PRs (#20853, #20859, #20848)
which had merged ~3.5h earlier. Its branch still carried the *old*
versions of the files those PRs touched. Because GitHub does not
require a branch to be up to date before merging, squash-merging #20869
landed those stale files on main and dropped the siblings' additions
(e.g. it removed the entire `Dated_jsonl` telemetry-persistence block
that #20853 had added — 19 of 19 lines). Nothing flagged it: git did
not report a conflict, and the misleading title hid the regression.

The signal
----------
The danger is not "the PR removes lines" — it is "main added lines to a
file *since this branch diverged*, and the branch's version of that file
does **not** contain them". Merging then drops those lines. So for every
file the PR modifies that main *also* modified since the merge-base, we
check whether the lines main added are present in the PR's head version.
A run of significant added-on-main lines missing from the PR head is a
stale-base revert.

Remedy
------
Rebase onto current main. That advances the merge-base past the sibling
commits, so `merge-base..base` no longer contains their additions and
the guard passes. The remedy is always available and never a dead end —
which is why this guard blocks rather than merely warns.

Intentional reverts (the rare legitimate case) opt out with the PR label
`stale-base-ack` (passed in via the PR_LABELS env var).

This is a deterministic structural check on git objects, not a content
classifier or a telemetry counter: it blocks the actual defect before
merge.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from dataclasses import dataclass

# A file fails the guard when at least this many *significant*
# added-on-main lines are absent from the PR's head version. The
# 2026-06-12 incident reversed 19 such lines; a handful is already a
# strong, unambiguous signal while leaving room for incidental overlap
# on small legitimate edits. Tunable; see RFC-0235 §Threshold.
REVERT_LINE_THRESHOLD = 5

# Lines shorter than this (after trimming) collide across unrelated code
# (`in`, `()`, `let () =`, closing braces) and carry no revert signal, so
# they are excluded from the count.
MIN_SIGNIFICANT_LEN = 10

# Opt-out label for an intentional revert / deliberate stale-base merge.
ACK_LABEL = "stale-base-ack"


def _run(args: list[str]) -> str:
    """Run a git command, returning stdout. Raises on non-zero exit."""
    result = subprocess.run(
        args, capture_output=True, text=True, check=True
    )
    return result.stdout


def _run_ok(args: list[str]) -> tuple[int, str]:
    """Run a git command, returning (exit_code, stdout). Never raises."""
    result = subprocess.run(args, capture_output=True, text=True)
    return result.returncode, result.stdout


def _is_significant(trimmed: str) -> bool:
    """A line carries revert signal when it is long enough to be specific
    and contains an actual identifier/word (not just punctuation)."""
    if len(trimmed) < MIN_SIGNIFICANT_LEN:
        return False
    return any(c.isalnum() for c in trimmed)


def added_lines_on_main(merge_base: str, base: str, path: str) -> set[str]:
    """Significant lines that `merge_base..base` adds to `path` (i.e. the
    work merged onto main since this branch diverged)."""
    diff = _run(["git", "diff", "--unified=0", merge_base, base, "--", path])
    added: set[str] = set()
    for line in diff.splitlines():
        if line.startswith("+++"):
            continue
        if line.startswith("+"):
            trimmed = line[1:].strip()
            if _is_significant(trimmed):
                added.add(trimmed)
    return added


def head_file_line_set(head: str, path: str) -> set[str]:
    """Trimmed line set of `path` at `head`. Empty if the file does not
    exist there (e.g. the PR deleted it — itself a possible revert)."""
    code, content = _run_ok(["git", "show", f"{head}:{path}"])
    if code != 0:
        return set()
    return {ln.strip() for ln in content.splitlines()}


def changed_files(rev_a: str, rev_b: str) -> set[str]:
    out = _run(["git", "diff", "--name-only", rev_a, rev_b])
    return {ln for ln in out.splitlines() if ln}


@dataclass(frozen=True)
class Reversal:
    path: str
    missing: tuple[str, ...]
    commits: str  # `git log --oneline merge_base..base -- path`


def detect(merge_base: str, base: str, head: str) -> list[Reversal]:
    """Files the PR modifies whose recently-added-on-main lines are
    missing from the PR head, above the threshold."""
    candidates = changed_files(merge_base, head) & changed_files(
        merge_base, base
    )
    reversals: list[Reversal] = []
    for path in sorted(candidates):
        added = added_lines_on_main(merge_base, base, path)
        if not added:
            continue
        head_lines = head_file_line_set(head, path)
        missing = sorted(l for l in added if l not in head_lines)
        if len(missing) >= REVERT_LINE_THRESHOLD:
            commits = _run(
                ["git", "log", "--oneline", f"{merge_base}..{base}", "--", path]
            ).strip()
            reversals.append(
                Reversal(path=path, missing=tuple(missing), commits=commits)
            )
    return reversals


def _labels_from_env() -> set[str]:
    raw = os.environ.get("PR_LABELS", "")
    return {l.strip() for l in raw.split(",") if l.strip()}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base",
        required=True,
        help="Base SHA (the PR target tip, e.g. pull_request.base.sha).",
    )
    parser.add_argument(
        "--head", default="HEAD", help="Head ref of the PR branch."
    )
    args = parser.parse_args(argv)

    code, mb = _run_ok(["git", "merge-base", args.base, args.head])
    if code != 0:
        # No common ancestor reachable (shallow clone, unrelated history).
        # Fail loud rather than silently no-op: a guard that cannot see the
        # history it needs must say so. CI checks out with fetch-depth: 0.
        print(
            "stale-base guard: cannot compute merge-base of "
            f"{args.base!r} and {args.head!r}; "
            "ensure the workflow checks out with fetch-depth: 0.",
            file=sys.stderr,
        )
        return 2
    merge_base = mb.strip()

    reversals = detect(merge_base, args.base, args.head)
    if not reversals:
        print("stale-base guard: no stale-base reversal detected.")
        return 0

    labels = _labels_from_env()
    acked = ACK_LABEL in labels

    print(
        "stale-base guard: this branch is missing lines that main added "
        "to files it also modifies — merging would silently revert them.\n"
    )
    for r in reversals:
        print(f"  {r.path}: {len(r.missing)} added-on-main line(s) absent "
              "from this branch")
        if r.commits:
            print("    added by:")
            for c in r.commits.splitlines():
                print(f"      {c}")
        print("    e.g. missing line(s):")
        for sample in r.missing[:3]:
            print(f"      + {sample}")
        print()

    print(
        "Remedy: rebase this branch onto current main "
        "(`git fetch origin main && git rebase origin/main`). That advances "
        "the merge-base past the commit(s) above, so the lines are no longer "
        "'added since you branched' and the guard passes.\n"
        f"Intentional revert? Add the `{ACK_LABEL}` label to acknowledge."
    )

    if acked:
        print(
            f"\nstale-base guard: `{ACK_LABEL}` label present — "
            "reversal acknowledged, passing.",
            file=sys.stderr,
        )
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
