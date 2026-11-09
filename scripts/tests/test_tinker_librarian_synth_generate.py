# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for how scripts/tinker/librarian/synth_generate.py plans and writes synthetic memories
and candidates, with a fake model in place of the Tinker caller.

A plan must not show its label: no category holds more facts than the cap, and
the size of a candidate's category does not depend on its kind. The generator
keeps only what it asked for: a duplicate restates a durable fact of its
category, and a copy, a mark or a length nobody asked for is not kept.
`synth_generate` imports the Tinker caller, which imports openai, so this file
runs with `uv run`.
"""

from __future__ import annotations

import datetime as dt
import json
import random
import re
import string
import sys
import unittest
from collections import Counter
from collections.abc import Callable, Sequence
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import synth_candidate_plan as C
import synth_generate as G
import synth_spec as S
from tinker_oai import HTTP_OK, Call

LENGTH = 200
BLANK = S.Surface(None, None, None)
SEEN = dt.datetime(2026, 10, 1, tzinfo=dt.UTC)
KEEPER = S.KeeperProfile("docs-gardener", "synth-docs-gardener", "문서 사이트를 돌보는 Keeper.", "가상의 문서 저장소.",
                         tuple(f"topic_{i}" for i in range(12)), S.GoalDraft("깨진 링크 줄이기", "깨진 링크 수", "0"))
ASKED = re.compile(r"facts는 정확히 (\d+)개")


def text(n: int) -> str:
    """A claim of LENGTH chars with no date, time or number in it: n spelled in letters."""
    return f"기억 {''.join(string.ascii_lowercase[int(d)] for d in str(n))} ".ljust(LENGTH, "가")


type Reply = Callable[["FakeModel"], str]


class FakeModel:
    """Answers every stage the way its prompt asks, with a new claim of LENGTH chars each time.
    `duplicate` replaces the answers of the duplicate stage, one per attempt."""

    def __init__(self, duplicate: Sequence[Reply] = ()) -> None:
        self.duplicate = tuple(duplicate)
        self.written: list[str] = []

    def fresh(self) -> str:
        self.written.append(text(1000 + len(self.written)))
        return self.written[-1]

    def ask(self, *, model: str, label: str, messages: Sequence[str], effort: str, max_tokens: int,
            attempt: int = 0) -> Call | None:
        body: dict[str, object]
        match label:
            case "facts":
                asked = ASKED.search(messages[-1])
                assert asked is not None
                body = {"facts": [{"claim": self.fresh()} for _ in range(int(asked.group(1)))]}
            case "duplicate" if self.duplicate:
                body = {"claim": self.duplicate[attempt](self)}
            case "duplicate" | "candidate":
                body = {"claim": self.fresh()}
            case other:
                raise AssertionError(f"the generator asked for {other}")
        return Call("key", label, HTTP_OK, "stop", json.dumps(body, ensure_ascii=False), None, 0, 0, 0, 0.0, None)


def copied(model: FakeModel) -> str:
    return model.written[0]


def dated(model: FakeModel) -> str:
    return ("2026-10-01 " + text(2001))[:LENGTH]


def too_long(model: FakeModel) -> str:
    return text(2002) * 2


def fresh(model: FakeModel) -> str:
    return model.fresh()


def memory_plan(seed: int) -> G.MemoryPlan:
    """One category of three durable and three stale facts, and a duplicate planted there."""
    slots = tuple(G.FactSlot("topic_0", LENGTH, i >= 3, SEEN + dt.timedelta(hours=i), BLANK) for i in range(6))
    return G.MemoryPlan("docs-gardener-00", KEEPER, slots,
                        G.DuplicateSlot("topic_0", SEEN + dt.timedelta(days=2), BLANK), seed)


def fact(index: int, *, category: str = "topic_0", stale: bool = False,
         duplicate_of: str | None = None) -> S.MemoryFact:
    seen = (SEEN + dt.timedelta(hours=index)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return S.MemoryFact(f"m{index}", text(index), category, None, seen, stale, duplicate_of)


# m4 is stale and m6 restates m5, so only m1, m2 and m3 can be targets.
PLANTED = (fact(1), fact(2), fact(3), fact(4, stale=True), fact(5), fact(6, duplicate_of="m5"))


def plan_of(kind: S.CandidateKind) -> C.CandidatePlan:
    return C.CandidatePlan(kind, LENGTH, None, None, False)


def mean(values: list[float]) -> float:
    return sum(values) / len(values)


class PlanTest(unittest.TestCase):
    def test_no_category_holds_more_than_the_cap(self) -> None:
        full = 0
        for seed in range(600):
            plan = G.plan_memory(random.Random(seed), KEEPER, 0, True)
            assert plan.duplicate is not None
            sizes = Counter(slot.category for slot in plan.slots)
            sizes[plan.duplicate.category] += 1
            self.assertLessEqual(max(sizes.values()), S.FACTS_PER_CATEGORY_CAP)
            planted = {slot.category for slot in plan.slots if slot.stale} | {plan.duplicate.category}
            full += any(sizes[c] == S.FACTS_PER_CATEGORY_CAP for c in planted)
            self.assertIsNone(G.plan_memory(random.Random(seed), KEEPER, 0, False).duplicate)
        self.assertGreater(full, 0, "no plan put a planted fact in a full category, so the cap went unchecked")

    def test_a_duplicate_lands_in_a_category_in_proportion_to_its_size(self) -> None:
        picked: list[float] = []
        even: list[float] = []
        by_size: list[float] = []
        for seed in range(2000):
            plan = G.plan_memory(random.Random(seed), KEEPER, 0, True)
            assert plan.duplicate is not None
            durable = Counter(slot.category for slot in plan.slots if not slot.stale)
            picked.append(durable[plan.duplicate.category])
            even.append(sum(durable.values()) / len(durable))
            by_size.append(sum(c * c for c in durable.values()) / sum(durable.values()))
        self.assertGreater(mean(picked), (mean(even) + mean(by_size)) / 2)


class MemoryTest(unittest.TestCase):
    def test_a_duplicate_names_the_id_its_fact_gets_once_sorted_by_time(self) -> None:
        late, early = dt.datetime(2026, 10, 9, tzinfo=dt.UTC), dt.datetime(2026, 10, 2, tzinfo=dt.UTC)
        written = [G.Written(late, "doc_links", False, "원래 기억", None),
                   G.Written(early, "doc_links", False, "같은 지식의 다른 문장", "원래 기억"),
                   G.Written(early + dt.timedelta(days=1), "doc_links", True, "낡은 상태", None)]
        facts = G.facts_of(random.Random(1), written)
        self.assertEqual([(f.memory_id, f.claim, f.planted_stale, f.duplicate_of) for f in facts],
                         [("m1", "같은 지식의 다른 문장", False, "m3"), ("m2", "낡은 상태", True, None),
                          ("m3", "원래 기억", False, None)])

    def test_a_duplicate_restates_a_durable_fact_of_its_category(self) -> None:
        for seed in range(30):
            facts = G.build_memory(FakeModel(), memory_plan(seed))
            assert facts is not None
            by_id = {f.memory_id: f for f in facts}
            (duplicate,) = [f for f in facts if f.duplicate_of is not None]
            original = by_id[duplicate.duplicate_of or ""]
            self.assertFalse(original.planted_stale)
            self.assertEqual(original.category, duplicate.category)

    def test_a_duplicate_that_copies_or_misses_its_marks_or_length_is_not_kept(self) -> None:
        model = FakeModel((copied, dated, too_long, fresh))
        facts = G.build_memory(model, memory_plan(0))
        assert facts is not None
        (duplicate,) = [f for f in facts if f.duplicate_of is not None]
        self.assertEqual(duplicate.claim, model.written[-1])
        refused = FakeModel((copied, dated, too_long) * 2)
        self.assertGreater(len(refused.duplicate), G.CANDIDATE_ATTEMPTS - 1)
        self.assertIsNone(G.build_memory(refused, memory_plan(0)))


class CandidatesTest(unittest.TestCase):
    def test_no_target_is_a_planted_fact(self) -> None:
        self.assertEqual([f.memory_id for f in G.target_choices(PLANTED)], ["m1", "m2", "m3"])

    def test_targeted_candidates_take_distinct_durable_facts_outside_the_pair(self) -> None:
        facts = PLANTED
        plans = tuple(plan_of(kind) for kind in
                      (S.CandidateKind.CORRECTION, S.CandidateKind.COMPLEMENT, S.CandidateKind.PARAPHRASE))
        for seed in range(40):
            built = G.build_candidates(FakeModel(), random.Random(seed), KEEPER, facts, plans)
            assert built is not None
            self.assertEqual(sorted(c.target_memory_id or "" for c in built), ["m1", "m2", "m3"])

    def test_an_untargeted_candidate_lands_where_a_targeted_one_would(self) -> None:
        facts = tuple(fact(i) for i in range(1, 9)) + (fact(9, category="topic_1"), fact(10, category="topic_1"))
        runs = 400
        for kind in (S.CandidateKind.NEW_DURABLE, S.CandidateKind.TRANSIENT):
            landed: Counter[str] = Counter()
            for seed in range(runs):
                built = G.build_candidates(FakeModel(), random.Random(seed), KEEPER, facts, (plan_of(kind),))
                assert built is not None
                landed[built[0].category] += 1
            # A target is topic_0 with 0.8; a category drawn evenly would be 0.5.
            self.assertGreater(landed["topic_0"] / runs, 0.7, kind)


if __name__ == "__main__":
    unittest.main()
