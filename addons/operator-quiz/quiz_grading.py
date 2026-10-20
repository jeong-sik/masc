"""Verdicts and review items (RFC operator-quiz §6.1, §6.3, §7).

A choice verdict is a pure function of the key and the answer, so it is
recomputed whenever it is needed and never stored. A written answer waits
for a judgment, which the grade output brings; until then it is
awaiting_judgment. A skip is a miss.
"""
from __future__ import annotations

from dataclasses import dataclass

import quiz_log as q

CORRECT = "correct"
INCORRECT = "incorrect"
SKIPPED = "skipped"
AWAITING_JUDGMENT = "awaiting_judgment"
MISSES = {INCORRECT, SKIPPED}


def verdict(posed: q.Posed, response: q.Response) -> str:
    match response:
        case q.Chose(choice_ids):
            return CORRECT if set(choice_ids) == set(posed.key) else INCORRECT
        case q.Skipped():
            return SKIPPED
        case q.Wrote():
            return AWAITING_JUDGMENT


@dataclass(frozen=True, slots=True)
class Attempt:
    session_id: str
    question_id: str
    answered_at: float
    verdict: str


@dataclass(frozen=True, slots=True)
class Item:
    item_id: str
    topic: str
    sources: tuple[q.Source, ...]  # every source a question of this item was posed with
    attempts: tuple[Attempt, ...]  # in the order answered

    @property
    def latest(self) -> str | None:
        return self.attempts[-1].verdict if self.attempts else None

    @property
    def correct_streak(self) -> int:
        """How many correct answers in a row end the history."""
        streak = 0
        for attempt in reversed(self.attempts):
            if attempt.verdict != CORRECT:
                break
            streak += 1
        return streak

    @property
    def open_debt(self) -> bool:
        return self.latest in MISSES


def items(sessions: list[q.Session]) -> list[Item]:
    """Every item ever posed, in the order first posed, with the attempts its
    answered questions made."""
    order: list[str] = []
    topics: dict[str, str] = {}
    sources: dict[str, list[q.Source]] = {}
    attempts: dict[str, list[Attempt]] = {}
    for session in sessions:
        responses = ({answer.question_id: answer.response for answer in session.answer.answers}
                     if session.answer else {})
        for posed in session.posed:
            if posed.item_id not in topics:
                order.append(posed.item_id)
                topics[posed.item_id] = posed.topic
                sources[posed.item_id] = []
                attempts[posed.item_id] = []
            for source in posed.sources:
                if source not in sources[posed.item_id]:
                    sources[posed.item_id].append(source)
            if posed.question_id in responses and session.answer is not None:
                attempts[posed.item_id].append(
                    Attempt(session.session_id, posed.question_id, session.answer.answered_at,
                            verdict(posed, responses[posed.question_id])))
    return [Item(item_id, topics[item_id], tuple(sources[item_id]),
                 tuple(sorted(attempts[item_id], key=lambda attempt: attempt.answered_at)))
            for item_id in order]
