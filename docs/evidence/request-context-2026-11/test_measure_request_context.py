"""Checks the arithmetic of measure_request_context.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/request-context-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from collections import Counter
from datetime import date
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_request_context as ctx  # noqa: E402

SINCE = 1000.0
UNTIL = 2000.0
DAY = date(2026, 11, 1)
NO_TRACES = ctx.TraceReading([], frozenset(), frozenset())
SHA_A = "a" * 64
SHA_B = "b" * 64
SHA_C = "c" * 64


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
    tool_schemas: object = None,
    system_prompt: object = None,
) -> str:
    row: dict[str, object] = {"captured_at": captured_at, "wire": {"body_bytes": body_bytes}, "messages": messages}
    if trace_id is not None:
        row["trace_id"] = trace_id
    if absolute_turn is not None:
        row["absolute_turn"] = absolute_turn
    if tool_schemas is not None:
        row["tool_schemas"] = tool_schemas
    if system_prompt is not None:
        row["system_prompt"] = system_prompt
    return json.dumps(row)


def write_captures(base: pathlib.Path, keeper: str, day: date, lines: list[str]) -> None:
    path = base / ".masc" / "keepers" / keeper / "provider-inputs" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def body(
    keeper: str,
    size: int,
    images: tuple[int, ...] = (),
    turn: ctx.TurnKey | None = None,
    *,
    tools: tuple[tuple[str, int], ...] = (),
    system: int = 0,
    sha: str | None = None,
) -> ctx.RequestBody:
    return ctx.RequestBody(keeper, size, images, turn, tools, system, sha)


def blob_ref(sha: str) -> str:
    return f'[masc:blob sha256={sha} bytes=10 mime=application/json preview=""]'


def schema_entry(name: str, size: int, sha: str | None = None) -> dict[str, object]:
    artifact: dict[str, object] = {"bytes": size}
    if sha is not None:
        artifact["content_ref"] = blob_ref(sha)
    return {"index": 0, "name": name, "artifact": artifact}


def identity_json(name: str) -> str:
    """One skill row's identity the way the server prints it: compact, UTF-8."""
    identity = {"source_id": "src", "package_id": "pkg", "name": name}
    return json.dumps(identity, separators=(",", ":"), ensure_ascii=False)


def skill_schema_text(rows: list[tuple[str, str]], *, head: str = "Read one Skill.") -> str:
    block = "\n".join(f"{identity_json(name)}: {text}" for name, text in rows)
    return json.dumps({"name": ctx.SKILL_TOOL, "description": f"{head}\n\nAvailable:\n{block}", "input_schema": {}})


def ledger_row(ts: object, keeper: object, tool: str, tool_input: object = None, *, record_kind: str = "tool_call") -> str:
    row: dict[str, object] = {"ts": ts, "record_kind": record_kind, "keeper": keeper, "tool": tool}
    if tool_input is not None:
        row["input"] = tool_input
    return json.dumps(row)


def skill_input(name: str) -> dict[str, object]:
    return {"identity": {"source_id": "src", "package_id": "pkg", "name": name}}


def write_ledger(base: pathlib.Path, day: date, lines: list[str], *, segment: int | None = None) -> None:
    name = f"{day.day:02d}.jsonl" if segment is None else f"{day.day:02d}.{segment:03d}.jsonl"
    path = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


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

    def test_reads_tool_schema_sizes_the_system_prompt_and_the_skill_blob_reference(self) -> None:
        schemas = [schema_entry("alpha_tool", 10), schema_entry(ctx.SKILL_TOOL, 20, SHA_A)]
        row = capture_row(1500.0, 5000, [], tool_schemas=schemas, system_prompt={"bytes": 77, "content_ref": "x"})
        write_captures(self.base, "alpha", DAY, [row])
        (item,) = ctx.read_request_bodies(self.base, DAY, DAY, SINCE, UNTIL)
        self.assertEqual(item.tools, (("alpha_tool", 10), (ctx.SKILL_TOOL, 20)))
        self.assertEqual((item.system_bytes, item.skill_schema_sha), (77, SHA_A))

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

    def test_a_keeper_row_takes_the_tool_and_system_medians_over_the_requests_that_have_them(self) -> None:
        bodies = [
            body("alpha", 10, tools=(("a", 300),), system=3000),
            body("alpha", 10, tools=(("a", 100),), system=1000),
            body("alpha", 10),  # a capture with neither: counted as a zero it would make the medians 100 and 1000
        ]
        row = first_row(ctx.summarize_bodies(bodies, NO_TRACES))
        self.assertEqual((row["tool_schema_bytes_p50"], row["system_prompt_bytes_p50"]), (300, 3000))

    def test_a_keeper_row_without_any_tool_or_system_bytes_gives_zeros(self) -> None:
        row = first_row(ctx.summarize_bodies([body("alpha", 10)], NO_TRACES))
        self.assertEqual((row["tool_schema_bytes_p50"], row["system_prompt_bytes_p50"]), (0, 0))


class ToolSchemaReadingTest(unittest.TestCase):
    def test_every_well_formed_entry_gives_its_name_and_size_in_order(self) -> None:
        entries = [schema_entry("b", 20), schema_entry("a", 10)]
        self.assertEqual(ctx.tool_schema_sizes(entries), (("b", 20), ("a", 10)))

    def test_entries_without_a_name_a_size_or_an_artifact_are_left_out(self) -> None:
        entries = [
            schema_entry("ok", 5),
            {"artifact": {"bytes": 7}},
            {"name": "no-artifact"},
            {"name": "no-size", "artifact": {}},
            {"name": "bool-size", "artifact": {"bytes": True}},
            {"name": "text-size", "artifact": {"bytes": "9"}},
            {"name": 3, "artifact": {"bytes": 1}},
            "not an entry",
        ]
        self.assertEqual(ctx.tool_schema_sizes(entries), (("ok", 5),))

    def test_a_capture_without_a_tool_list_has_no_tools(self) -> None:
        for value in (None, {}, "x", 3):
            with self.subTest(value=value):
                self.assertEqual(ctx.tool_schema_sizes(value), ())

    def test_the_system_prompt_size_is_its_bytes_field(self) -> None:
        self.assertEqual(ctx.system_prompt_bytes({"bytes": 123, "content_ref": "x"}), 123)
        for value in (None, {}, {"bytes": "9"}, {"bytes": True}, "x"):
            with self.subTest(value=value):
                self.assertEqual(ctx.system_prompt_bytes(value), 0)


class SkillSchemaShaTest(unittest.TestCase):
    def test_the_sha_is_read_from_the_keeper_skill_entry_and_no_other_tool(self) -> None:
        entries = [schema_entry("other", 1, SHA_A), schema_entry(ctx.SKILL_TOOL, 2, SHA_B)]
        self.assertEqual(ctx.skill_schema_sha(entries), SHA_B)

    def test_a_schema_with_nothing_to_read_gives_none(self) -> None:
        cases: dict[str, object] = {
            "no keeper_skill entry": [schema_entry("other", 1, SHA_A)],
            "no artifact": [{"name": ctx.SKILL_TOOL}],
            "no content_ref": [schema_entry(ctx.SKILL_TOOL, 1)],
            "reference without a sha": [{"name": ctx.SKILL_TOOL, "artifact": {"content_ref": "[masc:blob bytes=1]"}}],
            "sha too short": [{"name": ctx.SKILL_TOOL, "artifact": {"content_ref": "[masc:blob sha256=abc]"}}],
            "reference is not text": [{"name": ctx.SKILL_TOOL, "artifact": {"content_ref": 5}}],
            "no tool list": None,
        }
        for label, value in cases.items():
            with self.subTest(label):
                self.assertIsNone(ctx.skill_schema_sha(value))


class ParseSkillListTest(unittest.TestCase):
    def test_a_row_counts_its_identity_and_its_description_apart(self) -> None:
        parsed = ctx.parse_skill_list(skill_schema_text([("one", "abc"), ("twenty-two", "defgh")]))
        assert parsed is not None
        # Names and descriptions differ in length on purpose, so swapped or merged fields are caught.
        self.assertEqual(
            parsed.rows,
            (ctx.SkillRow(len(identity_json("one")), 3), ctx.SkillRow(len(identity_json("twenty-two")), 5)),
        )
        block = f"{identity_json('one')}: abc\n{identity_json('twenty-two')}: defgh"
        self.assertEqual(parsed.block_bytes, len(block))

    def test_sizes_are_utf8_bytes_and_not_characters(self) -> None:
        parsed = ctx.parse_skill_list(skill_schema_text([("한글", "설명")]))
        assert parsed is not None
        self.assertEqual(parsed.rows[0].description_bytes, len("설명".encode("utf-8")))
        self.assertEqual(parsed.rows[0].identity_bytes, len(identity_json("한글").encode("utf-8")))
        self.assertEqual(parsed.block_bytes, len(f"{identity_json('한글')}: 설명".encode("utf-8")))

    def test_only_the_text_after_the_marker_is_the_list(self) -> None:
        parsed = ctx.parse_skill_list(skill_schema_text([("one", "abc")], head="x" * 500))
        assert parsed is not None
        self.assertEqual(parsed.block_bytes, len(f"{identity_json('one')}: abc"))

    def test_a_line_that_does_not_start_a_row_continues_the_row_before_it(self) -> None:
        # Lines that begin like a JSON number, list or string are still text of the row before them.
        extra = 'second line\n42 is a number\n[1] a list\n"quoted" text'
        block = f"{identity_json('one')}: first\n{extra}\n{identity_json('two')}: next"
        parsed = ctx.parse_skill_list(json.dumps({"description": f"Head\n\nAvailable:\n{block}"}))
        assert parsed is not None
        self.assertEqual([row.description_bytes for row in parsed.rows], [len(f"first\n{extra}"), len("next")])

    def test_an_object_without_the_identity_keys_does_not_start_a_row(self) -> None:
        other = json.dumps({"name": "x"}, separators=(",", ":"))
        block = f"{identity_json('one')}: first\n{other}: not a row"
        parsed = ctx.parse_skill_list(json.dumps({"description": f"Head\n\nAvailable:\n{block}"}))
        assert parsed is not None
        self.assertEqual(len(parsed.rows), 1)
        self.assertEqual(parsed.rows[0].description_bytes, len(f"first\n{other}: not a row"))

    def test_an_identity_needs_the_separator_right_after_it_to_start_a_row(self) -> None:
        block = f"{identity_json('one')}: first\n{identity_json('two')} no separator"
        parsed = ctx.parse_skill_list(json.dumps({"description": f"Head\n\nAvailable:\n{block}"}))
        assert parsed is not None
        self.assertEqual(len(parsed.rows), 1)

    def test_an_empty_list_has_no_rows_and_no_bytes(self) -> None:
        parsed = ctx.parse_skill_list(json.dumps({"description": "Head\n\nAvailable:\n"}))
        self.assertEqual(parsed, ctx.SkillList((), 0))

    def test_a_schema_without_a_readable_list_gives_none(self) -> None:
        cases = {
            "not json": "{",
            "not an object": "[]",
            "no description": json.dumps({"name": "x"}),
            "description is not text": json.dumps({"description": 5}),
            "no marker": json.dumps({"description": "Available: none"}),
            "first line is not a row": json.dumps({"description": "Head\n\nAvailable:\nstray line"}),
        }
        for label, text in cases.items():
            with self.subTest(label):
                self.assertIsNone(ctx.parse_skill_list(text))


class ReadBlobTextTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def test_a_blob_sits_under_the_first_two_characters_of_its_sha(self) -> None:
        path = self.base / ".masc" / "tool_blobs" / SHA_A[:2] / SHA_A
        path.parent.mkdir(parents=True)
        path.write_text("한글", encoding="utf-8")
        self.assertEqual(ctx.read_blob_text(self.base, SHA_A), "한글")

    def test_a_missing_or_undecodable_blob_gives_none(self) -> None:
        self.assertIsNone(ctx.read_blob_text(self.base, SHA_A))
        path = self.base / ".masc" / "tool_blobs" / SHA_B[:2] / SHA_B
        path.parent.mkdir(parents=True)
        path.write_bytes(b"\xff\xfe\x00bad")
        self.assertIsNone(ctx.read_blob_text(self.base, SHA_B))


class ReadSkillCallsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def calls(self, first: date = DAY, last: date = DAY) -> ctx.SkillCalls:
        return ctx.read_skill_calls(self.base, first, last, SINCE, UNTIL)

    def test_calls_are_counted_per_keeper_and_per_skill_name(self) -> None:
        write_ledger(
            self.base,
            DAY,
            [
                ledger_row(1500.0, "alpha", ctx.SKILL_TOOL, skill_input("one")),
                ledger_row(1501.0, "alpha", ctx.SKILL_TOOL, skill_input("two")),
                ledger_row(1502.0, "beta", ctx.SKILL_TOOL, skill_input("one")),
            ],
        )
        calls = self.calls()
        self.assertEqual(dict(calls.by_keeper), {"alpha": 2, "beta": 1})
        self.assertEqual(dict(calls.by_skill), {"one": 2, "two": 1})
        self.assertEqual(calls.without_identity, 0)

    def test_only_the_keeper_skill_tool_counts_even_when_other_rows_name_it(self) -> None:
        write_ledger(
            self.base,
            DAY,
            [
                ledger_row(1500.0, "alpha", "Execute", {"command": "echo keeper_skill"}),
                ledger_row(1501.0, "alpha", "keeper_skill_extra", skill_input("one")),
                ledger_row(1502.0, "alpha", ctx.SKILL_TOOL, skill_input("one")),
            ],
        )
        self.assertEqual(dict(self.calls().by_keeper), {"alpha": 1})

    def test_only_tool_call_records_count(self) -> None:
        write_ledger(
            self.base,
            DAY,
            [
                ledger_row(1500.0, "alpha", ctx.SKILL_TOOL, skill_input("one"), record_kind="other"),
                ledger_row(1501.0, "alpha", ctx.SKILL_TOOL, skill_input("one")),
            ],
        )
        self.assertEqual(dict(self.calls().by_keeper), {"alpha": 1})

    def test_window_bounds_are_inclusive_and_nothing_outside_counts(self) -> None:
        stamps = (SINCE - 0.001, SINCE, UNTIL, UNTIL + 0.001)
        write_ledger(self.base, DAY, [ledger_row(ts, "alpha", ctx.SKILL_TOOL, skill_input("one")) for ts in stamps])
        self.assertEqual(self.calls().by_keeper["alpha"], 2)

    def test_a_row_without_a_usable_time_is_not_counted(self) -> None:
        write_ledger(
            self.base,
            DAY,
            [
                ledger_row(None, "alpha", ctx.SKILL_TOOL, skill_input("one")),
                ledger_row("1500", "alpha", ctx.SKILL_TOOL, skill_input("one")),
            ],
        )
        self.assertEqual(dict(self.calls().by_keeper), {})

    def test_a_call_without_a_skill_name_counts_for_its_keeper_and_is_tallied_apart(self) -> None:
        write_ledger(
            self.base,
            DAY,
            [
                ledger_row(1500.0, "alpha", ctx.SKILL_TOOL),
                ledger_row(1501.0, "alpha", ctx.SKILL_TOOL, {"identity": {}}),
                ledger_row(1502.0, "alpha", ctx.SKILL_TOOL, "stored elsewhere"),
                ledger_row(1503.0, "alpha", ctx.SKILL_TOOL, {"identity": {"name": 5}}),
                ledger_row(1504.0, "alpha", ctx.SKILL_TOOL, skill_input("one")),
            ],
        )
        calls = self.calls()
        self.assertEqual(dict(calls.by_keeper), {"alpha": 5})
        self.assertEqual(dict(calls.by_skill), {"one": 1})
        self.assertEqual(calls.without_identity, 4)

    def test_a_keeper_that_is_not_text_is_counted_under_one_unknown_name(self) -> None:
        write_ledger(self.base, DAY, [ledger_row(1500.0, None, ctx.SKILL_TOOL, skill_input("one"))])
        self.assertEqual(dict(self.calls().by_keeper), {ctx.UNKNOWN_KEEPER: 1})

    def test_rotated_segments_and_the_live_file_are_all_read(self) -> None:
        for segment in (1, 2):
            write_ledger(self.base, DAY, [ledger_row(1500.0, f"seg{segment}", ctx.SKILL_TOOL, skill_input("one"))], segment=segment)
        write_ledger(self.base, DAY, [ledger_row(1500.0, "live", ctx.SKILL_TOOL, skill_input("one"))])
        self.assertEqual(sorted(self.calls().by_keeper), ["live", "seg1", "seg2"])

    def test_every_day_in_the_range_is_read_and_no_other_day(self) -> None:
        first, last = date(2026, 11, 1), date(2026, 11, 2)
        for day in (date(2026, 10, 31), first, last, date(2026, 11, 3)):
            write_ledger(self.base, day, [ledger_row(1500.0, f"d{day.day}", ctx.SKILL_TOOL, skill_input("one"))])
        self.assertEqual(sorted(self.calls(first, last).by_keeper), ["d1", "d2"])

    def test_days_across_a_month_boundary_are_found(self) -> None:
        for day in (date(2026, 10, 31), date(2026, 11, 1)):
            write_ledger(self.base, day, [ledger_row(1500.0, f"d{day.day}", ctx.SKILL_TOOL, skill_input("one"))])
        self.assertEqual(sorted(self.calls(date(2026, 10, 31), date(2026, 11, 1)).by_keeper), ["d1", "d31"])

    def test_unreadable_lines_are_skipped_without_stopping_the_file(self) -> None:
        write_ledger(
            self.base,
            DAY,
            ["not json keeper_skill", '["keeper_skill"]', ledger_row(1500.0, "alpha", ctx.SKILL_TOOL, skill_input("one"))],
        )
        self.assertEqual(dict(self.calls().by_keeper), {"alpha": 1})

    def test_a_store_without_a_ledger_gives_nothing(self) -> None:
        calls = self.calls()
        self.assertEqual((dict(calls.by_keeper), dict(calls.by_skill), calls.without_identity), ({}, {}, 0))


class SummarizeSkillCatalogTest(unittest.TestCase):
    LIST_A = [("one", "abc"), ("twenty-two", "defgh")]
    LIST_B = [(f"n{index}", "x" * (10 * index)) for index in range(1, 7)]

    def reader(self, blobs: dict[str, str]):  # type: ignore[no-untyped-def]
        self.reads: list[str] = []

        def read(sha: str) -> str | None:
            self.reads.append(sha)
            return blobs.get(sha)

        return read

    @staticmethod
    def carrying(sha: str | None) -> ctx.RequestBody:
        return body("alpha", 100, tools=((ctx.SKILL_TOOL, 10),), sha=sha)

    @staticmethod
    def sizes(rows: list[tuple[str, str]]) -> tuple[int, int, int]:
        """(rows, identity bytes, description bytes) of a list, counted without the parser."""
        return len(rows), sum(len(identity_json(name)) for name, _ in rows), sum(len(text) for _, text in rows)

    @staticmethod
    def block_bytes(rows: list[tuple[str, str]]) -> int:
        return len("\n".join(f"{identity_json(name)}: {text}" for name, text in rows))

    def test_requests_with_the_tool_and_requests_whose_list_cannot_be_read_are_counted(self) -> None:
        bodies = [
            self.carrying(SHA_A),
            self.carrying(SHA_B),  # blob missing
            self.carrying(None),  # no reference to read
            self.carrying(SHA_C),  # blob without a list
            body("alpha", 100, tools=(("other", 10),), sha=SHA_A),  # does not carry the tool
        ]
        summary = ctx.summarize_skill_catalog(bodies, self.reader({SHA_A: skill_schema_text(self.LIST_A), SHA_C: "{}"}))
        self.assertEqual((summary["requests_with_tool"], summary["lists_read"], summary["lists_unreadable"]), (4, 1, 3))

    def test_a_blob_shared_by_requests_is_read_once_and_counted_for_each_request(self) -> None:
        read = self.reader({SHA_A: skill_schema_text(self.LIST_A)})
        summary = ctx.summarize_skill_catalog([self.carrying(SHA_A)] * 3, read)
        self.assertEqual(self.reads, [SHA_A])
        self.assertEqual((summary["lists_read"], summary["distinct_lists"]), (3, 1))

    def test_a_blob_that_cannot_be_read_is_asked_for_once_and_not_called_a_distinct_list(self) -> None:
        read = self.reader({SHA_A: skill_schema_text(self.LIST_A)})
        summary = ctx.summarize_skill_catalog([self.carrying(SHA_B), self.carrying(SHA_B), self.carrying(SHA_A)], read)
        self.assertEqual(self.reads.count(SHA_B), 1)
        self.assertEqual((summary["lists_read"], summary["lists_unreadable"], summary["distinct_lists"]), (1, 2, 1))

    def test_sizes_come_from_the_list_each_request_carried(self) -> None:
        blobs = {SHA_A: skill_schema_text(self.LIST_A), SHA_B: skill_schema_text(self.LIST_B)}
        # Three requests carry the short list and one the long list, so the median is the short one and the max the long one.
        summary = ctx.summarize_skill_catalog([self.carrying(SHA_A)] * 3 + [self.carrying(SHA_B)], self.reader(blobs))
        rows_a, identity_a, description_a = self.sizes(self.LIST_A)
        rows_b, identity_b, description_b = self.sizes(self.LIST_B)
        rows = 3 * rows_a + rows_b
        identity = 3 * identity_a + identity_b
        description = 3 * description_a + description_b
        block = 3 * self.block_bytes(self.LIST_A) + self.block_bytes(self.LIST_B)
        self.assertEqual((summary["rows_p50"], summary["rows_max"]), (rows_a, rows_b))
        self.assertEqual((summary["block_bytes_p50"], summary["block_bytes_max"]), (self.block_bytes(self.LIST_A), self.block_bytes(self.LIST_B)))
        self.assertEqual(
            (summary["identity_bytes_per_row_mean"], summary["description_bytes_per_row_mean"]),
            (round(identity / rows), round(description / rows)),
        )
        self.assertEqual(
            (summary["identity_share_of_block"], summary["description_share_of_block"]),
            (round(identity / block, 3), round(description / block, 3)),
        )
        self.assertEqual(summary["distinct_lists"], 2)

    def test_without_a_readable_list_only_the_counts_are_given(self) -> None:
        summary = ctx.summarize_skill_catalog([self.carrying(SHA_A)], self.reader({}))
        self.assertEqual(summary, {"requests_with_tool": 1, "lists_read": 0, "lists_unreadable": 1})
        empty = ctx.summarize_skill_catalog([], self.reader({}))
        self.assertEqual(empty, {"requests_with_tool": 0, "lists_read": 0, "lists_unreadable": 0})

    def test_an_empty_list_gives_zero_rows_and_zero_shares(self) -> None:
        empty_list = json.dumps({"description": "Head\n\nAvailable:\n"})
        summary = ctx.summarize_skill_catalog([self.carrying(SHA_A)], self.reader({SHA_A: empty_list}))
        self.assertEqual((summary["rows_p50"], summary["block_bytes_p50"]), (0, 0))
        self.assertEqual((summary["identity_bytes_per_row_mean"], summary["identity_share_of_block"]), (0, 0.0))

    def test_carrying_keepers_are_the_keepers_with_a_request_that_has_the_tool(self) -> None:
        bodies = [self.carrying(SHA_A), body("beta", 1, tools=(("other", 1),)), body("gamma", 1)]
        self.assertEqual(ctx.carrying_keepers(bodies), frozenset({"alpha"}))


def usage_of(keeper: str, count: int = 1) -> list[ctx.Usage]:
    return [ctx.Usage(keeper, 1, 0, 0) for _ in range(count)]


def skill_calls(by_keeper: dict[str, int], by_skill: dict[str, int] | None = None, without: int = 0) -> ctx.SkillCalls:
    return ctx.SkillCalls(Counter(by_keeper), Counter(by_skill or {}), without)


class SummarizeSkillUseTest(unittest.TestCase):
    def test_the_call_rate_counts_only_keepers_that_have_usage_events(self) -> None:
        # beta made calls but has no usage event, so its calls cannot be set against any request.
        usages = usage_of("alpha", 100) + usage_of("gamma", 50)
        summary = ctx.summarize_skill_use(skill_calls({"alpha": 3, "beta": 2, "gamma": 1}), usages, frozenset())
        self.assertEqual((summary["calls"], summary["model_requests"], summary["calls_per_100_requests"]), (6, 150, round(100 * 4 / 150, 2)))
        self.assertEqual((summary["calls_by_keepers_without_usage_events"], summary["keepers_with_calls_and_no_usage_events"]), (2, 1))
        self.assertEqual(summary["keepers_with_calls"], 3)

    def test_keepers_are_ranked_by_calls_then_name_and_the_list_is_capped(self) -> None:
        extra = 2
        count = ctx.TOP_SKILL_KEEPERS + extra
        # Calls are 1, 1, 2, 2, ...: neighbours tie, so the name has to break the tie.
        by_keeper = {f"k{index:02d}": 1 + index // 2 for index in reversed(range(count))}
        usages = [usage for index in range(count) for usage in usage_of(f"k{index:02d}", 10 * (index + 1))]
        summary = ctx.summarize_skill_use(skill_calls(by_keeper), usages, frozenset())
        rows = summary["top_keepers"]
        assert isinstance(rows, list)
        self.assertEqual(len(rows), ctx.TOP_SKILL_KEEPERS)
        self.assertEqual([row["keeper"] for row in rows[:4]], ["k08", "k09", "k06", "k07"])
        calls = [row["calls"] for row in rows]
        self.assertEqual(calls, sorted(calls, reverse=True))
        top = rows[0]
        total = sum(by_keeper.values())
        self.assertEqual((top["calls"], top["requests"], top["calls_per_100_requests"]), (5, 90, round(100 * 5 / 90, 2)))
        self.assertEqual(top["share_of_calls"], round(5 / total, 3))

    def test_a_keeper_without_usage_events_has_no_rate(self) -> None:
        summary = ctx.summarize_skill_use(skill_calls({"alpha": 4}), [], frozenset())
        (row,) = summary["top_keepers"]  # type: ignore[misc]
        self.assertEqual((row["requests"], row["calls_per_100_requests"], row["share_of_calls"]), (0, None, 1.0))

    def test_skills_are_ranked_by_calls_then_name_and_the_list_is_capped(self) -> None:
        extra = 2
        by_skill = {f"s{index:02d}": 1 + index // 2 for index in reversed(range(ctx.TOP_SKILLS + extra))}
        calls = skill_calls({"alpha": sum(by_skill.values())}, by_skill)
        summary = ctx.summarize_skill_use(calls, usage_of("alpha", 10), frozenset())
        rows = summary["top_skills"]
        assert isinstance(rows, list)
        self.assertEqual(len(rows), ctx.TOP_SKILLS)
        # Calls are s06=4, s04=s05=3, s02=s03=2, s00=s01=1: ties go by name, and the two names with 1 call fall off the list.
        self.assertEqual([row["skill"] for row in rows], ["s06", "s04", "s05", "s02", "s03"])
        self.assertEqual(rows[0]["share_of_calls"], round(4 / sum(by_skill.values()), 3))
        self.assertEqual(summary["skills_opened"], len(by_skill))

    def test_carrying_keepers_without_calls_are_counted_with_their_requests(self) -> None:
        usages = usage_of("alpha", 10) + usage_of("beta", 4) + usage_of("gamma", 6)
        summary = ctx.summarize_skill_use(skill_calls({"alpha": 1}), usages, frozenset({"alpha", "beta", "gamma"}))
        self.assertEqual(summary["carrying_keepers"], 3)
        self.assertEqual((summary["carrying_keepers_without_calls"], summary["carrying_keepers_without_calls_requests"]), (2, 10))

    def test_calls_without_a_skill_name_are_reported_apart_from_the_names(self) -> None:
        summary = ctx.summarize_skill_use(skill_calls({"alpha": 5}, {"one": 2}, without=3), usage_of("alpha", 10), frozenset())
        self.assertEqual((summary["calls_without_identity"], summary["skills_opened"]), (3, 1))

    def test_no_usage_events_and_no_calls_give_zeros_without_dividing(self) -> None:
        summary = ctx.summarize_skill_use(skill_calls({}), [], frozenset())
        self.assertEqual((summary["calls"], summary["calls_per_100_requests"], summary["top_keepers"], summary["top_skills"]), (0, 0.0, [], []))
        busy = ctx.summarize_skill_use(skill_calls({}), usage_of("alpha", 5), frozenset())
        self.assertEqual((busy["calls"], busy["calls_per_100_requests"]), (0, 0.0))


class SummarizeToolSchemasTest(unittest.TestCase):
    def test_totals_counts_system_prompt_and_share_come_from_the_requests_that_carry_tools(self) -> None:
        bodies = [
            body("a", 1000, tools=(("x", 10), ("y", 20)), system=100),  # tools 30, share 0.13
            body("a", 600, tools=(("x", 30),), system=300),  # tools 30, share 0.55
            body("a", 2000, tools=(("x", 50), ("y", 60), ("z", 70)), system=800),  # tools 180, share 0.49
            body("a", 9999),  # no tools: not a request that carries any
        ]
        summary = ctx.summarize_tool_schemas(bodies)
        self.assertEqual(summary["requests"], 3)
        # The mean (80) and the median (30) differ on purpose.
        self.assertEqual((summary["tool_bytes_p50"], summary["tool_bytes_mean"], summary["tool_bytes_max"]), (30, 80, 180))
        self.assertEqual((summary["tools_p50"], summary["tools_max"]), (2, 3))
        self.assertEqual(summary["system_prompt_bytes_p50"], 300)
        self.assertEqual(summary["tools_and_system_share_of_body_p50"], 0.49)

    def test_the_heaviest_tools_are_ranked_by_total_bytes_then_name_and_the_list_is_capped(self) -> None:
        extra = 2
        # "common" is small but in every request; "rare" is bigger but in one. Their order depends on the totals.
        bodies = [body("a", 100, tools=(("common", 40), ("rare", 70))), body("a", 100, tools=(("common", 40),))]
        names = [f"t{index:02d}" for index in range(ctx.TOP_TOOL_SCHEMAS + extra)]
        bodies.append(body("a", 100, tools=tuple((name, 1) for name in reversed(names))))  # ties must not follow this order
        bodies.append(body("a", 100))  # a request without tools is not part of the shares
        summary = ctx.summarize_tool_schemas(bodies)
        rows = summary["heaviest_by_total_bytes"]
        assert isinstance(rows, list)
        self.assertEqual(len(rows), ctx.TOP_TOOL_SCHEMAS)
        self.assertEqual([row["tool"] for row in rows[:4]], ["common", "rare", "t00", "t01"])
        common = rows[0]
        all_bytes = 40 + 70 + 40 + len(names)
        self.assertEqual((common["bytes_sum"], common["requests"], common["bytes_p50"]), (80, 2, 40))
        self.assertEqual(common["share_of_requests"], round(2 / 3, 3))
        self.assertEqual(common["share_of_tool_bytes"], round(80 / all_bytes, 3))
        self.assertEqual(rows[1]["share_of_requests"], round(1 / 3, 3))

    def test_a_tool_size_median_is_over_the_requests_that_carry_that_tool(self) -> None:
        bodies = [body("a", 100, tools=(("x", size),)) for size in (10, 90, 20)]
        (row,) = ctx.summarize_tool_schemas(bodies)["heaviest_by_total_bytes"]  # type: ignore[misc]
        self.assertEqual(row["bytes_p50"], 20)

    def test_requests_without_tools_give_only_the_request_count(self) -> None:
        self.assertEqual(ctx.summarize_tool_schemas([body("a", 100)]), {"requests": 0})
        self.assertEqual(ctx.summarize_tool_schemas([]), {"requests": 0})

    def test_a_body_of_zero_bytes_has_no_share_and_does_not_divide(self) -> None:
        summary = ctx.summarize_tool_schemas([body("a", 0, tools=(("x", 10),), system=5)])
        self.assertEqual(summary["tools_and_system_share_of_body_p50"], 0.0)

    def test_the_summary_of_bodies_carries_the_tool_schema_section(self) -> None:
        summary = ctx.summarize_bodies([body("a", 100, tools=(("x", 10),), system=5)], NO_TRACES)
        section = summary["tool_schemas"]
        assert isinstance(section, dict)
        self.assertEqual((section["requests"], section["tool_bytes_p50"]), (1, 10))


class MainTest(unittest.TestCase):
    """Runs the command on small stores that hold one of everything on each of two days, so each reader feeds the right summary."""

    FIRST_DAY = date(2026, 11, 1)
    SECOND_DAY = date(2026, 11, 2)
    NOON = 1793534400.0  # 2026-11-01T12:00:00Z
    DAY_SECONDS = 86400.0
    UNTIL_TEXT = "2026-11-02T18:00:00Z"

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def run_main(self) -> dict[str, object]:
        out = self.base / "result.json"
        argv = [
            "measure_request_context.py",
            "--base-path",
            str(self.base),
            "--from-date",
            "2026-11-01",
            "--to-date",
            "2026-11-02",
            "--until",
            self.UNTIL_TEXT,
            "--json-out",
            str(out),
        ]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ctx.main(), 0)
        return json.loads(out.read_text(encoding="utf-8"))

    def test_every_section_is_built_from_its_own_store(self) -> None:
        usage = {"input_tokens": 100, "output_tokens": 7, "cache_read_input_tokens": 60}
        blob = self.base / ".masc" / "tool_blobs" / SHA_A[:2] / SHA_A
        blob.parent.mkdir(parents=True)
        blob.write_text(skill_schema_text([("one", "abc"), ("two", "defgh")]), encoding="utf-8")
        schemas = [schema_entry("other", 11), schema_entry(ctx.SKILL_TOOL, 22, SHA_A)]
        for turn, day in ((5, self.FIRST_DAY), (6, self.SECOND_DAY)):
            noon = self.NOON + (day - self.FIRST_DAY).days * self.DAY_SECONDS
            write_trace(self.base, "alpha", f"trace-1-0-{turn}-abc.jsonl", [usage_row(noon, usage)])
            capture = capture_row(
                noon, 9000, [], trace_id="trace-1-0", absolute_turn=turn, tool_schemas=schemas, system_prompt={"bytes": 33}
            )
            write_captures(self.base, "alpha", day, [capture])
        write_ledger(
            self.base,
            self.FIRST_DAY,
            [
                ledger_row(self.NOON, "alpha", ctx.SKILL_TOOL, skill_input("one")),
                ledger_row(self.NOON, "beta", ctx.SKILL_TOOL, skill_input("one")),
            ],
        )
        write_ledger(self.base, self.SECOND_DAY, [ledger_row(self.NOON + self.DAY_SECONDS, "alpha", ctx.SKILL_TOOL, skill_input("two"))])
        result = self.run_main()
        self.assertEqual(result["window"], {"from": "2026-11-01", "to": "2026-11-02", "until": "2026-11-02T18:00:00+00:00"})
        usage_section = result["model_requests"]
        assert isinstance(usage_section, dict)
        self.assertEqual((usage_section["requests"], usage_section["input_tokens"]), (2, 200))
        bodies = result["captured_request_bodies"]
        assert isinstance(bodies, dict)
        self.assertEqual((bodies["requests"], bodies["body_bytes_sum"], bodies["unanswered_requests"]), (2, 18000, 0))
        tool_section = bodies["tool_schemas"]
        assert isinstance(tool_section, dict)
        self.assertEqual((tool_section["tool_bytes_p50"], tool_section["system_prompt_bytes_p50"]), (33, 33))
        catalog = result["skill_catalog"]
        assert isinstance(catalog, dict)
        self.assertEqual((catalog["lists_read"], catalog["distinct_lists"], catalog["rows_p50"]), (2, 1, 2))
        calls = result["skill_calls"]
        assert isinstance(calls, dict)
        # beta has no usage event, so only alpha's two calls are set against the two requests.
        self.assertEqual((calls["calls"], calls["calls_per_100_requests"], calls["carrying_keepers"]), (3, 100.0, 1))
        self.assertEqual((calls["carrying_keepers_without_calls"], calls["keepers_with_calls_and_no_usage_events"]), (0, 1))
        self.assertEqual(calls["skills_opened"], 2)

    def test_a_window_with_no_data_still_gives_every_section(self) -> None:
        (self.base / ".masc").mkdir()
        result = self.run_main()
        self.assertEqual(sorted(result), ["captured_request_bodies", "model_requests", "skill_calls", "skill_catalog", "window"])
        catalog = result["skill_catalog"]
        assert isinstance(catalog, dict)
        self.assertEqual(catalog["requests_with_tool"], 0)


if __name__ == "__main__":
    unittest.main()
