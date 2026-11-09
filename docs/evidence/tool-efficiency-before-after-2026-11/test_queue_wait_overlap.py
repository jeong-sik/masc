"""Checks the counting of queue_wait_overlap.py on small synthetic calls and stores.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest
from collections import Counter

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_before_after as before_after  # noqa: E402
import queue_wait_overlap as overlap  # noqa: E402

DAY_START = before_after.parse_instant("2026-11-05T00:00:00").timestamp()
DAY_END = before_after.parse_instant("2026-11-06T00:00:00").timestamp()


def execute(end: float, duration_s: float, keeper: str = "a", tool: str = "Execute", failed: bool = False) -> before_after.Call:
    return before_after.Call(
        ts=end,
        tool=tool,
        keeper=keeper,
        duration_ms=duration_s * 1000,
        result_bytes=0,
        failed=failed,
        input_text="",
        output_text="",
        sandbox="remote_ssh",
    )


def holds_of(calls: list[before_after.Call], since: float = 0.0, until: float = 1_000_000.0) -> dict[str, list[overlap.Interval]]:
    return overlap.holds_by_keeper(calls, overlap.DEFAULT_HOLD_S, since, until)[0]


def make_store(path: pathlib.Path, rows: list[tuple[str, float, float | None]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.closing(sqlite3.connect(path)) as connection:
        connection.execute("CREATE TABLE operations (state TEXT NOT NULL, created_at REAL NOT NULL, started_at REAL)")
        connection.executemany("INSERT INTO operations VALUES (?, ?, ?)", rows)
        connection.commit()


class IntervalTest(unittest.TestCase):
    def test_merged_joins_overlapping_and_touching_intervals(self) -> None:
        self.assertEqual(overlap.merged([(5, 8), (0, 3), (3, 4), (7, 9)]), [(0, 4), (5, 9)])

    def test_merged_keeps_an_interval_inside_another(self) -> None:
        self.assertEqual(overlap.merged([(0, 10), (2, 3)]), [(0, 10)])

    def test_merged_of_nothing_is_empty(self) -> None:
        self.assertEqual(overlap.merged([]), [])

    def test_inside_counts_the_part_of_a_wait_that_lies_in_holds(self) -> None:
        self.assertEqual(overlap.inside_s((15, 35), [(10, 20), (30, 40)]), 10)

    def test_inside_is_zero_for_a_wait_that_only_touches_a_hold(self) -> None:
        holds = [(10, 20)]
        self.assertEqual((overlap.inside_s((0, 10), holds), overlap.inside_s((20, 30), holds)), (0, 0))

    def test_inside_counts_a_hold_in_the_middle_of_a_wait_once(self) -> None:
        self.assertEqual(overlap.inside_s((0, 100), [(10, 20)]), 10)

    def test_clipped_is_none_outside_the_window(self) -> None:
        self.assertIsNone(overlap.clipped(0, 10, 10, 20))
        self.assertEqual(overlap.clipped(5, 25, 10, 20), (10, 20))


class HoldTest(unittest.TestCase):
    def test_the_threshold_is_inclusive(self) -> None:
        holds = holds_of([execute(100, 59.9), execute(300, 60.0)])
        self.assertEqual(holds, {"a": [(240.0, 300)]})

    def test_only_execute_holds(self) -> None:
        self.assertEqual(holds_of([execute(500, 400, tool="Read")]), {})

    def test_a_failed_execute_holds_too(self) -> None:
        self.assertEqual(holds_of([execute(500, 100, failed=True)]), {"a": [(400.0, 500)]})

    def test_a_hold_is_clipped_to_the_window(self) -> None:
        self.assertEqual(holds_of([execute(190, 100)], since=100, until=150), {"a": [(100, 150)]})

    def test_overlapping_holds_of_one_keeper_merge_and_both_calls_count(self) -> None:
        holds, counts = overlap.holds_by_keeper([execute(100, 100), execute(150, 100)], 60.0, 0.0, 1_000.0)
        self.assertEqual((holds, counts), ({"a": [(0.0, 150)]}, Counter({"a": 2})))

    def test_holds_of_two_keepers_stay_apart(self) -> None:
        holds = holds_of([execute(100, 100, keeper="a"), execute(100, 100, keeper="b")])
        self.assertEqual(sorted(holds), ["a", "b"])


class KeeperRowTest(unittest.TestCase):
    def test_two_operations_waiting_together_count_twice_in_the_overlap_and_once_in_the_hold(self) -> None:
        row = overlap.keeper_row("a", 1, [(800, 1000)], [(850, 950), (900, 1000)])
        self.assertEqual((row.overlap_s, row.queued_hold_s), (200, 150))

    def test_a_hold_with_nobody_waiting_adds_nothing(self) -> None:
        row = overlap.keeper_row("a", 1, [(800, 1000)], [(0, 100)])
        self.assertEqual((row.held_s, row.overlap_s, row.queued_hold_s), (200, 0, 0))


class StoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.store = pathlib.Path(self.dir.name) / "a" / overlap.OPERATIONS_DB

    def test_an_operation_that_never_started_has_no_wait(self) -> None:
        make_store(self.store, [("queued", 10, None), ("cancelled", 10, None), ("succeeded", 10, 40)])
        self.assertEqual(overlap.read_waits(self.store, 0, 1_000), [(10, 40)])

    def test_waits_are_clipped_to_the_window(self) -> None:
        make_store(self.store, [("succeeded", 0, 50), ("succeeded", 90, 130), ("succeeded", 200, 300)])
        self.assertEqual(overlap.read_waits(self.store, 20, 100), [(20, 50), (90, 100)])

    def test_a_missing_store_is_none(self) -> None:
        self.assertIsNone(overlap.read_waits(self.store, 0, 1_000))

    def test_a_file_that_is_not_a_store_is_none(self) -> None:
        self.store.parent.mkdir(parents=True)
        self.store.write_text("not a database", encoding="utf-8")
        self.assertIsNone(overlap.read_waits(self.store, 0, 1_000))


class MeasureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = pathlib.Path(self.dir.name)

    def write_ledger(self, rows: list[dict[str, object]]) -> None:
        folder = self.base / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True)
        (folder / "05.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def ledger_row(self, keeper: str, end: float, duration_s: float, tool: str = "Execute") -> dict[str, object]:
        return {
            "record_kind": "tool_call",
            "ts": end,
            "tool": tool,
            "keeper": keeper,
            "duration_ms": duration_s * 1000,
            "result_bytes": 0,
            "disposition": "ok",
            "input": "{}",
            "output": "{}",
        }

    def run_main(self, *extra: str) -> tuple[int, pathlib.Path]:
        out = self.base / "result.json"
        argv = ["--base-path", str(self.base), "--since", "2026-11-05T00:00:00", "--end", "2026-11-05T01:00:00", "--json-out", str(out), *extra]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = overlap.main(argv)
        return code, out

    def test_the_overlap_counts_waits_that_lie_inside_holds_of_the_same_keeper(self) -> None:
        t0 = DAY_START
        # Keeper a holds [t0+800, t0+1000]; Keeper b holds nothing.
        self.write_ledger([self.ledger_row("a", t0 + 1000, 200), self.ledger_row("b", t0 + 1000, 30)])
        make_store(
            self.base / ".masc" / "keepers" / "a" / overlap.OPERATIONS_DB,
            [("succeeded", t0 + 850, t0 + 950), ("succeeded", t0 + 700, t0 + 900), ("succeeded", t0 + 2000, t0 + 2100)],
        )
        make_store(self.base / ".masc" / "keepers" / "b" / overlap.OPERATIONS_DB, [("succeeded", t0 + 10, t0 + 110)])
        code, out = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(
            result["holds"],
            {
                "calls": 1,
                "keepers": 1,
                "hours": round(200 / 3600, 3),
                "hours_with_a_waiting_operation": round(150 / 3600, 3),
                "share_with_a_waiting_operation": 0.75,
            },
        )
        self.assertEqual(result["queue_wait"]["operations"], 4)
        self.assertEqual(result["queue_wait"]["hours_all_keepers"], round(500 / 3600, 3))
        self.assertEqual(result["queue_wait"]["hours_holding_keepers"], round(400 / 3600, 3))
        self.assertEqual(result["overlap"]["hours"], round(200 / 3600, 3))
        self.assertEqual(result["overlap"]["share_of_all_keepers"], 0.4)
        self.assertEqual(result["overlap"]["share_of_holding_keepers"], 0.5)
        self.assertEqual([row["keeper"] for row in result["top_keepers"]], ["a"])

    def test_a_hold_that_ends_just_after_the_window_still_counts_inside_it(self) -> None:
        t0 = DAY_START
        self.write_ledger([self.ledger_row("a", t0 + 3700, 400)])
        make_store(self.base / ".masc" / "keepers" / "a" / overlap.OPERATIONS_DB, [("succeeded", t0 + 3400, t0 + 3600)])
        _, out = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(result["holds"]["calls"], 1)
        self.assertEqual(result["overlap"]["hours"], round(200 / 3600, 3))

    def test_a_keeper_with_holds_and_no_store_and_an_unreadable_store_are_listed(self) -> None:
        t0 = DAY_START
        self.write_ledger(
            [self.ledger_row(keeper, t0 + 1000, 200) for keeper in ("lost", "broken", "fine")]
        )
        broken = self.base / ".masc" / "keepers" / "broken" / overlap.OPERATIONS_DB
        broken.parent.mkdir(parents=True)
        broken.write_text("not a database", encoding="utf-8")
        make_store(self.base / ".masc" / "keepers" / "fine" / overlap.OPERATIONS_DB, [("succeeded", t0 + 850, t0 + 950)])
        _, out = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(result["keepers_with_holds_and_no_store"], ["lost"])
        self.assertEqual(result["unreadable_stores"], ["broken"])
        # The share of hold time with a waiting operation is over the Keepers whose store was read.
        self.assertEqual(result["holds"]["share_with_a_waiting_operation"], 0.5)

    def test_no_wait_at_all_gives_no_share(self) -> None:
        self.write_ledger([])
        _, out = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertIsNone(result["overlap"]["share_of_all_keepers"])

    def test_an_end_before_the_start_is_refused(self) -> None:
        argv = ["--base-path", str(self.base), "--since", "2026-11-05T01:00:00", "--end", "2026-11-05T00:00:00"]
        with contextlib.redirect_stderr(io.StringIO()):
            code = overlap.main(argv)
        self.assertEqual(code, 2)

    def test_a_hold_threshold_that_is_not_positive_is_refused(self) -> None:
        code, _ = self.run_main("--hold-s", "0")
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
