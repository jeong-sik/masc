"""Checks measure_by_profile.py on small synthetic ledgers.

Run: python3 -B -m unittest discover -s docs/evidence/tool-efficiency-by-profile-2026-11
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from datetime import date
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_by_profile as by_profile  # noqa: E402

NOON = 1793534400.0  # 2026-11-01T12:00:00Z
DAY_SECONDS = 86400.0
FIRST = date(2026, 11, 1)
LAST = date(2026, 11, 2)
SCRIPT = pathlib.Path(__file__).resolve().parent / "measure_by_profile.py"
OFFICIAL_SCRIPT = by_profile.OFFICIAL_SCRIPT
PROGRAM_TIMEOUT_SECONDS = 60
BLOB = {"_blob": "sha256:abc"}

JsonObject = dict[str, object]


def call(
    ts: float,
    keeper: str,
    profile: str | None,
    tool: str = "Read",
    input_fp: str = "in-1",
    output_fp: str = "out-1",
    size: int = 100,
    output: object = "ok",
) -> JsonObject:
    row: JsonObject = {
        "record_kind": "tool_call",
        "ts": ts,
        "keeper": keeper,
        "tool": tool,
        "trace_id": "trace",
        "keeper_turn_id": 1,
        "duration_ms": 10,
        "result_bytes": size,
        "disposition": "completed",
        "input": {"path": "a"},
        "input_fingerprint": input_fp,
        "output_fingerprint": output_fp,
        "output": output,
    }
    if profile is not None:
        row["runtime_profile"] = profile
    return row


def write_ledger(base: pathlib.Path, day: date, lines: list[str]) -> None:
    directory = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{day.day:02d}.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")


def encode(rows: list[JsonObject]) -> list[str]:
    return [json.dumps(row) for row in rows]


def run_script(script: pathlib.Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-B", str(script), *args],
        capture_output=True,
        text=True,
        timeout=PROGRAM_TIMEOUT_SECONDS,
        check=False,
    )


def by_name(result: JsonObject) -> dict[str, JsonObject]:
    return {cast(str, report["profile"]): report for report in cast(list[JsonObject], result["profiles"])}


class MeasureByProfileTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.official = by_profile.load_official()

    def measure(self, top: int = 8) -> JsonObject:
        return by_profile.measure(self.official, self.base, FIRST, LAST, self.official.default_window_sec, top)

    def write_two_profile_ledger(self) -> None:
        write_ledger(
            self.base,
            FIRST,
            encode(
                [
                    call(NOON, "k1", "p1"),
                    call(NOON + 60, "k1", "p1"),  # same keeper, tool, input and result: a re-read under p1
                    call(NOON + 120, "k1", "p2"),  # the earlier equal call was p1's; the re-read counts under p2
                    call(NOON + 180, "k2", None, tool="Grep", output=BLOB, size=500),  # no profile, spilled
                    {**call(NOON + 240, "k3", "p1"), "record_kind": "turn"},  # not a tool call
                ]
            )
            + ["this is not json"],
        )

    def test_a_repeat_counts_under_the_profile_of_the_later_call(self) -> None:
        self.write_two_profile_ledger()
        profiles = by_name(self.measure())
        self.assertEqual({"p1", "p2", "unrecorded"}, set(profiles))
        self.assertEqual(2, profiles["p1"]["calls"])
        self.assertEqual(1, cast(JsonObject, profiles["p1"]["identical_rereads"])["calls"])
        self.assertEqual(1, profiles["p2"]["calls"])
        self.assertEqual(1, cast(JsonObject, profiles["p2"]["identical_rereads"])["calls"])
        self.assertEqual(100, cast(JsonObject, profiles["p2"]["identical_rereads"])["bytes"])

    def test_a_row_without_a_profile_is_unrecorded_and_its_spill_is_counted(self) -> None:
        self.write_two_profile_ledger()
        unrecorded = by_name(self.measure())["unrecorded"]
        self.assertEqual(1, unrecorded["calls"])
        self.assertEqual(0, cast(JsonObject, unrecorded["identical_rereads"])["calls"])
        self.assertEqual(1, cast(JsonObject, unrecorded["spilled_results"])["calls"])
        self.assertEqual(500, cast(JsonObject, unrecorded["spilled_results"])["bytes"])

    def test_a_line_that_is_not_a_tool_call_belongs_to_no_profile(self) -> None:
        self.write_two_profile_ledger()
        result = self.measure()
        self.assertEqual(4, result["rows"])
        self.assertEqual(1, result["unreadable_lines"])
        self.assertEqual(
            {"p1": {"k1": 2}, "p2": {"k1": 1}, "unrecorded": {"k2": 1}},
            {name: report["keepers"] for name, report in by_name(result).items()},
        )

    def test_profiles_are_ordered_by_calls_and_top_keeps_the_busiest(self) -> None:
        rows = [call(NOON + offset, "busy", "p1", input_fp=f"in-{offset}") for offset in range(3)]
        rows += [call(NOON + 10, "quiet", "p1", tool="Grep"), call(NOON + 20, "other", "p2")]
        write_ledger(self.base, FIRST, encode(rows))
        result = self.measure(top=1)
        reports = cast(list[JsonObject], result["profiles"])
        self.assertEqual(["p1", "p2"], [report["profile"] for report in reports])
        self.assertEqual({"busy": 3}, reports[0]["keepers"])
        self.assertEqual(["Read"], [row["tool"] for row in cast(list[JsonObject], reports[0]["tools"])])

    def test_the_sum_over_profiles_equals_the_official_whole_ledger_numbers(self) -> None:
        self.write_two_profile_ledger()
        # The same call a minute before and after midnight: each day starts with no earlier call.
        write_ledger(
            self.base,
            LAST,
            encode(
                [
                    call(NOON + DAY_SECONDS, "k1", "p1"),
                    call(NOON + DAY_SECONDS + 60, "k1", "p3"),
                    call(NOON + DAY_SECONDS + 120, "k4", "p3", tool="Grep", output=BLOB, size=300),
                ]
            ),
        )
        official_out = self.base / "official.json"
        completed = run_script(
            OFFICIAL_SCRIPT,
            "--base-path",
            str(self.base),
            "--from-date",
            FIRST.isoformat(),
            "--to-date",
            LAST.isoformat(),
            "--jobs",
            "1",
            "--json-out",
            str(official_out),
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        whole = cast(JsonObject, json.loads(official_out.read_text(encoding="utf-8")))
        reports = cast(list[JsonObject], self.measure()["profiles"])

        def total(section: str, field: str) -> int:
            return sum(cast(int, cast(JsonObject, report[section])[field]) for report in reports)

        self.assertEqual(whole["rows"], sum(cast(int, report["calls"]) for report in reports))
        self.assertEqual(whole["result_bytes"], sum(cast(int, report["result_bytes"]) for report in reports))
        for section, field in (
            ("identical_rereads", "calls"),
            ("identical_rereads", "bytes"),
            ("spilled_results", "calls"),
            ("spilled_results", "bytes"),
        ):
            self.assertEqual(cast(JsonObject, whole[section])[field], total(section, field), f"{section}.{field}")
        # Two re-reads on day one, one on day two (p3 repeats p1's call), none across midnight.
        self.assertEqual(3, total("identical_rereads", "calls"))

    def test_command_line_writes_the_json_and_prints_the_table(self) -> None:
        self.write_two_profile_ledger()
        out = self.base / "out" / "result.json"
        completed = run_script(
            SCRIPT,
            "--base-path",
            str(self.base),
            "--from-date",
            FIRST.isoformat(),
            "--to-date",
            LAST.isoformat(),
            "--json-out",
            str(out),
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        written = cast(JsonObject, json.loads(out.read_text(encoding="utf-8")))
        self.assertEqual(self.measure(), written)
        self.assertIn("unrecorded", completed.stdout)

    def test_a_window_that_ends_before_it_starts_is_refused(self) -> None:
        completed = run_script(
            SCRIPT,
            "--base-path",
            str(self.base),
            "--from-date",
            LAST.isoformat(),
            "--to-date",
            FIRST.isoformat(),
        )
        self.assertEqual(2, completed.returncode)
        self.assertIn("--to-date is before --from-date", completed.stderr)


if __name__ == "__main__":
    unittest.main()
