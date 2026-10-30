"""Rows the operator quiz publishes on every observation (RFC operator-quiz
§8, §14). Every row is computed from the log; nothing reads a row to decide
anything, and no field says pass or fail.

A question has a row only once it is answered, so its key never shows
early. R counts review items that had a miss followed by a graded attempt on
a later local day, and whether that first later attempt was correct. P is
graded attempts over posed questions. G is the judgments that changed a
verdict a question already had, over graded attempts. All are n/d.
"""
from __future__ import annotations

from datetime import date, datetime
import hashlib
import json
from zoneinfo import ZoneInfo

import quiz_grading as g
import quiz_log as q

SESSIONS = "quiz/sessions"
QUESTIONS = "quiz/questions"
TOPICS = "quiz/topics"
ITEMS = "quiz/items"
MEASURES = "quiz/measures"
GRADED = {g.CORRECT, g.INCORRECT, g.SKIPPED}
OPEN = "open"


def stable_id(*parts: str) -> str:
    return hashlib.sha256(json.dumps(parts, separators=(",", ":")).encode("utf-8")).hexdigest()


def row(lane: str, subject: str, title: str, observed_at: float, fields: dict, *,
        kind: str = "value", evidence: list | None = None) -> dict:
    return {"id": stable_id(lane, subject), "lane_id": lane, "kind": kind, "title": title,
            "observed_at": observed_at, "subject_id": subject, "clock": None, "actor": None,
            "fields": fields, "evidence": evidence or [], "related_ids": []}


def retained(sources: tuple[q.Source, ...]) -> list[dict]:
    """Each distinct Lane store blob a question's quotes were checked against."""
    out: list[dict] = []
    for source in sources:
        reference = {"uri": f"lane-evidence:{source.sha256}", "sha256": source.sha256}
        if reference not in out:
            out.append(reference)
    return out


def fraction(n: int, d: int) -> dict:
    return {"n": n, "d": d}


def local_day(at: float, zone: ZoneInfo) -> date:
    return datetime.fromtimestamp(at, zone).date()


def attempt_states(session: q.Session) -> list[tuple[q.Posed, str]]:
    """Each posed question with its attempt state. A failed session's
    questions were never answered and have none."""
    if session.state == "asked":
        return [(posed, OPEN) for posed in session.posed]
    if session.answer is None:
        return []
    responses = {answer.question_id: answer.response for answer in session.answer.answers}
    return [(posed, g.verdict(posed, responses[posed.question_id], session.judgments_of(posed.question_id)))
            for posed in session.posed]


def recovered(item: g.Item, zone: ZoneInfo) -> bool | None:
    """Whether the first graded attempt on a later local day than the item's
    first such miss was correct; None when no miss has a later-day attempt."""
    graded = [attempt for attempt in item.attempts if attempt.verdict in GRADED]
    for index, miss in enumerate(graded):
        if miss.verdict not in g.MISSES:
            continue
        day = local_day(miss.answered_at, zone)
        later = next((a for a in graded[index + 1:] if local_day(a.answered_at, zone) > day), None)
        if later is not None:
            return later.verdict == g.CORRECT
    return None


def session_row(session: q.Session, scope: str | None) -> dict:
    states = [state for _, state in attempt_states(session)]
    counts = {state: states.count(state) for state in (g.CORRECT, g.INCORRECT, g.SKIPPED,
                                                         g.AWAITING_JUDGMENT, g.VOID, OPEN)}
    graded = counts[g.CORRECT] + counts[g.INCORRECT] + counts[g.SKIPPED]
    fields = {"session_id": session.session_id, "action_request_id": session.action_request_id,
              "state": session.state, "opened_at": session.opened_at, "questions_requested": session.questions,
              "posed": len(session.posed), "counts": counts, "score": fraction(counts[g.CORRECT], graded),
              "history_scope": scope,
              "rejected_drafts": [{"index": r.index, "reason": r.reason} for r in session.rejected],
              "failure": q.failure_to_json(session.failure) if session.failure else None,
              "superseded_by": session.superseded_by,
              "answered_at": session.answer.answered_at if session.answer else None}
    title = {"writing": "작성 중", "asked": "답을 기다리는 중", "answered": "답함", "failed": "실패",
             "superseded": "다음 세션으로 대체"}[session.state]
    observed_at = session.answer.answered_at if session.answer else session.opened_at
    return row(SESSIONS, session.session_id, f"퀴즈 세션 — {title}", observed_at, fields)


def grading_state(session: q.Session, question_id: str) -> dict | None:
    """Where the question's grading stands: a request waiting for its
    result, or the final failure of the last one. None when neither."""
    events = session.grading_of(question_id)
    match events[-1] if events else None:
        case q.GradeRequested(request_id=request_id):
            return {"state": "waiting", "request_id": request_id}
        case q.GradeFailed(request_id=request_id, kind=kind, detail=detail):
            return {"state": "failed", "request_id": request_id, "kind": kind, "detail": detail}
        case q.Judged() | q.Disputed() | None:
            return None


def question_rows(session: q.Session) -> list[dict]:
    if session.answer is None:
        return []
    responses = {answer.question_id: answer.response for answer in session.answer.answers}
    out = []
    for posed, verdict in attempt_states(session):
        judgments = session.judgments_of(posed.question_id)
        by = "judgment" if judgments else "key" if verdict in GRADED else None
        fields = {"session_id": session.session_id, "ask_id": posed.ask_id, "question_id": posed.question_id,
                  "item_id": posed.item_id, "topic": posed.topic, "question": posed.question,
                  "response": q.response_to_json(responses[posed.question_id]), "key": q.key_to_json(posed.key),
                  "verdict": verdict, "by": by,
                  "judgments": [{"judgment": q.judgment_to_json(j.judgment), "rationale": j.rationale,
                                 "request_id": j.request_id} for j in judgments],
                  "grading": grading_state(session, posed.question_id),
                  "disputes": [{"note": d.note, "action_request_id": d.action_request_id}
                               for d in session.disputes_of(posed.question_id)],
                  "sources": [source.to_json() for source in posed.sources]}
        title = {g.CORRECT: "맞음", g.INCORRECT: "틀림", g.SKIPPED: "건너뜀",
                 g.AWAITING_JUDGMENT: "채점 대기", g.VOID: "무효"}[verdict]
        out.append(row(QUESTIONS, f"{session.session_id}/{posed.question_id}",
                       f"{title} — {posed.question['header']}", session.answer.answered_at, fields,
                       kind="event", evidence=retained(posed.sources)))
    return out


def item_row(item: g.Item, first_posed_at: float) -> dict:
    fields = {"item_id": item.item_id, "topic": item.topic, "latest": item.latest,
              "correct_streak": item.correct_streak, "open_debt": item.open_debt,
              "attempts": [{"session_id": a.session_id, "question_id": a.question_id,
                            "answered_at": a.answered_at, "verdict": a.verdict} for a in item.attempts],
              "sources": [source.to_json() for source in item.sources]}
    observed_at = item.attempts[-1].answered_at if item.attempts else first_posed_at
    return row(ITEMS, item.item_id, f"복습 항목 — {item.topic}", observed_at, fields,
               evidence=retained(item.sources))


def topic_rows(items: list[g.Item], first_posed: dict[str, float]) -> list[dict]:
    topics: dict[str, list[g.Item]] = {}
    for item in items:
        topics.setdefault(item.topic, []).append(item)
    out = []
    for topic, members in topics.items():
        attempts = [a for item in members for a in item.attempts]
        misses = [a for a in attempts if a.verdict in g.MISSES]
        debt = [item for item in members if item.open_debt]
        fields = {"topic": topic, "items": len(members), "attempts": len(attempts), "misses": len(misses),
                  "open_debt": len(debt), "last_miss_at": max((a.answered_at for a in misses), default=None),
                  "open_debt_items": [{"item_id": item.item_id,
                                       "sources": [source.to_json() for source in item.sources]}
                                      for item in debt]}
        observed_at = max([a.answered_at for a in attempts] + [first_posed[item.item_id] for item in members])
        out.append(row(TOPICS, topic, f"주제 — {topic}", observed_at, fields))
    return out


def measures_row(sessions: list[q.Session], items: list[g.Item], zone: ZoneInfo, observed_at: float,
                 evidence: list | None) -> dict:
    recoveries = [r for r in (recovered(item, zone) for item in items) if r is not None]
    states = [state for session in sessions for _, state in attempt_states(session)]
    graded = sum(state in GRADED for state in states)
    changed = sum(g.changed_verdicts(posed, answer.response, session.judgments_of(posed.question_id))
                  for session in sessions if session.answer is not None
                  for posed in session.posed
                  for answer in session.answer.answers if answer.question_id == posed.question_id)
    posed = sum(len(session.posed) for session in sessions)
    failures: dict[str, int] = {}
    for session in sessions:
        if session.failure is not None:
            kind = q.failure_to_json(session.failure)["kind"]
            failures[kind] = failures.get(kind, 0) + 1
    fields = {"recovery": fraction(sum(recoveries), len(recoveries)), "participation": fraction(graded, posed),
              "score": fraction(states.count(g.CORRECT), graded),
              "changed_grades": fraction(changed, graded),
              "rejected_drafts": sum(len(session.rejected) for session in sessions),
              "failed_sessions": failures,
              "author_refusals": sum(max(len(session.requests) - 1, 0) for session in sessions)
              + failures.get("author_input_refused", 0),
              "posed_never_answered": sum(len(session.posed) for session in sessions if session.state == "failed"),
              "sessions": len(sessions)}
    return row(MEASURES, "measures", "퀴즈 측정값", observed_at, fields, evidence=evidence)


def observation(sessions: list[q.Session], scopes: dict[str, str | None], zone: ZoneInfo, now: float,
                export: dict | None = None) -> dict:
    """The output for one observation. [export] is the log artifact of an
    export action, referenced from the measures row.

    Items and topics come from answered sessions only: a question still open
    must not show its sources, because a citation can give the answer away
    (§5). An item asked again keeps the sources its earlier answers revealed."""
    revealed = [session for session in sessions if session.state == "answered"]
    items = g.items(revealed)
    first_posed: dict[str, float] = {}
    for session in revealed:
        for posed in session.posed:
            first_posed.setdefault(posed.item_id, session.opened_at)
    rows = [session_row(session, scopes.get(session.session_id)) for session in sessions]
    rows += [r for session in sessions for r in question_rows(session)]
    rows += topic_rows(items, first_posed)
    rows += [item_row(item, first_posed[item.item_id]) for item in items]
    # Without an export the row times come from the log, so an observation
    # with nothing new gives the same rows.
    observed_at = now if export else max((r["observed_at"] for r in rows), default=now)
    rows.append(measures_row(sessions, items, zone, observed_at,
                             [{"artifact_id": export["id"]}] if export else None))
    output: dict = {"rows": rows, "coverage": []}
    if export:
        output["artifacts"] = [export]
    return output
