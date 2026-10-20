"""The operator quiz log (RFC operator-quiz §4.9): strict lines, unfinished
writes, and the session fold. No worker or host runs."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "operator-quiz"))

import quiz_log as q  # noqa: E402

QUESTION = {"question_id": "q1", "header": "Ledger", "prompt": "What does the ledger hold?",
            "mode": "single", "free_text": {"kind": "choices_only"},
            "choices": [{"choice_id": "a", "label": "Facts", "description": None},
                        {"choice_id": "b", "label": "Plans", "description": None}]}
SOURCE = q.Source("board_post", "board", "p-1", "the ledger records facts", "0" * 64)
GRANTS = (q.Grant("board", "board", ()), q.Grant("masc", "repository", ("changelog.d/",)))


def opened(session_id="s1", action="act-1", questions=1):
    return q.SessionOpened(session_id, action, questions, GRANTS, "ko", 1.0)


def posed(session_id="s1", ask_id="ask-1", question_id="q1"):
    return q.Posed(session_id, ask_id, question_id, "item-1", "ledger", QUESTION, ("a",), (SOURCE,))


def answered(ask_id="ask-1", choice="a"):
    return q.AnswerReceived(ask_id, (q.Answer("q1", q.Chose((choice,))),), {"surface": "tui"}, 2.0)


EVERY_EVENT = [
    opened("s1", "act-1", 3),
    q.MaterialRead("s1", "read-1", "1" * 64),
    q.ExactRequested("s1", "author-1", "author", "2" * 64),
    q.DraftRejected("s1", "author-1", 1, "quote not found in p-2"),
    posed(),
    answered(),
    opened("s2", "act-2", 1),
    q.SessionFailed("s2", q.AuthorInputRefused("author-2", "context_overflow")),
    opened("s3", "act-3", 1),
    q.SessionFailed("s3", q.NoMaterial()),
    opened("s4", "act-4", 1),
    q.SessionFailed("s4", q.ResultExceedsFrame("author-4")),
    opened("s5", "act-5", 1),
    q.SessionFailed("s5", q.AuthorRequestExceedsFrame("author-5")),
]


class LogFile(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = Path(self.temporary.name)
        self.log = q.Log(self.state)

    def tearDown(self):
        self.temporary.cleanup()

    def test_every_event_reads_back_as_written(self):
        self.log.append(EVERY_EVENT)
        self.assertEqual(self.log.read(), EVERY_EVENT)

    def test_an_unknown_field_or_event_names_its_line(self):
        self.log.append([opened("s1", "act-1", 3)])
        with open(self.log.path, "ab") as handle:
            line = q.event_to_json(opened("s2", "act-2", 1)) | {"x": 1}
            handle.write(json.dumps(line).encode() + b"\n")
        with self.assertRaisesRegex(q.LogError, "line 2 .*unknown field x"):
            self.log.read()
        self.log.path.write_bytes(b'{"event":"judged_by_vibes"}\n')
        with self.assertRaisesRegex(q.LogError, "line 1 .*judged_by_vibes"):
            self.log.read()

    def test_a_session_names_the_grants_it_reads_exactly(self):
        base = q.event_to_json(opened())
        for label, grants in [
            ("a repository grant without paths", [{"source_id": "masc", "kind": "repository", "paths": []}]),
            ("paths on a board grant", [{"source_id": "board", "kind": "board", "paths": ["x/"]}]),
            ("a source named twice", [{"source_id": "board", "kind": "board", "paths": []}] * 2),
            ("no grant", []),
        ]:
            with self.subTest(label):
                with self.assertRaises(q.LogError):
                    q.event_of_json(base | {"grants": grants})

    def test_an_event_that_would_not_read_back_is_not_written(self):
        with self.assertRaises(q.LogError):
            self.log.append([q.SessionOpened("s1", "act-1", None, GRANTS, "ko", 1.0)])  # type: ignore[arg-type]
        self.assertFalse(self.log.path.exists())

    def test_an_unreadable_log_refuses_a_write(self):
        self.log.path.parent.mkdir(parents=True)
        self.log.path.write_bytes(b"not json\n")
        with self.assertRaises(q.LogError):
            self.log.append([opened("s1", "act-1", 3)])
        self.assertEqual(self.log.path.read_bytes(), b"not json\n")

    def test_an_unfinished_write_is_skipped_and_cut_before_the_next(self):
        self.log.append([opened("s1", "act-1", 3)])
        # Longer than the next line, so writing over it would leave a remainder.
        with open(self.log.path, "ab") as handle:
            handle.write(b'{"event":"session_opened","session_id":"' + b"x" * 400)
        self.assertEqual(self.log.read(), [opened("s1", "act-1", 3)])
        self.log.append([opened("s2", "act-2", 1)])
        self.assertEqual([e.session_id for e in self.log.read()], ["s1", "s2"])
        self.assertTrue(self.log.path.read_bytes().endswith(b"\n"))

    def test_a_blob_is_written_once_and_read_by_its_digest(self):
        blobs = q.Blobs(self.state, "requests")
        blobs.write("ab" * 32, {"kind": "exact_output"})
        blobs.write("ab" * 32, {"kind": "something else"})
        self.assertEqual(blobs.read("ab" * 32), {"kind": "exact_output"})
        with self.assertRaises(q.LogError):
            blobs.read("cd" * 32)
        with self.assertRaises(q.LogError):
            blobs.path("../escape")


class Sessions(unittest.TestCase):
    def test_a_session_goes_from_writing_to_asked_to_answered(self):
        start = [opened("s1", "act-1", 1)]
        self.assertEqual([s.state for s in q.fold(start)], ["writing"])
        self.assertEqual([s.state for s in q.fold(start + [posed()])], ["asked"])
        sessions = q.fold(start + [posed(), answered()])
        self.assertEqual([s.state for s in sessions], ["answered"])
        self.assertEqual(sessions[0].ask_id, "ask-1")

    def test_a_later_compose_supersedes_only_a_writing_session(self):
        events = [opened("s1", "act-1", 1), opened("s2", "act-2", 1)]
        first, second = q.fold(events)
        self.assertEqual((first.state, first.superseded_by), ("superseded", "s2"))
        self.assertEqual(second.state, "writing")
        events = [opened("s1", "act-1", 1), posed(), opened("s2", "act-2", 1)]
        self.assertEqual([s.state for s in q.fold(events)], ["asked", "writing"])

    def test_a_failed_session_keeps_its_reason(self):
        failure = q.NotAllowed("author-1", "this package declares no output author")
        (session,) = q.fold([opened("s1", "act-1", 1), q.SessionFailed("s1", failure)])
        self.assertEqual((session.state, session.failure), ("failed", failure))
        refused = q.NotAllowed("ask-1", "no [world.asks]")
        (session,) = q.fold([opened("s1", "act-1", 1), posed(), q.SessionFailed("s1", refused)])
        self.assertEqual((session.state, session.failure), ("failed", refused))

    def test_history_that_contradicts_itself_is_an_error(self):
        start = [opened("s1", "act-1", 1)]
        superseded = start + [opened("s2", "act-2", 1)]
        for label, events in [
            ("a question for a superseded session", superseded + [posed("s1")]),
            ("an answer to an ask nobody posed", start + [answered("ask-9")]),
            ("a second answer", start + [posed(), answered(), answered()]),
            ("a failure after the answer", start + [posed(), answered(), q.SessionFailed("s1", q.NoMaterial())]),
            ("material for a session that was asked", start + [posed(), q.MaterialRead("s1", "read-1", "1" * 64)]),
            ("an event for a session never opened", [posed("s9")]),
            ("one question posed twice", start + [posed(), posed()]),
        ]:
            with self.subTest(label):
                with self.assertRaises(q.LogError):
                    q.fold(events)


if __name__ == "__main__":
    unittest.main()
