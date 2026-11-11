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
from tinker_librarian_synth_fixtures import KINDS, PLANTED, SCHEDULED, candidates_of, request

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


def replacing(section: str, value: object) -> Change:
    def change(row: JsonObject) -> None:
        row[section] = value
    return change


def swapping_the_first_ids(row: JsonObject) -> None:
    facts = cast(list[JsonObject], row["facts"])
    facts[0]["memory_id"], facts[1]["memory_id"] = facts[1]["memory_id"], facts[0]["memory_id"]


def renaming_ids(row: JsonObject) -> None:
    """Every memory ID, and every reference to one, renamed: the same request under IDs the prompt does not show."""
    facts, candidates = cast(list[JsonObject], row["facts"]), cast(list[JsonObject], row["candidates"])
    renamed = {cast(str, f["memory_id"]): f"fact-{i}" for i, f in enumerate(facts)}
    for f in facts:
        f["memory_id"] = renamed[cast(str, f["memory_id"])]
        if f["duplicate_of"] is not None:
            f["duplicate_of"] = renamed[cast(str, f["duplicate_of"])]
    for c in candidates:
        if c["target_memory_id"] is not None:
            c["target_memory_id"] = renamed[cast(str, c["target_memory_id"])]


# k1 corrects m1, k2 restates m2, k3 is new; m4 is stale and m6 restates m5.
BASE = request(PLANTED, candidates_of((S.CandidateKind.CORRECTION, S.CandidateKind.PARAPHRASE,
                                       S.CandidateKind.NEW_DURABLE)))
REFUSED: tuple[tuple[str, Change], ...] = (
    ("a fact without duplicate_of", removing("facts", 0, "duplicate_of")),
    ("a fact without use_at", removing("facts", 0, "use_at")),
    ("a fact with another field", setting("facts", 0, "note", "x")),
    ("two facts with one memory ID", setting("facts", 2, "memory_id", "m1")),
    ("two facts with one claim", setting("facts", 1, "claim", PLANTED[0].claim)),
    ("facts out of their place", swapping_the_first_ids),
    ("memory IDs the prompt does not show", renaming_ids),
    ("a candidate worded as a fact", setting("candidates", 2, "claim", PLANTED[2].claim)),
    ("two candidates worded alike", setting("candidates", 1, "claim", BASE.candidates[0].claim)),
    ("no candidates", replacing("candidates", [])),
    ("candidates that are not a list", replacing("candidates", {})),
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
    ("facts that are not a list", replacing("facts", {})),
)
# The same request with m7 used ahead (11-09) and m8 used on 10-02; the candidates fall on 11-07.
WITH_RECORDS = request(SCHEDULED, BASE.candidates)
REFUSED_RECORDS: tuple[tuple[str, Change], ...] = (
    ("a use time not written as seen_at is", setting("facts", 6, "use_at", "2026-11-09")),
    ("a record ahead on the candidates' day", setting("facts", 6, "use_at", "2026-11-07T23:00:00Z")),
    ("a record ahead planted stale", setting("facts", 6, "planted_stale", True)),
    ("a past record on the candidates' day", setting("facts", 7, "use_at", "2026-11-07T00:30:00Z")),
    ("a past record used before it was written", setting("facts", 7, "use_at", "2026-09-30T09:00:00Z")),
    ("a past record left durable", setting("facts", 7, "planted_stale", False)),
    ("a target on a record", setting("candidates", 0, "target_memory_id", "m7")),
    ("a duplicate of a record", setting("facts", 5, "duplicate_of", "m7")),
    ("a record that restates a fact", setting("facts", 6, "duplicate_of", "m3")),
)


class RowTest(unittest.TestCase):
    def test_a_stored_row_reads_back_as_its_request_and_label(self) -> None:
        boarded = (dataclasses.replace(PLANTED[0], board=S.BoardRef("p-1", "c-1")),) + PLANTED[1:]
        for facts in (boarded, SCHEDULED):
            for n in (1, 2, 3):
                for kinds in itertools.product(KINDS, repeat=n):
                    req = request(facts, candidates_of(kinds))
                    row = stored(req)
                    self.assertEqual(RW.parts_of(row), (req.facts, req.candidates), kinds)
                    self.assertEqual(RW.label_of_row(row), S.label_of(req), kinds)

    def test_a_row_the_generator_cannot_write_is_refused(self) -> None:
        for base, refused in ((BASE, REFUSED), (WITH_RECORDS, REFUSED_RECORDS)):
            self.assertIsNotNone(RW.label_of_row(stored(base)))
            for name, change in refused:
                row = copy.deepcopy(stored(base))
                change(row)
                self.assertIsNone(RW.parts_of(row), name)
                self.assertIsNone(RW.label_of_row(row), name)


if __name__ == "__main__":
    unittest.main()
