"""Checks the counting of measure_artifact_read_misses.py on small synthetic ledgers.

Run: python3 -m unittest discover -s docs/evidence/artifact-read-misses-2026-11
"""

from __future__ import annotations

import contextlib
import datetime
import io
import json
import pathlib
import sys
import tempfile
import unittest
import unittest.mock
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_artifact_read_misses as misses  # noqa: E402

UTC = datetime.timezone.utc
MISS_OUTPUT = '{"ok":false,"error":"invalid_artifact_read","message":"artifact does not exist"} failure_class=policy_rejection'
FAILED_OUTPUT = '{"ok":false,"error":"invalid_artifact_read","message":"offset 9 exceeds artifact size 3"}'
OK_OUTPUT = '{"ok":true,"data":{"content":"x","eof":true}}'
HASH_A = "a" * 64
HASH_B = "b" * 64
HASH_C = "c" * 64


def at(day: int, hour: int = 0, minute: int = 0, second: float = 0.0) -> float:
    return datetime.datetime(2026, 11, day, hour, minute, tzinfo=UTC).timestamp() + second


def row(
    stamp: float,
    keeper: str,
    sha256: str | None,
    output: str,
    *,
    tool: str = misses.TOOL,
    kind: str = misses.RECORD_KIND,
) -> str:
    given: dict[str, object] = {} if sha256 is None else {"sha256": sha256}
    return json.dumps(
        {"ts": stamp, "record_kind": kind, "keeper": keeper, "tool": tool, "input": given, "output": output}
    )


class Ledger:
    """A temporary base path with ledger files written under `.masc/tool_calls/2026-11`."""

    def __init__(self, test: unittest.TestCase) -> None:
        holder = tempfile.TemporaryDirectory()
        test.addCleanup(holder.cleanup)
        self.base = pathlib.Path(holder.name)
        self.folder = self.base / ".masc" / "tool_calls" / "2026-11"
        self.folder.mkdir(parents=True)

    def write(self, name: str, lines: list[str]) -> None:
        (self.folder / name).write_text("\n".join(lines) + "\n", encoding="utf-8")

    def trace(self, keeper: str, text: str) -> None:
        folder = self.base / ".masc" / "keepers" / keeper / "raw-traces"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "turn-1.jsonl").write_text(text, encoding="utf-8")

    def run(self, first: int = 6, last: int | None = None, **options: str) -> dict[str, object]:
        out = self.base / "out.json"
        argv = [
            "--base-path",
            str(self.base),
            "--from-date",
            f"2026-11-{first:02d}",
            "--to-date",
            f"2026-11-{(first if last is None else last):02d}",
            "--json-out",
            str(out),
        ]
        for name, value in options.items():
            argv += [f"--{name.replace('_', '-')}", value]
        self_status = misses.main(argv)
        assert self_status == 0
        return cast("dict[str, object]", json.loads(out.read_text(encoding="utf-8")))


def section(result: dict[str, object], name: str) -> dict[str, object]:
    return cast("dict[str, object]", result[name])


class CountTests(unittest.TestCase):
    def test_counts_reads_misses_and_their_share(self) -> None:
        ledger = Ledger(self)
        ledger.write(
            "06.jsonl",
            [
                row(at(6, 1), "k", HASH_A, OK_OUTPUT),
                row(at(6, 2), "k", HASH_B, FAILED_OUTPUT),
                row(at(6, 3), "k", HASH_C, MISS_OUTPUT),
                row(at(6, 4), "k", HASH_C, MISS_OUTPUT),
            ],
        )
        reads = section(ledger.run(), "reads")
        self.assertEqual((reads["total"], reads["missing"], reads["missing_share"]), (4, 2, 0.5))

    def test_other_tools_and_other_record_kinds_are_not_reads(self) -> None:
        ledger = Ledger(self)
        ledger.write(
            "06.jsonl",
            [
                # Both lines name the tool in their text, so only the field checks keep them out.
                row(at(6, 1), "k", HASH_A, MISS_OUTPUT + " keeper_artifact_read", tool="Execute"),
                row(at(6, 2), "k", HASH_A, MISS_OUTPUT, kind="tool_result"),
                row(at(6, 3), "k", HASH_A, OK_OUTPUT),
            ],
        )
        self.assertEqual(section(ledger.run(), "reads")["total"], 1)

    def test_every_segment_file_of_the_day_is_read_and_other_names_are_not(self) -> None:
        ledger = Ledger(self)
        for name in ("06.jsonl", "06.001.jsonl", "06.002.jsonl"):
            ledger.write(name, [row(at(6, 1), "k", HASH_A, OK_OUTPUT)])
        for name in ("07.jsonl", "060.jsonl", "06.abc.jsonl", "06.jsonl.lock"):
            ledger.write(name, [row(at(6, 2), "k", HASH_A, OK_OUTPUT)])
        result = ledger.run()
        self.assertEqual(section(result, "reads")["total"], 3)
        self.assertEqual(section(result, "files")["ledger"], 3)

    def test_since_is_inclusive_and_until_is_exclusive(self) -> None:
        ledger = Ledger(self)
        ledger.write(
            "06.jsonl",
            [
                row(at(6, 10) - 1, "k", HASH_A, OK_OUTPUT),
                row(at(6, 10), "k", HASH_A, OK_OUTPUT),
                row(at(6, 11) - 1, "k", HASH_A, OK_OUTPUT),
                row(at(6, 11), "k", HASH_A, OK_OUTPUT),
            ],
        )
        result = ledger.run(since="2026-11-06T10:00:00", until="2026-11-06T11:00:00")
        self.assertEqual(section(result, "reads")["total"], 2)

    def test_a_day_is_the_utc_date_of_the_timestamp(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(7) - 1, "k", HASH_A, OK_OUTPUT)])
        ledger.write("07.jsonl", [row(at(7), "k", HASH_A, MISS_OUTPUT)])
        by_day = cast("dict[str, dict[str, int]]", section(ledger.run(6, 7), "reads")["by_day"])
        self.assertEqual(by_day["2026-11-06"], {"reads": 1, "missing": 0, "traced": 0})
        self.assertEqual(by_day["2026-11-07"], {"reads": 1, "missing": 1, "traced": 0})

    def test_days_without_a_file_are_listed(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", HASH_A, OK_OUTPUT)])
        files = section(ledger.run(6, 8), "files")
        self.assertEqual(files["days_without_file"], ["2026-11-07", "2026-11-08"])

    def test_a_month_without_a_folder_lists_its_days(self) -> None:
        ledger = Ledger(self)
        out = ledger.base / "out.json"
        status = misses.main(
            ["--base-path", str(ledger.base), "--from-date", "2026-12-01", "--to-date", "2026-12-02", "--json-out", str(out)]
        )
        self.assertEqual(status, 0)
        result = cast("dict[str, object]", json.loads(out.read_text(encoding="utf-8")))
        self.assertEqual(section(result, "files")["days_without_file"], ["2026-12-01", "2026-12-02"])

    def test_bad_lines_and_bad_outputs_are_counted_and_left_out(self) -> None:
        ledger = Ledger(self)
        broken = {
            "ts": "late",
            "record_kind": misses.RECORD_KIND,
            "keeper": "k",
            "tool": misses.TOOL,
            "input": {},
            "output": OK_OUTPUT,
        }
        object_output = {**broken, "ts": at(6, 1), "output": {"ok": False}}
        flagged_ts = {**broken, "ts": True}
        ledger.write(
            "06.jsonl",
            [
                "{not json " + misses.TOOL,
                "[1, 2] " + misses.TOOL,
                json.dumps(broken),
                json.dumps(flagged_ts),
                json.dumps(object_output),
                row(at(6, 2), "k", HASH_A, OK_OUTPUT),
            ],
        )
        result = ledger.run()
        self.assertEqual(section(result, "skipped"), {"bad_lines": 4, "bad_outputs": 1})
        self.assertEqual(section(result, "reads")["total"], 1)

    def test_a_miss_without_an_input_hash_counts_as_a_call_but_not_as_a_hash(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", None, MISS_OUTPUT)])
        result = ledger.run()
        self.assertEqual(section(result, "reads")["missing"], 1)
        self.assertEqual(section(result, "missed_hashes")["distinct"], 0)
        self.assertEqual(section(result, "missed_calls"), {"traced_to_answer_sha256": 0, "not_traced": 1})

    def test_a_hash_that_is_not_64_lower_case_hex_is_not_a_hash(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", "A" * 64, MISS_OUTPUT), row(at(6, 2), "k", "abc", MISS_OUTPUT)])
        self.assertEqual(section(ledger.run(), "missed_hashes")["distinct"], 0)

    def test_keepers_are_ranked_by_misses_then_reads(self) -> None:
        ledger = Ledger(self)
        ledger.write(
            "06.jsonl",
            [
                row(at(6, 1), "quiet", HASH_A, OK_OUTPUT),
                row(at(6, 2), "one-miss", HASH_A, MISS_OUTPUT),
                row(at(6, 3), "two-miss", HASH_A, MISS_OUTPUT),
                row(at(6, 4), "two-miss", HASH_B, MISS_OUTPUT),
                row(at(6, 5), "one-miss-busy", HASH_A, MISS_OUTPUT),
                row(at(6, 6), "one-miss-busy", HASH_B, OK_OUTPUT),
                *[row(at(6, 7 + index), "busy-clean", HASH_A, OK_OUTPUT) for index in range(3)],
            ],
        )
        ranked = cast("list[dict[str, object]]", ledger.run(top="3")["by_keeper"])
        self.assertEqual([item["keeper"] for item in ranked], ["two-miss", "one-miss-busy", "one-miss"])


class FollowUpTests(unittest.TestCase):
    def after(self, ledger: Ledger) -> dict[str, object]:
        return section(ledger.run(), "after_a_miss")

    def test_each_class_is_counted_for_its_own_keeper(self) -> None:
        ledger = Ledger(self)
        ledger.write(
            "06.jsonl",
            [
                row(at(6, 1), "other-hash", HASH_A, MISS_OUTPUT),
                row(at(6, 1, 0, 4.5), "other-hash", HASH_B, OK_OUTPUT),
                row(at(6, 2), "same-hash", HASH_A, MISS_OUTPUT),
                row(at(6, 2, 0, 3), "same-hash", HASH_A, OK_OUTPUT),
                row(at(6, 3), "again", HASH_A, MISS_OUTPUT),
                row(at(6, 3, 0, 3), "again", HASH_B, MISS_OUTPUT),
                row(at(6, 4), "otherwise", HASH_A, MISS_OUTPUT),
                row(at(6, 4, 0, 3), "otherwise", HASH_B, FAILED_OUTPUT),
                row(at(6, 5), "alone", HASH_A, MISS_OUTPUT),
            ],
        )
        after = self.after(ledger)
        self.assertEqual(
            {name: after[name] for name in misses.FOLLOW_CLASSES},
            {
                "read_other_hash": 1,
                "read_same_hash": 1,
                "missed_again": 1,
                "failed_otherwise": 1,
                # the second miss of `again` has no next read, and neither has `alone`
                "no_next_read": 2,
            },
        )

    def test_the_next_read_must_come_within_the_window_inclusive(self) -> None:
        ledger = Ledger(self)
        ledger.write(
            "06.jsonl",
            [
                row(at(6, 1), "edge", HASH_A, MISS_OUTPUT),
                row(at(6, 1, 0, 600.0), "edge", HASH_B, OK_OUTPUT),
                row(at(6, 3), "late", HASH_A, MISS_OUTPUT),
                row(at(6, 3, 0, 600.5), "late", HASH_B, OK_OUTPUT),
            ],
        )
        after = self.after(ledger)
        self.assertEqual((after["read_other_hash"], after["no_next_read"]), (1, 1))

    def test_a_read_by_another_keeper_is_not_the_next_read(self) -> None:
        ledger = Ledger(self)
        ledger.write(
            "06.jsonl",
            [
                row(at(6, 1), "a", HASH_A, MISS_OUTPUT),
                row(at(6, 1, 0, 1), "b", HASH_B, OK_OUTPUT),
                row(at(6, 1, 0, 700), "a", HASH_B, OK_OUTPUT),
            ],
        )
        after = self.after(ledger)
        self.assertEqual((after["read_other_hash"], after["no_next_read"]), (0, 1))

    def test_lines_are_ordered_by_timestamp_not_by_file_order(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1, 0, 2), "k", HASH_B, OK_OUTPUT)])
        ledger.write("06.001.jsonl", [row(at(6, 1), "k", HASH_A, MISS_OUTPUT)])
        self.assertEqual(self.after(ledger)["read_other_hash"], 1)

    def test_recovery_seconds_use_the_rank_not_an_average(self) -> None:
        ledger = Ledger(self)
        lines: list[str] = []
        for index, gap in enumerate((1.0, 2.0, 10.0)):
            keeper = f"k{index}"
            lines += [
                row(at(6, 1), keeper, HASH_A, MISS_OUTPUT),
                row(at(6, 1, 0, gap), keeper, HASH_B, OK_OUTPUT),
            ]
        ledger.write("06.jsonl", lines)
        self.assertEqual(self.after(ledger)["read_other_hash_seconds"], {"p50": 2.0, "p90": 10.0})

    def test_a_follow_window_of_zero_or_less_is_refused(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", HASH_A, OK_OUTPUT)])
        for value in ("0", "-5"):
            with self.subTest(value=value), self.assertRaises(SystemExit) as raised:
                with contextlib.redirect_stderr(io.StringIO()):
                    ledger.run(follow_seconds=value)
            self.assertEqual(raised.exception.code, 2)


class TraceTests(unittest.TestCase):
    def test_a_missed_hash_that_is_an_answer_fingerprint_is_traced(self) -> None:
        ledger = Ledger(self)
        ledger.write(
            "06.jsonl",
            [
                row(at(6, 1), "k", HASH_A, MISS_OUTPUT),
                row(at(6, 2), "k", HASH_A, MISS_OUTPUT),
                row(at(6, 3), "k", HASH_B, MISS_OUTPUT),
            ],
        )
        # HASH_A follows `answer_sha256=`; HASH_B is only the input of a read.
        ledger.trace(
            "k",
            f'[masc:blob sha256={HASH_C} bytes=9 mime=m answer_sha256={HASH_A} preview=""]\n'
            f'{{"tool_input":{{"sha256":"{HASH_B}"}}}}\n',
        )
        result = ledger.run()
        self.assertEqual(section(result, "missed_calls"), {"traced_to_answer_sha256": 2, "not_traced": 1})
        self.assertEqual(
            section(result, "missed_hashes"), {"distinct": 2, "traced_to_answer_sha256": 1, "not_traced": 1}
        )
        self.assertEqual(section(result, "files")["raw_traces"], 1)

    def test_the_artifact_hash_of_a_marker_is_not_an_answer_fingerprint(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", HASH_C, MISS_OUTPUT)])
        ledger.trace("k", f'[masc:blob sha256={HASH_C} bytes=9 mime=m answer_sha256={HASH_A} preview=""]\n')
        self.assertEqual(section(ledger.run(), "missed_hashes")["traced_to_answer_sha256"], 0)

    def test_a_fingerprint_in_the_trace_of_another_keeper_still_counts(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "reader", HASH_A, MISS_OUTPUT)])
        ledger.trace("writer", f"answer_sha256={HASH_A}\n")
        self.assertEqual(section(ledger.run(), "missed_hashes")["traced_to_answer_sha256"], 1)

    def test_without_a_raw_trace_folder_every_miss_is_not_traced(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", HASH_A, MISS_OUTPUT)])
        result = ledger.run()
        self.assertEqual(section(result, "files")["raw_traces"], 0)
        self.assertEqual(section(result, "missed_calls"), {"traced_to_answer_sha256": 0, "not_traced": 1})

    def test_a_trace_file_deleted_after_the_listing_is_counted_and_the_run_goes_on(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", HASH_A, MISS_OUTPUT)])
        ledger.trace("k", f"answer_sha256={HASH_A}\n")
        listed = sorted((ledger.base / ".masc" / "keepers").glob("*/raw-traces/*.jsonl"))
        gone = ledger.base / ".masc" / "keepers" / "k" / "raw-traces" / "turn-gone.jsonl"
        with unittest.mock.patch.object(misses, "raw_trace_paths", lambda _base: iter([gone, *listed])):
            result = ledger.run()
        files = section(result, "files")
        self.assertEqual((files["raw_traces"], files["raw_traces_vanished"]), (1, 1))
        self.assertEqual(section(result, "missed_calls"), {"traced_to_answer_sha256": 1, "not_traced": 0})

    def test_by_day_counts_the_traced_misses_of_that_day(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", HASH_A, MISS_OUTPUT), row(at(6, 2), "k", HASH_B, MISS_OUTPUT)])
        ledger.trace("k", f"answer_sha256={HASH_A}\n")
        by_day = cast("dict[str, dict[str, int]]", section(ledger.run(), "reads")["by_day"])
        self.assertEqual(by_day["2026-11-06"], {"reads": 2, "missing": 2, "traced": 1})


class ArgumentTests(unittest.TestCase):
    def refused(self, *argv: str) -> str:
        buffer = io.StringIO()
        with contextlib.redirect_stderr(buffer), self.assertRaises(SystemExit) as raised:
            misses.main(["--base-path", "/nonexistent", *argv])
        self.assertEqual(raised.exception.code, 2)
        return buffer.getvalue()

    def test_dates_are_checked(self) -> None:
        self.assertIn("YYYY-MM-DD", self.refused("--from-date", "11-06", "--to-date", "2026-11-06"))
        self.assertIn("before", self.refused("--from-date", "2026-11-07", "--to-date", "2026-11-06"))
        self.assertIn("must be before", self.refused("--from-date", "2026-11-06", "--to-date", "9999-12-31"))
        self.assertIn("longer than", self.refused("--from-date", "2025-01-01", "--to-date", "2026-11-06"))

    def test_instants_are_checked(self) -> None:
        text = self.refused("--from-date", "2026-11-06", "--to-date", "2026-11-06", "--since", "yesterday")
        self.assertIn("YYYY-MM-DDTHH:MM:SS", text)

    def test_without_json_out_the_result_goes_to_stdout(self) -> None:
        ledger = Ledger(self)
        ledger.write("06.jsonl", [row(at(6, 1), "k", HASH_A, OK_OUTPUT)])
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = misses.main(["--base-path", str(ledger.base), "--from-date", "2026-11-06", "--to-date", "2026-11-06"])
        self.assertEqual(status, 0)
        printed = cast("dict[str, object]", json.loads(buffer.getvalue()))
        self.assertEqual(section(printed, "reads")["total"], 1)


if __name__ == "__main__":
    unittest.main()
