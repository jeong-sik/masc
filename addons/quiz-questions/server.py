"""Ask multiple-choice questions whose every answer is a retained record.

The questioner never grades. It reads a Keeper-exported fact deck
(`snapshot_file`), turns each fact into one question from a closed template
set, and publishes the choices without marking which one is right. Grading is a
separate installation that re-reads the same deck (see the design note).

Nothing is invented here: a prompt comes from a fixed template keyed by the
fact's `field`, and every choice is an `answer` some retained fact carries.
A fact whose field has no template, or whose field has no second distinct
answer to contrast with, is skipped and named in coverage.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import InvalidInput, Source, evidence, object_value, row, serve, stable_id, string

# Closed template set. A new field needs a reviewed template, not a guess.
TEMPLATES = {
    "author": "「{subject}」 를 쓴 이는?",
    "claimant": "{subject} 를 맡은 Keeper 는?",
    "status": "{subject} 의 지금 상태는?",
    "merged_commit": "{subject} 가 main 에 착지한 커밋은?",
    "cause": "{subject} 의 원인으로 기록된 것은?",
    "decision": "{subject} 에 대해 내려진 결정은?",
}
MAX_CHOICES = 4


def fact(observation: dict) -> dict:
    string(observation.get("id"), "fact.id")
    field = string(observation.get("field"), "fact.field")
    subject = string(observation.get("subject"), "fact.subject")
    answer = string(observation.get("answer"), "fact.answer")
    # The host prepends its own copy of the deck to every observation's
    # `evidence` (lane_addon_sources.ml snapshot_file), so a non-empty evidence
    # list proves nothing about the record. The record is a separate field.
    if "record" not in observation:
        raise InvalidInput(f"fact {observation['id']} has no record")
    record, = evidence([object_value(observation["record"], "fact.record")])
    if record["uri"].startswith(("lane-evidence:", "lane-sequence:")):
        raise InvalidInput(f"fact {observation['id']} cites the host copy, not a record")
    return {"field": field, "subject": subject, "answer": answer, "record": record}


def choices_for(question_id: str, answer: str, pool: list[str]) -> list[str]:
    others = sorted({value for value in pool if value != answer},
                    key=lambda value: stable_id(question_id, "distractor", value))
    picked = [answer] + others[: MAX_CHOICES - 1]
    # Order by hash so the right answer's position carries no signal.
    return sorted(picked, key=lambda value: stable_id(question_id, "order", value))


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    rows, coverage = [], []
    if not sources:
        return {"rows": [], "coverage": [{
            "source_id": "quiz-questions/deck", "incarnation": "unobserved", "cursor": None,
            "complete": False, "detail": "No fact deck was supplied; no question can be asked"}]}
    for source in sources:
        facts = [item for item in source.observations if item.get("kind") == "fact"]
        skipped_kinds = {str(item.get("kind", "untyped")) for item in source.observations
                         if item.get("kind") != "fact"}
        # Fail-closed on purpose: one fact without a record refuses the whole observe,
        # because the Keeper re-exports the deck and a partial deck would hide the gap.
        parsed = [(item, fact(item)) for item in facts]
        pool: dict[str, list[str]] = {}
        for _, value in parsed:
            pool.setdefault(value["field"], []).append(value["answer"])
        no_template, no_contrast = set(), set()
        for item, value in parsed:
            template = TEMPLATES.get(value["field"])
            if template is None:
                no_template.add(value["field"])
                continue
            question_id = stable_id(source.source_id, source.incarnation, item["id"])
            choices = choices_for(question_id, value["answer"], pool[value["field"]])
            if len(choices) < 2:
                no_contrast.add(value["field"])
                continue
            question = row(source, item, lane="quiz/questions", subject=item["id"],
                           title=template.format(subject=value["subject"]),
                           fields={"question_id": question_id, "field": value["field"],
                                   "choices": choices, "record": value["record"]})
            question["evidence"].append(value["record"])
            rows.append(question)
        status = source.coverage(skipped_kinds)
        details = [status["detail"]] if status["detail"] else []
        if no_template:
            details.append("Fields without a template: " + ", ".join(sorted(no_template)))
        if no_contrast:
            details.append("Fields with one distinct answer: " + ", ".join(sorted(no_contrast)))
        if not facts:
            details.append("No fact observation supplied")
        status["complete"] = source.complete and bool(facts) and not skipped_kinds \
            and not no_template and not no_contrast
        status["detail"] = "; ".join(details) if details else None
        coverage.append(status)
    return {"rows": rows, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-quiz-questions", observe)
