# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the case and match rules in scripts/tinker/librarian/e_synth_audit.py.

Requests are invented. `e_synth_audit` imports the Tinker caller, which imports
openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import random
import sys
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

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
                case, key = A.case_of("c001", req, None, random.Random(1))
                self.assertEqual(len(full_refs(case)), A.FULL_FACTS)
                self.assertEqual(sorted(cast(dict[str, str], key["facts"])), sorted(full_refs(case)))

    def test_suspects_past_the_size_still_get_distractors(self) -> None:
        stale = frozenset(f"m{i}" for i in range(1, A.FULL_FACTS + 1))
        case, _ = A.case_of("c001", request([candidate("new_durable")], stale=stale), None, random.Random(1))
        self.assertEqual(len(full_refs(case)), A.FULL_FACTS + A.MIN_DISTRACTORS)

    def test_a_fact_worded_like_a_candidate_is_shown_in_full(self) -> None:
        req = request([candidate("new_durable")], facts=40)
        facts = cast(list[JsonObject], req["facts"])
        facts[30]["claim"] = "재시도는 세 번까지 하고 실패하면 담당자에게 넘긴다"
        cast(list[JsonObject], req["candidates"])[0]["claim"] = "재시도는 세 번까지 하고 실패하면 담당자에게 넘긴다고 정했다"
        case, _ = A.case_of("c001", req, None, random.Random(1))
        self.assertIn("m31", full_refs(case))


class MisfitTest(unittest.TestCase):
    KEY: JsonObject = {"case": "c001", "candidates": {"k1": "restates:m3"}, "facts": {"m3": "keep"},
                       "refs": ["m3", "m7"]}

    def misfits(self, restates: str) -> list[str]:
        decision: JsonObject = {"case": "c001", "candidates": {"k1": restates}, "facts": {"m3": "keep"}}
        return A.misfits(self.KEY, decision)[0]

    def test_a_paraphrase_must_restate_the_labelled_memory_alone(self) -> None:
        self.assertEqual(self.misfits("restates:m3"), [])
        self.assertEqual(len(self.misfits("restates:m7")), 1)
        self.assertEqual(len(self.misfits("restates:m3,m7")), 1)

    def test_a_restated_memory_the_case_does_not_show_is_malformed(self) -> None:
        with self.assertRaises(SystemExit):
            self.misfits("restates:m3,m9")


if __name__ == "__main__":
    unittest.main()
