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
        self.assertEqual(self.summary()["rows"], 1)

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
