"""Checks the arithmetic of measure_aged_rewrite_cost.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/aged-tool-results-2026-11
"""

from __future__ import annotations

import contextlib
import datetime
import io
import json
import pathlib
import random
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_aged_rewrite_cost as cost  # noqa: E402

DAY = "2026-11-02"
MARKER = 100
THRESHOLD = 500
# Role, size, digest id (0 for a digest the store did not keep), and whether the message carries an image.
Spec = tuple[str, int, int] | tuple[str, int, int, bool]


def ref(number: int) -> str:
    return f"[masc:blob sha256={number:064x} bytes=1 mime=x preview=\"\"]"


def entry(position: int, spec: Spec) -> dict[str, object]:
    role, size, digest = spec[0], spec[1], spec[2]
    media: list[object] = [{"type": "image"}] if len(spec) == 4 and spec[3] else []
    artifact: dict[str, object] = {"bytes": size}
    if digest > 0:
        artifact["content_ref"] = ref(digest)
    return {"index": position, "role": role, "artifact": artifact, "media": media}


def row(
    specs: list[Spec],
    *,
    trace: str | None = "t1",
    at: float = 1.0,
    turn: int = 1,
    system_bytes: int = 0,
    schema_bytes: int = 0,
) -> dict[str, object]:
    fields: dict[str, object] = {
        "captured_at": at,
        "absolute_turn": turn,
        "system_prompt": {"bytes": system_bytes},
        "tool_schemas": [{"artifact": {"bytes": schema_bytes}}],
        "messages": [entry(position, spec) for position, spec in enumerate(specs)],
    }
    if trace is not None:
        fields["trace_id"] = trace
    return fields


def params(since: float | None = None, until: float | None = None) -> cost.Params:
    return cost.Params(THRESHOLD, MARKER, since, until)


def write_rows(base: pathlib.Path, keeper: str, day: str, rows: list[object], name: str | None = None) -> pathlib.Path:
    month, number = day[:7], day[8:]
    folder = base / ".masc" / "keepers" / keeper / "provider-inputs" / month
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / (name or f"{number}.jsonl")
    path.write_text("\n".join(json.dumps(item) for item in rows) + "\n", encoding="utf-8")
    return path


def run(
    base: pathlib.Path,
    first: str = DAY,
    last: str = DAY,
    p: cost.Params | None = None,
    excluded: tuple[str, ...] = (),
) -> tuple[cost.Tally, cost.Skipped]:
    skipped = cost.Skipped()
    loaded = cost.load(base, first, last, excluded, skipped)
    return cost.replay(loaded, p or params(), skipped), skipped


def replay_rows(rows: list[dict[str, object]], p: cost.Params | None = None) -> cost.Tally:
    with tempfile.TemporaryDirectory() as folder:
        base = pathlib.Path(folder)
        write_rows(base, "k", DAY, list(rows))
        return run(base, p=p)[0]


# One tool result of 1000 bytes between two turns: aged once the second user message is the last one.
TURN_ONE: list[Spec] = [("user", 10, 11), ("tool", 1000, 12), ("assistant", 10, 13)]
TURN_TWO: list[Spec] = [*TURN_ONE, ("user", 10, 14)]
# The same history one turn later, with the second user message answered.
TURN_THREE: list[Spec] = [*TURN_TWO, ("assistant", 10, 15), ("user", 10, 16)]


class KeysTest(unittest.TestCase):
    def test_equal_digests_are_told_apart_by_how_many_came_before(self) -> None:
        messages = [cost.Message("tool", 1, sha, False) for sha in ("a", "b", "a", None, "a")]
        self.assertEqual(cost.result_keys(messages), [("a", 0), ("b", 0), ("a", 1), None, ("a", 2)])


class TurnStartTest(unittest.TestCase):
    def start(self, roles: list[str]) -> int | None:
        return cost.turn_start([cost.Message(role, 1, None, False) for role in roles])

    def test_the_last_user_message_starts_the_current_turn(self) -> None:
        self.assertEqual(self.start(["user", "tool", "user", "assistant", "user", "tool"]), 4)

    def test_fewer_than_two_user_messages_leave_no_earlier_turn(self) -> None:
        self.assertIsNone(self.start(["user", "tool"]))
        self.assertIsNone(self.start(["tool", "assistant"]))
        self.assertIsNone(self.start([]))


class RewriteTest(unittest.TestCase):
    def test_a_request_without_a_predecessor_saves_bytes_and_rereads_nothing(self) -> None:
        tally = replay_rows([row(TURN_TWO)])
        self.assertEqual((tally.requests, tally.cold, tally.saved_bytes, tally.rewrite_bytes), (1, 1, 900, 0))
        self.assertEqual(tally.rewrite_shares, [])

    def test_a_result_that_ages_in_the_next_turn_is_read_again_from_itself_to_the_turn_start(self) -> None:
        # The predecessor has one user message, so it ages nothing. TURN_TWO ages the result at 1.
        tally = replay_rows([row(TURN_ONE, at=1.0, turn=1), row(TURN_TWO, at=2.0, turn=2)])
        self.assertEqual((tally.requests, tally.cold, tally.saved_bytes), (1, 0, 900))
        # Positions 1 and 2: the result at marker size and the assistant message.
        self.assertEqual(tally.rewrite_bytes, MARKER + 10)
        self.assertEqual(tally.with_rewrite, 1)

    def test_a_result_that_aged_before_costs_nothing_the_next_time(self) -> None:
        tally = replay_rows([row(TURN_ONE, at=1.0, turn=1), row(TURN_TWO, at=2.0, turn=2), row(TURN_THREE, at=3.0, turn=3)])
        self.assertEqual((tally.requests, tally.saved_bytes), (2, 1800))
        self.assertEqual(tally.rewrite_bytes, MARKER + 10)
        self.assertEqual(tally.with_rewrite, 1)

    def test_the_range_starts_at_the_first_fresh_result_not_at_the_first_aged_one(self) -> None:
        fourth: list[Spec] = [*TURN_THREE, ("tool", 1000, 17), ("assistant", 10, 18), ("user", 10, 19)]
        tally = replay_rows([row(TURN_THREE, at=1.0, turn=1), row(fourth, at=2.0, turn=2)])
        # The result at 1 aged in the first request. In the second only the result at 6 is new: positions 6 and 7.
        self.assertEqual(tally.rewrite_bytes, MARKER + 10)

    def test_messages_in_the_range_keep_their_size_unless_they_are_aged_results(self) -> None:
        small: list[Spec] = [("user", 10, 11), ("tool", 1000, 12), ("tool", 50, 13), ("assistant", 10, 14), ("user", 10, 15)]
        tally = replay_rows([row(small[:4], at=1.0, turn=1), row(small, at=2.0, turn=2)])
        # Positions 1..3: the aged result at marker size, the small result as it is, the assistant message.
        self.assertEqual(tally.rewrite_bytes, MARKER + 50 + 10)

    def test_every_aged_result_in_the_range_counts_at_marker_size(self) -> None:
        two: list[Spec] = [("user", 10, 11), ("tool", 1000, 12), ("tool", 2000, 13), ("assistant", 10, 14), ("user", 10, 15)]
        tally = replay_rows([row(two[:4], at=1.0, turn=1), row(two, at=2.0, turn=2)])
        self.assertEqual(tally.rewrite_bytes, MARKER + MARKER + 10)
        self.assertEqual(tally.saved_bytes, 900 + 1900)

    def test_a_repeated_identical_result_is_a_new_result(self) -> None:
        second: list[Spec] = [*TURN_TWO, ("tool", 1000, 12), ("assistant", 10, 15), ("user", 10, 16)]
        tally = replay_rows([row(TURN_TWO, at=1.0, turn=1), row(second, at=2.0, turn=2)])
        # The copy at 4 is not the result at 1: positions 4 and 5.
        self.assertEqual(tally.rewrite_bytes, MARKER + 10)
        self.assertEqual(tally.saved_bytes, 900 + 1800)

    def test_aged_results_without_a_digest_are_saved_and_counted_but_never_fresh(self) -> None:
        blind: list[Spec] = [("user", 10, 11), ("tool", 1000, 0), ("assistant", 10, 13), ("user", 10, 14)]
        tally = replay_rows([row(blind[:3], at=1.0, turn=1), row(blind, at=2.0, turn=2)])
        self.assertEqual((tally.saved_bytes, tally.unkeyed_aged, tally.rewrite_bytes), (900, 1, 0))

    def test_threshold_and_marker_edges(self) -> None:
        def saved_for(size: int, threshold: int = THRESHOLD, marker: int = MARKER) -> int:
            specs: list[Spec] = [("user", 10, 11), ("tool", size, 12), ("user", 10, 14)]
            return replay_rows([row(specs)], cost.Params(threshold, marker, None, None)).saved_bytes

        self.assertEqual(saved_for(THRESHOLD), THRESHOLD - MARKER)
        self.assertEqual(saved_for(THRESHOLD - 1), 0)
        self.assertEqual(saved_for(MARKER, threshold=50), 0)
        self.assertEqual(saved_for(MARKER + 1, threshold=50), 1)

    def test_a_result_the_size_of_the_marker_is_not_aged_and_costs_nothing(self) -> None:
        low = cost.Params(50, MARKER, None, None)
        previous: list[Spec] = [("user", 10, 11), ("tool", MARKER, 12), ("assistant", 10, 13)]
        tally = replay_rows([row(previous, at=1.0, turn=1), row([*previous, ("user", 10, 14)], at=2.0, turn=2)], low)
        self.assertEqual((tally.saved_bytes, tally.rewrite_bytes), (0, 0))

    def test_only_tool_results_without_media_before_the_last_user_message_are_aged(self) -> None:
        specs: list[Spec] = [
            ("user", 10, 11),
            ("assistant", 1000, 12),
            ("tool", 1000, 13, True),
            ("tool", 1000, 14),
            ("user", 10, 15),
            ("tool", 1000, 16),
        ]
        self.assertEqual(replay_rows([row(specs)]).saved_bytes, 900)

    def test_a_request_with_one_user_message_is_skipped_and_counted(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, [row(TURN_ONE)])
            tally, skipped = run(base)
        self.assertEqual((tally.requests, skipped.no_boundary), (0, 1))


class GroupingTest(unittest.TestCase):
    def test_traces_and_keepers_do_not_share_a_predecessor_or_state(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "a", DAY, [row(TURN_ONE, trace="t1", at=1.0), row(TURN_TWO, trace="t2", at=2.0)])
            write_rows(base, "b", DAY, [row(TURN_TWO, trace="t1", at=3.0)])
            tally, _ = run(base)
        self.assertEqual((tally.requests, tally.cold, tally.rewrite_bytes), (2, 2, 0))

    def test_rows_are_ordered_by_capture_time_not_by_file_position(self) -> None:
        tally = replay_rows([row(TURN_TWO, at=2.0, turn=2), row(TURN_ONE, at=1.0, turn=1)])
        self.assertEqual((tally.cold, tally.rewrite_bytes), (0, MARKER + 10))

    def test_capture_time_wins_over_the_turn_number(self) -> None:
        tally = replay_rows([row(TURN_TWO, at=2.0, turn=1), row(TURN_ONE, at=1.0, turn=9)])
        self.assertEqual((tally.cold, tally.rewrite_bytes), (0, MARKER + 10))

    def test_equal_capture_times_fall_back_to_the_turn_number(self) -> None:
        tally = replay_rows([row(TURN_TWO, at=1.0, turn=2), row(TURN_ONE, at=1.0, turn=1)])
        self.assertEqual((tally.cold, tally.rewrite_bytes), (0, MARKER + 10))

    def test_a_row_without_a_trace_is_its_own_group(self) -> None:
        tally = replay_rows([row(TURN_TWO, trace=None, at=1.0), row(TURN_TWO, trace=None, at=2.0)])
        self.assertEqual((tally.requests, tally.cold), (2, 2))

    def test_files_of_several_days_are_read_and_the_day_range_filters_files(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", "2026-11-01", [row(TURN_TWO, at=1.0)])
            write_rows(base, "k", "2026-11-02", [row(TURN_TWO, at=2.0)])
            write_rows(base, "k", "2026-11-03", [row(TURN_TWO, at=3.0)])
            both, _ = run(base, "2026-11-01", "2026-11-02")
            only_last, _ = run(base, "2026-11-03", "2026-11-03")
            skipped_keeper, _ = run(base, "2026-11-01", "2026-11-03", excluded=("k",))
        self.assertEqual((both.requests, only_last.requests, skipped_keeper.requests), (2, 1, 0))


class WindowTest(unittest.TestCase):
    def test_a_request_before_since_ages_results_but_is_not_counted(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, [row(TURN_TWO, at=1.0, turn=1), row(TURN_THREE, at=2.0, turn=2)])
            tally, skipped = run(base, p=params(since=1.5))
        # The result at 1 aged in the request before the window, so the counted request rereads nothing.
        self.assertEqual((tally.requests, tally.cold, tally.rewrite_bytes, tally.saved_bytes), (1, 0, 0, 900))
        self.assertEqual(skipped.outside_window, 1)

    def test_a_request_before_since_is_a_predecessor(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, [row(TURN_ONE, at=1.0, turn=1), row(TURN_TWO, at=2.0, turn=2)])
            tally, _ = run(base, p=params(since=1.5))
        self.assertEqual((tally.cold, tally.rewrite_bytes), (0, MARKER + 10))

    def test_a_request_captured_exactly_at_since_is_counted(self) -> None:
        rows = [row(TURN_TWO, at=1.0, turn=1), row(TURN_TWO, at=2.0, turn=2)]
        self.assertEqual(replay_rows(rows, params(since=2.0)).requests, 1)

    def test_until_is_exclusive(self) -> None:
        rows = [row(TURN_TWO, at=1.0, turn=1), row(TURN_TWO, at=2.0, turn=2)]
        self.assertEqual(replay_rows(rows, params(until=2.0)).requests, 1)

    def test_an_outside_request_with_one_user_message_is_not_counted_as_a_skipped_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, [row(TURN_ONE, at=1.0, turn=1), row(TURN_TWO, at=3.0, turn=2)])
            _, skipped = run(base, p=params(since=2.0))
        self.assertEqual((skipped.outside_window, skipped.no_boundary), (1, 0))


class PropertyTest(unittest.TestCase):
    def test_rewrite_matches_a_position_based_count_on_random_append_only_traces(self) -> None:
        generator = random.Random(20261106)
        for _ in range(200):
            messages: list[Spec] = []
            histories: list[list[Spec]] = []
            digest = 100
            for _ in range(8):
                digest += 1
                messages = [*messages, ("user", 10, digest)]
                for _ in range(generator.randint(0, 3)):
                    digest += 1
                    role = generator.choice(["tool", "tool", "assistant"])
                    messages = [*messages, (role, generator.choice([50, 400, 600, 1000, 5000]), digest)]
                histories.append(messages)
            tally = replay_rows([row(specs, at=float(turn), turn=turn) for turn, specs in enumerate(histories, 1)])
            # The histories only grow, so a result is fresh when it sits at or after the latest earlier turn start.
            expected_saved = 0
            expected_rewrite = 0
            previous_start = 0
            for position, specs in enumerate(histories):
                users = [index for index, spec in enumerate(specs) if spec[0] == "user"]
                if len(users) < 2:
                    continue
                start = users[-1]
                aged = [i for i in range(start) if specs[i][0] == "tool" and specs[i][1] >= THRESHOLD and specs[i][1] > MARKER]
                expected_saved += sum(specs[i][1] - MARKER for i in aged)
                fresh = [i for i in aged if i >= previous_start]
                if position > 0 and fresh:
                    expected_rewrite += sum(MARKER if i in aged else specs[i][1] for i in range(min(fresh), start))
                previous_start = start
            self.assertEqual(tally.saved_bytes, expected_saved)
            self.assertEqual(tally.rewrite_bytes, expected_rewrite)
            self.assertLessEqual(tally.rewrite_bytes, tally.prompt_bytes)
            self.assertTrue(all(0.0 <= value <= 1.0 for value in tally.rewrite_shares))
            self.assertEqual(tally.cold + len(tally.rewrite_shares), tally.requests)


class ReportTest(unittest.TestCase):
    def report(self, rows: list[dict[str, object]], per_turn: tuple[float, ...] = ()) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, list(rows))
            tally, skipped = run(base)
        return cost.report(tally, skipped, params(), 3, per_turn)

    def test_shares_are_of_the_prompt(self) -> None:
        specs: list[Spec] = [("user", 10, 11), ("tool", 1000, 12), ("user", 10, 14)]
        result = self.report([row(specs, system_bytes=200, schema_bytes=300)])
        self.assertEqual(result["prompt_bytes"], 1020 + 200 + 300)
        self.assertEqual(result["saved"], {"bytes": 900, "share_of_prompt": round(900 / 1520, 4)})
        self.assertEqual(cast(dict[str, int], result["requests"])["cold"], 1)

    def test_rewrite_is_reported_per_request_and_in_total(self) -> None:
        result = self.report([row(TURN_ONE, at=1.0, turn=1), row(TURN_TWO, at=2.0, turn=2)])
        rewrite = cast(dict[str, object], result["rewrite"])
        prompt = 1000 + 10 + 10 + 10
        self.assertEqual(result["prompt_bytes"], prompt)
        self.assertEqual(rewrite["bytes"], MARKER + 10)
        self.assertEqual(rewrite["share_of_prompt"], round(110 / prompt, 4))
        self.assertEqual(rewrite["requests_with_rewrite"], 1)
        self.assertEqual(rewrite["share_of_requests_with_predecessor"], 1.0)
        self.assertEqual(
            rewrite["per_request_share"],
            {"p50": round(110 / prompt, 4), "p90": round(110 / prompt, 4), "p99": round(110 / prompt, 4), "max": round(110 / prompt, 4)},
        )

    def test_per_request_shares_come_from_every_request_with_a_predecessor(self) -> None:
        # Each turn adds a user message, a 1000 byte result and an assistant message of the size in `answers`.
        answers = [10, 10, 400, 40]
        history: list[Spec] = []
        rows: list[dict[str, object]] = []
        digest = 100
        for turn, answer in enumerate(answers, 1):
            history = [*history, ("user", 10, digest + 1), ("tool", 1000, digest + 2), ("assistant", answer, digest + 3)]
            digest += 3
            rows.append(row([*history, ("user", 10, digest + 1)], at=float(turn), turn=turn))
        shares = cast(dict[str, object], cast(dict[str, object], self.report(rows)["rewrite"])["per_request_share"])
        # The first request has no predecessor. The others reread a marker and the answer that follows the new result.
        first = round(110 / 2050, 4)
        second = round(500 / 3460, 4)
        third = round(140 / 4510, 4)
        self.assertEqual(sorted([first, second, third]), [third, first, second])
        self.assertEqual(shares, {"p50": first, "p90": second, "p99": second, "max": second})

    def test_quantiles_pick_the_ceiling_rank(self) -> None:
        values = [float(number) for number in range(1, 11)]
        self.assertEqual([cost.quantile(values, q) for q in (0.5, 0.9, 0.99, 1.0)], [5.0, 9.0, 10.0, 10.0])
        self.assertEqual(cost.quantile([], 0.5), 0.0)
        self.assertEqual(cost.quantile([7.0], 0.01), 7.0)

    def test_empty_input_reports_zeros(self) -> None:
        result = self.report([])
        rewrite = cast(dict[str, object], result["rewrite"])
        self.assertEqual(cast(dict[str, float], result["saved"])["share_of_prompt"], 0.0)
        self.assertEqual(rewrite["share_of_prompt"], 0.0)
        self.assertEqual(rewrite["share_of_requests_with_predecessor"], 0.0)
        self.assertEqual(rewrite["per_request_share"], {"p50": 0.0, "p90": 0.0, "p99": 0.0, "max": 0.0})

    def test_by_keeper_is_sorted_by_prompt_and_limited(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            small: list[Spec] = [("user", 10, 11), ("user", 10, 14)]
            for name, size in (("a", 5000), ("b", 3000), ("c", 100), ("d", 1)):
                specs: list[Spec] = [("user", 10, 11), ("tool", size, 12), ("user", 10, 14)]
                write_rows(base, name, DAY, [row(specs if size > 1 else small)])
            tally, skipped = run(base)
        result = cost.report(tally, skipped, params(), 3, ())
        self.assertEqual([item["keeper"] for item in cast(list[dict[str, object]], result["by_keeper"])], ["a", "b", "c"])

    def test_by_keeper_carries_both_shares(self) -> None:
        result = self.report([row(TURN_ONE, at=1.0, turn=1), row(TURN_TWO, at=2.0, turn=2)])
        keeper = cast(list[dict[str, object]], result["by_keeper"])[0]
        self.assertEqual(keeper["saved_share"], round(900 / 1030, 4))
        self.assertEqual(keeper["rewrite_share"], round(110 / 1030, 4))

    def test_the_price_block_is_only_there_when_asked(self) -> None:
        self.assertNotIn("price", self.report([row(TURN_TWO)]))
        blocks = cast(list[dict[str, object]], self.report([row(TURN_TWO)], per_turn=(1.0, 10.0))["price"])
        self.assertEqual([block["requests_per_turn"] for block in blocks], [1.0, 10.0])

    def test_price_block_arithmetic(self) -> None:
        block = cost.price_block(0.5, 0.02, 10.0)
        self.assertEqual(block["requests_per_turn"], 10.0)
        self.assertEqual(block["break_even_cache_price"], round(0.02 / 5.02, 4))
        self.assertEqual(
            block["net_per_turn_in_prompts"],
            {"0.1": round(0.1 * 5.0 - 0.9 * 0.02, 4), "0.25": round(0.25 * 5.0 - 0.75 * 0.02, 4), "0.5": round(0.5 * 5.0 - 0.5 * 0.02, 4)},
        )

    def test_break_even_is_where_saving_and_cost_are_equal(self) -> None:
        block = cost.price_block(0.5, 0.2, 1.0)
        self.assertEqual(block["break_even_cache_price"], round(0.2 / 0.7, 4))

    def test_price_block_with_nothing_saved_and_nothing_reread(self) -> None:
        self.assertEqual(cost.price_block(0.0, 0.0, 10.0)["break_even_cache_price"], 0.0)


class ParsingTest(unittest.TestCase):
    def test_bad_lines_and_bad_entries_are_counted_not_dropped_silently(self) -> None:
        good = row(TURN_TWO)
        broken_message = row(TURN_TWO, at=2.0, turn=2)
        cast(list[object], broken_message["messages"]).append({"role": "tool"})
        no_time = row(TURN_TWO)
        del no_time["captured_at"]
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            path = write_rows(base, "k", DAY, [good, broken_message, no_time, [1, 2]])
            path.write_text(path.read_text(encoding="utf-8") + "not json\n", encoding="utf-8")
            skipped = cost.Skipped()
            loaded = cost.load(base, DAY, DAY, (), skipped)
        self.assertEqual(len(loaded), 2)
        self.assertEqual(skipped.bad_lines, 3)
        self.assertEqual(skipped.bad_message_entries, 1)

    def test_a_boolean_capture_time_is_a_bad_line(self) -> None:
        fields = row(TURN_TWO)
        fields["captured_at"] = True
        self.assertIsNone(cost.parse_stored("k", fields, cost.Skipped()))

    def test_messages_are_placed_by_their_index_not_by_their_place_in_the_row(self) -> None:
        fields = row(TURN_TWO)
        fields["messages"] = list(reversed(cast(list[dict[str, object]], fields["messages"])))
        parsed = cost.parse_stored("k", fields, cost.Skipped())
        assert parsed is not None
        self.assertEqual([message.role for message in parsed.messages], ["user", "tool", "assistant", "user"])

    def test_a_message_without_an_index_keeps_its_place(self) -> None:
        fields = row(TURN_TWO)
        for item in cast(list[dict[str, object]], fields["messages"]):
            del item["index"]
        parsed = cost.parse_stored("k", fields, cost.Skipped())
        assert parsed is not None
        self.assertEqual([message.role for message in parsed.messages], ["user", "tool", "assistant", "user"])

    def test_fixed_bytes_add_the_system_prompt_and_every_tool_schema(self) -> None:
        fields = row(TURN_TWO, system_bytes=200, schema_bytes=300)
        cast(list[dict[str, object]], fields["tool_schemas"]).append({"artifact": {"bytes": 50}})
        parsed = cost.parse_stored("k", fields, cost.Skipped())
        assert parsed is not None
        self.assertEqual(parsed.fixed_bytes, 550)

    def test_files_with_a_non_day_name_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, [row(TURN_TWO)], name="notes.jsonl")
            self.assertEqual(run(base)[0].requests, 0)


class CommandLineTest(unittest.TestCase):
    def test_json_out_gets_the_report(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, [row(TURN_TWO)])
            out = base / "result.json"
            code = cost.main(["--base-path", str(base), "--from-date", DAY, "--to-date", DAY, "--json-out", str(out)])
            result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(result["requests"]["counted"], 1)

    def test_without_json_out_the_report_goes_to_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, [row(TURN_TWO)])
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                cost.main(["--base-path", str(base), "--from-date", DAY, "--to-date", DAY, "--since", "2026-11-02T00:00:00"])
        midnight = datetime.datetime(2026, 11, 2, tzinfo=datetime.timezone.utc).timestamp()
        self.assertEqual(json.loads(buffer.getvalue())["params"]["since"], midnight)

    def test_requests_per_turn_adds_the_price_block(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            write_rows(base, "k", DAY, [row(TURN_TWO)])
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                cost.main(
                    ["--base-path", str(base), "--from-date", DAY, "--to-date", DAY]
                    + ["--requests-per-turn", "5", "--requests-per-turn", "17"]
                )
        self.assertEqual([block["requests_per_turn"] for block in json.loads(buffer.getvalue())["price"]], [5.0, 17.0])

    def test_a_bad_day_time_or_count_is_a_usage_error(self) -> None:
        for argv in (
            ["--from-date", "2026-13-01", "--to-date", DAY],
            ["--from-date", DAY, "--to-date", "tomorrow"],
            ["--from-date", DAY, "--to-date", DAY, "--since", "noon"],
            ["--from-date", DAY, "--to-date", DAY, "--until", "noon"],
            ["--from-date", DAY, "--to-date", DAY, "--requests-per-turn", "0"],
            ["--from-date", DAY, "--to-date", DAY, "--requests-per-turn", "5", "--requests-per-turn", "-1"],
        ):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                cost.main(["--base-path", ".", *argv])
            self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
