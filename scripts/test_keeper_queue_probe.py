#!/usr/bin/env python3
"""Tests for the due schedule latency table of keeper-queue-probe.py.

Run: python3 -I scripts/test_keeper_queue_probe.py
"""

from __future__ import annotations

import datetime
import importlib.util
import json
import math
import pathlib
import sys
import tempfile
import unittest
from types import ModuleType

UTC = datetime.timezone.utc


def load_probe() -> ModuleType:
    path = pathlib.Path(__file__).with_name("keeper-queue-probe.py")
    spec = importlib.util.spec_from_file_location("keeper_queue_probe", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load %s" % path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


PROBE = load_probe()


def at(day: int, hour: int = 0, minute: int = 0, second: int = 0) -> float:
    return datetime.datetime(2026, 10, day, hour, minute, second, tzinfo=UTC).timestamp()


def delivered_line(ts: float, schedule_id: str, due_at: float, keeper: str) -> str:
    stamp = datetime.datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    message = "turn entry: scheduled wake delivered schedule_id=%s due_at=%.3f (keeper=%s)" % (
        schedule_id, due_at, keeper)
    return json.dumps({"ts": stamp, "level": "INFO", "message": message})


class ScheduleLatencyTest(unittest.TestCase):
    def write_log(self, directory: str, lines: list[str]) -> None:
        pathlib.Path(directory, "system_log_2026-10-26.jsonl").write_text("\n".join(lines) + "\n")

    def test_first_delivery_sets_the_delay_and_later_ones_count_as_again(self) -> None:
        due_a, due_b = at(26, 10), at(26, 11)
        with tempfile.TemporaryDirectory() as directory:
            self.write_log(directory, [
                delivered_line(due_a + 10, "a", due_a, "k1"),
                delivered_line(due_a + 400, "a", due_a, "k1"),
                delivered_line(due_b + 30, "b", due_b, "k1"),
            ])
            deliveries = PROBE.read_scheduled_deliveries(directory, {"k1"})
        rows = PROBE.schedule_latency_rows(deliveries, PROBE.Window(0.0, math.inf), "day")
        self.assertEqual([row.bucket for row in rows], ["2026-10-26", "all"])
        day = rows[0]
        self.assertEqual(day.occurrences, 2)
        self.assertEqual(day.deliveries, 3)
        self.assertEqual(day.delivered_again, 1)
        self.assertEqual(day.p50, 30.0)
        self.assertEqual(day.longest, 30.0)
        self.assertEqual(rows[1].occurrences, 2)

    def test_window_bounds_the_due_time_not_the_delivery_time(self) -> None:
        early, late = at(26, 1), at(26, 12)
        with tempfile.TemporaryDirectory() as directory:
            self.write_log(directory, [
                delivered_line(early + 5, "early", early, "k1"),
                delivered_line(late + 5, "late", late, "k1"),
            ])
            deliveries = PROBE.read_scheduled_deliveries(directory, {"k1"})
        rows = PROBE.schedule_latency_rows(deliveries, PROBE.Window(at(26, 6), math.inf), "day")
        self.assertEqual([(row.bucket, row.occurrences) for row in rows], [("2026-10-26", 1), ("all", 1)])

    def test_other_keepers_other_messages_and_broken_lines_are_ignored(self) -> None:
        due = at(26, 10)
        with tempfile.TemporaryDirectory() as directory:
            self.write_log(directory, [
                delivered_line(due + 5, "mine", due, "k1"),
                delivered_line(due + 5, "theirs", due, "k2"),
                json.dumps({"ts": "2026-10-26T10:00:05Z", "message": "turn entry: bootstrap stimulus consumed (keeper=k1)"}),
                "not json",
            ])
            deliveries = PROBE.read_scheduled_deliveries(directory, {"k1"})
        self.assertEqual(list(deliveries), [("k1", "mine", round(due, 3))])

    def test_hour_buckets_split_the_day(self) -> None:
        first, second = at(26, 10, 5), at(26, 11, 5)
        with tempfile.TemporaryDirectory() as directory:
            self.write_log(directory, [
                delivered_line(first + 1, "x", first, "k1"),
                delivered_line(second + 100, "y", second, "k1"),
            ])
            deliveries = PROBE.read_scheduled_deliveries(directory, {"k1"})
        rows = PROBE.schedule_latency_rows(deliveries, PROBE.Window(0.0, math.inf), "hour")
        self.assertEqual([(row.bucket, row.p50) for row in rows], [("10-26T10Z", 1.0), ("10-26T11Z", 100.0), ("all", 100.0)])


if __name__ == "__main__":
    unittest.main()
