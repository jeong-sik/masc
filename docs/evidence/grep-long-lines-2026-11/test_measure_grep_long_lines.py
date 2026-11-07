"""Checks measure_grep_long_lines.py on small synthetic ledgers and blobs.

Run: python3 -m unittest discover -s docs/evidence/grep-long-lines-2026-11
"""

from __future__ import annotations

import datetime
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_grep_long_lines as grep_lines  # noqa: E402

UTC = datetime.timezone.utc
CAP = 2_000
BUDGET = 32_000


def at(day: int, hour: int = 0) -> float:
    return datetime.datetime(2026, 11, day, hour, tzinfo=UTC).timestamp()


def result_json(matches: list[str], extra: dict[str, object] | None = None) -> str:
    fields: dict[str, object] = {"ok": True, "op": "rg", "path": "/w", "pattern": "p", "via": "remote_ssh", "status": {"kind": "exit", "code": 0}, "matches": matches}
    fields.update(extra or {})
    return json.dumps(fields, ensure_ascii=False, separators=(",", ":"))


class Fixture:
    """A temporary base path with one ledger file and the blobs its rows point at."""

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.rows: list[str] = []

    def blob(self, text: str) -> dict[str, object]:
        sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
        folder = self.root / ".masc" / "tool_blobs" / sha[:2]
        folder.mkdir(parents=True, exist_ok=True)
        (folder / sha).write_text(text, encoding="utf-8")
        return {"_blob": {"sha256": sha, "bytes": len(text.encode("utf-8"))}}

    def add(self, stamp: float, output: object, size: int, tool: str = "Grep", keeper: str = "k") -> None:
        self.rows.append(json.dumps({"ts": stamp, "record_kind": "tool_call", "tool": tool, "keeper": keeper, "output": output, "result_bytes": size}))

    def summary(self, since: float, until: float) -> dict[str, object]:
        folder = self.root / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "07.jsonl").write_text("\n".join(self.rows) + "\n", encoding="utf-8")
        start = datetime.datetime.fromtimestamp(since, UTC)
        end = datetime.datetime.fromtimestamp(until, UTC)
        calls = grep_lines.read_calls(grep_lines.ledger_files(self.root, start, end), since, until, self.root / ".masc" / "tool_blobs")
        return grep_lines.summarize(calls, CAP, BUDGET)


def section(summary: dict[str, object], key: str) -> dict[str, int]:
    return cast("dict[str, int]", summary[key])


class CutTest(unittest.TestCase):
    """The same cases as the OCaml tests of `cut_to_bytes` and `lines_to_json`."""

    def test_a_text_that_fits_is_kept(self) -> None:
        self.assertEqual(grep_lines.cut_to_bytes("abc", 3), "abc")

    def test_one_byte_over_is_cut_and_counted(self) -> None:
        self.assertEqual(grep_lines.cut_to_bytes("abcd", 3), "abc...[cut: 3 of 4 bytes kept]")

    def test_a_line_of_300000_bytes_keeps_2000(self) -> None:
        self.assertEqual(grep_lines.cut_to_bytes("x" * 300_000, CAP), "x" * CAP + "...[cut: 2000 of 300000 bytes kept]")

    def test_a_cut_inside_a_character_steps_back(self) -> None:
        self.assertEqual(grep_lines.cut_to_bytes("가" * 100, 100), "가" * 33 + "...[cut: 99 of 300 bytes kept]")


class MeasureTest(unittest.TestCase):
    def test_a_long_line_in_a_blob_is_counted_and_shrinks_the_result(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(pathlib.Path(tmp))
            text = result_json(["/w/a.json:1:" + "x" * 300_000, "/w/b.ml:3:short"])
            fixture.add(at(7, 1), fixture.blob(text), len(text.encode("utf-8")))
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["calls"], 1)
        self.assertEqual(summary["lines_above_cap"], 1)
        self.assertEqual(summary["files_of_lines_above_cap"], {"/w/a.json": 1})
        self.assertEqual(section(summary, "line_cut")["calls"], 1)
        self.assertEqual(section(summary, "above_ceiling_before")["65536"], {"calls": 1, "bytes": len(text.encode("utf-8"))})
        self.assertEqual(section(summary, "above_ceiling_after_lower_bound")["16384"], {"calls": 0, "bytes": 0})
        self.assertEqual(summary["reserialized_size_equals_result_bytes"], 1)

    def test_the_omission_note_is_not_a_matched_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(pathlib.Path(tmp))
            text = result_json(["a", "...[5 more lines omitted - narrow]"])
            fixture.add(at(7, 1), text, len(text))
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["matched_lines"], 1)

    def test_a_cut_inline_excerpt_is_unreadable_and_adds_no_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(pathlib.Path(tmp))
            text = result_json(["a" * 5_000], {"_truncated": True})
            fixture.add(at(7, 1), text, 50_000)
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["unreadable"], {"cut_excerpt": 1})
        self.assertEqual(summary["matched_lines"], 0)

    def test_a_failed_result_cuts_error_detail_and_ignores_the_failure_note(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(pathlib.Path(tmp))
            text = result_json([], {"ok": False, "error_detail": "line of text\n" * 50_000}) + "\nfailure_class=runtime_failure"
            fixture.add(at(7, 1), fixture.blob(text), len(text.encode("utf-8")))
            summary = fixture.summary(at(7), at(8))
        detail = section(summary, "error_detail_cut")
        self.assertEqual(detail["calls"], 1)
        self.assertLess(detail["bytes_after"], 40_000)
        self.assertEqual(section(summary, "line_cut")["calls"], 0)

    def test_rows_outside_the_window_or_of_another_tool_are_left_out(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(pathlib.Path(tmp))
            text = result_json(["a"])
            fixture.add(at(6, 23), text, len(text), keeper="before")
            fixture.add(at(7, 1), text, len(text), tool="Read")
            fixture.add(at(7, 2), text, len(text), keeper="inside")
            fixture.add(at(8, 0), text, len(text), keeper="after")
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["calls"], 1)
        self.assertEqual(summary["matched_lines"], 1)

    def test_a_missing_blob_is_counted_not_fatal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(pathlib.Path(tmp))
            fixture.add(at(7, 1), {"_blob": {"sha256": "ab" + "0" * 62}}, 99_999)
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["unreadable"], {"blob_missing": 1})
        self.assertEqual(section(summary, "above_ceiling_before")["65536"], {"calls": 1, "bytes": 99_999})
        self.assertEqual(section(summary, "above_ceiling_after_lower_bound")["65536"], {"calls": 1, "bytes": 99_999})


if __name__ == "__main__":
    unittest.main()
