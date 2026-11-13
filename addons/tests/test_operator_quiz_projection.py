"""The operator quiz's rows on a fixed two-week history (RFC operator-quiz §8,
§14): R over later-local-day re-asks, P over posed questions, the debt map,
and no key before an answer."""
from __future__ import annotations

from datetime import datetime
from pathlib import Path
import sys
import unittest
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "operator-quiz"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # records.py

import quiz_log as q  # noqa: E402
import quiz_projection as p  # noqa: E402

SEOUL = ZoneInfo("Asia/Seoul")
GRANTS = (q.Grant("board", "board", ()),)
SOURCE = q.Source("board_post", "board", "p-1", "the ledger records facts", "a" * 64)
QUESTION = {"question_id": "q1", "header": "Ledger", "prompt": "What does it hold?", "mode": "single",
            "free_text": {"kind": "choices_only"},
            "choices": [{"choice_id": "a", "label": "Facts", "description": None},
                        {"choice_id": "b", "label": "Plans", "description": None}]}
RESPONSES = {"correct": q.Chose(("a",)), "incorrect": q.Chose(("b",)), "skipped": q.Skipped(),
             "wrote": q.Wrote("facts, I think")}


def at(day: int, hour: int, minute: int = 0) -> float:
    return datetime(2026, 10, day, hour, minute, tzinfo=SEOUL).timestamp()


def asked(n: int, item: str, topic: str, when: float) -> list[q.Event]:
    session = f"s{n:02d}"
    return [q.SessionOpened(session, f"act-{n}", 1, GRANTS, "ko", when - 60),
            q.Posed(session, f"{session}-ask", "q1", item, topic, QUESTION, q.ChoiceKey(("a",)), (SOURCE,))]


def answered(n: int, item: str, topic: str, when: float, response: str) -> list[q.Event]:
    return asked(n, item, topic, when) + [
        q.AnswerReceived(f"s{n:02d}-ask", (q.Answer("q1", RESPONSES[response]),), {"surface": "dashboard"}, when)]


# Two weeks in Seoul. Comments say what each item adds to R.
HISTORY: list[q.Event] = [
    # i1: missed, right again the same evening (not a later day), right two days later: recovered.
    *answered(1, "i1", "ledger", at(1, 8, 30), "incorrect"),
    *answered(2, "i1", "ledger", at(1, 20), "correct"),
    *answered(3, "i1", "ledger", at(3, 8, 30), "correct"),
    # i2: skipped, then wrong on a later day: not recovered.
    *answered(4, "i2", "ledger", at(2, 8, 30), "skipped"),
    *answered(5, "i2", "ledger", at(4, 8, 30), "incorrect"),
    # i3: missed and never asked again: not counted.
    *answered(6, "i3", "keepers", at(2, 9), "incorrect"),
    # i4: never missed: not counted.
    *answered(7, "i4", "keepers", at(5, 8, 30), "correct"),
    *answered(8, "i4", "keepers", at(8, 8, 30), "correct"),
    # i5: missed at 23:30 and right at 00:30, the next day in Seoul (the same day in UTC): recovered.
    *answered(9, "i5", "asks", at(6, 23, 30), "incorrect"),
    *answered(10, "i5", "asks", at(7, 0, 30), "correct"),
    # i6: missed, then a written answer that waits for a judgment: not counted.
    *answered(11, "i6", "asks", at(9, 8, 30), "incorrect"),
    *answered(12, "i6", "asks", at(14, 8, 30), "wrote"),
    # One question still open on the last day.
    *asked(13, "i7", "asks", at(14, 9)),
]


class TwoWeeks(unittest.TestCase):
    def setUp(self):
        self.output = p.observation(q.fold(HISTORY), {}, SEOUL, at(14, 12))

    def rows(self, lane: str) -> list[dict]:
        return [row for row in self.output["rows"] if row["lane_id"] == lane]

    def test_r_counts_items_with_a_miss_and_a_later_local_day_attempt(self):
        (measures,) = self.rows(p.MEASURES)
        self.assertEqual(measures["fields"]["recovery"], {"n": 2, "d": 3})

    def test_r_reads_the_day_in_the_operators_time_zone(self):
        utc = p.observation(q.fold(HISTORY), {}, ZoneInfo("UTC"), at(14, 12))
        (measures,) = [row for row in utc["rows"] if row["lane_id"] == p.MEASURES]
        self.assertEqual(measures["fields"]["recovery"], {"n": 1, "d": 2})

    def test_p_is_graded_attempts_over_posed_questions(self):
        (measures,) = self.rows(p.MEASURES)
        self.assertEqual(measures["fields"]["participation"], {"n": 11, "d": 13})
        self.assertEqual(measures["fields"]["score"], {"n": 5, "d": 11})
        self.assertFalse({"pass", "passed", "target", "met"} & set(measures["fields"]))

    def test_an_open_question_shows_no_source_in_items_or_topics(self):
        events = asked(1, "i9", "fresh", at(1, 9))
        output = p.observation(q.fold(events), {}, SEOUL, at(1, 10))
        self.assertEqual([row["lane_id"] for row in output["rows"]], [p.SESSIONS, p.MEASURES])
        self.assertNotIn(SOURCE.quote, str(output))

    def test_an_open_question_has_no_reveal_row_and_no_key_anywhere(self):
        questions = self.rows(p.QUESTIONS)
        self.assertEqual(len(questions), 12)
        self.assertNotIn("s13/q1", {row["subject_id"] for row in questions})
        (open_session,) = [row for row in self.rows(p.SESSIONS) if row["subject_id"] == "s13"]
        self.assertEqual(open_session["fields"]["counts"]["open"], 1)
        self.assertNotIn("key", str(open_session["fields"]))

    def test_the_debt_map_counts_items_whose_latest_attempt_is_a_miss(self):
        topics = {row["subject_id"]: row["fields"] for row in self.rows(p.TOPICS)}
        self.assertEqual({topic: fields["open_debt"] for topic, fields in topics.items()},
                         {"ledger": 1, "keepers": 1, "asks": 0})
        self.assertEqual([item["item_id"] for item in topics["ledger"]["open_debt_items"]], ["i2"])
        self.assertEqual(topics["ledger"]["last_miss_at"], at(4, 8, 30))

    def test_a_skip_left_as_the_latest_attempt_is_open_debt(self):
        events = HISTORY + answered(20, "i4", "keepers", at(14, 10), "skipped")
        output = p.observation(q.fold(events), {}, SEOUL, at(14, 12))
        (keepers,) = [row for row in output["rows"] if row["lane_id"] == p.TOPICS and row["subject_id"] == "keepers"]
        self.assertEqual(keepers["fields"]["open_debt"], 2)

    def test_a_written_answer_waits_and_is_not_graded(self):
        (reveal,) = [row for row in self.rows(p.QUESTIONS) if row["subject_id"] == "s12/q1"]
        self.assertEqual((reveal["fields"]["verdict"], reveal["fields"]["by"]), ("awaiting_judgment", None))

    def test_rows_without_new_facts_are_the_same_at_a_later_observation(self):
        later = p.observation(q.fold(HISTORY), {}, SEOUL, at(15, 12))
        self.assertEqual(later, self.output)

    def test_a_judgment_that_changes_a_verdict_counts_in_g_and_shows_on_its_reveal(self):
        events = HISTORY + [
            q.GradeRequested("s07-ask", "q1", "s07-ask-grade-q1-0", "1" * 64),
            q.Judged("s07-ask", "q1", q.Incorrect(), "the post says plans too", "s07-ask-grade-q1-0"),
            q.GradeRequested("s12-ask", "q1", "s12-ask-grade-q1-0", "2" * 64),
            q.Judged("s12-ask", "q1", q.Correct(), "names facts", "s12-ask-grade-q1-0")]
        output = p.observation(q.fold(events), {}, SEOUL, at(14, 12))
        (measures,) = [row for row in output["rows"] if row["lane_id"] == p.MEASURES]
        self.assertEqual(measures["fields"]["changed_grades"], {"n": 1, "d": 12})
        reveals = {row["subject_id"]: row["fields"] for row in output["rows"] if row["lane_id"] == p.QUESTIONS}
        self.assertEqual((reveals["s07/q1"]["verdict"], reveals["s07/q1"]["by"]), ("incorrect", "judgment"))
        self.assertEqual([j["rationale"] for j in reveals["s07/q1"]["judgments"]], ["the post says plans too"])
        self.assertEqual((reveals["s12/q1"]["verdict"], reveals["s12/q1"]["grading"]), ("correct", None))

    def test_a_void_judgment_is_no_attempt_and_a_waiting_grade_shows(self):
        events = HISTORY + [
            q.GradeRequested("s07-ask", "q1", "s07-ask-grade-q1-0", "1" * 64),
            q.Judged("s07-ask", "q1", q.Void(), "no", "s07-ask-grade-q1-0"),
            q.GradeRequested("s12-ask", "q1", "s12-ask-grade-q1-0", "2" * 64)]
        output = p.observation(q.fold(events), {}, SEOUL, at(14, 12))
        (measures,) = [row for row in output["rows"] if row["lane_id"] == p.MEASURES]
        self.assertEqual(measures["fields"]["participation"], {"n": 10, "d": 13})
        (i4,) = [row for row in output["rows"] if row["lane_id"] == p.ITEMS and row["subject_id"] == "i4"]
        self.assertEqual(len(i4["fields"]["attempts"]), 1)
        reveals = {row["subject_id"]: row["fields"] for row in output["rows"] if row["lane_id"] == p.QUESTIONS}
        self.assertEqual(reveals["s07/q1"]["verdict"], "void")
        self.assertEqual(reveals["s12/q1"]["grading"], {"state": "waiting", "request_id": "s12-ask-grade-q1-0"})

    def test_a_failed_session_shows_its_typed_reason(self):
        events = HISTORY + [q.SessionOpened("s20", "act-20", 1, GRANTS, "ko", at(14, 10)),
                            q.SessionFailed("s20", q.AuthorInvalidOutput("s20-author-0"))]
        output = p.observation(q.fold(events), {"s20": "all"}, SEOUL, at(14, 12))
        (failed,) = [row for row in output["rows"] if row["subject_id"] == "s20"]
        self.assertEqual(failed["fields"]["failure"], {"kind": "author_invalid_output", "request_id": "s20-author-0"})
        self.assertEqual(failed["fields"]["history_scope"], "all")
        (measures,) = [row for row in output["rows"] if row["lane_id"] == p.MEASURES]
        self.assertEqual(measures["fields"]["failed_sessions"], {"author_invalid_output": 1})

    def test_the_scorecard_windows_anchor_on_the_last_answer_day(self):
        cards = {row["subject_id"]: row["fields"] for row in self.rows(p.SCORECARD)}
        self.assertEqual(set(cards), {"day", "7d", "30d", "all"})
        # The last answer is s12's written one on day 14: the anchor day, with
        # nothing graded inside the one-day window.
        self.assertEqual(cards["day"]["anchor_local_date"], "2026-10-14")
        self.assertEqual(cards["day"]["graded"], 0)
        self.assertEqual(cards["day"]["score"], {"n": 0, "d": 0})
        # Days 8..14 hold two graded answers: i4's recovery on day 8 and
        # s11's miss on day 9.
        self.assertEqual((cards["7d"]["graded"], cards["7d"]["incorrect"]),
                         (2, 1))
        self.assertEqual(cards["7d"]["miss_topics"], [{"topic": "asks", "misses": 1}])
        # The whole log agrees with the measures row it stands next to.
        self.assertEqual(cards["all"]["score"], {"n": 5, "d": 11})
        self.assertEqual(cards["30d"]["score"], {"n": 5, "d": 11})

    def test_the_scorecard_all_window_matches_measures(self):
        (measures,) = self.rows(p.MEASURES)
        (whole,) = [row for row in self.rows(p.SCORECARD) if row["subject_id"] == "all"]
        self.assertEqual(whole["fields"]["score"], measures["fields"]["score"])
        self.assertEqual(whole["fields"]["graded"], measures["fields"]["participation"]["n"])

    def test_review_rows_carry_the_last_answer_of_each_unrecovered_miss(self):
        review = {row["subject_id"]: row["fields"] for row in self.rows(p.REVIEW)}
        self.assertEqual(set(review), {"i2", "i3"})
        self.assertEqual(review["i2"]["response"], {"kind": "chose", "choice_ids": ["b"]})
        self.assertEqual(review["i2"]["key"], {"kind": "choices", "choice_ids": ["a"]})
        self.assertEqual(review["i2"]["question"]["header"], "Ledger")
        self.assertEqual((review["i2"]["latest"], review["i2"]["attempts"]), ("incorrect", 2))
        self.assertEqual(review["i2"]["last_miss_at"], at(4, 8, 30))
        self.assertEqual(review["i3"]["last_miss_at"], at(2, 9))
        (i2,) = [row for row in self.rows(p.REVIEW) if row["subject_id"] == "i2"]
        self.assertEqual(i2["evidence"],
                         [{"uri": f"lane-evidence:{'a' * 64}", "sha256": "a" * 64}])

    def test_no_scorecard_or_review_row_before_any_answer(self):
        events = asked(1, "i9", "fresh", at(1, 9))
        output = p.observation(q.fold(events), {}, SEOUL, at(1, 10))
        self.assertNotIn(p.SCORECARD, {row["lane_id"] for row in output["rows"]})
        self.assertNotIn(p.REVIEW, {row["lane_id"] for row in output["rows"]})

    def test_a_void_latest_pose_is_not_the_notes_question(self):
        # Missed by choice on day 1, re-asked as a written question on day 3
        # and judged void: the void pose is not an attempt, so the note keeps
        # the day-1 choice question, not the voided one.
        events = HISTORY + answered(21, "i8", "asks", at(1, 9), "incorrect") \
            + asked(22, "i8", "asks", at(3, 8, 30)) + [
                q.AnswerReceived("s22-ask", (q.Answer("q1", q.Wrote("plans?")),),
                                 {"surface": "dashboard"}, at(3, 8, 31)),
                q.GradeRequested("s22-ask", "q1", "s22-ask-grade-q1-0", "3" * 64),
                q.Judged("s22-ask", "q1", q.Void(), "the quote is gone", "s22-ask-grade-q1-0")]
        output = p.observation(q.fold(events), {}, SEOUL, at(4, 12))
        (note,) = [row for row in output["rows"] if row["lane_id"] == p.REVIEW
                   and row["subject_id"] == "i8"]
        fields = note["fields"]
        self.assertEqual(fields["question"]["mode"], "single")
        self.assertEqual(fields["response"], {"kind": "chose", "choice_ids": ["b"]})
        self.assertEqual(fields["by"], "key")
        self.assertEqual(fields["last_miss_at"], at(1, 9))

    def test_a_written_latest_answer_is_not_open_debt_and_gets_no_review_row(self):
        # i6's latest attempt waits for a judgment: no wrong-answer note yet.
        self.assertNotIn("i6", {row["subject_id"] for row in self.rows(p.REVIEW)})


if __name__ == "__main__":
    unittest.main()
