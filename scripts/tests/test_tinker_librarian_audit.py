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

    def test_the_drop_cases_of_one_memory_show_the_same_facts(self) -> None:
        # Facts that differ between the cases of one memory would point at the dropped one.
        first = {**request([candidate("new_durable")], facts=40), "item_id": "eval-k-0"}
        second = {**request([candidate("transient")], facts=40), "item_id": "eval-k-1"}
        drops: D.OffLabel = {"eval-k-0": {"m37": ["A"]}, "eval-k-1": {"m5": ["B"]}}
        full = A.drop_full_sets(drops, {"eval-k-0": first, "eval-k-1": second}, 20261109)
        cases = [A.render_case(f"d00{n}", req, full["eval-k"])[0] for n, req in enumerate((first, second))]
        self.assertEqual(full_refs(cases[0]), full_refs(cases[1]))
        self.assertTrue({"m37", "m5"} <= set(full_refs(cases[0])))
        self.assertEqual(len(full_refs(cases[0])), A.FULL_FACTS)

    def test_a_drop_case_shows_the_label_picks_of_every_request_of_its_memory(self) -> None:
        # Without them, a dropped fact a candidate restates is the one fact in full a candidate points at.
        first = {**request([candidate("paraphrase", "m9")], stale=frozenset({"m2"}), facts=40), "item_id": "eval-k-0"}
        second = {**request([candidate("correction", "m14")]), "item_id": "eval-k-1", "facts": first["facts"]}
        cast(list[JsonObject], first["facts"])[30]["claim"] = "재시도는 세 번까지 하고 실패하면 담당자에게 넘긴다"
        cast(list[JsonObject], second["candidates"])[0]["claim"] = "재시도는 세 번까지 하고 실패하면 담당자에게 넘긴다고 정했다"
        full = A.drop_full_sets({"eval-k-0": {"m9": ["A"]}}, {"eval-k-0": first, "eval-k-1": second}, 20261109)
        self.assertTrue(A.label_picks(first) | A.label_picks(second) <= full["eval-k"])
        self.assertTrue({"m2", "m9", "m14", "m31"} <= full["eval-k"])

    def test_one_fact_set_cannot_serve_requests_with_different_facts(self) -> None:
        first = {**request([candidate("new_durable")]), "item_id": "eval-k-0"}
        second = {**request([candidate("new_durable")], facts=21), "item_id": "eval-k-1"}
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

    def test_a_kept_drop_stays_wrong_when_another_drop_takes_its_memory_out(self) -> None:
        drops: D.OffLabel = {"eval-k-0": {"m7": ["A"]}, "eval-k-1": {"m9": ["B"]}}
        facts = {"m7": "keep", "m9": "keep"}
        keys: list[JsonObject] = [{"case": f"d00{n + 1}", "item": item, "candidates": {"k1": "new"}, "facts": facts,
                                   "refs": ["m7", "m9"], "off_label": drops[item]}
                                  for n, item in enumerate(drops)]
        decisions: list[JsonObject] = [{"case": "d001", "candidates": {"k1": "new"}, "facts": {"m7": "keep", "m9": "drop"}},
                                       {"case": "d002", "candidates": {"k1": "new"}, "facts": {"m7": "keep", "m9": "drop"}}]
        judged = D.adjudicate(keys, decisions, drops)
        self.assertEqual(judged.excluded, frozenset({"eval-k"}))
        self.assertEqual(judged.wrong_outside(), {"A": 1})

    def test_cases_made_for_other_drops_or_missing_decisions_stop_the_verdict(self) -> None:
        with self.assertRaises(SystemExit):
            D.adjudicate([self.KEY], [], self.DROPS)
        with self.assertRaises(SystemExit):
            D.adjudicate([self.KEY], [{"case": "d001", "candidates": {"k1": "new"}, "facts": {"m2": "drop", "m7": "keep"}}],
                         {"eval-k-0": {"m7": ["A", "B"]}})

    def test_a_case_decided_twice_stops_the_verdict(self) -> None:
        decision: JsonObject = {"case": "d001", "candidates": {"k1": "new"}, "facts": {"m2": "drop", "m7": "keep"}}
        with self.assertRaises(SystemExit):
            D.adjudicate([self.KEY], [decision, {**decision, "facts": {"m2": "drop", "m7": "drop"}}], self.DROPS)

    def test_cases_of_one_memory_showing_different_facts_stop_the_verdict(self) -> None:
        drops: D.OffLabel = {"eval-k-0": {"m7": ["A"]}, "eval-k-1": {"m7": ["B"]}}
        keys: list[JsonObject] = [{**self.KEY, "off_label": drops["eval-k-0"]},
                                  {**self.KEY, "case": "d002", "item": "eval-k-1", "off_label": drops["eval-k-1"],
                                   "facts": {"m3": "keep", "m7": "keep"}, "refs": ["m3", "m7"]}]
        decisions: list[JsonObject] = [{"case": "d001", "candidates": {"k1": "new"}, "facts": {"m2": "drop", "m7": "keep"}},
                                       {"case": "d002", "candidates": {"k1": "new"}, "facts": {"m3": "keep", "m7": "keep"}}]
        with self.assertRaisesRegex(SystemExit, "other facts"):
            D.adjudicate(keys, decisions, drops)

    def test_a_case_without_every_drop_of_its_memory_stops_the_verdict(self) -> None:
        drops: D.OffLabel = {"eval-k-0": {"m7": ["A"]}, "eval-k-1": {"m9": ["B"]}}
        keys: list[JsonObject] = [{**self.KEY, "case": f"d00{n + 1}", "item": item, "off_label": drops[item]}
                                  for n, item in enumerate(drops)]
        decision: JsonObject = {"candidates": {"k1": "new"}, "facts": {"m2": "drop", "m7": "keep"}}
        with self.assertRaises(SystemExit):
            D.adjudicate(keys, [{**decision, "case": "d001"}, {**decision, "case": "d002"}], drops)


if __name__ == "__main__":
    unittest.main()
