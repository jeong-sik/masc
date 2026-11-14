"""The operator quiz's own record (RFC operator-quiz §4.9 Log, Sessions).

One append-only JSON line per event at ``<state>/operator-quiz/log.jsonl``.
Events and their fields are closed sets. The file, the pins and the grants are
the shared ones of records.py; the events, sessions and their fold are here.

A session's state is a fold of the log. Nothing else is stored about it.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Union

import records
from records import (  # noqa: F401  -- the names this package's modules and tests read from here
    BoardCommentPin, BoardPostPin, CommitPin, GRANT_KINDS, Grant, LogError, Pin, PrCommentPin, PrPin, PrReviewPin,
    RepoFilePin, SOURCE_KINDS, Source, WikiPagePin, parse_pin, pin_kind, pin_text)
from records import count as _count, exact as _exact, index as _index, number as _time, text as _text
from records import texts as _texts

FOLDER = "operator-quiz"  # under the persistent volume


# -- Answers, in the Keeper ask wire form the host delivers. ---------------

@dataclass(frozen=True, slots=True)
class Chose:
    choice_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Wrote:
    text: str


@dataclass(frozen=True, slots=True)
class Skipped:
    pass


Response = Union[Chose, Wrote, Skipped]


def response_to_json(response: Response) -> dict:
    match response:
        case Chose(choice_ids):
            return {"kind": "chose", "choice_ids": list(choice_ids)}
        case Wrote(text):
            return {"kind": "wrote", "text": text}
        case Skipped():
            return {"kind": "skipped"}


def response_of_json(value: Any) -> Response:
    if not isinstance(value, dict):
        raise LogError("response must be an object")
    match value.get("kind"):
        case "chose":
            fields = _exact(value, {"kind", "choice_ids"}, "response")
            return Chose(_texts(fields["choice_ids"], "response.choice_ids"))
        case "wrote":
            fields = _exact(value, {"kind", "text"}, "response")
            if not isinstance(fields["text"], str):
                raise LogError("response.text must be a string")
            return Wrote(fields["text"])
        case "skipped":
            _exact(value, {"kind"}, "response")
            return Skipped()
        case other:
            raise LogError(f"response.kind {other!r} is not chose, wrote or skipped")


@dataclass(frozen=True, slots=True)
class Answer:
    question_id: str
    response: Response

    def to_json(self) -> dict:
        return {"question_id": self.question_id, "response": response_to_json(self.response)}

    @staticmethod
    def of_json(value: Any) -> "Answer":
        fields = _exact(value, {"question_id", "response"}, "answer")
        return Answer(_text(fields["question_id"], "answer.question_id"), response_of_json(fields["response"]))


# -- What a question was asked with as its expected answer (RFC §4.9 Posed):
#    the correct choice ids, or the points a written answer must state. ------

@dataclass(frozen=True, slots=True)
class ChoiceKey:
    choice_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Rubric:
    points: tuple[str, ...]


Key = Union[ChoiceKey, Rubric]


def key_to_json(key: Key) -> dict:
    match key:
        case ChoiceKey(choice_ids):
            return {"kind": "choices", "choice_ids": list(choice_ids)}
        case Rubric(points):
            return {"kind": "rubric", "points": list(points)}


def key_of_json(value: Any) -> Key:
    if not isinstance(value, dict):
        raise LogError("key must be an object")
    match value.get("kind"):
        case "choices":
            fields = _exact(value, {"kind", "choice_ids"}, "key")
            ids = _texts(fields["choice_ids"], "key.choice_ids")
            if not ids:
                raise LogError("key.choice_ids must name a choice")
            return ChoiceKey(ids)
        case "rubric":
            fields = _exact(value, {"kind", "points"}, "key")
            points = _texts(fields["points"], "key.points")
            if not points:
                raise LogError("key.points must name a point")
            return Rubric(points)
        case other:
            raise LogError(f"key.kind {other!r} is not choices or rubric")


# -- A judgment the grade output brings (RFC §6.2, §6.4). A void question or
#    key is not an attempt; the judgment's rationale says what is wrong. ----

@dataclass(frozen=True, slots=True)
class Correct:
    pass


@dataclass(frozen=True, slots=True)
class Incorrect:
    pass


@dataclass(frozen=True, slots=True)
class Void:
    pass


Judgment = Union[Correct, Incorrect, Void]


def judgment_to_json(judgment: Judgment) -> dict:
    match judgment:
        case Correct():
            return {"kind": "correct"}
        case Incorrect():
            return {"kind": "incorrect"}
        case Void():
            return {"kind": "void"}


def judgment_of_json(value: Any) -> Judgment:
    if not isinstance(value, dict):
        raise LogError("judgment must be an object")
    match value.get("kind"):
        case "correct":
            _exact(value, {"kind"}, "judgment")
            return Correct()
        case "incorrect":
            _exact(value, {"kind"}, "judgment")
            return Incorrect()
        case "void":
            _exact(value, {"kind"}, "judgment")
            return Void()
        case other:
            raise LogError(f"judgment.kind {other!r} is not correct, incorrect or void")


# The final results a grade request can end with that bring no judgment. The
# answer stays awaiting judgment, and the next compose asks again.
# request_exceeds_frame: the grade request alone would not fit the package's reply frame.
GRADE_FAILURES = {"invalid_output", "input_refused", "outcome_unknown", "not_allowed", "result_exceeds_frame",
                  "request_exceeds_frame"}


# -- Why a session failed (RFC §4.9 Sessions, closed). ---------------------

@dataclass(frozen=True, slots=True)
class NotAllowed:
    request_id: str
    reason: str


@dataclass(frozen=True, slots=True)
class AuthorInvalidOutput:
    request_id: str


@dataclass(frozen=True, slots=True)
class AuthorInputRefused:
    request_id: str
    kind: str


@dataclass(frozen=True, slots=True)
class AuthorOutcomeUnknown:
    request_id: str


@dataclass(frozen=True, slots=True)
class NoQuestionPassed:
    pass


@dataclass(frozen=True, slots=True)
class NoMaterial:
    """Every grant was read and none held a record to ask about, so no
    author request was made."""


@dataclass(frozen=True, slots=True)
class ResultExceedsFrame:
    """An author or ask result too large for the frame. Read results are read
    back in pieces instead (read_result)."""
    request_id: str


@dataclass(frozen=True, slots=True)
class AuthorRequestExceedsFrame:
    """One material record alone made the author request too large for the
    listing frame, so it could not be listed."""
    request_id: str


Failure = Union[NotAllowed, AuthorInvalidOutput, AuthorInputRefused, AuthorOutcomeUnknown, NoQuestionPassed,
                NoMaterial, ResultExceedsFrame, AuthorRequestExceedsFrame]


def failure_to_json(failure: Failure) -> dict:
    match failure:
        case NotAllowed(request_id, reason):
            return {"kind": "not_allowed", "request_id": request_id, "reason": reason}
        case AuthorInvalidOutput(request_id):
            return {"kind": "author_invalid_output", "request_id": request_id}
        case AuthorInputRefused(request_id, kind):
            return {"kind": "author_input_refused", "request_id": request_id, "refusal": kind}
        case AuthorOutcomeUnknown(request_id):
            return {"kind": "author_outcome_unknown", "request_id": request_id}
        case NoQuestionPassed():
            return {"kind": "no_question_passed"}
        case NoMaterial():
            return {"kind": "no_material"}
        case ResultExceedsFrame(request_id):
            return {"kind": "result_exceeds_frame", "request_id": request_id}
        case AuthorRequestExceedsFrame(request_id):
            return {"kind": "author_request_exceeds_frame", "request_id": request_id}


def failure_of_json(value: Any) -> Failure:
    if not isinstance(value, dict):
        raise LogError("reason must be an object")
    match value.get("kind"):
        case "not_allowed":
            fields = _exact(value, {"kind", "request_id", "reason"}, "reason")
            return NotAllowed(_text(fields["request_id"], "reason.request_id"), _text(fields["reason"], "reason.reason"))
        case "author_invalid_output":
            fields = _exact(value, {"kind", "request_id"}, "reason")
            return AuthorInvalidOutput(_text(fields["request_id"], "reason.request_id"))
        case "author_input_refused":
            fields = _exact(value, {"kind", "request_id", "refusal"}, "reason")
            return AuthorInputRefused(_text(fields["request_id"], "reason.request_id"),
                                      _text(fields["refusal"], "reason.refusal"))
        case "author_outcome_unknown":
            fields = _exact(value, {"kind", "request_id"}, "reason")
            return AuthorOutcomeUnknown(_text(fields["request_id"], "reason.request_id"))
        case "no_question_passed":
            _exact(value, {"kind"}, "reason")
            return NoQuestionPassed()
        case "no_material":
            _exact(value, {"kind"}, "reason")
            return NoMaterial()
        case "result_exceeds_frame":
            fields = _exact(value, {"kind", "request_id"}, "reason")
            return ResultExceedsFrame(_text(fields["request_id"], "reason.request_id"))
        case "author_request_exceeds_frame":
            fields = _exact(value, {"kind", "request_id"}, "reason")
            return AuthorRequestExceedsFrame(_text(fields["request_id"], "reason.request_id"))
        case other:
            raise LogError(f"reason.kind {other!r} is not a session failure")


# -- Events (RFC §4.9 Log). -------------------------------------------------

@dataclass(frozen=True, slots=True)
class SessionOpened:
    session_id: str
    action_request_id: str
    questions: int
    grants: tuple[Grant, ...]
    language: str
    opened_at: float


@dataclass(frozen=True, slots=True)
class MaterialRead:
    """One delivered read result, kept whole under pages/ by its digest. The
    page's cursor, completeness and records, or the file's bytes, are in it."""
    session_id: str
    request_id: str
    digest: str


@dataclass(frozen=True, slots=True)
class ExactRequested:
    session_id: str
    request_id: str
    output: str
    digest: str  # the request body kept under requests/


@dataclass(frozen=True, slots=True)
class AuthorContextRecorded:
    """Domain context of the latest author request, independent of its wire body."""
    session_id: str
    request_id: str
    history_scope: str  # all | open_debt_only


@dataclass(frozen=True, slots=True)
class Posed:
    session_id: str
    ask_id: str
    question_id: str
    item_id: str
    topic: str
    question: dict  # the Keeper question wire form, as asked
    key: Key
    sources: tuple[Source, ...]


@dataclass(frozen=True, slots=True)
class DraftRejected:
    session_id: str
    request_id: str
    index: int
    reason: str


@dataclass(frozen=True, slots=True)
class SessionFailed:
    session_id: str
    reason: Failure


@dataclass(frozen=True, slots=True)
class AnswerReceived:
    ask_id: str
    answers: tuple[Answer, ...]
    responder: dict
    answered_at: float


@dataclass(frozen=True, slots=True)
class GradeRequested:
    """A grade request for one answered question; its body is kept under
    requests/ by its digest."""
    ask_id: str
    question_id: str
    request_id: str
    digest: str


@dataclass(frozen=True, slots=True)
class Judged:
    ask_id: str
    question_id: str
    judgment: Judgment
    rationale: str
    request_id: str  # the grade request that brought it


@dataclass(frozen=True, slots=True)
class GradeFailed:
    ask_id: str
    question_id: str
    request_id: str
    kind: str  # one of GRADE_FAILURES
    detail: str | None


@dataclass(frozen=True, slots=True)
class Disputed:
    """The operator's words about a grade (RFC §6.4); the grade request it
    leads to is written with it."""
    ask_id: str
    question_id: str
    note: str
    action_request_id: str


Grading = Union[GradeRequested, Judged, GradeFailed, Disputed]


# -- What a bound lesson taught (RFC operator-quiz-follows-lesson §3). -------

@dataclass(frozen=True, slots=True)
class Cite:
    """A record a lesson scene quoted. Two cites name the same record only
    when all three are equal: a repository pin does not say which repository."""
    kind: str
    source_id: str
    pin: str

    def to_json(self) -> dict:
        return {"kind": self.kind, "source_id": self.source_id, "pin": self.pin}

    @staticmethod
    def of_json(value: Any) -> "Cite":
        fields = _exact(value, {"kind", "source_id", "pin"}, "cite")
        kind, pin = _text(fields["kind"], "cite.kind"), _text(fields["pin"], "cite.pin")
        parse_pin(kind, pin)
        return Cite(kind, _text(fields["source_id"], "cite.source_id"), pin)


@dataclass(frozen=True, slots=True)
class Scene:
    session_id: str  # the lesson's session, not one of this log's
    entry_id: str
    cites: tuple[Cite, ...]

    def to_json(self) -> dict:
        return {"session_id": self.session_id, "entry_id": self.entry_id,
                "cites": [cite.to_json() for cite in self.cites]}

    @staticmethod
    def of_json(value: Any) -> "Scene":
        fields = _exact(value, {"session_id", "entry_id", "cites"}, "scene")
        if not isinstance(fields["cites"], list) or not fields["cites"]:
            raise LogError("a scene cites at least one record")
        return Scene(_text(fields["session_id"], "scene.session_id"), _text(fields["entry_id"], "scene.entry_id"),
                     tuple(Cite.of_json(cite) for cite in fields["cites"]))


@dataclass(frozen=True, slots=True)
class LessonSeen:
    """One completed output of the bound lesson, read whole at an
    observation. [sha256] is the evidence the host retained for it and
    [rows] the digest of each row's lane and fields: the lesson is observed
    far more often than it writes, so an output whose rows were already
    recorded is not recorded again."""
    instance_id: str
    observation_seq: int
    sha256: str
    rows: str
    scenes: tuple[Scene, ...]


@dataclass(frozen=True, slots=True)
class LessonUnreadable:
    """One completed output of the bound lesson with a row this package does
    not read as a scene. None of its rows count."""
    instance_id: str
    observation_seq: int
    sha256: str
    rows: str
    reason: str


@dataclass(frozen=True, slots=True)
class FollowsLesson:
    """Written with session_opened when the binding names a lesson source:
    the session's new questions come only from records a lesson cited."""
    session_id: str
    source_id: str


@dataclass(frozen=True, slots=True)
class LessonScopeApplied:
    """Written with an author request of a session that follows a lesson:
    the records its material holds, which are the cited ones among those read."""
    session_id: str
    request_id: str
    kept: tuple[Cite, ...]

Event = Union[SessionOpened, MaterialRead, ExactRequested, AuthorContextRecorded, Posed, DraftRejected, SessionFailed, AnswerReceived,
              GradeRequested, Judged, GradeFailed, Disputed, LessonSeen, LessonUnreadable, FollowsLesson,
              LessonScopeApplied]


def event_to_json(event: Event) -> dict:
    match event:
        case SessionOpened(session_id, action_request_id, questions, grants, language, opened_at):
            return {"event": "session_opened", "session_id": session_id,
                    "action_request_id": action_request_id, "questions": questions,
                    "grants": [grant.to_json() for grant in grants], "language": language,
                    "opened_at": opened_at}
        case MaterialRead(session_id, request_id, digest):
            return {"event": "material_read", "session_id": session_id, "request_id": request_id, "digest": digest}
        case ExactRequested(session_id, request_id, output, digest):
            return {"event": "exact_requested", "session_id": session_id, "request_id": request_id,
                    "output": output, "digest": digest}
        case AuthorContextRecorded(session_id, request_id, history_scope):
            return {"event": "author_context_recorded", "session_id": session_id,
                    "request_id": request_id, "history_scope": history_scope}
        case Posed(session_id, ask_id, question_id, item_id, topic, question, key, sources):
            return {"event": "posed", "session_id": session_id, "ask_id": ask_id, "question_id": question_id,
                    "item_id": item_id, "topic": topic, "question": question, "key": key_to_json(key),
                    "sources": [source.to_json() for source in sources]}
        case DraftRejected(session_id, request_id, index, reason):
            return {"event": "draft_rejected", "session_id": session_id, "request_id": request_id,
                    "index": index, "reason": reason}
        case SessionFailed(session_id, reason):
            return {"event": "session_failed", "session_id": session_id, "reason": failure_to_json(reason)}
        case AnswerReceived(ask_id, answers, responder, answered_at):
            return {"event": "answer_received", "ask_id": ask_id,
                    "answers": [answer.to_json() for answer in answers],
                    "responder": responder, "answered_at": answered_at}
        case GradeRequested(ask_id, question_id, request_id, digest):
            return {"event": "grade_requested", "ask_id": ask_id, "question_id": question_id,
                    "request_id": request_id, "digest": digest}
        case Judged(ask_id, question_id, judgment, rationale, request_id):
            return {"event": "judged", "ask_id": ask_id, "question_id": question_id,
                    "judgment": judgment_to_json(judgment), "rationale": rationale, "request_id": request_id}
        case GradeFailed(ask_id, question_id, request_id, kind, detail):
            return {"event": "grade_failed", "ask_id": ask_id, "question_id": question_id,
                    "request_id": request_id, "kind": kind, "detail": detail}
        case Disputed(ask_id, question_id, note, action_request_id):
            return {"event": "disputed", "ask_id": ask_id, "question_id": question_id, "note": note,
                    "action_request_id": action_request_id}
        case LessonSeen(instance_id, observation_seq, sha256, rows, scenes):
            return {"event": "lesson_seen", "instance_id": instance_id, "observation_seq": observation_seq,
                    "sha256": sha256, "rows": rows, "scenes": [scene.to_json() for scene in scenes]}
        case LessonUnreadable(instance_id, observation_seq, sha256, rows, reason):
            return {"event": "lesson_unreadable", "instance_id": instance_id, "observation_seq": observation_seq,
                    "sha256": sha256, "rows": rows, "reason": reason}
        case FollowsLesson(session_id, source_id):
            return {"event": "follows_lesson", "session_id": session_id, "source_id": source_id}
        case LessonScopeApplied(session_id, request_id, kept):
            return {"event": "lesson_scope_applied", "session_id": session_id, "request_id": request_id,
                    "kept": [cite.to_json() for cite in kept]}


def event_of_json(value: Any) -> Event:
    if not isinstance(value, dict):
        raise LogError("an event must be an object")
    match value.get("event"):
        case "session_opened":
            f = _exact(value, {"event", "session_id", "action_request_id", "questions", "grants", "language",
                               "opened_at"}, "session_opened")
            if not isinstance(f["grants"], list) or not f["grants"]:
                raise LogError("session_opened.grants must be a non-empty array")
            grants = tuple(Grant.of_json(grant) for grant in f["grants"])
            if len({grant.source_id for grant in grants}) != len(grants):
                raise LogError("session_opened.grants names a source twice")
            return SessionOpened(_text(f["session_id"], "session_id"),
                                 _text(f["action_request_id"], "action_request_id"),
                                 _count(f["questions"], "questions"), grants, _text(f["language"], "language"),
                                 _time(f["opened_at"], "opened_at"))
        case "material_read":
            f = _exact(value, {"event", "session_id", "request_id", "digest"}, "material_read")
            return MaterialRead(_text(f["session_id"], "session_id"), _text(f["request_id"], "request_id"),
                                _text(f["digest"], "digest"))
        case "exact_requested":
            f = _exact(value, {"event", "session_id", "request_id", "output", "digest"}, "exact_requested")
            return ExactRequested(_text(f["session_id"], "session_id"), _text(f["request_id"], "request_id"),
                                  _text(f["output"], "output"), _text(f["digest"], "digest"))
        case "author_context_recorded":
            f = _exact(value, {"event", "session_id", "request_id", "history_scope"}, "author_context_recorded")
            if f["history_scope"] not in ("all", "open_debt_only"):
                raise LogError("author history_scope must be all or open_debt_only")
            return AuthorContextRecorded(_text(f["session_id"], "session_id"),
                                         _text(f["request_id"], "request_id"), f["history_scope"])
        case "posed":
            f = _exact(value, {"event", "session_id", "ask_id", "question_id", "item_id", "topic", "question",
                               "key", "sources"}, "posed")
            if not isinstance(f["question"], dict):
                raise LogError("posed.question must be an object")
            if not isinstance(f["sources"], list):
                raise LogError("posed.sources must be an array")
            return Posed(_text(f["session_id"], "session_id"), _text(f["ask_id"], "ask_id"),
                         _text(f["question_id"], "question_id"), _text(f["item_id"], "item_id"),
                         _text(f["topic"], "topic"), f["question"], key_of_json(f["key"]),
                         tuple(Source.of_json(source) for source in f["sources"]))
        case "draft_rejected":
            f = _exact(value, {"event", "session_id", "request_id", "index", "reason"}, "draft_rejected")
            return DraftRejected(_text(f["session_id"], "session_id"), _text(f["request_id"], "request_id"),
                                 _index(f["index"], "index"), _text(f["reason"], "reason"))
        case "session_failed":
            f = _exact(value, {"event", "session_id", "reason"}, "session_failed")
            return SessionFailed(_text(f["session_id"], "session_id"), failure_of_json(f["reason"]))
        case "answer_received":
            f = _exact(value, {"event", "ask_id", "answers", "responder", "answered_at"}, "answer_received")
            if not isinstance(f["answers"], list):
                raise LogError("answer_received.answers must be an array")
            if not isinstance(f["responder"], dict):
                raise LogError("answer_received.responder must be an object")
            return AnswerReceived(_text(f["ask_id"], "ask_id"), tuple(Answer.of_json(a) for a in f["answers"]),
                                  f["responder"], _time(f["answered_at"], "answered_at"))
        case "grade_requested":
            f = _exact(value, {"event", "ask_id", "question_id", "request_id", "digest"}, "grade_requested")
            return GradeRequested(_text(f["ask_id"], "ask_id"), _text(f["question_id"], "question_id"),
                                  _text(f["request_id"], "request_id"), _text(f["digest"], "digest"))
        case "judged":
            f = _exact(value, {"event", "ask_id", "question_id", "judgment", "rationale", "request_id"}, "judged")
            return Judged(_text(f["ask_id"], "ask_id"), _text(f["question_id"], "question_id"),
                          judgment_of_json(f["judgment"]), _text(f["rationale"], "rationale"),
                          _text(f["request_id"], "request_id"))
        case "grade_failed":
            f = _exact(value, {"event", "ask_id", "question_id", "request_id", "kind", "detail"}, "grade_failed")
            kind = _text(f["kind"], "grade_failed.kind")
            if kind not in GRADE_FAILURES:
                raise LogError(f"grade_failed.kind {kind!r} is not a final grade failure")
            detail = None if f["detail"] is None else _text(f["detail"], "grade_failed.detail")
            return GradeFailed(_text(f["ask_id"], "ask_id"), _text(f["question_id"], "question_id"),
                               _text(f["request_id"], "request_id"), kind, detail)
        case "disputed":
            f = _exact(value, {"event", "ask_id", "question_id", "note", "action_request_id"}, "disputed")
            return Disputed(_text(f["ask_id"], "ask_id"), _text(f["question_id"], "question_id"),
                            _text(f["note"], "note"), _text(f["action_request_id"], "action_request_id"))
        case "lesson_seen":
            f = _exact(value, {"event", "instance_id", "observation_seq", "sha256", "rows", "scenes"}, "lesson_seen")
            if not isinstance(f["scenes"], list):
                raise LogError("lesson_seen.scenes must be an array")
            return LessonSeen(_text(f["instance_id"], "instance_id"), _count(f["observation_seq"], "observation_seq"),
                              _text(f["sha256"], "sha256"), _text(f["rows"], "rows"),
                              tuple(Scene.of_json(scene) for scene in f["scenes"]))
        case "lesson_unreadable":
            f = _exact(value, {"event", "instance_id", "observation_seq", "sha256", "rows", "reason"},
                       "lesson_unreadable")
            return LessonUnreadable(_text(f["instance_id"], "instance_id"),
                                    _count(f["observation_seq"], "observation_seq"),
                                    _text(f["sha256"], "sha256"), _text(f["rows"], "rows"),
                                    _text(f["reason"], "reason"))
        case "follows_lesson":
            f = _exact(value, {"event", "session_id", "source_id"}, "follows_lesson")
            return FollowsLesson(_text(f["session_id"], "session_id"), _text(f["source_id"], "source_id"))
        case "lesson_scope_applied":
            f = _exact(value, {"event", "session_id", "request_id", "kept"}, "lesson_scope_applied")
            if not isinstance(f["kept"], list):
                raise LogError("lesson_scope_applied.kept must be an array")
            return LessonScopeApplied(_text(f["session_id"], "session_id"), _text(f["request_id"], "request_id"),
                                      tuple(Cite.of_json(cite) for cite in f["kept"]))
        case other:
            raise LogError(f"event {other!r} is not an event of this package")


# -- The files. --------------------------------------------------------------

def unreadable(event: Event) -> str | None:
    """Why this event would not read back as written, or None."""
    return records.unreadable(event, event_to_json, event_of_json)


class Log(records.Log[Event]):
    def __init__(self, state: Path):
        super().__init__(state / FOLDER, event_to_json, event_of_json)


class Blobs(records.Blobs):
    def __init__(self, state: Path, kind: str):
        super().__init__(state / FOLDER / kind)



# -- Sessions (RFC §4.9 Sessions). "graded" is derived by grading, from an
#    answered session's verdicts. -------------------------------------------

@dataclass(frozen=True, slots=True)
class Session:
    session_id: str
    action_request_id: str
    questions: int
    grants: tuple[Grant, ...]
    language: str
    opened_at: float
    state: str  # writing | asked | answered | failed | superseded
    failure: Failure | None
    superseded_by: str | None
    material: tuple[MaterialRead, ...]
    requests: tuple[ExactRequested, ...]
    rejected: tuple[DraftRejected, ...]
    posed: tuple[Posed, ...]
    answer: AnswerReceived | None
    grading: tuple[Grading, ...]  # in log order
    history_scope: str | None  # None means no domain context was recorded; never infer it from request wire.
    follows: str | None  # the lesson source this session follows, from follows_lesson
    scopes: tuple[LessonScopeApplied, ...]  # one per author request of a session that follows a lesson
    taught: frozenset[str]  # question ids whose source a lesson seen before the question had cited

    @property
    def ask_id(self) -> str | None:
        return self.posed[0].ask_id if self.posed else None

    def grading_of(self, question_id: str) -> tuple[Grading, ...]:
        return tuple(event for event in self.grading if event.question_id == question_id)

    def judgments_of(self, question_id: str) -> tuple[Judged, ...]:
        return tuple(event for event in self.grading_of(question_id) if isinstance(event, Judged))

    def disputes_of(self, question_id: str) -> tuple[Disputed, ...]:
        return tuple(event for event in self.grading_of(question_id) if isinstance(event, Disputed))

    def outstanding_grade(self, question_id: str) -> GradeRequested | None:
        """The grade request for this question that has no result yet."""
        events = self.grading_of(question_id)
        return events[-1] if events and isinstance(events[-1], GradeRequested) else None


def fold(events: list[Event]) -> list[Session]:
    """Sessions in the order they were opened. History that contradicts
    itself (an event for a session that cannot take it) is a LogError: the
    package wrote it, so a reader that skipped it would hide a fault."""
    sessions: dict[str, dict] = {}
    order: list[str] = []
    by_ask: dict[str, str] = {}
    outputs: set[tuple[type, str]] = set()
    cited: set[tuple[str, str, str]] = set()
    grade_requests: set[str] = set()
    disputes: set[str] = set()

    def session(session_id: str, label: str) -> dict:
        if session_id not in sessions:
            raise LogError(f"{label} names session {session_id}, which was never opened")
        return sessions[session_id]

    def writing(session_id: str, label: str) -> dict:
        current = session(session_id, label)
        if current["state"] != "writing":
            raise LogError(f"{label} for session {session_id}, which is {current['state']}")
        return current

    for event in events:
        match event:
            case SessionOpened(session_id=session_id, action_request_id=action_request_id, questions=questions,
                               grants=grants, language=language, opened_at=opened_at):
                if session_id in sessions:
                    raise LogError(f"session {session_id} was opened twice")
                for other in sessions.values():
                    if other["state"] == "writing":
                        other["state"] = "superseded"
                        other["superseded_by"] = session_id
                sessions[session_id] = {"session_id": session_id, "action_request_id": action_request_id,
                                        "questions": questions, "grants": grants, "language": language,
                                        "opened_at": opened_at, "state": "writing", "failure": None,
                                        "superseded_by": None, "material": [], "requests": [], "rejected": [],
                                        "posed": [], "answer": None, "grading": [], "history_scope": None,
                                        "follows": None, "scopes": [], "taught": set()}
                order.append(session_id)
            case LessonSeen(rows=rows) | LessonUnreadable(rows=rows):
                # Rows recorded as unreadable may be recorded as seen later,
                # by a revision that reads them; neither is recorded twice.
                if (type(event), rows) in outputs or (LessonSeen, rows) in outputs:
                    raise LogError(f"the lesson output with rows {rows} was recorded twice")
                outputs.add((type(event), rows))
                if isinstance(event, LessonSeen):
                    cited.update((cite.kind, cite.source_id, cite.pin) for scene in event.scenes for cite in scene.cites)
            case FollowsLesson(session_id=session_id, source_id=source_id):
                current = writing(session_id, "follows_lesson")
                if current["follows"] is not None or current["material"] or current["requests"]:
                    raise LogError(f"follows_lesson for session {session_id} does not come with its opening")
                current["follows"] = source_id
            case LessonScopeApplied(session_id=session_id, request_id=request_id):
                current = writing(session_id, "lesson_scope_applied")
                latest = current["requests"][-1] if current["requests"] else None
                if current["follows"] is None or latest is None or latest.request_id != request_id \
                        or latest.output != "author":
                    raise LogError("lesson scope does not name the latest author request of a session that follows")
                if any(scope.request_id == request_id for scope in current["scopes"]):
                    raise LogError(f"lesson scope of {request_id} was recorded twice")
                current["scopes"].append(event)
            case MaterialRead(session_id=session_id):
                writing(session_id, "material_read")["material"].append(event)
            case ExactRequested(session_id=session_id):
                current = writing(session_id, "exact_requested")
                current["requests"].append(event)
                current["history_scope"] = None
            case AuthorContextRecorded(session_id=session_id, request_id=request_id, history_scope=scope):
                current = writing(session_id, "author_context_recorded")
                latest = current["requests"][-1] if current["requests"] else None
                if latest is None or latest.request_id != request_id or latest.output != "author":
                    raise LogError("author context does not name the latest author request")
                if scope not in ("all", "open_debt_only") or current["history_scope"] is not None:
                    raise LogError("author context is invalid or already recorded")
                current["history_scope"] = scope
            case DraftRejected(session_id=session_id):
                writing(session_id, "draft_rejected")["rejected"].append(event)
            case Posed(session_id=session_id, ask_id=ask_id, question_id=question_id):
                current = session(session_id, "posed")
                if current["state"] == "writing":
                    current["state"] = "asked"
                elif current["state"] != "asked" or current["answer"] is not None:
                    raise LogError(f"posed for session {session_id}, which is {current['state']}")
                if by_ask.setdefault(ask_id, session_id) != session_id:
                    raise LogError(f"ask {ask_id} belongs to another session")
                if any(p.ask_id != ask_id for p in current["posed"]):
                    raise LogError(f"session {session_id} posed under two asks")
                if any(p.question_id == question_id for p in current["posed"]):
                    raise LogError(f"question {question_id} was posed twice in session {session_id}")
                current["posed"].append(event)
                if any((source.kind, source.source_id, source.pin) in cited for source in event.sources):
                    current["taught"].add(question_id)
            case SessionFailed(session_id=session_id, reason=reason):
                # An asked session fails when the host refuses its ask by rule.
                current = session(session_id, "session_failed")
                if current["state"] not in ("writing", "asked"):
                    raise LogError(f"session_failed for session {session_id}, which is {current['state']}")
                current["state"] = "failed"
                current["failure"] = reason
            case AnswerReceived(ask_id=ask_id):
                if ask_id not in by_ask:
                    raise LogError(f"answer_received for ask {ask_id}, which no session posed")
                current = sessions[by_ask[ask_id]]
                if current["state"] != "asked":
                    raise LogError(f"answer_received for session {current['session_id']}, which is {current['state']}")
                # A question asked with a rubric has no choices to choose.
                rubric = {p.question_id for p in current["posed"] if isinstance(p.key, Rubric)}
                if any(isinstance(a.response, Chose) and a.question_id in rubric for a in event.answers):
                    raise LogError(f"answer_received chooses on a question of ask {ask_id} that has no choices")
                current["state"] = "answered"
                current["answer"] = event
            case Disputed(ask_id=ask_id, question_id=question_id, action_request_id=action_request_id):
                if ask_id not in by_ask or sessions[by_ask[ask_id]]["state"] != "answered":
                    raise LogError(f"disputed for ask {ask_id}, which no answered session posed")
                current = sessions[by_ask[ask_id]]
                if all(p.question_id != question_id for p in current["posed"]):
                    raise LogError(f"disputed for question {question_id}, which ask {ask_id} did not pose")
                earlier = [e for e in current["grading"] if e.question_id == question_id]
                if earlier and isinstance(earlier[-1], GradeRequested):
                    raise LogError(f"disputed for {ask_id}/{question_id} while {earlier[-1].request_id} waits")
                if action_request_id in disputes:
                    raise LogError(f"dispute action {action_request_id} was written twice")
                disputes.add(action_request_id)
                current["grading"].append(event)
            case GradeRequested(ask_id=ask_id, question_id=question_id, request_id=request_id) \
                    | Judged(ask_id=ask_id, question_id=question_id, request_id=request_id) \
                    | GradeFailed(ask_id=ask_id, question_id=question_id, request_id=request_id):
                label = type(event).__name__
                if ask_id not in by_ask or sessions[by_ask[ask_id]]["state"] != "answered":
                    raise LogError(f"{label} for ask {ask_id}, which no answered session posed")
                current = sessions[by_ask[ask_id]]
                if all(p.question_id != question_id for p in current["posed"]):
                    raise LogError(f"{label} for question {question_id}, which ask {ask_id} did not pose")
                earlier = [e for e in current["grading"] if e.question_id == question_id]
                outstanding = earlier[-1] if earlier and isinstance(earlier[-1], GradeRequested) else None
                if isinstance(event, GradeRequested):
                    if outstanding is not None:
                        raise LogError(f"{label} for {ask_id}/{question_id} while {outstanding.request_id} waits")
                    if request_id in grade_requests:
                        raise LogError(f"grade request {request_id} was written twice")
                    grade_requests.add(request_id)
                elif outstanding is None or outstanding.request_id != request_id:
                    raise LogError(f"{label} for {request_id}, which is not the waiting grade request")
                current["grading"].append(event)
    return [Session(s["session_id"], s["action_request_id"], s["questions"], s["grants"], s["language"],
                    s["opened_at"], s["state"], s["failure"],
                    s["superseded_by"], tuple(s["material"]), tuple(s["requests"]), tuple(s["rejected"]),
                    tuple(s["posed"]), s["answer"], tuple(s["grading"]), s["history_scope"], s["follows"],
                    tuple(s["scopes"]), frozenset(s["taught"]))
            for s in (sessions[session_id] for session_id in order)]


def cited(events: list[Event]) -> frozenset[Cite]:
    """Every record a lesson output read so far cited."""
    return frozenset(cite for event in events if isinstance(event, LessonSeen)
                     for scene in event.scenes for cite in scene.cites)
