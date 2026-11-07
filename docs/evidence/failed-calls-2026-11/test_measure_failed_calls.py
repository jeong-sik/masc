"""Checks the counting of measure_failed_calls.py on small synthetic ledgers.

Run: python3 -m unittest discover -s docs/evidence/failed-calls-2026-11
"""

from __future__ import annotations

import datetime
import json
import pathlib
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_failed_calls as failed_calls  # noqa: E402

UTC = datetime.timezone.utc
WIDTH = 60


def at(day: int, hour: int = 0, minute: int = 0) -> float:
    return datetime.datetime(2026, 11, day, hour, minute, tzinfo=UTC).timestamp()


def row(stamp: float, tool: str, keeper: str, turn: str | int | None, disposition: str | None, output: str) -> bytes:
    fields: dict[str, object] = {"ts": stamp, "record_kind": "tool_call", "tool": tool, "keeper": keeper, "output": output}
    if turn is not None:
        fields["keeper_turn_id"] = turn
    if disposition is not None:
        fields["disposition"] = disposition
    return json.dumps(fields).encode("utf-8")


def summary_of(lines: list[bytes], since: float, until: float) -> dict[str, object]:
    skipped = failed_calls.Skipped()
    calls = (call for raw in lines if (call := failed_calls.parse_call(raw, since, until, WIDTH, skipped, 1)) is not None)
    result = failed_calls.summarize(calls, 10)
    result["skipped"] = skipped.bad_lines
    return result


class SignatureTest(unittest.TestCase):
    def test_numbers_and_hashes_fold_and_only_the_first_line_stays(self) -> None:
        output = "comment_offset 18 names no comment of p-d8f423a224896e1cfa45a9751b273886: 17 now\nsecond line"
        self.assertEqual(
            failed_calls.signature_of(output, 200),
            "comment_offset N names no comment of p-<hex>: N now",
        )

    def test_a_signature_is_cut_at_the_width(self) -> None:
        self.assertEqual(failed_calls.signature_of("x" * 100, 10), "x" * 10)

    def test_an_empty_output_has_an_empty_signature(self) -> None:
        self.assertEqual(failed_calls.signature_of("", 10), "")


class CountTest(unittest.TestCase):
    def test_only_a_failed_disposition_counts_as_failed(self) -> None:
        lines = [
            row(at(7, 1), "Grep", "a", "t1", "failed", "boom 1"),
            row(at(7, 2), "Grep", "a", "t2", "completed", "fine"),
            row(at(7, 3), "Grep", "a", "t3", None, "no disposition"),
        ]
        result = summary_of(lines, at(7), at(8))
        self.assertEqual(result["calls"], 3)
        self.assertEqual(result["failed"], 1)

    def test_the_window_holds_since_and_leaves_out_until(self) -> None:
        lines = [
            row(at(7, 0), "Grep", "a", "t1", "failed", "x"),
            row(at(7, 12), "Grep", "a", "t2", "failed", "x"),
            row(at(8, 0), "Grep", "a", "t3", "failed", "x"),
        ]
        result = summary_of(lines, at(7), at(8))
        self.assertEqual(result["calls"], 2)

    def test_lines_that_are_not_calls_or_not_ledger_rows_are_skipped_or_ignored(self) -> None:
        other = json.dumps({"ts": at(7, 1), "record_kind": "other", "tool": "Grep"}).encode("utf-8")
        no_stamp = json.dumps({"record_kind": "tool_call", "tool": "Grep"}).encode("utf-8")
        lines = [b"not json", no_stamp, other, row(at(7, 1), "Grep", "a", "t1", "failed", "x")]
        result = summary_of(lines, at(7), at(8))
        self.assertEqual(result["calls"], 1)
        self.assertEqual(result["skipped"], 2)

    def test_signatures_group_by_tool_and_count_keepers_and_turns(self) -> None:
        lines = [
            row(at(7, 1), "masc_board_post_get", "leader", "t1", "failed", "comment_offset 18 names no comment"),
            row(at(7, 2), "masc_board_post_get", "leader", "t1", "failed", "comment_offset 24 names no comment"),
            row(at(7, 3), "masc_board_post_get", "other", "t9", "failed", "comment_offset 31 names no comment"),
            row(at(7, 4), "Grep", "a", "t2", "failed", "other thing"),
            row(at(7, 5), "Grep", "a", "t3", "completed", "ok"),
        ]
        result = summary_of(lines, at(7), at(8))
        signatures = cast("list[dict[str, object]]", result["signatures"])
        self.assertEqual(signatures[0]["tool"], "masc_board_post_get")
        self.assertEqual(signatures[0]["signature"], "comment_offset N names no comment")
        self.assertEqual((signatures[0]["failed"], signatures[0]["keepers"], signatures[0]["turns"]), (3, 2, 2))
        tools = cast("list[dict[str, object]]", result["tools"])
        self.assertEqual([entry["tool"] for entry in tools], ["masc_board_post_get", "Grep"])
        self.assertEqual((tools[1]["calls"], tools[1]["failed"]), (2, 1))

    def test_a_line_without_a_turn_id_is_its_own_turn(self) -> None:
        lines = [
            row(at(7, 1), "Grep", "a", None, "failed", "same"),
            row(at(7, 2), "Grep", "a", None, "failed", "same"),
        ]
        skipped = failed_calls.Skipped()
        calls = [failed_calls.parse_call(raw, at(7), at(8), WIDTH, skipped, ordinal) for ordinal, raw in enumerate(lines, start=1)]
        result = failed_calls.summarize((call for call in calls if call is not None), 10)
        signatures = cast("list[dict[str, object]]", result["signatures"])
        self.assertEqual(signatures[0]["turns"], 2)

    def test_a_numeric_turn_is_one_turn_per_keeper_and_session(self) -> None:
        lines = [
            row(at(7, 1), "Grep", "a", 11898, "failed", "same"),
            row(at(7, 2), "Grep", "a", 11898, "failed", "same"),
            row(at(7, 3), "Grep", "b", 11898, "failed", "same"),
        ]
        result = summary_of(lines, at(7), at(8))
        signatures = cast("list[dict[str, object]]", result["signatures"])
        self.assertEqual((signatures[0]["failed"], signatures[0]["keepers"], signatures[0]["turns"]), (3, 2, 2))


class LedgerFilesTest(unittest.TestCase):
    def test_files_of_the_days_the_window_touches_are_found_in_name_order(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            month = base / ".masc" / "tool_calls" / "2026-11"
            month.mkdir(parents=True)
            for name in ("06.jsonl", "07.jsonl", "07.001.jsonl", "08.jsonl", "notes.txt"):
                (month / name).write_text("", encoding="utf-8")
            since = datetime.datetime(2026, 11, 7, 9, 30, tzinfo=UTC)
            until = datetime.datetime(2026, 11, 8, 9, 30, tzinfo=UTC)
            names = [path.name for path in failed_calls.ledger_files(base, since, until)]
            self.assertEqual(names, ["07.001.jsonl", "07.jsonl", "08.jsonl"])


if __name__ == "__main__":
    unittest.main()
