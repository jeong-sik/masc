# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the case rules in scripts/tinker/librarian/e_synth_audit.py.

Requests are invented. `e_synth_audit` imports the Tinker caller, which imports
openai, so this file runs with `uv run`. The decision rules are tested in
`test_tinker_librarian_audit_decisions.py`.
"""

from __future__ import annotations

import dataclasses
import itertools
import json
import random
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import audit_decisions as D
import e_synth_audit as A
import synth_render
import synth_rows as RW
import synth_spec as S
from tinker_librarian_synth_fixtures import KINDS, PLANTED, candidates_of
from tinker_librarian_synth_fixtures import request as synth_request

type JsonObject = dict[str, object]
K = S.CandidateKind


def candidate(kind: S.CandidateKind, target: str | None = None, claim: str = "claim") -> S.Candidate:
    return S.Candidate("memory-admission-0", 1, claim, "c", 0.0, None, "trace-0", kind, target)


def request(candidates: tuple[S.Candidate, ...], stale: frozenset[str] = frozenset(), facts: int = 20,
            claims: dict[str, str] | None = None, item_id: str = "eval-k-0") -> A.Request:
    return A.Request(item_id, "role", tuple(
        S.MemoryFact(f"m{i}", (claims or {}).get(f"m{i}", f"fact {i}"), "c", None, "2026-10-01T00:00:00Z",
                     f"m{i}" in stale, None)
        for i in range(1, facts + 1)), candidates)


def planted(kinds: tuple[S.CandidateKind, ...]) -> A.Request:
    """A request on the synth fixtures' memory: m4 is stale and m6 restates m5."""
    return A.Request("eval-k-0", "role", PLANTED, candidates_of(kinds))


def full_refs(case: JsonObject) -> list[str]:
    return [cast(str, f["ref"]) for f in cast(list[JsonObject], case["facts"])]


SIMILAR = "재시도는 세 번까지 하고 실패하면 담당자에게 넘긴다"


class CaseTest(unittest.TestCase):
    def test_every_case_shows_the_same_number_of_facts_in_full(self) -> None:
        few = request((candidate(K.NEW_DURABLE),))
        many = request((candidate(K.CORRECTION, "m4"), candidate(K.PARAPHRASE, "m9")), stale=frozenset({"m2"}))
        for req in (few, many):
            with self.subTest(candidates=len(req.candidates)):
                case, key = A.case_of("c001", req, set(), random.Random(1))
                self.assertEqual(len(full_refs(case)), A.FULL_FACTS)
                self.assertEqual(sorted(cast(dict[str, str], key["facts"])), sorted(full_refs(case)))

    def test_suspects_past_the_size_still_get_distractors(self) -> None:
        stale = frozenset(f"m{i}" for i in range(1, A.FULL_FACTS + 1))
        case, _ = A.case_of("c001", request((candidate(K.NEW_DURABLE),), stale=stale), set(), random.Random(1))
        self.assertEqual(len(full_refs(case)), A.FULL_FACTS + A.MIN_DISTRACTORS)

    def test_a_fact_worded_like_a_candidate_is_shown_in_full(self) -> None:
        req = request((candidate(K.NEW_DURABLE, claim=SIMILAR + "고 정했다"),), facts=40, claims={"m31": SIMILAR})
        case, _ = A.case_of("c001", req, set(), random.Random(1))
        self.assertIn("m31", full_refs(case))

    def test_the_key_names_every_kind_and_plant_in_judge_terms(self) -> None:
        req = planted((K.COMPLEMENT, K.CORRECTION, K.PARAPHRASE, K.NEW_DURABLE, K.TRANSIENT))
        case, key = A.case_of("c001", req, set(), random.Random(1))
        self.assertEqual(key["candidates"], {"k1": "complements:m1", "k2": "corrects:m2", "k3": "restates:m3",
                                             "k4": "new", "k5": "transient"})
        facts = cast(dict[str, str], key["facts"])
        self.assertEqual({m: facts[m] for m in ("m1", "m2", "m3", "m4", "m5", "m6")},
                         {"m1": "keep", "m2": "superseded:k2", "m3": "keep", "m4": "drop",
                          "m5": "restates:m6", "m6": "restates:m5"})
        self.assertTrue({"m4", "m5", "m6"} <= set(full_refs(case)))

    def test_a_decision_that_says_what_the_key_says_fits_for_every_mix_of_kinds(self) -> None:
        for n in (1, 2, 3):
            for kinds in itertools.product(KINDS, repeat=n):
                with self.subTest(kinds=[k.value for k in kinds]):
                    _, key = A.case_of("c001", planted(kinds), set(), random.Random(1))
                    self.assertEqual(D.misfits(key, key), ([], []))

    def test_every_row_is_read_before_any_is_picked(self) -> None:
        written = RW.row_of(synth_request(PLANTED, candidates_of((K.COMPLEMENT,))))
        earlier = json.loads(json.dumps(written))
        del cast(list[dict[str, object]], cast(JsonObject, earlier)["facts"])[0]["duplicate_of"]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "requests.jsonl"
            path.write_text(json.dumps({"request": written}, ensure_ascii=False) + "\n", encoding="utf-8")
            [read] = A.requests_of(path).values()
            self.assertEqual((read.role, read.facts, read.candidates[0].kind), ("문서 사이트를 돌보는 Keeper.", PLANTED,
                                                                                K.COMPLEMENT))
            path.write_text("".join(json.dumps({"request": r}, ensure_ascii=False) + "\n" for r in (written, earlier)),
                            encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, ":2: the request is not one synth_generate.py writes"):
                A.requests_of(path)

    def test_the_drop_cases_of_one_memory_show_the_same_facts(self) -> None:
        # Facts that differ between the cases of one memory would point at the dropped one.
        first = request((candidate(K.NEW_DURABLE),), facts=40)
        second = request((candidate(K.TRANSIENT),), facts=40, item_id="eval-k-1")
        drops: D.OffLabel = {"eval-k-0": {"m37": ["A"]}, "eval-k-1": {"m5": ["B"]}}
        full = A.drop_full_sets(drops, {"eval-k-0": first, "eval-k-1": second}, 20261109)
        cases = [A.render_case(f"d00{n}", req, full["eval-k"])[0] for n, req in enumerate((first, second))]
        self.assertEqual(full_refs(cases[0]), full_refs(cases[1]))
        self.assertTrue({"m37", "m5"} <= set(full_refs(cases[0])))
        self.assertEqual(len(full_refs(cases[0])), A.FULL_FACTS)

    def test_a_drop_case_shows_the_label_picks_of_every_request_of_its_memory(self) -> None:
        # Without them, a dropped fact a candidate restates is the one fact in full a candidate points at.
        first = request((candidate(K.PARAPHRASE, "m9"),), stale=frozenset({"m2"}), facts=40, claims={"m31": SIMILAR})
        second = dataclasses.replace(first, item_id="eval-k-1",
                                     candidates=(candidate(K.CORRECTION, "m14", claim=SIMILAR + "고 정했다"),))
        full = A.drop_full_sets({"eval-k-0": {"m9": ["A"]}}, {"eval-k-0": first, "eval-k-1": second}, 20261109)
        self.assertTrue(A.label_picks(first) | A.label_picks(second) <= full["eval-k"])
        self.assertTrue({"m2", "m9", "m14", "m31"} <= full["eval-k"])

    def test_one_fact_set_cannot_serve_requests_with_different_facts(self) -> None:
        first = request((candidate(K.NEW_DURABLE),))
        second = request((candidate(K.NEW_DURABLE),), facts=21, item_id="eval-k-1")
        with self.assertRaises(SystemExit):
            A.drop_full_sets({"eval-k-0": {"m3": ["A"]}}, {"eval-k-0": first, "eval-k-1": second}, 1)

    def test_the_judge_folder_holds_the_rules_judge_names_and_not_the_key(self) -> None:
        self.assertIn(f"`{D.RULES.as_posix()}`", A.JUDGE)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            A.write_cases(out, [{"case": "d001"}], [{"case": "d001", "item": "eval-k-0"}])
            judge = out / D.JUDGE_DIR
            given = sorted(["cases.jsonl", "judge.md", D.RULES.as_posix()])
            self.assertEqual((judge / D.RULES).read_bytes(), synth_render.TEMPLATE.read_bytes())
            self.assertEqual(sorted(p.relative_to(judge).as_posix() for p in judge.rglob("*") if p.is_file()), given)
            recorded = cast(dict[str, str], json.loads((out / D.JUDGE_FILES).read_text(encoding="utf-8")))
            self.assertEqual(recorded, {name: D.file_sha256(judge / name) for name in given})

    def test_cases_are_not_written_over_a_judge_folder_that_holds_decisions(self) -> None:
        # Decisions left there were made on the cases and rules written before.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            A.write_cases(out, [{"case": "d001"}], [{"case": "d001", "item": "eval-k-0"}])
            A.write_cases(out, [{"case": "d001"}], [{"case": "d001", "item": "eval-k-0"}])
            (out / D.JUDGE_DIR / D.DECISIONS).write_text('{"case": "d001"}\n', encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "already holds"):
                A.write_cases(out, [{"case": "d001"}], [{"case": "d001", "item": "eval-k-0"}])

    def test_a_record_that_leaves_out_a_given_file_stops_the_reading(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            A.write_cases(out, [{"case": "d001"}], [{"case": "d001", "item": "eval-k-0"}])
            (out / D.JUDGE_DIR / D.DECISIONS).write_text('{"case": "d001"}\n', encoding="utf-8")
            record = out / D.JUDGE_FILES
            files = cast(dict[str, str], json.loads(record.read_text(encoding="utf-8")))
            record.write_text(json.dumps({D.RULES.as_posix(): files[D.RULES.as_posix()]}), encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "other files"):
                D.judge_decisions(out, synth_render.TEMPLATE)

    def test_decisions_are_read_only_beside_the_files_the_judge_was_given(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            A.write_cases(out, [{"case": "d001"}], [{"case": "d001", "item": "eval-k-0"}])
            (out / D.JUDGE_DIR / D.DECISIONS).write_text('{"case": "d001"}\n', encoding="utf-8")
            self.assertEqual(D.judge_decisions(out, synth_render.TEMPLATE)[1], [{"case": "d001"}])
            with self.assertRaisesRegex(SystemExit, "is not"):
                D.judge_decisions(out, out / D.JUDGE_DIR / "judge.md")
            rules = out / D.JUDGE_DIR / D.RULES
            rules.write_bytes(rules.read_bytes() + b"\n")
            with self.assertRaisesRegex(SystemExit, "changed after"):
                D.judge_decisions(out, synth_render.TEMPLATE)
            rules.unlink()
            with self.assertRaisesRegex(SystemExit, "changed after"):
                D.judge_decisions(out, synth_render.TEMPLATE)


if __name__ == "__main__":
    unittest.main()
