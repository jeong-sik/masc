"""Checks the arithmetic of measure_dos_screen_trim.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/tool-result-carry-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_dos_screen_trim as trim_tool  # noqa: E402
import measure_tool_result_carry as carry_tool  # noqa: E402
import test_measure_tool_result_carry as fixtures  # noqa: E402

BLANK_PAGE = (" " * 80 + "\n") * 25
# Bytes of the blank page inside a request body: 25 rows of 80 spaces and an escaped newline
# (`\n`, 2 characters). The result text holds it as a JSON string (+2 quotes), and the message
# holds that text as a JSON string again: each quote and each backslash gets one more
# backslash. 25 * 82 + 2 = 2,052, plus 2 for the quotes and 25 for the backslashes, 2,079.
BLANK_PAGE_BYTES = 2079
# The trimmed page is "", which is `""` in the result text and `\"\"` in the message.
EMPTY_PAGE_BYTES = 4
SMALL_PAGE = "HI\n"
SMALL_PAGE_BYTES = 9
SMALL_TRIMMED = "HI"
SMALL_TRIMMED_BYTES = 6
DAY_1 = fixtures.DAY_1
DAY_2 = fixtures.DAY_2


def observation(page: object = BLANK_PAGE, mode: object = "12h", files: object = ("A.COM",), **extra: object) -> str:
    document: dict[str, object] = {"steps": 1, "video_mode": mode, "screen_text": page, "files": files}
    document.update(extra)
    return fixtures.compact(document)


def dos_block(use_id: object, as_list: bool = True, **fields: object) -> dict[str, object]:
    text = observation(**fields)
    content: object = [{"type": "text", "text": text}] if as_list else text
    return fixtures.result_block(use_id, content)


class TrimTextPageTest(unittest.TestCase):
    def test_trailing_spaces_of_each_row_and_trailing_empty_rows_go(self) -> None:
        self.assertEqual(trim_tool.trim_text_page("HI   \nOK  \n\n   \n"), "HI\nOK")

    def test_a_blank_page_becomes_empty(self) -> None:
        self.assertEqual(trim_tool.trim_text_page(BLANK_PAGE), "")
        self.assertEqual(trim_tool.trim_text_page(""), "")

    def test_rows_keep_their_position(self) -> None:
        self.assertEqual(trim_tool.trim_text_page("\n\nTOP  \n   \nEND  \n\n"), "\n\nTOP\n\nEND")

    def test_leading_and_inner_spaces_stay(self) -> None:
        self.assertEqual(trim_tool.trim_text_page("  a  b  \n"), "  a  b")

    def test_a_page_without_a_final_newline(self) -> None:
        self.assertEqual(trim_tool.trim_text_page("a  \nb   "), "a\nb")

    def test_only_the_space_character_is_padding(self) -> None:
        self.assertEqual(trim_tool.trim_text_page("a\t\nb\u00a0\nc\r\n"), "a\t\nb\u00a0\nc\r")
        self.assertEqual(trim_tool.trim_text_page("a\n\t\n"), "a\n\t")
        self.assertEqual(trim_tool.trim_text_page("a\n\u00a0\n"), "a\n\u00a0")

    def test_box_drawing_characters_stay(self) -> None:
        page = "\u2554\u2550\u2557  \n\u2551HI\u2551 \n"
        self.assertEqual(trim_tool.trim_text_page(page), "\u2554\u2550\u2557\n\u2551HI\u2551")

    def test_trimming_twice_changes_nothing(self) -> None:
        for page in (BLANK_PAGE, SMALL_PAGE, "a  \n\nb \n  \n", "  \n x\n"):
            with self.subTest(page=page):
                once = trim_tool.trim_text_page(page)
                self.assertEqual(trim_tool.trim_text_page(once), once)


class MeasurePageTest(unittest.TestCase):
    def test_the_blank_page_costs_what_the_escaping_makes_of_it(self) -> None:
        page = trim_tool.measure_page(BLANK_PAGE)
        self.assertEqual((page.bytes, page.trimmed_bytes), (BLANK_PAGE_BYTES, EMPTY_PAGE_BYTES))
        self.assertTrue(page.blank)
        self.assertFalse(page.changed)

    def test_a_page_with_text_is_not_blank(self) -> None:
        page = trim_tool.measure_page(SMALL_PAGE)
        self.assertEqual((page.bytes, page.trimmed_bytes), (SMALL_PAGE_BYTES, SMALL_TRIMMED_BYTES))
        self.assertFalse(page.blank)

    def test_bytes_are_utf8_bytes(self) -> None:
        self.assertEqual(trim_tool.measure_page("\u00e9").bytes, trim_tool.measure_page("e").bytes + 1)

    def test_a_character_other_than_a_space_or_newline_makes_the_blank_flag_false(self) -> None:
        self.assertFalse(trim_tool.measure_page(" \t \n").blank)
        self.assertFalse(trim_tool.measure_page(" \u00a0 ").blank)

    def test_a_trim_that_loses_a_character_is_flagged(self) -> None:
        with mock.patch.object(trim_tool, "trim_text_page", lambda page: page[:1]):
            self.assertTrue(trim_tool.measure_page("ab").changed)


class PercentTest(unittest.TestCase):
    def test_a_share_is_part_over_whole(self) -> None:
        self.assertEqual(trim_tool._pct(1, 4), 25.0)
        self.assertEqual(trim_tool._pct(3, 3), 100.0)

    def test_a_share_of_nothing_is_zero(self) -> None:
        self.assertEqual(trim_tool._pct(5, 0), 0.0)


class InspectMessageTest(unittest.TestCase):
    def inspect(self, *blocks: object) -> list[trim_tool.DosResult]:
        message = fixtures.tool_message(*blocks)  # type: ignore[arg-type]
        return trim_tool.inspect_message(fixtures.compact(message).encode("utf-8"))

    def test_a_result_text_in_a_block_list_is_read(self) -> None:
        (found,) = self.inspect(dos_block("u1", page=SMALL_PAGE))
        self.assertEqual(found.tool_use_id, "u1")
        self.assertEqual((found.page.bytes, found.page.trimmed_bytes), (SMALL_PAGE_BYTES, SMALL_TRIMMED_BYTES))

    def test_the_first_part_with_a_string_text_is_the_result_text(self) -> None:
        content = [{"type": "image", "source": {}}, {"type": "text", "text": observation(page=SMALL_PAGE)}]
        (found,) = self.inspect(fixtures.result_block("u1", content))
        self.assertEqual(found.page.bytes, SMALL_PAGE_BYTES)
        content = [{"type": "text", "text": 5}, {"type": "text", "text": observation(page=SMALL_PAGE)}]
        (again,) = self.inspect(fixtures.result_block("u1", content))
        self.assertEqual(again.page.bytes, SMALL_PAGE_BYTES)

    def test_a_result_text_that_is_a_string_is_read(self) -> None:
        (found,) = self.inspect(dos_block("u1", as_list=False, page=SMALL_PAGE))
        self.assertEqual(found.page.bytes, SMALL_PAGE_BYTES)

    def test_content_bytes_are_utf8_bytes(self) -> None:
        text = observation(page="\u2554\u2550\u2557")
        content = [{"type": "text", "text": text}]
        (found,) = self.inspect(fixtures.result_block("u1", content))
        self.assertEqual(found.content_bytes, fixtures.size_of(content))
        self.assertGreater(found.content_bytes, len(fixtures.compact(content)))

    def test_content_bytes_do_not_count_the_stored_copy(self) -> None:
        text = observation()
        content = [{"type": "text", "text": text}]
        plain = fixtures.result_block("u1", content)
        with_copy = fixtures.result_block("u1", content, text_content=text)
        (a,) = self.inspect(plain)
        (b,) = self.inspect(with_copy)
        self.assertEqual(a.content_bytes, fixtures.size_of(content))
        self.assertEqual(b.content_bytes, a.content_bytes)

    def test_only_a_json_object_with_a_string_page_counts(self) -> None:
        block = fixtures.result_block
        not_results = [
            block("a", "not json"),
            block("b", "[1,2]"),
            block("c", fixtures.compact({"steps": 1})),
            block("d", fixtures.compact({"screen_text": 7})),
            block("e", [{"type": "image", "source": {}}]),
            block("f", 5),
            {"type": "text", "text": observation()},
            {"type": "other", "tool_use_id": "g", "content": [{"type": "text", "text": observation()}]},
            "not a block",
        ]
        self.assertEqual(self.inspect(*not_results), [])

    def test_a_message_without_blocks_has_no_results(self) -> None:
        raw = fixtures.compact({"role": "tool"}).encode("utf-8")
        self.assertEqual(trim_tool.inspect_message(raw), [])

    def test_the_video_mode_defaults_when_it_is_missing_or_not_a_string(self) -> None:
        (missing,) = self.inspect(fixtures.result_block("u1", fixtures.compact({"screen_text": "x"})))
        (number,) = self.inspect(dos_block("u2", mode=18))
        self.assertEqual((missing.video_mode, number.video_mode), (trim_tool.NO_MODE, trim_tool.NO_MODE))
        (named,) = self.inspect(dos_block("u3", mode="03h"))
        self.assertEqual(named.video_mode, "03h")

    def test_the_files_list_is_measured_when_it_is_a_list(self) -> None:
        (listed,) = self.inspect(dos_block("u1", files=["A.COM", "B.DAT"]))
        self.assertEqual(listed.files_key, '["A.COM","B.DAT"]')
        self.assertEqual(listed.files_bytes, len(json.dumps('["A.COM","B.DAT"]')) - 2)
        (absent,) = self.inspect(fixtures.result_block("u2", fixtures.compact({"screen_text": ""})))
        (not_a_list,) = self.inspect(dos_block("u3", files="A.COM"))
        self.assertEqual((absent.files_key, absent.files_bytes), (None, 0))
        self.assertEqual((not_a_list.files_key, not_a_list.files_bytes), (None, 0))

    def test_a_tool_use_id_that_is_not_a_string_is_kept_as_none(self) -> None:
        (found,) = self.inspect(dos_block(7))
        self.assertIsNone(found.tool_use_id)

    def test_a_blob_that_is_not_a_message_raises_value_error(self) -> None:
        for raw in (b"[1]", b"not json", b"\xff\xfe"):
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):
                    trim_tool.inspect_message(raw)


class SummaryTest(fixtures.TempStoreCase):
    def run_trim(self, from_day: str = DAY_1, to_day: str = DAY_2) -> tuple[carry_tool.Carried, trim_tool.Summary, carry_tool.Skipped]:
        carried, skipped = self.read(from_day, to_day)
        names = carry_tool.read_tool_names(self.masc_dir, from_day, to_day, skipped)
        return carried, trim_tool.summarize(self.masc_dir, carried, names, skipped), skipped

    def dos_ledger(self, *pairs: tuple[str, str]) -> None:
        self.store.ledger(DAY_1, [fixtures.ledger_row(tool, use_id) for tool, use_id in pairs])

    def test_a_result_is_counted_once_and_carried_once_for_each_request(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1")))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a)), fixtures.request(fixtures.listing(a))])
        self.dos_ledger(("masc_dos_press", "u1"))
        _, summary, _ = self.run_trim()
        (row,) = summary.rows
        self.assertEqual((row.tool, row.results, row.carried_results), ("masc_dos_press", 1, 2))
        self.assertEqual(row.page_bytes, 2 * BLANK_PAGE_BYTES)
        self.assertEqual(row.trimmed_page_bytes, 2 * EMPTY_PAGE_BYTES)
        self.assertEqual(row.saved_bytes, 2 * (BLANK_PAGE_BYTES - EMPTY_PAGE_BYTES))
        self.assertEqual(summary.saved_bytes, row.saved_bytes)

    def test_content_bytes_and_files_bytes_are_carried(self) -> None:
        block = dos_block("u1", files=["A.COM"])
        a = self.store.blob(fixtures.tool_message(block))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))] * 3)
        self.dos_ledger(("masc_dos_screen", "u1"))
        _, summary, _ = self.run_trim()
        (row,) = summary.rows
        self.assertEqual(row.content_bytes, 3 * fixtures.size_of(block["content"]))
        self.assertEqual(row.files_bytes, 3 * (len(json.dumps('["A.COM"]')) - 2))
        self.assertEqual(summary.content_bytes, row.content_bytes)
        self.assertEqual(summary.files_bytes, row.files_bytes)
        self.assertEqual(summary.files_lists, 1)

    def test_only_tools_named_masc_dos_are_counted(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1"), dos_block("u2"), dos_block("u3"), call_id="c"))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.dos_ledger(("masc_dos_step", "u1"), ("masc_msx_screen", "u2"), ("other_masc_dos_step", "u3"))
        _, summary, _ = self.run_trim()
        self.assertEqual([row.tool for row in summary.rows], ["masc_dos_step"])
        self.assertEqual(summary.unattributed_pages, 0)

    def test_a_page_whose_tool_is_not_in_the_ledger_window_is_reported(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1"), dos_block(None), dos_block("u3")))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.dos_ledger(("masc_dos_step", "u3"))
        _, summary, _ = self.run_trim()
        self.assertEqual([row.tool for row in summary.rows], ["masc_dos_step"])
        self.assertEqual(summary.unattributed_pages, 2)

    def test_blank_pages_and_video_modes_are_counted_by_distinct_result(self) -> None:
        blank = dos_block("u1", mode="12h")
        text = dos_block("u2", mode="03h", page=SMALL_PAGE)
        other_blank = dos_block("u3", mode="12h")
        a = self.store.blob(fixtures.tool_message(blank, text, other_blank, call_id="c"))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))] * 2)
        self.dos_ledger(("masc_dos_press", "u1"), ("masc_dos_press", "u2"), ("masc_dos_press", "u3"))
        _, summary, _ = self.run_trim()
        self.assertEqual((summary.results, summary.blank_pages, summary.carried_results), (3, 2, 6))
        self.assertEqual(summary.video_modes, (("12h", 2, 2), ("03h", 1, 0)))

    def test_video_modes_with_the_same_count_are_listed_by_name(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1", mode="13h"), dos_block("u2", mode="03h"), call_id="c"))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.dos_ledger(("masc_dos_press", "u1"), ("masc_dos_press", "u2"))
        _, summary, _ = self.run_trim()
        self.assertEqual([mode for mode, _, _ in summary.video_modes], ["03h", "13h"])

    def test_a_lossy_trim_is_counted_in_changed_pages(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1", page=SMALL_PAGE)))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.dos_ledger(("masc_dos_press", "u1"))
        with mock.patch.object(trim_tool, "trim_text_page", lambda page: page[:1]):
            _, summary, _ = self.run_trim()
        self.assertEqual(summary.changed_pages, 1)
        _, honest, _ = self.run_trim()
        self.assertEqual(honest.changed_pages, 0)

    def test_distinct_files_lists_are_counted_once_each(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1", files=["A"]), dos_block("u2", files=["A"]), dos_block("u3", files=["B"]), call_id="c"))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.dos_ledger(("masc_dos_press", "u1"), ("masc_dos_press", "u2"), ("masc_dos_press", "u3"))
        _, summary, _ = self.run_trim()
        self.assertEqual(summary.files_lists, 2)

    def test_tools_are_listed_by_content_bytes_then_name(self) -> None:
        big = dos_block("u1", page=BLANK_PAGE)
        small_a = dos_block("u2", page="")
        small_b = dos_block("u3", page="")
        a = self.store.blob(fixtures.tool_message(big, small_b, small_a, call_id="c"))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.dos_ledger(("masc_dos_screen", "u1"), ("masc_dos_step", "u3"), ("masc_dos_press", "u2"))
        _, summary, _ = self.run_trim()
        self.assertEqual([row.tool for row in summary.rows], ["masc_dos_screen", "masc_dos_press", "masc_dos_step"])

    def test_unreadable_invalid_and_mismatched_blobs_are_reported(self) -> None:
        good = self.store.blob(fixtures.tool_message(dos_block("u1")))
        missing = ("e" * 64, 10)
        invalid = self.store.raw_blob(b"[1]")
        self.store.requests(
            "alpha",
            DAY_1,
            [fixtures.request(fixtures.listing(good, recorded=good[1] + 1), fixtures.listing(missing), fixtures.listing(invalid))],
        )
        self.dos_ledger(("masc_dos_press", "u1"))
        _, summary, skipped = self.run_trim()
        self.assertEqual((skipped.unreadable_blobs, skipped.invalid_blobs, skipped.size_disagreements), (1, 1, 1))
        self.assertEqual(summary.messages, 1)

    def test_a_request_outside_the_window_is_not_carried(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1")))
        self.store.requests("alpha", fixtures.OUTSIDE_DAY, [fixtures.request(fixtures.listing(a))])
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.dos_ledger(("masc_dos_press", "u1"))
        carried, summary, _ = self.run_trim()
        self.assertEqual((carried.requests, summary.carried_results), (1, 1))


class CommandLineTest(fixtures.TempStoreCase):
    def invoke(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = trim_tool.main(list(args))
            except SystemExit as exit_:
                code = int(exit_.code) if isinstance(exit_.code, int) else 1
        return code, out.getvalue(), err.getvalue()

    def populate(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1", files=["A"])))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a), body=10_000)] * 2)
        self.store.ledger(DAY_1, [fixtures.ledger_row("masc_dos_press", "u1")])

    def window(self) -> list[str]:
        return ["--base-path", str(self.store.base), "--from-date", DAY_1, "--to-date", DAY_2]

    def test_the_report_and_the_json_agree(self) -> None:
        self.populate()
        out_path = self.store.base / "result.json"
        code, out, _ = self.invoke(*self.window(), "--json-out", str(out_path))
        self.assertEqual(code, 0)
        payload = json.loads(out_path.read_text(encoding="utf-8"))
        saved = 2 * (BLANK_PAGE_BYTES - EMPTY_PAGE_BYTES)
        self.assertEqual(
            (payload["stored_requests"], payload["body_bytes"], payload["dos_results"], payload["dos_carried_results"]),
            (2, 20_000, 1, 2),
        )
        self.assertEqual((payload["page_bytes"], payload["saved_bytes"]), (2 * BLANK_PAGE_BYTES, saved))
        self.assertEqual(payload["blank_pages"], 1)
        self.assertEqual(payload["changed_pages"], 0)
        self.assertEqual(payload["files_distinct_lists"], 1)
        self.assertEqual(payload["tools"][0]["saved_bytes"], saved)
        self.assertEqual(payload["video_modes"], [{"video_mode": "12h", "results": 1, "blank_pages": 1}])
        self.assertEqual(payload["skipped"]["bad_lines"], 0)
        self.assertIn("masc_dos_press", out)
        self.assertIn(f"saved {saved / 1e9:.3f} GB", out)
        self.assertIn("skipped: none", out)

    def test_a_lossy_trim_shows_in_the_json(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1", page=SMALL_PAGE)))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.store.ledger(DAY_1, [fixtures.ledger_row("masc_dos_press", "u1")])
        out_path = self.store.base / "lossy.json"
        with mock.patch.object(trim_tool, "trim_text_page", lambda page: page[:1]):
            code, _, _ = self.invoke(*self.window(), "--json-out", str(out_path))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out_path.read_text(encoding="utf-8"))["changed_pages"], 1)

    def test_a_request_without_a_recorded_body_size_reports_zero_percent_of_body(self) -> None:
        a = self.store.blob(fixtures.tool_message(dos_block("u1")))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.store.ledger(DAY_1, [fixtures.ledger_row("masc_dos_press", "u1")])
        code, out, _ = self.invoke(*self.window())
        self.assertEqual(code, 0)
        self.assertIn("0.0% of body", out)

    def test_a_missing_directory_is_an_error(self) -> None:
        code, _, err = self.invoke("--base-path", str(self.store.base / "nowhere"), "--from-date", DAY_1, "--to-date", DAY_2)
        self.assertEqual(code, 2)
        self.assertIn("is not a directory", err)

    def test_a_window_without_stored_requests_is_an_error(self) -> None:
        (self.store.base / ".masc").mkdir()
        code, _, err = self.invoke(*self.window())
        self.assertEqual(code, 2)
        self.assertIn("no stored request", err)

    def test_a_window_without_a_dos_page_is_an_error(self) -> None:
        a = self.store.blob(fixtures.tool_message(fixtures.result_block("u1", "plain")))
        self.store.requests("alpha", DAY_1, [fixtures.request(fixtures.listing(a))])
        self.store.ledger(DAY_1, [fixtures.ledger_row("masc_dos_press", "u1")])
        code, _, err = self.invoke(*self.window())
        self.assertEqual(code, 2)
        self.assertIn("no DOS result", err)

    def test_a_reversed_window_and_bad_dates_are_refused(self) -> None:
        self.populate()
        for args, message in (
            (["--from-date", DAY_2, "--to-date", DAY_1], "is after"),
            (["--from-date", "2026-02-30", "--to-date", DAY_2], "is not a date"),
            (["--from-date", "20261101", "--to-date", DAY_2], "is not YYYY-MM-DD"),
            (["--from-date", DAY_1, "--to-date", "2099-12-31x"], "is not YYYY-MM-DD"),
        ):
            with self.subTest(args=args):
                code, _, err = self.invoke("--base-path", str(self.store.base), *args)
                self.assertEqual(code, 2)
                self.assertIn(message, err)


if __name__ == "__main__":
    unittest.main()
