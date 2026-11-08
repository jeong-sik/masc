"""Checks the counting of idle_repeats.py on small synthetic calls, ledgers and turn traces.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import idle_repeats as repeats  # noqa: E402
import measure_before_after as before_after  # noqa: E402

DAY_START = before_after.parse_instant("2026-11-05T00:00:00").timestamp()
GAP = repeats.DEFAULT_GAP_S


def payload(answer: str, run_ms: int = 5) -> str:
    return json.dumps({"ok": True, "output": answer, "execution_time_ms": run_ms})


def execute(
    end: float,
    keeper: str = "a",
    command: str = "gh api pulls",
    answer: str = "same",
    tool: str = "Execute",
    held_s: float = 1.0,
    result_bytes: int = 10,
    run_ms: int = 5,
) -> before_after.Call:
    return before_after.Call(
        ts=end,
        tool=tool,
        keeper=keeper,
        duration_ms=held_s * 1000,
        result_bytes=result_bytes,
        failed=False,
        input_text=json.dumps({"command": command}),
        output_text=payload(answer, run_ms),
        sandbox="remote_ssh",
    )


def usage_line(ts: float, input_tokens: int, cache: int = 0, output: int = 0, kind: str = repeats.USAGE_EVENT) -> str:
    event = {"type": kind, "usage": {"input_tokens": input_tokens, "cache_read_input_tokens": cache, "output_tokens": output}}
    return json.dumps({"v": 2, "seq": 1, "ts": ts, "event": event})


class AnswerTest(unittest.TestCase):
    def test_timing_does_not_make_two_answers_differ(self) -> None:
        self.assertEqual(repeats.answer_digest(payload("x", 5)), repeats.answer_digest(payload("x", 900)))

    def test_a_different_output_is_a_different_answer(self) -> None:
        self.assertNotEqual(repeats.answer_digest(payload("x")), repeats.answer_digest(payload("y")))

    def test_key_order_does_not_matter(self) -> None:
        self.assertEqual(repeats.answer_digest('{"a": 1, "b": 2}'), repeats.answer_digest('{"b": 2, "a": 1}'))

    def test_text_that_is_not_a_json_object_is_compared_as_text(self) -> None:
        self.assertEqual(repeats.answer_digest("plain"), repeats.answer_digest("plain"))
        self.assertNotEqual(repeats.answer_digest("plain"), repeats.answer_digest("other"))
        self.assertNotEqual(repeats.answer_digest("[1, 2]"), repeats.answer_digest("[1, 3]"))


class HeadTest(unittest.TestCase):
    def test_the_command_is_squeezed_to_one_line(self) -> None:
        self.assertEqual(repeats.command_head(json.dumps({"command": "gh  api\n  pulls"})), "gh api pulls")

    def test_the_head_is_cut_at_the_limit(self) -> None:
        head = repeats.command_head(json.dumps({"command": "x" * 500}))
        self.assertEqual(len(head), repeats.COMMAND_HEAD_CHARS)

    def test_input_that_is_not_json_is_used_as_text(self) -> None:
        self.assertEqual(repeats.command_head('{"command": "cut sho'), '{"command": "cut sho')

    def test_json_without_a_command_is_used_as_text(self) -> None:
        self.assertEqual(repeats.command_head('{"script": "ls"}'), '{"script": "ls"}')


class ScanTest(unittest.TestCase):
    def test_three_identical_runs_are_one_first_run_and_two_repeats(self) -> None:
        found = repeats.scan([execute(100), execute(120), execute(140)], GAP)
        self.assertEqual((len(found.repeats), dict(found.executes), found.streaks), (2, {"a": 3}, {"a": [3]}))

    def test_a_changed_answer_ends_the_streak(self) -> None:
        found = repeats.scan([execute(100), execute(110), execute(120, answer="new"), execute(130, answer="new")], GAP)
        self.assertEqual((len(found.repeats), found.streaks), (2, {"a": [2, 2]}))

    def test_a_run_after_a_longer_gap_is_not_a_repeat(self) -> None:
        found = repeats.scan([execute(100), execute(100 + GAP + 1)], GAP)
        self.assertEqual((len(found.repeats), found.streaks), (0, {}))

    def test_a_run_exactly_one_gap_later_is_a_repeat(self) -> None:
        self.assertEqual(len(repeats.scan([execute(100), execute(100 + GAP)], GAP).repeats), 1)

    def test_the_gap_is_measured_from_the_last_run_not_the_first(self) -> None:
        calls = [execute(0), execute(GAP - 1), execute(2 * GAP - 2)]
        self.assertEqual(len(repeats.scan(calls, GAP).repeats), 2)

    def test_another_command_in_between_does_not_end_the_streak(self) -> None:
        found = repeats.scan([execute(100), execute(110, command="ls", answer="z"), execute(120)], GAP)
        self.assertEqual((len(found.repeats), found.streaks), (1, {"a": [2]}))

    def test_the_same_command_with_another_argument_is_another_command(self) -> None:
        found = repeats.scan([execute(100, command="gh api pulls/1"), execute(110, command="gh api pulls/2")], GAP)
        self.assertEqual(len(found.repeats), 0)

    def test_keepers_do_not_share_runs(self) -> None:
        found = repeats.scan([execute(100, keeper="a"), execute(110, keeper="b")], GAP)
        self.assertEqual((len(found.repeats), dict(found.executes)), (0, {"a": 1, "b": 1}))

    def test_only_execute_calls_count(self) -> None:
        found = repeats.scan([execute(100, tool="Read"), execute(110, tool="Read")], GAP)
        self.assertEqual((len(found.repeats), dict(found.executes)), (0, {}))

    def test_calls_out_of_order_are_sorted_by_end_time(self) -> None:
        found = repeats.scan([execute(140), execute(100), execute(120)], GAP)
        self.assertEqual(found.streaks, {"a": [3]})

    def test_calls_far_apart_are_not_close_when_listed_the_other_way_round(self) -> None:
        found = repeats.scan([execute(100 + GAP + 50), execute(100)], GAP)
        self.assertEqual(len(found.repeats), 0)

    def test_a_repeat_records_its_hold_its_bytes_and_the_first_head(self) -> None:
        found = repeats.scan([execute(100, held_s=2.0), execute(120, held_s=3.5, result_bytes=77)], GAP)
        self.assertEqual(found.repeats, [repeats.Repeat("a", "gh api pulls", 3.5, 77, 120)])

    def test_the_run_time_of_the_command_does_not_hide_a_repeat(self) -> None:
        found = repeats.scan([execute(100, run_ms=5), execute(120, run_ms=7000)], GAP)
        self.assertEqual(len(found.repeats), 1)

    def test_a_call_whose_answer_is_not_json_still_repeats(self) -> None:
        plain = before_after.Call(100, "Execute", "a", 1000.0, 1, True, "{}", "boom", "remote_ssh")
        again = before_after.Call(110, "Execute", "a", 1000.0, 1, True, "{}", "boom", "remote_ssh")
        self.assertEqual(len(repeats.scan([plain, again], GAP).repeats), 1)


class DateCallTest(unittest.TestCase):
    def test_a_bare_date_command_counts(self) -> None:
        for command in ["date", "date -u", "date -u +%H:%MZ", "date -u +'%Y-%m-%dT%H:%M:%SZ'", "  date -u  "]:
            self.assertTrue(repeats.is_date_call(json.dumps({"command": command})), command)

    def test_an_argv_date_counts(self) -> None:
        self.assertTrue(repeats.is_date_call(json.dumps({"argv": ["date", "-u", "+%Y-%m-%dT%H:%MZ"], "cwd": "."})))

    def test_anything_around_the_date_does_not(self) -> None:
        for command in ["date; ls", "date && ls", "date | cat", "echo date", "datex", "date > out", "date $(id)", "date `id`", "ls; date", "date -u\nls", ""]:
            self.assertFalse(repeats.is_date_call(json.dumps({"command": command})), command)

    def test_an_argv_that_carries_a_list_or_a_non_string_does_not(self) -> None:
        self.assertFalse(repeats.is_date_call(json.dumps({"argv": ["date", "-d", "now; ls"]})))
        self.assertFalse(repeats.is_date_call(json.dumps({"argv": []})))
        self.assertFalse(repeats.is_date_call(json.dumps({"argv": ["date", 1]})))

    def test_input_that_is_not_a_json_object_with_a_command_does_not(self) -> None:
        self.assertFalse(repeats.is_date_call("date"))
        self.assertFalse(repeats.is_date_call("[1]"))
        self.assertFalse(repeats.is_date_call(json.dumps({"script": "date"})))
        self.assertFalse(repeats.is_date_call(json.dumps({"command": 7})))

    def test_a_date_call_is_counted_per_keeper_among_execute_calls_only(self) -> None:
        calls = [
            execute(100, command="date -u"),
            execute(110, command="date -u +%s", answer="x"),
            execute(120, command="ls"),
            execute(130, keeper="b", command="date"),
            execute(140, tool="Read", command="date"),
        ]
        self.assertEqual(dict(repeats.scan(calls, GAP).date_calls), {"a": 2, "b": 1})


class StreakCountTest(unittest.TestCase):
    def summary_of(self, longest: int) -> dict[str, object]:
        found = repeats.Scan(Counter({"a": longest}), Counter(), Counter(), [], {"a": [longest]})
        return repeats.keeper_summary("a", found, {}, 0)

    def test_a_streak_of_exactly_the_minimum_counts_as_long(self) -> None:
        self.assertEqual(self.summary_of(repeats.STREAK_MIN)["streaks_of_10_or_more"], 1)

    def test_a_streak_one_short_of_the_minimum_does_not(self) -> None:
        self.assertEqual(self.summary_of(repeats.STREAK_MIN - 1)["streaks_of_10_or_more"], 0)


class HourlyTest(unittest.TestCase):
    HOUR = repeats.SECONDS_PER_HOUR

    def test_the_hour_starts_on_the_utc_hour(self) -> None:
        self.assertEqual(repeats.hour_start(DAY_START + self.HOUR - 0.5), DAY_START)
        self.assertEqual(repeats.hour_start(DAY_START + self.HOUR), DAY_START + self.HOUR)

    def test_a_call_is_counted_in_the_hour_it_ended(self) -> None:
        found = repeats.scan([execute(DAY_START + self.HOUR - 1, command="x"), execute(DAY_START + self.HOUR, command="y")], GAP)
        self.assertEqual(dict(found.executes_by_hour), {DAY_START: 1, DAY_START + self.HOUR: 1})

    def test_a_repeat_is_counted_in_the_hour_of_the_repeat_not_of_the_first_run(self) -> None:
        found = repeats.scan([execute(DAY_START + self.HOUR - 100), execute(DAY_START + self.HOUR + 100)], GAP)
        rows = repeats.hourly(found)
        self.assertEqual([(r["execute_calls"], r["repeat_calls"]) for r in rows], [(1, 0), (1, 1)])

    def test_hours_come_in_order_and_an_hour_without_a_call_is_left_out(self) -> None:
        later = DAY_START + 2 * self.HOUR + 5
        found = repeats.scan([execute(later, answer="b"), execute(DAY_START + 5, answer="a"), execute(DAY_START + 25, answer="a")], GAP)
        rows = repeats.hourly(found)
        self.assertEqual(
            rows,
            [
                {"hour": "2026-11-05T00:00:00+00:00", "execute_calls": 2, "repeat_calls": 1, "repeat_share": 0.5},
                {"hour": "2026-11-05T02:00:00+00:00", "execute_calls": 1, "repeat_calls": 0, "repeat_share": 0.0},
            ],
        )


class TokensTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = pathlib.Path(self.dir.name)

    def trace(self, keeper: str, name: str, lines: list[str], mtime: float | None = None) -> pathlib.Path:
        folder = self.base / ".masc" / repeats.TURN_EVENTS / keeper
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / name
        path.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def test_requests_in_the_window_are_summed(self) -> None:
        self.trace("a", "t-1-x.jsonl", [usage_line(100, 10, 4, 1), usage_line(200, 20, 8, 2)])
        self.assertEqual(repeats.read_tokens(self.base, 0, 1_000), {"a": repeats.Tokens(2, 30, 12, 3)})

    def test_the_window_includes_its_start_and_excludes_its_end(self) -> None:
        self.trace("a", "t-1-x.jsonl", [usage_line(100, 1), usage_line(200, 2), usage_line(300, 4)])
        self.assertEqual(repeats.read_tokens(self.base, 100, 300)["a"].input_tokens, 3)

    def test_other_events_and_broken_lines_are_not_requests(self) -> None:
        lines = [usage_line(100, 5, kind="agent_core_turn_complete"), "not json", json.dumps({"ts": 100, "event": {"type": "x"}}), usage_line(100, 7)]
        self.trace("a", "t-1-x.jsonl", lines)
        self.assertEqual(repeats.read_tokens(self.base, 0, 1_000)["a"].requests, 1)

    def test_a_file_written_before_the_window_is_not_read(self) -> None:
        self.trace("a", "t-1-x.jsonl", [usage_line(500, 9)], mtime=50)
        self.assertEqual(repeats.read_tokens(self.base, 100, 1_000), {})

    def test_a_keeper_without_a_request_in_the_window_is_left_out(self) -> None:
        self.trace("quiet", "t-1-x.jsonl", [usage_line(5_000, 9)])
        self.assertEqual(repeats.read_tokens(self.base, 0, 1_000), {})

    def test_a_missing_trace_folder_gives_nothing(self) -> None:
        self.assertEqual(repeats.read_tokens(self.base, 0, 1_000), {})


class MeasureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = pathlib.Path(self.dir.name)

    def write_ledger(self, rows: list[dict[str, object]]) -> None:
        folder = self.base / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True)
        (folder / "05.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def row(self, keeper: str, end: float, answer: str = "same", command: str = "gh api pulls") -> dict[str, object]:
        return {
            "record_kind": "tool_call",
            "ts": end,
            "tool": "Execute",
            "keeper": keeper,
            "duration_ms": 1000,
            "result_bytes": 1_048_576,
            "disposition": "ok",
            "input": json.dumps({"command": command}),
            "output": payload(answer),
        }

    def write_trace(self, keeper: str, stamps: list[float], input_tokens: int) -> None:
        folder = self.base / ".masc" / repeats.TURN_EVENTS / keeper
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "trace-1-0-1-abc.jsonl").write_text(
            "".join(usage_line(stamp, input_tokens) + "\n" for stamp in stamps), encoding="utf-8"
        )

    def run_main(self, *extra: str) -> tuple[int, pathlib.Path]:
        out = self.base / "result.json"
        argv = ["--base-path", str(self.base), "--since", "2026-11-05T00:00:00", "--end", "2026-11-05T01:00:00", "--json-out", str(out), *extra]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = repeats.main(argv)
        return code, out

    def test_a_waiting_keeper_is_counted_against_its_own_requests_and_the_fleet(self) -> None:
        t0 = DAY_START
        self.write_ledger(
            [self.row("waiter", t0 + 100 + 20 * i) for i in range(12)]
            + [self.row("worker", t0 + 100, answer="a"), self.row("worker", t0 + 200, answer="b")]
        )
        self.write_trace("waiter", [t0 + 100 + 20 * i for i in range(12)], 300)
        self.write_trace("worker", [t0 + 100, t0 + 200], 1_200)
        code, out = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(
            result["execute"],
            {"calls": 14, "repeat_calls": 11, "repeat_share": round(11 / 14, 4), "repeat_held_hours": round(11 / 3600, 3), "repeat_result_mib": 11.0, "date_calls": 0, "date_call_share": 0.0, "keepers_with_repeats": 1},
        )
        self.assertEqual(result["model_requests"]["requests"], 14)
        self.assertEqual(result["model_requests"]["input_tokens"], 12 * 300 + 2 * 1_200)
        [top] = result["top_keepers"]
        self.assertEqual((top["keeper"], top["repeat_calls"], top["execute_calls"]), ("waiter", 11, 12))
        self.assertEqual((top["longest_streak"], top["streaks_of_10_or_more"]), (12, 1))
        self.assertEqual(top["input_token_share_of_all_keepers"], round(3_600 / 6_000, 4))
        self.assertEqual(top["repeats_per_model_request"], round(11 / 12, 3))
        self.assertEqual(top["top_commands"], [{"command": "gh api pulls", "repeats": 11}])
        self.assertEqual(
            result["hourly"],
            [{"hour": "2026-11-05T00:00:00+00:00", "execute_calls": 14, "repeat_calls": 11, "repeat_share": round(11 / 14, 4)}],
        )

    def test_the_keepers_with_the_most_date_calls_are_listed_first_with_their_share(self) -> None:
        t0 = DAY_START
        self.write_ledger(
            [self.row("a", t0 + 90, command="date -u"), self.row("a", t0 + 200, command="ls")]
            + [self.row("b", t0 + 100 + 10 * i, answer=str(i), command="date") for i in range(3)]
        )
        _, out = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(result["execute"]["date_calls"], 4)
        self.assertEqual(result["execute"]["date_call_share"], round(4 / 5, 4))
        self.assertEqual(
            result["date_callers"],
            [
                {"keeper": "b", "date_calls": 3, "execute_calls": 3, "date_call_share": 1.0},
                {"keeper": "a", "date_calls": 1, "execute_calls": 2, "date_call_share": 0.5},
            ],
        )

    def test_a_keeper_without_a_trace_has_no_request_ratio(self) -> None:
        t0 = DAY_START
        self.write_ledger([self.row("a", t0 + 100), self.row("a", t0 + 110)])
        _, out = self.run_main()
        [top] = json.loads(out.read_text(encoding="utf-8"))["top_keepers"]
        self.assertEqual((top["model_requests"], top["repeats_per_model_request"], top["input_token_share_of_all_keepers"]), (0, None, None))

    def test_a_ledger_without_repeats_lists_no_keeper(self) -> None:
        self.write_ledger([self.row("a", DAY_START + 100, answer="x"), self.row("a", DAY_START + 200, answer="y")])
        _, out = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual((result["top_keepers"], result["execute"]["repeat_calls"]), ([], 0))

    def test_an_empty_ledger_gives_no_share(self) -> None:
        self.write_ledger([])
        _, out = self.run_main()
        self.assertIsNone(json.loads(out.read_text(encoding="utf-8"))["execute"]["repeat_share"])

    def test_the_gap_option_reaches_the_scan(self) -> None:
        self.write_ledger([self.row("a", DAY_START + 100), self.row("a", DAY_START + 400)])
        _, out = self.run_main("--gap-s", "60")
        self.assertEqual(json.loads(out.read_text(encoding="utf-8"))["execute"]["repeat_calls"], 0)

    def test_an_end_before_the_start_is_refused(self) -> None:
        argv = ["--base-path", str(self.base), "--since", "2026-11-05T01:00:00", "--end", "2026-11-05T00:00:00"]
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(repeats.main(argv), 2)

    def test_a_gap_that_is_not_positive_is_refused(self) -> None:
        code, _ = self.run_main("--gap-s", "0")
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
