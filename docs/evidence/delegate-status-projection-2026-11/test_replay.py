"""Checks the byte arithmetic of replay.py on small synthetic stored outputs.

Run: python3 -m unittest discover -s docs/evidence/delegate-status-projection-2026-11
"""

from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import replay  # noqa: E402

MARKER = replay.TRUNCATED_MEMBER_BYTES


def queued(**overrides: object) -> dict[str, object]:
    operation: dict[str, object] = {
        "schema": "masc.keeper_chat_operation.v1",
        "operation_id": "op1",
        "sequence": "7",
        "created_at": 1.0,
        "admission_digest": "a" * 8,
        "execution_digest": "b" * 8,
        "source": {"submitted_by": "agent"},
        "input": {"message": "hello"},
        "state": "Queued",
    }
    operation.update(overrides)
    return operation


def kept_bytes(obj: dict[str, object]) -> int:
    return replay.compact_bytes({key: value for key, value in obj.items() if key in replay.KEPT_FIELDS})


class DroppedBytesTest(unittest.TestCase):
    def test_unclipped_output_drops_the_request_echo(self) -> None:
        obj = queued()
        size = replay.compact_bytes(obj)
        self.assertEqual(replay.dropped_bytes(obj, size), size - kept_bytes(obj))

    def test_cut_input_counts_the_unstored_tail_and_not_the_marker(self) -> None:
        obj = queued(input={"message": "cut", "_truncated": True})
        unstored_tail = 100
        received = replay.compact_bytes(obj) - MARKER + unstored_tail
        expected = replay.compact_bytes(obj) - kept_bytes(obj) - MARKER + unstored_tail
        self.assertEqual(replay.dropped_bytes(obj, received), expected)

    def test_cut_inside_a_kept_field_is_not_attributed_to_the_dropped_side(self) -> None:
        obj = queued(state="Succeeded", input=None, completed_reply={"text": "cut", "_truncated": True})
        received = replay.compact_bytes(obj) - MARKER + 500
        self.assertEqual(replay.dropped_bytes(obj, received), replay.compact_bytes(obj) - kept_bytes(obj))

    def test_top_level_marker_is_removed_and_does_not_decide_the_side(self) -> None:
        obj = queued(input={"message": "cut", "_truncated": True})
        obj["_truncated"] = True
        unstored_tail = 500
        received = replay.compact_bytes(obj) - 2 * MARKER + unstored_tail
        # Everything but the kept fields is dropped, so what remains is exactly the kept fields.
        self.assertEqual(replay.dropped_bytes(obj, received), received - kept_bytes(obj))

    def test_top_level_marker_with_a_cut_kept_field_keeps_the_tail_in_after(self) -> None:
        obj = queued(state="Succeeded", input=None, completed_reply={"text": "cut", "_truncated": True})
        obj["_truncated"] = True
        received = replay.compact_bytes(obj) - 2 * MARKER + 500
        expected = replay.compact_bytes(obj) - kept_bytes(obj) - MARKER
        self.assertEqual(replay.dropped_bytes(obj, received), expected)

    def test_cut_in_both_a_dropped_and_a_kept_field_keeps_the_tail_in_after(self) -> None:
        obj = queued(
            state="Succeeded",
            input={"message": "cut", "_truncated": True},
            completed_reply={"text": "cut", "_truncated": True},
        )
        received = replay.compact_bytes(obj) - 2 * MARKER + 500
        expected = replay.compact_bytes(obj) - kept_bytes(obj) - MARKER
        self.assertEqual(replay.dropped_bytes(obj, received), expected)

    def test_result_smaller_than_the_stored_output_adds_no_negative_tail(self) -> None:
        obj = queued(input={"message": "cut", "_truncated": True})
        received = replay.compact_bytes(obj) - MARKER - 5
        self.assertEqual(replay.dropped_bytes(obj, received), replay.compact_bytes(obj) - kept_bytes(obj) - MARKER)


class CountTruncatedMembersTest(unittest.TestCase):
    def test_counts_markers_at_every_depth(self) -> None:
        value = {"a": {"_truncated": True}, "b": [{"_truncated": True}, {"c": {"_truncated": True}}], "_truncated": True}
        self.assertEqual(replay.count_truncated_members(value), 4)

    def test_a_marker_that_is_not_true_is_not_counted(self) -> None:
        self.assertEqual(replay.count_truncated_members({"_truncated": False, "x": 1}), 0)


if __name__ == "__main__":
    unittest.main()
