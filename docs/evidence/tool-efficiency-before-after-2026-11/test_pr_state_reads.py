"""Checks the counting of pr_state_reads.py on small synthetic calls and ledgers.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_before_after as before_after  # noqa: E402
import pr_state_reads as reads  # noqa: E402

DAY_START = before_after.parse_instant("2026-11-05T00:00:00").timestamp()
SECONDS_PER_DAY = 86_400.0
SWEEP = (
    "for n in $(gh pr list -R o/r --state open --json number --jq '.[].number'); do "
    "gh pr view $n -R o/r --json headRefOid; gh api repos/o/r/pulls/$n/reviews; done"
)


def call(
    end: float,
    command: str = "gh pr view 5",
    keeper: str = "a",
    tool: str = "Execute",
    held_s: float = 1.0,
    input_text: str | None = None,
) -> before_after.Call:
    return before_after.Call(
        ts=end,
        tool=tool,
        keeper=keeper,
        duration_ms=held_s * 1000,
        result_bytes=10,
        failed=False,
        input_text=json.dumps({"command": command}) if input_text is None else input_text,
        output_text="{}",
        sandbox="remote_ssh",
        turn="",
    )


class CommandTextTest(unittest.TestCase):
    def test_the_command_is_taken_as_it_is(self) -> None:
        self.assertEqual(reads.command_text(json.dumps({"command": "gh pr list"})), "gh pr list")

    def test_an_argv_is_joined(self) -> None:
        self.assertEqual(reads.command_text(json.dumps({"argv": ["gh", "pr", "view", "5"]})), "gh pr view 5")

    def test_the_script_of_a_shell_argv_is_the_text(self) -> None:
        self.assertEqual(reads.command_text(json.dumps({"argv": ["sh", "-c", "gh pr list | wc -l"]})), "gh pr list | wc -l")
        self.assertEqual(reads.command_text(json.dumps({"argv": ["bash", "-lc", "gh pr list"]})), "gh pr list")

    def test_a_shell_argv_with_another_flag_is_joined(self) -> None:
        self.assertEqual(reads.command_text(json.dumps({"argv": ["sh", "-x", "run.sh"]})), "sh -x run.sh")

    def test_a_shell_argv_with_more_than_a_script_is_joined(self) -> None:
        self.assertEqual(reads.command_text(json.dumps({"argv": ["sh", "-c", "gh pr list", "name"]})), "sh -c gh pr list name")

    def test_an_argv_with_a_non_text_token_is_not_read(self) -> None:
        text = json.dumps({"argv": ["gh", 5]})
        self.assertEqual(reads.command_text(text), text)

    def test_an_empty_argv_is_not_read(self) -> None:
        text = json.dumps({"argv": []})
        self.assertEqual(reads.command_text(text), text)

    def test_input_that_is_not_a_json_object_is_the_text(self) -> None:
        self.assertEqual(reads.command_text("gh pr view 5"), "gh pr view 5")
        self.assertEqual(reads.command_text("[1, 2]"), "[1, 2]")

    def test_a_command_that_is_not_text_falls_back_to_the_input(self) -> None:
        text = json.dumps({"command": 5})
        self.assertEqual(reads.command_text(text), text)


class PrReadTest(unittest.TestCase):
    def test_these_commands_read_pull_requests(self) -> None:
        for command in (
            "gh pr view 5 --json title",
            "gh pr list -R o/r",
            "gh pr checks 5",
            "gh pr status",
            "gh api repos/o/r/pulls/5/reviews",
            "gh api repos/o/r/pulls?state=open",
            "gh api graphql -f query='{ repository { pullRequests(first: 5) { nodes { number } } } }'",
            "cd x && gh pr view 5",
        ):
            with self.subTest(command=command):
                self.assertIsNotNone(reads.PR_READ.search(command))

    def test_these_commands_do_not(self) -> None:
        for command in (
            "gh pr diff 5",
            "gh pr create --title x",
            "gh issue list",
            "gh run list",
            "gh api repos/o/r/issues/5",
            "ggh pr view 5",
            "xgh api repos/o/r/pulls/5",
            "echo gh_pr_view",
            "git log",
        ):
            with self.subTest(command=command):
                self.assertIsNone(reads.PR_READ.search(command))

    def test_a_pipe_ends_the_arguments_of_gh_api(self) -> None:
        self.assertIsNone(reads.PR_READ.search("gh api user | grep /pulls"))


class ShapeTest(unittest.TestCase):
    def test_a_loop_over_a_list_that_gh_made_is_a_fan_out(self) -> None:
        self.assertEqual(reads.shape_of(SWEEP), reads.FAN_OUT)

    def test_the_other_ways_to_feed_a_loop_from_gh_are_fan_outs_too(self) -> None:
        for command in (
            "gh pr list --json number --jq '.[].number' | while read n; do gh pr view $n; done",
            "gh pr list --json number --jq '.[].number' | xargs -n1 gh pr view",
            "for n in `gh pr list --json number --jq '.[].number'`; do gh pr view $n; done",
            "while read n; do gh pr view $n; done < <(gh api repos/o/r/pulls --jq '.[].number')",
        ):
            with self.subTest(command=command):
                self.assertEqual(reads.shape_of(command), reads.FAN_OUT)

    def test_a_loop_that_gh_did_not_feed_is_not_a_fan_out(self) -> None:
        self.assertEqual(reads.shape_of("for i in 1 2 3; do gh pr view 5; done"), reads.SINGLE)

    def test_a_list_without_a_loop_is_not_a_fan_out(self) -> None:
        self.assertEqual(reads.shape_of("x=$(gh pr list --json number); echo $x"), reads.SINGLE)

    def test_a_sleep_with_a_number_or_a_watch_is_a_wait(self) -> None:
        self.assertEqual(reads.shape_of("sleep 300; gh pr view 5"), reads.WAIT)
        self.assertEqual(reads.shape_of("gh pr checks 5 --watch"), reads.WAIT)

    def test_a_sleep_without_a_number_is_not_a_wait(self) -> None:
        self.assertEqual(reads.shape_of("sleep $N; gh pr view 5"), reads.SINGLE)

    def test_a_loop_that_sleeps_is_still_a_fan_out(self) -> None:
        self.assertEqual(reads.shape_of(SWEEP + "; sleep 60"), reads.FAN_OUT)

    def test_everything_else_is_single(self) -> None:
        self.assertEqual(reads.shape_of("gh pr view 5"), reads.SINGLE)


class ScanTest(unittest.TestCase):
    def test_only_execute_calls_are_counted(self) -> None:
        found = reads.scan([call(DAY_START + 10), call(DAY_START + 20, tool="Grep")])
        self.assertEqual(dict(found.execute_calls), {"2026-11-05": 1})
        self.assertEqual(len(found.reads), 1)

    def test_calls_that_read_nothing_still_count_as_execute_time(self) -> None:
        found = reads.scan([call(DAY_START + 10, command="ls", held_s=3.0), call(DAY_START + 20, held_s=1.0)])
        self.assertEqual(found.execute_calls["2026-11-05"], 2)
        self.assertEqual(found.execute_ms["2026-11-05"], 4000.0)
        self.assertEqual([read.held_ms for read in found.reads], [1000.0])

    def test_the_day_changes_at_utc_midnight_of_the_end_time(self) -> None:
        found = reads.scan([call(DAY_START + SECONDS_PER_DAY - 1), call(DAY_START + SECONDS_PER_DAY)])
        self.assertEqual([read.day for read in found.reads], ["2026-11-05", "2026-11-06"])

    def test_a_read_carries_its_keeper_and_shape(self) -> None:
        [read] = reads.scan([call(DAY_START + 10, command=SWEEP, keeper="sweeper", held_s=90.0)]).reads
        self.assertEqual((read.keeper, read.shape, read.held_ms), ("sweeper", reads.FAN_OUT, 90_000.0))

    def test_an_input_that_is_not_json_is_read_as_text(self) -> None:
        found = reads.scan([call(DAY_START + 10, input_text="gh pr list")])
        self.assertEqual(len(found.reads), 1)


class SummaryTest(unittest.TestCase):
    def summary(self, calls: list[before_after.Call]) -> dict[str, object]:
        return reads.summarize(reads.scan(calls))

    def test_a_day_row_has_the_shares_of_calls_and_hours(self) -> None:
        result = self.summary(
            [
                call(DAY_START + 10, command=SWEEP, held_s=90.0),
                call(DAY_START + 20, command="sleep 300; gh pr view 5", keeper="b", held_s=300.0),
                call(DAY_START + 30, command="gh pr view 5", keeper="b", held_s=2.0),
                call(DAY_START + 40, command="ls", held_s=8.0),
            ]
        )
        [day] = cast("list[dict[str, object]]", result["days"])
        self.assertEqual(day["day"], "2026-11-05")
        self.assertEqual((day["execute_calls"], day["pr_read_calls"]), (4, 3))
        self.assertEqual(day["pr_read_call_share"], round(3 / 4, 4))
        self.assertEqual(day["execute_hours"], round(400 / 3600, 3))
        self.assertEqual(day["pr_read_hours"], round(392 / 3600, 3))
        self.assertEqual(day["pr_read_hour_share"], round(392 / 400, 4))
        self.assertEqual(day["keepers"], 2)
        self.assertEqual(
            day["by_shape"],
            {
                "fan_out": {"calls": 1, "hours": round(90 / 3600, 3)},
                "wait": {"calls": 1, "hours": round(300 / 3600, 3)},
                "single": {"calls": 1, "hours": round(2 / 3600, 3)},
            },
        )

    def test_every_shape_is_listed_even_when_empty(self) -> None:
        result = self.summary([call(DAY_START + 10)])
        [day] = cast("list[dict[str, object]]", result["days"])
        self.assertEqual(day["by_shape"], {"fan_out": {"calls": 0, "hours": 0.0}, "wait": {"calls": 0, "hours": 0.0}, "single": {"calls": 1, "hours": round(1 / 3600, 3)}})

    def test_the_total_adds_the_days(self) -> None:
        result = self.summary([call(DAY_START + 10, held_s=3.0), call(DAY_START + SECONDS_PER_DAY + 10, held_s=5.0), call(DAY_START + SECONDS_PER_DAY + 20, command="ls", held_s=2.0)])
        days = cast("list[dict[str, object]]", result["days"])
        self.assertEqual([day["day"] for day in days], ["2026-11-05", "2026-11-06"])
        total = cast("dict[str, object]", result["total"])
        self.assertEqual((total["day"], total["execute_calls"], total["pr_read_calls"]), ("all", 3, 2))
        self.assertEqual(total["pr_read_hours"], round(8 / 3600, 3))
        self.assertEqual(total["pr_read_hour_share"], round(8 / 10, 4))

    def test_the_days_are_listed_oldest_first_whatever_the_order_of_the_calls(self) -> None:
        result = self.summary([call(DAY_START + SECONDS_PER_DAY + 10), call(DAY_START + 10)])
        days = cast("list[dict[str, object]]", result["days"])
        self.assertEqual([day["day"] for day in days], ["2026-11-05", "2026-11-06"])

    def test_days_without_execute_calls_are_left_out_and_shares_have_no_zero_division(self) -> None:
        result = self.summary([])
        self.assertEqual(result["days"], [])
        total = cast("dict[str, object]", result["total"])
        self.assertEqual((total["pr_read_call_share"], total["pr_read_hour_share"]), (None, None))

    def test_the_keepers_are_ranked_by_held_hours_then_name(self) -> None:
        result = self.summary(
            [
                call(DAY_START + 10, keeper="small", held_s=1.0),
                call(DAY_START + 20, keeper="big", held_s=50.0),
                call(DAY_START + 30, keeper="b-tie", held_s=5.0),
                call(DAY_START + 40, keeper="a-tie", held_s=5.0),
            ]
        )
        top = cast("list[dict[str, object]]", result["top_keepers"])
        self.assertEqual([row["keeper"] for row in top], ["big", "a-tie", "b-tie", "small"])

    def test_only_the_six_keepers_with_the_most_hours_are_listed(self) -> None:
        result = self.summary([call(DAY_START + 10 * i, keeper=f"k{i}", held_s=float(i)) for i in range(1, 9)])
        top = cast("list[dict[str, object]]", result["top_keepers"])
        self.assertEqual([row["keeper"] for row in top], ["k8", "k7", "k6", "k5", "k4", "k3"])

    def test_a_keeper_row_counts_its_loops_and_their_median(self) -> None:
        result = self.summary(
            [call(DAY_START + 10 * i, command=SWEEP, keeper="s", held_s=float(seconds)) for i, seconds in enumerate((70, 90, 100, 120), start=1)]
            + [call(DAY_START + 100, command="gh pr view 5", keeper="s", held_s=2.0)]
        )
        [row] = cast("list[dict[str, object]]", result["top_keepers"])
        self.assertEqual((row["pr_read_calls"], row["fan_out_calls"]), (5, 4))
        self.assertEqual(row["fan_out_hours"], round(380 / 3600, 3))
        self.assertEqual(row["fan_out_p50_s"], 100.0)
        self.assertEqual(row["pr_read_hours"], round(382 / 3600, 3))

    def test_a_keeper_without_loops_has_no_median(self) -> None:
        [row] = cast("list[dict[str, object]]", self.summary([call(DAY_START + 10)])["top_keepers"])
        self.assertEqual((row["fan_out_calls"], row["fan_out_p50_s"]), (0, None))


class MeasureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = pathlib.Path(self.dir.name)

    def write_ledger(self, rows: list[dict[str, object]]) -> None:
        folder = self.base / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True)
        (folder / "05.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def row(self, end: float, command: str, tool: str = "Execute") -> dict[str, object]:
        return {
            "record_kind": "tool_call",
            "ts": end,
            "tool": tool,
            "keeper": "k",
            "duration_ms": 2000,
            "result_bytes": 10,
            "disposition": "ok",
            "input": json.dumps({"command": command}),
            "output": "{}",
        }

    def run_main(self, *extra: str) -> tuple[int, pathlib.Path]:
        out = self.base / "result.json"
        argv = ["--base-path", str(self.base), "--since", "2026-11-05T00:00:00", "--end", "2026-11-05T01:00:00", "--json-out", str(out), *extra]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = reads.main(argv)
        return code, out

    def test_the_window_holds_the_calls_from_the_ledger(self) -> None:
        self.write_ledger(
            [
                self.row(DAY_START + 100, "gh pr view 5"),
                self.row(DAY_START + 200, SWEEP),
                self.row(DAY_START + 300, "ls"),
                self.row(DAY_START + 400, "gh pr view 5", tool="Grep"),
                self.row(DAY_START + 3_600, "gh pr view 5"),
            ]
        )
        code, out = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(result["window"], ["2026-11-05T00:00:00+00:00", "2026-11-05T01:00:00+00:00"])
        self.assertEqual(result["skipped"], {"bad_lines": 0})
        total = result["total"]
        self.assertEqual((total["execute_calls"], total["pr_read_calls"]), (3, 2))
        self.assertEqual(total["by_shape"]["fan_out"]["calls"], 1)
        [top] = result["top_keepers"]
        self.assertEqual((top["keeper"], top["fan_out_calls"], top["fan_out_p50_s"]), ("k", 1, 2.0))

    def test_a_reversed_window_is_refused(self) -> None:
        self.write_ledger([])
        out = self.base / "result.json"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = reads.main(["--base-path", str(self.base), "--since", "2026-11-05T01:00:00", "--end", "2026-11-05T01:00:00", "--json-out", str(out)])
        self.assertEqual(code, 2)
        self.assertFalse(out.exists())

    def test_a_window_longer_than_the_limit_is_refused(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = reads.main(["--base-path", str(self.base), "--since", "2025-01-01T00:00:00", "--end", "2026-11-05T01:00:00"])
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
