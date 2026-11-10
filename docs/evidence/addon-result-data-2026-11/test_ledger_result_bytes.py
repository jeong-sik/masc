"""Tests for ledger_result_bytes.py: each case builds a small ledger in a temporary directory."""

import datetime
import json
import pathlib
import tempfile
import unittest

import ledger_result_bytes as lrb

DAY = datetime.datetime(2026, 11, 5, tzinfo=datetime.timezone.utc).timestamp()
SINCE, END = DAY, DAY + 86400


def row(tool, result_bytes, output="ok", ts=DAY + 10, kind="tool_call"):
    return {"record_kind": kind, "ts": ts, "tool": tool, "result_bytes": result_bytes, "output": output}


def blob(sha, size):
    return {"_blob": {"sha256": sha, "bytes": size, "mime": "text/plain", "preview": "{"}}


ENVELOPE = '{"_meta":{},"structuredContent":{"steps":1},"content":[{"type":"text","text":"{}"}]}'


class Ledger:
    def __init__(self, test):
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        self.base = pathlib.Path(self.dir.name)

    def write(self, month, name, rows):
        folder = self.base / ".masc" / "tool_calls" / month
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")


class CensusTest(unittest.TestCase):
    def census(self, ledger, since=SINCE, end=END):
        return lrb.census(ledger.base, since, end)

    def test_rows_and_bytes_add_up_per_tool(self):
        ledger = Ledger(self)
        ledger.write("2026-11", "05.jsonl", [row("Read", 100), row("Read", 50), row("Grep", 7)])
        tools = self.census(ledger)
        self.assertEqual((tools["Read"]["rows"], tools["Read"]["result_bytes"]), (2, 150))
        self.assertEqual((tools["Grep"]["rows"], tools["Grep"]["result_bytes"]), (1, 7))

    def test_a_blob_shared_by_two_rows_counts_its_bytes_once(self):
        ledger = Ledger(self)
        ledger.write("2026-11", "05.jsonl",
                     [row("S", 900, blob("aa", 900)), row("S", 900, blob("aa", 900)), row("S", 700, blob("bb", 700))])
        entry = self.census(ledger)["S"]
        self.assertEqual((entry["blob_rows"], len(entry["blobs"]), sum(entry["blobs"].values())), (3, 2, 1600))

    def test_only_a_string_output_with_structured_content_up_front_is_an_envelope(self):
        ledger = Ledger(self)
        late = "x" * lrb.ENVELOPE_PREFIX_CHARS + ENVELOPE
        ledger.write("2026-11", "05.jsonl",
                     [row("E", 1, ENVELOPE), row("E", 1, "plain"), row("E", 1, late), row("E", 1, {"structuredContent": 1})])
        self.assertEqual(self.census(ledger)["E"]["envelope_rows"], 1)

    def test_the_window_is_closed_at_since_and_open_at_end(self):
        ledger = Ledger(self)
        ledger.write("2026-11", "05.jsonl",
                     [row("W", 1, ts=SINCE), row("W", 2, ts=END - 1), row("W", 4, ts=END), row("W", 8, ts=SINCE - 1)])
        self.assertEqual(self.census(ledger)["W"]["result_bytes"], 3)

    def test_other_record_kinds_and_rows_without_result_bytes_are_skipped(self):
        ledger = Ledger(self)
        missing = row("K", 5)
        del missing["result_bytes"]
        ledger.write("2026-11", "05.jsonl", [row("K", 5, kind="tool_event"), missing, row("K", 3)])
        self.assertEqual(self.census(ledger)["K"]["rows"], 1)

    def test_rotated_files_and_both_months_of_a_window_are_read(self):
        ledger = Ledger(self)
        end_of_month = datetime.datetime(2026, 10, 31, 23, tzinfo=datetime.timezone.utc).timestamp()
        ledger.write("2026-10", "31.jsonl", [row("M", 1, ts=end_of_month)])
        ledger.write("2026-11", "01.jsonl", [row("M", 2, ts=end_of_month + 7200)])
        ledger.write("2026-11", "01.003.jsonl", [row("M", 4, ts=end_of_month + 7300)])
        tools = self.census(ledger, since=end_of_month - 1, end=end_of_month + 86400)
        self.assertEqual(tools["M"]["result_bytes"], 7)

    def test_unreadable_lines_are_skipped(self):
        ledger = Ledger(self)
        folder = ledger.base / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True)
        (folder / "05.jsonl").write_text('{"record_kind":"tool_call" broken\n' + json.dumps(row("B", 9)) + "\n")
        self.assertEqual(self.census(ledger)["B"]["rows"], 1)


class ReportTest(unittest.TestCase):
    def tools(self):
        entry = lambda b, blobs=None: {"rows": 2, "result_bytes": b, "blob_rows": len(blobs or {}),
                                       "blobs": blobs or {}, "envelope_rows": 1}
        return {"big": entry(900, {"a": 400, "b": 400}), "mid": entry(500), "small": entry(10)}

    def test_top_orders_by_result_bytes_and_named_tools_are_added(self):
        report = lrb.report(self.tools(), top=1, named={"small"})
        self.assertEqual([t["tool"] for t in report["tools"]], ["big", "small"])

    def test_totals_cover_every_tool_not_only_the_listed_ones(self):
        report = lrb.report(self.tools(), top=1, named=set())
        self.assertEqual(report["ledger"], {"rows": 6, "result_bytes": 1410})
        self.assertEqual(report["externalized"], {"rows": 2, "distinct_blob_bytes": 800})

    def test_a_tool_summary_reads_its_blobs_and_mean(self):
        big = lrb.report(self.tools(), top=3, named=set())["tools"][0]
        self.assertEqual((big["mean_result_bytes"], big["distinct_blobs"], big["blob_bytes"], big["envelope_rows"]),
                         (450, 2, 800, 1))


class WindowTest(unittest.TestCase):
    def test_utc_text_and_month_walk(self):
        self.assertEqual(lrb.parse_utc("2026-11-05T00:00:00Z"), DAY)
        since, end = lrb.parse_utc("2026-10-31T23:00:00Z"), lrb.parse_utc("2027-01-01T00:00:00Z")
        self.assertEqual(list(lrb.months_between(since, end)), ["2026-10", "2026-11", "2026-12", "2027-01"])


if __name__ == "__main__":
    unittest.main()
