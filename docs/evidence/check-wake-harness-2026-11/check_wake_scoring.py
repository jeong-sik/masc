"""Score a "the checks of this commit ended" wake against the Actions runs GitHub holds for it.

Pure functions over plain data, no I/O. `probe_head_shas.py` fills `Run` from GitHub and
`test_check_wake_scoring.py` fills it by hand. The definitions below are the harness of
docs/rfc/RFC-keeper-wakes-when-a-pr-check-finishes.md section 5.2. A change to the
implementation that this scores must not change this file.

A run is read at the run level: `created_at` is when GitHub made the run and `end_at` is
the `updated_at` of a run whose `status` is `completed`, `None` while it has not completed.
The job level (a job made after the run is `in_progress`) is a finer reading of the same
idea and is not in this file.
"""

from __future__ import annotations

import dataclasses
import math

# The `event` values of the runs that are the checks of a commit: the event that pushed or
# opened it (`push`, `pull_request`) and the one GitHub makes when another workflow ends
# (`workflow_run`). A run made by a review, a label or a hand (`pull_request_review`,
# `pull_request_target`, `workflow_dispatch`, ...) is a new happening, not a check of the
# commit, and does not count against a wake (RFC section 5.2). The names are GitHub's
# documented `event` values; this set is a reading of them made by the harness, not a rule
# of the product.
CHECK_EVENTS = frozenset({"push", "pull_request", "workflow_run"})


@dataclasses.dataclass(frozen=True, slots=True)
class Run:
    run_id: int
    workflow: str
    event: str
    created_at: float
    end_at: float | None


@dataclasses.dataclass(frozen=True, slots=True)
class Gap:
    """An instant where every run made so far had ended and one more run was still to come."""

    run_id: int
    workflow: str
    event: str
    opened_at: float
    closed_at: float

    @property
    def length_s(self) -> float:
        return self.closed_at - self.opened_at


@dataclasses.dataclass(frozen=True, slots=True)
class WakeVerdict:
    false_wake: bool
    late_s: float | None
    check_runs_after_wake: tuple[int, ...]


def finish_of(runs: tuple[Run, ...]) -> float | None:
    """When the last of the runs ended; `None` for no runs or a run that has not ended."""
    if not runs or any(run.end_at is None for run in runs):
        return None
    return max(run.end_at for run in runs if run.end_at is not None)


def gaps(runs: tuple[Run, ...]) -> tuple[Gap, ...]:
    """Every run made after all earlier runs had ended, in the order the runs were made.

    A run that has not ended hides every later run from this reading, because no instant
    after it has all earlier runs ended.
    """
    ordered = sorted(runs, key=lambda run: (run.created_at, run.run_id))
    found: list[Gap] = []
    latest_end = -math.inf
    for index, run in enumerate(ordered):
        if index > 0 and latest_end < run.created_at:
            found.append(
                Gap(run_id=run.run_id, workflow=run.workflow, event=run.event, opened_at=latest_end, closed_at=run.created_at)
            )
        latest_end = max(latest_end, math.inf if run.end_at is None else run.end_at)
    return tuple(found)


def gaps_before_a_check_run(runs: tuple[Run, ...]) -> tuple[Gap, ...]:
    """The gaps after which at least one check run (`CHECK_EVENTS`) was still to be made.

    A watch that wakes at the first instant every run made so far has ended is early at such a
    gap: the checks it waits for had not all been made yet.
    """
    return tuple(
        gap
        for gap in gaps(runs)
        if any(run.event in CHECK_EVENTS and run.created_at >= gap.closed_at for run in runs)
    )


def score_wake(wake_ts: float, runs: tuple[Run, ...]) -> WakeVerdict:
    """Judge a wake that said every run of the commit had ended at `wake_ts`.

    false_wake: a run made at or before `wake_ts` had not ended at `wake_ts`.
    late_s: `wake_ts` minus the end of the last run made at or before it; `None` for a false wake.
    check_runs_after_wake: check runs (`CHECK_EVENTS`) made after `wake_ts`. A wake with any of
    these was early even though every run it could see had ended.
    """
    known = tuple(run for run in runs if run.created_at <= wake_ts)
    false_wake = any(run.end_at is None or run.end_at > wake_ts for run in known)
    done = None if false_wake else finish_of(known)
    later = tuple(
        run.run_id for run in runs if run.created_at > wake_ts and run.event in CHECK_EVENTS
    )
    return WakeVerdict(
        false_wake=false_wake,
        late_s=None if done is None else wake_ts - done,
        check_runs_after_wake=later,
    )


def is_missed(woke_by_due: bool, due_ts: float, runs: tuple[Run, ...]) -> bool:
    """A watch that only woke at its due time while the runs made by then had all ended before it."""
    if not woke_by_due:
        return False
    done = finish_of(tuple(run for run in runs if run.created_at <= due_ts))
    return done is not None and done <= due_ts
