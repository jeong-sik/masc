"""Rows the operator lesson publishes on every observation (RFC
operator-lesson §4.6). Every row is computed from the log; nothing reads a
row to decide anything, and no field says pass or fail.
"""
from __future__ import annotations

import hashlib
import json

import lesson_log as l

SCENES = "lesson/scenes"
SESSIONS = "lesson/sessions"
MEASURES = "lesson/measures"
STATES = (l.READING, l.WRITING, l.WRITTEN, l.FAILED, l.SUPERSEDED)
STATE_TITLES = {l.READING: "기록을 읽는 중", l.WRITING: "장면을 쓰는 중", l.WRITTEN: "씀", l.FAILED: "실패",
                l.SUPERSEDED: "다음 세션으로 대체"}


def stable_id(*parts: str) -> str:
    return hashlib.sha256(json.dumps(parts, separators=(",", ":")).encode("utf-8")).hexdigest()


def row(lane: str, subject: str, title: str, observed_at: float, fields: dict, *,
        evidence: list | None = None) -> dict:
    return {"id": stable_id(lane, subject), "lane_id": lane, "kind": "value", "title": title,
            "observed_at": observed_at, "subject_id": subject, "clock": None, "actor": None,
            "fields": fields, "evidence": evidence or [], "related_ids": []}


def retained(scene: l.SceneWritten) -> list[dict]:
    """Each distinct Lane store blob the scene's quotes were checked against."""
    out: list[dict] = []
    for paragraph in scene.paragraphs:
        for source in paragraph.sources:
            reference = {"uri": f"lane-evidence:{source.sha256}", "sha256": source.sha256}
            if reference not in out:
                out.append(reference)
    return out


def scene_row(scene: l.SceneWritten) -> dict:
    fields = {"session_id": scene.session_id, "entry_id": scene.entry_id, "title": scene.title,
              "body": "\n\n".join(paragraph.text for paragraph in scene.paragraphs),
              "sources": [{"paragraph": position} | source.to_json()
                          for position, paragraph in enumerate(scene.paragraphs) for source in paragraph.sources],
              "written_at": scene.written_at}
    return row(SCENES, f"{scene.session_id}/{scene.entry_id}", scene.title, scene.written_at, fields,
               evidence=retained(scene))


def session_row(session: l.Session) -> dict:
    entries = len(session.entries)
    written, rejected = len(session.written), len(session.rejected_scenes)
    fields = {"session_id": session.session_id, "action_request_id": session.action_request_id,
              "state": session.state, "opened_at": session.opened_at,
              "scenes": {"requested": session.scenes, "outlined": entries, "written": written,
                         "rejected": rejected, "waiting": entries - written - rejected},
              "rejected_entries": [{"index": r.index, "reason": l.entry_rejection_to_json(r.reason)}
                                   for r in session.rejected],
              "rejected_scenes": [{"entry_id": r.entry_id, "reason": l.scene_rejection_to_json(r.reason)}
                                  for r in session.rejected_scenes],
              "failure": l.failure_to_json(session.failure) if session.failure else None,
              "superseded_by": session.superseded_by}
    observed_at = max([session.opened_at, *(scene.written_at for scene in session.written)])
    return row(SESSIONS, session.session_id, f"수업 세션 — {STATE_TITLES[session.state]}", observed_at, fields)


def by_kind(reasons: list[dict]) -> dict:
    kinds = [reason["kind"] for reason in reasons]
    return {kind: kinds.count(kind) for kind in sorted(set(kinds))}


def shown(sessions: list[l.Session]) -> tuple[l.Session, ...]:
    """The sessions whose scenes are rows, in the order given. Every scene
    ever written does not fit one reply for long (#51941), so earlier
    lessons are read from an export.

    The host commits this package's output once at the end of a host cycle,
    and one cycle can write scenes of two sessions: one left writing while
    its scene slot rested, and the one composed after it. So the rows are
    not the newest session's alone. They are the scenes of every session
    that wrote a scene at or after the opening of the newest session that
    wrote one. A lesson whose scenes all came before that opening was shown
    by the observation that ended its own cycle, or by the compose that
    opened the newer session. Only clock values decide; the order of
    [sessions] does not."""
    wrote = [session for session in sessions if session.written]
    if not wrote:
        return ()
    latest = max(scene.written_at for session in wrote for scene in session.written)
    since = max(session.opened_at for session in wrote
                if any(scene.written_at == latest for scene in session.written))
    return tuple(session for session in wrote if any(scene.written_at >= since for scene in session.written))


def measures_row(sessions: list[l.Session], lessons: tuple[l.Session, ...], observed_at: float,
                 evidence: list | None) -> dict:
    states = [session.state for session in sessions]
    fields = {"sessions": {state: states.count(state) for state in STATES},
              "scenes_written": sum(len(session.written) for session in sessions),
              "shown_sessions": [lesson.session_id for lesson in lessons],
              "rejected_entries": by_kind([l.entry_rejection_to_json(r.reason)
                                           for session in sessions for r in session.rejected]),
              "rejected_scenes": by_kind([l.scene_rejection_to_json(r.reason)
                                          for session in sessions for r in session.rejected_scenes]),
              "failed_sessions": by_kind([l.failure_to_json(session.failure)
                                          for session in sessions if session.failure])}
    return row(MEASURES, "measures", "수업 측정", observed_at, fields, evidence=evidence)


def observation(sessions: list[l.Session], now: float, export: dict | None = None) -> dict:
    """The output for one observation. [export] is the log artifact of an
    export action, referenced from the measures row."""
    lessons = shown(sessions)
    rows = [scene_row(scene) for lesson in lessons for scene in lesson.written]
    rows += [session_row(session) for session in sessions]
    # Without an export the row times come from the log, so an observation
    # with nothing new gives the same rows.
    observed_at = now if export else max((r["observed_at"] for r in rows), default=now)
    rows.append(measures_row(sessions, lessons, observed_at, [{"artifact_id": export["id"]}] if export else None))
    output: dict = {"rows": rows, "coverage": []}
    if export:
        output["artifacts"] = [export]
    return output
