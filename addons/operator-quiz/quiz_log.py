"""The operator quiz's own record (RFC operator-quiz §4.9 Log, Sessions).

One append-only JSON line per event at ``<state>/operator-quiz/log.jsonl``.
Events and their fields are closed sets: an unknown event or field is an
error naming the line, and a log that cannot be read refuses every write.

A write always ends with a newline, so a last segment without one is a write
the process did not finish. Reading skips it and the next append cuts it off
first; every complete line before it must decode.

A session's state is a fold of the log. Nothing else is stored about it.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Union


class LogError(Exception):
    """The log cannot be read as this package's history."""


def _exact(value: Any, keys: set[str], label: str) -> dict:
    if not isinstance(value, dict):
        raise LogError(f"{label} must be an object")
    extra = set(value) - keys
    missing = keys - set(value)
    if extra:
        raise LogError(f"{label} has unknown field {sorted(extra)[0]}")
    if missing:
        raise LogError(f"{label} is missing {sorted(missing)[0]}")
    return value


def _text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise LogError(f"{label} must be a non-blank string")
    return value


def _count(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise LogError(f"{label} must be a positive integer")
    return value


def _index(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise LogError(f"{label} must be a non-negative integer")
    return value


def _time(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        raise LogError(f"{label} must be a number")
    return float(value)


def _texts(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise LogError(f"{label} must be an array")
    return tuple(_text(item, label) for item in value)


# -- Sources a question cites (RFC §5). The first slice has three kinds. ----

SOURCE_KINDS = {"board_post", "board_comment", "repo_file"}


@dataclass(frozen=True, slots=True)
class Source:
    kind: str
    source_id: str  # the grant
    pin: str  # post id, "post id/comment id", or "commit:path"
    quote: str
    sha256: str  # the retained bytes the quote was checked against

    def to_json(self) -> dict:
        return {"kind": self.kind, "source_id": self.source_id, "pin": self.pin,
                "quote": self.quote, "sha256": self.sha256}

    @staticmethod
    def of_json(value: Any) -> "Source":
        fields = _exact(value, {"kind", "source_id", "pin", "quote", "sha256"}, "source")
        kind = _text(fields["kind"], "source.kind")
        if kind not in SOURCE_KINDS:
            raise LogError(f"source.kind {kind} is not a kind this package cites")
        # Kept byte for byte, spacing included, but whitespace alone cites nothing.
        if not isinstance(fields["quote"], str) or not fields["quote"].strip():
            raise LogError("source.quote must hold more than whitespace")
        return Source(kind, _text(fields["source_id"], "source.source_id"),
                      _text(fields["pin"], "source.pin"), fields["quote"],
                      _text(fields["sha256"], "source.sha256"))


# -- The grants a session reads, fixed when it opens. The listing is then a
#    function of the log alone, even before this worker's first observation.

GRANT_KINDS = {"board", "repository"}


@dataclass(frozen=True, slots=True)
class Grant:
    source_id: str
    kind: str
    paths: tuple[str, ...]  # repository grants only: the files read for each new commit

    def to_json(self) -> dict:
        return {"source_id": self.source_id, "kind": self.kind, "paths": list(self.paths)}

    @staticmethod
    def of_json(value: Any) -> "Grant":
        fields = _exact(value, {"source_id", "kind", "paths"}, "grant")
        kind = _text(fields["kind"], "grant.kind")
        if kind not in GRANT_KINDS:
            raise LogError(f"grant.kind {kind} is not a kind this package reads")
        paths = _texts(fields["paths"], "grant.paths")
        if (kind == "repository") != bool(paths):
            raise LogError("grant.paths is required for a repository grant and only for one")
        return Grant(_text(fields["source_id"], "grant.source_id"), kind, paths)


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


# -- Events (RFC §4.9 Log). Disputed arrives with the dispute action. -------

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
class Posed:
    session_id: str
    ask_id: str
    question_id: str
    item_id: str
    topic: str
    question: dict  # the Keeper question wire form, as asked
    key: tuple[str, ...]  # the correct choice ids
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


Event = Union[SessionOpened, MaterialRead, ExactRequested, Posed, DraftRejected, SessionFailed, AnswerReceived,
              GradeRequested, Judged, GradeFailed]


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
        case Posed(session_id, ask_id, question_id, item_id, topic, question, key, sources):
            return {"event": "posed", "session_id": session_id, "ask_id": ask_id, "question_id": question_id,
                    "item_id": item_id, "topic": topic, "question": question, "key": list(key),
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
        case "posed":
            f = _exact(value, {"event", "session_id", "ask_id", "question_id", "item_id", "topic", "question",
                               "key", "sources"}, "posed")
            if not isinstance(f["question"], dict):
                raise LogError("posed.question must be an object")
            if not isinstance(f["sources"], list):
                raise LogError("posed.sources must be an array")
            return Posed(_text(f["session_id"], "session_id"), _text(f["ask_id"], "ask_id"),
                         _text(f["question_id"], "question_id"), _text(f["item_id"], "item_id"),
                         _text(f["topic"], "topic"), f["question"], _texts(f["key"], "key"),
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
        case other:
            raise LogError(f"event {other!r} is not an event of this package")


# -- The file. --------------------------------------------------------------

def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _make_directory(path: Path) -> None:
    """Creates the folder and any missing parents, syncing each parent that
    gained an entry, so a new folder survives a crash with its contents."""
    if path.is_dir():
        return
    _make_directory(path.parent)
    path.mkdir()
    _fsync_directory(path.parent)


def _line(event: Event) -> bytes:
    """The bytes one event is written as."""
    return (json.dumps(event_to_json(event), ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            + "\n").encode("utf-8")


def unreadable(event: Event) -> str | None:
    """Why this event would not read back as written, or None. It is checked
    through the bytes it would be written as: text UTF-8 cannot hold, such as
    a lone surrogate, never reaches the file."""
    try:
        if event_of_json(json.loads(_line(event).decode("utf-8"))) == event:
            return None
        return f"{type(event).__name__} reads back differently"
    except UnicodeEncodeError:
        return f"{type(event).__name__} holds text UTF-8 cannot encode"
    except (LogError, ValueError, TypeError) as error:
        return str(error)


class Log:
    def __init__(self, state: Path):
        self.directory = state / "operator-quiz"
        self.path = self.directory / "log.jsonl"
        # Lines already decoded, their byte length and the last of them.
        self._events: list[Event] = []
        self._complete = 0
        self._last_line = b""

    def _read(self) -> tuple[list[Event], int]:
        """Events and the byte length of the complete lines.

        Lines decoded before are kept and only the bytes after them are read:
        the worker is the log's only writer, so those bytes do not change. A
        shorter file, or a last line that is no longer where it was, means
        they did, and the whole file is decoded again."""
        try:
            with open(self.path, "rb") as handle:
                start = self._complete
                if start:
                    size = os.fstat(handle.fileno()).st_size
                    handle.seek(start - len(self._last_line) - 1)
                    if size < start or handle.read(len(self._last_line) + 1) != self._last_line + b"\n":
                        self._events, self._complete, self._last_line, start = [], 0, b"", 0
                handle.seek(start)
                data = handle.read()
        except FileNotFoundError:
            self._events, self._complete, self._last_line = [], 0, b""
            return [], 0
        complete = data.rfind(b"\n") + 1
        lines = data[:complete].split(b"\n")[:-1]
        events: list[Event] = []
        for number, line in enumerate(lines, start=len(self._events) + 1):
            try:
                events.append(event_of_json(json.loads(line.decode("utf-8"))))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise LogError(f"line {number} of {self.path} is not JSON: {error}") from error
            except LogError as error:
                raise LogError(f"line {number} of {self.path}: {error}") from error
        if lines:
            self._events = self._events + events
            self._complete = start + complete
            self._last_line = lines[-1]
        return list(self._events), self._complete

    def read(self) -> list[Event]:
        return self._read()[0]

    def append(self, events: list[Event]) -> None:
        """Appends after the history decodes; the lines are synced before return."""
        if not events:
            return
        # A line that would not read back would make the whole log unreadable.
        for event in events:
            problem = unreadable(event)
            if problem is not None:
                raise LogError(problem)
        _, complete = self._read()
        payload = b"".join(_line(event) for event in events)
        created = not self.path.exists()
        _make_directory(self.directory)
        descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT, 0o600)
        try:
            os.ftruncate(descriptor, complete)  # cut off an unfinished write
            os.lseek(descriptor, complete, os.SEEK_SET)
            written = 0
            while written < len(payload):
                written += os.write(descriptor, payload[written:])
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        if created:
            _fsync_directory(self.directory)


class Blobs:
    """Bodies the log names by digest: the package's exact requests and the
    pages it read. Written whole before the event that names them."""

    def __init__(self, state: Path, kind: str):
        self.directory = state / "operator-quiz" / kind

    def path(self, digest: str) -> Path:
        if not digest or any(c not in "0123456789abcdef" for c in digest):
            raise LogError(f"{digest!r} is not a digest")
        return self.directory / f"{digest}.json"

    def write(self, digest: str, value: Any) -> None:
        target = self.path(digest)
        if target.exists():
            return
        _make_directory(self.directory)
        temporary = target.with_suffix(".tmp")
        with open(temporary, "wb") as handle:
            handle.write(json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True).encode("utf-8"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
        _fsync_directory(self.directory)

    def read(self, digest: str) -> Any:
        try:
            return json.loads(self.path(digest).read_bytes().decode("utf-8"))
        except FileNotFoundError as error:
            raise LogError(f"the log names {digest} and it is not kept") from error
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise LogError(f"{digest} is not JSON: {error}") from error


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
    grading: tuple[GradeRequested | Judged | GradeFailed, ...]  # in log order

    @property
    def ask_id(self) -> str | None:
        return self.posed[0].ask_id if self.posed else None

    def grading_of(self, question_id: str) -> tuple[GradeRequested | Judged | GradeFailed, ...]:
        return tuple(event for event in self.grading if event.question_id == question_id)

    def judgments_of(self, question_id: str) -> tuple[Judged, ...]:
        return tuple(event for event in self.grading_of(question_id) if isinstance(event, Judged))

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
    grade_requests: set[str] = set()

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
                                        "posed": [], "answer": None, "grading": []}
                order.append(session_id)
            case MaterialRead(session_id=session_id):
                writing(session_id, "material_read")["material"].append(event)
            case ExactRequested(session_id=session_id):
                writing(session_id, "exact_requested")["requests"].append(event)
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
                current["state"] = "answered"
                current["answer"] = event
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
                    tuple(s["posed"]), s["answer"], tuple(s["grading"]))
            for s in (sessions[session_id] for session_id in order)]
