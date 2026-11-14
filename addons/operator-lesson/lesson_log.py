"""The operator lesson's own record (RFC operator-lesson §4.5).

One append-only JSON line per event at ``<state>/operator-lesson/log.jsonl``.
Events, their fields and every reason are closed sets. The file, the pins and
the grants are the shared ones of records.py; the events, the sessions and
their fold are here.

A session's state is a fold of the log. Nothing else is stored about it.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Union

import records
from records import (  # noqa: F401  -- the names this package's modules and tests read from here
    Grant, LogError, Source, count, exact, index, number, parse_pin, text, texts)

FOLDER = "operator-lesson"  # under the persistent volume


def _string(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise LogError(f"{label} must be a string")
    return value


# -- What a model output named as a source, kept as it was written. A
#    rejected one may be no pin at all, so it is three strings and no more.

@dataclass(frozen=True, slots=True)
class Cite:
    kind: str
    source_id: str
    pin: str

    def to_json(self) -> dict:
        return {"kind": self.kind, "source_id": self.source_id, "pin": self.pin}

    @staticmethod
    def of_json(value: Any) -> "Cite":
        fields = exact(value, {"kind", "source_id", "pin"}, "cite")
        return Cite(_string(fields["kind"], "cite.kind"), _string(fields["source_id"], "cite.source_id"),
                    _string(fields["pin"], "cite.pin"))


# -- An outline entry that passed: what one scene is about and the records
#    it may quote. Its sources are pins of records the session read.

@dataclass(frozen=True, slots=True)
class Entry:
    entry_id: str
    title: str
    points: tuple[str, ...]
    sources: tuple[Cite, ...]

    def to_json(self) -> dict:
        return {"entry_id": self.entry_id, "title": self.title, "points": list(self.points),
                "sources": [source.to_json() for source in self.sources]}

    @staticmethod
    def of_json(value: Any) -> "Entry":
        fields = exact(value, {"entry_id", "title", "points", "sources"}, "entry")
        points = texts(fields["points"], "entry.points")
        if not isinstance(fields["sources"], list) or not fields["sources"] or not points:
            raise LogError("an entry names at least one point and one source")
        sources = tuple(Cite.of_json(source) for source in fields["sources"])
        for source in sources:
            parse_pin(source.kind, source.pin)
            text(source.source_id, "entry.sources.source_id")
        return Entry(text(fields["entry_id"], "entry.entry_id"), text(fields["title"], "entry.title"), points,
                     sources)


@dataclass(frozen=True, slots=True)
class Paragraph:
    text: str
    sources: tuple[Source, ...]

    def to_json(self) -> dict:
        return {"text": self.text, "sources": [source.to_json() for source in self.sources]}

    @staticmethod
    def of_json(value: Any) -> "Paragraph":
        fields = exact(value, {"text", "sources"}, "paragraph")
        if not isinstance(fields["sources"], list) or not fields["sources"]:
            raise LogError("a paragraph cites at least one source")
        return Paragraph(text(fields["text"], "paragraph.text"),
                         tuple(Source.of_json(source) for source in fields["sources"]))


# -- Why an outline entry was dropped (closed). -----------------------------

@dataclass(frozen=True, slots=True)
class SourceNotRead:
    source: Cite


@dataclass(frozen=True, slots=True)
class DuplicateEntryId:
    pass


@dataclass(frozen=True, slots=True)
class BeyondRequestedScenes:
    pass


@dataclass(frozen=True, slots=True)
class Incomplete:
    """A blank id, title, point or paragraph, or none where one is needed."""


@dataclass(frozen=True, slots=True)
class NotRecordable:
    """The log's own decoder would not read it back, as with text UTF-8
    cannot hold."""
    detail: str


EntryRejection = Union[SourceNotRead, DuplicateEntryId, BeyondRequestedScenes, Incomplete, NotRecordable]


def entry_rejection_to_json(reason: EntryRejection) -> dict:
    match reason:
        case SourceNotRead(source):
            return {"kind": "source_not_read", "source": source.to_json()}
        case DuplicateEntryId():
            return {"kind": "duplicate_entry_id"}
        case BeyondRequestedScenes():
            return {"kind": "beyond_requested_scenes"}
        case Incomplete():
            return {"kind": "incomplete"}
        case NotRecordable(detail):
            return {"kind": "not_recordable", "detail": detail}


def entry_rejection_of_json(value: Any) -> EntryRejection:
    if not isinstance(value, dict):
        raise LogError("reason must be an object")
    match value.get("kind"):
        case "source_not_read":
            return SourceNotRead(Cite.of_json(exact(value, {"kind", "source"}, "reason")["source"]))
        case "duplicate_entry_id":
            exact(value, {"kind"}, "reason")
            return DuplicateEntryId()
        case "beyond_requested_scenes":
            exact(value, {"kind"}, "reason")
            return BeyondRequestedScenes()
        case "incomplete":
            exact(value, {"kind"}, "reason")
            return Incomplete()
        case "not_recordable":
            return NotRecordable(text(exact(value, {"kind", "detail"}, "reason")["detail"], "reason.detail"))
        case other:
            raise LogError(f"reason.kind {other!r} is not a reason an entry is dropped for")


# -- Why a scene was not written (closed). ----------------------------------

@dataclass(frozen=True, slots=True)
class SceneNotAllowed:
    reason: str


@dataclass(frozen=True, slots=True)
class InvalidOutput:
    pass


@dataclass(frozen=True, slots=True)
class InputRefused:
    kind: str


@dataclass(frozen=True, slots=True)
class OutcomeUnknown:
    pass


@dataclass(frozen=True, slots=True)
class RequestExceedsFrame:
    pass


@dataclass(frozen=True, slots=True)
class SceneResultExceedsFrame:
    pass


@dataclass(frozen=True, slots=True)
class QuoteNotInRecord:
    paragraph: int
    source: Cite


@dataclass(frozen=True, slots=True)
class SourceNotInEntry:
    paragraph: int
    source: Cite


@dataclass(frozen=True, slots=True)
class ParagraphWithoutSource:
    paragraph: int


SceneRejection = Union[SceneNotAllowed, InvalidOutput, InputRefused, OutcomeUnknown, RequestExceedsFrame,
                       SceneResultExceedsFrame, QuoteNotInRecord, SourceNotInEntry, ParagraphWithoutSource,
                       Incomplete, NotRecordable]


def scene_rejection_to_json(reason: SceneRejection) -> dict:
    match reason:
        case SceneNotAllowed(why):
            return {"kind": "not_allowed", "reason": why}
        case InvalidOutput():
            return {"kind": "invalid_output"}
        case InputRefused(kind):
            return {"kind": "input_refused", "input_kind": kind}
        case OutcomeUnknown():
            return {"kind": "outcome_unknown"}
        case RequestExceedsFrame():
            return {"kind": "request_exceeds_frame"}
        case SceneResultExceedsFrame():
            return {"kind": "result_exceeds_frame"}
        case QuoteNotInRecord(paragraph, source):
            return {"kind": "quote_not_in_record", "paragraph": paragraph, "source": source.to_json()}
        case SourceNotInEntry(paragraph, source):
            return {"kind": "source_not_in_entry", "paragraph": paragraph, "source": source.to_json()}
        case ParagraphWithoutSource(paragraph):
            return {"kind": "paragraph_without_source", "paragraph": paragraph}
        case Incomplete():
            return {"kind": "incomplete"}
        case NotRecordable(detail):
            return {"kind": "not_recordable", "detail": detail}


def scene_rejection_of_json(value: Any) -> SceneRejection:
    if not isinstance(value, dict):
        raise LogError("reason must be an object")
    match value.get("kind"):
        case "not_allowed":
            return SceneNotAllowed(_string(exact(value, {"kind", "reason"}, "reason")["reason"], "reason.reason"))
        case "invalid_output":
            exact(value, {"kind"}, "reason")
            return InvalidOutput()
        case "input_refused":
            return InputRefused(_string(exact(value, {"kind", "input_kind"}, "reason")["input_kind"],
                                        "reason.input_kind"))
        case "outcome_unknown":
            exact(value, {"kind"}, "reason")
            return OutcomeUnknown()
        case "request_exceeds_frame":
            exact(value, {"kind"}, "reason")
            return RequestExceedsFrame()
        case "result_exceeds_frame":
            exact(value, {"kind"}, "reason")
            return SceneResultExceedsFrame()
        case "quote_not_in_record":
            fields = exact(value, {"kind", "paragraph", "source"}, "reason")
            return QuoteNotInRecord(index(fields["paragraph"], "reason.paragraph"), Cite.of_json(fields["source"]))
        case "source_not_in_entry":
            fields = exact(value, {"kind", "paragraph", "source"}, "reason")
            return SourceNotInEntry(index(fields["paragraph"], "reason.paragraph"), Cite.of_json(fields["source"]))
        case "paragraph_without_source":
            return ParagraphWithoutSource(index(exact(value, {"kind", "paragraph"}, "reason")["paragraph"],
                                                "reason.paragraph"))
        case "incomplete":
            exact(value, {"kind"}, "reason")
            return Incomplete()
        case "not_recordable":
            return NotRecordable(text(exact(value, {"kind", "detail"}, "reason")["detail"], "reason.detail"))
        case other:
            raise LogError(f"reason.kind {other!r} is not a reason a scene is not written for")


# -- Why a session failed before any scene was asked for (closed). ---------

@dataclass(frozen=True, slots=True)
class NotAllowed:
    request_id: str
    reason: str


@dataclass(frozen=True, slots=True)
class OutlineInvalidOutput:
    request_id: str


@dataclass(frozen=True, slots=True)
class OutlineInputRefused:
    request_id: str
    kind: str


@dataclass(frozen=True, slots=True)
class OutlineOutcomeUnknown:
    request_id: str


@dataclass(frozen=True, slots=True)
class OutlineRequestExceedsFrame:
    request_id: str


@dataclass(frozen=True, slots=True)
class ResultExceedsFrame:
    request_id: str


@dataclass(frozen=True, slots=True)
class NoMaterial:
    pass


@dataclass(frozen=True, slots=True)
class NoEntryPassed:
    pass


Failure = Union[NotAllowed, OutlineInvalidOutput, OutlineInputRefused, OutlineOutcomeUnknown,
                OutlineRequestExceedsFrame, ResultExceedsFrame, NoMaterial, NoEntryPassed]


def failure_to_json(failure: Failure) -> dict:
    match failure:
        case NotAllowed(request_id, reason):
            return {"kind": "not_allowed", "request_id": request_id, "reason": reason}
        case OutlineInvalidOutput(request_id):
            return {"kind": "outline_invalid_output", "request_id": request_id}
        case OutlineInputRefused(request_id, kind):
            return {"kind": "outline_input_refused", "request_id": request_id, "input_kind": kind}
        case OutlineOutcomeUnknown(request_id):
            return {"kind": "outline_outcome_unknown", "request_id": request_id}
        case OutlineRequestExceedsFrame(request_id):
            return {"kind": "outline_request_exceeds_frame", "request_id": request_id}
        case ResultExceedsFrame(request_id):
            return {"kind": "result_exceeds_frame", "request_id": request_id}
        case NoMaterial():
            return {"kind": "no_material"}
        case NoEntryPassed():
            return {"kind": "no_entry_passed"}


def failure_of_json(value: Any) -> Failure:
    if not isinstance(value, dict):
        raise LogError("failure must be an object")

    def request_id(keys: set[str]) -> str:
        return text(exact(value, keys, "failure")["request_id"], "failure.request_id")

    match value.get("kind"):
        case "not_allowed":
            return NotAllowed(request_id({"kind", "request_id", "reason"}), _string(value["reason"], "failure.reason"))
        case "outline_invalid_output":
            return OutlineInvalidOutput(request_id({"kind", "request_id"}))
        case "outline_input_refused":
            return OutlineInputRefused(request_id({"kind", "request_id", "input_kind"}),
                                       _string(value["input_kind"], "failure.input_kind"))
        case "outline_outcome_unknown":
            return OutlineOutcomeUnknown(request_id({"kind", "request_id"}))
        case "outline_request_exceeds_frame":
            return OutlineRequestExceedsFrame(request_id({"kind", "request_id"}))
        case "result_exceeds_frame":
            return ResultExceedsFrame(request_id({"kind", "request_id"}))
        case "no_material":
            exact(value, {"kind"}, "failure")
            return NoMaterial()
        case "no_entry_passed":
            exact(value, {"kind"}, "failure")
            return NoEntryPassed()
        case other:
            raise LogError(f"failure.kind {other!r} is not a reason a session fails for")


# -- Events. -----------------------------------------------------------------

@dataclass(frozen=True, slots=True)
class SessionOpened:
    session_id: str
    action_request_id: str
    scenes: int
    grants: tuple[Grant, ...]
    language: str
    since: float  # where a grant no earlier session read starts (RFC §4.8)
    opened_at: float


@dataclass(frozen=True, slots=True)
class MaterialRead:
    """One delivered read result, kept whole under pages/ by its digest."""
    session_id: str
    request_id: str
    digest: str


@dataclass(frozen=True, slots=True)
class OutlineRequested:
    session_id: str
    request_id: str
    digest: str  # the request body kept under requests/


@dataclass(frozen=True, slots=True)
class EntryRejected:
    session_id: str
    request_id: str
    index: int  # the entry's place in the outline output
    reason: EntryRejection


@dataclass(frozen=True, slots=True)
class Outlined:
    session_id: str
    request_id: str
    entries: tuple[Entry, ...]


@dataclass(frozen=True, slots=True)
class SceneRequested:
    session_id: str
    entry_id: str
    request_id: str
    digest: str  # the request body kept under requests/


@dataclass(frozen=True, slots=True)
class SceneWritten:
    session_id: str
    entry_id: str
    request_id: str
    written_at: float
    title: str
    paragraphs: tuple[Paragraph, ...]


@dataclass(frozen=True, slots=True)
class SceneRejected:
    session_id: str
    entry_id: str
    request_id: str
    reason: SceneRejection


@dataclass(frozen=True, slots=True)
class SessionFailed:
    session_id: str
    reason: Failure


Event = Union[SessionOpened, MaterialRead, OutlineRequested, EntryRejected, Outlined, SceneRequested, SceneWritten,
              SceneRejected, SessionFailed]


def event_to_json(event: Event) -> dict:
    match event:
        case SessionOpened(session_id, action_request_id, scenes, grants, language, since, opened_at):
            return {"event": "session_opened", "session_id": session_id, "action_request_id": action_request_id,
                    "scenes": scenes, "grants": [grant.to_json() for grant in grants], "language": language,
                    "since": since, "opened_at": opened_at}
        case MaterialRead(session_id, request_id, digest):
            return {"event": "material_read", "session_id": session_id, "request_id": request_id, "digest": digest}
        case OutlineRequested(session_id, request_id, digest):
            return {"event": "outline_requested", "session_id": session_id, "request_id": request_id,
                    "digest": digest}
        case EntryRejected(session_id, request_id, at, reason):
            return {"event": "entry_rejected", "session_id": session_id, "request_id": request_id, "index": at,
                    "reason": entry_rejection_to_json(reason)}
        case Outlined(session_id, request_id, entries):
            return {"event": "outlined", "session_id": session_id, "request_id": request_id,
                    "entries": [entry.to_json() for entry in entries]}
        case SceneRequested(session_id, entry_id, request_id, digest):
            return {"event": "scene_requested", "session_id": session_id, "entry_id": entry_id,
                    "request_id": request_id, "digest": digest}
        case SceneWritten(session_id, entry_id, request_id, written_at, title, paragraphs):
            return {"event": "scene_written", "session_id": session_id, "entry_id": entry_id,
                    "request_id": request_id, "written_at": written_at, "title": title,
                    "paragraphs": [paragraph.to_json() for paragraph in paragraphs]}
        case SceneRejected(session_id, entry_id, request_id, reason):
            return {"event": "scene_rejected", "session_id": session_id, "entry_id": entry_id,
                    "request_id": request_id, "reason": scene_rejection_to_json(reason)}
        case SessionFailed(session_id, reason):
            return {"event": "session_failed", "session_id": session_id, "reason": failure_to_json(reason)}


def event_of_json(value: Any) -> Event:
    if not isinstance(value, dict):
        raise LogError("an event must be an object")
    match value.get("event"):
        case "session_opened":
            f = exact(value, {"event", "session_id", "action_request_id", "scenes", "grants", "language", "since",
                              "opened_at"}, "session_opened")
            if not isinstance(f["grants"], list) or not f["grants"]:
                raise LogError("session_opened.grants must be a non-empty array")
            grants = tuple(Grant.of_json(grant) for grant in f["grants"])
            if len({grant.source_id for grant in grants}) != len(grants):
                raise LogError("session_opened.grants names a source twice")
            return SessionOpened(text(f["session_id"], "session_id"),
                                 text(f["action_request_id"], "action_request_id"), count(f["scenes"], "scenes"),
                                 grants, text(f["language"], "language"), number(f["since"], "since"),
                                 number(f["opened_at"], "opened_at"))
        case "material_read":
            f = exact(value, {"event", "session_id", "request_id", "digest"}, "material_read")
            return MaterialRead(text(f["session_id"], "session_id"), text(f["request_id"], "request_id"),
                                text(f["digest"], "digest"))
        case "outline_requested":
            f = exact(value, {"event", "session_id", "request_id", "digest"}, "outline_requested")
            return OutlineRequested(text(f["session_id"], "session_id"), text(f["request_id"], "request_id"),
                                    text(f["digest"], "digest"))
        case "entry_rejected":
            f = exact(value, {"event", "session_id", "request_id", "index", "reason"}, "entry_rejected")
            return EntryRejected(text(f["session_id"], "session_id"), text(f["request_id"], "request_id"),
                                 index(f["index"], "index"), entry_rejection_of_json(f["reason"]))
        case "outlined":
            f = exact(value, {"event", "session_id", "request_id", "entries"}, "outlined")
            if not isinstance(f["entries"], list) or not f["entries"]:
                raise LogError("outlined.entries must be a non-empty array")
            return Outlined(text(f["session_id"], "session_id"), text(f["request_id"], "request_id"),
                            tuple(Entry.of_json(entry) for entry in f["entries"]))
        case "scene_requested":
            f = exact(value, {"event", "session_id", "entry_id", "request_id", "digest"}, "scene_requested")
            return SceneRequested(text(f["session_id"], "session_id"), text(f["entry_id"], "entry_id"),
                                  text(f["request_id"], "request_id"), text(f["digest"], "digest"))
        case "scene_written":
            f = exact(value, {"event", "session_id", "entry_id", "request_id", "written_at", "title",
                              "paragraphs"}, "scene_written")
            if not isinstance(f["paragraphs"], list) or not f["paragraphs"]:
                raise LogError("scene_written.paragraphs must be a non-empty array")
            return SceneWritten(text(f["session_id"], "session_id"), text(f["entry_id"], "entry_id"),
                                text(f["request_id"], "request_id"), number(f["written_at"], "written_at"),
                                text(f["title"], "title"),
                                tuple(Paragraph.of_json(paragraph) for paragraph in f["paragraphs"]))
        case "scene_rejected":
            f = exact(value, {"event", "session_id", "entry_id", "request_id", "reason"}, "scene_rejected")
            return SceneRejected(text(f["session_id"], "session_id"), text(f["entry_id"], "entry_id"),
                                 text(f["request_id"], "request_id"), scene_rejection_of_json(f["reason"]))
        case "session_failed":
            f = exact(value, {"event", "session_id", "reason"}, "session_failed")
            return SessionFailed(text(f["session_id"], "session_id"), failure_of_json(f["reason"]))
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


# -- Sessions (RFC §4.5). "written" and "superseded" are derived. -----------

READING = "reading"
WRITING = "writing"
WRITTEN = "written"
FAILED = "failed"
SUPERSEDED = "superseded"

Outcome = Union[SceneWritten, SceneRejected]


@dataclass(frozen=True, slots=True)
class Session:
    session_id: str
    action_request_id: str
    scenes: int
    grants: tuple[Grant, ...]
    language: str
    since: float
    opened_at: float
    state: str  # reading | writing | written | failed | superseded
    failure: Failure | None
    superseded_by: str | None
    material: tuple[MaterialRead, ...]
    requests: tuple[OutlineRequested, ...]
    rejected: tuple[EntryRejected, ...]
    outlined: Outlined | None
    scene_requests: tuple[SceneRequested, ...]
    outcomes: tuple[Outcome, ...]  # in log order, at most one per entry

    @property
    def entries(self) -> tuple[Entry, ...]:
        return self.outlined.entries if self.outlined is not None else ()

    @property
    def written(self) -> tuple[SceneWritten, ...]:
        return tuple(outcome for outcome in self.outcomes if isinstance(outcome, SceneWritten))

    @property
    def rejected_scenes(self) -> tuple[SceneRejected, ...]:
        return tuple(outcome for outcome in self.outcomes if isinstance(outcome, SceneRejected))

    def waiting(self) -> tuple[SceneRequested, ...]:
        """The scene requests that have no result yet."""
        done = {outcome.entry_id for outcome in self.outcomes}
        return tuple(request for request in self.scene_requests if request.entry_id not in done)


def fold(events: list[Event]) -> list[Session]:
    """Sessions in the order they were opened. History that contradicts
    itself (an event for a session that cannot take it) is a LogError: the
    package wrote it, so a reader that skipped it would hide a fault."""
    sessions: dict[str, dict] = {}
    order: list[str] = []
    request_ids: set[str] = set()

    def session(session_id: str, label: str, state: str) -> dict:
        if session_id not in sessions:
            raise LogError(f"{label} names session {session_id}, which was never opened")
        current = sessions[session_id]
        if current["state"] != state:
            raise LogError(f"{label} for session {session_id}, which is {current['state']}")
        return current

    def fresh(request_id: str, label: str) -> None:
        if request_id in request_ids:
            raise LogError(f"{label} {request_id} was written twice")
        request_ids.add(request_id)

    def entry_of(current: dict, entry_id: str, label: str) -> None:
        if all(entry.entry_id != entry_id for entry in current["outlined"].entries):
            raise LogError(f"{label} names entry {entry_id}, which session {current['session_id']} did not outline")
        if any(outcome.entry_id == entry_id for outcome in current["outcomes"]):
            raise LogError(f"{label} for entry {entry_id}, which already has its result")

    for event in events:
        match event:
            case SessionOpened(session_id=session_id):
                if session_id in sessions:
                    raise LogError(f"session {session_id} was opened twice")
                for other in sessions.values():
                    if other["state"] == READING:
                        other["state"] = SUPERSEDED
                        other["superseded_by"] = session_id
                sessions[session_id] = {
                    "session_id": session_id, "action_request_id": event.action_request_id, "scenes": event.scenes,
                    "grants": event.grants, "language": event.language, "since": event.since,
                    "opened_at": event.opened_at, "state": READING, "failure": None, "superseded_by": None,
                    "material": [], "requests": [], "rejected": [], "outlined": None, "scene_requests": [],
                    "outcomes": []}
                order.append(session_id)
            case MaterialRead(session_id=session_id):
                session(session_id, "material_read", READING)["material"].append(event)
            case OutlineRequested(session_id=session_id, request_id=request_id):
                current = session(session_id, "outline_requested", READING)
                fresh(request_id, "outline request")
                current["requests"].append(event)
            case EntryRejected(session_id=session_id, request_id=request_id):
                current = session(session_id, "entry_rejected", READING)
                if not current["requests"] or current["requests"][-1].request_id != request_id:
                    raise LogError("entry_rejected does not name the latest outline request")
                current["rejected"].append(event)
            case Outlined(session_id=session_id, request_id=request_id, entries=entries):
                current = session(session_id, "outlined", READING)
                if not current["requests"] or current["requests"][-1].request_id != request_id:
                    raise LogError("outlined does not name the latest outline request")
                if len(entries) > current["scenes"]:
                    raise LogError(f"outlined holds more entries than the {current['scenes']} scenes asked for")
                if len({entry.entry_id for entry in entries}) != len(entries):
                    raise LogError("outlined names an entry twice")
                current["outlined"] = event
                current["state"] = WRITING
            case SceneRequested(session_id=session_id, entry_id=entry_id, request_id=request_id):
                current = session(session_id, "scene_requested", WRITING)
                entry_of(current, entry_id, "scene_requested")
                if any(request.entry_id == entry_id for request in current["scene_requests"]):
                    raise LogError(f"entry {entry_id} was asked for twice")
                fresh(request_id, "scene request")
                current["scene_requests"].append(event)
            case SceneWritten(session_id=session_id, entry_id=entry_id, request_id=request_id) \
                    | SceneRejected(session_id=session_id, entry_id=entry_id, request_id=request_id):
                label = "scene_written" if isinstance(event, SceneWritten) else "scene_rejected"
                current = session(session_id, label, WRITING)
                entry_of(current, entry_id, label)
                asked = next((r for r in current["scene_requests"] if r.entry_id == entry_id), None)
                # A scene whose request never fit the frame is rejected with
                # no request written; any other result follows its request.
                unasked = isinstance(event, SceneRejected) and isinstance(event.reason, RequestExceedsFrame)
                if (asked is None) != unasked or (asked is not None and asked.request_id != request_id):
                    raise LogError(f"{label} for entry {entry_id} does not follow its request")
                current["outcomes"].append(event)
                if len(current["outcomes"]) == len(current["outlined"].entries):
                    current["state"] = WRITTEN
            case SessionFailed(session_id=session_id, reason=reason):
                current = session(session_id, "session_failed", READING)
                current["state"] = FAILED
                current["failure"] = reason
    return [Session(**{key: tuple(value) if isinstance(value, list) else value
                       for key, value in sessions[session_id].items()}) for session_id in order]
