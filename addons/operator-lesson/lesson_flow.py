"""What the operator lesson lists, and what it does with each result (RFC
operator-lesson §4.1, §4.5, §4.8).

The listing is a function of the log and the bodies kept beside it, so a
restarted worker lists the same requests with the same bodies. Every write
happens while a result is consumed, and the result is answered accepted only
after it: a package that dies first lists the request again and the host
delivers the same retained result.

A session reads its grants one request at a time, from where the last
outlined session stopped, or from the binding's since. When everything is
read it asks the outline output once; a refusal for size is answered with a
smaller request until nothing is left to drop. Each entry that passes gets
one scene request, written with the entry, carrying only the records that
entry cites. A scene that fails is not asked for again.

Only a summary of each read stays in memory (records.Pages).
"""
from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import lesson_log as l
import records
from records import InvalidBinding, InvalidResult, digest, grants_of_binding, material  # noqa: F401

OUTLINE = "outline"
SCENE = "scene"


@dataclass(frozen=True, slots=True)
class Prompts:
    outline: str
    scene: str


def session_id_of(action_request_id: str) -> str:
    return "s-" + hashlib.sha256(action_request_id.encode("utf-8")).hexdigest()[:16]


def language_of_binding(binding: dict) -> str:
    language = binding.get("language")
    if not isinstance(language, str) or not language.strip():
        raise InvalidBinding("binding.language must name the language scenes are written in")
    return language


def since_of_binding(binding: dict) -> float:
    since = binding.get("since")
    problem = InvalidBinding("binding.since must be the Unix time, in seconds, the first lesson reads from")
    if isinstance(since, bool) or not isinstance(since, (int, float)):
        raise problem
    try:
        seconds = float(since)
    except OverflowError as error:
        raise problem from error
    if not math.isfinite(seconds) or seconds < 0:
        raise problem
    return seconds


def _cite(value: dict) -> l.Cite:
    return l.Cite(value["kind"], value["source_id"], value["pin"])


def _blank(*values: str) -> bool:
    return any(not value.strip() for value in values)


def _entry_rejected(session_id: str, request_id: str, at: int, reason: l.EntryRejection) -> l.EntryRejected:
    """The rejection as the log can keep it. A reason that carries what the
    model wrote, such as a pin UTF-8 cannot hold, would otherwise refuse the
    whole write and leave the request listed for good."""
    event = l.EntryRejected(session_id, request_id, at, reason)
    problem = l.unreadable(event)
    return event if problem is None else l.EntryRejected(session_id, request_id, at, l.NotRecordable(problem))


def _scene_rejected(session_id: str, entry_id: str, request_id: str, reason: l.SceneRejection) -> l.SceneRejected:
    """As _entry_rejected, for a scene."""
    event = l.SceneRejected(session_id, entry_id, request_id, reason)
    problem = l.unreadable(event)
    return event if problem is None else l.SceneRejected(session_id, entry_id, request_id,
                                                         l.NotRecordable(problem))


def _payload(body: dict) -> dict:
    return json.loads(body["messages"][0]["text"])


class Flow:
    def __init__(self, state: Path, prompts: Prompts, fits: Callable[[dict], bool]):
        """[fits] says whether a listing that holds this one request fits the
        package's reply frame. The frame is a transport limit; a request that
        does not fit could never be listed."""
        self.log = l.Log(state)
        self.pages = l.Blobs(state, "pages")
        self.requests = l.Blobs(state, "requests")
        self.prompts = prompts
        self.fits = fits
        self._reads = records.Pages(self.pages)
        # The fold is redone only when the log grew.
        self._folded: tuple[int, list[l.Session]] = (-1, [])

    def sessions(self) -> list[l.Session]:
        events = self.log.read()
        if self._folded[0] != len(events):
            self._folded = (len(events), l.fold(events))
        return self._folded[1]

    # -- compose --------------------------------------------------------------

    def compose(self, action_request_id: str, scenes: int, binding: dict, opened_at: float) -> str:
        """Opens the session for one compose action; the same action again
        names the same session and writes nothing."""
        grants = grants_of_binding(binding)
        language = language_of_binding(binding)
        since = since_of_binding(binding)
        session_id = session_id_of(action_request_id)
        if all(session.session_id != session_id for session in self.sessions()):
            self.log.append([l.SessionOpened(session_id, action_request_id, scenes, grants, language, since,
                                             opened_at)])
        return session_id

    # -- listing --------------------------------------------------------------

    def _session_reads(self, session: l.Session) -> list[dict]:
        """The session's reads, each with the summary of its result."""
        return self._reads.summaries([event.digest for event in session.material], session.grants)

    def _next_read(self, session: l.Session, sessions: list[l.Session]) -> dict | None:
        def start(grant: l.Grant) -> dict:
            # The cursor moves with a session that was outlined (RFC §4.8).
            # Material of a session that failed or was superseded while
            # reading is read again.
            position = next(i for i, other in enumerate(sessions) if other.session_id == session.session_id)
            after = records.last_cursor(grant, [(other.outlined is not None, self._session_reads(other))
                                                for other in sessions[:position]])
            return {"after": after} if after is not None else {"after": None, "since": session.since}

        return records.next_read(f"{session.session_id}-read-{len(session.material)}", session.grants,
                                 self._session_reads(session), start)

    def listing(self) -> list[dict]:
        """Sessions in the order opened: a reading session's outline request,
        or its next read; a writing session's scene requests still waiting."""
        sessions = self.sessions()
        out: list[dict] = []
        for session in sessions:
            if session.state == l.READING:
                if session.requests:
                    out.append(self.requests.read(session.requests[-1].digest))
                else:
                    request = self._next_read(session, sessions)
                    if request is not None:
                        out.append(request)
            elif session.state == l.WRITING:
                out += [self.requests.read(request.digest) for request in session.waiting()]
        return out

    # -- the outline request --------------------------------------------------

    @staticmethod
    def _earlier(session: l.Session, sessions: list[l.Session]) -> list[dict]:
        """The scenes of earlier lessons: their titles and the pins they cite."""
        return [{"title": scene.title,
                 "sources": [{"kind": s.kind, "source_id": s.source_id, "pin": s.pin}
                             for paragraph in scene.paragraphs for s in paragraph.sources]}
                for other in sessions if other.session_id != session.session_id for scene in other.written]

    def _outline_body(self, session: l.Session, *, earlier: list[dict], records_in: list[dict]) -> dict:
        payload = {"language": session.language, "scenes": session.scenes, "material": records_in,
                   "earlier": earlier}
        request_id = f"{session.session_id}-{OUTLINE}-{len(session.requests)}"
        return {"kind": "exact_output", "request_id": request_id, "output": OUTLINE,
                "system": self.prompts.outline,
                "messages": [{"role": "user", "text": json.dumps(payload, ensure_ascii=False, sort_keys=True)}]}

    def _material(self, session: l.Session, earlier: list[dict]) -> list[dict]:
        """The material of a session that has read everything, in the order
        read, with the oldest left out once the rest no longer fits one
        outline request. Reads are taken again from disk from the last one
        back, so older reads are not loaded at all. The fit is checked each
        time the material doubles."""
        out: list[dict] = []
        checked = 0
        grants = {grant.source_id: grant for grant in session.grants}
        for read in reversed(self._session_reads(session)):
            out = material(self._reads.whole(read), grants) + out
            if out and len(out) >= 2 * checked:
                checked = len(out)
                if not self.fits(self._outline_body(session, earlier=earlier, records_in=out)):
                    break
        return out

    def _request_outline(self, session: l.Session, *, earlier: list[dict],
                         records_in: list[dict]) -> l.Event:
        """Writes the body of the outline request and returns the event that
        names it. While the request does not fit the frame it is cut as
        after an input refusal: first the earlier lessons, then the material
        to its newer half."""
        while True:
            body = self._outline_body(session, earlier=earlier, records_in=records_in)
            if self.fits(body):
                key = digest(body)
                self.requests.write(key, body)
                return l.OutlineRequested(session.session_id, body["request_id"], key)
            if earlier:
                earlier = []
            elif len(records_in) > 1:
                records_in = records_in[len(records_in) // 2:]
            else:
                return l.SessionFailed(session.session_id, l.OutlineRequestExceedsFrame(body["request_id"]))

    # -- consuming results ----------------------------------------------------

    def deliver(self, request_id: str, result: Any, at: float) -> bool:
        """Consumes one delivered result at time [at]. False when no request
        of this package's current listing has that id, as for a superseded
        session."""
        if not isinstance(result, dict) or not isinstance(result.get("status"), str):
            raise InvalidResult("a result must be an object with a status")
        sessions = self.sessions()
        listed = next((r for r in self.listing() if r["request_id"] == request_id), None)
        if listed is None:
            return False
        for session in sessions:
            if session.state == l.WRITING:
                asked = next((r for r in session.waiting() if r.request_id == request_id), None)
                if asked is not None:
                    self._deliver_scene(session, asked, listed, result, at)
                    return True
            elif session.state == l.READING:
                if session.requests and session.requests[-1].request_id == request_id:
                    self._deliver_outline(session, listed, result)
                    return True
                if not session.requests and listed["kind"] != "exact_output" \
                        and request_id == f"{session.session_id}-read-{len(session.material)}":
                    self._deliver_read(session, sessions, listed, result)
                    return True
        raise l.LogError(f"{request_id} is listed and no session waits for it")

    def _deliver_read(self, session: l.Session, sessions: list[l.Session], request: dict, result: dict) -> None:
        status = result["status"]
        entry = {"request": request, "result": result}
        key = digest(entry)
        read = l.MaterialRead(session.session_id, request["request_id"], key)
        # A file a commit deleted is not a file at that commit. Its refusal is
        # kept as read and skipped. Any other refusal ends the session.
        if status == "not_allowed" and request["kind"] != "read_file":
            self.pages.write(key, entry)
            self.log.append([read, l.SessionFailed(session.session_id,
                                                   l.NotAllowed(request["request_id"], str(result.get("reason"))))])
            return
        expected = {"read_records": {"records", "result_exceeds_frame"},
                    "read_file": {"file", "result_exceeds_frame", "not_allowed"},
                    "read_result": {"result_chunk"}}[request["kind"]]
        if status not in expected:
            raise InvalidResult(f"{request['kind']} cannot end as {status}")
        self.pages.write(key, entry)
        after = next(s for s in l.fold(self.log.read() + [read]) if s.session_id == session.session_id)
        if self._next_read(after, sessions) is not None:
            self.log.append([read])
            return
        earlier = self._earlier(session, sessions)
        records_in = self._material(after, earlier)
        if not records_in:
            self.log.append([read, l.SessionFailed(session.session_id, l.NoMaterial())])
            return
        self.log.append([read, self._request_outline(after, earlier=earlier, records_in=records_in)])

    def _deliver_outline(self, session: l.Session, body: dict, result: dict) -> None:
        request_id = body["request_id"]
        failure: l.Failure
        match result["status"]:
            case "answered":
                self._deliver_entries(session, body, result)
                return
            case "input_refused":
                self._reduce(session, body, str(result.get("kind")))
                return
            case "invalid_output" | "output_limit_reached":
                failure = l.OutlineInvalidOutput(request_id)
            case "outcome_unknown":
                failure = l.OutlineOutcomeUnknown(request_id)
            case "not_allowed":
                failure = l.NotAllowed(request_id, str(result.get("reason")))
            case "request_id_reused":
                failure = l.NotAllowed(request_id, "request_id_reused")
            case "result_exceeds_frame":
                failure = l.ResultExceedsFrame(request_id)
            case other:
                raise InvalidResult(f"an outline request cannot end as {other}")
        self.log.append([l.SessionFailed(session.session_id, failure)])

    def _reduce(self, session: l.Session, body: dict, kind: str) -> None:
        """The provider refused the request for its size: leave out the
        earlier lessons, then send the newer half of the material, each
        request smaller than the one before (RFC §4.5)."""
        payload = _payload(body)
        records_in = payload["material"]
        if payload["earlier"]:
            requested = self._request_outline(session, earlier=[], records_in=records_in)
        elif len(records_in) > 1:
            requested = self._request_outline(session, earlier=[], records_in=records_in[len(records_in) // 2:])
        else:
            requested = l.SessionFailed(session.session_id, l.OutlineInputRefused(body["request_id"], kind))
        self.log.append([requested])

    def _check_entry(self, drafted: dict, input_material: list[dict], passed: list[l.Entry],
                     scenes: int) -> l.Entry | l.EntryRejection:
        """The entry as the log keeps it, or why it is dropped."""
        points = drafted["points"]
        cited = [_cite(source) for source in drafted["sources"]]
        if not points or not cited or _blank(drafted["entry_id"], drafted["title"], *points):
            return l.Incomplete()
        for source, cite in zip(drafted["sources"], cited):
            if records.cited_record(source, input_material) is None:
                return l.SourceNotRead(cite)
        if any(entry.entry_id == drafted["entry_id"] for entry in passed):
            return l.DuplicateEntryId()
        if len(passed) == scenes:
            return l.BeyondRequestedScenes()
        return l.Entry(drafted["entry_id"], drafted["title"], tuple(points), tuple(cited))

    def _deliver_entries(self, session: l.Session, body: dict, result: dict) -> None:
        output = result.get("output")
        if not isinstance(output, dict) or not isinstance(output.get("entries"), list):
            raise InvalidResult("an answered outline request carries output.entries")
        input_material = _payload(body)["material"]
        request_id = body["request_id"]
        rejected: list[l.Event] = []
        passed: list[l.Entry] = []
        for at, drafted in enumerate(output["entries"]):
            try:
                checked = self._check_entry(drafted, input_material, passed, session.scenes)
            except (KeyError, TypeError, AttributeError) as error:
                raise InvalidResult(f"entry {at} does not have the outline schema's shape: {error}") from error
            if isinstance(checked, l.Entry):
                # The log's own decoder decides what it can keep; an entry
                # it would refuse is dropped alone, not the whole outline.
                problem = l.unreadable(l.Outlined(session.session_id, request_id, (checked,)))
                if problem is None:
                    passed.append(checked)
                    continue
                checked = l.NotRecordable(problem)
            rejected.append(_entry_rejected(session.session_id, request_id, at, checked))
        if not passed:
            self.log.append(rejected + [l.SessionFailed(session.session_id, l.NoEntryPassed())])
            return
        asked: list[l.Event] = []
        for position, entry in enumerate(passed, start=1):
            scene_request_id = f"{session.session_id}-{SCENE}-{position}"
            cites = {(source.kind, source.source_id, source.pin) for source in entry.sources}
            payload = {"language": session.language, "title": entry.title, "points": list(entry.points),
                       "material": [record for record in input_material
                                    if (record["kind"], record["source_id"], record["pin"]) in cites]}
            scene_body = {"kind": "exact_output", "request_id": scene_request_id, "output": SCENE,
                          "system": self.prompts.scene,
                          "messages": [{"role": "user",
                                        "text": json.dumps(payload, ensure_ascii=False, sort_keys=True)}]}
            if self.fits(scene_body):
                key = digest(scene_body)
                self.requests.write(key, scene_body)
                asked.append(l.SceneRequested(session.session_id, entry.entry_id, scene_request_id, key))
            else:
                asked.append(l.SceneRejected(session.session_id, entry.entry_id, scene_request_id,
                                             l.RequestExceedsFrame()))
        self.log.append(rejected + [l.Outlined(session.session_id, request_id, tuple(passed))] + asked)

    def _check_scene(self, session: l.Session, entry: l.Entry, request_id: str, output: dict,
                     input_material: list[dict], at: float) -> l.SceneWritten | l.SceneRejection:
        """The scene as the log keeps it, or why it is not written."""
        title, drafted = output["title"], output["paragraphs"]
        if not drafted or _blank(title, *(paragraph["text"] for paragraph in drafted)):
            return l.Incomplete()
        allowed = set(entry.sources)
        paragraphs: list[l.Paragraph] = []
        for position, paragraph in enumerate(drafted):
            if not paragraph["sources"]:
                return l.ParagraphWithoutSource(position)
            sources: list[l.Source] = []
            for cited in paragraph["sources"]:
                cite = _cite(cited)
                record = records.cited_record(cited, input_material) if cite in allowed else None
                if record is None:
                    return l.SourceNotInEntry(position, cite)
                if not cited["quote"].strip() or not records.holds_quote(record, cited["quote"]):
                    return l.QuoteNotInRecord(position, cite)
                sources.append(l.Source(cite.kind, cite.source_id, cite.pin, cited["quote"], record["sha256"]))
            paragraphs.append(l.Paragraph(paragraph["text"], tuple(sources)))
        return l.SceneWritten(session.session_id, entry.entry_id, request_id, at, title, tuple(paragraphs))

    def _deliver_scene(self, session: l.Session, asked: l.SceneRequested, body: dict, result: dict,
                       at: float) -> None:
        outcome: l.SceneWritten | l.SceneRejection
        match result["status"]:
            case "answered":
                output = result.get("output")
                if not isinstance(output, dict) or not isinstance(output.get("paragraphs"), list) \
                        or not isinstance(output.get("title"), str):
                    raise InvalidResult("an answered scene request carries output.title and output.paragraphs")
                entry = next(entry for entry in session.entries if entry.entry_id == asked.entry_id)
                try:
                    outcome = self._check_scene(session, entry, asked.request_id, output,
                                                _payload(body)["material"], at)
                except (KeyError, TypeError, AttributeError) as error:
                    raise InvalidResult(f"the scene does not have the scene schema's shape: {error}") from error
                if isinstance(outcome, l.SceneWritten):
                    problem = l.unreadable(outcome)
                    if problem is not None:
                        outcome = l.NotRecordable(problem)
            case "input_refused":
                outcome = l.InputRefused(str(result.get("kind")))
            case "invalid_output" | "output_limit_reached":
                outcome = l.InvalidOutput()
            case "outcome_unknown":
                outcome = l.OutcomeUnknown()
            case "not_allowed":
                outcome = l.SceneNotAllowed(str(result.get("reason")))
            case "request_id_reused":
                outcome = l.SceneNotAllowed("request_id_reused")
            case "result_exceeds_frame":
                outcome = l.SceneResultExceedsFrame()
            case other:
                raise InvalidResult(f"a scene request cannot end as {other}")
        if isinstance(outcome, l.SceneWritten):
            self.log.append([outcome])
        else:
            self.log.append([_scene_rejected(session.session_id, asked.entry_id, asked.request_id, outcome)])
