"""Tests for store_vs_ledger.py on a synthetic ledger and a synthetic metrics store.

Run: python3 -I docs/evidence/tool-metrics-refused-calls-2026-11/test_store_vs_ledger.py
"""

from __future__ import annotations

import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import store_vs_ledger as sut  # noqa: E402

DAY2 = sut.parse_utc("2026-11-02T00:00:00Z")
DAY3 = sut.parse_utc("2026-11-03T00:00:00Z")
DAY4 = sut.parse_utc("2026-11-04T00:00:00Z")
REFUSAL = 'Your call to "Read":\n{}\n\nErrors (fix these and call again):\n  "file_path": MISSING (required: string)'

SCHEMA = (
    "CREATE TABLE tool_metric_events (record_id TEXT PRIMARY KEY NOT NULL, ts REAL NOT NULL,"
    " tool_name TEXT NOT NULL, disposition TEXT NOT NULL, duration_ms REAL NOT NULL)"
)


def ledger_row(ts: float, tool: str, output: object = "ok", disposition: str | None = "completed", kind: str = "tool_call") -> str:
    row: dict[str, object] = {"record_kind": kind, "ts": ts, "tool": tool, "output": output}
    if disposition is not None:
        row["disposition"] = disposition
    return json.dumps(row)


class Fixture:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.tmp.name)
        self.ledger_dir = self.base / ".masc" / "tool_calls" / "2026-11"
        self.ledger_dir.mkdir(parents=True)
        self.store_path = self.base / ".masc" / "tool-metrics.sqlite3"
        with sqlite3.connect(self.store_path) as connection:
            connection.execute(SCHEMA)

    def write_ledger(self, name: str, rows: list[str]) -> None:
        (self.ledger_dir / name).write_text("\n".join(rows) + "\n", encoding="utf-8")

    def add_store(self, ts: float, tool: str, disposition: str = "completed") -> None:
        with sqlite3.connect(self.store_path) as connection:
            count = connection.execute("SELECT count(*) FROM tool_metric_events").fetchone()[0]
            connection.execute(
                "INSERT INTO tool_metric_events VALUES (?, ?, ?, ?, 1.0)", (f"id-{count}", ts, tool, disposition)
            )

    def report(self, since: float = DAY2, end: float = DAY4) -> dict[str, object]:
        with sut.open_store(self.base) as connection:
            return sut.compare(sut.read_ledger(self.base, since, end), sut.read_store(connection, since, end))

    def close(self) -> None:
        self.tmp.cleanup()


class StoreVsLedgerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = Fixture()
        self.addCleanup(self.fx.close)

    def tool(self, report: dict[str, object], name: str) -> dict[str, int]:
        return next(row for row in report["tools"] if row["tool"] == name)  # type: ignore[index]

    def test_a_refusal_is_the_whole_gap_when_the_store_lacks_exactly_the_refused_calls(self) -> None:
        self.fx.write_ledger("02.jsonl", [
            ledger_row(DAY2 + 10, "Read"),
            ledger_row(DAY2 + 20, "Read", output=REFUSAL, disposition=None),
            ledger_row(DAY2 + 30, "Read"),
        ])
        self.fx.add_store(DAY2 + 11, "tool_read_file")
        self.fx.add_store(DAY2 + 31, "tool_read_file")
        report = self.fx.report()
        row = self.tool(report, "tool_read_file")
        self.assertEqual((row["ledger_calls"], row["ledger_refused"], row["store_calls"]), (3, 1, 2))
        self.assertEqual((row["gap"], row["gap_minus_refused"]), (1, 0))
        self.assertEqual(report["tools_where_refusals_are_the_whole_gap"], ["tool_read_file"])

    def test_after_the_change_the_refused_call_is_in_the_store_and_the_gap_is_zero(self) -> None:
        self.fx.write_ledger("02.jsonl", [
            ledger_row(DAY2 + 10, "Read"),
            ledger_row(DAY2 + 20, "Read", output=REFUSAL, disposition=None),
        ])
        self.fx.add_store(DAY2 + 11, "tool_read_file")
        self.fx.add_store(DAY2 + 21, "tool_read_file", disposition="failed")
        totals = self.fx.report()["totals"]
        self.assertEqual((totals["gap"], totals["store_failed"]), (0, 1))  # type: ignore[index]

    def test_only_a_string_output_with_the_refusal_prefix_and_no_disposition_counts(self) -> None:
        self.fx.write_ledger("02.jsonl", [
            ledger_row(DAY2 + 1, "Read", output=REFUSAL, disposition="failed"),
            ledger_row(DAY2 + 2, "Read", output={"text": REFUSAL}, disposition=None),
            ledger_row(DAY2 + 3, "Read", output="Tool 'Read' failed: " + REFUSAL, disposition=None),
            ledger_row(DAY2 + 4, "Read", output=REFUSAL, disposition=None),
        ])
        self.fx.add_store(DAY2 + 5, "tool_read_file")
        refused = self.fx.report()["totals"]["ledger_refused"]  # type: ignore[index]
        self.assertEqual(refused, 1)

    def test_days_are_utc_and_the_window_is_half_open(self) -> None:
        self.fx.write_ledger("02.jsonl", [
            ledger_row(DAY3 - 1, "masc_status"),
            ledger_row(DAY3, "masc_status"),
            ledger_row(DAY4, "masc_status"),
        ])
        self.fx.add_store(DAY3 - 1, "masc_status")
        self.fx.add_store(DAY3, "masc_status")
        report = self.fx.report(DAY2, DAY4)
        days = {row["day"]: row["ledger_calls"] for row in report["days"]}  # type: ignore[index]
        self.assertEqual(days, {"2026-11-02": 1, "2026-11-03": 1})
        self.assertEqual(report["totals"]["store_calls"], 2)  # type: ignore[index]

    def test_ledger_rotation_files_are_read_and_other_files_are_not(self) -> None:
        self.fx.write_ledger("02.jsonl", [ledger_row(DAY2 + 1, "masc_status")])
        self.fx.write_ledger("02.001.jsonl", [ledger_row(DAY2 + 2, "masc_status")])
        self.fx.write_ledger("02.jsonl.bak", [ledger_row(DAY2 + 3, "masc_status")])
        self.fx.write_ledger("notes.jsonl", [ledger_row(DAY2 + 4, "masc_status")])
        self.fx.add_store(DAY2 + 1, "masc_status")
        self.assertEqual(self.fx.report()["totals"]["ledger_calls"], 2)  # type: ignore[index]

    def test_rows_that_are_not_tool_calls_or_not_json_are_skipped(self) -> None:
        self.fx.write_ledger("02.jsonl", [
            ledger_row(DAY2 + 1, "masc_status", kind="turn"),
            "not json but mentions tool_call",
            json.dumps({"record_kind": "tool_call", "ts": "yesterday", "tool": "masc_status"}),
            ledger_row(DAY2 + 2, "masc_status"),
        ])
        self.fx.add_store(DAY2 + 2, "masc_status")
        self.assertEqual(self.fx.report()["totals"]["ledger_calls"], 1)  # type: ignore[index]

    def test_a_ledger_tool_the_store_never_saw_is_listed_not_dropped(self) -> None:
        self.fx.write_ledger("02.jsonl", [ledger_row(DAY2 + 1, "keeper_skill"), ledger_row(DAY2 + 2, "keeper_skill")])
        self.fx.add_store(DAY2 + 2, "masc_status")
        report = self.fx.report()
        self.assertEqual(report["unmapped_ledger_tools"], {"keeper_skill": 2})
        self.assertEqual(report["tools_compared"], 0)

    def test_a_store_that_holds_more_than_the_ledger_gives_a_negative_residual(self) -> None:
        self.fx.write_ledger("02.jsonl", [ledger_row(DAY2 + 1, "masc_board_comment"), ledger_row(DAY2 + 2, "masc_board_comment", output=REFUSAL, disposition=None)])
        for offset in (3, 4, 5):
            self.fx.add_store(DAY2 + offset, "masc_board_comment")
        row = self.tool(self.fx.report(), "masc_board_comment")
        self.assertEqual((row["gap"], row["gap_minus_refused"]), (-1, -2))
        self.assertEqual(self.fx.report()["tools_where_refusals_are_the_whole_gap"], [])

    def test_the_store_connection_cannot_write(self) -> None:
        with sut.open_store(self.fx.base) as connection:
            with self.assertRaises(sqlite3.OperationalError):
                connection.execute("DELETE FROM tool_metric_events")

    def test_a_missing_store_is_an_error_naming_the_path(self) -> None:
        self.fx.store_path.unlink()
        with self.assertRaises(SystemExit) as raised:
            sut.open_store(self.fx.base)
        self.assertIn("tool-metrics.sqlite3", str(raised.exception))

    def test_a_time_without_an_offset_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            sut.parse_utc("2026-11-02T00:00:00")

    def test_the_literal_name_pairs_match_the_descriptor_source(self) -> None:
        source = pathlib.Path(__file__).resolve().parents[3] / "lib" / "keeper" / "keeper_tool_descriptor.ml"
        if not source.is_file():
            self.skipTest("descriptor source not next to this script")
        text = source.read_text(encoding="utf-8")
        for public, internal in [(p, i) for p, i in sut.PUBLIC_TO_STORE.items() if i.startswith("tool_")]:
            self.assertIn(f'~public_name:"{public}"\n      ~internal_name:"{internal}"', text)


if __name__ == "__main__":
    unittest.main()
