"""Tests of check_wake_scoring.py on a fixture cut from a real head, plus mutations of the scorer.

    python3 -I docs/evidence/check-wake-harness-2026-11/test_check_wake_scoring.py

The fixture is the run list of the head of jeong-sik/masc#51286 as GitHub held it at 2026-11-11T09:5xZ,
with times in seconds from the first run (09:34:28Z). Two approval runs end before a review run is made,
which ends before the check runs (`pull_request`) are made; the first `PR type-check` was cancelled and a
second one made 22 s after it. Every `end_at` is the run's `updated_at`.
"""

from __future__ import annotations

import pathlib
import sys
import types
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import check_wake_scoring as scoring  # noqa: E402

APPROVAL = "Approval merge request"
RUNS_51286 = (
    scoring.Run(1, APPROVAL, "pull_request_target", 0.0, 9.0),
    scoring.Run(2, APPROVAL, "pull_request_target", 2.0, 14.0),
    scoring.Run(3, APPROVAL, "pull_request_review", 67.0, 73.0),
    scoring.Run(4, "Changelog fragments", "pull_request", 77.0, 100.0),
    scoring.Run(5, "PR type-check", "pull_request", 77.0, 103.0),
    scoring.Run(6, "Changelog fragments", "pull_request", 99.0, 128.0),
    scoring.Run(7, "PR type-check", "pull_request", 99.0, 588.0),
    scoring.Run(8, APPROVAL, "pull_request_review", 111.0, 131.0),
)
RUNNING = scoring.Run(9, "PR type-check", "pull_request", 99.0, None)


def check_all(module: types.ModuleType) -> None:
    """The assertions of this file against `module`; raises AssertionError on the first that fails."""
    runs = RUNS_51286
    found = module.gaps(runs)
    assert [g.run_id for g in found] == [3, 4], found
    assert found[0].length_s == 53.0 and found[1].length_s == 4.0, found
    assert [g.run_id for g in module.gaps_before_a_check_run(runs)] == [3, 4]
    assert module.gaps_before_a_check_run(runs[:3]) == ()
    assert module.gaps(tuple(r for r in runs if r.event in module.CHECK_EVENTS)) == ()

    assert module.finish_of(runs) == 588.0
    assert module.finish_of(runs + (RUNNING,)) is None
    assert module.finish_of(()) is None
    assert module.gaps((module.Run(1, "a", "push", 0.0, None), module.Run(2, "b", "push", 50.0, 60.0))) == ()

    early = module.score_wake(75.0, runs)
    assert early.false_wake is False and early.late_s == 2.0, early
    assert early.check_runs_after_wake == (4, 5, 6, 7), early
    false = module.score_wake(100.0, runs)
    assert false.false_wake is True and false.late_s is None, false
    done = module.score_wake(590.0, runs)
    assert done.false_wake is False and done.late_s == 2.0 and done.check_runs_after_wake == (), done
    after_review = module.score_wake(588.0, runs[:7] + (module.Run(8, APPROVAL, "pull_request_review", 600.0, 620.0),))
    assert after_review.check_runs_after_wake == (), after_review

    assert module.is_missed(True, 600.0, runs) is True
    assert module.is_missed(True, 400.0, runs) is False
    assert module.is_missed(False, 600.0, runs) is False

    # Boundaries. A run made the instant the last one ended leaves no gap.
    touching = (module.Run(1, "a", "push", 0.0, 10.0), module.Run(2, "b", "push", 10.0, 20.0))
    assert module.gaps(touching) == ()
    # A wake at the instant a run is made sees that run, still running.
    at_creation = module.score_wake(10.0, (module.Run(1, "a", "push", 0.0, 5.0), module.Run(2, "b", "push", 10.0, None)))
    assert at_creation.false_wake is True, at_creation
    # The run made right after a gap is itself a check run: the gap is before a check run.
    own = (module.Run(1, "x", "pull_request_target", 0.0, 10.0), module.Run(2, "c", "pull_request", 20.0, 30.0))
    assert [g.run_id for g in module.gaps_before_a_check_run(own)] == [2]
    # A watch due the instant the runs ended was missed.
    assert module.is_missed(True, 20.0, touching) is True


class ScoringTest(unittest.TestCase):
    def test_fixture(self) -> None:
        check_all(scoring)


# Each pair edits the source of check_wake_scoring.py once. `check_all` must fail on the edited module.
MUTATIONS = (
    ("latest_end < run.created_at", "latest_end <= run.created_at"),
    ("return max(run.end_at for run in runs if run.end_at is not None)", "return min(run.end_at for run in runs if run.end_at is not None)"),
    ("known = tuple(run for run in runs if run.created_at <= wake_ts)", "known = tuple(run for run in runs if run.created_at < wake_ts)"),
    ("run.event in CHECK_EVENTS and run.created_at >= gap.closed_at", "run.event in CHECK_EVENTS and run.created_at > gap.closed_at"),
    ("run.created_at > wake_ts and run.event in CHECK_EVENTS", "run.created_at > wake_ts"),
    ("latest_end = max(latest_end, math.inf if run.end_at is None else run.end_at)", "latest_end = max(latest_end, 0.0 if run.end_at is None else run.end_at)"),
    ("return done is not None and done <= due_ts", "return done is not None and done < due_ts"),
    ("CHECK_EVENTS = frozenset({\"push\", \"pull_request\", \"workflow_run\"})", "CHECK_EVENTS = frozenset({\"push\", \"pull_request\", \"workflow_run\", \"pull_request_review\"})"),
)


class MutationTest(unittest.TestCase):
    def test_every_mutation_is_caught(self) -> None:
        source = pathlib.Path(scoring.__file__).read_text(encoding="utf-8")
        for old, new in MUTATIONS:
            with self.subTest(old=old):
                self.assertEqual(source.count(old), 1, "the mutation target must occur once")
                module = types.ModuleType("mutated_check_wake_scoring")
                sys.modules[module.__name__] = module  # dataclasses reads annotations through sys.modules
                try:
                    exec(compile(source.replace(old, new), "mutated", "exec"), module.__dict__)  # noqa: S102
                    with self.assertRaises(AssertionError):
                        check_all(module)
                finally:
                    del sys.modules[module.__name__]


if __name__ == "__main__":
    unittest.main()
