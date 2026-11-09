# pyright: strict
"""Tests for synthetic request rows (scripts/tinker/librarian/synth_rows.py).

A row read back gives the facts, candidates and label of the request it was
written from, and a row the generator cannot write gives none. Requests come from
`tinker_librarian_synth_fixtures.py`.
"""

from __future__ import annotations

import copy
import dataclasses
import itertools
import json
import sys
import unittest
from collections.abc import Callable
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import synth_rows as RW
import synth_spec as S
from tinker_librarian_synth_fixtures import KINDS, PLANTED, candidates_of, request

type JsonObject = dict[str, object]
type Change = Callable[[JsonObject], None]


def stored(req: S.SynthRequest) -> JsonObject:
    """The request row as requests.jsonl holds it."""
    return cast(JsonObject, json.loads(json.dumps(RW.row_of(req), ensure_ascii=False)))


def setting(section: str, index: int, field: str, value: object) -> Change:
    def change(row: JsonObject) -> None:
        cast(list[JsonObject], row[section])[index][field] = value
    return change


def removing(section: str, index: int, field: str) -> Change:
    def change(row: JsonObject) -> None:
        del cast(list[JsonObject], row[section])[index][field]
    return change


def adding_duplicate_of(original: str) -> Change:
    def change(row: JsonObject) -> None:
        facts = cast(list[JsonObject], row["facts"])
        facts.append({**facts[0], "memory_id": "m7", "claim": "기억 7: 같은 지식을 또 적은 문장.", "duplicate_of": original})
    return change


def replacing_facts(row: JsonObject) -> None:
    row["facts"] = {}


# k1 corrects m1, k2 restates m2, k3 is new; m4 is stale and m6 restates m5.
BASE = request(PLANTED, candidates_of((S.CandidateKind.CORRECTION, S.CandidateKind.PARAPHRASE,
                                       S.CandidateKind.NEW_DURABLE)))
REFUSED: tuple[tuple[str, Change], ...] = (
    ("a fact without duplicate_of", removing("facts", 0, "duplicate_of")),
    ("a fact with another field", setting("facts", 0, "note", "x")),
    ("two facts with one memory ID", setting("facts", 2, "memory_id", "m1")),
    ("two facts with one claim", setting("facts", 1, "claim", PLANTED[0].claim)),
    ("two candidates with one request ID", setting("candidates", 1, "request_id", BASE.candidates[0].request_id)),
    ("a new fact with a target", setting("candidates", 2, "target_memory_id", "m3")),
    ("a correction without a target", setting("candidates", 0, "target_memory_id", None)),
    ("a target on the stale fact", setting("candidates", 0, "target_memory_id", "m4")),
    ("a target on the pair's original", setting("candidates", 0, "target_memory_id", "m5")),
    ("a target on the pair's duplicate", setting("candidates", 0, "target_memory_id", "m6")),
    ("two candidates on one target", setting("candidates", 1, "target_memory_id", "m1")),
    ("a target naming no fact", setting("candidates", 0, "target_memory_id", "m99")),
    ("a duplicate of no fact", setting("facts", 5, "duplicate_of", "m99")),
    ("a duplicate of itself", setting("facts", 5, "duplicate_of", "m6")),
    ("a duplicate of the stale fact", setting("facts", 5, "duplicate_of", "m4")),
    ("a stale duplicate", setting("facts", 5, "planted_stale", True)),
    ("a duplicate of a duplicate", adding_duplicate_of("m6")),
    ("two duplicates of one fact", adding_duplicate_of("m5")),
    ("an unknown kind", setting("candidates", 2, "kind", "rewrite")),
    ("a true-or-false sequence", setting("candidates", 0, "sequence", True)),
    ("a whole-number candidate time", setting("candidates", 0, "seen_at", 1762505000)),
    ("a board with another field", setting("facts", 0, "board", {"post_id": "p-1", "comment_id": None, "x": 1})),
    ("facts that are not a list", replacing_facts),
)


class RowTest(unittest.TestCase):
    def test_a_stored_row_reads_back_as_its_request_and_label(self) -> None:
        boarded = (dataclasses.replace(PLANTED[0], board=S.BoardRef("p-1", "c-1")),) + PLANTED[1:]
        for n in (1, 2, 3):
            for kinds in itertools.product(KINDS, repeat=n):
                req = request(boarded, candidates_of(kinds))
                row = stored(req)
                self.assertEqual(RW.parts_of(row), (req.facts, req.candidates), kinds)
                self.assertEqual(RW.label_of_row(row), S.label_of(req), kinds)

    def test_a_row_the_generator_cannot_write_is_refused(self) -> None:
        self.assertIsNotNone(RW.label_of_row(stored(BASE)))
        for name, change in REFUSED:
            row = copy.deepcopy(stored(BASE))
            change(row)
            self.assertIsNone(RW.parts_of(row), name)
            self.assertIsNone(RW.label_of_row(row), name)


if __name__ == "__main__":
    unittest.main()
