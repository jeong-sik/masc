"""Operator tool-call verdict, matching Tool_result.recorded_call_outcome.

Disposition has authority when present, including malformed values. Missing
evidence stays unsettled; legacy booleans and result text grant no success.
"""
from enum import Enum


class RecordedCallOutcome(Enum):
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    DEFERRED = "deferred"
    UNSETTLED = "unsettled"
    MALFORMED = "malformed"


def recorded_call_outcome(row: object) -> RecordedCallOutcome:
    if not isinstance(row, dict):
        return RecordedCallOutcome.MALFORMED
    if "disposition" in row:
        value = row["disposition"]
        if not isinstance(value, str):
            return RecordedCallOutcome.MALFORMED
        return {"completed": RecordedCallOutcome.SUCCEEDED,
                "failed": RecordedCallOutcome.FAILED,
                "deferred": RecordedCallOutcome.DEFERRED}.get(value, RecordedCallOutcome.MALFORMED)
    if "wire_outcome" in row:
        value = row["wire_outcome"]
        if not isinstance(value, str):
            return RecordedCallOutcome.MALFORMED
        return {"ok": RecordedCallOutcome.SUCCEEDED,
                "error": RecordedCallOutcome.FAILED,
                "unknown": RecordedCallOutcome.UNSETTLED}.get(value, RecordedCallOutcome.MALFORMED)
    return RecordedCallOutcome.UNSETTLED
