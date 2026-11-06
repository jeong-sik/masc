#!/usr/bin/env python3
"""The tool-efficiency chart draws what the measurement JSON says and refuses input it cannot draw."""
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from collections.abc import Sequence
from contextlib import redirect_stderr, redirect_stdout
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import ModuleType

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


CHART = load("tool_efficiency_chart", "tool-efficiency-chart.py")

MB = 1_000_000
SVG_NS = "{http://www.w3.org/2000/svg}"
FIRST_DAY = datetime(2026, 11, 4, tzinfo=UTC)
Row = dict[str, float]
Result = dict[str, dict[str, Row]]
DAILY_TIP = re.compile(r"^\d\d-\d\d · ")
HOURLY_TIP = re.compile(r"^\d\d-\d\dT\d\dZ · ")
VALUE_LABEL = re.compile(r'class="ink2" text-anchor="middle">(\d+\.\d%?)<')
DAY_LABEL = re.compile(r'class="muted" text-anchor="middle">(\d\d-\d\d\*?)<')


def fields(result_mb: float = 0.0, spilled_mb: float = 0.0, reread_mb: float = 0.0, wait_s: float = 0.0, calls: int = 1) -> Row:
    return {
        "calls": calls,
        "failed": 0,
        "time_s": 1.0,
        "result_bytes": int(result_mb * MB),
        "spilled_bytes": int(spilled_mb * MB),
        "reread_bytes": int(reread_mb * MB),
        "wait_s": wait_s,
    }


def result(days: int = 2, last_hour: int = 23, hourly_mb: float = 4.0, spilled_mb: float = 1.0) -> Result:
    """`days` UTC days; the last one ends at `last_hour`, so it is partial unless that is 23."""
    daily: dict[str, Row] = {}
    hourly: dict[str, Row] = {}
    for offset in range(days):
        day = FIRST_DAY + timedelta(days=offset)
        daily[day.strftime("%Y-%m-%d")] = fields(100.0, 40.0 + offset, 20.0 + offset, 3600.0 * (offset + 1))
        end = last_hour if offset == days - 1 else 23
        for hour in range(end + 1):
            hourly[(day + timedelta(hours=hour)).strftime("%Y-%m-%dT%H")] = fields(hourly_mb, spilled_mb)
    return {"daily": daily, "hourly": hourly}


def render(data: Result | None = None, hours: int = 24, marks: Sequence[object] = ()) -> str:
    return str(CHART.render(data or result(), hours, list(marks)))


def titles(svg: str) -> list[str]:
    return [element.text or "" for element in ET.fromstring(svg).iter(SVG_NS + "title")]


def group(pattern: str, haystack: str, number: int = 1) -> str:
    found = re.search(pattern, haystack)
    if found is None:
        raise AssertionError(f"{pattern!r} is not in the text")
    return str(found.group(number))


def path_numbers(d: str) -> list[float]:
    return [float(token) for token in re.findall(r"-?\d+\.?\d*", d)]


def mark(hour: int, minute: int, label: str) -> object:
    return CHART.Mark(datetime(2026, 11, 5, hour, minute, tzinfo=UTC), label)


class NiceScaleTests(unittest.TestCase):
    def test_ticks_are_clean_steps_that_cover_the_peak(self):
        self.assertEqual(CHART.nice_scale(58.02), (60.0, [0.0, 20.0, 40.0, 60.0]))
        self.assertEqual(CHART.nice_scale(13.4), (15.0, [0.0, 5.0, 10.0, 15.0]))
        self.assertEqual(CHART.nice_scale(20.0), (20.0, [0.0, 5.0, 10.0, 15.0, 20.0]))

    def test_a_peak_below_one_gets_decimal_steps(self):
        top, ticks = CHART.nice_scale(0.35)
        self.assertAlmostEqual(top, 0.4)
        self.assertEqual(len(ticks), 5)

    def test_no_data_still_has_an_axis(self):
        self.assertEqual(CHART.nice_scale(0.0), (1.0, [0.0, 1.0]))

    def test_a_tick_prints_without_float_noise(self):
        self.assertEqual(CHART.format_tick(0.1 + 0.2, ""), "0.3")
        self.assertEqual(CHART.format_tick(20.0, "%"), "20%")


class ShapeTests(unittest.TestCase):
    def test_a_column_has_a_square_foot_and_a_rounded_end(self):
        rounded = CHART.column_path(10.0, 100.0, 20.0, 50.0, True)
        self.assertEqual(rounded.count("A"), 2)
        self.assertTrue(rounded.startswith("M10.00,100.00V54.00"))
        self.assertTrue(rounded.endswith("V100.00Z"))

    def test_a_column_that_is_not_the_data_end_is_square(self):
        self.assertNotIn("A", CHART.column_path(10.0, 100.0, 20.0, 50.0, False))

    def test_a_short_column_never_rounds_past_its_height(self):
        self.assertIn("A2.00,2.00", CHART.column_path(0.0, 100.0, 20.0, 2.0, True))

    def test_a_share_of_nothing_is_zero(self):
        self.assertEqual(CHART.share(0, 0), 0.0)
        self.assertAlmostEqual(CHART.share(1, 4), 25.0)

    def test_a_bar_is_as_wide_as_the_slot_less_its_gap_up_to_the_cap(self):
        self.assertEqual(CHART.bar_width_of(10.0, 3, 2.0, "days"), 8.0)
        self.assertEqual(CHART.bar_width_of(100.0, 3, 2.0, "days"), CHART.MAX_BAR)

    def test_a_bar_that_would_vanish_is_an_error_that_names_the_count(self):
        with self.assertRaises(ValueError) as caught:
            CHART.bar_width_of(2.5, 40, 2.0, "days")
        self.assertIn("40 days", str(caught.exception))


class LabelThinningTests(unittest.TestCase):
    five_chars = ["10.0%"] * 6

    def test_every_value_label_stays_when_they_fit_side_by_side(self):
        self.assertEqual(CHART.peak_and_last(self.five_chars, [1, 9, 3, 2, 2, 2], 40.0), {0, 1, 2, 3, 4, 5})

    def test_a_dense_row_keeps_the_peak_and_a_last_bar_clear_of_it(self):
        self.assertEqual(CHART.peak_and_last(self.five_chars, [1, 9, 3, 2, 2, 2], 14.0), {1, 5})

    def test_a_dense_row_keeps_one_label_when_the_last_bar_is_the_peak_or_next_to_it(self):
        self.assertEqual(CHART.peak_and_last(self.five_chars, [1, 2, 3, 4, 5, 9], 14.0), {5})
        self.assertEqual(CHART.peak_and_last(self.five_chars, [1, 2, 3, 4, 9, 5], 14.0), {4})

    def test_a_dense_row_keeps_both_labels_when_the_last_bar_is_exactly_one_label_away(self):
        self.assertEqual(CHART.peak_and_last(self.five_chars, [1, 2, 3, 9, 4, 5], 14.0), {3, 5})

    def test_the_widest_label_sets_the_step(self):
        self.assertEqual(CHART.label_step(["1.0%", "58.0%"], 25.0), 2)
        self.assertEqual(CHART.label_step(["1.0%", "5.0%"], 25.0), 1)

    def test_day_names_thin_out_from_the_newest_day(self):
        names = ["11-01", "11-02", "11-03", "11-04", "11-05", "11-06", "11-07"]
        self.assertEqual(CHART.every_nth_from_last(names, 40.0), {0, 1, 2, 3, 4, 5, 6})
        self.assertEqual(CHART.every_nth_from_last(names, 14.0), {6, 4, 2, 0})
        self.assertEqual(CHART.every_nth_from_last(names, 10.0), {6, 3, 0})


class ParseTests(unittest.TestCase):
    def test_series_are_sorted_by_time(self):
        data = {"daily": {"2026-11-05": fields(), "2026-11-04": fields()}, "hourly": {}}
        days = CHART.parse_series(data, "daily", CHART.DAY_FORMAT)
        self.assertEqual([d.start.day for d in days], [4, 5])

    def test_a_wrong_field_is_named(self):
        wrong: tuple[tuple[str, object], ...] = (
            ("wait_s", None),
            ("result_bytes", -1),
            ("calls", True),
            ("spilled_bytes", "9"),
            ("reread_bytes", float("inf")),
        )
        for name, value in wrong:
            row: dict[str, object] = dict(fields())
            row[name] = value
            with self.assertRaises(ValueError, msg=name) as caught:
                CHART.parse_series({"daily": {"2026-11-04": row}}, "daily", CHART.DAY_FORMAT)
            self.assertIn(name, str(caught.exception))

    def test_a_missing_field_is_named(self):
        row = fields()
        del row["wait_s"]
        with self.assertRaises(ValueError) as caught:
            CHART.parse_series({"daily": {"2026-11-04": row}}, "daily", CHART.DAY_FORMAT)
        self.assertIn("wait_s", str(caught.exception))

    def test_a_bad_key_and_a_non_object_are_refused(self):
        with self.assertRaises(ValueError):
            CHART.parse_series({"daily": {"11/04": fields()}}, "daily", CHART.DAY_FORMAT)
        with self.assertRaises(ValueError):
            CHART.parse_series({"daily": []}, "daily", CHART.DAY_FORMAT)
        with self.assertRaises(ValueError):
            CHART.parse_series({"daily": {"2026-11-04": 5}}, "daily", CHART.DAY_FORMAT)

    def test_an_empty_series_is_refused(self):
        with self.assertRaises(ValueError) as caught:
            CHART.parse_series({"hourly": {}}, "hourly", CHART.HOUR_FORMAT)
        self.assertIn("hourly", str(caught.exception))

    def test_a_file_that_is_not_an_object_or_not_json_is_refused_with_its_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "r.json"
            for body in ('{"daily": NaN}', "{", "[]"):
                path.write_text(body, encoding="utf-8")
                with self.assertRaises(ValueError, msg=body):
                    CHART.read_result(path)
            path.write_text("{", encoding="utf-8")
            with self.assertRaises(ValueError) as caught:
                CHART.read_result(path)
            self.assertIn("r.json", str(caught.exception))

    def test_a_mark_is_an_instant_and_a_label(self):
        parsed = CHART.parse_mark("2026-11-05T02:19:09Z=boot")
        self.assertEqual(parsed.at, datetime(2026, 11, 5, 2, 19, 9, tzinfo=UTC))
        self.assertEqual(parsed.label, "boot")


class WindowTests(unittest.TestCase):
    def test_the_window_ends_with_the_last_hour(self):
        hourly = CHART.parse_series(result(last_hour=9), "hourly", CHART.HOUR_FORMAT)
        window = CHART.hour_window(hourly, 12)
        self.assertEqual(len(window), 12)
        self.assertEqual(window[-1].start, datetime(2026, 11, 5, 9, tzinfo=UTC))
        self.assertEqual(window[0].start, datetime(2026, 11, 4, 22, tzinfo=UTC))

    def test_an_hour_without_a_row_is_an_hour_without_calls(self):
        data = result(last_hour=9)
        del data["hourly"]["2026-11-05T05"]
        window = CHART.hour_window(CHART.parse_series(data, "hourly", CHART.HOUR_FORMAT), 6)
        gap = next(bucket for bucket in window if bucket.start.hour == 5)
        self.assertEqual((gap.calls, gap.result_bytes), (0, 0))

    def test_a_window_longer_than_the_input_reaches_back_with_empty_hours(self):
        hourly = CHART.parse_series(result(days=1), "hourly", CHART.HOUR_FORMAT)
        window = CHART.hour_window(hourly, 30)
        self.assertEqual(sum(1 for bucket in window if bucket.calls == 0), 6)


class RenderTests(unittest.TestCase):
    def test_the_picture_is_well_formed_svg(self):
        root = ET.fromstring(render())
        self.assertEqual(root.tag, SVG_NS + "svg")
        self.assertEqual(root.get("role"), "img")

    def test_every_bar_has_a_title_with_its_numbers(self):
        found = titles(render(hours=24))
        self.assertEqual(len(found), 1 + 3 * 2 + 24)
        self.assertEqual(sum(1 for t in found if DAILY_TIP.match(t)), 3 * 2)
        self.assertEqual(sum(1 for t in found if HOURLY_TIP.match(t)), 24)
        self.assertIn("11-04 · identical re-reads 20.0% of 100.00 MB (20.00 MB)", found)
        self.assertIn("11-05 · Execute blocked 2.0 h (7,200 s)", found)
        self.assertIn("11-05T00Z · 1 call · spilled 1.00 MB (25.0% of 4.00 MB) · inline 3.00 MB", found)

    def test_one_call_is_singular(self):
        bucket = CHART.Bucket(datetime(2026, 11, 5, tzinfo=UTC), 1, MB, 0, 0, 0.0)
        self.assertIn("· 1 call ·", CHART.hour_tip(bucket))
        self.assertIn("· 2 calls ·", CHART.hour_tip(CHART.Bucket(bucket.start, 2, MB, 0, 0, 0.0)))

    def test_the_output_is_the_same_every_time(self):
        self.assertEqual(render(), render())

    def test_a_partial_last_day_is_starred_and_explained(self):
        svg = render(result(last_hour=9))
        self.assertIn(">11-05*<", svg)
        self.assertIn("the last hour read starts at 09:00Z", svg)

    def test_only_the_last_day_is_starred(self):
        svg = render(result(last_hour=9))
        self.assertNotIn(">11-04*<", svg)
        self.assertIn(">11-04<", svg)

    def test_a_whole_last_day_has_no_star(self):
        self.assertNotIn("*", render(result(last_hour=23)))

    def test_each_panel_has_one_baseline_and_gridlines_above_it(self):
        svg = render()
        self.assertEqual(svg.count('<line x1="') - svg.count('class="mark"'), svg.count('class="axis"') + svg.count('class="grid"'))
        self.assertEqual(svg.count('class="axis"'), 4)
        self.assertGreater(svg.count('class="grid"'), 4)

    def test_the_hour_axis_names_every_sixth_hour_and_the_day_at_midnight(self):
        svg = render()
        for hour in ("00", "06", "12", "18"):
            self.assertIn(f'class="muted" text-anchor="middle">{hour}<', svg)
        self.assertNotIn('class="muted" text-anchor="middle">01<', svg)
        self.assertIn('class="ink2" text-anchor="middle">11-05<', svg)

    def test_value_labels_keep_one_decimal(self):
        svg = render()
        self.assertIn(">20.0%<", svg)
        self.assertIn(">1.0<", svg)

    def test_five_days_label_every_bar(self):
        svg = render(result(days=5))
        self.assertEqual(len(VALUE_LABEL.findall(svg)), 3 * 5)
        self.assertEqual(len(DAY_LABEL.findall(svg)), 3 * 5)

    def test_a_dense_row_of_days_keeps_the_peak_and_names_every_other_day(self):
        svg = render(result(days=12))
        self.assertEqual(len(VALUE_LABEL.findall(svg)), 3)
        self.assertEqual(len(DAY_LABEL.findall(svg)), 3 * 6)
        self.assertIn(">11-15<", svg)
        self.assertNotIn(">11-14<", svg)

    def test_the_most_days_that_fit_draw_and_one_more_is_an_error(self):
        panel = (CHART.WIDTH - CHART.LEFT - CHART.RIGHT - CHART.PANEL_GAP * (CHART.PANEL_COUNT - 1)) / CHART.PANEL_COUNT
        fit = int((panel - CHART.TICK_COLUMN) // (2 * CHART.SURFACE_GAP + CHART.MIN_BAR))
        ET.fromstring(render(result(days=fit)))
        with self.assertRaises(ValueError) as caught:
            render(result(days=fit + 1))
        self.assertIn(f"{fit + 1} days", str(caught.exception))

    def test_the_most_hours_that_fit_draw_and_one_more_is_an_error(self):
        plot = CHART.WIDTH - CHART.RIGHT - CHART.LEFT - CHART.TICK_COLUMN
        fit = int(plot // (CHART.SURFACE_GAP + CHART.MIN_BAR))
        ET.fromstring(render(result(days=3), hours=fit))
        with self.assertRaises(ValueError) as caught:
            render(result(days=3), hours=fit + 1)
        self.assertIn(f"{fit + 1} hours", str(caught.exception))

    def test_input_without_any_bytes_draws_axes_and_no_bar(self):
        data = {"daily": {"2026-11-04": fields()}, "hourly": {"2026-11-04T23": fields()}}
        svg = render(data, hours=6)
        ET.fromstring(svg)
        self.assertNotIn("<path", svg)
        self.assertNotIn("nan", svg.lower())

    def test_colors_are_literal_and_dark_and_forced_colors_are_declared(self):
        self.assertNotIn("var(", CHART.STYLE)
        self.assertIn("@media (prefers-color-scheme:dark)", CHART.STYLE)
        self.assertIn("@media (forced-colors:active)", CHART.STYLE)
        for color in ("#2a78d6", "#3987e5", "#fcfcfb", "#1a1a19"):
            self.assertIn(color, CHART.STYLE)

    def test_text_is_escaped(self):
        svg = render(marks=[mark(3, 0, "a<b & c")])
        self.assertIn("a&lt;b &amp; c", svg)
        ET.fromstring(svg)

    def test_hours_below_one_are_refused(self):
        with self.assertRaises(ValueError):
            render(hours=0)


class StackTests(unittest.TestCase):
    def bars(self, spilled_mb: float, result_mb: float = 4.0) -> tuple[list[str], list[str]]:
        bucket = CHART.Bucket(datetime(2026, 11, 5, tzinfo=UTC), 1, int(result_mb * MB), int(spilled_mb * MB), 0, 0.0)
        drawn = [p for p in CHART.hourly_panel([bucket], []) if p.startswith("<path")]
        return [group(r'class="(\w+)"', p) for p in drawn], [group(r'd="([^"]+)"', p) for p in drawn]

    def test_the_spilled_part_sits_one_gap_above_the_inline_part(self):
        classes, shapes = self.bars(1.0)
        self.assertEqual(classes, ["context", "accent"])
        context_top = path_numbers(shapes[0])[2]
        accent_bottom = path_numbers(shapes[1])[1]
        self.assertAlmostEqual(context_top - accent_bottom, CHART.SURFACE_GAP, places=1)

    def test_the_inline_part_is_square_under_a_spilled_part(self):
        _, shapes = self.bars(1.0)
        self.assertNotIn("A", shapes[0])
        self.assertIn("A", shapes[1])

    def test_the_stack_ends_at_the_hours_total(self):
        _, shapes = self.bars(1.0)
        top = path_numbers(shapes[1])[9]
        self.assertAlmostEqual(top, CHART.HOURLY_TOP, places=1)

    def test_with_nothing_spilled_the_inline_part_takes_the_rounded_end(self):
        classes, shapes = self.bars(0.0)
        self.assertEqual(classes, ["context"])
        self.assertIn("A", shapes[0])

    def test_a_spilled_part_under_one_pixel_draws_nothing(self):
        classes, _ = self.bars(0.001)
        self.assertEqual(classes, ["context"])

    def test_an_hour_with_nothing_draws_no_bar(self):
        classes, _ = self.bars(0.0, result_mb=0.0)
        self.assertEqual(classes, [])


class MarkTests(unittest.TestCase):
    def test_a_mark_is_a_line_and_a_label_with_its_time(self):
        svg = render(marks=[mark(3, 30, "m3")])
        self.assertIn(">03:30 m3<", svg)
        self.assertEqual(svg.count('class="mark"'), 1)

    def test_a_label_that_would_leave_the_picture_is_written_to_the_left_of_its_line(self):
        near_the_end = render(marks=[mark(23, 30, "end")])
        near_the_start = render(marks=[mark(1, 30, "start")])
        self.assertIn('text-anchor="end">23:30 end<', near_the_end)
        self.assertIn('text-anchor="start">01:30 start<', near_the_start)

    def test_each_mark_has_its_own_row_and_the_leftmost_is_highest(self):
        svg = render(marks=[mark(8, 30, "m8"), mark(2, 30, "m2"), mark(5, 30, "m5")])
        rows = {name: float(group(rf'<text x="[\d.]+" y="([\d.]+)"[^>]*>\d\d:\d\d {name}<', svg)) for name in ("m2", "m5", "m8")}
        self.assertEqual(len(set(rows.values())), 3)
        self.assertLess(rows["m2"], rows["m5"])
        self.assertLess(rows["m5"], rows["m8"])

    def test_a_mark_outside_the_plotted_hours_is_an_error(self):
        early = CHART.Mark(datetime(2026, 11, 4, 23, tzinfo=UTC), "early")
        with self.assertRaises(ValueError) as caught:
            render(marks=[early], hours=24)
        self.assertIn("early", str(caught.exception))
        with self.assertRaises(ValueError):
            render(marks=[CHART.Mark(datetime(2026, 11, 6, tzinfo=UTC), "late")], hours=24)

    def test_the_first_and_the_last_instant_of_the_window_are_inside(self):
        render(marks=[CHART.Mark(datetime(2026, 11, 5, tzinfo=UTC), "first")], hours=24)
        render(marks=[CHART.Mark(datetime(2026, 11, 5, 23, 59, 59, tzinfo=UTC), "last")], hours=24)

    def test_more_marks_than_rows_are_refused(self):
        with self.assertRaises(ValueError):
            render(marks=[mark(hour, 0, f"m{hour}") for hour in (1, 2, 3, 4)])


class CommandLineTests(unittest.TestCase):
    def write(self, tmp: str, data: dict[str, dict[str, Row]] | None = None, name: str = "r.json") -> str:
        path = Path(tmp) / name
        path.write_text(json.dumps(data or result()), encoding="utf-8")
        return str(path)

    def test_the_svg_goes_to_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "c.svg"
            self.assertEqual(CHART.main(["--json", self.write(tmp), "--out", str(out), "--hours", "24"]), 0)
            ET.parse(out)
            self.assertTrue(out.read_text(encoding="utf-8").endswith("</svg>\n"))

    def test_without_out_the_svg_goes_to_standard_output_with_the_default_hours(self):
        with tempfile.TemporaryDirectory() as tmp:
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                CHART.main(["--json", self.write(tmp)])
            found = titles(buffer.getvalue())
            self.assertEqual(sum(1 for t in found if HOURLY_TIP.match(t)), 48)

    def test_a_mark_is_read_as_instant_equals_label(self):
        with tempfile.TemporaryDirectory() as tmp:
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                CHART.main(["--json", self.write(tmp), "--hours", "24", "--mark", "2026-11-05T02:19:09Z=a=b"])
            self.assertIn("02:19 a=b", buffer.getvalue())

    def test_bad_input_exits_with_code_two_and_the_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = self.write(tmp)
            empty = self.write(tmp, {"daily": {}, "hourly": {}}, "empty.json")
            cases = (
                (["--json", good, "--mark", "2026-11-05=x"], "not a UTC instant"),
                (["--json", good, "--mark", "2026-11-05T02:19:09Z"], "INSTANT=LABEL"),
                (["--json", good, "--mark", "2026-11-05T02:19:09Z="], "INSTANT=LABEL"),
                (["--json", empty], "no buckets"),
                (["--json", good, "--hours", "0"], "--hours must be at least 1"),
                (["--json", good, "--hours", "24", "--mark", "2026-11-09T00:00:00Z=far"], "outside the plotted hours"),
            )
            for argv, needle in cases:
                errors = io.StringIO()
                with self.assertRaises(SystemExit) as caught, redirect_stderr(errors), redirect_stdout(io.StringIO()):
                    CHART.main(argv)
                self.assertEqual(caught.exception.code, 2, argv)
                self.assertIn(needle, errors.getvalue(), argv)


if __name__ == "__main__":
    unittest.main()
