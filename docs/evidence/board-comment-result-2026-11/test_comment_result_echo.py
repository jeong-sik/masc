"""Checks the counting of comment_result_echo.py on small synthetic ledgers.

Run: python3 -m unittest discover -s docs/evidence/board-comment-result-2026-11
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

import comment_result_echo as echo  # noqa: E402

DAY = "2026-11-05"
DAY_START = echo.parse_instant(f"{DAY}T00:00:00").timestamp()
POST = "p-0123456789abcdef0123456789abcdef"
OTHER_POST = "p-fedcba9876543210fedcba9876543210"
TEXT = "A comment long enough to count: " + "word " * 20
SHORT = "ok"


def comment_row(
    offset_s: float,
    *,
    keeper: str = "a",
    text: str | None = TEXT,
    post: str = POST,
    answer: str | None = None,
    disposition: str = "completed",
    field: str = "content",
) -> dict[str, object]:
    written = {field: text} if text is not None else {}
    reply = answer if answer is not None else json.dumps({"id": "c-1", "post_id": post, "content": text})
    return {
        "record_kind": "tool_call",
        "ts": DAY_START + offset_s,
        "keeper": keeper,
        "tool": echo.COMMENT_TOOL,
        "input": {"post_id": post, **written},
        "output": reply,
        "disposition": disposition,
    }


def get_row(offset_s: float, *, keeper: str = "a", post: str = POST) -> dict[str, object]:
    return {
        "record_kind": "tool_call",
        "ts": DAY_START + offset_s,
        "keeper": keeper,
        "tool": echo.POST_GET_TOOL,
        "input": {"post_id": post},
        "output": "page",
        "disposition": "completed",
    }


def other_row(offset_s: float, *, keeper: str = "a") -> dict[str, object]:
    return {
        "record_kind": "tool_call",
        "ts": DAY_START + offset_s,
        "keeper": keeper,
        "tool": "Execute",
        "input": {"command": "ls"},
        "output": "{}",
        "disposition": "completed",
    }


def measure(
    rows: list[dict[str, object]],
    reread_s: float = 60.0,
    file_names: tuple[str, ...] = (f"{DAY[8:]}.jsonl",),
) -> dict[str, object]:
    """Write the rows into the ledger file(s), one row to each name in turn, and measure the day."""
    with tempfile.TemporaryDirectory() as base:
        folder = pathlib.Path(base) / ".masc" / "tool_calls" / DAY[:7]
        folder.mkdir(parents=True)
        for position, name in enumerate(file_names):
            share = rows[position :: len(file_names)]
            (folder / name).write_text("\n".join(json.dumps(r) for r in share) + "\n", encoding="utf-8")
        since = echo.parse_instant(f"{DAY}T00:00:00")
        end = since + datetime.timedelta(days=1)
        return echo.measure(pathlib.Path(base), since, end, reread_s)


def number(result: dict[str, object], key: str) -> int:
    return cast("int", result[key])


class RepeatedText(unittest.TestCase):
    def test_an_answer_that_holds_the_text_repeats_it(self) -> None:
        result = measure([comment_row(0)])
        self.assertEqual(number(result, "successful_calls"), 1)
        self.assertEqual(number(result, "calls_repeating_text"), 1)
        self.assertEqual(number(result, "repeated_text_bytes"), len(echo.escaped(TEXT).encode("utf-8")))
        share = cast("float", result["repeated_text_share"])
        self.assertGreater(share, 0.5)
        self.assertLess(share, 1.0)

    def test_an_answer_without_the_text_repeats_nothing(self) -> None:
        answer = json.dumps({"id": "c-1", "post_id": POST, "comment_offset": 3})
        result = measure([comment_row(0, answer=answer)])
        self.assertEqual(number(result, "calls_repeating_text"), 0)
        self.assertEqual(number(result, "repeated_text_bytes"), 0)
        self.assertEqual(result["repeated_text_share"], 0.0)

    def test_the_body_member_is_the_written_text(self) -> None:
        answer = json.dumps({"id": "c-1", "content": TEXT})
        result = measure([comment_row(0, answer=answer, field="body")])
        self.assertEqual(number(result, "calls_repeating_text"), 1)

    def test_body_wins_over_content_when_an_input_has_both(self) -> None:
        # The tool reads `body` first, so the stored text, and the one an answer could repeat, is the body.
        row = comment_row(0, answer=json.dumps({"id": "c-1", "content": TEXT}), field="body")
        row["input"] = {"post_id": POST, "body": TEXT, "content": "A different text that is also longer than forty bytes"}
        self.assertEqual(number(measure([row]), "calls_repeating_text"), 1)

    def test_a_text_with_quotes_and_newlines_is_matched_as_json_content(self) -> None:
        text = 'He said "stop"\nand left, and the line goes on for a while longer than forty bytes'
        result = measure([comment_row(0, text=text)])
        self.assertEqual(number(result, "calls_repeating_text"), 1)

    def test_a_text_below_the_minimum_is_not_a_repeat(self) -> None:
        result = measure([comment_row(0, text=SHORT, answer=json.dumps({"id": "c-1", "post_id": POST, "content": SHORT}))])
        self.assertEqual(number(result, "calls_repeating_text"), 0)

    def test_a_call_with_no_text_in_its_input_repeats_nothing(self) -> None:
        result = measure([comment_row(0, text=None, answer=json.dumps({"id": "c-1"}))])
        self.assertEqual(number(result, "successful_calls"), 1)
        self.assertEqual(number(result, "calls_repeating_text"), 0)


class WhichCallsCount(unittest.TestCase):
    def test_a_failed_call_is_counted_apart(self) -> None:
        result = measure([comment_row(0, disposition="failed")])
        self.assertEqual(number(result, "successful_calls"), 0)
        self.assertEqual(number(result, "failed_calls"), 1)

    def test_an_argument_refusal_is_counted_apart(self) -> None:
        refusal = 'Your call to "masc_board_comment":\n{"_blob":{}}\n\nErrors (fix these and call again):\n  "post_id": MISSING'
        result = measure([comment_row(0, answer=refusal, disposition="completed")])
        self.assertEqual(number(result, "successful_calls"), 0)
        self.assertEqual(number(result, "refused_calls"), 1)

    def test_an_answer_cut_short_is_counted(self) -> None:
        cut = json.dumps({"id": "c-1", "content": TEXT[:30], "_truncated": True})
        result = measure([comment_row(0, answer=cut), comment_row(10)])
        self.assertEqual(number(result, "answers_cut_short"), 1)

    def test_calls_outside_the_span_are_left_out(self) -> None:
        rows = [comment_row(-5), comment_row(86_400 + 5), comment_row(100)]
        self.assertEqual(number(measure(rows), "successful_calls"), 1)

    def test_other_tools_are_not_comment_calls(self) -> None:
        self.assertEqual(number(measure([other_row(0)]), "successful_calls"), 0)

    def test_rotated_ledger_files_are_read_and_other_days_are_not(self) -> None:
        # The ledger rotates a day into `DD.NNN.jsonl` files; the day is the first two digits.
        rows = [comment_row(10), comment_row(20), comment_row(30)]
        names = ("05.jsonl", "05.001.jsonl", "05.002.jsonl")
        self.assertEqual(number(measure(rows, file_names=names), "successful_calls"), 3)
        # A span ending at midnight still touches the next day's files, so the day left out is the one before.
        self.assertEqual(number(measure(rows, file_names=("04.jsonl", "04.001.jsonl", "04.002.jsonl")), "successful_calls"), 0)


class ReadAfterWrite(unittest.TestCase):
    def test_the_next_call_reading_the_same_post_soon_counts(self) -> None:
        result = measure([comment_row(0), get_row(20)])
        self.assertEqual(cast("dict[str, object]", result["read_after_write"])["calls"], 1)

    def test_a_read_after_the_limit_does_not_count(self) -> None:
        result = measure([comment_row(0), get_row(61)])
        self.assertEqual(cast("dict[str, object]", result["read_after_write"])["calls"], 0)

    def test_a_read_of_another_post_does_not_count(self) -> None:
        result = measure([comment_row(0), get_row(5, post=OTHER_POST)])
        self.assertEqual(cast("dict[str, object]", result["read_after_write"])["calls"], 0)

    def test_a_read_by_another_keeper_does_not_count(self) -> None:
        result = measure([comment_row(0), get_row(5, keeper="b")])
        self.assertEqual(cast("dict[str, object]", result["read_after_write"])["calls"], 0)

    def test_only_the_very_next_call_counts(self) -> None:
        result = measure([comment_row(0), other_row(3), get_row(6)])
        self.assertEqual(cast("dict[str, object]", result["read_after_write"])["calls"], 0)

    def test_the_share_is_over_the_successful_calls(self) -> None:
        rows = [comment_row(0), get_row(5), comment_row(100), other_row(105)]
        share = cast("dict[str, object]", measure(rows)["read_after_write"])["share"]
        self.assertEqual(share, 0.5)


class EmptyWindow(unittest.TestCase):
    def test_no_calls_gives_no_shares(self) -> None:
        result = measure([other_row(0)])
        self.assertIsNone(result["repeated_text_share"])
        self.assertIsNone(result["answer_bytes_median"])
        self.assertIsNone(cast("dict[str, object]", result["read_after_write"])["share"])


if __name__ == "__main__":
    unittest.main()
