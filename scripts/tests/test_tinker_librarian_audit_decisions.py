# pyright: strict
"""Tests for the decision rules in scripts/tinker/librarian/audit_decisions.py.

Keys, rows and decisions are invented. Keys follow the shape
`e_synth_audit.render_case` writes.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import audit_decisions as D

type JsonObject = dict[str, object]
KEEP = D.Classed[D.FactVerb]("keep", frozenset())


class VocabularyTest(unittest.TestCase):
    def test_classes_are_read_in_judge_terms_and_nothing_else(self) -> None:
        self.assertEqual(D.candidate_class("complements:m3"), D.Classed("complements", frozenset({"m3"})))
        self.assertEqual(D.candidate_class("restates:m7,m3"), D.Classed("restates", frozenset({"m3", "m7"})))
        self.assertEqual(D.fact_class("restates:m5"), D.Classed("restates", frozenset({"m5"})))
        self.assertEqual(D.fact_class("keep"), KEEP)
        refused = {"candidate": ("complements", "complements:m3,m4", "corrects:", "new:m3", "restates:m3,m3",
                                 "restates:m3,", "keep", "superseded:k1"),
                   "fact": ("keep:m1", "drop:k1", "superseded", "superseded:k1,k2", "restates", "new", "complements:m3")}
        for text in refused["candidate"]:
            self.assertIsNone(D.candidate_class(text), text)
        for text in refused["fact"]:
            self.assertIsNone(D.fact_class(text), text)
        self.assertEqual(D.Classed("restates", frozenset({"m7", "m3"})).text(), "restates:m3,m7")


class MisfitTest(unittest.TestCase):
    WANT_C = {"k1": "restates:m3", "k2": "corrects:m8", "k3": "complements:m4"}
    WANT_F = {"m3": "keep", "m4": "keep", "m5": "restates:m6", "m6": "restates:m5", "m8": "superseded:k2"}
    KEY: JsonObject = {"case": "c001", "candidates": WANT_C, "facts": WANT_F, "refs": ["m3", "m4", "m5", "m6", "m7", "m8"]}

    def misfits(self, **changed: str) -> tuple[list[str], list[str]]:
        return D.misfits(self.KEY, {"case": "c001", "candidates": {r: changed.get(r, w) for r, w in self.WANT_C.items()},
                                    "facts": {m: changed.get(m, w) for m, w in self.WANT_F.items()}})

    def test_a_decision_that_says_what_the_key_says_fits(self) -> None:
        self.assertEqual(self.misfits(), ([], []))

    def test_a_candidate_must_point_at_its_labelled_memory_alone(self) -> None:
        for ref, got in (("k1", "restates:m7"), ("k1", "restates:m3,m7"), ("k1", "new"),
                         ("k3", "corrects:m4"), ("k3", "new"), ("k3", "complements:m3")):
            self.assertEqual(tuple(map(len, self.misfits(**{ref: got}))), (1, 0), (ref, got))

    def test_a_fact_misfit_that_names_no_candidate_puts_the_memory_in_doubt(self) -> None:
        for mid, got in (("m5", "keep"), ("m6", "restates:m5,m7"), ("m3", "restates:m7"), ("m3", "drop")):
            self.assertEqual(tuple(map(len, self.misfits(**{mid: got}))), (0, 1), (mid, got))

    def test_a_fact_misfit_that_names_a_candidate_puts_the_request_in_doubt(self) -> None:
        for mid, got in (("m8", "keep"), ("m3", "superseded:k1"), ("m8", "superseded:k1")):
            self.assertEqual(tuple(map(len, self.misfits(**{mid: got}))), (1, 0), (mid, got))

    def test_a_class_naming_what_the_case_does_not_show_is_malformed(self) -> None:
        for ref, got in (("k1", "restates:m3,m9"), ("m3", "restates:m3"), ("m3", "superseded:m4"),
                         ("m3", "restates:k1"), ("k3", "complements:k1"), ("m3", "lost")):
            with self.assertRaises(SystemExit, msg=f"{ref} {got}"):
                self.misfits(**{ref: got})


def drop_row(target: str, item: str, off_label: list[str], unmerged: list[str] | None = None) -> JsonObject:
    return {"target": target, "item": item, "dropped_off_label": off_label, "dropped_unmerged": unmerged or []}


class DropTest(unittest.TestCase):
    DROPS: D.OffLabel = {"eval-k-0": {"m7": ["A"]}}
    KEY: JsonObject = {"case": "d001", "item": "eval-k-0", "candidates": {"k1": "new"},
                       "facts": {"m2": "drop", "m7": "keep"}, "refs": ["m2", "m7"], "off_label": {"m7": ["A"]}}

    def judge(self, m7: str) -> D.Adjudication:
        decision: JsonObject = {"case": "d001", "candidates": {"k1": "new"}, "facts": {"m2": "drop", "m7": m7}}
        return D.adjudicate([self.KEY], [decision], self.DROPS)

    def test_off_label_drops_are_grouped_by_item_with_their_targets(self) -> None:
        rows = [drop_row("base", "eval-k-0", ["m3"]), drop_row("A", "eval-k-0", ["m3"]),
                drop_row("B", "eval-k-0", ["m4"]), drop_row("A", "eval-k-1", [])]
        self.assertEqual(D.off_label(rows), {"eval-k-0": {"m3": ["A", "base"], "m4": ["B"]}})

    def test_a_kept_fact_leaves_the_drop_wrong(self) -> None:
        judged = self.judge("keep")
        self.assertEqual(judged.excluded, frozenset())
        self.assertEqual(judged.drops, (D.Judged("eval-k-0", "m7", ("A",), KEEP),))

    def test_a_fact_the_judge_takes_out_or_finds_restated_removes_its_memory(self) -> None:
        for m7 in ("drop", "superseded:k1", "restates:m2"):
            with self.subTest(judged=m7):
                self.assertEqual(self.judge(m7).excluded, frozenset({"eval-k"}))

    def test_no_target_is_scored_on_an_excluded_memory(self) -> None:
        rows = [drop_row("base", "eval-k-0", []), drop_row("A", "eval-k-1", ["m7"]), drop_row("A", "eval-j-0", [])]
        self.assertEqual([r["item"] for r in self.judge("drop").scored(rows)], ["eval-j-0"])

    def test_wrong_drops_on_an_excluded_memory_are_counted_apart(self) -> None:
        # A restated fact leaves by being absorbed, and a fact the label asks to absorb is not dropped.
        rows = [drop_row("A", "eval-k-0", ["m7"]), drop_row("B", "eval-k-1", [], ["m3"]),
                drop_row("B", "eval-j-0", [], ["m4"])]
        self.assertEqual(self.judge("drop").wrong_outside(rows), {"B": 1})
        self.assertEqual(self.judge("restates:m2").wrong_outside(rows), {"A": 1, "B": 1})
        record = self.judge("restates:m2").record(rows)
        self.assertEqual((record["off_label_drops"], record["items_scored"]),
                         ([{"item": "eval-k-0", "memory_id": "m7", "targets": ["A"], "judged": "restates:m2"}], 1))

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
        self.assertEqual(judged.wrong_outside([]), {"A": 1})

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
