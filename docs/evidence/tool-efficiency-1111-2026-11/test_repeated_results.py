"""Tests for repeated_results.py on synthetic calls.

Run: python3 -I docs/evidence/tool-efficiency-1111-2026-11/test_repeated_results.py
"""

from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import repeated_results as repeats  # noqa: E402

HOUR = 3600.0


def call(
    ts: float,
    *,
    keeper: str = "k",
    tool: str = "t",
    inp: str | None = "i",
    out: str | None = "o",
    size: int = 100,
) -> repeats.Call:
    return repeats.Call(ts, keeper, tool, inp, out, size)


class MeasureTest(unittest.TestCase):
    def test_second_identical_call_inside_the_hour_repeats(self) -> None:
        share = repeats.measure([call(0), call(60)], since=0, end=HOUR)
        self.assertEqual((share.calls, share.repeated_calls), (2, 1))
        self.assertEqual((share.result_bytes, share.repeated_bytes), (200, 100))

    def test_the_hour_is_inclusive_and_a_second_more_is_not_a_repeat(self) -> None:
        self.assertEqual(repeats.measure([call(0), call(HOUR)], since=0, end=2 * HOUR).repeated_calls, 1)
        self.assertEqual(repeats.measure([call(0), call(HOUR + 1)], since=0, end=2 * HOUR).repeated_calls, 0)

    def test_each_part_of_the_key_separates_calls(self) -> None:
        others = [
            call(60, keeper="other"),
            call(60, tool="other"),
            call(60, inp="other"),
            call(60, out="other"),
        ]
        for other in others:
            with self.subTest(other=other):
                self.assertEqual(repeats.measure([call(0), other], since=0, end=HOUR).repeated_calls, 0)

    def test_the_repeat_is_measured_from_the_latest_earlier_call(self) -> None:
        # 0, 3000, 6000: the third is 3000 s after the second, so it repeats although it is 6000 s after the first.
        share = repeats.measure([call(0), call(3000), call(6000)], since=0, end=2 * HOUR)
        self.assertEqual(share.repeated_calls, 2)

    def test_a_call_before_the_window_seeds_the_memory_and_is_not_counted(self) -> None:
        share = repeats.measure([call(-60), call(0)], since=0, end=HOUR)
        self.assertEqual((share.calls, share.repeated_calls), (1, 1))

    def test_a_call_at_or_after_the_end_is_not_counted(self) -> None:
        share = repeats.measure([call(0), call(HOUR)], since=0, end=HOUR)
        self.assertEqual(share.calls, 1)

    def test_a_call_without_a_fingerprint_cannot_repeat(self) -> None:
        share = repeats.measure([call(0, out=None), call(60, out=None), call(120, inp=None), call(180, inp=None)], 0, HOUR)
        self.assertEqual((share.calls, share.repeated_calls), (4, 0))

    def test_the_order_of_the_input_does_not_matter(self) -> None:
        # 3601 s apart is not a repeat. Read in the order given, the later call comes first and 0 - 3601 would pass as one.
        reversed_pair = repeats.measure([call(HOUR + 1), call(0)], since=0, end=2 * HOUR)
        self.assertEqual(reversed_pair.repeated_calls, 0)
        in_order = repeats.measure([call(0), call(HOUR + 1)], since=0, end=2 * HOUR)
        self.assertEqual(in_order.repeated_calls, 0)

    def test_tools_are_tallied_apart(self) -> None:
        share = repeats.measure([call(0), call(1), call(2, tool="u", size=7), call(3, tool="u", size=7)], 0, HOUR)
        self.assertEqual(share.by_tool["t"].repeated_bytes, 100)
        self.assertEqual(share.by_tool["u"].repeated_bytes, 7)


class CallOfTest(unittest.TestCase):
    def test_a_row_without_the_identity_fields_is_dropped(self) -> None:
        self.assertIsNone(repeats.call_of({"ts": 1.0, "tool": "t"}))
        self.assertIsNone(repeats.call_of({"ts": "1", "keeper": "k", "tool": "t"}))

    def test_missing_bytes_count_as_zero_and_empty_fingerprints_as_absent(self) -> None:
        parsed = repeats.call_of({"ts": 1, "keeper": "k", "tool": "t", "input_fingerprint": "", "output_fingerprint": "o"})
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual(parsed.result_bytes, 0)
        self.assertIsNone(parsed.input_fingerprint)


    def test_negative_and_boolean_bytes_count_as_zero(self) -> None:
        base = {"ts": 1, "keeper": "k", "tool": "t"}
        for bad in (-1, True, "5", None):
            with self.subTest(bad=bad):
                parsed = repeats.call_of({**base, "result_bytes": bad})
                assert parsed is not None
                self.assertEqual(parsed.result_bytes, 0)
        parsed = repeats.call_of({**base, "result_bytes": 0})
        assert parsed is not None
        self.assertEqual(parsed.result_bytes, 0)


class ReportTest(unittest.TestCase):
    def test_percentages_and_per_day_values(self) -> None:
        share = repeats.measure([call(0), call(60)], since=0, end=HOUR)
        out = repeats.report(share, 0, HOUR)
        self.assertEqual(out["repeated_calls_pct"], 50.0)
        self.assertEqual(out["repeated_bytes_pct"], 50.0)
        self.assertEqual(out["repeated_bytes_per_day"], 2400)
        self.assertEqual(out["result_bytes_per_day"], 4800)

    def test_top_tools_are_ordered_by_repeated_bytes_not_by_repeated_calls(self) -> None:
        # "small" repeats 3 times for 3 bytes, "big" repeats once for 500 bytes.
        calls = [call(0, tool="small", size=1)] + [call(i, tool="small", size=1) for i in (1, 2, 3)]
        calls += [call(10, tool="big", size=500), call(11, tool="big", size=500)]
        out = repeats.report(repeats.measure(calls, 0, HOUR), 0, HOUR)
        top = out["top_by_repeated_bytes"]
        assert isinstance(top, list)
        self.assertEqual([entry["tool"] for entry in top], ["big", "small"])

    def test_an_empty_window_has_no_percentage(self) -> None:
        out = repeats.report(repeats.measure([], 0, HOUR), 0, HOUR)
        self.assertIsNone(out["repeated_calls_pct"])
        self.assertIsNone(out["repeated_bytes_pct"])


if __name__ == "__main__":
    unittest.main()
