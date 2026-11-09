"""Checks retry_diff.py on small synthetic ledger records.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
"""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import retry_diff as retries  # noqa: E402

type Record = dict[str, retries.Json]

REFUSED = "Invalid browser arguments: x must be a JavaScript-safe integer."


def record(
    ts: float,
    disposition: str = "failed",
    keeper: str = "a",
    tool: str = "BrowserInteract",
    input_value: retries.Json = None,
    output: str = "ok",
    kind: str = "tool_call",
) -> Record:
    return {
        "record_kind": kind,
        "ts": ts,
        "keeper": keeper,
        "tool": tool,
        "disposition": disposition,
        "input": {"action": "scroll", "y": 5} if input_value is None else input_value,
        "output": output,
    }


class ErrorHeadTest(unittest.TestCase):
    def test_digits_and_long_hex_do_not_split_a_group(self) -> None:
        self.assertEqual(
            retries.error_head("Post not found: p-3f9a1c0b7d2e9 after 12 tries"),
            "Post not found: p-H after N tries",
        )

    def test_the_head_is_cut_and_has_no_newline(self) -> None:
        head = retries.error_head("a\n" * 200)
        self.assertEqual(len(head), retries.HEAD_CHARS)
        self.assertNotIn("\n", head)


class InputDiffTest(unittest.TestCase):
    def test_added_dropped_and_changed_keys(self) -> None:
        self.assertEqual(retries.input_diff({"a": 1, "b": 2}, {"b": 3, "c": 4}), "+c -a ~b")

    def test_equal_inputs_have_an_empty_diff(self) -> None:
        self.assertEqual(retries.input_diff({"a": 1}, {"a": 1}), "+- -- ~-")

    def test_an_input_that_is_not_an_object_has_no_diff(self) -> None:
        self.assertEqual(retries.input_diff("text", {"a": 1}), retries.NON_OBJECT_INPUT)


class RetriesOfTest(unittest.TestCase):
    def test_a_retry_that_adds_a_key_and_completes(self) -> None:
        found = retries.retries_of(
            [
                record(100.0, output=REFUSED),
                record(103.0, disposition="completed", input_value={"action": "scroll", "y": 5, "x": 0}),
            ],
            since=0.0,
            until=200.0,
        )
        self.assertEqual(found, [retries.Retry("BrowserInteract", REFUSED, "+x -- ~-", True)])

    def test_a_failure_with_no_call_within_the_window_has_no_retry(self) -> None:
        found = retries.retries_of(
            [record(100.0), record(100.0 + retries.RETRY_WINDOW_S + 1.0, disposition="completed")],
            since=0.0,
            until=200.0,
        )
        self.assertEqual([(row.diff, row.completed) for row in found], [(retries.NO_RETRY, False)])

    def test_another_keeper_or_tool_is_not_a_retry(self) -> None:
        found = retries.retries_of(
            [
                record(100.0),
                record(101.0, disposition="completed", keeper="b"),
                record(102.0, disposition="completed", tool="Edit"),
            ],
            since=0.0,
            until=200.0,
        )
        self.assertEqual([(row.diff, row.completed) for row in found], [(retries.NO_RETRY, False)])

    def test_a_failure_outside_the_window_is_not_counted_but_may_be_the_retry(self) -> None:
        found = retries.retries_of(
            [
                record(10.0),
                record(250.0),
                record(255.0, disposition="completed"),
            ],
            since=100.0,
            until=300.0,
        )
        self.assertEqual([(row.diff, row.completed) for row in found], [("+- -- ~-", True)])

    def test_a_retry_after_until_still_counts_for_a_failure_before_it(self) -> None:
        found = retries.retries_of(
            [record(299.0), record(310.0, disposition="completed")],
            since=0.0,
            until=300.0,
        )
        self.assertEqual([row.completed for row in found], [True])

    def test_a_retry_exactly_at_the_window_edge_counts(self) -> None:
        found = retries.retries_of(
            [record(100.0), record(100.0 + retries.RETRY_WINDOW_S, disposition="completed")],
            since=0.0,
            until=200.0,
        )
        self.assertEqual([row.completed for row in found], [True])

    def test_a_failure_exactly_at_until_is_not_counted(self) -> None:
        self.assertEqual(retries.retries_of([record(200.0)], since=0.0, until=200.0), [])

    def test_a_failure_exactly_at_since_is_counted(self) -> None:
        self.assertEqual(len(retries.retries_of([record(0.0)], since=0.0, until=200.0)), 1)

    def test_lines_that_are_not_tool_calls_are_ignored(self) -> None:
        found = retries.retries_of([record(100.0, kind="turn")], since=0.0, until=200.0)
        self.assertEqual(found, [])

    def test_a_retry_that_fails_again_is_not_completed(self) -> None:
        found = retries.retries_of([record(100.0), record(101.0)], since=0.0, until=200.0)
        self.assertEqual([row.completed for row in found], [False, False])


class CallsInWindowTest(unittest.TestCase):
    def test_since_is_included_until_is_excluded_and_other_lines_are_skipped(self) -> None:
        records: list[Record] = [
            record(0.0, disposition="completed"),
            record(100.0),
            record(200.0),
            record(150.0, kind="turn"),
            {"record_kind": "tool_call", "tool": "t"},
        ]
        self.assertEqual(retries.calls_in_window(records, since=0.0, until=200.0), 2)


class ReportTest(unittest.TestCase):
    def test_groups_below_the_minimum_are_left_out_and_the_largest_comes_first(self) -> None:
        many = [retries.Retry("t", "big", "+x -- ~-", True)] * 3 + [retries.Retry("t", "big", retries.NO_RETRY, False)]
        few = [retries.Retry("t", "small", retries.NO_RETRY, False)]
        lines = retries.report(many + few, min_failures=2)
        self.assertEqual(
            lines,
            [
                "   4 failures, retry completed   3  t: big",
                "        retry diff +x -- ~-  x3",
                "        retry diff no retry  x1",
            ],
        )


class ReadRecordsTest(unittest.TestCase):
    def test_lines_that_are_not_json_are_counted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            folder = pathlib.Path(directory) / ".masc" / "tool_calls" / "2026-11"
            folder.mkdir(parents=True)
            (folder / "09.jsonl").write_text(json.dumps(record(1.0)) + "\nnot json\n[1]\n", encoding="utf-8")
            records, unreadable = retries.read_records(pathlib.Path(directory), "2026-11")
        self.assertEqual((len(records), unreadable), (1, 1))


if __name__ == "__main__":
    unittest.main()
