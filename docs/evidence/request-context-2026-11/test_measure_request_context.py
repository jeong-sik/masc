"""Checks the arithmetic of measure_request_context.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/request-context-2026-11
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
import tempfile
import unittest
from datetime import date

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_request_context as ctx  # noqa: E402

SINCE = 1000.0
UNTIL = 2000.0
DAY = date(2026, 11, 1)
NO_TRACES = ctx.TraceReading([], frozenset(), frozenset())


def usage_row(ts: float, usage: object, *, event_type: str = ctx.USAGE_EVENT) -> str:
    return json.dumps({"v": 1, "seq": 1, "ts": ts, "event": {"type": event_type, "usage": usage}})


def write_trace(base: pathlib.Path, keeper: str, name: str, lines: list[str]) -> pathlib.Path:
    path = base / ".masc" / "keeper_turn_events" / keeper / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def media_item(raw_bytes: int, media_type: str = "image/png") -> dict[str, object]:
    return {"type": "stored", "media_type": media_type, "sha256": "x", "bytes": raw_bytes}


def capture_row(
    captured_at: float,
    body_bytes: object,
    messages: list[dict[str, object]],
    *,
    trace_id: object = None,
    absolute_turn: object = None,
) -> str:
    row: dict[str, object] = {"captured_at": captured_at, "wire": {"body_bytes": body_bytes}, "messages": messages}
    if trace_id is not None:
        row["trace_id"] = trace_id
    if absolute_turn is not None:
        row["absolute_turn"] = absolute_turn
    return json.dumps(row)


def write_captures(base: pathlib.Path, keeper: str, day: date, lines: list[str]) -> None:
    path = base / ".masc" / "keepers" / keeper / "provider-inputs" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def body(keeper: str, size: int, images: tuple[int, ...] = (), turn: ctx.TurnKey | None = None) -> ctx.RequestBody:
    return ctx.RequestBody(keeper, size, images, turn)


def traces(traced: set[ctx.KeeperTurn], answered: set[ctx.KeeperTurn]) -> ctx.TraceReading:
    return ctx.TraceReading([], frozenset(traced), frozenset(answered))


class Base64Test(unittest.TestCase):
    def test_chars_round_up_to_whole_groups_of_three_bytes(self) -> None:
        self.assertEqual([ctx.base64_chars(n) for n in (0, 1, 3, 4, 6, 62596)], [0, 4, 4, 8, 8, 83464])

    def test_only_the_oldest_images_beyond_the_kept_latest_count_as_stale(self) -> None:
        # Message order is oldest first, so the last image is the one that stays.
        sizes = (3, 3000, 6)
        self.assertEqual(ctx.stale_image_chars(sizes, 1), ctx.base64_chars(3) + ctx.base64_chars(3000))
        self.assertEqual(ctx.stale_image_chars(sizes, 2), ctx.base64_chars(3))

    def test_nothing_is_stale_when_the_request_has_no_more_images_than_are_kept(self) -> None:
        self.assertEqual(ctx.stale_image_chars((3, 3), 3), 0)
        self.assertEqual(ctx.stale_image_chars((3, 3), 2), 0)
        self.assertEqual(ctx.stale_image_chars((), 1), 0)


class TurnKeyTest(unittest.TestCase):
    def test_the_trace_id_keeps_its_hyphens_and_the_turn_is_a_number(self) -> None:
        path = pathlib.Path("trace-1788882319100-00000-8350-2c47750f0b5e9300.jsonl")
        self.assertEqual(ctx.turn_key_of(path), ("trace-1788882319100-00000", 8350))

    def test_names_that_do_not_fit_the_pattern_have_no_turn(self) -> None:
        for name in ("trace-1.jsonl", "a-b-c.jsonl", "plain.jsonl"):
            with self.subTest(name=name):
                self.assertIsNone(ctx.turn_key_of(pathlib.Path(name)))


class ReadTracesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def usages(self) -> list[ctx.Usage]:
        return ctx.read_traces(self.base, SINCE, UNTIL).usages

    def test_reads_every_field_and_keeps_the_keeper_from_the_directory(self) -> None:
        usage = {"input_tokens": 100, "output_tokens": 7, "cache_read_input_tokens": 60}
        write_trace(self.base, "alpha", "trace-1.jsonl", [usage_row(1500.0, usage)])
        self.assertEqual(self.usages(), [ctx.Usage("alpha", 100, 60, 7)])

    def test_window_bounds_are_inclusive_and_nothing_outside_counts(self) -> None:
        usage = {"input_tokens": 1}
        write_trace(
            self.base,
            "alpha",
            "trace-1.jsonl",
            [usage_row(SINCE - 0.001, usage), usage_row(SINCE, usage), usage_row(UNTIL, usage), usage_row(UNTIL + 0.001, usage)],
        )
        self.assertEqual(len(self.usages()), 2)

    def test_only_the_usage_event_type_counts(self) -> None:
        usage = {"input_tokens": 5}
        write_trace(
            self.base,
            "alpha",
            "trace-1.jsonl",
            [usage_row(1500.0, usage, event_type="tool_call_end"), usage_row(1500.0, usage)],
        )
        self.assertEqual(len(self.usages()), 1)

    def test_rows_that_cannot_be_read_are_skipped_without_stopping_the_file(self) -> None:
        usage = {"input_tokens": 5}
        lines = [
            '{"usage": broken',
            usage_row(1500.0, "not an object"),
            json.dumps({"ts": "1500", "event": {"type": ctx.USAGE_EVENT, "usage": usage}}),
            json.dumps({"ts": True, "event": {"type": ctx.USAGE_EVENT, "usage": usage}}),
            json.dumps([{"usage": usage}]),
            usage_row(1500.0, usage),
        ]
        write_trace(self.base, "alpha", "trace-1.jsonl", lines)
        self.assertEqual(len(self.usages()), 1)

    def test_a_missing_or_non_numeric_token_field_counts_as_zero(self) -> None:
        usage = {"input_tokens": 9, "output_tokens": "many", "cache_read_input_tokens": True}
        write_trace(self.base, "alpha", "trace-1.jsonl", [usage_row(1500.0, usage)])
        self.assertEqual(self.usages(), [ctx.Usage("alpha", 9, 0, 0)])

    def test_every_keeper_and_every_trace_file_is_read(self) -> None:
        usage = {"input_tokens": 1}
        write_trace(self.base, "alpha", "trace-1.jsonl", [usage_row(1500.0, usage)])
        write_trace(self.base, "alpha", "trace-2.jsonl", [usage_row(1600.0, usage)])
        write_trace(self.base, "beta", "trace-1.jsonl", [usage_row(1700.0, usage)])
        self.assertEqual(sorted(item.keeper for item in self.usages()), ["alpha", "alpha", "beta"])

    def test_a_trace_file_last_written_before_the_window_is_not_read(self) -> None:
        usage = {"input_tokens": 1}
        old = write_trace(self.base, "alpha", "trace-1-0-1-aa.jsonl", [usage_row(1500.0, usage)])
        os.utime(old, (SINCE - 10, SINCE - 10))
        new = write_trace(self.base, "alpha", "trace-1-0-2-bb.jsonl", [usage_row(1600.0, usage)])
        os.utime(new, (SINCE + 10, SINCE + 10))
        reading = ctx.read_traces(self.base, SINCE, UNTIL)
        self.assertEqual(len(reading.usages), 1)
        self.assertEqual(reading.traced, frozenset({("alpha", ("trace-1-0", 2))}))

    def test_a_store_without_traces_gives_nothing(self) -> None:
        reading = ctx.read_traces(self.base, SINCE, UNTIL)
        self.assertEqual((reading.usages, reading.traced, reading.answered), ([], frozenset(), frozenset()))

    def test_a_turn_is_traced_by_its_file_and_answered_only_with_a_usage_event(self) -> None:
        usage = {"input_tokens": 1}
        write_trace(self.base, "alpha", "trace-1-0-5-aa.jsonl", [usage_row(1500.0, usage)])
        write_trace(self.base, "alpha", "trace-1-0-6-bb.jsonl", [usage_row(1500.0, usage, event_type="event_error")])
        reading = ctx.read_traces(self.base, SINCE, UNTIL)
        self.assertEqual(reading.traced, frozenset({("alpha", ("trace-1-0", 5)), ("alpha", ("trace-1-0", 6))}))
        self.assertEqual(reading.answered, frozenset({("alpha", ("trace-1-0", 5))}))

    def test_the_same_turn_number_of_another_keeper_is_another_turn(self) -> None:
        usage = {"input_tokens": 1}
        write_trace(self.base, "alpha", "trace-1-0-5-aa.jsonl", [usage_row(1500.0, usage)])
        write_trace(self.base, "beta", "trace-1-0-5-aa.jsonl", [])
        reading = ctx.read_traces(self.base, SINCE, UNTIL)
        self.assertEqual(reading.answered, frozenset({("alpha", ("trace-1-0", 5))}))
        self.assertIn(("beta", ("trace-1-0", 5)), reading.traced)

    def test_a_usage_event_outside_the_window_still_answers_its_turn_but_adds_no_tokens(self) -> None:
        usage = {"input_tokens": 1}
        write_trace(self.base, "alpha", "trace-1-0-5-aa.jsonl", [usage_row(UNTIL + 500.0, usage)])
        reading = ctx.read_traces(self.base, SINCE, UNTIL)
        self.assertEqual(reading.usages, [])
        self.assertEqual(reading.answered, frozenset({("alpha", ("trace-1-0", 5))}))

    def test_a_file_without_a_turn_in_its_name_is_read_for_tokens_but_names_no_turn(self) -> None:
        write_trace(self.base, "alpha", "notes.jsonl", [usage_row(1500.0, {"input_tokens": 3})])
        reading = ctx.read_traces(self.base, SINCE, UNTIL)
        self.assertEqual(len(reading.usages), 1)
        self.assertEqual((reading.traced, reading.answered), (frozenset(), frozenset()))


class SummarizeUsageTest(unittest.TestCase):
    def test_totals_add_up_and_keepers_are_ordered_by_input_tokens_then_name(self) -> None:
        usages = [
            ctx.Usage("small", 10, 4, 1),
            ctx.Usage("big", 300, 200, 5),
            ctx.Usage("big", 100, 50, 3),
            ctx.Usage("alpha", 10, 0, 0),
        ]
        summary = ctx.summarize_usage(usages)
        self.assertEqual(
            (summary["keepers"], summary["requests"], summary["input_tokens"]),
            (3, 4, 420),
        )
        self.assertEqual((summary["cache_read_tokens"], summary["output_tokens"], summary["mean_input_tokens"]), (254, 9, 105))
        rows = summary["by_keeper"]
        assert isinstance(rows, list)
        self.assertEqual([row["keeper"] for row in rows], ["big", "alpha", "small"])
        self.assertEqual(
            rows[0],
            {
                "keeper": "big",
                "requests": 2,
                "input_tokens": 400,
                "cache_read_tokens": 250,
                "output_tokens": 8,
                "mean_input_tokens": 200,
            },
        )

    def test_the_mean_is_rounded_to_the_nearest_token(self) -> None:
        summary = ctx.summarize_usage([ctx.Usage("a", 2, 0, 0), ctx.Usage("a", 2, 0, 0), ctx.Usage("a", 1, 0, 0)])
        rows = summary["by_keeper"]
        assert isinstance(rows, list)
        self.assertEqual((summary["mean_input_tokens"], rows[0]["mean_input_tokens"]), (2, 2))

    def test_an_empty_window_gives_zeros(self) -> None:
        summary = ctx.summarize_usage([])
        self.assertEqual((summary["requests"], summary["input_tokens"], summary["mean_input_tokens"], summary["by_keeper"]), (0, 0, 0, []))


class ImageSizesTest(unittest.TestCase):
    def test_only_images_count_and_message_order_is_kept(self) -> None:
        messages = [
            {"media": [media_item(10), media_item(99, "application/pdf")]},
            {"role": "user"},
            {"media": [media_item(20, "image/jpeg"), "junk", {"media_type": "image/png"}]},
        ]
        self.assertEqual(ctx.image_sizes(messages), (10, 20, 0))

    def test_a_request_without_a_message_list_has_no_images(self) -> None:
        self.assertEqual(ctx.image_sizes(None), ())
        self.assertEqual(ctx.image_sizes([{"media": "none"}]), ())


class ReadRequestBodiesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def test_reads_body_bytes_image_sizes_and_the_turn(self) -> None:
        row = capture_row(1500.0, 5000, [{"media": [media_item(30), media_item(60)]}], trace_id="trace-9-0", absolute_turn=7)
        write_captures(self.base, "alpha", DAY, [row])
        bodies = ctx.read_request_bodies(self.base, DAY, DAY, SINCE, UNTIL)
        self.assertEqual(bodies, [ctx.RequestBody("alpha", 5000, (30, 60), ("trace-9-0", 7))])

    def test_a_capture_without_a_usable_trace_id_or_turn_has_no_turn(self) -> None:
        rows = [
            capture_row(1500.0, 1, [], trace_id="trace-9-0"),
            capture_row(1500.0, 2, [], absolute_turn=7),
            capture_row(1500.0, 3, [], trace_id=5, absolute_turn=7),
            capture_row(1500.0, 4, [], trace_id="trace-9-0", absolute_turn="7"),
            capture_row(1500.0, 5, [], trace_id="trace-9-0", absolute_turn=True),
        ]
        write_captures(self.base, "alpha", DAY, rows)
        bodies = ctx.read_request_bodies(self.base, DAY, DAY, SINCE, UNTIL)
        self.assertEqual([item.turn for item in bodies], [None] * 5)

    def test_reads_each_day_from_first_through_last_and_no_other_day(self) -> None:
        first, last = date(2026, 11, 1), date(2026, 11, 3)
        for day in (date(2026, 10, 31), first, date(2026, 11, 2), last, date(2026, 11, 4)):
            write_captures(self.base, "alpha", day, [capture_row(1500.0, day.day, [])])
        sizes = sorted(item.body_bytes for item in ctx.read_request_bodies(self.base, first, last, SINCE, UNTIL))
        self.assertEqual(sizes, [1, 2, 3])

    def test_days_across_a_month_boundary_are_found(self) -> None:
        write_captures(self.base, "alpha", date(2026, 10, 31), [capture_row(1500.0, 31, [])])
        write_captures(self.base, "alpha", date(2026, 11, 1), [capture_row(1500.0, 1, [])])
        bodies = ctx.read_request_bodies(self.base, date(2026, 10, 31), date(2026, 11, 1), SINCE, UNTIL)
        self.assertEqual(sorted(item.body_bytes for item in bodies), [1, 31])

    def test_window_bounds_are_inclusive_and_nothing_outside_counts(self) -> None:
        rows = [capture_row(ts, 1, []) for ts in (SINCE - 0.001, SINCE, UNTIL, UNTIL + 0.001)]
        write_captures(self.base, "alpha", DAY, rows)
        self.assertEqual(len(ctx.read_request_bodies(self.base, DAY, DAY, SINCE, UNTIL)), 2)

    def test_rows_without_a_readable_size_or_time_are_skipped(self) -> None:
        rows = [
            "{broken",
            "[1, 2]",
            json.dumps({"captured_at": 1500.0, "messages": []}),
            json.dumps({"captured_at": 1500.0, "wire": "x", "messages": []}),
            capture_row(1500.0, "5000", []),
            capture_row(1500.0, True, []),
            json.dumps({"wire": {"body_bytes": 5}, "messages": []}),
            capture_row(1500.0, 7, []),
        ]
        write_captures(self.base, "alpha", DAY, rows)
        self.assertEqual([item.body_bytes for item in ctx.read_request_bodies(self.base, DAY, DAY, SINCE, UNTIL)], [7])

    def test_every_keeper_is_read_and_a_keeper_without_captures_is_skipped(self) -> None:
        write_captures(self.base, "alpha", DAY, [capture_row(1500.0, 1, [])])
        write_captures(self.base, "beta", DAY, [capture_row(1500.0, 2, [])])
        (self.base / ".masc" / "keepers" / "gamma").mkdir(parents=True)
        keepers = sorted(item.keeper for item in ctx.read_request_bodies(self.base, DAY, DAY, SINCE, UNTIL))
        self.assertEqual(keepers, ["alpha", "beta"])

    def test_a_store_without_keepers_gives_nothing(self) -> None:
        self.assertEqual(ctx.read_request_bodies(self.base, DAY, DAY, SINCE, UNTIL), [])


def first_row(summary: dict[str, object]) -> dict[str, object]:
    rows = summary["by_keeper"]
    assert isinstance(rows, list)
    return rows[0]


class SummarizeBodiesTest(unittest.TestCase):
    def test_sizes_percentiles_and_image_counts_per_keeper(self) -> None:
        # Mean 400 and median 250 differ on purpose, so a mean that is really a median is caught.
        bodies = [body("alpha", size) for size in (1000, 100, 300, 200)]
        row = first_row(ctx.summarize_bodies(bodies, NO_TRACES))
        self.assertEqual(
            (row["body_bytes_sum"], row["body_bytes_mean"], row["body_bytes_p50"], row["body_bytes_p90"], row["body_bytes_max"]),
            (1600, 400, 300, 1000, 1000),
        )
        self.assertEqual((row["images_mean"], row["images_p50"], row["images_max"]), (0.0, 0, 0))

    def test_image_counts_use_the_mean_the_median_and_the_request_with_the_most(self) -> None:
        bodies = [body("alpha", 10, (1,) * count) for count in (0, 1, 5)]
        row = first_row(ctx.summarize_bodies(bodies, NO_TRACES))
        self.assertEqual((row["images_mean"], row["images_p50"], row["images_max"]), (2.0, 1, 5))

    def test_stale_share_is_the_base64_size_of_the_stale_images_over_the_body_bytes(self) -> None:
        raw = 3000
        encoded = ctx.base64_chars(raw)
        bodies = [body("alpha", encoded * 8, (raw,) * 4)]
        row = first_row(ctx.summarize_bodies(bodies, NO_TRACES))
        self.assertEqual(row["stale_image_share_keep_latest_1"], 0.375)
        self.assertEqual(row["stale_image_share_keep_latest_3"], 0.125)

    def test_stale_share_adds_up_over_requests_before_dividing_and_the_median_is_per_request(self) -> None:
        raw = 3000
        encoded = ctx.base64_chars(raw)
        bodies = [
            body("alpha", encoded * 4, (raw, raw)),  # one stale image: 1/4 of this body
            body("alpha", encoded * 6, (raw, raw, raw)),  # two stale images: 1/3 of this body
            body("alpha", encoded * 10),  # no stale image
        ]
        row = first_row(ctx.summarize_bodies(bodies, NO_TRACES))
        # 12000 stale chars over 80000 body bytes. The mean of the three per-request shares would be about 0.194,
        # and counting only the request with the most stale images would give 0.1.
        self.assertEqual(row["stale_image_share_keep_latest_1"], 0.15)
        # The per-request shares are 0, 0.25 and 0.333; their median is 0.25.
        self.assertEqual(row["stale_image_share_median_keep_latest_1"], 0.25)
        self.assertEqual(row["stale_image_share_median_keep_latest_3"], 0.0)

    def test_the_same_size_count_is_the_most_repeated_size_and_ties_go_to_the_larger_size(self) -> None:
        # The smaller size comes first, so a tie that is not broken by size would pick 3.
        bodies = [body("alpha", size) for size in (3, 3, 7, 7, 5)]
        row = first_row(ctx.summarize_bodies(bodies, NO_TRACES))
        self.assertEqual((row["same_size_requests_max"], row["same_size_bytes"]), (2, 7))

    def test_the_most_repeated_size_wins_over_a_larger_size_that_appears_once(self) -> None:
        bodies = [body("alpha", size) for size in (3, 3, 9)]
        row = first_row(ctx.summarize_bodies(bodies, NO_TRACES))
        self.assertEqual((row["same_size_requests_max"], row["same_size_bytes"]), (2, 3))

    def test_a_single_request_is_its_own_most_repeated_size(self) -> None:
        row = first_row(ctx.summarize_bodies([body("alpha", 42)], NO_TRACES))
        self.assertEqual((row["same_size_requests_max"], row["same_size_bytes"]), (1, 42))

    def test_a_request_is_unanswered_only_when_its_turn_has_a_trace_without_usage(self) -> None:
        answered, silent, other_keeper = ("t", 1), ("t", 2), ("t", 3)
        bodies = [
            body("alpha", 100, turn=answered),
            body("alpha", 200, turn=silent),
            body("alpha", 400, turn=("t", 4)),  # no trace file for this turn
            body("alpha", 800),  # the capture names no turn
            body("alpha", 1600, turn=other_keeper),  # only another keeper has this turn's trace
        ]
        reading = traces(
            {("alpha", answered), ("alpha", silent), ("beta", other_keeper)},
            {("alpha", answered), ("beta", other_keeper)},
        )
        row = first_row(ctx.summarize_bodies(bodies, reading))
        self.assertEqual((row["unanswered_requests"], row["unanswered_body_bytes"]), (1, 200))
        self.assertEqual(row["untraced_requests"], 3)

    def test_fleet_counts_cover_every_keeper_not_only_the_listed_ones(self) -> None:
        extra = 2
        count = ctx.TOP_BODY_KEEPERS + extra
        turn = ("t", 1)
        bodies = [body(f"k{index:02d}", 10, turn=turn) for index in range(count)]
        reading = traces({(f"k{index:02d}", turn) for index in range(count)}, set())
        summary = ctx.summarize_bodies(bodies, reading)
        self.assertEqual((summary["unanswered_requests"], summary["unanswered_body_bytes"], summary["untraced_requests"]), (count, 10 * count, 0))
        self.assertEqual(len(summary["by_keeper"]), ctx.TOP_BODY_KEEPERS)  # type: ignore[arg-type]

    def test_fleet_untraced_requests_are_counted(self) -> None:
        summary = ctx.summarize_bodies([body("alpha", 1), body("beta", 2, turn=("t", 1))], NO_TRACES)
        self.assertEqual((summary["unanswered_requests"], summary["untraced_requests"]), (0, 2))

    def test_keepers_are_ordered_by_total_body_bytes_and_the_list_is_capped(self) -> None:
        extra = 2
        bodies = [body(f"k{index:02d}", 100 + index) for index in range(ctx.TOP_BODY_KEEPERS + extra)]
        summary = ctx.summarize_bodies(bodies, NO_TRACES)
        rows = summary["by_keeper"]
        assert isinstance(rows, list)
        self.assertEqual(summary["keepers"], ctx.TOP_BODY_KEEPERS + extra)
        self.assertEqual(len(rows), ctx.TOP_BODY_KEEPERS)
        sums = [row["body_bytes_sum"] for row in rows]
        self.assertEqual(sums, sorted(sums, reverse=True))
        self.assertEqual(rows[0]["keeper"], f"k{ctx.TOP_BODY_KEEPERS + extra - 1:02d}")

    def test_fleet_totals_cover_every_keeper_not_only_the_listed_ones(self) -> None:
        extra = 2
        bodies = [body(f"k{index:02d}", 10) for index in range(ctx.TOP_BODY_KEEPERS + extra)]
        summary = ctx.summarize_bodies(bodies, NO_TRACES)
        self.assertEqual((summary["requests"], summary["body_bytes_sum"]), (ctx.TOP_BODY_KEEPERS + extra, 10 * (ctx.TOP_BODY_KEEPERS + extra)))

    def test_fleet_percentiles_and_max_come_from_all_requests(self) -> None:
        bodies = [body("a" if index % 2 else "b", size) for index, size in enumerate(range(1, 101))]
        summary = ctx.summarize_bodies(bodies, NO_TRACES)
        self.assertEqual((summary["body_bytes_p50"], summary["body_bytes_p99"], summary["body_bytes_max"]), (51, 100, 100))

    def test_no_requests_gives_zeros(self) -> None:
        summary = ctx.summarize_bodies([], NO_TRACES)
        self.assertEqual((summary["requests"], summary["body_bytes_sum"], summary["body_bytes_max"], summary["by_keeper"]), (0, 0, 0, []))
        self.assertEqual((summary["unanswered_requests"], summary["untraced_requests"]), (0, 0))


if __name__ == "__main__":
    unittest.main()
