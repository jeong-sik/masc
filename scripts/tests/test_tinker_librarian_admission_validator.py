# pyright: strict
"""Tests for scripts/tinker/librarian/admission_validator.py.

One valid answer, then one mutation per enforced rule that must fail with
exactly that rule's kind. Synthetic fixtures only (tinker_librarian_fixtures.py).
"""

from __future__ import annotations

import math
import sys
import unittest
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_validator as V
import yojson_wire as W

from tinker_librarian_fixtures import (
    COMMENT,
    M2,
    M3,
    NEW,
    make_prompt,
)


@dataclass(frozen=True, slots=True)
class Drop:
    """Remove the member."""


DROP = Drop()


def obj(*members: tuple[str, W.Json]) -> W.JsonObject:
    return W.JsonObject(members)


def edit(base: W.JsonObject, *changes: tuple[str, W.Json | Drop]) -> W.JsonObject:
    """Replace members in place, remove the ones set to DROP, append new ones."""
    members = list(base.members)
    for name, value in changes:
        at = next((index for index, (key, _) in enumerate(members) if key == name), None)
        match value:
            case Drop():
                members = [pair for pair in members if pair[0] != name]
            case _ if at is None:
                members.append((name, value))
            case _:
                members[at] = (name, value)
    return W.JsonObject(tuple(members))


NO_EVIDENCE = obj(("conversation", ()), ("tools", ()), ("counterpart", False), ("task_contexts", False))


CLAIM = obj(
    ("claim", NEW),
    ("category", "release_schedule"),
    ("board_post_id", None),
    ("board_comment_id", None),
    ("supersedes", "m1"),
    ("absorbs", ()),
    ("evidence", NO_EVIDENCE),
)


DROPPED = obj(("memory_id", "m1"), ("reason", "Corrected by r1."))


J1 = obj(
    ("request_id", "r1"),
    ("outcome", "incorporated"),
    ("memory_claim", NEW),
    ("reason", "A durable schedule change."),
)


J2 = obj(
    ("request_id", "r2"),
    ("outcome", "already_represented"),
    ("memory_claim", M2),
    ("reason", "m2 says this."),
)


J3 = obj(
    ("request_id", "r3"), ("outcome", "not_durable"), ("memory_claim", None), ("reason", "A one-off plan.")
)


def answer(
    new_claims: tuple[W.Json, ...] = (CLAIM,),
    dropped: tuple[W.Json, ...] = (DROPPED,),
    candidates: W.Json = (J1, J2, J3),
    support: tuple[W.Json, ...] = ("r1",),
    memory_changes: tuple[tuple[str, W.Json | Drop], ...] = (),
    top_changes: tuple[tuple[str, W.Json | Drop], ...] = (),
) -> W.JsonObject:
    memory = edit(
        obj(
            ("new_claims", new_claims),
            ("dropped", dropped),
            ("working_state", None),
            ("working_contexts", ()),
        ),
        *memory_changes,
    )
    return edit(
        obj(("memory", memory), ("candidates", candidates), ("change_support", support)), *top_changes
    )


def with_claim(*changes: tuple[str, W.Json | Drop]) -> str:
    return W.write(answer(new_claims=(edit(CLAIM, *changes),)))


VALID = W.write(answer())


MUTATIONS: dict[V.Kind, tuple[str, ...]] = {
    V.Kind.INVALID_JSON: ("```json\n" + VALID + "\n```",),
    V.Kind.DUPLICATE_MEMBER: (
        W.write(W.JsonObject(answer().members + (("change_support", ("r1",)),))),
        W.write(answer(new_claims=(W.JsonObject(CLAIM.members + (("claim", NEW),)),))),
    ),
    V.Kind.NON_FINITE_NUMBER: (with_claim(("evidence", edit(NO_EVIDENCE, ("conversation", (math.nan,))))),),
    V.Kind.NOT_AN_OBJECT: (W.write((answer(),)),),
    V.Kind.MISSING_REQUIRED_KEY: (W.write(answer(top_changes=(("change_support", DROP),))),),
    V.Kind.INCOMPATIBLE_SHAPE: (W.write(answer(candidates=obj())),),
    V.Kind.WRAPPER_FIELDS: (W.write(answer(top_changes=(("notes", "extra"),))),),
    V.Kind.JUDGMENT_NOT_OBJECT: (W.write(answer(candidates=(J1, "r2", J3))),),
    V.Kind.JUDGMENT_FIELDS: (W.write(answer(candidates=(J1, edit(J2, ("reason", DROP)), J3))),),
    V.Kind.JUDGMENT_REQUEST_ID_INVALID: (W.write(answer(candidates=(edit(J1, ("request_id", 1)), J2, J3))),),
    V.Kind.JUDGMENT_REASON_INVALID: (
        W.write(answer(candidates=(edit(J1, ("reason", "  ")), J2, J3))),
        W.write(answer(candidates=(edit(J1, ("reason", 5)), J2, J3))),
    ),
    V.Kind.JUDGMENT_OUTCOME_INVALID: (W.write(answer(candidates=(J1, edit(J2, ("outcome", "maybe")), J3))),),
    V.Kind.JUDGMENT_CLAIM_REQUIRED: (W.write(answer(candidates=(edit(J1, ("memory_claim", None)), J2, J3))),),
    V.Kind.JUDGMENT_CLAIM_NOT_NULL: (
        W.write(answer(candidates=(J1, J2, edit(J3, ("memory_claim", "A one-off plan."))))),
    ),
    V.Kind.CHANGE_SUPPORT_ITEM_INVALID: (
        W.write(answer(support=("r1", " "))),
        W.write(answer(support=(1,))),
    ),
    V.Kind.UNKNOWN_REQUEST_ID: (
        W.write(answer(candidates=(J1, J2, J3, edit(J3, ("request_id", "r9"))))),
        W.write(answer(candidates=(edit(J1, ("request_id", " r1")), J2, J3))),
    ),
    V.Kind.DUPLICATE_REQUEST_ID: (W.write(answer(candidates=(J1, J2, J3, J1))),),
    V.Kind.MISSING_REQUEST_ID: (W.write(answer(candidates=(J1, J2))),),
    V.Kind.MEMORY_UNEXPECTED_FIELD: (W.write(answer(memory_changes=(("notes", "extra"),))),),
    V.Kind.CLAIM_UNEXPECTED_FIELD: (with_claim(("confidence", 0.9)),),
    V.Kind.DROPPED_UNEXPECTED_FIELD: (W.write(answer(dropped=(edit(DROPPED, ("supersedes", "m2")),))),),
    V.Kind.CLAIM_NOT_OBJECT: (W.write(answer(new_claims=(NEW,))),),
    V.Kind.CLAIM_TEXT_INVALID: (with_claim(("claim", " \t")),),
    V.Kind.CLAIM_CATEGORY_INVALID: (with_claim(("category", "Release Schedule")),),
    V.Kind.CLAIM_BOARD_INVALID: (
        with_claim(("board_comment_id", COMMENT)),
        with_claim(("board_post_id", "bad id!")),
        with_claim(("board_post_id", "p-release"), ("board_comment_id", "c-123")),
    ),
    V.Kind.CLAIM_SUPERSEDES_INVALID: (with_claim(("supersedes", 1)),),
    V.Kind.CLAIM_ABSORBS_INVALID: (with_claim(("absorbs", "m2")),),
    V.Kind.CLAIM_EVIDENCE_INVALID: (with_claim(("evidence", edit(NO_EVIDENCE, ("conversation", "0")))),),
    V.Kind.DROPPED_NOT_OBJECT: (W.write(answer(dropped=("m1",))),),
    V.Kind.DROPPED_MEMORY_ID_INVALID: (W.write(answer(dropped=(edit(DROPPED, ("memory_id", " ")),))),),
    V.Kind.DROPPED_REASON_INVALID: (
        W.write(answer(dropped=(edit(DROPPED, ("reason", None)),))),
        W.write(answer(dropped=(edit(DROPPED, ("reason", "  ")),))),
    ),
    V.Kind.UNKNOWN_DROPPED_MEMORY_ID: (W.write(answer(dropped=(edit(DROPPED, ("memory_id", "m9")),))),),
    V.Kind.ABSORBS_UNKNOWN_MEMORY_ID: (with_claim(("absorbs", ("m9",))),),
    V.Kind.ABSORBS_DROPPED_MEMORY_ID: (with_claim(("absorbs", ("m1",))),),
    V.Kind.ABSORBS_MEMORY_ID_TWICE: (
        with_claim(("absorbs", ("m3", "m3"))),
        W.write(
            answer(
                new_claims=(
                    edit(CLAIM, ("absorbs", ("m3",))),
                    edit(
                        CLAIM,
                        ("claim", "Freeze starts Wednesday noon."),
                        ("supersedes", None),
                        ("absorbs", ("m3",)),
                    ),
                )
            )
        ),
    ),
    V.Kind.DUPLICATE_DROPPED_MEMORY_ID: (W.write(answer(dropped=(DROPPED, DROPPED))),),
    V.Kind.DROPPED_MEMORY_ID_RECREATED: (
        W.write(
            answer(
                new_claims=(CLAIM, edit(CLAIM, ("claim", M2), ("supersedes", None))),
                dropped=(DROPPED, edit(DROPPED, ("memory_id", "m2"))),
            )
        ),
    ),
    V.Kind.EVIDENCE_NOT_IN_INPUT: (with_claim(("evidence", edit(NO_EVIDENCE, ("conversation", (0,))))),),
    V.Kind.SUPERSEDES_UNKNOWN_MEMORY_ID: (with_claim(("supersedes", "m9")),),
    V.Kind.SUPERSEDES_NOT_DROPPED: (with_claim(("supersedes", "m2")),),
    V.Kind.MEMORY_CLAIM_ABSENT: (
        W.write(answer(candidates=(edit(J1, ("memory_claim", "Releases ship daily.")), J2, J3))),
        W.write(answer(candidates=(edit(J1, ("memory_claim", NEW + " ")), J2, J3))),
    ),
    V.Kind.DUPLICATE_CHANGE_SUPPORT: (W.write(answer(support=("r1", "r1"))),),
    V.Kind.UNKNOWN_CHANGE_SUPPORT: (W.write(answer(support=("r9",))),),
    V.Kind.UNSETTLED_CHANGE_SUPPORT: (
        W.write(answer(support=("r1", "r3"))),
        W.write(answer(candidates=(J1, J2, edit(J3, ("outcome", "deferred"))), support=("r1", "r3"))),
    ),
    V.Kind.NEW_CLAIM_WITHOUT_SUPPORT: (
        W.write(answer(support=("r2",))),
        W.write(answer(candidates=(edit(J1, ("outcome", "already_represented")), J2, J3))),
        # A claim that revises a dropped memory is an addition, with or without absorbs.
        W.write(answer(support=())),
        W.write(answer(new_claims=(edit(CLAIM, ("absorbs", ("m3",))),), support=())),
    ),
}


class ValidatorTest(unittest.TestCase):
    def test_valid_answer(self) -> None:
        result = V.validate(make_prompt(), VALID)
        assert isinstance(result, V.Valid), result
        accepted = result.answer
        self.assertEqual(
            tuple(judgment.outcome for judgment in accepted.judgments),
            ("incorporated", "already_represented", "not_durable"),
        )
        self.assertFalse(accepted.deferred)
        self.assertEqual(accepted.added_claims, (NEW,))
        self.assertEqual(accepted.dropped, ("m1",))
        self.assertEqual(accepted.revisions, (("m1", NEW),))
        self.assertEqual(accepted.memory_after, (M2, M3, NEW))

    def test_all_deferred_is_valid_and_deferred(self) -> None:
        deferred = tuple(edit(row, ("outcome", "deferred"), ("memory_claim", None)) for row in (J1, J2, J3))
        text = W.write(answer(new_claims=(), dropped=(), candidates=deferred, support=()))
        result = V.validate(make_prompt(), text)
        assert isinstance(result, V.Valid), result
        self.assertTrue(result.answer.deferred)

    def test_drops_and_merges_need_no_support(self) -> None:
        # RFC-0517 §7.1: change_support covers additions only. No candidate names NEW here.
        unnamed = (
            edit(J1, ("outcome", "not_durable"), ("memory_claim", None)),
            edit(J2, ("outcome", "not_durable"), ("memory_claim", None)),
            J3,
        )
        merge = edit(CLAIM, ("supersedes", None), ("absorbs", ("m2", "m3")))
        cases = {
            "drop": (answer(new_claims=(), candidates=unnamed, support=()), (), ("m1",)),
            "merge": (answer(new_claims=(merge,), dropped=(), candidates=unnamed, support=()), (NEW,), ()),
            "merge and drop": (answer(new_claims=(merge,), candidates=unnamed, support=()), (NEW,), ("m1",)),
        }
        for name, (text, added, dropped) in cases.items():
            with self.subTest(case=name):
                result = V.validate(make_prompt(), W.write(text))
                assert isinstance(result, V.Valid), result
                self.assertEqual(result.answer.added_claims, added)
                self.assertEqual(result.answer.dropped, dropped)

    def test_every_kind_has_a_mutation(self) -> None:
        self.assertEqual(set(MUTATIONS), set(V.Kind))

    def test_each_mutation_fails_with_its_kind(self) -> None:
        prompt = make_prompt()
        for kind, texts in MUTATIONS.items():
            for number, text in enumerate(texts):
                with self.subTest(kind=kind.value, mutation=number):
                    result = V.validate(prompt, text)
                    assert isinstance(result, V.Invalid), result
                    self.assertEqual([violation.kind for violation in result.violations], [kind])

    def test_masc_reason_texts(self) -> None:
        prompt = make_prompt()
        expected = {
            V.Kind.NEW_CLAIM_WITHOUT_SUPPORT: "admission_invalid: new Memory claim has no incorporated supporting candidate",
            V.Kind.JUDGMENT_OUTCOME_INVALID: 'admission_invalid: candidates[1].outcome: this build does not know the token "maybe"',
            V.Kind.CLAIM_CATEGORY_INVALID: "claim_schema_mismatch",
            V.Kind.MISSING_REQUIRED_KEY: "missing required key $.change_support",
            V.Kind.SUPERSEDES_NOT_DROPPED: "supersedes_not_dropped: " + V.memory_id(M2),
        }
        for kind, detail in expected.items():
            with self.subTest(kind=kind.value):
                result = V.validate(prompt, MUTATIONS[kind][0])
                assert isinstance(result, V.Invalid), result
                self.assertEqual(result.violations[0].detail, detail)

    def test_masc_accepts_what_strict_json_refuses(self) -> None:
        # Yojson reads comments and surrounding space.
        commented = "/* answer */ " + VALID.replace('"tools":[]', '"tools":[] // none\n')
        self.assertIsInstance(V.validate(make_prompt(), commented), V.Valid)
        self.assertIsInstance(V.validate(make_prompt(), " \n" + VALID + "\n"), V.Valid)

    def test_masc_accepts_what_only_the_prompt_forbids(self) -> None:
        # Short ids, supersedes and board ids are trimmed; working_contexts items
        # and working_state are not checked; absent evidence cites nothing.
        accepted = (
            W.write(answer(dropped=(edit(DROPPED, ("memory_id", " m1 ")),))),
            with_claim(("supersedes", " m1\t")),
            with_claim(("board_post_id", " p-release "), ("board_comment_id", COMMENT)),
            with_claim(("evidence", DROP), ("absorbs", DROP), ("board_post_id", DROP)),
            with_claim(("evidence", None), ("absorbs", None)),
            W.write(answer(memory_changes=(("working_contexts", (1, "x")), ("working_state", 5)))),
            W.write(answer(top_changes=(("change_support", ("r1", "r2")),))),
        )
        for number, text in enumerate(accepted):
            with self.subTest(case=number):
                self.assertIsInstance(V.validate(make_prompt(), text), V.Valid)

    def test_masc_reads_any_integer_length_and_depth(self) -> None:
        # Checked against a MASC harness (Yojson 3.0.0) on 2026-11-09: it accepts all three.
        # CPython's int() refuses past 4300 digits and a recursive reader stopped near 500 levels.
        depth = 100_000
        for value in ("1" * 5000, "[" * depth + "]" * depth, '{"a":' * depth + "1.0" + "}" * depth):
            with self.subTest(length=len(value)):
                text = VALID.replace('"working_state":null', '"working_state":' + value)
                self.assertIsInstance(V.validate(make_prompt(), text), V.Valid)
        broken = VALID.replace('"working_state":null', '"working_state":' + "[" * depth + "]" * (depth - 1))
        result = V.validate(make_prompt(), broken)
        assert isinstance(result, V.Invalid)
        self.assertEqual(result.violations[0].kind, V.Kind.INVALID_JSON)

    def test_the_first_refusal_in_source_order_wins(self) -> None:
        # Same kinds from the MASC harness on 2026-11-09: an object's names are
        # checked before its members, and members in source order.
        cases = (('{"b":NaN,"a":1,"a":2}', V.Kind.DUPLICATE_MEMBER),
                 ('[{"x":NaN},{"a":1,"a":2}]', V.Kind.NON_FINITE_NUMBER),
                 ('[{"a":1,"a":2},{"x":NaN}]', V.Kind.DUPLICATE_MEMBER))
        for value, kind in cases:
            with self.subTest(value=value):
                text = VALID.replace('"working_state":null', '"working_state":' + value)
                result = V.validate(make_prompt(), text)
                assert isinstance(result, V.Invalid)
                self.assertEqual(result.violations[0].kind, kind)

    def test_category_grammar(self) -> None:
        for name in ("fact", "release_schedule", "a1_b2", "x"):
            self.assertTrue(V.category_valid(name), name)
        for name in ("", "all", "dropped", "Release", "a__b", "a_", "_a", "1a", "a-b"):
            self.assertFalse(V.category_valid(name), name)


if __name__ == "__main__":
    unittest.main()
