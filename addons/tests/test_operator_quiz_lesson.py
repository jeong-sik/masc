#!/usr/bin/env python3
"""A quiz that follows a lesson (RFC operator-quiz-follows-lesson): what it
keeps of the lesson output an observation carries, and which records its
author request then holds."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_operator_quiz_flow as t  # noqa: E402
from test_operator_quiz_flow import BINDING, Base, answering, f, first_quote, g, post, q  # noqa: E402
from test_operator_quiz_worker import BINDING as WORKER_BINDING, CONTEXT, Worker  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "operator-quiz"))
import quiz_projection as p  # noqa: E402

INSTANCE = "lesson-1"
SOURCE = {"source_id": "lesson", "kind": "lane_output", "installation_id": "operator-lesson",
          "output_id": "scenes", "selection": "latest_completed"}
FOLLOWING = BINDING | {"sources": [SOURCE]}


def cite(pin: str, source_id: str = "board", kind: str = "board_post") -> dict:
    return {"paragraph": 0, "kind": kind, "source_id": source_id, "pin": pin, "quote": "a quote", "sha256": "a" * 64}


def scene_row(entry: str, *cites: dict, instance: str = INSTANCE) -> dict:
    return {"id": f"{instance}/1/{entry}", "lane_id": f"{instance}/lesson/scenes", "kind": "value",
            "title": f"scene {entry}", "observed_at": 1.0, "subject_id": f"s-1/{entry}", "clock": None, "actor": None,
            "fields": {"session_id": "s-1", "entry_id": entry, "title": f"scene {entry}", "body": "a body",
                       "sources": list(cites), "written_at": 1.0},
            "evidence": [], "related_ids": []}


def lesson_output(seq: int, *rows: dict, complete: bool = True, instance: str = INSTANCE) -> dict:
    """The source envelope the host builds for a lane_output binding."""
    return {"source_id": "lesson", "incarnation": instance, "cursor": str(seq), "complete": complete,
            "detail": None if complete else "latest completed output has incomplete source or worker coverage",
            "observations": [{
                "id": f"{instance}/output/{seq}", "kind": "lane_output", "observed_at": 5.0, "actor": None,
                "producer": {"installation_id": "operator-lesson", "instance_id": instance, "run_id": "study",
                             "configuration_revision": "c", "package_revision": "0.2.0", "observation_seq": seq,
                             "output_id": "scenes", "output_selection": {"lanes": ["lesson/scenes"]},
                             "coverage_scope": "whole_producer"},
                "output": {"rows": list(rows), "coverage": []}, "sampling_receipts": [],
                "producer_status": {"source_id": instance, "incarnation": instance, "cursor": None,
                                    "complete": complete, "detail": None},
                "evidence": [{"uri": f"lane-evidence:{seq:064x}", "sha256": f"{seq:064x}"}]}]}


UNAVAILABLE = {"source_id": "lesson", "incarnation": "unobserved", "cursor": None, "complete": False,
               "detail": "upstream installation belongs to another run", "observations": []}


class Binding(unittest.TestCase):
    def test_a_binding_names_no_lesson_or_one_scenes_output(self):
        self.assertIsNone(f.lesson_source_of_binding(BINDING | {"sources": []}))
        self.assertEqual(f.lesson_source_of_binding(FOLLOWING), "lesson")
        for sources in (None, [SOURCE, SOURCE], ["lesson"], [SOURCE | {"kind": "snapshot_file"}],
                        [SOURCE | {"output_id": "lesson"}], [{k: v for k, v in SOURCE.items() if k != "output_id"}],
                        [SOURCE | {"selection": "all"}], [SOURCE | {"source_id": ""}], [SOURCE | {"path": "x"}]):
            with self.assertRaises(f.InvalidBinding, msg=sources):
                f.lesson_source_of_binding(BINDING | {"sources": sources})


class Seeing(Base):
    def seen(self) -> list[q.Event]:
        return [e for e in self.flow.log.read() if isinstance(e, (q.LessonSeen, q.LessonUnreadable))]

    def test_an_installation_bound_to_no_lesson_keeps_nothing(self):
        self.assertIsNone(self.flow.see_lesson(BINDING | {"sources": []}, [lesson_output(1, scene_row("e1", cite("p-1")))]))
        self.assertEqual(self.flow.log.read(), [])

    def test_one_output_is_kept_once_however_often_it_is_observed(self):
        output = lesson_output(1, scene_row("e1", cite("p-1"), cite("p-1"), cite("p-2")), scene_row("e2", cite("p-3")))
        for _ in range(3):
            self.assertEqual(self.flow.see_lesson(FOLLOWING, [output]), {"complete": True, "detail": None})
        # The same scenes under a later sequence number: the host renumbers the row ids.
        later = lesson_output(7, scene_row("e1", cite("p-1"), cite("p-1"), cite("p-2")) | {"id": f"{INSTANCE}/7/e1"},
                              scene_row("e2", cite("p-3")) | {"id": f"{INSTANCE}/7/e2"})
        self.flow.see_lesson(FOLLOWING, [later])
        (event,) = self.seen()
        self.assertEqual((event.instance_id, event.observation_seq, event.sha256), (INSTANCE, 1, f"{1:064x}"))
        self.assertEqual([(scene.entry_id, [cite.pin for cite in scene.cites]) for scene in event.scenes],
                         [("e1", ["p-1", "p-2"]), ("e2", ["p-3"])])
        self.flow.see_lesson(FOLLOWING, [lesson_output(2, scene_row("e3", cite("p-2")))])
        self.assertEqual(len(self.seen()), 2)
        self.assertEqual(q.cited(self.flow.log.read()),
                         {q.Cite("board_post", "board", pin) for pin in ("p-1", "p-2", "p-3")})
        # The log reads back as written, new events included.
        self.assertEqual(q.Log(self.state).read(), self.flow.log.read())

    def test_an_output_with_one_wrong_row_counts_for_nothing(self):
        good = scene_row("e1", cite("p-1"))
        wrong = [scene_row("e2", cite("p-2", kind="tweet")), scene_row("e2"), scene_row("e2", cite("p-2") | {"quote": ""}),
                 scene_row("e2", cite("p-2")) | {"lane_id": f"{INSTANCE}/lesson/sessions"},
                 scene_row("e2", cite("p-2"), instance="another"), {"fields": None}, "row"]
        for seq, row in enumerate(wrong, start=1):
            self.flow.see_lesson(FOLLOWING, [lesson_output(seq, good, row)])
        events = self.seen()
        self.assertEqual([type(event) for event in events], [q.LessonUnreadable] * len(wrong))
        self.assertEqual(q.cited(self.flow.log.read()), frozenset())
        # An unreadable output is not recorded again either, and the readable one after it is.
        self.flow.see_lesson(FOLLOWING, [lesson_output(len(wrong) + 1, good, wrong[0])])
        self.assertEqual(len(self.seen()), len(wrong))
        self.flow.see_lesson(FOLLOWING, [lesson_output(len(wrong) + 2, good)])
        self.assertEqual([cite.pin for cite in q.cited(self.flow.log.read())], ["p-1"])

    def test_a_source_without_an_output_keeps_nothing_and_says_why(self):
        self.assertEqual(self.flow.see_lesson(FOLLOWING, [UNAVAILABLE]),
                         {"complete": False, "detail": "upstream installation belongs to another run"})
        self.assertEqual(self.flow.see_lesson(FOLLOWING, []),
                         {"complete": False, "detail": "the host supplied no source of this name"})
        self.assertEqual(self.flow.log.read(), [])

    def test_rows_once_unreadable_are_kept_when_they_can_be_read(self):
        output = lesson_output(1, scene_row("e1", cite("p-1")))
        key = f.digest([[row["lane_id"], row["fields"]] for row in output["observations"][0]["output"]["rows"]])
        # What an earlier revision that could not read these rows left behind.
        self.flow.log.append([q.LessonUnreadable(INSTANCE, 1, f"{1:064x}", key, "a kind it did not know")])
        self.flow.see_lesson(FOLLOWING, [output])
        self.flow.see_lesson(FOLLOWING, [output])
        self.assertEqual([type(event) for event in self.seen()], [q.LessonUnreadable, q.LessonSeen])
        self.assertEqual(len(q.cited(q.Log(self.state).read())), 1)

    def test_an_output_of_a_failing_lesson_is_still_kept(self):
        status = self.flow.see_lesson(FOLLOWING, [lesson_output(1, scene_row("e1", cite("p-1")), complete=False)])
        self.assertEqual(status["complete"], False)
        self.assertEqual(len(self.seen()), 1)

    def test_an_observation_without_the_hosts_shape_is_refused_and_keeps_nothing(self):
        output = lesson_output(1, scene_row("e1", cite("p-1")))
        for broken in ({"producer": {}}, {"evidence": []}, {"output": {"rows": None}}):
            source = output | {"observations": [output["observations"][0] | broken]}
            with self.assertRaises(f.InvalidResult, msg=broken):
                self.flow.see_lesson(FOLLOWING, [source])
        self.assertEqual(self.flow.log.read(), [])


class Following(Base):
    def material(self) -> list[str]:
        (request,) = [r for r in self.flow.listing() if r["kind"] == "exact_output"]
        return [m["pin"] for m in json.loads(request["messages"][0]["text"])["material"]]

    def read(self) -> None:
        """Delivers reads until the author request is listed."""
        self.host.author = lambda payload: None
        self.host.run(self.flow)

    def test_a_session_that_does_not_follow_sees_every_record(self):
        self.flow.see_lesson(FOLLOWING, [lesson_output(1, scene_row("e1", cite("p-2")))])
        session_id = self.compose()
        self.read()
        self.assertEqual(self.material(), ["p-1", "p-2", "p-3"])
        self.assertEqual((self.session(session_id).follows, self.session(session_id).scopes), (None, ()))

    def test_the_author_sees_only_the_records_a_lesson_cited(self):
        self.flow.see_lesson(FOLLOWING, [lesson_output(1, scene_row("e1", cite("p-2"), cite("p-9")))])
        session_id = self.flow.compose("act-1", 1, BINDING, 0.0, lesson="lesson")
        self.read()
        self.assertEqual(self.material(), ["p-2"])
        session = self.session(session_id)
        self.assertEqual(session.follows, "lesson")
        self.assertEqual([[cite.pin for cite in scope.kept] for scope in session.scopes], [["p-2"]])

    def test_the_same_pin_under_another_source_id_or_kind_is_another_record(self):
        self.flow.see_lesson(FOLLOWING, [lesson_output(1, scene_row(
            "e1", cite("p-1", source_id="notes"), cite("p-2", kind="wiki_page") | {"pin": "p-2@1"}))])
        session_id = self.flow.compose("act-1", 1, BINDING, 0.0, lesson="lesson")
        self.read()
        self.assertEqual(self.session(session_id).failure, q.NoMaterial())

    def test_a_session_with_nothing_cited_fails_and_the_next_reads_the_same_records(self):
        first = self.flow.compose("act-1", 1, BINDING, 0.0, lesson="lesson")
        self.read()
        self.assertEqual((self.session(first).state, self.session(first).failure), ("failed", q.NoMaterial()))
        self.flow.see_lesson(FOLLOWING, [lesson_output(1, scene_row("e1", cite("p-3")))])
        self.host.listed.clear()
        second = self.flow.compose("act-2", 1, BINDING, 1.0, lesson="lesson")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        reads = [r for r in self.host.listed if r["kind"] == "read_records"]
        self.assertEqual((reads[0]["after"], reads[0]["since"]), (None, 0.0))
        session = self.session(second)
        self.assertEqual((session.state, [posed.sources[0].pin for posed in session.posed]), ("asked", ["p-3"]))
        self.assertEqual(session.taught, frozenset({"q1"}))

    def test_with_nothing_cited_an_earlier_item_is_still_asked_again(self):
        plain = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.answer(plain, q.Chose(("b",)))
        self.host.board.append(post(4, "a lane rests until its slot answers"))
        seen = []
        self.host.author = lambda payload: seen.append(payload) or {"status": "invalid_output", "detail": "x"}
        self.flow.compose("act-2", 1, BINDING, 1.0, lesson="lesson")
        self.host.run(self.flow)
        (payload,) = seen
        self.assertEqual((payload["material"], len(payload["items"])), ([], 1))

    def test_a_request_of_history_alone_that_does_not_fit_fails_the_session(self):
        plain = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.answer(plain, q.Chose(("b",)))
        self.flow.fits = lambda request: request["kind"] != "exact_output"
        session_id = self.flow.compose("act-2", 1, BINDING, 1.0, lesson="lesson")
        self.host.run(self.flow)
        self.assertIsInstance(self.session(session_id).failure, q.AuthorRequestExceedsFrame)

    def test_a_compose_sent_again_completes_an_opening_cut_before_follows_lesson(self):
        session_id = self.flow.compose("act-1", 1, BINDING, 0.0, lesson="lesson")
        log = self.state / "operator-quiz" / "log.jsonl"
        opened, follows = log.read_text().splitlines()
        log.write_text(opened + "\n" + follows[:10])
        cut = f.Flow(self.state, self.flow.prompts, lambda request: True)
        self.assertIsNone(next(s for s in cut.sessions() if s.session_id == session_id).follows)
        self.assertEqual(cut.compose("act-1", 1, BINDING, 0.0, lesson="lesson"), session_id)
        self.assertEqual(cut.compose("act-1", 1, BINDING, 0.0, lesson="lesson"), session_id)
        self.assertEqual([type(event) for event in cut.log.read()], [q.SessionOpened, q.FollowsLesson])
        # A session that has read already is left as it is.
        other = self.compose("act-2")
        self.host.author = lambda payload: None
        self.host.run(self.flow)
        before = q.Log(self.state).read()
        self.flow.compose("act-2", 1, BINDING, 1.0, lesson="lesson")
        self.assertEqual((q.Log(self.state).read(), self.session(other).follows), (before, None))

    def test_a_question_is_taught_only_if_the_lesson_was_seen_before_it(self):
        session_id = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.flow.see_lesson(FOLLOWING, [lesson_output(1, scene_row("e1", cite("p-1")))])
        self.assertEqual(self.session(session_id).taught, frozenset())

    def test_a_log_written_before_this_reads_as_it_did(self):
        session_id = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        lines = (self.state / "operator-quiz" / "log.jsonl").read_text().splitlines()
        self.assertTrue(all(json.loads(line)["event"] in {"session_opened", "material_read", "exact_requested",
                                                           "author_context_recorded", "posed"} for line in lines))
        session = self.session(session_id)
        self.assertEqual((session.follows, session.scopes, session.taught), (None, (), frozenset()))


class History(unittest.TestCase):
    def test_a_fold_refuses_lesson_events_that_contradict_the_log(self):
        opened = q.SessionOpened("s", "a", 1, f.grants_of_binding(BINDING), "ko", 0.0)
        seen = q.LessonSeen(INSTANCE, 1, "a" * 64, "b" * 64, ())
        for events in ([seen, q.LessonUnreadable(INSTANCE, 2, "c" * 64, "b" * 64, "x")],
                       [q.FollowsLesson("s", "lesson")],
                       [opened, q.FollowsLesson("s", "lesson"), q.FollowsLesson("s", "lesson")],
                       [opened, q.MaterialRead("s", "r", "d"), q.FollowsLesson("s", "lesson")],
                       [opened, q.LessonScopeApplied("s", "r", ())],
                       [opened, q.FollowsLesson("s", "lesson"), q.LessonScopeApplied("s", "r", ())]):
            with self.assertRaises(q.LogError, msg=events):
                q.fold(events)

    def test_a_cite_whose_pin_is_not_of_its_kind_does_not_read_back(self):
        for value in ({"kind": "tweet", "source_id": "board", "pin": "p-1"},
                      {"kind": "repo_file", "source_id": "masc", "pin": "not-a-commit:path"},
                      {"kind": "board_post", "source_id": "", "pin": "p-1"},
                      {"kind": "board_post", "source_id": "board", "pin": "p-1", "quote": "x"}):
            with self.assertRaises(q.LogError, msg=value):
                q.Cite.of_json(value)


class Rows(Base):
    def test_rows_say_which_questions_were_taught_and_count_first_attempts_apart(self):
        plain = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.answer(plain, q.Chose(("b",)), at=10.0)
        self.host.board.append(post(4, "a lane rests until its slot answers"))
        self.flow.see_lesson(FOLLOWING, [lesson_output(1, scene_row("e1", cite("p-4"), cite("p-9")))])
        self.flow.see_lesson(FOLLOWING, [lesson_output(2, scene_row("e2", cite("p-4", kind="tweet")))])
        taught = self.flow.compose("act-2", 1, BINDING, 1.0, lesson="lesson")
        self.host.run(self.flow)
        self.answer(taught, q.Chose(("a",)), at=20.0)
        sessions = self.flow.sessions()
        lesson = p.lesson_measures(sessions, self.flow.log.read(), {"complete": True, "detail": None})
        self.assertEqual(lesson, {"scenes_seen": 1, "cites_seen": 2, "cites_unmatched": 1, "unreadable": 1,
                                  "source": {"complete": True, "detail": None},
                                  "first_attempt": {"taught": p.fraction(1, 1), "other": p.fraction(0, 1)}})
        scopes = {session.session_id: self.flow.history_scope(session) for session in sessions}
        output = p.observation(sessions, scopes, ZoneInfo("Asia/Seoul"), 99.0, None, lesson)
        questions = {row["fields"]["session_id"]: row["fields"]["taught"]
                     for row in output["rows"] if row["lane_id"] == p.QUESTIONS}
        self.assertEqual(questions, {plain: False, taught: True})
        (review,) = [row for row in output["rows"] if row["lane_id"] == p.REVIEW]
        self.assertEqual(review["fields"]["taught"], False)
        measures = next(row for row in output["rows"] if row["lane_id"] == p.MEASURES)["fields"]
        self.assertEqual(measures["lesson"], lesson)
        unbound = p.observation(sessions, scopes, ZoneInfo("Asia/Seoul"), 99.0)
        self.assertNotIn("lesson", next(row for row in unbound["rows"] if row["lane_id"] == p.MEASURES)["fields"])
        self.assertFalse(any("taught" in row["fields"] for row in unbound["rows"]))
        self.assertEqual(g.items(sessions)[0].latest, g.INCORRECT)


    def test_the_first_attempt_of_an_item_is_its_first_answer(self):
        early = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        item = self.session(early).posed[0].item_id
        self.flow.see_lesson(FOLLOWING, [lesson_output(1, scene_row("e1", cite("p-1")))])
        self.host.author = answering(lambda payload: t.draft(
            {"kind": "board_post", "source_id": "board", "pin": "p-1"}, "the ledg", reask=(item,)))
        late = self.flow.compose("act-2", 1, BINDING, 1.0, lesson="lesson")
        self.host.run(self.flow)
        self.assertEqual(self.session(late).taught, frozenset({"q1"}))
        self.answer(late, q.Chose(("a",)), at=10.0)
        self.answer(early, q.Chose(("b",)), at=20.0)
        measures = p.lesson_measures(self.flow.sessions(), self.flow.log.read(), None)
        self.assertEqual(measures["first_attempt"], {"taught": p.fraction(1, 1), "other": p.fraction(0, 0)})


class Served(unittest.TestCase):
    def test_a_worker_keeps_the_lesson_at_an_observation_and_follows_it_at_compose(self):
        with tempfile.TemporaryDirectory() as temporary:
            worker = Worker(Path(temporary))
            try:
                binding = WORKER_BINDING | {"sources": [SOURCE]}
                observe = lambda sources: worker.ok(  # noqa: E731
                    "lane_observe", {"context": CONTEXT, "binding": binding, "sources": sources})
                measures = lambda output: next(  # noqa: E731
                    row for row in output["rows"] if row["lane_id"] == "quiz/measures")["fields"]["lesson"]
                self.assertEqual(measures(observe([UNAVAILABLE])),
                                 {"scenes_seen": 0, "cites_seen": 0, "cites_unmatched": 0, "unreadable": 0,
                                  "source": {"complete": False,
                                             "detail": "upstream installation belongs to another run"},
                                  "first_attempt": {"taught": p.fraction(0, 0), "other": p.fraction(0, 0)}})
                output = lesson_output(1, scene_row("e1", cite("p-2")))
                self.assertEqual(measures(observe([output]))["cites_seen"], 1)
                self.assertEqual(measures(observe([output]))["scenes_seen"], 1)
                worker.act("act-1", {"kind": "compose", "questions": 1})
                events = [json.loads(line)["event"] for line in
                          (Path(temporary) / "operator-quiz" / "log.jsonl").read_text().splitlines()]
                self.assertEqual(events, ["lesson_seen", "session_opened", "follows_lesson"])
                broken = worker.call("lane_observe", {"context": CONTEXT, "binding": binding, "sources": [
                    output | {"observations": [output["observations"][0] | {"evidence": []}]}]})
                self.assertTrue(broken["isError"])
                unbound = worker.ok("lane_observe", {"context": CONTEXT, "binding": WORKER_BINDING, "sources": []})
                self.assertNotIn("lesson", next(row for row in unbound["rows"]
                                                if row["lane_id"] == "quiz/measures")["fields"])
            finally:
                worker.close()


if __name__ == "__main__":
    unittest.main()
