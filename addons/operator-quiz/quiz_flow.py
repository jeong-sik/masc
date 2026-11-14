"""What the operator quiz lists, and what it does with each result (RFC
operator-quiz §4.4, §4.9, §5, §7).

The listing is a function of the log and the bodies kept beside it, so a
restarted worker lists the same requests with the same bodies. Every write
happens while a result is consumed, and the result is answered accepted only
after it: a package that dies first lists the request again and the host
delivers the same retained result.

A session reads its grants one request at a time, from where the last asked
session stopped. A read result too large for the frame comes back in pieces
(read_result) and is put together and checked against its digest before it
counts. When everything is read, the session asks the author output once; a
refusal for size is answered with a smaller request until nothing is left to
drop.

A written answer is graded by the grade output (§6.2). Its request is written
with the answer, and a final failure is asked again only at the next compose,
never in reply to the failure itself.

Only a summary of each read stays in memory. Record bodies and file contents
are read again from disk when the author request is written, newest first,
and only as far as one request can hold (#44537).
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import quiz_grading as g
import quiz_log as q
import records
from records import (  # noqa: F401  -- the names this package's modules and tests read from here
    InvalidBinding, InvalidResult, digest, grants_of_binding, material)

AUTHOR = "author"
GRADE = "grade"
SCOPE_ALL = "all"
SCOPE_OPEN_DEBT = "open_debt_only"
CHOICES_ONLY = {"kind": "choices_only"}
WRITTEN = {"kind": "allowed", "hint": None}
TEXT = "text"  # the author schema's mode for a question answered in words


class DisputeRefused(ValueError):
    """A dispute this package cannot take; nothing was written."""


@dataclass(frozen=True, slots=True)
class Prompts:
    author: str
    grade: str


def session_id_of(action_request_id: str) -> str:
    return "s-" + hashlib.sha256(action_request_id.encode("utf-8")).hexdigest()[:16]


def language_of_binding(binding: dict) -> str:
    language = binding.get("language")
    if not isinstance(language, str) or not language.strip():
        raise InvalidBinding("binding.language must name the language questions are written in")
    return language


# -- Drafts (RFC §4.9 Compose, step 3). -------------------------------------

def check_draft(draft: dict, input_material: list[dict],
                known: dict[str, g.Item]) -> tuple[list[q.Source], str | None] | str:
    """The checked sources and the item a draft asks again, or why it is dropped."""
    choices = draft["choices"]
    ids = [choice["choice_id"] for choice in choices]
    if len(set(ids)) != len(ids):
        return "two choices share an id"
    if any(not text.strip() for text in [draft["topic"], draft["header"], draft["prompt"], *ids,
                                          *(choice["label"] for choice in choices)]):
        return "a blank topic, header, prompt, choice id or choice label"
    key, rubric = draft["key"], draft["rubric"]
    if draft["mode"] == TEXT:
        # Answered in words: no choices to show, and the points a correct
        # answer must state in place of a key (§6.2).
        if choices or key:
            return "a text question has no choices and no key"
        if not rubric or any(not point.strip() for point in rubric):
            return "a text question names the points its answer must state"
    else:
        if len(choices) < 2:
            return "a choice question offers at least two choices"
        if rubric:
            return "a choice question has a key, not a rubric"
        if not key:
            return "a choice question names its key"
        if not set(key) <= set(ids):
            return "a key choice id is not one of its choices"
        if len(set(key)) != len(key):
            return "the key names a choice twice"
        if draft["mode"] == "single" and len(key) != 1:
            return "a single question has exactly one key"
    reask = draft["reask_of"][0] if draft["reask_of"] else None
    if reask is not None and reask not in known:
        return f"reask_of names {reask}, which is not an item"
    earlier = known[reask].sources if reask is not None else ()
    sources: list[q.Source] = []
    for cited in draft["sources"]:
        if not cited["quote"].strip():
            return f"the quote cited from {cited['pin']} is only whitespace"
        record = records.cited_record(cited, input_material)
        if record is not None:
            if not records.holds_quote(record, cited["quote"]):
                return f"the quote is not in {cited['pin']}"
            sources.append(q.Source(cited["kind"], cited["source_id"], cited["pin"], cited["quote"], record["sha256"]))
            continue
        prior = next((s for s in earlier if (s.kind, s.source_id, s.pin, s.quote)
                      == (cited["kind"], cited["source_id"], cited["pin"], cited["quote"])), None)
        if prior is None:
            return f"{cited['pin']} is not a record this session read"
        sources.append(prior)
    return sources, reask


class Flow:
    def __init__(self, state: Path, prompts: Prompts, fits: Callable[[dict], bool]):
        """[fits] says whether a listing that holds this one request fits the
        package's reply frame. The frame is a transport limit; an author
        request that does not fit could never be listed."""
        self.log = q.Log(state)
        self.pages = q.Blobs(state, "pages")
        self.requests = q.Blobs(state, "requests")
        self.prompts = prompts
        self.fits = fits
        # The fold is redone only when the log grew.
        self._reads = records.Pages(self.pages)
        self._folded: tuple[int, list[q.Session]] = (-1, [])

    def sessions(self) -> list[q.Session]:
        events = self.log.read()
        if self._folded[0] != len(events):
            self._folded = (len(events), q.fold(events))
        return self._folded[1]

    # -- compose --------------------------------------------------------------

    def compose(self, action_request_id: str, questions: int, binding: dict, opened_at: float) -> str:
        """Opens the session for one compose action; the same action again
        names the same session and writes nothing."""
        grants = grants_of_binding(binding)
        language = language_of_binding(binding)
        session_id = session_id_of(action_request_id)
        sessions = self.sessions()
        if all(session.session_id != session_id for session in sessions):
            # A grade that ended in a final failure is asked again here, once
            # per compose (§6.2), and so is a written answer that has no
            # grading at all: one answered before this package graded, or
            # whose request was lost with the end of a torn write.
            again = [event for session in sessions if session.state == "answered" and session.answer is not None
                     for posed, response in zip(session.posed, _responses(session.answer, session.posed))
                     if _needs_grade(session.grading_of(posed.question_id), response)
                     for event in self._request_grade(session, posed, response)]
            self.log.append([q.SessionOpened(session_id, action_request_id, questions, grants, language, opened_at),
                             *again])
        return session_id

    # -- listing --------------------------------------------------------------

    def _session_reads(self, session: q.Session) -> list[dict]:
        """The session's reads, each with the summary of its result."""
        return self._reads.summaries([event.digest for event in session.material], session.grants)

    def _material(self, session: q.Session, sessions: list[q.Session]) -> list[dict]:
        """The material of a session that has read everything, in the order
        read, with the oldest left out once the rest no longer fits one
        author request. Reads are taken again from disk from the last one
        back; the request keeps only the newer part that fits (§7), so older
        reads are not loaded at all, and what is held at once stays near one
        frame. The fit is checked each time the material doubles, so the
        request is encoded a few times rather than once per read."""
        out: list[dict] = []
        checked = 0
        grants = {grant.source_id: grant for grant in session.grants}
        for read in reversed(self._session_reads(session)):
            out = material(self._reads.whole(read), grants) + out
            if out and len(out) >= 2 * checked:
                checked = len(out)
                if not self.fits(self._author_body(session, sessions, scope=SCOPE_ALL, records=out)):
                    break
        return out

    def _start_cursor(self, grant: q.Grant, sessions: list[q.Session], session_id: str) -> str | None:
        """Where the last earlier session that reached asked stopped reading
        this grant. A session reached asked when it posed questions, even if
        the host later refused its ask, so the start of a session never moves.
        Material of a session that failed before asking is read again.

        A cursor the host refused is skipped (records.last_cursor)."""
        position = next(i for i, session in enumerate(sessions) if session.session_id == session_id)
        return records.last_cursor(grant, [(bool(session.posed), self._session_reads(session))
                                           for session in sessions[:position]])

    def _next_read(self, session: q.Session, sessions: list[q.Session]) -> dict | None:
        def start(grant: q.Grant) -> dict:
            after = self._start_cursor(grant, sessions, session.session_id)
            if after is not None:
                return {"after": after}
            # No session has asked yet, so nothing marks where the last one
            # stopped: read what was made since the quiz began, not the
            # workspace's whole history (#44537).
            return {"after": None, "since": sessions[0].opened_at}

        return records.next_read(f"{session.session_id}-read-{len(session.material)}", session.grants,
                                 self._session_reads(session), start)

    @staticmethod
    def _ask(session: q.Session) -> dict:
        return {"kind": "ask", "request_id": session.ask_id, "questions": [posed.question for posed in session.posed]}

    def listing(self) -> list[dict]:
        """The writing session's request first, then every open ask. An ask
        waits on the operator with no end, so nothing waits behind one."""
        sessions = self.sessions()
        out = []
        for session in sessions:
            if session.state == "writing":
                if session.requests:
                    out.append(self.requests.read(session.requests[-1].digest))
                else:
                    request = self._next_read(session, sessions)
                    if request is not None:
                        out.append(request)
        out += [self.requests.read(outstanding.digest) for session in sessions if session.state == "answered"
                for posed in session.posed
                if (outstanding := session.outstanding_grade(posed.question_id)) is not None]
        out += [self._ask(session) for session in sessions if session.state == "asked"]
        return out

    # -- the author request -------------------------------------------------

    def _author_body(self, session: q.Session, sessions: list[q.Session], *, scope: str,
                     records: list[dict]) -> dict:
        history = [item for item in g.items([s for s in sessions if s.session_id != session.session_id])
                   if scope == SCOPE_ALL or item.open_debt]
        payload = {"language": session.language, "questions": session.questions, "history_scope": scope,
                   "material": records,
                   "items": [{"item_id": item.item_id, "topic": item.topic, "latest": item.latest,
                              "correct_streak": item.correct_streak,
                              "attempts": [{"answered_at": a.answered_at, "verdict": a.verdict} for a in item.attempts],
                              "sources": [source.to_json() for source in item.sources]} for item in history]}
        request_id = f"{session.session_id}-{AUTHOR}-{len(session.requests)}"
        return {"kind": "exact_output", "request_id": request_id, "output": AUTHOR, "system": self.prompts.author,
                "messages": [{"role": "user", "text": json.dumps(payload, ensure_ascii=False, sort_keys=True)}]}

    def _request_author(self, session: q.Session, sessions: list[q.Session], *, scope: str,
                        records: list[dict]) -> tuple[q.Event, ...]:
        """Writes the body of the author request and returns the event that
        names it. While the request does not fit the frame, the material is
        cut to its newer half, as after an input refusal (§7)."""
        while True:
            body = self._author_body(session, sessions, scope=scope, records=records)
            if self.fits(body):
                key = digest(body)
                self.requests.write(key, body)
                return (q.ExactRequested(session.session_id, body["request_id"], AUTHOR, key),
                        q.AuthorContextRecorded(session.session_id, body["request_id"], scope))
            if len(records) == 1:
                return (q.SessionFailed(session.session_id, q.AuthorRequestExceedsFrame(body["request_id"])),)
            records = records[len(records) // 2:]

    @staticmethod
    def _payload(body: dict) -> dict:
        return json.loads(body["messages"][0]["text"])

    # -- the grade request --------------------------------------------------

    def dispute(self, action_request_id: str, ask_id: str, question_id: str, note: str) -> str:
        """The operator's words about one answered question (§6.4): a
        Disputed and a new grade request with the note, the verdict it
        disputes and the bytes this package read for each source. The same
        action again writes nothing and names the same request."""
        sessions = self.sessions()
        for session in sessions:
            for index, event in enumerate(session.grading):
                if isinstance(event, q.Disputed) and event.action_request_id == action_request_id:
                    following = session.grading[index + 1]
                    if not isinstance(following, q.GradeRequested):
                        raise q.LogError(f"dispute {action_request_id} has no grade request after it")
                    return following.request_id
        if not note.strip():
            raise DisputeRefused("a dispute says what is wrong with the grade")
        not_answered = f"{ask_id}/{question_id} is not an answered question of this package"
        # An ask belongs to one session (the log refuses a second), so the
        # first session with this ask is the only one.
        session = next((s for s in sessions if s.ask_id == ask_id), None)
        if session is None:
            raise DisputeRefused(not_answered)
        match session.dispute_standing(question_id):
            case q.NotAnswered():
                raise DisputeRefused(not_answered)
            case q.GradeWaiting():
                raise DisputeRefused(f"a grade request for {ask_id}/{question_id} is still waiting")
            case q.Disputable(posed=posed, answer=answer):
                pass
        response = dict(zip((p.question_id for p in session.posed), _responses(answer, session.posed)))[question_id]
        prior = g.verdict(posed, response, session.judgments_of(question_id))
        texts = self._record_texts(sessions, posed.sources)
        records = [texts[(s.kind, s.source_id, s.pin)] for s in posed.sources if (s.kind, s.source_id, s.pin) in texts]
        disputed = q.Disputed(ask_id, question_id, note, action_request_id)
        requested = self._request_grade(session, posed, response,
                                        dispute={"note": note, "prior_verdict": prior, "records": records})
        self.log.append([disputed, *requested])
        return requested[0].request_id

    def _record_texts(self, sessions: list[q.Session],
                      sources: tuple[q.Source, ...]) -> dict[tuple[str, str, str], dict]:
        """The records of the pages [sources] were checked against, by kind,
        source and pin, with the bytes read and their page digest. Only
        those pages are read back from disk, never every page read."""
        cited = {source.sha256 for source in sources}
        out: dict[tuple[str, str, str], dict] = {}
        for session in sessions:
            grants = {grant.source_id: grant for grant in session.grants}
            for read in self._session_reads(session):
                if read["result"] is None or read["result"].get("sha256") not in cited:
                    continue
                for record in material(self._reads.whole(read), grants):
                    out[(record["kind"], record["source_id"], record["pin"])] = {
                        key: record[key] for key in ("kind", "source_id", "pin", "sha256", "title", "text")}
        return out

    def _request_grade(self, session: q.Session, posed: q.Posed, response: q.Response,
                       dispute: dict | None = None) -> list[q.Event]:
        """Writes the body of a grade request for one answered question and
        returns the event that names it (§6.2): the question, the labels of
        its key choices as recorded before the answer, the sources with their
        quotes, the answer, and the judgments it already has. A request that
        would not fit the frame could never be listed, so it ends at once."""
        labels = {choice["choice_id"]: choice["label"] for choice in posed.question["choices"]}
        expected: dict
        match posed.key:
            case q.ChoiceKey(choice_ids):
                expected = {"kind": "choices", "labels": [labels[choice_id] for choice_id in choice_ids]}
            case q.Rubric(points):
                expected = {"kind": "rubric", "points": list(points)}
        judgments = session.judgments_of(posed.question_id)
        payload = {"language": session.language,
                   "question": {"header": posed.question["header"], "prompt": posed.question["prompt"],
                                "mode": posed.question["mode"], "choices": posed.question["choices"]},
                   "expected": expected,
                   "sources": [source.to_json() for source in posed.sources],
                   "answer": q.response_to_json(response),
                   "judgments": [{"judgment": q.judgment_to_json(j.judgment), "rationale": j.rationale}
                                 for j in judgments],
                   "dispute": dispute}
        asked = sum(isinstance(e, q.GradeRequested) for e in session.grading_of(posed.question_id))
        request_id = f"{posed.ask_id}-{GRADE}-{posed.question_id}-{asked}"
        body = {"kind": "exact_output", "request_id": request_id, "output": GRADE, "system": self.prompts.grade,
                "messages": [{"role": "user", "text": json.dumps(payload, ensure_ascii=False, sort_keys=True)}]}
        key = digest(body)
        self.requests.write(key, body)
        requested = q.GradeRequested(posed.ask_id, posed.question_id, request_id, key)
        if self.fits(body):
            return [requested]
        return [requested, q.GradeFailed(posed.ask_id, posed.question_id, request_id, "request_exceeds_frame", None)]

    def history_scope(self, session: q.Session) -> str | None:
        """Recorded domain context, or None when not recorded. Historical
        observations never decode a provider request to reconstruct it."""
        return session.history_scope

    # -- consuming results --------------------------------------------------

    def deliver(self, request_id: str, result: Any) -> bool:
        """Consumes one delivered result. False when no request of this
        package's current listing has that id, as for a superseded session."""
        if not isinstance(result, dict) or not isinstance(result.get("status"), str):
            raise InvalidResult("a result must be an object with a status")
        sessions = self.sessions()
        listed = next((r for r in self.listing() if r["request_id"] == request_id), None)
        if listed is None:
            return False
        grading = next(((session, event) for session in sessions for event in session.grading
                        if isinstance(event, q.GradeRequested) and event.request_id == request_id), None)
        if grading is not None:
            self._deliver_grade(*grading, result)
        elif listed["kind"] == "ask":
            session = next(s for s in sessions if s.ask_id == request_id)
            self._deliver_ask(session, request_id, result)
        else:
            session = next(s for s in sessions if request_id.startswith(s.session_id + "-") and s.state == "writing")
            if listed["kind"] == "exact_output":
                self._deliver_author(session, sessions, listed, result)
            else:
                self._deliver_read(session, sessions, listed, result)
        return True

    def _deliver_read(self, session: q.Session, sessions: list[q.Session], request: dict, result: dict) -> None:
        status = result["status"]
        # A file a commit deleted is not a file at that commit. Its refusal is
        # kept as read and skipped, so a release that removes fragments does
        # not stop the session. Any other refusal ends it.
        if status == "not_allowed" and request["kind"] != "read_file":
            entry = {"request": request, "result": result}
            key = digest(entry)
            self.pages.write(key, entry)
            self.log.append([q.MaterialRead(session.session_id, request["request_id"], key),
                             q.SessionFailed(session.session_id,
                                             q.NotAllowed(request["request_id"], str(result.get("reason"))))])
            return
        expected = {"read_records": {"records", "result_exceeds_frame"},
                    "read_file": {"file", "result_exceeds_frame", "not_allowed"},
                    "read_result": {"result_chunk"}}[request["kind"]]
        if status not in expected:
            raise InvalidResult(f"{request['kind']} cannot end as {status}")
        entry = {"request": request, "result": result}
        key = digest(entry)
        self.pages.write(key, entry)
        read = q.MaterialRead(session.session_id, request["request_id"], key)
        after = next(s for s in q.fold(self.log.read() + [read]) if s.session_id == session.session_id)
        if self._next_read(after, sessions) is not None:
            self.log.append([read])
            return
        records = self._material(after, sessions)
        # With no new record the author can still ask again an item asked
        # before, citing its earlier sources (§7). Only a workspace with
        # neither has nothing to ask about.
        if not records and not g.items([s for s in sessions if s.session_id != session.session_id]):
            self.log.append([read, q.SessionFailed(session.session_id, q.NoMaterial())])
            return
        self.log.append([read, *self._request_author(after, sessions, scope=SCOPE_ALL, records=records)])

    def _deliver_author(self, session: q.Session, sessions: list[q.Session], body: dict, result: dict) -> None:
        request_id = body["request_id"]
        failure: q.Failure
        match result["status"]:
            case "answered":
                self._deliver_drafts(session, sessions, body, result)
                return
            case "input_refused":
                self._reduce(session, sessions, body, str(result.get("kind")))
                return
            case "invalid_output" | "output_limit_reached":
                failure = q.AuthorInvalidOutput(request_id)
            case "outcome_unknown":
                failure = q.AuthorOutcomeUnknown(request_id)
            case "not_allowed":
                failure = q.NotAllowed(request_id, str(result.get("reason")))
            case "request_id_reused":
                failure = q.NotAllowed(request_id, "request_id_reused")
            case "result_exceeds_frame":
                failure = q.ResultExceedsFrame(request_id)
            case other:
                raise InvalidResult(f"an author request cannot end as {other}")
        self.log.append([q.SessionFailed(session.session_id, failure)])

    def _reduce(self, session: q.Session, sessions: list[q.Session], body: dict, kind: str) -> None:
        """RFC §7: send only the open debt, then the newer half of the
        material, each request smaller than the one before. The older half is
        not asked about in this session."""
        payload = self._payload(body)
        records = payload["material"]
        history = g.items([s for s in sessions if s.session_id != session.session_id])
        if payload["history_scope"] == SCOPE_ALL and any(not item.open_debt for item in history):
            requested = self._request_author(session, sessions, scope=SCOPE_OPEN_DEBT, records=records)
        elif len(records) > 1:
            requested = self._request_author(session, sessions, scope=payload["history_scope"],
                                             records=records[len(records) // 2:])
        else:
            self.log.append([q.SessionFailed(session.session_id, q.AuthorInputRefused(body["request_id"], kind))])
            return
        self.log.append(list(requested))

    def _deliver_drafts(self, session: q.Session, sessions: list[q.Session], body: dict, result: dict) -> None:
        output = result.get("output")
        if not isinstance(output, dict) or not isinstance(output.get("questions"), list):
            raise InvalidResult("an answered author request carries output.questions")
        payload = self._payload(body)
        known = {item.item_id: item for item in g.items([s for s in sessions if s.session_id != session.session_id])}
        ask_id = f"{session.session_id}-ask"
        rejected: list[q.Event] = []
        posed: list[q.Posed] = []
        for index, draft in enumerate(output["questions"]):
            try:
                checked = check_draft(draft, payload["material"], known)
            except (KeyError, TypeError, IndexError) as error:
                raise InvalidResult(f"question {index} does not have the author schema's shape: {error}") from error
            if isinstance(checked, str):
                rejected.append(q.DraftRejected(session.session_id, body["request_id"], index, checked))
                continue
            sources, reask = checked
            if len(posed) == session.questions:
                rejected.append(q.DraftRejected(session.session_id, body["request_id"], index,
                                                f"the session asked for {session.questions} questions"))
                continue
            if reask is not None and any(p.item_id == reask for p in posed):
                rejected.append(q.DraftRejected(session.session_id, body["request_id"], index,
                                                f"{reask} is already asked in this session"))
                continue
            question_id = f"q{len(posed) + 1}"
            key: q.Key
            if draft["mode"] == TEXT:
                # Ask has no text mode: a question with no choices that
                # invites free text is answered in words.
                question = {"question_id": question_id, "header": draft["header"], "prompt": draft["prompt"],
                            "mode": "single", "free_text": WRITTEN, "choices": []}
                key = q.Rubric(tuple(draft["rubric"]))
            else:
                question = {"question_id": question_id, "header": draft["header"], "prompt": draft["prompt"],
                            "mode": draft["mode"], "free_text": CHOICES_ONLY,
                            "choices": [{"choice_id": c["choice_id"], "label": c["label"], "description": None}
                                        for c in draft["choices"]]}
                key = q.ChoiceKey(tuple(draft["key"]))
            item_id = reask or "i-" + hashlib.sha256(f"{session.session_id}/{index}".encode()).hexdigest()[:16]
            event = q.Posed(session.session_id, ask_id, question_id, item_id, draft["topic"], question,
                            key, tuple(sources))
            # The log's own decoder decides what it can keep; a draft it
            # would refuse is dropped alone, not the whole author result.
            unreadable = q.unreadable(event)
            if unreadable is not None:
                rejected.append(q.DraftRejected(session.session_id, body["request_id"], index,
                                                f"the log cannot keep it: {unreadable}"))
                continue
            posed.append(event)
        ending: list[q.Event] = list(posed) if posed else [q.SessionFailed(session.session_id, q.NoQuestionPassed())]
        self.log.append(rejected + ending)

    def _deliver_ask(self, session: q.Session, ask_id: str, result: dict) -> None:
        """An answer, or the host's refusal of the ask by rule. This package
        never withdraws, so a withdrawn ask is not a result it can take."""
        match result["status"]:
            case "answered":
                try:
                    answers = tuple(q.Answer.of_json(answer) for answer in result["answers"])
                    responder, answered_at = result["responder"], result["answered_at"]
                except (KeyError, TypeError, q.LogError) as error:
                    raise InvalidResult(f"an answered ask is malformed: {error}") from error
                if not isinstance(responder, dict) or isinstance(answered_at, bool) \
                        or not isinstance(answered_at, (int, float)):
                    raise InvalidResult("an answered ask names its responder and time")
                # The host refuses an answer that leaves a question out, so each
                # posed question has exactly one response.
                if sorted(answer.question_id for answer in answers) != sorted(p.question_id for p in session.posed):
                    raise InvalidResult("the answers do not name each posed question once")
                rubric = {p.question_id for p in session.posed if isinstance(p.key, q.Rubric)}
                if any(isinstance(answer.response, q.Chose) and answer.question_id in rubric for answer in answers):
                    raise InvalidResult("an answer chooses on a question that has no choices")
                received = q.AnswerReceived(ask_id, answers, responder, float(answered_at))
                problem = q.unreadable(received)
                if problem is not None:
                    raise InvalidResult(f"the answer cannot be kept: {problem}")
                responses = {answer.question_id: answer.response for answer in answers}
                # The answer and the grade request of each written answer are
                # one write, so no answer waits for a request that was never made.
                self.log.append([received, *(event for posed in session.posed
                                             if isinstance(responses[posed.question_id], q.Wrote)
                                             for event in self._request_grade(session, posed,
                                                                              responses[posed.question_id]))])
            case "not_allowed":
                self.log.append([q.SessionFailed(session.session_id,
                                                 q.NotAllowed(ask_id, str(result.get("reason"))))])
            case "request_id_reused":
                self.log.append([q.SessionFailed(session.session_id,
                                                 q.NotAllowed(ask_id, "request_id_reused"))])
            case "result_exceeds_frame":
                self.log.append([q.SessionFailed(session.session_id, q.ResultExceedsFrame(ask_id))])
            case other:
                raise InvalidResult(f"an ask of this package cannot end as {other}")

    def _deliver_grade(self, session: q.Session, request: q.GradeRequested, result: dict) -> None:
        """A judgment, or the final failure that leaves the answer waiting."""
        def failed(kind: str, detail: str | None) -> q.Event:
            return q.GradeFailed(request.ask_id, request.question_id, request.request_id, kind, detail)
        event: q.Event
        match result["status"]:
            case "answered":
                event = self._judgment(request, result.get("output"))
            case "invalid_output" | "output_limit_reached":
                event = failed("invalid_output", _detail(result.get("detail")))
            case "input_refused":
                event = failed("input_refused", _detail(result.get("kind")))
            case "outcome_unknown":
                event = failed("outcome_unknown", None)
            case "not_allowed":
                event = failed("not_allowed", _detail(result.get("reason")))
            case "request_id_reused":
                event = failed("not_allowed", "request_id_reused")
            case "result_exceeds_frame":
                event = failed("result_exceeds_frame", None)
            case other:
                raise InvalidResult(f"a grade request cannot end as {other}")
        if q.unreadable(event) is not None:
            # The result is final either way; one the log cannot keep is the
            # output's failure, so the answer waits visibly instead of the
            # result being delivered again and again.
            event = failed("invalid_output", "the output holds text the log cannot keep")
        self.log.append([event])

    @staticmethod
    def _judgment(request: q.GradeRequested, output: Any) -> q.Event:
        """The grade schema's verdict and rationale as a Judged. The host
        checked the schema, so anything else is a broken delivery. A
        rationale of only whitespace passes the schema's length rule and is
        kept as the output's failure."""
        if not isinstance(output, dict) or set(output) != {"verdict", "rationale"} \
                or not isinstance(output["rationale"], str):
            raise InvalidResult("an answered grade request carries the grade schema's verdict and rationale")
        judgment: q.Judgment
        match output["verdict"]:
            case "correct":
                judgment = q.Correct()
            case "incorrect":
                judgment = q.Incorrect()
            case "void":
                judgment = q.Void()
            case other:
                raise InvalidResult(f"{other!r} is not a verdict of the grade schema")
        if not output["rationale"].strip():
            return q.GradeFailed(request.ask_id, request.question_id, request.request_id, "invalid_output",
                                 "the rationale is only whitespace")
        return q.Judged(request.ask_id, request.question_id, judgment, output["rationale"], request.request_id)


def _needs_grade(grading: tuple[q.Grading, ...], response: q.Response) -> bool:
    """Whether a compose asks for this answered question's grade again."""
    if grading:
        return isinstance(grading[-1], q.GradeFailed)
    return isinstance(response, q.Wrote)


def _responses(answer: q.AnswerReceived, posed: tuple[q.Posed, ...]) -> list[q.Response]:
    """The responses of an answer in the order its questions were posed."""
    by_question = {item.question_id: item.response for item in answer.answers}
    return [by_question[question.question_id] for question in posed]


def _detail(value: Any) -> str | None:
    return value if isinstance(value, str) and value.strip() else None
