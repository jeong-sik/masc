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
category, a copy, a mark or a length nobody asked for is not kept, and a facts
answer that is not one text claim per slot is asked again. Each refusal is
recorded.
`synth_generate` imports the Tinker caller, which imports openai, so this file
runs with `uv run`.
"""

from __future__ import annotations

import dataclasses
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
import synth_prompts as P
import synth_rows as RW
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
# A float claim is written as a bare JSON number, NaN included.
type FactsReply = Callable[["FakeModel", int], Sequence[str | float]]


class FakeModel:
    """Answers every stage the way its prompt asks, with a new claim of LENGTH chars each time.
    `duplicate` replaces the answers of the duplicate stage and `facts` those of the facts stage,
    one per attempt; `candidate` replaces the answers of the candidate stage, one per call."""

    def __init__(self, duplicate: Sequence[Reply] = (), candidate: Sequence[Reply] = (),
                 facts: Sequence[FactsReply] = ()) -> None:
        self.duplicate = tuple(duplicate)
        self.candidate = tuple(candidate)
        self.facts = tuple(facts)
        self.written: list[str] = []
        self.candidate_calls = 0
        self.prompts: list[tuple[str, str]] = []

    def fresh(self) -> str:
        self.written.append(text(1000 + len(self.written)))
        return self.written[-1]

    def ask(self, *, model: str, label: str, messages: Sequence[str], effort: str, max_tokens: int,
            attempt: int = 0) -> Call | None:
        body: dict[str, object]
        self.prompts.append((label, messages[-1]))
        match label:
            case "facts":
                asked = ASKED.search(messages[-1])
                assert asked is not None
                n = int(asked.group(1))
                claims = self.facts[attempt](self, n) if self.facts else [self.fresh() for _ in range(n)]
                body = {"facts": [{"claim": claim} for claim in claims]}
            case "duplicate":
                body = {"claim": self.duplicate[attempt](self) if self.duplicate else self.fresh()}
            case "candidate":
                reply = self.candidate[self.candidate_calls] if self.candidate_calls < len(self.candidate) else fresh
                self.candidate_calls += 1
                body = {"claim": reply(self)}
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


def a_fact(model: FakeModel) -> str:
    return PLANTED[0].claim


def previous(model: FakeModel) -> str:
    return model.written[-1]


def fresh_facts(model: FakeModel, n: int) -> list[str]:
    return [model.fresh() for _ in range(n)]


def second_copies_first(model: FakeModel, n: int) -> list[str]:
    claims = fresh_facts(model, n)
    claims[1] = claims[0]
    return claims


def second_dated(model: FakeModel, n: int) -> list[str]:
    claims = fresh_facts(model, n)
    claims[1] = dated(model)
    return claims


def two_copy_first(model: FakeModel, n: int) -> list[str]:
    claims = fresh_facts(model, n)
    claims[1] = claims[2] = claims[0]
    return claims


def stale_copies_first(model: FakeModel, n: int) -> list[str]:
    claims = fresh_facts(model, n)
    claims[3] = claims[0]
    return claims


def second_blank(model: FakeModel, n: int) -> list[str]:
    claims = fresh_facts(model, n)
    claims[1] = " \t\n"
    return claims


def second_skipped(model: FakeModel, n: int) -> list[str]:
    claims = fresh_facts(model, n)
    del claims[1]
    return claims


def second_bare_nan(model: FakeModel, n: int) -> list[str | float]:
    return [float("nan") if i == 1 else claim for i, claim in enumerate(fresh_facts(model, n))]


def memory_plan(seed: int) -> G.MemoryPlan:
    """One category of three durable and three stale facts, and a duplicate planted there."""
    slots = tuple(G.FactSlot("topic_0", LENGTH, i >= 3, SEEN + dt.timedelta(hours=i), BLANK, None)
                  for i in range(6))
    return G.MemoryPlan("docs-gardener-00", KEEPER, slots,
                        G.DuplicateSlot("topic_0", SEEN + dt.timedelta(days=2), BLANK), seed)


def fact(index: int, *, category: str = "topic_0", stale: bool = False, duplicate_of: str | None = None,
         use_at: str | None = None) -> S.MemoryFact:
    seen = (SEEN + dt.timedelta(hours=index)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return S.MemoryFact(f"m{index}", text(index), category, None, seen, stale, duplicate_of, use_at)


def durable_plan(n: int) -> G.MemoryPlan:
    """n durable facts in topic_0 and no duplicate; DURABLE_KEEP_SHARE keeps an attempt short of one of three."""
    slots = tuple(G.FactSlot("topic_0", LENGTH, False, SEEN + dt.timedelta(hours=i), BLANK, None) for i in range(n))
    return G.MemoryPlan("docs-gardener-00", KEEPER, slots, None, 0)


def record_plan() -> G.MemoryPlan:
    """Three durable facts, then a record still ahead and one already past, all in topic_0."""
    durable = tuple(G.FactSlot("topic_0", LENGTH, False, SEEN + dt.timedelta(hours=i), BLANK, None)
                    for i in range(3))
    ahead = G.FactSlot("topic_0", LENGTH, False, SEEN + dt.timedelta(hours=3), BLANK, G.USE_AHEAD_START)
    past = G.FactSlot("topic_0", LENGTH, True, SEEN + dt.timedelta(hours=4), BLANK, SEEN + dt.timedelta(days=1))
    return G.MemoryPlan("docs-gardener-00", KEEPER, (*durable, ahead, past), None, 0)


# m4 is stale and m6 restates m5, so only m1, m2 and m3 can be targets.
PLANTED = (fact(1), fact(2), fact(3), fact(4, stale=True), fact(5), fact(6, duplicate_of="m5"))


def plan_of(kind: S.CandidateKind) -> C.CandidatePlan:
    return C.CandidatePlan(kind, LENGTH, None, None, False)


def mean(values: list[float]) -> float:
    return sum(values) / len(values)


class PlanTest(unittest.TestCase):
    def test_a_batch_that_starts_where_the_last_ended_shares_no_memory_key_with_it(self) -> None:
        per_keeper = 3
        first = G.memory_homes([KEEPER], per_keeper, 0)
        second = G.memory_homes([KEEPER], per_keeper, per_keeper)
        self.assertEqual([i for _, i in first + second], list(range(2 * per_keeper)))
        keys = [G.plan_memory(random.Random(i), keeper, i, False).memory_key for keeper, i in first + second]
        self.assertEqual(keys, [f"{KEEPER.key}-{i:02d}" for i in range(2 * per_keeper)])

    def test_no_category_holds_more_than_the_cap(self) -> None:
        full = 0
        for seed in range(600):
            plan = G.plan_memory(random.Random(seed), KEEPER, 0, True)
            assert plan.duplicate is not None
            sizes = Counter(slot.category for slot in plan.slots)
            sizes[plan.duplicate.category] += 1
            self.assertLessEqual(max(sizes.values()), S.FACTS_PER_CATEGORY_CAP)
            planted = {slot.category for slot in plan.slots if G.planted(slot)} | {plan.duplicate.category}
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

    def test_a_stale_fact_lands_in_a_category_in_proportion_to_its_size(self) -> None:
        picked: list[float] = []
        even: list[float] = []
        by_size: list[float] = []
        for seed in range(2000):
            plan = G.plan_memory(random.Random(seed), KEEPER, 0, False)
            durable = Counter(slot.category for slot in plan.slots if not slot.stale)
            for slot in plan.slots:
                if slot.stale and durable[slot.category]:
                    picked.append(durable[slot.category])
                    even.append(sum(durable.values()) / len(durable))
                    by_size.append(sum(c * c for c in durable.values()) / sum(durable.values()))
        self.assertGreater(mean(picked), (mean(even) + mean(by_size)) / 2)

    def test_a_record_is_used_on_its_side_of_the_candidates_days(self) -> None:
        """Candidates fall on 11-07 or 11-08. A record ahead is used on a later day; a past one is
        used after it was written, on a day of its memory."""
        last_candidate_day = (G.CANDIDATE_TIME_START + dt.timedelta(days=1)).date()
        sides: Counter[bool] = Counter()
        for seed in range(2000):
            for slot in G.plan_memory(random.Random(seed), KEEPER, 0, False).slots:
                if slot.use_at is None:
                    continue
                sides[slot.stale] += 1
                if slot.stale:
                    self.assertLessEqual(slot.seen + G.USE_PAST_AFTER, slot.use_at)
                    self.assertLessEqual(slot.use_at, G.MEMORY_END)
                else:
                    self.assertGreater(slot.use_at.date(), last_candidate_day)
                    self.assertLess(slot.use_at, G.USE_AHEAD_START + dt.timedelta(days=G.USE_AHEAD_DAYS))
        self.assertLess(abs(sides[False] / sides.total() - S.SCHEDULED_AHEAD_SHARE), 0.05)


class MemoryTest(unittest.TestCase):
    def test_a_duplicate_names_the_id_its_fact_gets_once_sorted_by_time(self) -> None:
        late, early = dt.datetime(2026, 10, 9, tzinfo=dt.UTC), dt.datetime(2026, 10, 2, tzinfo=dt.UTC)
        written = [G.Written(late, "doc_links", False, "원래 기억", None, None),
                   G.Written(early, "doc_links", False, "같은 지식의 다른 문장", "원래 기억", None),
                   G.Written(early + dt.timedelta(days=1), "doc_links", True, "낡은 상태", None, None)]
        facts = G.facts_of(random.Random(1), written)
        self.assertEqual([(f.memory_id, f.claim, f.planted_stale, f.duplicate_of) for f in facts],
                         [("m1", "같은 지식의 다른 문장", False, "m3"), ("m2", "낡은 상태", True, None),
                          ("m3", "원래 기억", False, None)])

    def test_a_duplicate_restates_a_durable_fact_of_its_category(self) -> None:
        for seed in range(30):
            facts = G.build_memory(FakeModel(), memory_plan(seed)).value
            assert facts is not None
            by_id = {f.memory_id: f for f in facts}
            (duplicate,) = [f for f in facts if f.duplicate_of is not None]
            original = by_id[duplicate.duplicate_of or ""]
            self.assertFalse(original.planted_stale)
            self.assertEqual(original.category, duplicate.category)

    def test_a_duplicate_never_restates_a_record(self) -> None:
        # topic_0 holds three durable facts and a record still ahead, which is not stale either.
        for seed in range(30):
            plan = dataclasses.replace(record_plan(), duplicate=G.DuplicateSlot("topic_0", SEEN + dt.timedelta(days=2),
                                                                                BLANK), seed=seed)
            facts = G.build_memory(FakeModel(), plan).value
            assert facts is not None
            by_id = {f.memory_id: f for f in facts}
            (duplicate,) = [f for f in facts if f.duplicate_of is not None]
            self.assertIsNone(by_id[duplicate.duplicate_of or ""].use_at, seed)

    def test_a_duplicate_that_copies_or_misses_its_marks_or_length_is_not_kept(self) -> None:
        model = FakeModel((copied, dated, too_long, fresh))
        facts = G.build_memory(model, memory_plan(0)).value
        assert facts is not None
        (duplicate,) = [f for f in facts if f.duplicate_of is not None]
        self.assertEqual(duplicate.claim, model.written[-1])
        refused = FakeModel((copied, dated, too_long) * 2)
        self.assertGreater(len(refused.duplicate), G.CANDIDATE_ATTEMPTS - 1)
        self.assertIsNone(G.build_memory(refused, memory_plan(0)).value)

    def test_a_fact_that_copies_another_or_misses_its_marks_is_not_kept(self) -> None:
        # Three durable slots, then three stale ones; DURABLE_KEEP_SHARE keeps an attempt with two
        # durable facts of three, and only one with every stale fact.
        plan = memory_plan(0)
        for reply, miss in ((second_copies_first, G.ClaimMiss.COPY), (second_dated, G.ClaimMiss.MARKS)):
            got = G.claims_for(FakeModel(facts=(reply,)), plan, "topic_0", plan.slots, [], [])
            assert got.value is not None
            self.assertEqual([plan.slots.index(slot) for slot, _ in got.value], [0, 2, 3, 4, 5], reply.__name__)
            self.assertEqual(got.refused, (miss,))
        existing = text(999)
        for same, others in (([existing], []), ([], [existing])):
            got = G.claims_for(FakeModel(facts=(lambda m, n: [existing, *fresh_facts(m, n - 1)],)), plan,
                               "topic_0", plan.slots, same, others)
            assert got.value is not None
            self.assertEqual([plan.slots.index(slot) for slot, _ in got.value], [1, 2, 3, 4, 5])

    def test_an_answer_that_is_not_one_text_claim_per_slot_is_asked_again(self) -> None:
        # Matched by position, each answer would put its third claim on the second slot, and two
        # durable facts of three would keep the attempt.
        for reply, fault in ((second_skipped, G.AnswerFault.COUNT), (second_bare_nan, G.AnswerFault.CLAIM_NOT_TEXT),
                             (second_blank, G.AnswerFault.CLAIM_NOT_TEXT)):
            model = FakeModel(facts=(reply, fresh_facts))
            got = G.claims_for(model, durable_plan(3), "topic_0", durable_plan(3).slots, [], [])
            assert got.value is not None
            self.assertEqual([claim for _, claim in got.value], model.written[-3:], reply.__name__)
            self.assertEqual(got.refused, (fault,))

    def test_an_attempt_that_keeps_too_few_facts_is_asked_again(self) -> None:
        for lost in (two_copy_first, stale_copies_first):
            model = FakeModel(facts=(lost, fresh_facts))
            kept = G.claims_for(model, memory_plan(0), "topic_0", memory_plan(0).slots, [], []).value
            assert kept is not None
            self.assertEqual([claim for _, claim in kept], model.written[-6:], lost.__name__)

    def test_an_attempt_that_loses_a_record_is_asked_again(self) -> None:
        # Slot 3 is the record ahead. Counted as a durable fact, losing it would leave enough.
        plan = record_plan()
        model = FakeModel(facts=(stale_copies_first, fresh_facts))
        kept = G.claims_for(model, plan, "topic_0", plan.slots, [], []).value
        assert kept is not None
        self.assertEqual([claim for _, claim in kept], model.written[-5:])

    def test_the_prompt_names_a_records_kind_and_not_its_side(self) -> None:
        plan = record_plan()
        prompts: list[str] = []
        for slot in plan.slots[3:]:
            model = FakeModel()
            self.assertIsNotNone(G.claims_for(model, plan, "topic_0", (slot,), [], []).value)
            prompts.append(model.prompts[-1][1])
        self.assertEqual(prompts[0], prompts[1])
        self.assertIn(P.fact_kind_word("scheduled"), prompts[0])

    def test_a_record_keeps_its_use_time_and_side(self) -> None:
        facts = G.build_memory(FakeModel(), record_plan()).value
        assert facts is not None
        self.assertEqual([(f.planted_stale, f.use_at) for f in facts if f.use_at is not None],
                         [(False, "2026-11-09T00:00:00Z"), (True, "2026-10-02T00:00:00Z")])

    def test_a_later_call_sees_its_categorys_facts_whole_and_others_by_their_head(self) -> None:
        # One topic_1 fact, then eight topic_0 facts: topic_0 takes two calls of FACTS_PER_CALL.
        slots = tuple(G.FactSlot(category, LENGTH, False, SEEN + dt.timedelta(hours=i), BLANK, None)
                      for i, category in enumerate(["topic_1"] + ["topic_0"] * 8))
        model = FakeModel()
        facts = G.build_memory(model, G.MemoryPlan("docs-gardener-00", KEEPER, slots, None, 0)).value
        assert facts is not None
        prompts = [prompt for label, prompt in model.prompts if label == "facts"]
        self.assertEqual(len(prompts), 3)
        other, *first_topic_0 = model.written[:1 + G.FACTS_PER_CALL]
        self.assertGreater(len(other), G.EXISTING_HEAD)
        last = prompts[-1]
        for claim in first_topic_0:
            self.assertIn(claim, last)
        self.assertIn(other[:G.EXISTING_HEAD], last)
        self.assertNotIn(other, last)


class CandidatesTest(unittest.TestCase):
    def test_no_target_is_a_planted_fact(self) -> None:
        records = (fact(7, use_at="2026-11-09T09:00:00Z"), fact(8, stale=True, use_at="2026-10-02T09:00:00Z"))
        for facts in (PLANTED, PLANTED + records):
            self.assertEqual([f.memory_id for f in G.target_choices(facts)], ["m1", "m2", "m3"])

    def test_a_request_on_a_planned_memory_with_records_reads_back(self) -> None:
        """The use times plan_memory draws hold against the times build_candidates gives."""
        sides: Counter[bool] = Counter()
        for seed in range(300):
            plan = G.plan_memory(random.Random(seed), KEEPER, 0, False)
            if not any(slot.use_at is not None for slot in plan.slots):
                continue
            written = [G.Written(slot.seen, slot.category, slot.stale, text(i), None, slot.use_at)
                       for i, slot in enumerate(plan.slots)]
            facts = G.facts_of(random.Random(seed), written)
            plans = tuple(plan_of(kind) for kind in (S.CandidateKind.NEW_DURABLE, S.CandidateKind.TRANSIENT))
            candidates = G.build_candidates(FakeModel(), random.Random(seed), KEEPER, facts, plans)
            assert candidates is not None
            req = S.SynthRequest(f"eval-{plan.memory_key}-000", KEEPER, facts, S.NoTask(), candidates)
            row = json.loads(G.request_json(req))["request"]
            self.assertEqual(RW.parts_of(row), (facts, candidates), seed)
            sides.update(f.planted_stale for f in facts if f.use_at is not None)
        self.assertGreater(min(sides[False], sides[True]), 50)

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

    def test_a_new_candidate_sees_its_categorys_durable_facts_whole(self) -> None:
        model = FakeModel()
        built = G.build_candidates(model, random.Random(1), KEEPER, PLANTED,
                                   (plan_of(S.CandidateKind.NEW_DURABLE),))
        assert built is not None
        (prompt,) = [prompt for label, prompt in model.prompts if label == "candidate"]
        self.assertTrue(all(len(f.claim) > G.EXISTING_HEAD for f in PLANTED))
        for f in PLANTED:
            if f.planted_stale:
                self.assertNotIn(f.claim, prompt)
            else:
                self.assertIn(f.claim, prompt)

    def test_a_candidate_that_copies_a_fact_or_misses_its_marks_or_length_is_not_kept(self) -> None:
        plans = (plan_of(S.CandidateKind.NEW_DURABLE),)
        model = FakeModel(candidate=(a_fact, dated, too_long, fresh))
        built = G.build_candidates(model, random.Random(1), KEEPER, PLANTED, plans)
        assert built is not None
        self.assertEqual([c.claim for c in built], [model.written[-1]])
        refused = FakeModel(candidate=(a_fact, dated, too_long) * 2)
        self.assertGreaterEqual(len(refused.candidate), G.CANDIDATE_ATTEMPTS)
        self.assertIsNone(G.build_candidates(refused, random.Random(1), KEEPER, PLANTED, plans))

    def test_a_candidate_that_copies_an_earlier_one_is_not_kept(self) -> None:
        model = FakeModel(candidate=(fresh, previous, fresh))
        plans = (plan_of(S.CandidateKind.NEW_DURABLE), plan_of(S.CandidateKind.TRANSIENT))
        built = G.build_candidates(model, random.Random(1), KEEPER, PLANTED, plans)
        assert built is not None
        self.assertEqual([c.claim for c in built], model.written)
        self.assertEqual(len(model.written), 2)


if __name__ == "__main__":
    unittest.main()
