"""Checks the arithmetic of measure_defer_replay.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/defer-loading-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_defer_replay as replay_tool  # noqa: E402

DAY_1 = "2026-11-01"
DAY_2 = "2026-11-02"
OUTSIDE_DAY = "2026-10-20"


def schemas(sizes: dict[str, int]) -> list[dict[str, object]]:
    return [{"name": name, "artifact": {"bytes": size}} for name, size in sizes.items()]


def stored(trace: str, sizes: dict[str, int]) -> dict[str, object]:
    return {"trace_id": trace, "tool_schemas": schemas(sizes)}


def with_body(
    trace: str,
    sizes: dict[str, int],
    *,
    body: int,
    system: int = 0,
    messages: tuple[tuple[str, int], ...] = (),
) -> dict[str, object]:
    row = stored(trace, sizes)
    row["wire"] = {"body_bytes": body}
    row["system_prompt"] = {"bytes": system}
    row["messages"] = [{"role": role, "artifact": {"bytes": size}, "media": []} for role, size in messages]
    return row


def call(keeper: str, tool: str, trace: str, turn: str, key: str = "keeper_turn_id") -> dict[str, object]:
    return {"record_kind": "tool_call", "keeper": keeper, "tool": tool, "trace_id": trace, key: turn}


class Store:
    """A temporary base path holding `.masc` with the two stores."""

    def __init__(self, base: pathlib.Path) -> None:
        self.base = base

    def requests(self, keeper: str, day: str, rows: list[dict[str, object]], raw: tuple[str, ...] = ()) -> None:
        path = self.base / ".masc" / "keepers" / keeper / "provider-inputs" / day[:7] / f"{day[8:]}.jsonl"
        self._write(path, rows, raw)

    def ledger(self, day: str, rows: list[dict[str, object]], suffix: str = "", raw: tuple[str, ...] = ()) -> None:
        path = self.base / ".masc" / "tool_calls" / day[:7] / f"{day[8:]}{suffix}.jsonl"
        self._write(path, rows, raw)

    @staticmethod
    def _write(path: pathlib.Path, rows: list[dict[str, object]], raw: tuple[str, ...]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = [json.dumps(row) for row in rows] + list(raw)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class TempStoreCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.store = Store(pathlib.Path(self._tmp.name))
        self.masc_dir = self.store.base / ".masc"

    def read(
        self, from_day: str = DAY_1, to_day: str = DAY_2
    ) -> tuple[list[replay_tool.StoredRequest], list[replay_tool.Call], replay_tool.Skipped]:
        skipped = replay_tool.Skipped()
        requests = replay_tool.read_stored_requests(self.masc_dir, from_day, to_day, skipped)
        calls = replay_tool.read_calls(self.masc_dir, from_day, to_day, skipped)
        return requests, calls, skipped


class RankingTest(TempStoreCase):
    def test_presence_median_and_loading_cost(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"core": 100, "rare": 40}), stored("t2", {"core": 100}), stored("t3", {"core": 100, "rare": 60})])
        requests, calls, _ = self.read()
        surface, rows = replay_tool.summarize_tools(requests, calls, 0.0)
        by_name = {row.name: row for row in rows}
        self.assertEqual(surface, 140)
        self.assertEqual(by_name["core"].presence_pct, 100.0)
        self.assertAlmostEqual(by_name["rare"].presence_pct, 200 / 3)
        self.assertEqual(by_name["rare"].median_bytes, 50)
        self.assertEqual(by_name["rare"].loading_bytes, 100)

    def test_min_presence_hides_tools_that_ride_less_often(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"core": 10, "rare": 5}), stored("t2", {"core": 10})])
        requests, calls, _ = self.read()
        _, rows = replay_tool.summarize_tools(requests, calls, 90.0)
        self.assertEqual([row.name for row in rows], ["core"])

    def test_a_tool_at_exactly_the_minimum_presence_is_kept(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"core": 10, "half": 5}), stored("t2", {"core": 10})])
        requests, calls, _ = self.read()
        _, rows = replay_tool.summarize_tools(requests, calls, 50.0)
        self.assertEqual(sorted(row.name for row in rows), ["core", "half"])

    def test_ratio_is_loading_cost_over_needed_turns_times_median_surface(self) -> None:
        self.store.requests("alpha", DAY_1, [stored(f"t{i}", {"core": 900, "tool": 100}) for i in range(4)])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t0", "1"), call("alpha", "tool", "t1", "1")])
        requests, calls, _ = self.read()
        surface, rows = replay_tool.summarize_tools(requests, calls, 0.0)
        row = next(row for row in rows if row.name == "tool")
        self.assertEqual(surface, 1000)
        # loading 4 x 100 = 400; deferring 2 turns x 1000 = 2000.
        self.assertEqual((row.loading_bytes, row.needed_turns), (400, 2))
        self.assertAlmostEqual(row.ratio or 0.0, 0.2)

    def test_a_tool_no_turn_needed_has_no_ratio_and_sorts_first(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"unused": 10, "used": 500})])
        self.store.ledger(DAY_1, [call("alpha", "used", "t1", "1")])
        requests, calls, _ = self.read()
        _, rows = replay_tool.summarize_tools(requests, calls, 0.0)
        self.assertEqual([(row.name, row.ratio is None) for row in rows], [("unused", True), ("used", False)])

    def test_rows_run_from_the_best_deferral_candidate_to_the_worst(self) -> None:
        sizes = {"big_unused": 300, "small_unused": 20, "high": 200, "low": 100}
        self.store.requests("alpha", DAY_1, [stored(f"t{i}", sizes) for i in range(4)])
        self.store.ledger(
            DAY_1,
            [call("alpha", "high", "t0", "1")] + [call("alpha", "low", f"t{i}", "1") for i in range(4)],
        )
        requests, calls, _ = self.read()
        _, rows = replay_tool.summarize_tools(requests, calls, 0.0)
        self.assertEqual([row.name for row in rows], ["big_unused", "small_unused", "high", "low"])

    def test_two_calls_in_one_turn_are_one_needed_turn(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 10})])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t1", "7"), call("alpha", "tool", "t1", "7"), call("alpha", "tool", "t1", "8")])
        requests, calls, _ = self.read()
        _, rows = replay_tool.summarize_tools(requests, calls, 0.0)
        self.assertEqual((rows[0].calls, rows[0].needed_turns), (3, 2))

    def test_turn_falls_back_to_the_turn_field(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 10})])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t1", "7", key="turn"), call("alpha", "tool", "t1", "8", key="turn")])
        requests, calls, _ = self.read()
        _, rows = replay_tool.summarize_tools(requests, calls, 0.0)
        self.assertEqual(rows[0].needed_turns, 2)

    def test_calls_of_a_keeper_without_stored_requests_are_not_counted(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 10})])
        self.store.ledger(DAY_1, [call("codex-only", "tool", "t9", "1")])
        requests, calls, _ = self.read()
        _, rows = replay_tool.summarize_tools(requests, calls, 0.0)
        self.assertEqual((rows[0].calls, rows[0].needed_turns), (0, 0))

    def test_rows_that_are_not_tool_calls_are_ignored(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 10})])
        other = call("alpha", "tool", "t1", "1")
        other["record_kind"] = "tool_result"
        self.store.ledger(DAY_1, [other])
        _, calls, _ = self.read()
        self.assertEqual(calls, [])

    def test_empty_window_is_an_error(self) -> None:
        with self.assertRaises(ValueError):
            replay_tool.summarize_tools([], [], 0.0)


class ReadingTest(TempStoreCase):
    def test_window_is_inclusive_and_filters_by_path_day(self) -> None:
        for day in (OUTSIDE_DAY, DAY_1, DAY_2, "2026-11-03"):
            self.store.requests("alpha", day, [stored("t", {"tool": 1})])
            self.store.ledger(day, [call("alpha", "tool", "t", day)])
        requests, calls, _ = self.read(DAY_1, DAY_2)
        self.assertEqual(sorted({request.day for request in requests}), [DAY_1, DAY_2])
        self.assertEqual(sorted({c.day for c in calls}), [DAY_1, DAY_2])

    def test_rotated_ledger_files_are_read(self) -> None:
        self.store.ledger(DAY_1, [call("alpha", "tool", "t", "1")])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t", "2")], suffix=".001")
        _, calls, _ = self.read()
        self.assertEqual(len(calls), 2)
        self.assertEqual({c.day for c in calls}, {DAY_1})

    def test_a_row_without_a_tool_schemas_list_is_not_a_stored_request(self) -> None:
        self.store.requests("alpha", DAY_1, [{"trace_id": "t", "messages": []}, stored("t2", {"tool": 1})])
        requests, _, _ = self.read()
        self.assertEqual(len(requests), 1)

    def test_unreadable_input_is_counted_and_not_dropped_silently(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 1})], raw=("{not json", "[1, 2]"))
        broken = {"trace_id": "t", "tool_schemas": [{"name": "no-size"}, {"artifact": {"bytes": 3}}, "text", {"name": "flag", "artifact": {"bytes": True}}]}
        self.store.requests("beta", DAY_1, [broken])
        self.store.ledger(DAY_1, [{"record_kind": "tool_call", "keeper": "alpha"}])
        stray = self.masc_dir / "tool_calls" / "2026-11" / "notes.jsonl"
        stray.write_text("{}\n", encoding="utf-8")
        requests, calls, skipped = self.read()
        self.assertEqual(len(requests), 2)
        self.assertEqual(calls, [])
        self.assertEqual(skipped.bad_lines, 3)
        self.assertEqual(skipped.bad_schema_entries, 4)
        self.assertEqual(skipped.unplaced_files, 1)

    def test_a_tool_listed_twice_in_one_request_adds_up(self) -> None:
        row = {"trace_id": "t", "tool_schemas": schemas({"tool": 5}) + schemas({"tool": 7})}
        self.store.requests("alpha", DAY_1, [row])
        requests, _, _ = self.read()
        self.assertEqual(requests[0].tools["tool"], 12)


class ReplayTest(TempStoreCase):
    def test_a_keeper_that_never_called_the_tool_loses_its_schema_and_pays_the_listing_name(self) -> None:
        name = "BrowserSession"
        self.store.requests("alpha", DAY_1, [stored(f"t{i}", {"core": 900, name: 100}) for i in range(3)])
        requests, calls, _ = self.read()
        outcome = replay_tool.replay(requests, calls, [name])
        listing = len(name) + 2
        (tool,) = outcome.tools
        self.assertEqual((tool.requests_carrying, tool.requests_released), (3, 3))
        self.assertEqual((tool.released_bytes, tool.listing_bytes), (300, 3 * listing))
        self.assertEqual((outcome.summed_before, outcome.summed_after), (3000, 3000 - 300 + 3 * listing))
        self.assertEqual((outcome.surface_median_before, outcome.surface_median_after), (1000, 900 + listing))

    def test_a_keeper_day_with_a_call_keeps_the_schema_and_still_pays_the_listing_name(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"core": 900, "tool": 100}), stored("t2", {"core": 900, "tool": 100})])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t1", "1")])
        requests, calls, _ = self.read()
        outcome = replay_tool.replay(requests, calls, ["tool"])
        (tool,) = outcome.tools
        self.assertEqual((tool.requests_carrying, tool.requests_released, tool.released_bytes), (2, 0, 0))
        self.assertEqual(tool.keeper_days_loading, 1)
        self.assertEqual(outcome.summed_after, outcome.summed_before + 2 * (len("tool") + 2))

    def test_the_call_frees_only_its_own_keeper_and_day(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 100})])
        self.store.requests("alpha", DAY_2, [stored("t2", {"tool": 100})])
        self.store.requests("beta", DAY_1, [stored("t3", {"tool": 100})])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t1", "1")])
        requests, calls, _ = self.read()
        outcome = replay_tool.replay(requests, calls, ["tool"])
        (tool,) = outcome.tools
        self.assertEqual((tool.requests_carrying, tool.requests_released, tool.keeper_days_loading), (3, 2, 1))

    def test_a_call_of_another_tool_does_not_carry_this_one(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 100, "other": 50})])
        self.store.ledger(DAY_1, [call("alpha", "other", "t1", "1")])
        requests, calls, _ = self.read()
        (tool,) = replay_tool.replay(requests, calls, ["tool"]).tools
        self.assertEqual(tool.requests_released, 1)

    def test_a_request_that_does_not_carry_the_tool_is_unchanged(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"core": 50, "tool": 10}), stored("t2", {"core": 50})])
        requests, calls, _ = self.read()
        outcome = replay_tool.replay(requests, calls, ["tool"])
        self.assertEqual(outcome.summed_before, 110)
        self.assertEqual(outcome.summed_after, 110 - 10 + len("tool") + 2)

    def test_from_first_call_keeps_the_schema_on_the_days_after_the_call(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 100})])
        self.store.requests("alpha", DAY_2, [stored("t2", {"tool": 100})])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t1", "1")])
        requests, calls, _ = self.read()
        (same_day,) = replay_tool.replay(requests, calls, ["tool"], replay_tool.CARRY_SAME_DAY).tools
        (from_first,) = replay_tool.replay(requests, calls, ["tool"], replay_tool.CARRY_FROM_FIRST_CALL).tools
        self.assertEqual((same_day.requests_released, same_day.keeper_days_loading), (1, 1))
        self.assertEqual((from_first.requests_released, from_first.keeper_days_loading), (0, 2))

    def test_the_first_call_is_the_earliest_one(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 100})])
        self.store.requests("alpha", DAY_2, [stored("t2", {"tool": 100})])
        self.store.ledger(DAY_2, [call("alpha", "tool", "t2", "1")])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t1", "1")])
        requests, calls, _ = self.read()
        (tool,) = replay_tool.replay(requests, calls, ["tool"], replay_tool.CARRY_FROM_FIRST_CALL).tools
        self.assertEqual(tool.requests_released, 0)

    def test_from_first_call_does_not_reach_back_to_earlier_days(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 100})])
        self.store.requests("alpha", DAY_2, [stored("t2", {"tool": 100})])
        self.store.ledger(DAY_2, [call("alpha", "tool", "t2", "1")])
        requests, calls, _ = self.read()
        for rule in replay_tool.CARRY_RULES:
            (tool,) = replay_tool.replay(requests, calls, ["tool"], rule).tools
            self.assertEqual(tool.requests_released, 1, rule)

    def test_from_first_call_is_per_keeper_and_per_tool(self) -> None:
        self.store.requests("alpha", DAY_2, [stored("t1", {"tool": 100, "other": 10})])
        self.store.requests("beta", DAY_2, [stored("t2", {"tool": 100, "other": 10})])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t0", "1")])
        requests, calls, _ = self.read()
        outcome = replay_tool.replay(requests, calls, ["tool", "other"], replay_tool.CARRY_FROM_FIRST_CALL)
        tool, other = outcome.tools
        self.assertEqual((tool.requests_released, other.requests_released), (1, 2))

    def test_the_lower_bound_never_removes_more_than_the_estimate(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 100})])
        self.store.requests("alpha", DAY_2, [stored("t2", {"tool": 100})])
        self.store.requests("beta", DAY_1, [stored("t3", {"tool": 100})])
        self.store.requests("beta", DAY_2, [stored("t4", {"tool": 100})])
        self.store.ledger(DAY_1, [call("alpha", "tool", "t1", "1")])
        self.store.ledger(DAY_2, [call("beta", "tool", "t4", "1")])
        requests, calls, _ = self.read()
        estimate = replay_tool.replay(requests, calls, ["tool"], replay_tool.CARRY_SAME_DAY)
        bound = replay_tool.replay(requests, calls, ["tool"], replay_tool.CARRY_FROM_FIRST_CALL)
        self.assertLess(estimate.summed_after, bound.summed_after)
        self.assertEqual(estimate.summed_before, bound.summed_before)

    def test_an_unknown_carry_rule_is_an_error(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 10})])
        requests, calls, _ = self.read()
        with self.assertRaisesRegex(ValueError, "carry rule"):
            replay_tool.replay(requests, calls, ["tool"], "forever")

    def test_a_name_that_never_rides_is_an_error(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 10})])
        requests, calls, _ = self.read()
        with self.assertRaisesRegex(ValueError, "tooll"):
            replay_tool.replay(requests, calls, ["tool", "tooll"])


class CompositionTest(TempStoreCase):
    def test_pooled_and_median_shares_of_the_body(self) -> None:
        self.store.requests(
            "alpha",
            DAY_1,
            [
                with_body("t1", {"a": 100}, body=1000, system=200, messages=(("user", 100), ("assistant", 300), ("tool", 200))),
                with_body("t2", {"a": 100}, body=2000, system=200, messages=(("tool", 1000),)),
            ],
        )
        requests, _, _ = self.read()
        result = replay_tool.composition(requests)
        assert result is not None
        self.assertEqual((result.requests, result.body_bytes), (2, 3000))
        pooled, median = result.pooled_pct, result.median_pct
        self.assertAlmostEqual(pooled[replay_tool.TOOL_SCHEMAS], 100 * 200 / 3000)
        self.assertAlmostEqual(pooled[replay_tool.SYSTEM_PROMPT], 100 * 400 / 3000)
        self.assertAlmostEqual(pooled["messages.tool"], 100 * 1200 / 3000)
        self.assertAlmostEqual(pooled[replay_tool.UNACCOUNTED], 100 * 800 / 3000)
        self.assertAlmostEqual(median[replay_tool.TOOL_SCHEMAS], 7.5)
        # messages.user is in one request of two: the other counts as zero.
        self.assertAlmostEqual(median["messages.user"], 5.0)

    def test_messages_of_one_role_add_up(self) -> None:
        self.store.requests("alpha", DAY_1, [with_body("t1", {"a": 1}, body=100, messages=(("tool", 10), ("assistant", 5), ("tool", 20)))])
        requests, _, _ = self.read()
        result = replay_tool.composition(requests)
        assert result is not None
        self.assertAlmostEqual(result.pooled_pct["messages.tool"], 30.0)
        self.assertAlmostEqual(result.pooled_pct["messages.assistant"], 5.0)

    def test_the_rest_of_the_body_is_never_negative(self) -> None:
        self.store.requests("alpha", DAY_1, [with_body("t1", {"a": 80}, body=100, system=50)])
        requests, _, _ = self.read()
        result = replay_tool.composition(requests)
        assert result is not None
        self.assertEqual(result.pooled_pct[replay_tool.UNACCOUNTED], 0.0)

    def test_the_rest_of_the_body_is_what_the_parts_leave(self) -> None:
        self.store.requests("alpha", DAY_1, [with_body("t1", {"a": 10}, body=100, system=20, messages=(("user", 30),))])
        requests, _, _ = self.read()
        result = replay_tool.composition(requests)
        assert result is not None
        self.assertAlmostEqual(result.pooled_pct[replay_tool.UNACCOUNTED], 40.0)

    def test_requests_without_a_body_size_are_left_out(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"a": 10}), with_body("t2", {"a": 10}, body=100)])
        requests, _, _ = self.read()
        result = replay_tool.composition(requests)
        assert result is not None
        self.assertEqual((len(requests), result.requests, result.body_bytes), (2, 1, 100))
        self.assertIsNone(replay_tool.composition(requests[:1]))
        self.assertIsNone(replay_tool.composition([]))

    def test_unreadable_messages_are_counted(self) -> None:
        row = with_body("t1", {"a": 1}, body=100)
        row["messages"] = [
            {"role": "user", "artifact": {"bytes": 5}},
            {"artifact": {"bytes": 5}},
            {"role": "tool"},
            {"role": "tool", "artifact": {"bytes": True}},
            "text",
        ]
        other = with_body("t2", {"a": 1}, body=100)
        other["messages"] = "not a list"
        absent = stored("t3", {"a": 1})
        self.store.requests("alpha", DAY_1, [row, other, absent])
        requests, _, skipped = self.read()
        self.assertEqual(skipped.bad_message_entries, 5)
        self.assertEqual(requests[0].message_bytes, {"user": 5})


class CommandLineTest(TempStoreCase):
    def run_main(self, *extra: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        args = ["--base-path", str(self.store.base), "--from-date", DAY_1, "--to-date", DAY_2, *extra]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = replay_tool.main(args)
        return code, out.getvalue(), err.getvalue()

    def test_report_and_json_match(self) -> None:
        self.store.requests("alpha", DAY_1, [stored(f"t{i}", {"core": 900, "tool": 100}) for i in range(2)])
        self.store.ledger(DAY_1, [call("alpha", "core", "t0", "1")])
        target = self.store.base / "result.json"
        code, out, _ = self.run_main("--tools", "tool", "--json-out", str(target))
        self.assertEqual(code, 0)
        self.assertIn("2 stored requests, 1 agent-core Keepers, surface median 1000 B", out)
        self.assertNotIn("composition of", out)
        payload = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(payload["stored_requests"], 2)
        self.assertEqual(payload["window"], {"from": DAY_1, "to": DAY_2})
        self.assertEqual([replay["carry"] for replay in payload["replays"]], ["same-day", "from-first-call"])
        for replay in payload["replays"]:
            self.assertEqual(replay["removed_bytes"], 2 * 100 - 2 * (len("tool") + 2))
        by_name = {row["name"]: row for row in payload["tools"]}
        self.assertIsNone(by_name["tool"]["ratio"])
        self.assertEqual(by_name["core"]["needed_turns"], 1)

    def test_composition_is_in_the_report_and_json(self) -> None:
        self.store.requests("alpha", DAY_1, [with_body("t1", {"a": 10}, body=100, system=20, messages=(("tool", 30),))])
        target = self.store.base / "result.json"
        code, out, _ = self.run_main("--json-out", str(target))
        self.assertEqual(code, 0)
        self.assertIn("composition of 1 requests with a body size", out)
        payload = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(payload["composition"]["requests"], 1)
        self.assertEqual(payload["composition"]["pooled_pct"]["messages.tool"], 30.0)
        self.assertEqual(payload["composition"]["median_pct"]["unaccounted"], 40.0)

    def test_without_tools_there_is_no_replay(self) -> None:
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 10})])
        target = self.store.base / "result.json"
        code, _, _ = self.run_main("--json-out", str(target))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(target.read_text(encoding="utf-8"))["replays"], [])

    def test_errors_exit_with_two_and_name_the_cause(self) -> None:
        code, _, err = self.run_main()
        self.assertEqual((code, err.strip()), (2, "error: no stored request in the window"))
        self.store.requests("alpha", DAY_1, [stored("t1", {"tool": 10})])
        code, _, err = self.run_main("--tools", "missing")
        self.assertEqual(code, 2)
        self.assertIn("missing", err)

    def test_a_reversed_window_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
            replay_tool.main(["--base-path", str(self.store.base), "--from-date", DAY_2, "--to-date", DAY_1])
        self.assertEqual(raised.exception.code, 2)

    def test_a_date_that_is_not_a_day_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
            replay_tool.main(["--base-path", str(self.store.base), "--from-date", "2026-13-01", "--to-date", DAY_2])
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
