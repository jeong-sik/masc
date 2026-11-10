"""Tests for the scripts of this folder on a synthetic ledger.

Run: python3 -I docs/evidence/tool-efficiency-1110-2026-11/test_tool_efficiency_1110.py
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import artifact_read_refusals as artifact  # noqa: E402
import github_wait_shapes as waits  # noqa: E402
import ledger_window as ledger  # noqa: E402
import schedule_until_run as schedule  # noqa: E402
import ts_position as tsposition  # noqa: E402

NEED_DUE = '{"message":"one of due_at_unix, due_at_iso, due_in_sec is required unless recurrence_kind is daily or cron"}'
MISSING = "keeper_artifact_read: artifact does not exist: sha256 abc"
MALFORMED = "keeper_artifact_read: sha256 is malformed"
RUN_URL = "https://github.com/o/r/actions/runs/{}"


def line(
    ts: float,
    tool: str,
    keeper: str = "k",
    disposition: str = "completed",
    output: object = "ok",
    inp: dict[str, object] | None = None,
    duration_ms: float | None = None,
    fingerprint: str | None = None,
    kind: str = "tool_call",
) -> str:
    row: dict[str, object] = {
        "record_kind": kind,
        "ts": ts,
        "tool": tool,
        "keeper": keeper,
        "disposition": disposition,
        "output": output,
    }
    if inp is not None:
        row["input"] = inp
    if duration_ms is not None:
        row["duration_ms"] = duration_ms
    if fingerprint is not None:
        row["output_fingerprint"] = fingerprint
    return json.dumps(row, separators=(",", ":"))


def parsed(lines: list[str]) -> list[ledger.Row]:
    return [json.loads(text) for text in lines]


class LedgerFixture:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.tmp.name)
        self.dir = self.base / ".masc" / "tool_calls" / "2026-11"
        self.dir.mkdir(parents=True)

    def write(self, name: str, lines: list[str], mtime: float | None = None) -> pathlib.Path:
        path = self.dir / name
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def close(self) -> None:
        self.tmp.cleanup()


class LedgerWindowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = LedgerFixture()
        self.addCleanup(self.fx.close)

    def test_parse_utc_reads_z_offsets_and_naive_times_as_utc(self) -> None:
        zulu = ledger.parse_utc("2026-11-10T00:00:00Z")
        self.assertEqual(zulu, ledger.parse_utc("2026-11-10T00:00:00+00:00"))
        self.assertEqual(zulu, ledger.parse_utc("2026-11-10T00:00:00"))
        self.assertEqual(ledger.parse_utc("2026-11-10T09:00:00+09:00"), zulu)

    def test_window_is_half_open_and_keeps_only_tool_call_rows(self) -> None:
        self.fx.write(
            "09.jsonl",
            [
                line(99, "Read"),
                line(100, "Read"),
                line(199, "Read"),
                line(200, "Read"),
                line(150, "Read", kind="tool_call_start"),
                '{"record_kind":"tool_call", broken',
                "not json at all",
            ],
        )
        self.assertEqual([r["ts"] for r in ledger.read_rows(self.fx.base, 100, 200)], [100, 199])

    def test_markers_select_lines_by_raw_text(self) -> None:
        self.fx.write("09.jsonl", [line(10, "Execute"), line(11, "Read"), line(12, "Execute")])
        rows = list(ledger.read_rows(self.fx.base, 0, 100, ('"tool":"Execute"',)))
        self.assertEqual([r["ts"] for r in rows], [10, 12])

    def test_a_file_last_written_before_the_window_is_not_opened(self) -> None:
        self.fx.write("09.jsonl", [line(150, "Read")], mtime=50)
        self.assertEqual(list(ledger.read_rows(self.fx.base, 100, 200)), [])

    def test_a_base_without_a_ledger_gives_no_rows(self) -> None:
        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(list(ledger.read_rows(pathlib.Path(empty), 0, 100)), [])


class ArtifactReadRefusalsTest(unittest.TestCase):
    SINCE = 1000.0
    END = 2000.0

    def measure(self, lines: list[str]) -> dict[str, object]:
        return artifact.measure(parsed(lines), self.SINCE, self.END)

    def read(self, ts: float, sha: str, keeper: str = "a", output: str = "ok", disposition: str = "completed") -> str:
        return line(ts, "keeper_artifact_read", keeper, disposition, output, {"sha256": sha})

    def test_a_refused_sha_equal_to_an_earlier_fingerprint_of_the_same_keeper_is_the_answer_fingerprint(self) -> None:
        result = self.measure(
            [
                line(900, "Execute", "a", fingerprint="f1"),
                self.read(1100, "f1", output=MISSING, disposition="failed"),
                line(1300, "Execute", "a", fingerprint="f1"),
            ]
        )
        self.assertEqual(result["refused_missing"], 1)
        self.assertEqual(result["cause"], {"answer_fingerprint": 1})

    def test_other_keepers_later_and_unknown_fingerprints_are_not_the_cause(self) -> None:
        result = self.measure(
            [
                line(900, "Execute", "b", fingerprint="f1"),
                self.read(1100, "f1", "a", MISSING, "failed"),
                self.read(1200, "f2", "a", MISSING, "failed"),
                self.read(1250, "f3", "a", MISSING, "failed"),
                line(1300, "Execute", "a", fingerprint="f3"),
                self.read(1500, "f9", "a", MISSING, "failed"),
            ]
        )
        self.assertEqual(result["refused_missing"], 4)
        self.assertEqual(result["cause"], {"other": 4})

    def test_rows_before_the_window_give_fingerprints_but_are_not_calls(self) -> None:
        result = self.measure(
            [
                self.read(500, "old", output=MISSING, disposition="failed"),
                line(600, "Read"),
                self.read(1100, "x"),
            ]
        )
        self.assertEqual(result["calls"], 1)
        self.assertEqual(result["refused_missing"], 0)
        self.assertEqual(result["refusal_rate"], 0.0)

    def test_the_next_read_within_300_seconds_decides_the_outcome(self) -> None:
        result = self.measure(
            [
                self.read(1100, "p1", output=MISSING, disposition="failed"),
                self.read(1110, "q1"),
                self.read(1300, "p2", output=MISSING, disposition="failed"),
                self.read(1310, "p2", output=MISSING, disposition="failed"),
                self.read(1320, "r3", output="boom", disposition="failed"),
                self.read(1700, "p4", output=MISSING, disposition="failed"),
            ]
        )
        self.assertEqual(result["refused_missing"], 4)
        self.assertEqual(result["after"], {"fixed": 1, "repeated": 1, "other_error": 1, "none": 1})
        self.assertEqual(result["fix_delay_s"], {"median": 10.0, "p90": 10.0})

    def test_the_response_window_is_300_seconds_and_inclusive(self) -> None:
        result = self.measure(
            [
                self.read(1100, "p1", output=MISSING, disposition="failed"),
                self.read(1400, "q1"),
                self.read(1500, "p2", output=MISSING, disposition="failed"),
                self.read(1801, "q2"),
            ]
        )
        self.assertEqual(result["after"], {"fixed": 1, "none": 1})

    def test_a_completed_row_that_says_the_artifact_is_missing_is_not_a_fix(self) -> None:
        result = self.measure(
            [
                self.read(1100, "p1", output=MISSING, disposition="failed"),
                self.read(1110, "q1", output=MISSING, disposition="completed"),
            ]
        )
        self.assertEqual(result["refused_missing"], 2)
        self.assertEqual(result["after"], {"other_error": 1, "none": 1})

    def test_a_follow_up_after_the_window_end_classifies_a_refusal_inside_it(self) -> None:
        result = self.measure(
            [
                self.read(1990, "p1", output=MISSING, disposition="failed"),
                self.read(2100, "q1"),
                self.read(1500, "p2", output=MISSING, disposition="failed"),
                self.read(1500 + 301, "q2"),
            ]
        )
        self.assertEqual(result["calls"], 3)
        self.assertEqual(result["refused_missing"], 2)
        self.assertEqual(result["after"], {"fixed": 1, "none": 1})

    def test_only_reads_inside_the_half_open_window_are_counted(self) -> None:
        result = self.measure(
            [
                self.read(self.SINCE - 1, "a", output=MISSING, disposition="failed"),
                self.read(self.SINCE, "b"),
                self.read(self.END, "c", output=MISSING, disposition="failed"),
                self.read(self.END + 5, "d", output=MISSING, disposition="failed"),
            ]
        )
        self.assertEqual((result["calls"], result["refused_missing"]), (1, 0))

    def test_a_malformed_sha_is_counted_apart_from_a_missing_artifact(self) -> None:
        result = self.measure([self.read(1100, "zz", output=MALFORMED, disposition="failed")])
        self.assertEqual((result["refused_missing"], result["refused_malformed"]), (0, 1))

    def test_no_reads_give_no_rate(self) -> None:
        result = self.measure([line(1100, "Read")])
        self.assertEqual((result["calls"], result["refusal_rate"]), (0, None))


class ScheduleUntilRunTest(unittest.TestCase):
    SINCE = 5.0
    END = 10_000.0

    def create(
        self,
        ts: float,
        keeper: str = "k",
        until: bool = True,
        due: bool = False,
        refused: bool = False,
    ) -> str:
        inp: dict[str, object] = {"keeper_name": "k", "message": "m"}
        if until:
            inp["until_github_run"] = RUN_URL.format(1)
        if due:
            inp["due_in_sec"] = 600
        return line(
            ts,
            "masc_schedule_create",
            keeper,
            "failed" if refused else "completed",
            NEED_DUE if refused else "{}",
            inp,
        )

    def measure(self, lines: list[str]) -> dict[str, object]:
        return schedule.measure(parsed(lines), self.SINCE, self.END)

    def test_the_rate_counts_only_calls_that_carry_until_github_run(self) -> None:
        result = self.measure(
            [
                self.create(10, due=True),
                self.create(20, refused=True),
                self.create(30, until=False, refused=True),
                line(40, "Read"),
                line(
                    25,
                    "masc_schedule_create",
                    "k",
                    "failed",
                    "boom",
                    {"until_github_run": RUN_URL.format(1), "due_in_sec": 5},
                ),
            ]
        )
        self.assertEqual(result["with_until"], 3)
        self.assertEqual(result["with_until_completed"], 1)
        self.assertEqual(result["missing_due_refused"], 1)
        self.assertEqual(result["missing_due_rate"], round(1 / 3, 4))
        self.assertEqual(result["carried_due_field"], 0)

    def test_a_refusal_that_carried_a_due_field_is_reported(self) -> None:
        result = self.measure([self.create(10, due=True, refused=True)])
        self.assertEqual(result["carried_due_field"], 1)

    def test_the_next_create_of_the_same_keeper_within_180_seconds_is_classified(self) -> None:
        result = self.measure(
            [
                self.create(100, refused=True),
                self.create(150, due=True),
                self.create(1000, refused=True),
                line(1100, "masc_schedule_create", "k", "failed", "boom", {"keeper_name": "k"}),
                self.create(2000, refused=True),
                self.create(2100, keeper="other", due=True),
                self.create(3000, refused=True),
                self.create(3200, due=True),
            ]
        )
        self.assertEqual(result["missing_due_refused"], 4)
        self.assertEqual(result["next_create"], {"completed": 1, "failed": 1, "none": 2})

    def test_no_calls_give_no_rate(self) -> None:
        result = self.measure([])
        self.assertEqual((result["with_until"], result["missing_due_rate"]), (0, None))

    def test_a_follow_up_after_the_window_end_classifies_a_refusal_inside_it(self) -> None:
        result = self.measure(
            [
                self.create(self.END - 10, refused=True),
                self.create(self.END + 100, due=True),
                self.create(self.END - 1000, refused=True),
                self.create(self.END - 1000 + 181, due=True),
            ]
        )
        self.assertEqual(result["missing_due_refused"], 2)
        self.assertEqual(result["next_create"], {"completed": 1, "none": 1})

    def test_only_rows_inside_the_half_open_window_are_counted(self) -> None:
        result = self.measure(
            [
                self.create(self.SINCE - 1, refused=True),
                self.create(self.SINCE, due=True),
                self.create(self.END, refused=True),
                self.create(self.END + 5, refused=True),
            ]
        )
        self.assertEqual((result["with_until"], result["missing_due_refused"]), (1, 0))


class GithubWaitShapesTest(unittest.TestCase):
    def test_shape_of_names_what_the_command_waits_for(self) -> None:
        cases = {
            'sleep 420; gh api "repos/o/r/actions/runs/123" --jq .status': "single_run",
            "gh run view 99 --json status,conclusion": "single_run",
            "gh run watch 5 --exit-status --interval 20": "single_run",
            'gh api "repos/o/r/commits/849f2975dd/check-runs" --jq .check_runs': "commit_checks",
            "sleep 60; gh pr checks 7 --watch": "pr_checks",
            "gh pr view 49811 --json headRefOid,statusCheckRollup": "pr_checks",
            "gh run list --repo o/r --workflow t.yml": None,
            "gh api repos/o/r/git/ref/heads/main": "api_other",
            "gh pr list --state open && gh api repos/o/r/pulls/7/reviews": "api_other",
            "gh run view $ID --json status": "other",
            "dune build @check": None,
            "echo hello": None,
        }
        # `gh run list` alone is not in GITHUB, so it is not a GitHub wait unless another term matches.
        # `gh pr list` lists pull requests and reads none, so it does not make a command `pr_checks`.
        for command, shape in cases.items():
            with self.subTest(command=command):
                self.assertEqual(waits.shape_of(command), shape)

    def test_run_list_is_a_shape_when_a_github_term_also_matches(self) -> None:
        self.assertEqual(waits.shape_of("gh run list --repo o/r --json status && gh api user"), "run_list")

    def test_run_id_comes_from_the_url_or_the_run_subcommand(self) -> None:
        self.assertEqual(waits.run_id_of("gh api repos/o/r/actions/runs/42370622931 --jq .status"), "42370622931")
        self.assertEqual(waits.run_id_of("gh run watch 4237 --exit-status"), "4237")
        self.assertIsNone(waits.run_id_of("gh run view $ID"))

    def execute(self, ts: float, seconds: float, command: str, keeper: str = "k", background: bool = False) -> str:
        inp: dict[str, object] = {"command": command}
        if background:
            inp["run_in_background"] = True
        return line(ts, "Execute", keeper, inp=inp, duration_ms=seconds * 1000)

    def watch(self, ts: float, run: int, keeper: str = "k", disposition: str = "completed") -> str:
        return line(
            ts,
            "masc_schedule_create",
            keeper,
            disposition,
            inp={"until_github_run": RUN_URL.format(run), "due_in_sec": 600},
        )

    def measure(self, executes: list[str], creates: list[str]) -> dict[str, object]:
        return waits.measure(parsed(executes), parsed(creates))

    def test_execute_totals_count_background_and_long_calls(self) -> None:
        result = self.measure(
            [
                self.execute(1000, 5, "ls", background=True),
                self.execute(1100, 30, "sleep 30"),
                self.execute(1300, 120, "sleep 120; gh run view 1"),
                self.execute(1500, 300, "dune build", background=True),
                self.execute(1700, 60, "gh run view 7"),
            ],
            [],
        )
        self.assertEqual(
            result["execute"],
            {"calls": 5, "run_in_background": 2, "long_calls": 3, "long_run_in_background": 1},
        )
        github = result["github_wait"]
        assert isinstance(github, dict)
        self.assertEqual(github["calls"], 2)
        self.assertEqual(github["hours"], round(180 / 3600, 3))

    def test_a_poll_is_watched_only_by_a_completed_watch_of_the_same_keeper_on_that_run_before_it_ended(self) -> None:
        result = self.measure(
            [
                self.execute(2000, 100, "gh run view 1"),
                self.execute(2200, 100, "gh run view 2"),
                self.execute(2400, 100, "gh run view 3"),
                self.execute(2600, 100, "gh run view 4"),
                self.execute(2800, 100, "gh run view 5", keeper="j"),
            ],
            [
                self.watch(1500, 1),
                self.watch(1500, 2, disposition="failed"),
                self.watch(2500, 3),
                self.watch(1500, 5),
            ],
        )
        polls = result["single_run_polls"]
        assert isinstance(polls, dict)
        self.assertEqual(polls["calls"], 5)
        self.assertEqual(polls["watched_by_same_keeper"], {"calls": 1, "hours": round(100 / 3600, 3)})
        not_watched = polls["not_watched"]
        assert isinstance(not_watched, dict)
        self.assertEqual(not_watched["calls"], 4)
        self.assertEqual(not_watched["top_keepers"], [("k", 3), ("j", 1)])

    def test_a_schedule_create_shortly_before_a_poll_began_is_counted(self) -> None:
        result = self.measure(
            [
                self.execute(5100, 100, "gh run view 1"),
                self.execute(6100, 100, "gh run view 2"),
                self.execute(7100, 100, "gh run view 3"),
                self.execute(8100, 100, "gh run view 4"),
                self.execute(20100, 100, "gh run view 5"),
            ],
            [
                self.watch(5000, 91),
                line(5990, "masc_schedule_create", "k", "failed", NEED_DUE, {"until_github_run": RUN_URL.format(92)}),
                line(6000, "masc_schedule_create", "k", "completed", inp={"keeper_name": "k"}),
                self.watch(6000, 93, keeper="j"),
                line(18990, "masc_schedule_create", "k", "completed", inp={"keeper_name": "k"}),
            ],
        )
        polls = result["single_run_polls"]
        assert isinstance(polls, dict)
        self.assertEqual(
            polls["schedule_create_in_prior_15_min"],
            {"any": 2, "with_until_github_run": 2, "refused_missing_due": 1},
        )


class WatchEndTimeTest(unittest.TestCase):
    def test_a_watch_that_finished_after_the_poll_ended_does_not_cover_it(self) -> None:
        poll = line(2700, "Execute", "k", inp={"command": "gh run view 1"}, duration_ms=100_000)
        late_watch = line(
            2750,
            "masc_schedule_create",
            "k",
            "completed",
            inp={"until_github_run": RUN_URL.format(1), "due_in_sec": 600},
            duration_ms=100_000,
        )
        result = waits.measure(parsed([poll]), parsed([late_watch]))
        polls = result["single_run_polls"]
        assert isinstance(polls, dict)
        self.assertEqual(polls["watched_by_same_keeper"]["calls"], 0)  # type: ignore[index]
        self.assertEqual(polls["not_watched"]["calls"], 1)  # type: ignore[index]


class PriorCreateStartTimeTest(unittest.TestCase):
    """`schedule_create_in_prior_15_min` compares the create's start (ts - duration) with the poll's start."""

    P = 50_000.0

    def test_the_band_is_read_from_the_start_of_the_create(self) -> None:
        def create(keeper: str, ended: float, seconds: float) -> str:
            return line(
                ended,
                "masc_schedule_create",
                keeper,
                "completed",
                inp={"keeper_name": keeper},
                duration_ms=seconds * 1000,
            )

        def poll(keeper: str, run: int) -> str:
            return line(
                self.P + 100,
                "Execute",
                keeper,
                inp={"command": f"gh run view {run}"},
                duration_ms=100_000,
            )

        cases = {
            # keeper: (create end, create seconds, counted)
            "ended_in_band_but_began_before": (self.P - 800, 150, False),
            "began_in_band_and_ended_after_poll_began": (self.P + 1, 51, True),
            "began_exactly_900_s_before": (self.P - 890, 10, True),
            "began_900_5_s_before": (self.P - 890.5, 10, False),
            "began_exactly_at_poll_start": (self.P + 10, 10, True),
            "began_half_a_second_after": (self.P + 10.5, 10, False),
        }
        for index, (keeper, (ended, seconds, counted)) in enumerate(cases.items(), start=1):
            with self.subTest(case=keeper):
                result = waits.measure(parsed([poll(keeper, index)]), parsed([create(keeper, ended, seconds)]))
                polls = result["single_run_polls"]
                assert isinstance(polls, dict)
                self.assertEqual(polls["schedule_create_in_prior_15_min"]["any"], 1 if counted else 0)  # type: ignore[index]


class TsPositionTest(unittest.TestCase):
    def execute(
        self,
        ts: float,
        seconds: float,
        keeper: str = "k",
        trace: str | None = "t",
        turn: int | None = 1,
        tool: str = "Execute",
    ) -> ledger.Row:
        row: ledger.Row = {"record_kind": "tool_call", "ts": ts, "tool": tool, "keeper": keeper, "duration_ms": seconds * 1000}
        if trace is not None:
            row["trace_id"] = trace
        if turn is not None:
            row["turn"] = turn
        return row

    def test_a_gap_shorter_than_the_earlier_call_contradicts_ts_is_the_start(self) -> None:
        result = tsposition.measure([self.execute(1000, 100), self.execute(1030, 5)])
        self.assertEqual(result, {"pairs": 1, "contradicts_ts_is_start": 1, "contradicts_ts_is_end": 0})

    def test_a_gap_shorter_than_the_later_call_contradicts_ts_is_the_end(self) -> None:
        result = tsposition.measure([self.execute(1000, 100), self.execute(1003, 10)])
        self.assertEqual(result, {"pairs": 1, "contradicts_ts_is_start": 1, "contradicts_ts_is_end": 1})

    def test_a_long_gap_contradicts_neither(self) -> None:
        result = tsposition.measure([self.execute(1000, 100), self.execute(1200, 5)])
        self.assertEqual(result, {"pairs": 1, "contradicts_ts_is_start": 0, "contradicts_ts_is_end": 0})

    def test_a_gap_equal_to_a_duration_does_not_contradict_that_reading(self) -> None:
        start = tsposition.measure([self.execute(1000, 100), self.execute(1100, 5)])
        self.assertEqual(start, {"pairs": 1, "contradicts_ts_is_start": 0, "contradicts_ts_is_end": 0})
        end = tsposition.measure([self.execute(1000, 100), self.execute(1005, 5)])
        self.assertEqual(end, {"pairs": 1, "contradicts_ts_is_start": 1, "contradicts_ts_is_end": 0})

    def test_the_duration_thresholds_are_inclusive(self) -> None:
        kept = tsposition.measure([self.execute(1000, 60), self.execute(1010, 20)])
        self.assertEqual(kept["pairs"], 1)
        for first, second in ((59.9, 20), (60, 20.1)):
            with self.subTest(first=first, second=second):
                self.assertEqual(tsposition.measure([self.execute(1000, first), self.execute(1010, second)])["pairs"], 0)

    def test_two_keepers_with_the_same_trace_and_turn_are_not_paired(self) -> None:
        rows = [self.execute(1000, 100, keeper="a"), self.execute(1005, 5, keeper="b")]
        self.assertEqual(tsposition.measure(rows)["pairs"], 0)

    def test_a_row_missing_the_trace_or_the_turn_is_skipped(self) -> None:
        rows = [
            self.execute(2000, 100, trace=None),
            self.execute(2010, 5, trace=None),
            self.execute(3000, 100, turn=None),
            self.execute(3010, 5, turn=None),
        ]
        self.assertEqual(tsposition.measure(rows)["pairs"], 0)

    def test_rows_of_other_tools_do_not_sit_between_two_execute_calls(self) -> None:
        rows = [self.execute(3000, 100), self.execute(3010, 30, tool="Read"), self.execute(3020, 5)]
        self.assertEqual(tsposition.measure(rows), {"pairs": 1, "contradicts_ts_is_start": 1, "contradicts_ts_is_end": 0})

    def test_only_neighbours_of_one_keeper_turn_are_paired(self) -> None:
        rows = [
            self.execute(1000, 100),
            self.execute(1010, 100),
            self.execute(1020, 5),
            self.execute(1030, 100, keeper="other"),
            self.execute(1031, 5, keeper="other", turn=2),
            self.execute(1032, 5, trace="other-trace"),
            self.execute(1033, 5, tool="Read"),
            self.execute(1034, 5, trace=None),
            self.execute(1035, 5, turn=None),
        ]
        result = tsposition.measure(rows)
        # (1010, 100) -> (1020, 5) is the only neighbour pair with a long earlier call and a short later call.
        self.assertEqual(result, {"pairs": 1, "contradicts_ts_is_start": 1, "contradicts_ts_is_end": 0})


class CommandLineTest(unittest.TestCase):
    """The scripts read from BASE/.masc/tool_calls and take the window as ISO times; the two with a follow-up window
    read past END."""

    SINCE = "2026-11-10T00:00:00Z"
    END = "2026-11-10T01:00:00Z"

    def setUp(self) -> None:
        self.fx = LedgerFixture()
        self.addCleanup(self.fx.close)
        self.end = ledger.parse_utc(self.END)

    def run_script(self, name: str) -> dict[str, object]:
        script = pathlib.Path(__file__).resolve().parent / name
        done = subprocess.run(
            [sys.executable, "-I", str(script), self.SINCE, self.END, str(self.fx.base)],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )
        return json.loads(done.stdout)

    def test_artifact_read_refusals_reads_the_follow_up_past_the_end(self) -> None:
        self.fx.write(
            "10.jsonl",
            [
                line(self.end - 10, "keeper_artifact_read", "a", "failed", MISSING, {"sha256": "p"}),
                line(self.end + 100, "keeper_artifact_read", "a", "completed", "ok", {"sha256": "q"}),
                line(self.end + 301, "keeper_artifact_read", "a", "failed", MISSING, {"sha256": "r"}),
            ],
        )
        result = self.run_script("artifact_read_refusals.py")
        self.assertEqual((result["calls"], result["refused_missing"], result["after"]), (1, 1, {"fixed": 1}))

    def test_schedule_until_run_reads_the_follow_up_past_the_end(self) -> None:
        refused = {"until_github_run": RUN_URL.format(1)}
        self.fx.write(
            "10.jsonl",
            [
                line(self.end - 10, "masc_schedule_create", "k", "failed", NEED_DUE, refused),
                line(self.end + 100, "masc_schedule_create", "k", "completed", "{}", {"due_in_sec": 60}),
                line(self.end + 181, "masc_schedule_create", "k", "failed", NEED_DUE, refused),
            ],
        )
        result = self.run_script("schedule_until_run.py")
        self.assertEqual((result["with_until"], result["next_create"]), (1, {"completed": 1}))

    def test_github_wait_shapes_and_ts_position_read_the_window(self) -> None:
        def execute(ts: float, seconds: float) -> str:
            row = json.loads(line(ts, "Execute", "k", inp={"command": "gh run view 5"}, duration_ms=seconds * 1000))
            row.update({"trace_id": "t", "turn": 1})
            return json.dumps(row, separators=(",", ":"))

        self.fx.write("10.jsonl", [execute(self.end - 500, 100), execute(self.end - 400, 5), execute(self.end + 5, 100)])
        shapes = self.run_script("github_wait_shapes.py")
        self.assertEqual(shapes["execute"]["calls"], 2)  # type: ignore[index]
        position = self.run_script("ts_position.py")
        self.assertEqual(position["pairs"], 1)


if __name__ == "__main__":
    unittest.main()
