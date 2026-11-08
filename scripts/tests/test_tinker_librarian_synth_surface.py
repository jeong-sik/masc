# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the surface traits of synthetic claims (scripts/tinker/librarian/synth_spec.py).

A label must leave no mark in a claim's dates, times or numbers. `synth_generate`
imports the Tinker caller, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import datetime as dt
import random
import sys
import unittest
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

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
    def test_stale_and_durable_slots_carry_marks_at_the_same_rates(self) -> None:
        keeper = S.KeeperProfile("k", "synth-k", "role", "world", tuple(f"cat_{i}" for i in range(12)),
                                 S.GoalDraft("t", "m", "v"))
        rng = random.Random(20261109)
        slots = [slot for i in range(400) for slot in G.plan_memory(rng, keeper, i).slots]
        stale = [s for s in slots if s.stale]
        durable = [s for s in slots if not s.stale]
        self.assertGreater(len(stale), 300)
        traits: dict[str, Callable[[S.Surface], str | None]] = {
            "date": lambda s: s.date, "time": lambda s: s.time, "reference": lambda s: s.reference}
        def share(group: list[G.FactSlot], mark: Callable[[S.Surface], str | None]) -> float:
            return sum(mark(s.surface) is not None for s in group) / len(group)

        for name, mark in traits.items():
            self.assertLess(abs(share(stale, mark) - share(durable, mark)), 0.06, name)


if __name__ == "__main__":
    unittest.main()
