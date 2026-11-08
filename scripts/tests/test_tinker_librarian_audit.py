# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the case rules in scripts/tinker/librarian/e_synth_audit.py and the
decision rules in scripts/tinker/librarian/audit_decisions.py.

Requests, rows and decisions are invented. `e_synth_audit` imports the Tinker
caller, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import random
import sys
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import audit_decisions as D
import e_synth_audit as A

type JsonObject = dict[str, object]


def request(candidates: list[JsonObject], stale: frozenset[str] = frozenset(), facts: int = 20) -> JsonObject:
    return {"item_id": "eval-k-0", "keeper": {"role_material": "role"}, "candidates": candidates,
            "facts": [{"memory_id": f"m{i}", "category": "c", "claim": f"fact {i}", "planted_stale": f"m{i}" in stale}
                      for i in range(1, facts + 1)]}


def candidate(kind: str, target: str | None = None) -> JsonObject:
    return {"kind": kind, "target_memory_id": target, "category": "c", "claim": "claim"}


def full_refs(case: JsonObject) -> list[str]:
    return [cast(str, f["ref"]) for f in cast(list[JsonObject], case["facts"])]


class CaseTest(unittest.TestCase):
    def test_every_case_shows_the_same_number_of_facts_in_full(self) -> None:
        few = request([candidate("new_durable")])
        many = request([candidate("correction", "m4"), candidate("paraphrase", "m9")], stale=frozenset({"m2"}))
        for req in (few, many):
            with self.subTest(candidates=len(cast(list[JsonObject], req["candidates"]))):
                case, key = A.case_of("c001", req, set(), random.Random(1))
                self.assertEqual(len(full_refs(case)), A.FULL_FACTS)
                self.assertEqual(sorted(cast(dict[str, str], key["facts"])), sorted(full_refs(case)))

    def test_suspects_past_the_size_still_get_distractors(self) -> None:
        stale = frozenset(f"m{i}" for i in range(1, A.FULL_FACTS + 1))
        case, _ = A.case_of("c001", request([candidate("new_durable")], stale=stale), set(), random.Random(1))
        self.assertEqual(len(full_refs(case)), A.FULL_FACTS + A.MIN_DISTRACTORS)

    def test_a_fact_worded_like_a_candidate_is_shown_in_full(self) -> None:
        req = request([candidate("new_durable")], facts=40)
        facts = cast(list[JsonObject], req["facts"])
        facts[30]["claim"] = "재시도는 세 번까지 하고 실패하면 담당자에게 넘긴다"
        cast(list[JsonObject], req["candidates"])[0]["claim"] = "재시도는 세 번까지 하고 실패하면 담당자에게 넘긴다고 정했다"
        case, _ = A.case_of("c001", req, set(), random.Random(1))
        self.assertIn("m31", full_refs(case))

    def test_a_drop_case_shows_the_dropped_fact_among_as_many_facts(self) -> None:
        req = request([candidate("new_durable")], facts=40)
        case, key = A.case_of("d001", req, {"m37"}, random.Random(1))
        self.assertIn("m37", full_refs(case))
        self.assertEqual(len(full_refs(case)), A.FULL_FACTS)
        self.assertEqual(cast(dict[str, str], key["facts"])["m37"], "keep")


class MisfitTest(unittest.TestCase):
    KEY: JsonObject = {"case": "c001", "candidates": {"k1": "restates:m3"}, "facts": {"m3": "keep"},
                       "refs": ["m3", "m7"]}

    def misfits(self, restates: str) -> list[str]:
        decision: JsonObject = {"case": "c001", "candidates": {"k1": restates}, "facts": {"m3": "keep"}}
        return D.misfits(self.KEY, decision)[0]

    def test_a_paraphrase_must_restate_the_labelled_memory_alone(self) -> None:
        self.assertEqual(self.misfits("restates:m3"), [])
        self.assertEqual(len(self.misfits("restates:m7")), 1)
        self.assertEqual(len(self.misfits("restates:m3,m7")), 1)

    def test_a_restated_memory_the_case_does_not_show_is_malformed(self) -> None:
        with self.assertRaises(SystemExit):
            self.misfits("restates:m3,m9")


def synth_row(target: str, item: str, off_label: list[str]) -> JsonObject:
    return {"target": target, "item": item, "dropped_off_label": off_label}


class DropTest(unittest.TestCase):
    DROPS: D.OffLabel = {"eval-k-0": {"m7": ["A"]}}
    KEY: JsonObject = {"case": "d001", "item": "eval-k-0", "candidates": {"k1": "new"},
                       "facts": {"m2": "drop", "m7": "keep"}, "refs": ["m2", "m7"], "off_label": {"m7": ["A"]}}

    def judge(self, m7: str) -> D.Adjudication:
        decision: JsonObject = {"case": "d001", "candidates": {"k1": "new"}, "facts": {"m2": "drop", "m7": m7}}
        return D.adjudicate([self.KEY], [decision], self.DROPS)

    def test_off_label_drops_are_grouped_by_item_with_their_targets(self) -> None:
        rows = [synth_row("base", "eval-k-0", ["m3"]), synth_row("A", "eval-k-0", ["m3"]),
                synth_row("B", "eval-k-0", ["m4"]), synth_row("A", "eval-k-1", [])]
        self.assertEqual(D.off_label(rows), {"eval-k-0": {"m3": ["A", "base"], "m4": ["B"]}})

    def test_a_kept_fact_leaves_the_drop_wrong(self) -> None:
        judged = self.judge("keep")
        self.assertEqual(judged.excluded, frozenset())
        self.assertEqual(judged.drops, (D.Judged("eval-k-0", "m7", ("A",), "keep"),))

    def test_a_fact_the_judge_takes_out_too_removes_its_memory(self) -> None:
        for m7 in ("drop", "superseded:k1"):
            with self.subTest(judged=m7):
                self.assertEqual(self.judge(m7).excluded, frozenset({"eval-k"}))

    def test_no_target_is_scored_on_an_excluded_memory(self) -> None:
        rows = [synth_row("base", "eval-k-0", []), synth_row("A", "eval-k-1", ["m7"]), synth_row("A", "eval-j-0", [])]
        self.assertEqual([r["item"] for r in self.judge("drop").scored(rows)], ["eval-j-0"])

    def test_cases_made_for_other_drops_or_missing_decisions_stop_the_verdict(self) -> None:
        with self.assertRaises(SystemExit):
            D.adjudicate([self.KEY], [], self.DROPS)
        with self.assertRaises(SystemExit):
            D.adjudicate([self.KEY], [{"case": "d001", "candidates": {"k1": "new"}, "facts": {"m2": "drop", "m7": "keep"}}],
                         {"eval-k-0": {"m7": ["A", "B"]}})


if __name__ == "__main__":
    unittest.main()
