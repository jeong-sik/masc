#!/usr/bin/env python3
"""The tool-efficiency measurement reads rotated ledger segments and counts what it names."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import date, datetime, timezone

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS / "lib"))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


EFFICIENCY = load("measure_tool_efficiency", "measure-tool-efficiency.py")

DAY = date(2026, 11, 5)
NOON = datetime(2026, 11, 5, 12, 0, 0, tzinfo=timezone.utc).timestamp()
WINDOW = 3600.0
PAGE_BYTES = 16_384


def call(tool, keeper="a", turn=1, at=0.0, size=100, duration=10.0, args=None, output: object = "ok",
         outcome="ok", profile="p1", input_fp=None, output_fp=None, trace="tr"):
    """One ledger row shaped like Keeper_tool_call_log's tool_call record."""
    row = {
        "record_kind": "tool_call",
        "tool": tool,
        "keeper": keeper,
        "trace_id": trace,
        "keeper_turn_id": turn,
        "ts": NOON + at,
        "duration_ms": duration,
        "result_bytes": size,
        "input": {} if args is None else args,
        "output": output,
        "wire_outcome": outcome,
        "runtime_profile": profile,
    }
    row["input_fingerprint"] = input_fp if input_fp is not None else json.dumps(row["input"], sort_keys=True)
    row["output_fingerprint"] = output_fp if output_fp is not None else json.dumps(output, sort_keys=True)
    return row


class Ledger(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.directory = self.base / ".masc" / "tool_calls" / "2026-11"
        self.directory.mkdir(parents=True)

    def write(self, name, rows, extra_lines=()):
        lines = [json.dumps(row) for row in rows] + list(extra_lines)
        (self.directory / name).write_text("\n".join(lines) + "\n", encoding="utf-8")

    def summary(self, jobs=1):
        totals = EFFICIENCY.measure_range(self.base, DAY, DAY, WINDOW, jobs)
        return EFFICIENCY.summarize(totals, 5)


class IdenticalRereads(Ledger):
    def test_counts_equal_results_inside_the_window_and_splits_by_turn(self):
        page = {"sha256": "x", "offset": 0}
        self.write("05.jsonl", [
            call("keeper_artifact_read", turn=1, at=0, size=PAGE_BYTES, args=page, output="page"),
            call("keeper_artifact_read", turn=1, at=10, size=PAGE_BYTES, args=page, output="page"),
            call("keeper_artifact_read", turn=2, at=100, size=PAGE_BYTES, args=page, output="page"),
            call("keeper_artifact_read", turn=3, at=100 + WINDOW + 1, size=PAGE_BYTES, args=page, output="page"),
        ])
        rereads = self.summary()["identical_rereads"]
        self.assertEqual(rereads["calls"], 2)
        self.assertEqual(rereads["bytes"], 2 * PAGE_BYTES)
        self.assertEqual((rereads["same_turn"], rereads["later_turn"]), (1, 1))

    def test_a_changed_result_is_not_a_re_read(self):
        args = {"schedule_id": "s"}
        self.write("05.jsonl", [
            call("masc_schedule_notes_list", at=0, args=args, output="one"),
            call("masc_schedule_notes_list", at=5, args=args, output="two"),
            call("masc_schedule_notes_list", at=9, args=args, output="two"),
        ])
        self.assertEqual(self.summary()["identical_rereads"]["calls"], 1)

    def test_two_keepers_do_not_share_a_re_read(self):
        args = {"schedule_id": "s"}
        self.write("05.jsonl", [
            call("masc_schedule_notes_list", keeper="a", at=0, args=args),
            call("masc_schedule_notes_list", keeper="b", at=5, args=args),
        ])
        self.assertEqual(self.summary()["identical_rereads"]["calls"], 0)


class RotatedSegments(Ledger):
    def test_reads_segments_in_order_then_the_live_file(self):
        args = {"sha256": "x"}
        self.write("05.001.jsonl", [call("keeper_artifact_read", at=0, args=args)])
        self.write("05.002.jsonl", [call("keeper_artifact_read", at=1, args=args)])
        self.write("05.jsonl", [call("keeper_artifact_read", at=2, args=args)])
        names = [path.name for path in EFFICIENCY.ledger_files(self.base, DAY)]
        self.assertEqual(names, ["05.001.jsonl", "05.002.jsonl", "05.jsonl"])
        summary = self.summary()
        self.assertEqual(summary["rows"], 3)
        self.assertEqual(summary["identical_rereads"]["calls"], 2)

    def test_skips_unparsable_lines_and_other_record_kinds(self):
        other = dict(call("Execute"), record_kind="composition_run")
        self.write("05.jsonl", [call("Read"), other], extra_lines=["{not json", ""])
        summary = self.summary()
        self.assertEqual(summary["rows"], 1)
        self.assertEqual(summary["skipped"]["unreadable_lines"], 1)

    def test_one_bad_line_does_not_stop_the_run_and_is_counted(self):
        good = json.dumps(call("Read", at=1, args={"n": 1})).encode()
        lines = [
            good,
            b'{"record_kind": "tool_call", "tool": "Read", "ts": NaN}',
            b'{"record_kind": "tool_call", "tool": "Read", "duration_ms": Infinity}',
            b'{"record_kind": "tool_call", "tool": "Read", "ts": 1' + b'0' * 400 + b'}',
            b"[1, 2]",
            b'{"record_kind": "tool_call", "tool": "Read", "input": {"x": "\xe3\x81',
            good,
        ]
        (self.directory / "05.jsonl").write_bytes(b"\n".join(lines) + b"\n")
        summary = self.summary()
        self.assertEqual(summary["rows"], 3)
        self.assertEqual(summary["skipped"]["unreadable_lines"], 4)
        self.assertEqual(summary["skipped"]["tool_calls_without_timestamp"], 1)

    def test_a_tool_call_with_no_usable_hour_stays_in_the_totals_only(self):
        row = dict(call("Read", args={"n": 1}), ts=1e20, result_bytes=1e999)
        text = json.dumps(row).replace("Infinity", "1e999")
        (self.directory / "05.jsonl").write_text(text + "\n" + json.dumps(call("Read", args={"n": 2})) + "\n",
                                                encoding="utf-8")
        summary = self.summary()
        self.assertEqual(summary["rows"], 2)
        self.assertEqual(summary["skipped"], {"unreadable_lines": 0, "tool_calls_without_timestamp": 1})
        self.assertEqual(sum(hour["calls"] for hour in summary["hourly"].values()), 1)
        self.assertEqual(summary["result_bytes"], 100)

    def test_a_segment_name_the_writer_never_makes_is_not_read(self):
        args = {"sha256": "x"}
        self.write("05.001.jsonl", [call("keeper_artifact_read", at=0, args=args)])
        self.write("05.1.jsonl", [call("keeper_artifact_read", at=1, args=args)])
        self.write("05.jsonl", [call("keeper_artifact_read", at=2, args=args)])
        names = [path.name for path in EFFICIENCY.ledger_files(self.base, DAY)]
        self.assertEqual(names, ["05.001.jsonl", "05.jsonl"])

    def test_a_missing_day_is_empty(self):
        self.assertEqual(self.summary()["rows"], 0)

    def test_worker_processes_give_the_same_answer(self):
        self.write("05.jsonl", [call("Read", at=n, args={"n": n}) for n in range(6)])
        self.assertEqual(self.summary(jobs=1)["rows"], self.summary(jobs=2)["rows"])


class SpilledResults(Ledger):
    def test_counts_blob_references_whether_the_output_is_an_object_or_text(self):
        blob = {"_blob": {"sha256": "x", "bytes": 70_000, "mime": "text/plain", "preview": "p"}}
        self.write("05.jsonl", [
            call("Execute", size=70_000, output=blob),
            call("Execute", size=80_000, output=json.dumps(blob)),
            call("Execute", size=100, output="small"),
            call("keeper_artifact_read", size=PAGE_BYTES, args={"sha256": "x", "offset": 0}),
            call("keeper_artifact_read", size=PAGE_BYTES, args={"sha256": "x", "offset": PAGE_BYTES}),
        ])
        spilled = self.summary()["spilled_results"]
        self.assertEqual((spilled["calls"], spilled["bytes"]), (2, 150_000))
        self.assertEqual(spilled["read_back_calls"], 2)
        self.assertEqual(spilled["distinct_artifacts_read"], 1)
        self.assertEqual(spilled["most_paged_artifacts"], [("x", 2)])


class BlockedWaits(Ledger):
    def test_a_sleeping_or_polling_command_is_a_wait_and_a_plain_one_is_not(self):
        self.write("05.jsonl", [
            call("Execute", duration=420_000, args={"command": "sleep 420; gh run view 1"}),
            call("Execute", duration=60_000, args={"argv": ["bash", "-c", "until gh run view 1; do sleep 5; done"]}),
            call("Execute", duration=100, args={"command": "ls -la"}),
            call("Read", duration=999_999, args={"file_path": "sleep 5"}),
        ])
        waits = self.summary()["blocked_waits"]
        self.assertEqual((waits["wait_calls"], waits["execute_calls"]), (2, 3))
        self.assertEqual(waits["wait_time_s"], 480.0)

    def test_the_word_until_is_a_wait_only_as_a_shell_loop(self):
        self.write("05.jsonl", [
            call("Execute", duration=50_000, args={"command": "until gh run view 1; do date; done"}),
            call("Execute", duration=4_000, args={"command": "gh api 'repos/o/r/commits?until=2026-11-03T09:00:00Z'"}),
            call("Execute", duration=100, args={"command": "grep -rn 'until' lib/"}),
        ])
        waits = self.summary()["blocked_waits"]
        self.assertEqual((waits["wait_calls"], waits["execute_calls"]), (1, 3))
        self.assertEqual(waits["wait_time_s"], 50.0)

    def test_the_hourly_series_carries_the_wait_time(self):
        self.write("05.jsonl", [call("Execute", duration=30_000, args={"command": "sleep 30"})])
        hour = self.summary()["hourly"]["2026-11-05T12"]
        self.assertEqual(hour["wait_s"], 30.0)
        self.assertEqual(hour["calls"], 1)


class EmptyInputFailures(Ledger):
    def test_counts_failed_calls_with_no_arguments_and_not_tools_that_take_none(self):
        self.write("05.jsonl", [
            call("Execute", outcome="error", profile="muse"),
            call("Read", outcome="error", profile="muse", args=None),
            call("keeper_lane_status", outcome="ok", profile="muse"),
            call("Read", outcome="error", profile="glm", args={"file_path": "/missing"}),
        ])
        empty = self.summary()["empty_input_failures"]
        self.assertEqual(empty["total"], 2)
        by_profile = {item["profile"]: item for item in empty["by_profile"]}
        self.assertEqual(by_profile["muse"]["failed"], 2)
        self.assertEqual(by_profile["muse"]["calls"], 3)
        self.assertNotIn("glm", by_profile)

    def test_disposition_outranks_the_wire_outcome(self):
        failed = dict(call("Execute", outcome="ok"), disposition="failed")
        self.write("05.jsonl", [failed])
        self.assertEqual(self.summary()["empty_input_failures"]["total"], 1)


class Bursts(Ledger):
    def test_names_the_turn_that_called_one_tool_the_most(self):
        rows = [call("masc_schedule_notes_list", turn=7, at=n, args={"n": n}, size=1000) for n in range(5)]
        rows.append(call("masc_schedule_notes_list", turn=8, at=9, args={"n": 99}))
        self.write("05.jsonl", rows)
        burst = self.summary()["same_tool_bursts"][0]
        self.assertEqual((burst["tool"], burst["calls"], burst["span_s"]), ("masc_schedule_notes_list", 5, 4.0))
        self.assertTrue(burst["turn"].endswith("#7"))


class Percentile(unittest.TestCase):
    """Tool_metrics.percentile: the sample at rank round((n - 1) * p), halves rounded up."""

    def test_follows_the_rank_rule_of_tool_metrics(self):
        thousand = [float(n) for n in range(1, 1001)]
        self.assertEqual(EFFICIENCY.percentile(thousand, 0.99), 990.0)
        self.assertEqual(EFFICIENCY.percentile(thousand, 0.5), 501.0)
        self.assertEqual(EFFICIENCY.percentile([1.0, 2.0], 0.5), 2.0)
        self.assertEqual(EFFICIENCY.percentile([7.0], 0.99), 7.0)
        self.assertIsNone(EFFICIENCY.percentile([], 0.5))


class MergedDays(Ledger):
    """Two days merged give what the two days give apart, field by field."""

    def write_day(self, name, rows):
        (self.directory / name).write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

    def test_two_days_add_up_and_share_what_is_shared(self):
        day5 = NOON
        day6 = NOON + 86_400
        blob = {"_blob": {"sha256": "x", "bytes": 70_000, "mime": "text/plain", "preview": "p"}}
        page = {"sha256": "x", "offset": 0}

        def row(tool, ts, **fields):
            built = call(tool, at=ts - NOON, **fields)
            built["ts"] = ts
            return built

        self.write_day("05.jsonl", [
            row("Execute", day5, size=70_000, duration=2_000, output=blob, args={"command": "sleep 30"}, outcome="error"),
            row("keeper_artifact_read", day5 + 1, size=PAGE_BYTES, duration=5, args=page, output="page", turn=4),
            row("keeper_artifact_read", day5 + 2, size=PAGE_BYTES, duration=7, args=page, output="page", turn=4),
            row("Read", day5 + 3, size=10, duration=1, args={"n": 1}),
        ])
        self.write_day("06.jsonl", [
            row("Execute", day6, size=80_000, duration=3_000, output=blob, args={"command": "sleep 5"}),
            row("keeper_artifact_read", day6 + 1, size=PAGE_BYTES, duration=9, args=page, output="page", turn=4),
            row("keeper_artifact_read", day6 + 2, size=PAGE_BYTES, duration=11, args=page, output="page", turn=4),
            row("Read", day6 + 3, size=20, duration=3, args={"n": 2}, outcome="error"),
        ])
        both = EFFICIENCY.summarize(
            EFFICIENCY.measure_range(self.base, date(2026, 11, 5), date(2026, 11, 6), WINDOW, 2), 5)

        self.assertEqual(both["rows"], 8)
        self.assertEqual(both["result_bytes"], 70_000 + 2 * PAGE_BYTES + 10 + 80_000 + 2 * PAGE_BYTES + 20)
        rereads = both["identical_rereads"]
        self.assertEqual((rereads["calls"], rereads["bytes"]), (2, 2 * PAGE_BYTES))
        self.assertEqual((rereads["same_turn"], rereads["later_turn"]), (2, 0))
        spilled = both["spilled_results"]
        self.assertEqual((spilled["calls"], spilled["bytes"]), (2, 150_000))
        self.assertEqual((spilled["read_back_calls"], spilled["read_back_bytes"]), (4, 4 * PAGE_BYTES))
        waits = both["blocked_waits"]
        self.assertEqual((waits["execute_calls"], waits["execute_time_s"]), (2, 5.0))
        self.assertEqual((waits["wait_calls"], waits["wait_time_s"]), (2, 5.0))
        self.assertEqual(both["spilled_results"]["distinct_artifacts_read"], 1)
        self.assertEqual(both["spilled_results"]["most_paged_artifacts"], [("x", 4)])
        self.assertEqual(both["outcomes"], {"succeeded": 6, "failed": 2})
        by_tool = {item["tool"]: item for item in both["tools"]}
        self.assertEqual((by_tool["Read"]["calls"], by_tool["Read"]["failed"]), (2, 1))
        self.assertEqual(by_tool["keeper_artifact_read"]["reread_calls"], 2)
        self.assertEqual(by_tool["Execute"]["spilled_bytes"], 150_000)
        self.assertEqual(by_tool["keeper_artifact_read"]["p50_ms"], 9.0)
        self.assertEqual(by_tool["keeper_artifact_read"]["p99_ms"], 11.0)
        self.assertEqual(sorted(both["daily"]), ["2026-11-05", "2026-11-06"])
        self.assertEqual(sum(hour["calls"] for hour in both["hourly"].values()), 8)
        for day_key in both["daily"]:
            self.assertEqual(both["daily"][day_key]["calls"], 4)
            self.assertEqual(both["daily"][day_key]["wait_s"], 2.0 if day_key.endswith("05") else 3.0)
        burst = next(item for item in both["same_tool_bursts"] if item["tool"] == "keeper_artifact_read")
        self.assertEqual((burst["calls"], burst["span_s"]), (4, 86_402.0 - 1.0))


class Command(unittest.TestCase):
    def run_script(self, *args, env=None):
        merged = {key: value for key, value in os.environ.items() if key != "MASC_BASE_PATH"}
        merged.update(env or {})
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPTS / "measure-tool-efficiency.py"), *args],
            capture_output=True, text=True, env=merged, check=False,
        )

    def test_stops_when_no_base_is_named(self):
        done = self.run_script("--from-date", "2026-11-05", "--to-date", "2026-11-05")
        self.assertEqual(done.returncode, 2)
        self.assertIn("MASC_BASE_PATH", done.stderr)

    def test_stops_on_a_reversed_range(self):
        done = self.run_script("--base-path", "/nowhere", "--from-date", "2026-11-05", "--to-date", "2026-11-01")
        self.assertEqual(done.returncode, 2)

    def test_writes_json_and_a_report(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            directory = base / ".masc" / "tool_calls" / "2026-11"
            directory.mkdir(parents=True)
            (directory / "05.jsonl").write_text(json.dumps(call("Read")) + "\n", encoding="utf-8")
            out = base / "out" / "summary.json"
            done = self.run_script(
                "--from-date", "2026-11-05", "--to-date", "2026-11-05", "--json-out", str(out),
                env={"MASC_BASE_PATH": str(base)},
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("tool calls: 1", done.stdout)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8"))["rows"], 1)


if __name__ == "__main__":
    unittest.main()
