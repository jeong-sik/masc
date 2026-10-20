"""The operator quiz against a fake host speaking K2 (RFC operator-quiz §4.4,
§4.9, §7, §15 L6). The fake host answers each listed request the way the Lane
host does: Board and repository pages oldest first with a cursor, files at a
commit, results too large for the frame in pieces, the author output from the
test, and an ask only once the test answers it."""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import tracemalloc
from typing import Callable
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "operator-quiz"))

import quiz_flow as f  # noqa: E402
import quiz_grading as g  # noqa: E402
import quiz_log as q  # noqa: E402

BOARD = {"source_id": "board", "kind": "board", "visibilities": ["public"]}
REPO = {"source_id": "masc", "kind": "repository", "repository_id": "masc", "paths": ["changelog.d/"]}
BINDING = {"records": [BOARD], "language": "ko"}
HEAD = "f" * 40
PROMPTS = f.Prompts(author="author prompt", grade="grade prompt")


def sha(value) -> str:
    return hashlib.sha256(json.dumps(value).encode()).hexdigest()


def post(n: int, body: str) -> dict:
    return {"kind": "post", "id": f"p-{n}", "author": "operator", "created_at": float(n), "updated_at": float(n),
            "visibility": "public", "title": f"post {n}", "body": body}


def commit(n: int, paths: list[str]) -> dict:
    return {"kind": "commit", "sha": f"{n:040x}", "author": "operator", "committed_at": n,
            "subject": f"commit {n}", "body": "", "paths": paths}


class FakeHost:
    def __init__(self, *, page_size: int = 2, frame: int | None = None):
        self.board: list[dict] = []
        self.commits: list[dict] = []
        self.files: dict[tuple[str, str], str] = {}
        self.page_size = page_size
        self.frame = frame
        # None leaves the request waiting, as a lane that has not answered does.
        self.author: Callable[[dict], dict | None] = lambda payload: None
        self.grade: Callable[[dict], dict | None] = lambda payload: None
        self.answers: dict[str, dict] = {}
        self.retained: dict[str, bytes] = {}
        self.listed: list[dict] = []

    def page(self, request: dict, records: list[dict], head: str | None) -> dict:
        after = request["after"]
        since = request.get("since")
        cursors = [str(index).zfill(6) for index in range(len(records))]
        if after is not None and since is not None:
            raise AssertionError("a read names after or since, not both")
        if since is not None:
            made = [record.get("created_at", record.get("committed_at")) for record in records]
            start = next((i for i, at in enumerate(made) if at >= since), len(records))
        else:
            start = 0 if after is None else cursors.index(after) + 1
        taken = list(range(start, min(start + self.page_size, len(records))))
        body = {"status": "records", "source_id": request["source_id"]}
        if head is not None:
            body["head"] = head
        page = [records[i] for i in taken]
        return body | {"records": page, "next_cursor": cursors[taken[-1]] if taken else after,
                       "complete": start + len(taken) == len(records), "sha256": sha(page)}

    def produce(self, request: dict) -> dict | None:
        match request["kind"]:
            case "read_records":
                result = self.page(request, self.board, None) if request["source_id"] == "board" \
                    else self.page(request, self.commits, HEAD)
            case "read_file":
                content = self.files.get((request["commit"], request["path"]))
                if content is None:
                    return {"status": "not_allowed", "reason": f"path {request['path']} is not a file at that commit"}
                result = {"status": "file", "source_id": request["source_id"], "commit": request["commit"],
                          "path": request["path"], "encoding": "utf-8", "content": content,
                          "bytes": len(content.encode()), "sha256": hashlib.sha256(content.encode()).hexdigest()}
            case "read_result":
                data = self.retained[request["original_request_id"]]
                offset = request["offset"]
                piece = data[offset:offset + self.frame]
                return {"status": "result_chunk", "original_request_id": request["original_request_id"],
                        "source_id": request["source_id"], "sha256": request["sha256"], "bytes": len(data),
                        "offset": offset, "next_offset": offset + len(piece),
                        "eof": offset + len(piece) == len(data), "encoding": "base64",
                        "content": base64.b64encode(piece).decode()}
            case "exact_output":
                answer = self.author if request["output"] == "author" else self.grade
                return answer(json.loads(request["messages"][0]))
            case "ask":
                return self.answers.get(request["request_id"])
            case other:
                raise AssertionError(f"the package listed {other}")
        encoded = json.dumps(result).encode()
        if self.frame is None or len(encoded) <= self.frame:
            return result
        self.retained[request["request_id"]] = encoded
        return {"status": "result_exceeds_frame", "original_request_id": request["request_id"],
                "source_id": request.get("source_id"), "retained_sha256": hashlib.sha256(encoded).hexdigest(),
                "bytes": len(encoded), "encoding": "json-utf8", "complete": False}

    def run(self, flow: f.Flow) -> None:
        """Delivers one result per listing until only waiting requests are left."""
        for _ in range(500):
            listing = flow.listing()
            self.listed.extend(listing)
            pending = [(request, self.produce(request)) for request in listing]
            ready = [(request, result) for request, result in pending if result is not None]
            if not ready:
                return
            request, result = ready[0]
            if not flow.deliver(request["request_id"], result):
                raise AssertionError(f"{request['request_id']} was listed and then refused")
        raise AssertionError("the package kept listing new requests")


def draft(record: dict, quote: str, *, key=("a",), mode="single", reask=(), topic="ledger", rubric=()) -> dict:
    return {"topic": topic, "header": "Ledger", "prompt": "What does it hold?", "mode": mode,
            "choices": [{"choice_id": "a", "label": "Facts"}, {"choice_id": "b", "label": "Plans"},
                        {"choice_id": "c", "label": "Both"}],
            "key": list(key), "rubric": list(rubric), "reask_of": list(reask),
            "sources": [{"kind": record["kind"], "source_id": record["source_id"], "pin": record["pin"],
                         "quote": quote}]}


def answering(*drafts_of):
    """An author that writes questions from the material it is given."""
    def author(payload):
        questions = [make(payload) for make in drafts_of]
        return {"status": "answered", "output": {"questions": [d for d in questions if d is not None]}, "slot": "s"}
    return author


def first_quote(payload):
    record = payload["material"][0]
    return draft(record, record["text"][:8])


class Base(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = Path(self.temporary.name)
        self.flow = f.Flow(self.state, PROMPTS, lambda request: True)
        self.host = FakeHost()
        self.host.board = [post(1, "the ledger records facts"), post(2, "keepers choose their next step"),
                           post(3, "an open question never expires")]

    def tearDown(self):
        self.temporary.cleanup()

    def compose(self, action="act-1", questions=1, binding=BINDING):
        return self.flow.compose(action, questions, binding, float(len(self.flow.sessions())))

    def session(self, session_id):
        return next(s for s in self.flow.sessions() if s.session_id == session_id)

    def answer(self, session_id, *responses, at=10.0):
        session = self.session(session_id)
        self.host.answers[session.ask_id] = {
            "status": "answered", "responder": {"surface": "dashboard", "actor_id": None, "display_name": None},
            "answered_at": at,
            "answers": [{"question_id": p.question_id, "response": q.response_to_json(r)}
                        for p, r in zip(session.posed, responses)]}
        self.host.run(self.flow)


class Compose(Base):
    def test_posed_is_on_disk_before_the_ask_is_listed(self):
        session_id = self.compose()
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual(session.state, "asked")
        (ask,) = self.flow.listing()
        self.assertEqual(ask["kind"], "ask")
        self.assertEqual(ask["questions"], [p.question for p in session.posed])
        self.assertNotIn("key", json.dumps(ask))
        events = q.Log(self.state).read()
        self.assertIsInstance(events[-1], q.Posed)
        self.assertEqual(session.posed[0].sources[0].sha256, sha([post(1, "the ledger records facts"),
                                                                   post(2, "keepers choose their next step")]))

    def test_the_author_sees_every_read_record_with_its_page_digest(self):
        self.compose()
        seen = []
        self.host.author = lambda payload: seen.append(payload) or {"status": "invalid_output", "detail": "x"}
        self.host.run(self.flow)
        (payload,) = seen
        self.assertEqual([m["pin"] for m in payload["material"]], ["p-1", "p-2", "p-3"])
        self.assertEqual((payload["language"], payload["questions"], payload["history_scope"]), ("ko", 1, "all"))

    def test_a_quote_missing_from_the_record_drops_the_question(self):
        session_id = self.compose(questions=2)
        self.host.author = answering(first_quote,
                                     lambda p: draft(p["material"][1], "the ledger records facts"))
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual(len(session.posed), 1)
        (rejected,) = session.rejected
        self.assertEqual((rejected.index, rejected.reason), (1, "the quote is not in p-2"))

    def test_a_citation_of_a_record_never_read_drops_the_question(self):
        session_id = self.compose()
        made_up = {"kind": "board_post", "source_id": "board", "pin": "p-99"}
        self.host.author = answering(lambda p: draft(made_up, "anything"))
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual((session.state, session.failure), ("failed", q.NoQuestionPassed()))
        self.assertEqual(session.rejected[0].reason, "p-99 is not a record this session read")

    def test_a_key_outside_the_choices_or_two_keys_on_single_drops_the_question(self):
        session_id = self.compose(questions=3)
        self.host.author = answering(lambda p: first_quote(p) | {"key": ["z"]},
                                     lambda p: first_quote(p) | {"key": ["a", "b"]},
                                     lambda p: first_quote(p) | {"mode": "multi", "key": ["a", "b"]})
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual([r.reason for r in session.rejected],
                         ["a key choice id is not one of its choices", "a single question has exactly one key"])
        self.assertEqual([p.key for p in session.posed], [q.ChoiceKey(("a", "b"))])

    def test_drafts_beyond_the_requested_count_are_dropped(self):
        session_id = self.compose(questions=1)
        self.host.author = answering(first_quote, first_quote)
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual(len(session.posed), 1)
        self.assertEqual(session.rejected[0].reason, "the session asked for 1 questions")

    def test_invalid_output_fails_the_session_without_a_new_author_request(self):
        session_id = self.compose()
        self.host.author = lambda payload: {"status": "invalid_output", "detail": "schema"}
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual(session.failure, q.AuthorInvalidOutput(f"{session_id}-author-0"))
        self.assertEqual(len(session.requests), 1)
        self.assertEqual(self.flow.listing(), [])

    def test_no_material_fails_without_an_author_request(self):
        self.host.board = []
        session_id = self.compose()
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual((session.failure, session.requests), (q.NoMaterial(), ()))

    def test_a_refused_read_fails_the_session(self):
        session_id = self.compose()
        self.host.produce = lambda request: {"status": "not_allowed", "reason": "no grant"}
        self.host.run(self.flow)
        self.assertEqual(self.session(session_id).failure, q.NotAllowed(f"{session_id}-read-0", "no grant"))


def judging(verdict: str, rationale: str = "names the point"):
    return lambda payload: {"status": "answered", "slot": "s",
                            "output": {"verdict": verdict, "rationale": rationale}}


class Judging(Base):
    """A written answer and the grade output (RFC §6.2)."""
    def wrote(self, text="facts"):
        session_id = self.compose()
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.answer(session_id, q.Wrote(text))
        return session_id

    def grade_requests(self):
        return [r for r in self.flow.listing() if r["kind"] == "exact_output" and r["output"] == f.GRADE]

    def test_a_written_answer_lists_one_grade_request_with_the_key_labels(self):
        self.wrote("facts")
        (request,) = self.grade_requests()
        payload = json.loads(request["messages"][0])
        self.assertEqual(request["system"], PROMPTS.grade)
        self.assertEqual(payload["expected"], {"kind": "choices", "labels": ["Facts"]})
        self.assertEqual(payload["answer"], {"kind": "wrote", "text": "facts"})
        self.assertEqual([s["quote"] for s in payload["sources"]], ["the ledg"])

    def test_a_judgment_decides_the_verdict_and_ends_the_request(self):
        session_id = self.wrote()
        self.host.grade = judging("correct")
        self.host.run(self.flow)
        session = self.session(session_id)
        posed = session.posed[0]
        self.assertEqual(g.verdict(posed, q.Wrote("facts"), session.judgments_of(posed.question_id)), g.CORRECT)
        self.assertEqual(self.grade_requests(), [])
        (item,) = g.items(self.flow.sessions())
        self.assertEqual([a.verdict for a in item.attempts], [g.CORRECT])

    def test_a_void_judgment_takes_the_question_out_of_the_attempts(self):
        self.wrote()
        self.host.grade = judging("void", "the quote does not say what the key says")
        self.host.run(self.flow)
        (item,) = g.items(self.flow.sessions())
        self.assertEqual(item.attempts, ())

    def test_a_rationale_of_only_whitespace_is_kept_as_the_outputs_failure(self):
        session_id = self.wrote()
        self.host.grade = judging("incorrect", "   ")
        self.host.run(self.flow)
        (failure,) = [e for e in self.session(session_id).grading if isinstance(e, q.GradeFailed)]
        self.assertEqual(failure.kind, "invalid_output")

    def test_a_final_failure_waits_until_the_next_compose(self):
        session_id = self.wrote()
        self.host.grade = lambda payload: {"status": "outcome_unknown"}
        self.host.run(self.flow)
        self.assertEqual(self.grade_requests(), [])
        posed = self.session(session_id).posed[0]
        self.assertEqual(g.verdict(posed, q.Wrote("facts"), ()), g.AWAITING_JUDGMENT)
        self.host.author = lambda payload: None  # the new session's author request waits
        self.flow.compose("act-2", 1, BINDING, 5.0)
        (request,) = self.grade_requests()
        self.assertTrue(request["request_id"].endswith("-grade-q1-1"))
        self.host.grade = judging("incorrect")
        self.host.run(self.flow)
        self.assertEqual(self.session(session_id).judgments_of("q1")[0].judgment, q.Incorrect())

    def test_a_restarted_worker_lists_the_same_grade_request(self):
        self.wrote()
        (request,) = self.grade_requests()
        restarted = f.Flow(self.state, PROMPTS, lambda request: True)
        self.assertIn(request, restarted.listing())

    def test_a_grade_request_that_cannot_fit_the_frame_ends_at_once(self):
        session_id = self.compose()
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.flow = f.Flow(self.state, PROMPTS, lambda request: request["output"] != f.GRADE
                           if request["kind"] == "exact_output" else True)
        self.answer(session_id, q.Wrote("facts"))
        (failure,) = [e for e in self.session(session_id).grading if isinstance(e, q.GradeFailed)]
        self.assertEqual(failure.kind, "request_exceeds_frame")
        self.assertEqual(self.grade_requests(), [])

    def test_a_written_answer_with_no_grading_is_asked_at_the_next_compose(self):
        # The answer line without its grade request, as a torn write or an
        # answer from before this package graded leaves it.
        session_id = self.compose()
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        ask_id = self.session(session_id).ask_id
        self.flow.log.append([q.AnswerReceived(ask_id, (q.Answer("q1", q.Wrote("facts")),),
                                               {"surface": "dashboard"}, 10.0)])
        self.assertEqual(self.grade_requests(), [])
        self.host.author = lambda payload: None
        self.flow.compose("act-2", 1, BINDING, 11.0)
        (request,) = self.grade_requests()
        self.assertTrue(request["request_id"].endswith("-grade-q1-0"))

    def test_every_failed_grade_is_asked_again_in_one_compose(self):
        session_id = self.compose(questions=2)
        self.host.author = answering(first_quote, lambda p: draft(p["material"][1], "keepers"))
        self.host.run(self.flow)
        self.answer(session_id, q.Wrote("facts"), q.Wrote("they choose"))
        self.host.grade = lambda payload: {"status": "invalid_output", "detail": "schema"}
        self.host.run(self.flow)
        self.assertEqual(self.grade_requests(), [])
        self.host.author = lambda payload: None
        self.flow.compose("act-2", 1, BINDING, 11.0)
        self.assertEqual(sorted(r["request_id"].rsplit("-grade-", 1)[1] for r in self.grade_requests()),
                         ["q1-1", "q2-1"])

    def test_text_the_log_cannot_keep_is_refused_at_the_boundary(self):
        session_id = self.wrote()
        self.host.grade = judging("correct", "facts \ud800")
        self.host.run(self.flow)
        (failure,) = [e for e in self.session(session_id).grading if isinstance(e, q.GradeFailed)]
        self.assertEqual(failure.kind, "invalid_output")
        self.host.board.append(post(4, "an answer is recorded once"))
        second = self.flow.compose("act-2", 1, BINDING, 20.0)
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        ask_id = self.session(second).ask_id
        events = len(self.flow.log.read())
        broken = {"status": "answered", "answered_at": 21.0,
                  "responder": {"surface": "dashboard", "actor_id": None, "display_name": None},
                  "answers": [{"question_id": "q1", "response": {"kind": "wrote", "text": "facts \ud800"}}]}
        with self.assertRaises(f.InvalidResult):
            self.flow.deliver(ask_id, broken)
        self.assertEqual(len(self.flow.log.read()), events)

    def test_a_choice_or_a_skip_needs_no_grade_request(self):
        session_id = self.compose()
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.answer(session_id, q.Chose(("a",)))
        self.assertEqual(self.grade_requests(), [])
        self.assertEqual(self.session(session_id).grading, ())


def text_draft(record: dict, quote: str, points=("the ledger records facts",)) -> dict:
    return draft(record, quote, mode="text", key=(), rubric=points) | {"choices": []}


class Rubrics(Base):
    """A question answered in words, graded against its rubric (RFC §6.2)."""
    def asked(self, make=lambda p: text_draft(p["material"][0], "the ledger records facts")):
        session_id = self.compose()
        self.host.author = answering(make)
        self.host.run(self.flow)
        return session_id

    def test_a_text_question_is_asked_with_no_choices_and_graded_by_its_rubric(self):
        session_id = self.asked()
        (ask,) = [r for r in self.flow.listing() if r["kind"] == "ask"]
        (question,) = ask["questions"]
        self.assertEqual((question["choices"], question["free_text"]), ([], f.WRITTEN))
        self.assertNotIn("the ledger records facts", json.dumps(ask))
        self.answer(session_id, q.Wrote("it keeps facts"))
        (request,) = [r for r in self.flow.listing() if r["kind"] == "exact_output"]
        self.assertEqual(json.loads(request["messages"][0])["expected"],
                         {"kind": "rubric", "points": ["the ledger records facts"]})
        self.host.grade = judging("correct")
        self.host.run(self.flow)
        session = self.session(session_id)
        posed = session.posed[0]
        self.assertEqual(posed.key, q.Rubric(("the ledger records facts",)))
        self.assertEqual(g.verdict(posed, q.Wrote("it keeps facts"), session.judgments_of("q1")), g.CORRECT)

    def test_a_skipped_text_question_is_a_miss(self):
        session_id = self.asked()
        self.answer(session_id, q.Skipped())
        (item,) = g.items(self.flow.sessions())
        self.assertTrue(item.open_debt)

    def test_a_choice_answer_to_a_text_question_is_refused(self):
        session_id = self.asked()
        ask_id = self.session(session_id).ask_id
        chose = {"status": "answered", "answered_at": 1.0,
                 "responder": {"surface": "dashboard", "actor_id": None, "display_name": None},
                 "answers": [{"question_id": "q1", "response": {"kind": "chose", "choice_ids": ["a"]}}]}
        with self.assertRaises(f.InvalidResult):
            self.flow.deliver(ask_id, chose)
        self.assertEqual(self.session(session_id).state, "asked")

    def test_each_mode_keeps_its_own_shape(self):
        record = {"kind": "board_post", "source_id": "board", "pin": "p-1"}
        cases = [
            (text_draft(record, "the ledg") | {"choices": [{"choice_id": "a", "label": "Facts"}]},
             "a text question has no choices and no key"),
            (text_draft(record, "the ledg", points=()), "a text question names the points its answer must state"),
            (text_draft(record, "the ledg", points=(" ",)), "a text question names the points its answer must state"),
            (draft(record, "the ledg", rubric=("facts",)), "a choice question has a key, not a rubric"),
            (draft(record, "the ledg") | {"choices": [{"choice_id": "a", "label": "Facts"}]},
             "a choice question offers at least two choices"),
            (draft(record, "the ledg", key=()), "a choice question names its key"),
        ]
        material = [{"kind": "board_post", "source_id": "board", "pin": "p-1", "sha256": "0" * 64,
                     "title": "post 1", "text": "the ledger records facts"}]
        for candidate, reason in cases:
            with self.subTest(reason):
                self.assertEqual(f.check_draft(candidate, material, {}), reason)


class Repetition(Base):
    def test_a_session_with_no_new_record_still_asks_a_missed_item_again(self):
        first = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.answer(first, q.Chose(("b",)))
        (missed,) = g.items(self.flow.sessions())
        seen = []

        def again(payload):
            seen.append(payload)
            (item,) = payload["items"]
            source = item["sources"][0]
            return {"status": "answered", "slot": "s", "output": {"questions": [
                draft(source, source["quote"], reask=(item["item_id"],))]}}

        self.host.author = again
        second = self.compose("act-2")
        self.host.run(self.flow)
        (payload,) = seen
        self.assertEqual(payload["material"], [])
        session = self.session(second)
        self.assertEqual(session.state, "asked")
        self.assertEqual([(p.item_id, p.sources) for p in session.posed], [(missed.item_id, missed.sources)])


class Sessions(Base):
    def test_a_second_compose_supersedes_a_writing_session(self):
        first = self.compose("act-1")
        (request,) = self.flow.listing()
        second = self.compose("act-2")
        self.assertEqual(self.session(first).state, "superseded")
        self.assertTrue(all(r["request_id"].startswith(second) for r in self.flow.listing()))
        before = q.Log(self.state).path.read_bytes()
        self.assertFalse(self.flow.deliver(request["request_id"], self.host.produce(request)))
        self.assertEqual(q.Log(self.state).path.read_bytes(), before)

    def test_the_same_compose_twice_opens_one_session(self):
        self.assertEqual(self.compose("act-1"), self.compose("act-1"))
        self.assertEqual(len(self.flow.sessions()), 1)

    def test_a_compose_leaves_an_asked_session_untouched(self):
        first = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        second = self.compose("act-2")
        self.assertEqual(self.session(first).state, "asked")
        self.assertIn(self.session(first).ask_id, [r["request_id"] for r in self.flow.listing()])
        self.host.board.append(post(4, "a later fact"))
        self.host.run(self.flow)
        self.assertEqual([s.state for s in self.flow.sessions()], ["asked", "asked"])
        self.assertNotEqual(self.session(second).ask_id, self.session(first).ask_id)

    def test_a_new_session_reads_from_the_cursor_of_the_last_asked_session(self):
        self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.host.board.append(post(4, "the next decision"))
        second = self.compose("act-2")
        seen = []
        self.host.author = lambda payload: seen.append(payload) or {"status": "invalid_output", "detail": "x"}
        self.host.run(self.flow)
        reads = [r for r in self.host.listed if r["kind"] == "read_records" and r["request_id"].startswith(second)]
        self.assertEqual(reads[0]["after"], "000002")
        self.assertNotIn("since", reads[0])
        self.assertEqual([m["pin"] for m in seen[0]["material"]], ["p-4"])

    def test_the_first_session_reads_only_what_was_made_since_the_quiz_began(self):
        session_id = self.flow.compose("act-1", 1, BINDING, 3.5)
        self.host.board.append(post(5, "a decision made after the quiz was turned on"))
        seen = []
        self.host.author = lambda payload: seen.append(payload) or {"status": "outcome_unknown"}
        self.host.run(self.flow)
        reads = [r for r in self.host.listed if r["kind"] == "read_records" and r["request_id"].startswith(session_id)]
        self.assertEqual((reads[0]["after"], reads[0]["since"]), (None, 3.5))
        self.assertEqual([m["pin"] for m in seen[0]["material"]], ["p-5"])

    def test_a_later_session_with_no_asked_session_reads_since_the_first_one(self):
        self.flow.compose("act-1", 1, BINDING, 3.5)
        self.host.board.append(post(5, "a decision made after the quiz was turned on"))
        self.host.author = lambda payload: {"status": "outcome_unknown"}
        self.host.run(self.flow)
        second = self.flow.compose("act-2", 1, BINDING, 10.0)
        seen = []
        self.host.author = lambda payload: seen.append(payload) or {"status": "outcome_unknown"}
        self.host.run(self.flow)
        reads = [r for r in self.host.listed if r["kind"] == "read_records" and r["request_id"].startswith(second)]
        self.assertEqual(reads[0]["since"], 3.5)
        self.assertEqual([m["pin"] for m in seen[0]["material"]], ["p-5"])

    def test_material_of_a_failed_session_is_read_again(self):
        self.compose("act-1")
        self.host.author = lambda payload: {"status": "outcome_unknown"}
        self.host.run(self.flow)
        second = self.compose("act-2")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        reads = [r for r in self.host.listed if r["kind"] == "read_records" and r["request_id"].startswith(second)]
        self.assertIsNone(reads[0]["after"])

    def test_an_ask_refused_by_rule_fails_the_asked_session(self):
        session_id = self.compose()
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        ask_id = self.session(session_id).ask_id
        self.host.answers[ask_id] = {"status": "not_allowed", "reason": "no [world.asks]"}
        self.host.run(self.flow)
        self.assertEqual(self.session(session_id).failure, q.NotAllowed(ask_id, "no [world.asks]"))
        self.assertEqual(self.flow.listing(), [])

    def test_an_answer_that_leaves_a_question_out_is_not_accepted(self):
        session_id = self.compose(questions=2)
        self.host.author = answering(first_quote, lambda p: draft(p["material"][1], "keepers choose"))
        self.host.run(self.flow)
        session = self.session(session_id)
        partial = {"status": "answered", "responder": {"surface": "dashboard"}, "answered_at": 1.0,
                   "answers": [{"question_id": "q1", "response": {"kind": "skipped"}}]}
        with self.assertRaises(f.InvalidResult):
            self.flow.deliver(session.ask_id, partial)
        self.assertEqual(self.session(session_id).state, "asked")

    def test_a_withdrawn_ask_is_not_a_result_this_package_takes(self):
        session_id = self.compose()
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        with self.assertRaises(f.InvalidResult):
            self.flow.deliver(self.session(session_id).ask_id, {"status": "withdrawn", "reason": "x",
                                                                "withdrawn_at": 1.0})
        self.assertEqual(self.session(session_id).state, "asked")


class ReviewFindings(Base):
    def test_a_draft_the_log_cannot_keep_is_dropped_alone(self):
        session_id = self.compose(questions=3)
        self.host.author = answering(lambda p: first_quote(p) | {"topic": " "},
                                     lambda p: draft(p["material"][0], " "),
                                     lambda p: draft(p["material"][1], "keepers choose"))
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual(session.state, "asked")
        self.assertEqual([p.question_id for p in session.posed], ["q1"])
        self.assertEqual([r.index for r in session.rejected], [0, 1])

    def test_the_writing_session_is_listed_before_open_asks(self):
        self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.compose("act-2")
        self.assertEqual([r["kind"] for r in self.flow.listing()], ["read_records", "ask"])

    def test_a_cursor_the_host_refused_is_not_used_again(self):
        self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        produce = self.host.produce
        self.host.produce = lambda request: ({"status": "not_allowed", "reason": "cursor is not reached"}
                                             if request["kind"] == "read_records" and request["after"] == "000002"
                                             else produce(request))
        second = self.compose("act-2")
        self.host.run(self.flow)
        self.assertEqual(self.session(second).state, "failed")
        third = self.compose("act-3")
        (request,) = [r for r in self.flow.listing() if r["request_id"].startswith(third)]
        self.assertIsNone(request["after"])

    def test_a_session_that_asked_and_then_failed_still_gives_its_cursor(self):
        first = self.compose("act-1")
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        self.host.answers[self.session(first).ask_id] = {"status": "not_allowed", "reason": "no [world.asks]"}
        self.host.run(self.flow)
        self.assertEqual(self.session(first).state, "failed")
        second = self.compose("act-2")
        (request,) = [r for r in self.flow.listing() if r["request_id"].startswith(second)]
        self.assertEqual(request["after"], "000002")

    def test_a_quote_taken_from_a_file_path_is_not_in_the_file(self):
        self.host.commits = [commit(1, ["changelog.d/a.md"])]
        self.host.files = {(f"{1:040x}", "changelog.d/a.md"): "the ledger records facts"}
        session_id = self.compose(binding={"records": [REPO], "language": "ko"})
        self.host.author = answering(lambda p: draft(p["material"][0], "changelog.d/a.md"))
        self.host.run(self.flow)
        self.assertEqual(self.session(session_id).failure, q.NoQuestionPassed())


class Recovery(Base):
    def test_a_restart_lists_the_same_request_with_the_same_body(self):
        session_id = self.compose()
        self.host.run(self.flow)
        listing = self.flow.listing()
        (request,) = listing
        self.assertEqual(request["request_id"], f"{session_id}-author-0")
        restarted = f.Flow(self.state, PROMPTS, lambda request: True)
        self.assertEqual(restarted.listing(), listing)
        self.assertEqual(f.digest(request), self.session(session_id).requests[0].digest)

    def test_a_result_is_accepted_only_after_the_log_write(self):
        self.compose()
        (request,) = self.flow.listing()
        log = q.Log(self.state)
        good = log.path.read_bytes()
        log.path.write_bytes(good + b"not json\n")
        with self.assertRaises(q.LogError):
            self.flow.deliver(request["request_id"], self.host.produce(request))
        log.path.write_bytes(good)
        self.assertEqual(self.flow.listing(), [request])
        self.assertTrue(self.flow.deliver(request["request_id"], self.host.produce(request)))
        self.assertNotEqual(self.flow.listing(), [request])

    def test_an_unreadable_log_refuses_a_compose(self):
        self.compose()
        log = q.Log(self.state)
        log.path.write_bytes(log.path.read_bytes() + b"not json\n")
        with self.assertRaises(q.LogError):
            self.compose("act-2")


class Pieces(Base):
    def test_a_page_too_large_for_the_frame_is_read_in_pieces(self):
        self.host = FakeHost(page_size=3, frame=180)
        self.host.board = [post(1, "the ledger records facts " * 4), post(2, "keepers choose"), post(3, "asks wait")]
        session_id = self.compose()
        self.host.author = answering(first_quote)
        self.host.run(self.flow)
        kinds = [r["kind"] for r in self.host.listed if r["request_id"].startswith(session_id + "-read")]
        self.assertGreater(kinds.count("read_result"), 1)
        self.assertEqual(self.session(session_id).state, "asked")

    def test_pieces_that_do_not_match_the_digest_are_not_accepted(self):
        self.host = FakeHost(page_size=3, frame=180)
        self.host.board = [post(1, "the ledger records facts " * 4)]
        self.compose()
        (request,) = self.flow.listing()
        marker = self.host.produce(request)
        assert marker is not None and marker["status"] == "result_exceeds_frame"
        self.flow.deliver(request["request_id"], marker | {"retained_sha256": "0" * 64})
        with self.assertRaises(f.InvalidResult):
            self.host.run(self.flow)


class Repository(Base):
    def test_files_the_new_commits_changed_under_the_grant_are_read(self):
        self.host.commits = [commit(1, ["changelog.d/a.md", "lib/x.ml"]), commit(2, ["changelog.d/b.md"])]
        self.host.files = {(f"{1:040x}", "changelog.d/a.md"): "the ledger records facts"}
        session_id = self.compose(binding={"records": [REPO], "language": "ko"})
        seen = []
        self.host.author = lambda payload: seen.append(payload) or answering(first_quote)(payload)
        self.host.run(self.flow)
        files = [r for r in self.host.listed if r["kind"] == "read_file"]
        self.assertEqual([(r["commit"], r["path"]) for r in files],
                         [(f"{1:040x}", "changelog.d/a.md"), (f"{2:040x}", "changelog.d/b.md")])
        # b.md is gone at that commit in this fixture, as a released fragment is.
        self.assertEqual([m["pin"] for m in seen[0]["material"]], [f"{1:040x}:changelog.d/a.md"])
        self.assertEqual(self.session(session_id).state, "asked")


class Reductions(Base):
    def setUp(self):
        super().setUp()
        # One earlier item answered correctly and one missed, so open debt is smaller than all.
        self.compose("act-0", questions=2)
        self.host.author = answering(first_quote, lambda p: draft(p["material"][1], "keepers choose"))
        self.host.run(self.flow)
        self.answer(self.flow.sessions()[0].session_id, q.Chose(("a",)), q.Chose(("b",)))

    def test_an_input_refusal_sends_open_debt_then_the_newer_half_then_fails(self):
        self.host.board += [post(4, "four"), post(5, "five"), post(6, "six"), post(7, "seven")]
        session_id = self.compose("act-1")
        seen = []
        self.host.author = lambda payload: seen.append(payload) or {"status": "input_refused",
                                                                    "kind": "context_overflow"}
        self.host.run(self.flow)
        self.assertEqual([p["history_scope"] for p in seen], ["all", "open_debt_only", "open_debt_only",
                                                              "open_debt_only"])
        self.assertEqual([len(p["items"]) for p in seen], [2, 1, 1, 1])
        self.assertEqual([[m["pin"] for m in p["material"]] for p in seen],
                         [["p-4", "p-5", "p-6", "p-7"]] * 2 + [["p-6", "p-7"], ["p-7"]])
        session = self.session(session_id)
        self.assertEqual(session.failure, q.AuthorInputRefused(f"{session_id}-author-3", "context_overflow"))


class Frame(Base):
    def test_an_author_request_too_large_to_list_keeps_the_newer_half(self):
        self.host.board += [post(4, "four"), post(5, "five")]

        # A frame that holds three records and not five.
        def fits(body):
            return len(json.loads(body["messages"][0])["material"]) <= 3
        self.flow = f.Flow(self.state, PROMPTS, fits)
        session_id = self.compose()
        seen = []
        self.host.author = lambda payload: seen.append(payload) or {"status": "invalid_output", "detail": "x"}
        self.host.run(self.flow)
        self.assertEqual([m["pin"] for m in seen[0]["material"]], ["p-3", "p-4", "p-5"])
        self.assertEqual(self.session(session_id).requests[0].request_id, f"{session_id}-author-0")

    def test_one_record_that_cannot_be_listed_fails_the_session(self):
        self.flow = f.Flow(self.state, PROMPTS, lambda request: False)
        session_id = self.compose()
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual((session.failure, session.requests),
                         (q.AuthorRequestExceedsFrame(f"{session_id}-author-0"), ()))


class Memory(Base):
    """What a worker holds does not grow with what its sessions read: on the
    live workspace a session that read the Board from the start ran the
    worker out of memory twice, the second time right after a restart that
    read every kept page back (#44537)."""

    def deliver_one(self):
        (request,) = self.flow.listing()
        self.assertTrue(self.flow.deliver(request["request_id"], self.host.produce(request)))

    def test_a_restarted_worker_keeps_no_record_body_of_the_pages_it_reads_back(self):
        self.host = FakeHost(page_size=10)
        self.host.board = [post(n, f"post {n} " + "x" * 4000) for n in range(1, 201)]
        self.compose()
        for _ in range(19):
            self.deliver_one()
        kept = sum(path.stat().st_size for path in q.Blobs(self.state, "pages").directory.iterdir())
        tracemalloc.start()
        try:
            restarted = f.Flow(self.state, PROMPTS, lambda request: True)
            (request,) = restarted.listing()
            held, _ = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(request["after"], "000189")
        self.assertLess(held, kept // 10)

    def test_a_restarted_worker_keeps_no_content_of_the_files_it_reads_back(self):
        self.host = FakeHost(page_size=50)
        self.host.commits = [commit(n, [f"changelog.d/{n}.md"]) for n in range(1, 41)]
        self.host.files = {(f"{n:040x}", f"changelog.d/{n}.md"): f"fragment {n} " + "x" * 100000 for n in range(1, 41)}
        self.compose(binding={"records": [REPO], "language": "ko"})
        for _ in range(40):
            self.deliver_one()
        kept = sum(path.stat().st_size for path in q.Blobs(self.state, "pages").directory.iterdir())
        tracemalloc.start()
        try:
            restarted = f.Flow(self.state, PROMPTS, lambda request: True)
            (request,) = restarted.listing()
            held, _ = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual((request["kind"], request["path"]), ("read_file", "changelog.d/40.md"))
        self.assertLess(held, kept // 10)

    def test_the_author_request_reads_back_only_the_newest_pages_that_fit(self):
        self.host.board = [post(n, f"post {n}") for n in range(1, 7)]

        # A frame that holds two records and not four.
        def fits(body):
            return len(json.loads(body["messages"][0])["material"]) <= 2
        self.flow = f.Flow(self.state, PROMPTS, fits)
        seen = []
        self.host.author = lambda payload: seen.append(payload) or {"status": "invalid_output", "detail": "x"}
        session_id = self.compose()
        self.deliver_one()
        self.deliver_one()
        first_page = self.session(session_id).material[0].digest
        read = self.flow.pages.read
        loaded = []
        self.flow.pages.read = lambda key: loaded.append(key) or read(key)
        self.deliver_one()
        self.assertNotIn(first_page, loaded)
        self.host.run(self.flow)
        self.assertEqual([m["pin"] for m in seen[0]["material"]], ["p-5", "p-6"])


class Grading(unittest.TestCase):
    QUESTION = {"question_id": "q1", "header": "h", "prompt": "p", "mode": "multi",
                "free_text": {"kind": "choices_only"}, "choices": []}

    def posed(self, key, item="i-1", question_id="q1", session="s1"):
        return q.Posed(session, f"{session}-ask", question_id, item, "t", self.QUESTION, q.ChoiceKey(key), ())

    def test_a_choice_is_right_only_with_the_exact_key_set(self):
        multi = self.posed(("a", "b"))
        self.assertEqual(g.verdict(multi, q.Chose(("b", "a"))), g.CORRECT)
        self.assertEqual(g.verdict(multi, q.Chose(("a",))), g.INCORRECT)
        self.assertEqual(g.verdict(multi, q.Chose(("a", "b", "c"))), g.INCORRECT)

    def test_written_text_waits_and_a_skip_is_a_miss(self):
        self.assertEqual(g.verdict(self.posed(("a",)), q.Wrote("facts")), g.AWAITING_JUDGMENT)
        self.assertEqual(g.verdict(self.posed(("a",)), q.Skipped()), g.SKIPPED)
        events = [q.SessionOpened("s1", "act-1", 1, (q.Grant("board", "board", ()),), "ko", 0.0), self.posed(("a",)),
                  q.AnswerReceived("s1-ask", (q.Answer("q1", q.Skipped()),), {}, 1.0)]
        (item,) = g.items(q.fold(events))
        self.assertTrue(item.open_debt)

    def test_an_item_keeps_its_attempts_in_answer_order(self):
        sessions = []
        for n, (choice, at) in enumerate([("b", 1.0), ("a", 2.0), ("a", 3.0)]):
            opened = q.SessionOpened(f"s{n}", f"act-{n}", 1, (q.Grant("board", "board", ()),), "ko", 0.0)
            asked = self.posed(("a",), session=f"s{n}")
            answered = q.AnswerReceived(f"s{n}-ask", (q.Answer("q1", q.Chose((choice,))),), {}, at)
            sessions += [opened, asked, answered]
        (item,) = g.items(q.fold(sessions))
        self.assertEqual([a.verdict for a in item.attempts], [g.INCORRECT, g.CORRECT, g.CORRECT])
        self.assertEqual((item.correct_streak, item.open_debt), (2, False))


if __name__ == "__main__":
    unittest.main()
