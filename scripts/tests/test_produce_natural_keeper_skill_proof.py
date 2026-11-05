"""Status shapes the natural Keeper proof producer accepts and refuses.

`masc_keeper_delegate_status` returns the shape of
`Keeper_chat_operation.to_status_json`. A Succeeded operation also carries
`completed_reply`, which `keeper_delegate_status_body` appends.
"""

from __future__ import annotations

import pathlib
import sys
import unittest
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/harness/workload"))

import produce_natural_keeper_skill_proof as producer  # noqa: E402

OPERATION_ID = "op-1"
TURN_REF = "trace-abc#3"
CREATED_AT = 1_760_000_000.5
COMPLETED_AT = 1_760_000_010.25
AVAILABLE_REPLY: dict[str, Any] = {
    "status": "available",
    "turn_ref": TURN_REF,
    "replies": [{"message_id": "m1", "text": "done", "blocks": None}],
}
UNAVAILABLE_REPLY: dict[str, Any] = {"status": "unavailable", "reason": "reply_not_found"}

STATUS_FIELDS: dict[str, dict[str, Any]] = {
    "Queued": {"state": "Queued"},
    "Running": {"state": "Running", "started_at": CREATED_AT + 1},
    "Succeeded": {
        "state": "Succeeded",
        "completed_at": COMPLETED_AT,
        "outcome_ref": TURN_REF,
        "completed_reply": UNAVAILABLE_REPLY,
    },
    "Failed": {
        "state": "Failed",
        "completed_at": COMPLETED_AT,
        "failure_kind": "Timeout",
        "failure_detail": "turn exceeded the deadline",
        "outcome_ref": None,
    },
    "Cancelled": {"state": "Cancelled", "completed_at": COMPLETED_AT},
}

# Fields of the full operation record that the status read no longer returns.
DROPPED_FIELDS: dict[str, Any] = {
    "schema": "masc.keeper_chat_operation.v1",
    "sequence": "4",
    "admission_digest": "0" * 64,
    "execution_digest": "1" * 64,
    "source": {"kind": "direct_message"},
    "input": {"message": "hello"},
    "batch_input_digest": "2" * 64,
}


def status(kind: str, **changes: Any) -> dict[str, Any]:
    value: dict[str, Any] = {
        "operation_id": OPERATION_ID,
        "created_at": CREATED_AT,
        **STATUS_FIELDS[kind],
    }
    value.update(changes)
    return value


def without(value: dict[str, Any], field: str) -> dict[str, Any]:
    return {name: item for name, item in value.items() if name != field}


class ValidateOperationTest(unittest.TestCase):
    def refused(self, value: dict[str, Any]) -> None:
        with self.assertRaises(producer.ProducerError):
            producer.validate_operation(value, OPERATION_ID)

    def test_each_state_in_the_shape_the_tool_returns_is_accepted(self) -> None:
        for kind in STATUS_FIELDS:
            with self.subTest(kind=kind):
                self.assertEqual(
                    producer.validate_operation(status(kind), OPERATION_ID), kind
                )

    def test_a_batch_member_adds_only_its_batch_execution_id(self) -> None:
        self.assertEqual(
            producer.validate_operation(
                status("Succeeded", batch_execution_id="batch-1"), OPERATION_ID
            ),
            "Succeeded",
        )
        self.refused(status("Queued", batch_execution_id=""))

    def test_both_completed_reply_shapes_are_accepted(self) -> None:
        for reply in (AVAILABLE_REPLY, UNAVAILABLE_REPLY):
            with self.subTest(reply=reply["status"]):
                self.assertEqual(
                    producer.validate_operation(
                        status("Succeeded", completed_reply=reply), OPERATION_ID
                    ),
                    "Succeeded",
                )

    def test_a_succeeded_status_needs_completed_reply_as_an_object(self) -> None:
        self.refused(without(status("Succeeded"), "completed_reply"))
        for not_an_object in (None, "done", [AVAILABLE_REPLY], 3):
            with self.subTest(value=not_an_object):
                self.refused(status("Succeeded", completed_reply=not_an_object))

    def test_completed_reply_belongs_to_a_succeeded_status_only(self) -> None:
        for kind in ("Queued", "Running", "Failed", "Cancelled"):
            with self.subTest(kind=kind):
                self.refused(status(kind, completed_reply=UNAVAILABLE_REPLY))

    def test_fields_the_status_read_dropped_are_refused(self) -> None:
        for field, extra in DROPPED_FIELDS.items():
            with self.subTest(field=field):
                self.refused(status("Succeeded", **{field: extra}))

    def test_each_state_needs_its_own_fields(self) -> None:
        required = {
            "Running": ("started_at",),
            "Succeeded": ("completed_at", "outcome_ref", "completed_reply"),
            "Failed": ("completed_at", "failure_kind", "failure_detail", "outcome_ref"),
            "Cancelled": ("completed_at",),
        }
        for kind, fields in required.items():
            for field in fields:
                with self.subTest(kind=kind, missing=field):
                    self.refused(without(status(kind), field))
        self.refused(without(status("Queued"), "created_at"))

    def test_a_failed_status_may_carry_a_null_outcome_ref_but_not_an_empty_one(
        self,
    ) -> None:
        self.assertEqual(
            producer.validate_operation(status("Failed", outcome_ref=None), OPERATION_ID),
            "Failed",
        )
        self.assertEqual(
            producer.validate_operation(
                status("Failed", outcome_ref="trace-abc#3"), OPERATION_ID
            ),
            "Failed",
        )
        self.refused(status("Failed", outcome_ref=""))

    def test_another_operation_id_is_refused(self) -> None:
        self.refused(status("Queued", operation_id="op-2"))

    def test_an_unknown_state_is_refused(self) -> None:
        self.refused(status("Queued", state="Done"))

    def test_times_are_nonnegative_numbers(self) -> None:
        self.refused(status("Queued", created_at=True))
        self.refused(status("Queued", created_at="1760000000"))
        self.refused(status("Succeeded", completed_at=-1.0))


class ValidateProducerOperationTest(unittest.TestCase):
    def test_a_succeeded_status_with_a_canonical_turn_ref_is_accepted(self) -> None:
        self.assertEqual(
            producer.validate_producer_operation(
                status("Succeeded"), operation_id=OPERATION_ID
            ),
            "Succeeded",
        )

    def test_a_succeeded_status_needs_a_canonical_turn_ref(self) -> None:
        for turn_ref in ("trace-abc", "trace-abc#03", "#3", "trace-abc#-1"):
            with self.subTest(turn_ref=turn_ref):
                with self.assertRaises(producer.ProducerError):
                    producer.validate_producer_operation(
                        status("Succeeded", outcome_ref=turn_ref),
                        operation_id=OPERATION_ID,
                    )

    def test_the_operation_id_must_match_the_one_accepted_at_submission(self) -> None:
        with self.assertRaises(producer.ProducerError):
            producer.validate_producer_operation(
                status("Queued"), operation_id="op-2"
            )


if __name__ == "__main__":
    unittest.main()
