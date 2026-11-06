"""Checks the arithmetic of measure_turn_requests.py on small synthetic turn events.

Run: python3 -m unittest discover -s docs/evidence/aged-tool-results-2026-11
"""

from __future__ import annotations

import contextlib
import datetime
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_turn_requests as turns  # noqa: E402

# Request place in the turn, input tokens (cache reads included) and cache read tokens.
UsageSpec = tuple[int, int, int]


def line(stamp: float, event: dict[str, object]) -> str:
    return json.dumps({"v": 2, "seq": 0, "ts": stamp, "event": event})


def turn_lines(
    trace: str,
    number: int,
    start: float,
    usages: list[UsageSpec],
    *,
    end: float | None = None,
    model: str | None = "m",
) -> list[str]:
    lines = [line(start, {"type": "run_started", "run_id": f"{trace}#{number}", "thread_id": "keeper:k"})]
    if model is not None:
        lines.append(line(start + 0.5, {"type": "agent_core_stream_message_start", "stream_scope": 0, "model": model}))
    for scope, total, read in usages:
        usage = {"input_tokens": total, "output_tokens": 1, "cache_read_input_tokens": read}
        lines.append(
            line(start + 1 + scope, {"type": "agent_core_stream_message_delta", "stream_scope": scope, "usage": usage})
        )
    lines.append(line(start + 100 if end is None else end, {"type": "text_message_end"}))
    return lines


def parse(lines: list[str], skipped: turns.Skipped | None = None) -> turns.Turn | None:
    return turns.parse_turn("k", lines, skipped or turns.Skipped())


def make(trace: str, number: int, start: float, end: float, usages: list[UsageSpec], model: str = "m") -> turns.Turn:
    result = parse(turn_lines(trace, number, start, usages, end=end, model=model))
    assert result is not None
    return result


def write_turn(base: pathlib.Path, keeper: str, name: str, lines: list[str], mtime: float | None = None) -> pathlib.Path:
    folder = base / ".masc" / "keeper_turn_events" / keeper
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{name}.jsonl"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


class ParseTest(unittest.TestCase):
    def test_a_turn_is_read_from_its_events(self) -> None:
        parsed = parse(turn_lines("trace-1-00000", 7, 1000.0, [(1, 300, 200), (0, 100, 0)], end=1090.0, model="glm"))
        assert parsed is not None
        self.assertEqual((parsed.keeper, parsed.trace, parsed.number, parsed.model), ("k", "trace-1-00000", 7, "glm"))
        self.assertEqual((parsed.started, parsed.ended), (1000.0, 1090.0))
        # Ordered by the request's place in the turn, not by the order of the lines.
        self.assertEqual(parsed.usages, (turns.Usage(100, 0), turns.Usage(300, 200)))

    def test_the_last_usage_of_a_request_wins(self) -> None:
        parsed = parse(turn_lines("t", 1, 1.0, [(0, 100, 0), (0, 120, 20)]))
        assert parsed is not None
        self.assertEqual(parsed.usages, (turns.Usage(120, 20),))

    def test_a_turn_without_usage_is_counted_and_dropped(self) -> None:
        skipped = turns.Skipped()
        self.assertIsNone(parse(turn_lines("t", 1, 1.0, []), skipped))
        self.assertEqual(skipped.no_usage, 1)

    def test_a_turn_without_a_start_is_dropped_without_counting_it_as_unused(self) -> None:
        skipped = turns.Skipped()
        usage = {"input_tokens": 1, "cache_read_input_tokens": 0}
        event: dict[str, object] = {"type": "agent_core_stream_message_delta", "stream_scope": 0, "usage": usage}
        self.assertIsNone(parse([line(1.0, event)], skipped))
        self.assertEqual(skipped.no_usage, 0)

    def test_a_run_id_without_a_turn_number_is_not_a_start(self) -> None:
        lines = turn_lines("t", 1, 1.0, [(0, 1, 0)])
        lines[0] = line(1.0, {"type": "run_started", "run_id": "no-turn-number"})
        self.assertIsNone(parse(lines))

    def test_only_the_first_start_and_the_first_model_count(self) -> None:
        lines = turn_lines("t", 1, 1.0, [(0, 1, 0)], model="first")
        lines += turn_lines("t", 9, 50.0, [], model="second")[:2]
        parsed = parse(lines)
        assert parsed is not None
        self.assertEqual((parsed.number, parsed.started, parsed.model), (1, 1.0, "first"))

    def test_a_missing_model_is_unknown(self) -> None:
        parsed = parse(turn_lines("t", 1, 1.0, [(0, 1, 0)], model=None))
        assert parsed is not None
        self.assertEqual(parsed.model, turns.UNKNOWN_MODEL)

    def test_a_usage_without_cache_reads_counts_zero_and_one_without_input_is_ignored(self) -> None:
        lines = turn_lines("t", 1, 1.0, [])
        for scope, usage in ((0, {"input_tokens": 50}), (1, {"cache_read_input_tokens": 5}), (2, {"input_tokens": True})):
            lines.insert(1, line(2.0 + scope, {"type": "agent_core_stream_message_delta", "stream_scope": scope, "usage": usage}))
        parsed = parse(lines)
        assert parsed is not None
        self.assertEqual(parsed.usages, (turns.Usage(50, 0),))

    def test_a_boolean_timestamp_is_no_start(self) -> None:
        lines = turn_lines("t", 1, 1.0, [(0, 1, 0)])
        lines[0] = json.dumps({"v": 2, "ts": True, "event": {"type": "run_started", "run_id": "t#1"}})
        self.assertIsNone(parse(lines))

    def test_bad_lines_and_events_that_are_not_objects_are_counted(self) -> None:
        skipped = turns.Skipped()
        lines = [*turn_lines("t", 1, 1.0, [(0, 1, 0)]), "not json", json.dumps([1, 2]), json.dumps({"ts": 1.0})]
        self.assertIsNotNone(parse(lines, skipped))
        self.assertEqual(skipped.bad_lines, 3)


class GapTest(unittest.TestCase):
    def test_a_gap_is_the_start_minus_the_end_of_the_turn_before(self) -> None:
        first = make("t", 4, 100.0, 160.0, [(0, 1, 0)])
        second = make("t", 5, 400.0, 410.0, [(0, 1, 0)])
        self.assertEqual(turns.gaps([second, first]), {("k", "t", 5): 240.0})

    def test_only_the_turn_number_one_lower_of_the_same_keeper_and_trace_counts(self) -> None:
        base = make("t", 4, 100.0, 160.0, [(0, 1, 0)])
        skipped_number = make("t", 6, 400.0, 410.0, [(0, 1, 0)])
        other_trace = make("u", 5, 400.0, 410.0, [(0, 1, 0)])
        other_keeper = turns.Turn("j", "t", 5, 400.0, 410.0, "m", (turns.Usage(1, 0),))
        self.assertEqual(turns.gaps([base, skipped_number, other_trace, other_keeper]), {})

    def test_bucket_edges(self) -> None:
        cases = [
            (None, "unknown"),
            (-5.0, "<1m"),
            (59.9, "<1m"),
            (60.0, "1-5m"),
            (299.9, "1-5m"),
            (300.0, "5-10m"),
            (600.0, "10-30m"),
            (1800.0, "30-60m"),
            (3600.0, ">60m"),
            (90000.0, ">60m"),
        ]
        for seconds, label in cases:
            with self.subTest(seconds=seconds):
                self.assertEqual(turns.gap_label(seconds), label)


class StatisticsTest(unittest.TestCase):
    def test_first_hits_use_only_the_first_request_of_each_turn(self) -> None:
        group = [
            make("t", 1, 1.0, 2.0, [(0, 100, 90), (1, 500, 500)]),
            make("t", 2, 3.0, 4.0, [(0, 300, 30)]),
            make("t", 3, 5.0, 6.0, [(0, 0, 0)]),
            make("t", 4, 7.0, 8.0, [(0, 200, 100)]),
        ]
        result = turns.first_hits(group)
        self.assertEqual(result["turns"], 4)
        self.assertEqual(result["hit_share_of_tokens"], round(220 / 600, 4))
        # Ratios 0.9, 0.1 and 0.5; a turn with no input tokens has no ratio. A hit of exactly half is not below half.
        self.assertEqual(result["median_hit"], 0.5)
        self.assertEqual(result["share_of_turns_below_half"], round(1 / 3, 4))

    def test_first_hits_of_nothing_are_zero(self) -> None:
        self.assertEqual(turns.first_hits([]), {"turns": 0, "hit_share_of_tokens": 0.0, "median_hit": 0.0, "share_of_turns_below_half": 0.0})

    def test_requests_per_turn(self) -> None:
        group = [make("t", n, float(n), float(n) + 1, [(i, 1, 0) for i in range(count)]) for n, count in enumerate((1, 2, 3, 4, 20), 1)]
        self.assertEqual(turns.requests_per_turn(group), {"mean": 6.0, "median": 3.0, "p90": 20.0})
        self.assertEqual(turns.requests_per_turn([]), {"mean": 0.0, "median": 0.0, "p90": 0.0})

    def test_quantile_takes_the_ceiling_rank(self) -> None:
        values = [float(number) for number in range(1, 11)]
        self.assertEqual([turns.quantile(values, q) for q in (0.5, 0.9, 0.99)], [5.0, 9.0, 10.0])
        self.assertEqual(turns.quantile([], 0.5), 0.0)


class ReportTest(unittest.TestCase):
    def build(self) -> list[turns.Turn]:
        return [
            make("t", 1, 100.0, 160.0, [(0, 100, 0), (1, 100, 100)], model="a"),
            make("t", 2, 200.0, 210.0, [(0, 100, 90)], model="a"),
            make("t", 3, 5000.0, 5010.0, [(0, 100, 0)], model="b"),
            make("u", 9, 7000.0, 7010.0, [(0, 100, 50)], model="a"),
        ]

    def test_window_and_gap_buckets(self) -> None:
        skipped = turns.Skipped()
        result = turns.report(self.build(), skipped, 150.0, 6000.0, 5)
        counted = cast(dict[str, int], result["turns"])
        # The turn started at 100 is before `since`, the one at 7000 is not before `until`.
        self.assertEqual((counted["counted"], counted["outside_window"]), (2, 2))
        gaps = {item["gap"]: item for item in cast(list[dict[str, object]], result["first_request_by_gap"])}
        # Turn 2 follows turn 1 by 40 s, turn 3 follows turn 2 by 4790 s. The turn before `since` still gives a gap.
        self.assertEqual(set(gaps), {"<1m", ">60m"})
        self.assertEqual(gaps["<1m"]["hit_share_of_tokens"], 0.9)
        self.assertEqual(gaps[">60m"]["hit_share_of_tokens"], 0.0)

    def test_the_window_includes_its_start_and_excludes_its_end(self) -> None:
        group = [make("t", 1, 100.0, 110.0, [(0, 1, 0)]), make("t", 2, 200.0, 210.0, [(0, 1, 0)]), make("t", 3, 300.0, 310.0, [(0, 1, 0)])]
        result = turns.report(group, turns.Skipped(), 200.0, 300.0, 5)
        self.assertEqual(cast(dict[str, int], result["turns"])["counted"], 1)

    def test_a_turn_without_the_turn_before_has_an_unknown_gap(self) -> None:
        result = turns.report([make("u", 9, 7000.0, 7010.0, [(0, 100, 50)])], turns.Skipped(), None, None, 5)
        self.assertEqual([item["gap"] for item in cast(list[dict[str, object]], result["first_request_by_gap"])], ["unknown"])

    def test_buckets_come_in_gap_order_and_empty_ones_are_left_out(self) -> None:
        group = [
            make("t", 1, 0.0, 10.0, [(0, 1, 0)]),
            make("t", 2, 5000.0, 5010.0, [(0, 1, 0)]),
            make("t", 3, 5020.0, 5030.0, [(0, 1, 0)]),
            make("u", 5, 9.0, 9.5, [(0, 1, 0)]),
        ]
        labels = [item["gap"] for item in turns.by_gap(group, turns.gaps(group))]
        self.assertEqual(labels, ["<1m", ">60m", "unknown"])

    def test_models_are_ranked_by_turns_and_limited(self) -> None:
        result = turns.report(self.build(), turns.Skipped(), None, None, 1)
        models = cast(list[dict[str, object]], result["by_model"])
        self.assertEqual([item["model"] for item in models], ["a"])
        self.assertEqual(cast(dict[str, object], models[0]["first_request"])["turns"], 3)

    def test_empty_input_reports_zeros(self) -> None:
        result = turns.report([], turns.Skipped(), None, None, 5)
        self.assertEqual(result["by_model"], [])
        self.assertEqual(result["first_request_by_gap"], [])
        self.assertEqual(cast(dict[str, object], result["first_request"])["turns"], 0)


class LoadTest(unittest.TestCase):
    def test_files_are_chosen_by_modification_time_and_read_per_keeper(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_turn(base, "a", "old", turn_lines("t", 1, 100.0, [(0, 1, 0)]), mtime=500.0)
            write_turn(base, "a", "new", turn_lines("t", 2, 900.0, [(0, 1, 0)]), mtime=950.0)
            write_turn(base, "b", "new", turn_lines("u", 1, 910.0, [(0, 1, 0)]), mtime=800.0)
            (base / ".masc" / "keeper_turn_events" / ".DS_Store").write_text("x", encoding="utf-8")
            everything = turns.load(base, None, turns.Skipped())
            recent = turns.load(base, 800.0, turns.Skipped())
        self.assertEqual(len(everything), 3)
        # A file modified exactly at `since` is read.
        self.assertEqual(sorted((item.keeper, item.number) for item in recent), [("a", 2), ("b", 1)])

    def test_a_missing_store_has_no_turns(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(turns.load(pathlib.Path(folder), None, turns.Skipped()), [])


class CommandLineTest(unittest.TestCase):
    def test_json_out_gets_the_report(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_turn(base, "a", "x", turn_lines("t", 1, 100.0, [(0, 10, 5)]))
            out = base / "result.json"
            code = turns.main(["--base-path", str(base), "--json-out", str(out)])
            result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(result["turns"]["counted"], 1)

    def test_without_json_out_the_report_goes_to_stdout_with_the_window(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_turn(base, "a", "x", turn_lines("t", 1, 100.0, [(0, 10, 5)]))
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                turns.main(["--base-path", str(base), "--since", "2026-11-02T00:00:00", "--until", "2026-11-03T00:00:00"])
        midnight = datetime.datetime(2026, 11, 2, tzinfo=datetime.timezone.utc).timestamp()
        params = json.loads(buffer.getvalue())["params"]
        self.assertEqual((params["since"], params["until"]), (midnight, midnight + 86400))

    def test_a_bad_time_is_a_usage_error(self) -> None:
        for flag in ("--since", "--until"):
            with self.subTest(flag=flag), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                turns.main(["--base-path", ".", flag, "noon"])
            self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
