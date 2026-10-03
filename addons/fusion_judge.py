"""Canonical retained judge contract shared by Fusion projection and reports."""
from dataclasses import dataclass
from enum import Enum

from protocol import InvalidInput, object_value, string


class JudgeState(Enum):
    SYNTHESIZED = "synthesized"
    FAILED = "failed"


@dataclass(frozen=True)
class JudgeSynthesis:
    resolved_answer: str


@dataclass(frozen=True)
class JudgeFailure:
    failure_code: str
    error: str


def canonical_judge(post):
    judge = object_value(object_value(post.get("meta"), "Board post.meta").get("judge"),
                         "Board post.meta.judge")
    try:
        status = JudgeState(judge.get("status"))
    except (ValueError, TypeError) as error:
        raise InvalidInput("Unknown canonical Fusion judge status") from error
    if status is JudgeState.SYNTHESIZED:
        answer = judge.get("resolved_answer")
        if not isinstance(answer, str):
            raise InvalidInput("Canonical judge resolved_answer must be a string")
        return JudgeSynthesis(answer)
    if status is JudgeState.FAILED:
        return JudgeFailure(string(judge.get("failure_code"), "judge.failure_code"),
                            string(judge.get("error"), "judge.error"))


