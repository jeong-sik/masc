# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the surface traits of synthetic claims (scripts/tinker/librarian/synth_spec.py).

A label must leave no mark in a claim's dates, times, numbers or length.
`synth_generate` imports the Tinker caller, which imports openai, so this file
runs with `uv run`.
"""

from __future__ import annotations

import datetime as dt
import random
import sys
import unittest
from collections import Counter
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import synth_candidate_plan as C
import synth_generate as G
import synth_spec as S

WHEN = dt.datetime(2026, 10, 14, 5, 30, tzinfo=dt.UTC)


class HoldsTest(unittest.TestCase):
    def test_a_claim_carries_exactly_its_planned_marks(self) -> None:
        planned = S.Surface("2026-10-14", None, "#4521")
        self.assertTrue(S.surface_holds("2026-10-14에 #4521에서 재시도 기준을 정했다.", planned))
        self.assertFalse(S.surface_holds("2026-10-14에 정했다.", planned))
        self.assertFalse(S.surface_holds("2026-10-14 05:30에 #4521에서 정했다.", planned))
        self.assertFalse(S.surface_holds("2026-10-14에 #4521과 #4522에서 정했다.", planned))

    def test_no_marks_means_none_of_any_kind(self) -> None:
        bare = S.Surface(None, None, None)
        self.assertTrue(S.surface_holds("리뷰 큐에 세 건이 쌓여 있어 3시간 뒤 다시 본다.", bare))
        self.assertFalse(S.surface_holds("task-12가 아직 대기 중이다.", bare))
        self.assertFalse(S.surface_holds("재시도는 3-5회까지 한다.", bare))
        self.assertFalse(S.surface_holds("1/3이 실패했다.", bare))
        self.assertFalse(S.surface_holds("14시에 깨운다.", bare))

    def test_an_iso_timestamp_is_a_date_and_a_time(self) -> None:
        self.assertTrue(S.surface_holds("2026-10-14T05:30Z에 본 상태", S.Surface("2026-10-14", "05:30", None)))
        self.assertFalse(S.surface_holds("2026-10-14T05:30Z에 본 상태", S.Surface(None, None, None)))

    def test_date_formats(self) -> None:
        self.assertEqual([S.date_text(WHEN, f) for f, _ in S.DATE_FORMAT_WEIGHTS],
                         ["2026-10-14", "10-14", "10/14", "10월 14일"])
        for form, _ in S.DATE_FORMAT_WEIGHTS:
            self.assertTrue(S.surface_holds(f"{S.date_text(WHEN, form)}에 정했다.",
                                            S.Surface(S.date_text(WHEN, form), None, None)))


class IndependenceTest(unittest.TestCase):
    def test_planted_and_durable_slots_carry_marks_at_the_same_rates(self) -> None:
        keeper = S.KeeperProfile("k", "synth-k", "role", "world", tuple(f"cat_{i}" for i in range(12)),
                                 S.GoalDraft("t", "m", "v"))
        rng = random.Random(20261109)
        plans = [G.plan_memory(rng, keeper, i, True) for i in range(2000)]
        slots = [slot for plan in plans for slot in plan.slots]
        stale = [s.surface for s in slots if s.stale]
        durable = [s.surface for s in slots if not s.stale]
        duplicates = [plan.duplicate.surface for plan in plans if plan.duplicate is not None]
        self.assertGreater(len(stale), 1500)
        self.assertEqual(len(duplicates), 2000)
        traits: dict[str, Callable[[S.Surface], str | None]] = {
            "date": lambda s: s.date, "time": lambda s: s.time, "reference": lambda s: s.reference}
        def share(group: list[S.Surface], mark: Callable[[S.Surface], str | None]) -> float:
            return sum(mark(s) is not None for s in group) / len(group)

        for name, mark in traits.items():
            for planted in (stale, duplicates):
                self.assertLess(abs(share(planted, mark) - share(durable, mark)), 0.06, name)


def fact(memory_id: str, chars: int) -> S.MemoryFact:
    return S.MemoryFact(memory_id, "가" * chars, "c", None, "2026-10-14T05:30:00Z", False, None)


class CandidatePlanTest(unittest.TestCase):
    def test_a_deck_gives_each_value_its_share_and_the_rest_by_remainder(self) -> None:
        dealt = C.deck(random.Random(1), 10, S.DATE_FORMAT_WEIGHTS)
        self.assertEqual(Counter(dealt), Counter({"iso": 6, "month_day_dash": 2, "month_day_slash": 2}))
        self.assertEqual(C.deck(random.Random(1), 0, S.DATE_FORMAT_WEIGHTS), [])

    def test_every_kind_carries_each_mark_at_the_planned_share(self) -> None:
        plans = [p for row in C.plan_candidates(random.Random(20261109), 300) for p in row]
        shares = S.CANDIDATE_SURFACE
        for kind in S.CandidateKind:
            group = [p for p in plans if p.kind is kind]
            dated = [p.date for p in group if p.date is not None]
            counts = {"date": (len(dated), len(group), shares.date),
                      "time": (sum(d.timed for d in dated), len(dated), shares.time_given_date),
                      "reference": (sum(p.reference is not None for p in group), len(group), shares.reference),
                      "board": (sum(p.board for p in group), len(group), S.CANDIDATE_BOARD_SHARE)}
            for name, (hits, n, share) in counts.items():
                with self.subTest(kind=kind, mark=name):
                    self.assertGreater(n, 20)
                    self.assertLess(abs(hits - share * n), 1)

    def test_every_kind_draws_its_lengths_band_by_band(self) -> None:
        plans = [p for row in C.plan_candidates(random.Random(20261109), 300) for p in row]
        points = S.CANDIDATE_CLAIM_CHARS
        for kind in S.CandidateKind:
            lengths = sorted(p.length for p in plans if p.kind is kind)
            n = len(lengths)
            for i, length in enumerate(lengths):
                # Rounded to tens, so a length may sit 5 chars past its band.
                self.assertGreaterEqual(length, S.value_at(points, i / n) - 5, (kind, i))
                self.assertLessEqual(length, S.value_at(points, (i + 1) / n) + 5, (kind, i))

    def test_a_candidate_is_kept_only_inside_its_length_band(self) -> None:
        low, high = C.CANDIDATE_LENGTH_BAND
        self.assertTrue(C.length_holds("가" * int(low * 400), 400))
        self.assertFalse(C.length_holds("가" * (int(low * 400) - 1), 400))
        self.assertTrue(C.length_holds("가" * int(high * 400), 400))
        self.assertFalse(C.length_holds("가" * (int(high * 400) + 1), 400))

    def test_a_target_fits_the_planned_length_when_one_does(self) -> None:
        facts = [fact("m1", 100), fact("m2", 700), fact("m3", 800), fact("m4", 2000)]
        picked = {C.target_near(random.Random(seed), facts, 750).memory_id for seed in range(40)}
        self.assertEqual(picked, {"m2", "m3"})
        self.assertEqual(C.target_near(random.Random(1), [fact("m1", 100), fact("m4", 2000)], 750).memory_id, "m4")

    def test_the_surface_follows_the_plan(self) -> None:
        bare = C.CandidatePlan(S.CandidateKind.TRANSIENT, 400, None, None, False)
        self.assertEqual(C.candidate_surface(random.Random(1), bare, WHEN), S.Surface(None, None, None))
        full = C.CandidatePlan(S.CandidateKind.TRANSIENT, 400, C.DatePlan("korean", True), "task", False)
        surface = C.candidate_surface(random.Random(1), full, WHEN)
        self.assertEqual((surface.date, surface.time), ("10월 14일", "05:30"))
        self.assertRegex(surface.reference or "", r"^task-\d+$")


if __name__ == "__main__":
    unittest.main()
