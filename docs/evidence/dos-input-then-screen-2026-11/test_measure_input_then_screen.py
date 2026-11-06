"""Tests for measure_input_then_screen.py on small synthetic ledgers."""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import tempfile
import unittest
from datetime import date
from typing import cast

import measure_input_then_screen as measure

JsonObject = dict[str, object]


def row(
    ts: object,
    keeper: str,
    tool: str,
    turn: int,
    *,
    trace: str = "t1",
    profile: str | None = "p1",
    result_bytes: int = 10,
    batch_size: int = 1,
    arguments: JsonObject | None = None,
    kind: str = "tool_call",
) -> JsonObject:
    entry: JsonObject = {
        "ts": ts,
        "record_kind": kind,
        "keeper": keeper,
        "tool": tool,
        "input": {} if arguments is None else arguments,
        "trace_id": trace,
        "keeper_turn_id": turn,
        "result_bytes": result_bytes,
        "batch_size": batch_size,
    }
    if profile is not None:
        entry["runtime_profile"] = profile
    return entry


def write_ledger(base: pathlib.Path, name: str, lines: list[bytes]) -> None:
    month_dir = base / ".masc" / "tool_calls" / "2026-11"
    month_dir.mkdir(parents=True, exist_ok=True)
    (month_dir / name).write_bytes(b"\n".join(lines) + b"\n")


def encode(entries: list[JsonObject]) -> list[bytes]:
    return [json.dumps(entry).encode() for entry in entries]


def run(base: pathlib.Path, first: str, last: str) -> measure.JsonObject:
    window = measure.Window()
    measure.measure(measure.read_calls(base, date.fromisoformat(first), date.fromisoformat(last), window), window)
    return measure.summarize_window(date.fromisoformat(first), date.fromisoformat(last), window)


def section(summary: JsonObject, name: str, key: str) -> JsonObject:
    return cast(dict[str, JsonObject], summary[name])[key]


class PairTests(unittest.TestCase):
    def test_pairs_gaps_frames_and_profiles(self) -> None:
        entries = [
            row(100, "k1", "masc_dos_press", 1),
            row(105, "k1", "Execute", 1),  # another tool: not a DOS call, between the pair
            row(105, "k2", "masc_dos_click", 1, trace="t9"),  # another Keeper, between the pair
            row("1970-01-01T00:01:50Z", "k1", "masc_dos_screen", 1, result_bytes=1000),
            row(120, "k2", "masc_dos_screen", 1, trace="t9", result_bytes=500),
            row(200, "k1", "masc_dos_step", 1),
            row(230, "k1", "masc_dos_meta", 1),  # a DOS call that is not a screen ends the chance of a pair
            row(300, "k1", "masc_dos_press", 1, arguments={"include_frame": True}),
            row(310, "k1", "masc_dos_step", 1, profile="p2"),
            row(330, "k1", "masc_dos_screen", 1, result_bytes=2000),
            row(340, "k1", "masc_dos_press", 1, batch_size=2),  # asked for together with the screen read
            row(341, "k1", "masc_dos_screen", 1, batch_size=2),
            row(350, "k1", "masc_dos_press", 1),
            row(351, "k1", "masc_dos_screen", 1, batch_size=3),  # the input was alone: the read needed its own request
            row(400, "k1", "masc_dos_type", 2),
            row(405, "k1", "masc_dos_screen", 3),  # another turn: not a pair
            row(500, "k1", "masc_dos_screen", 4),
            row(501, "k1", "masc_dos_screen", 4),  # a screen after a screen is not an input pair
            row(600, "k1", "masc_dos_press", 5, kind="other"),  # not a tool call record
        ]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "01.jsonl", encode(entries))
            summary = run(base, "2026-11-01", "2026-11-01")
        self.assertEqual(summary["dos_calls"], 17)
        self.assertEqual(summary["screen_calls"], 8)
        self.assertEqual(summary["dos_calls_by_keeper"], {"k1": 15, "k2": 2})
        press = section(summary, "by_tool", "masc_dos_press")
        self.assertEqual((press["calls"], press["with_frame"], press["followed_by_screen"]), (4, 1, 3))
        self.assertEqual(press["screen_in_next_request"], 2)  # the pair of batch_size 2 costs no request
        self.assertEqual((press["gap_hours"], press["gap_p50_s"], press["gap_p90_s"]), (round(12 / 3600, 2), 1.0, 10.0))
        self.assertEqual(press["screen_result_bytes"], 1020)
        step = section(summary, "by_tool", "masc_dos_step")
        self.assertEqual((step["calls"], step["followed_by_screen"], step["gap_p50_s"]), (2, 1, 20.0))
        self.assertEqual(step["screen_result_bytes"], 2000)
        click = section(summary, "by_tool", "masc_dos_click")
        self.assertEqual((click["calls"], click["followed_by_screen"], click["gap_p50_s"]), (1, 1, 15.0))
        typed = section(summary, "by_tool", "masc_dos_type")
        self.assertEqual((typed["calls"], typed["followed_by_screen"], typed["gap_p50_s"]), (1, 0, None))
        first_profile = section(summary, "by_profile", "p1")
        self.assertEqual((first_profile["calls"], first_profile["followed_by_screen"], first_profile["with_frame"]), (7, 4, 1))
        second_profile = section(summary, "by_profile", "p2")
        self.assertEqual((second_profile["calls"], second_profile["followed_by_screen"]), (1, 1))

    def test_a_row_without_a_profile_is_counted_as_unrecorded(self) -> None:
        entries = [row(1, "k1", "masc_dos_press", 1, profile=None), row(2, "k1", "masc_dos_screen", 1)]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "01.jsonl", encode(entries))
            summary = run(base, "2026-11-01", "2026-11-01")
        self.assertEqual(section(summary, "by_profile", measure.UNRECORDED_PROFILE)["followed_by_screen"], 1)


class ReadTests(unittest.TestCase):
    def test_window_segments_and_unreadable_lines(self) -> None:
        pair = [row(1, "k1", "masc_dos_press", 1), row(2, "k1", "masc_dos_screen", 1)]
        damaged = [
            b"not json",
            b"[1, 2]",
            b'{"ts": NaN, "record_kind": "tool_call", "keeper": "k1", "tool": "masc_dos_press"}',
            b'{"ts": 3, "tool": "x", "keeper": "\xff"}',
        ]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "01.jsonl", encode(pair[:1]) + damaged)
            write_ledger(base, "01.001.jsonl", encode(pair[1:]))
            write_ledger(base, "02.jsonl", encode([row(9, "k1", "masc_dos_press", 1)]))  # outside the window
            summary = run(base, "2026-11-01", "2026-11-01")
        self.assertEqual(summary["unreadable_lines"], 4)
        self.assertEqual(summary["dos_calls"], 2)
        self.assertEqual(section(summary, "by_tool", "masc_dos_press")["followed_by_screen"], 1)

    def test_the_command_line_writes_the_summary_and_refuses_a_reversed_window(self) -> None:
        entries = [row(1, "k1", "masc_dos_type", 1), row(2, "k1", "masc_dos_screen", 1)]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "01.jsonl", encode(entries))
            out = base / "result.json"
            argv = ["--base-path", str(base), "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--json-out", str(out)]
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                self.assertEqual(measure.main(argv), 0)
            written = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(written["by_tool"]["masc_dos_type"]["followed_by_screen"], 1)
            self.assertIn("masc_dos_type", printed.getvalue())
            reversed_window = ["--base-path", str(base), "--from-date", "2026-11-02", "--to-date", "2026-11-01"]
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as refused:
                measure.main(reversed_window)
            self.assertEqual(refused.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
