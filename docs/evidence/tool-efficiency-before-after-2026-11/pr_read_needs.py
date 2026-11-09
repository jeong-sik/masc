#!/usr/bin/env python3
"""Which of the pull request reads Keepers make with `gh` the open pull request snapshot could answer.

The server snapshot (`Repository_pulls`, read by `keeper_pull_requests_list`) holds, for each open pull
request: the number, the title, the draft flag, the state of the checks, the review decision, whether it
merges cleanly, the head commit, the last review of each account (account, verdict, commit) and the git author
of the newest commit. This script counts, among the Execute calls that `pr_state_reads.py` counts as PR reads,
the calls whose command text names none of the facts below. Those calls ask for nothing but snapshot facts, so
the snapshot could have answered them. The other calls name at least one fact the snapshot lacks.

Reads, and never writes, the ledger files that `measure_before_after.py` reads.

Definitions:

- PR read, command text, shape, hours: as in `pr_state_reads.py`.
- need: something the snapshot lacks, or something no read answers. A call names a need when its command text
  matches the pattern of the need:
  `closed_or_merged` (`.merged`, `merged_at`, `mergedAt`, `mergeCommit`, `--state closed|merged|all`),
  `check_detail` (`statusCheckRollup`, `gh pr checks`, `check-runs`), `ci_run_or_main_tip` (`actions/runs`,
  `actions/workflows`, `gh run`, `commits/main`, `git fetch|log|rev-parse`), `times` (`updated_at`,
  `created_at`, `submitted_at`, `sort=updated` and their camel case), `body_or_comments`, `files_or_diff`
  (`/files`, `gh pr diff`, a diff `Accept` header), `labels_or_requests`, `refs_or_author_login` (base and
  head names, the login of the author of the pull request), `merge_state_detail` (`mergeable_state`,
  `mergeStateStatus`), `search` and `writes` (a `POST|PUT|PATCH|DELETE` method, a `-f` or `-F` field on a call
  that is neither GET nor GraphQL, `gh pr merge|review|comment|edit|ready|close|reopen`, a GraphQL mutation;
  a call that posts a review reads the head first, but the post is what the call is for). The patterns are in
  `NEEDS`.
- snapshot only: a PR read that names no need.
- only: a PR read that names exactly one need. These are the hours a single new column would free.

The match is on text, as in `pr_state_reads.py`, so `snapshot_only` is an estimate with errors in both
directions. A call that only quotes a need counts as naming it, which makes the estimate too low. A call that
names none may still ask for something the patterns do not know, which makes it too high. It does not say a
Keeper would have used the tool for these calls.

Output: `pr_reads` the calls and hours of all PR reads, `snapshot_only` the same for the calls that name no need
(with the share of the PR read hours and of the Execute hours, the shapes, and the six Keepers with the most
hours), `named` the calls and hours that name each need (a call can name several, so these overlap) and `only`
the calls and hours that name exactly that need.

Usage:
    python3 docs/evidence/tool-efficiency-before-after-2026-11/pr_read_needs.py \
        --base-path ~/me --since 2026-11-06T00:00:00 --end 2026-11-09T00:00:00 \
        --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-pr-read-needs-2026-11-06_11-08.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import re
import sys
from collections import defaultdict
from collections.abc import Iterable, Sequence
from typing import cast

import measure_before_after as ledger
import pr_state_reads as reads

TOP_KEEPERS = 6
SHARE_DIGITS = 4

# `gh api` sends a POST when it gets a `-f` or `-F` field, unless the call asks for GET or goes to GraphQL, where
# the fields are the variables of a query. The lookahead at `\A` looks at the whole text for either.
FIELD_SENT = (
    r"\A(?![\s\S]*(?:(?:-X|--method)[ =]*GET\b|\bgh\s+api\s+graphql\b))"
    r"[\s\S]*?\s(?:-f|-F|--field|--raw-field)[ =]+\w+="
)
WRITES = (
    r"(?:-X|--method)[ =]*(?:POST|PUT|PATCH|DELETE)\b"
    r"|\bgh\s+pr\s+(?:merge|review|comment|edit|ready|close|reopen)\b"
    r"|\bmutation\b"
    "|" + FIELD_SENT
)

NEEDS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "closed_or_merged",
        re.compile(
            r"\.merged\b|merged_at|mergedAt|mergeCommit|merge_commit"
            r"|--state[ =]+(?:closed|merged|all)\b|state=(?:closed|all)\b"
        ),
    ),
    ("check_detail", re.compile(r"statusCheckRollup|\bgh\s+pr\s+checks\b|check-runs|check_runs")),
    (
        "ci_run_or_main_tip",
        re.compile(r"actions/runs|actions/workflows|\bgh\s+run\b|commits/main|\bgit\s+(?:fetch|log|rev-parse)\b"),
    ),
    ("times", re.compile(r"updated_at|updatedAt|created_at|createdAt|submitted_at|submittedAt|sort=updated")),
    ("body_or_comments", re.compile(r"\.body\b|--json[ =]+\S*\bbody\b|comments|/issues/")),
    (
        "files_or_diff",
        re.compile(
            r"/files\b|changedFiles|\badditions\b|\bdeletions\b|\.patch\b|\bgh\s+pr\s+diff\b"
            r"|vnd\.github[.\w]*\.(?:diff|patch)|/compare/"
        ),
    ),
    ("labels_or_requests", re.compile(r"\blabels\b|\bassignees\b|requested_reviewers|requested_teams|reviewRequests")),
    (
        "refs_or_author_login",
        re.compile(
            r"baseRefName|headRefName|base\.ref|head\.ref|\.user\b|author\.login"
            r"|--json[ =]+\S*\bauthor\b|--(?:author|head|base)\b"
        ),
    ),
    ("merge_state_detail", re.compile(r"mergeable_state|mergeStateStatus")),
    ("search", re.compile(r"--search|search/")),
    ("writes", re.compile(WRITES, re.IGNORECASE)),
)


@dataclasses.dataclass(frozen=True, slots=True)
class Read:
    keeper: str
    shape: str
    held_ms: float
    needs: tuple[str, ...]


@dataclasses.dataclass(frozen=True, slots=True)
class Scan:
    execute_calls: int
    execute_ms: float
    reads: list[Read]


def needs_of(text: str) -> tuple[str, ...]:
    """The needs a command text names, in the order of `NEEDS`."""
    return tuple(name for name, pattern in NEEDS if pattern.search(text) is not None)


def scan(calls: Iterable[ledger.Call]) -> Scan:
    """Execute calls, and the PR reads among them with the needs they name."""
    execute_calls = 0
    execute_ms = 0.0
    found: list[Read] = []
    for call in calls:
        if call.tool != ledger.EXECUTE:
            continue
        execute_calls += 1
        execute_ms += call.duration_ms
        text = reads.command_text(call.input_text)
        if reads.PR_READ.search(text) is not None:
            found.append(Read(call.keeper, reads.shape_of(text), call.duration_ms, needs_of(text)))
    return Scan(execute_calls, execute_ms, found)


def share(part: float, whole: float) -> float | None:
    return round(part / whole, SHARE_DIGITS) if whole > 0 else None


def held_ms(items: Sequence[Read]) -> float:
    return sum(item.held_ms for item in items)


def tally(items: Sequence[Read]) -> dict[str, object]:
    return {"calls": len(items), "hours": ledger.hours(held_ms(items))}


def keeper_row(keeper: str, items: Sequence[Read]) -> dict[str, object]:
    return {"keeper": keeper, **tally(items)}


def summarize(found: Scan) -> dict[str, object]:
    snapshot_only = [read for read in found.reads if not read.needs]
    by_keeper: defaultdict[str, list[Read]] = defaultdict(list)
    for read in snapshot_only:
        by_keeper[read.keeper].append(read)
    ranked = sorted(by_keeper.items(), key=lambda item: (-held_ms(item[1]), item[0]))
    return {
        "execute_calls": found.execute_calls,
        "execute_hours": ledger.hours(found.execute_ms),
        "pr_reads": tally(found.reads),
        "snapshot_only": {
            **tally(snapshot_only),
            "share_of_pr_read_hours": share(held_ms(snapshot_only), held_ms(found.reads)),
            "share_of_execute_hours": share(held_ms(snapshot_only), found.execute_ms),
            "by_shape": {
                shape: tally([read for read in snapshot_only if read.shape == shape]) for shape in reads.SHAPES
            },
            "top_keepers": [keeper_row(keeper, items) for keeper, items in ranked[:TOP_KEEPERS]],
        },
        "named": {name: tally([read for read in found.reads if name in read.needs]) for name, _ in NEEDS},
        "only": {name: tally([read for read in found.reads if read.needs == (name,)]) for name, _ in NEEDS},
    }


def measure(base: pathlib.Path, since: datetime.datetime, end: datetime.datetime) -> dict[str, object]:
    first = since.timestamp()
    last = end.timestamp()
    skipped = ledger.Skipped()
    paths = ledger.ledger_files(base, since, end)
    found = scan(ledger.read_calls(paths, first, last, skipped))
    return {
        "window": [ledger.stamp(first), ledger.stamp(last)],
        "files": len(paths),
        "skipped": {"bad_lines": skipped.bad_lines},
        **summarize(found),
    }


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="UTC, like 2026-11-06T00:00:00")
    parser.add_argument("--end", required=True, help="UTC, like 2026-11-09T00:00:00")
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since = ledger.parse_instant(cast("str", args.since))
    end = ledger.parse_instant(cast("str", args.end))
    if end <= since:
        print("--end must come after --since", file=sys.stderr)
        return 2
    if end - since > datetime.timedelta(days=ledger.MAX_DAYS):
        print(f"the span must stay within {ledger.MAX_DAYS} days", file=sys.stderr)
        return 2
    result = measure(cast("pathlib.Path", args.base_path).expanduser(), since, end)
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
