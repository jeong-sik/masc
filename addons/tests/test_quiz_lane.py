"""Questioner and grader over real stdio. No Docker image, host, or Keeper is exercised.

`host_deck` imitates what the host does to a snapshot file before a worker sees
it (lane_addon_sources.ml snapshot_file): each observation's evidence starts with
the host's own copy of the deck, `lane-evidence:<sha256>`.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import unittest

ADDONS = Path(__file__).resolve().parents[1]
ROW_FIELDS = {"id", "lane_id", "kind", "title", "observed_at", "subject_id", "clock",
              "actor", "fields", "evidence", "related_ids"}
THREAD = "masc://board/p-c08eb2f4f2f9d4083ca9c8fa347a25cc"
HOST_COPY = {"uri": "lane-evidence:" + "a" * 64, "sha256": "a" * 64}
CONTEXT = {"instance_id": "grader-1", "incarnation": "grader-1"}


def fact(ident, field, subject, answer, comment, record=True):
    item = {"id": ident, "kind": "fact", "observed_at": 1790175000, "actor": "indie-geek-blue",
            "field": field, "subject": subject, "answer": answer, "evidence": [HOST_COPY]}
    if record:
        item["record"] = {"uri": f"{THREAD}#{comment}", "sha256": None}
    return item


# Facts read from the 09-23 add-on thread; each names the comment that states it.
DECK = [
    fact("f-live-path", "author", "라이브 lane.toml 에 sha256 ID 가 적힌 경로를 확인한 댓글",
         "lane-smith", "c-65cd3d4c94fce33f239e1382dc8515c3"),
    fact("f-tick", "author", "retire → re-attach tick 표를 그린 댓글",
         "code-reviewer", "c-35a72702ba83bb3ccf1aad5fb8b97028"),
    fact("f-truncate", "author", "Activity 줄이 이미지 ID 를 자른다는 측정 댓글",
         "tui-developer", "c-9a322c281720d429edb82b6c3c17190f"),
    fact("f-preview", "author", "inspect_image 가 설치 미리보기에서만 불린다는 댓글",
         "indie-geek-blue", "c-22257f2b821ebe38add42a31cdc03790"),
    fact("f-owner", "claimant", "add-on 재시도 루프 코드 수정", "code-reviewer",
         "c-eb89ca25f9e3df1331430019a8021ae7"),
]
ANSWER = {f["id"]: f["answer"] for f in DECK}


def deck_source(observations, incarnation="deck-2026-09-23", complete=True):
    return {"source_id": "deck", "incarnation": incarnation, "cursor": None,
            "complete": complete, "detail": None, "observations": copy.deepcopy(observations)}


def run(package, calls):
    requests = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}}]
    requests += [{"jsonrpc": "2.0", "id": i + 1, "method": "tools/call",
                  "params": {"name": name, "arguments": args}} for i, (name, args) in enumerate(calls)]
    proc = subprocess.run([sys.executable, str(ADDONS / package / "server.py")],
                          input="".join(json.dumps(r) + "\n" for r in requests),
                          text=True, capture_output=True, check=True, timeout=10)
    assert proc.stderr == "", proc.stderr
    return [json.loads(line)["result"] for line in proc.stdout.splitlines()][1:]


def ask(sources):
    return run("quiz-questions", [("lane_observe", {"binding": {"sources": []}, "sources": sources})])[0]


def as_lane_output(questions_output):
    return {"source_id": "questions", "incarnation": "questioner-1", "cursor": None,
            "complete": True, "detail": None, "observations": [{
                "id": "questioner-1/output/1", "kind": "lane_output", "observed_at": 1790175100,
                "actor": None, "evidence": [HOST_COPY],
                "producer": {"installation_id": "quiz-questions"},
                "output": questions_output}]}


class Questioner(unittest.TestCase):
    def test_every_choice_is_a_recorded_answer_and_no_key_is_published(self):
        result = ask([deck_source(DECK)])
        self.assertFalse(result["isError"])
        output = result["structuredContent"]
        authors = {f["answer"] for f in DECK if f["field"] == "author"}
        by_subject = {row["subject_id"]: row for row in output["rows"]}
        self.assertEqual(set(by_subject), {"f-live-path", "f-tick", "f-truncate", "f-preview"})
        for row in output["rows"]:
            self.assertEqual(set(row), ROW_FIELDS)
            self.assertEqual(row["lane_id"], "quiz/questions")
            self.assertTrue(set(row["fields"]["choices"]) <= authors)
            self.assertEqual(len(row["fields"]["choices"]), 4)
            self.assertIn(HOST_COPY, row["evidence"])
            self.assertTrue(any(e["uri"].startswith(THREAD) for e in row["evidence"]))
            self.assertNotIn('"answer"', json.dumps(row["fields"], ensure_ascii=False))

    def test_same_deck_gives_same_questions(self):
        self.assertEqual(ask([deck_source(DECK)]), ask([deck_source(DECK)]))

    def test_right_answer_position_varies(self):
        rows = ask([deck_source(DECK)])["structuredContent"]["rows"]
        positions = {row["fields"]["choices"].index(ANSWER[row["subject_id"]]) for row in rows}
        self.assertGreater(len(positions), 1)

    def test_a_single_distinct_answer_is_not_a_question(self):
        output = ask([deck_source(DECK)])["structuredContent"]
        self.assertNotIn("f-owner", {row["subject_id"] for row in output["rows"]})
        self.assertFalse(output["coverage"][0]["complete"])
        self.assertIn("claimant", output["coverage"][0]["detail"])

    def test_unknown_field_is_named_not_guessed(self):
        deck = DECK[:4] + [fact("f-x", "mood", "오늘 밤", "좋음", "c-x")]
        output = ask([deck_source(deck)])["structuredContent"]
        self.assertEqual(len(output["rows"]), 4)
        self.assertIn("mood", output["coverage"][0]["detail"])

    def test_host_evidence_alone_is_not_a_record(self):
        # The host always adds its own copy to `evidence`; that must not pass for a record.
        deck = DECK[:3] + [fact("f-bare", "author", "근거 없는 주장", "someone", "c-y", record=False)]
        result = ask([deck_source(deck)])
        self.assertTrue(result["isError"])
        self.assertIn("has no record", result["content"][0]["text"])

    def test_citing_the_host_copy_is_not_a_record(self):
        deck = DECK[:3] + [dict(fact("f-self", "author", "자기 인용", "someone", "c-z"),
                                record=HOST_COPY)]
        result = ask([deck_source(deck)])
        self.assertTrue(result["isError"])
        self.assertIn("host copy", result["content"][0]["text"])

    def test_no_deck_is_incomplete_not_empty_success(self):
        output = ask([])["structuredContent"]
        self.assertEqual(output["rows"], [])
        self.assertFalse(output["coverage"][0]["complete"])


class Grader(unittest.TestCase):
    def setUp(self):
        self.questions = ask([deck_source(DECK)])["structuredContent"]
        self.by_subject = {row["subject_id"]: row for row in self.questions["rows"]}

    def observe(self, deck=None):
        return ("lane_observe", {"context": CONTEXT, "binding": {},
                                 "sources": [as_lane_output(self.questions), deck or deck_source(DECK)]})

    def answer(self, request_id, subject, choice, answerer="masc-tui"):
        question_id = self.by_subject[subject]["fields"]["question_id"]
        action = {"kind": "answer", "question_id": question_id, "choice": choice}
        if answerer:
            action["answerer"] = answerer
        return ("lane_act", {"context": CONTEXT, "request_id": request_id, "action": action})

    def wrong_choice(self, subject):
        return next(c for c in self.by_subject[subject]["fields"]["choices"] if c != ANSWER[subject])

    def test_right_and_wrong_answers_are_graded_by_the_record(self):
        results = run("quiz-grader", [self.observe(),
                                      self.answer("r1", "f-live-path", "lane-smith"),
                                      self.answer("r2", "f-tick", self.wrong_choice("f-tick"))])
        right, wrong = results[1]["structuredContent"], results[2]["structuredContent"]
        self.assertEqual(right["status"], "confirmed")
        self.assertTrue(right["result"]["correct"])
        self.assertFalse(wrong["result"]["correct"])
        grades = [r for r in wrong["output"]["rows"] if r["lane_id"] == "quiz/grades"]
        self.assertEqual([g["fields"]["correct"] for g in grades], [True, False])
        self.assertEqual(grades[1]["fields"]["answer"], "code-reviewer")
        # The grade cites the deck's record exactly as the deck carries it (code-reviewer c-16c77fe9).
        self.assertEqual(grades[1]["evidence"], [next(f["record"] for f in DECK if f["id"] == "f-tick")])
        score = next(r for r in wrong["output"]["rows"] if r["lane_id"] == "quiz/score")
        self.assertEqual((score["fields"]["answered"], score["fields"]["correct"]), (2, 1))
        for row in wrong["output"]["rows"]:
            self.assertEqual(set(row), ROW_FIELDS)

    def test_the_grader_ignores_who_says_they_are_right(self):
        # Claiming to be the questioner or grader does not change the comparison.
        results = run("quiz-grader", [self.observe(),
                                      self.answer("r1", "f-truncate", self.wrong_choice("f-truncate"),
                                                  answerer="quiz-grader")])
        self.assertFalse(results[1]["structuredContent"]["result"]["correct"])

    def test_repeated_request_returns_the_same_grade_once(self):
        results = run("quiz-grader", [self.observe(),
                                      self.answer("r1", "f-preview", "indie-geek-blue"),
                                      self.answer("r1", "f-preview", "indie-geek-blue")])
        self.assertEqual(results[1], results[2])
        rows = results[2]["structuredContent"]["output"]["rows"]
        self.assertEqual(sum(r["lane_id"] == "quiz/grades" for r in rows), 1)

    def test_a_new_request_id_is_not_a_second_attempt(self):
        # Found by the 09-23 rehearsal: retrying with a fresh request_id inflated the score.
        results = run("quiz-grader", [self.observe(),
                                      self.answer("r1", "f-tick", self.wrong_choice("f-tick")),
                                      self.answer("r2", "f-tick", "code-reviewer"),
                                      self.answer("r3", "f-tick", "code-reviewer", answerer="lane-smith")])
        self.assertEqual(results[2]["structuredContent"]["status"], "failed_before_effect")
        self.assertIn("first grade", results[2]["structuredContent"]["result"]["reason"])
        self.assertEqual(results[3]["structuredContent"]["status"], "confirmed")
        score = next(r for r in results[3]["structuredContent"]["output"]["rows"]
                     if r["lane_id"] == "quiz/score")["fields"]
        self.assertEqual((score["answered"], score["correct"]), (2, 1))
        self.assertEqual(score["by_claimed_label"], {"masc-tui": {"answered": 1, "correct": 0, "about_self": 0},
                                                "lane-smith": {"answered": 1, "correct": 1, "about_self": 0}})

    def test_answering_a_question_about_yourself_is_counted_apart(self):
        # code-reviewer c-70d137e0: the author of the quoted comment answers from memory.
        results = run("quiz-grader", [self.observe(),
                                      self.answer("r1", "f-tick", "code-reviewer", answerer="code-reviewer"),
                                      self.answer("r2", "f-live-path", "lane-smith", answerer="code-reviewer")])
        rows = results[2]["structuredContent"]["output"]["rows"]
        grades = [r for r in rows if r["lane_id"] == "quiz/grades"]
        self.assertEqual([g["fields"]["about_answerer"] for g in grades], [True, False])
        self.assertEqual([g["fields"]["correct"] for g in grades], [True, True])
        score = next(r for r in rows if r["lane_id"] == "quiz/score")["fields"]
        self.assertEqual((score["answered"], score["correct"]), (2, 2))
        self.assertEqual(score["excluding_claimed_about_answerer"], {"answered": 1, "correct": 1})
        self.assertEqual(score["answerer_basis"], "self_claimed_label")
        self.assertEqual(score["by_claimed_label"]["code-reviewer"]["about_self"], 1)

    def test_answers_outside_the_question_are_refused_before_effect(self):
        foreign = ("lane_act", {"context": CONTEXT, "request_id": "r9", "action": {
            "kind": "answer", "question_id": "not-a-question", "choice": "x"}})
        results = run("quiz-grader", [self.observe(), foreign,
                                      self.answer("r2", "f-tick", "someone-not-offered")])
        for result in results[1:]:
            self.assertEqual(result["structuredContent"]["status"], "failed_before_effect")
        self.assertIn("latest observed questions", results[1]["structuredContent"]["result"]["reason"])
        self.assertIn("not one of", results[2]["structuredContent"]["result"]["reason"])

    def test_a_changed_deck_does_not_grade_old_questions(self):
        changed = deck_source(DECK, incarnation="deck-2026-09-24")
        results = run("quiz-grader", [self.observe(changed),
                                      self.answer("r1", "f-live-path", "lane-smith")])
        body = results[1]["structuredContent"]
        self.assertEqual(body["status"], "failed_before_effect")
        self.assertIn("deck changed", body["result"]["reason"])

    def test_no_questions_observed_means_no_grade(self):
        results = run("quiz-grader", [self.answer("r1", "f-live-path", "lane-smith")])
        self.assertEqual(results[0]["structuredContent"]["status"], "failed_before_effect")

    def test_another_incarnation_is_refused(self):
        other = ("lane_act", {"context": {"instance_id": "grader-2", "incarnation": "grader-2"},
                              "request_id": "r1", "action": {"kind": "answer", "question_id": "q",
                                                             "choice": "c"}})
        results = run("quiz-grader", [self.observe(), other])
        self.assertEqual(results[1]["structuredContent"]["status"], "failed_before_effect")
        self.assertIn("different worker incarnation", results[1]["structuredContent"]["result"]["reason"])


class BuildDeckTest(unittest.TestCase):
    """The deck builder's entrance check (code-reviewer on #38433)."""

    def build(self, quote, answer):
        import importlib.util, tempfile
        path = ADDONS / "quiz-questions" / "skills" / "quiz-deck" / "scripts" / "build_deck.py"
        spec = importlib.util.spec_from_file_location("build_deck", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "record.txt").write_text(f"header\n{quote}\nfooter\n")
            candidate = {"id": "f1", "field": "status", "subject": "s", "answer": answer,
                         "quote": quote, "record": {"uri": "masc://board/p-x", "file": "record.txt"}}
            deck, rejected = module.build([candidate], Path(tmp), "deck-test")
        return [o["answer"] for o in deck["observations"]], rejected

    def test_an_answer_inside_a_longer_word_is_refused(self):
        accepted, rejected = self.build("status: unmerged", "merged")
        self.assertEqual(accepted, [])
        self.assertIn("whole word", rejected[0])

    def test_a_whole_word_next_to_punctuation_or_a_particle_is_accepted(self):
        self.assertEqual(self.build("status: merged.", "merged"), (["merged"], []))
        self.assertEqual(self.build("code-reviewer가 맡았다", "code-reviewer"), (["code-reviewer"], []))


if __name__ == "__main__":
    unittest.main()
