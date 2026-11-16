# pyright: strict, reportMissingTypeStubs=false
"""Checks measure_stated_reset_refusals.py on small synthetic logs.

Run: python3 -m unittest discover -s docs/evidence/stated-reset-refusals-2026-11
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

import measure_stated_reset_refusals as measure  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parents[3]
ROW = "claude_code_0a1b2c"
OTHER_ROW = "claude_code_d4e5f6"
RELEASE = 1794823200
HARD_QUOTA_ERROR = "Provider 'claude_code' hard quota exhausted: quota blocked"


def line(ts: str, message: str, keeper: str | None = None) -> dict[str, object]:
    record: dict[str, object] = {"ts": ts, "message": message}
    if keeper is not None:
        record["keeper_name"] = keeper
    return record


def boot(ts: str) -> dict[str, object]:
    return line(ts, "[Startup] retained checkpoint sweep: removed=0 bytes=0 live_references=0 failures=0")


def started(ts: str, keeper: str) -> dict[str, object]:
    return line(ts, f"agent started agent={keeper} task_id=t", keeper)


def composed(ts: str, keeper: str) -> dict[str, object]:
    return line(ts, "Claude Code turn composition: mode=resume prompt_bytes=1", keeper)


def turn_ended(ts: str, keeper: str) -> dict[str, object]:
    return line(ts, f"{keeper}: keeper cycle rested until={RELEASE} waiting_on={ROW}.m runtime={ROW}.m lane=l", keeper)


def succeeded(ts: str, keeper: str) -> dict[str, object]:
    return line(ts, f"{keeper}: keeper cycle OK runtime_lane={ROW}.m tokens=1 latency=1ms mode=m stop=s", keeper)


def terminal(ts: str, keeper: str, error: str = HARD_QUOTA_ERROR) -> dict[str, object]:
    return line(ts, f"{keeper}: turn terminal (non-exhaustion error) — err={error} runtime={ROW}.m", keeper)


def waits(ts: str, keeper: str, row: str = ROW, release: int = RELEASE) -> dict[str, object]:
    message = f"{keeper}: the next dispatch waits 600s for {row}.model to be released at {release}; the walk head is resting"
    return line(ts, message, keeper)


def refused(ts: str, keeper: str, row: str = ROW, release: int = RELEASE) -> list[dict[str, object]]:
    """The lines a refused turn ends with: its terminal error, its turn end and
    the heartbeat's wait. The caller writes the turn's dispatch mark."""
    return [terminal(ts, keeper), turn_ended(ts, keeper), waits(ts, keeper, row, release)]


def write_log(directory: str, records: list[dict[str, object]]) -> pathlib.Path:
    path = pathlib.Path(directory) / "system_log_2026-11-15.jsonl"
    path.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
    return path


def run(records: list[dict[str, object]]) -> dict[str, object]:
    with tempfile.TemporaryDirectory() as directory:
        return measure.measure(measure.read_events([write_log(directory, records)]))


def mark(result: dict[str, object], name: str = "composition") -> dict[str, object]:
    return cast(dict[str, dict[str, object]], result["dispatch_mark"])[name]


def verdicts(result: dict[str, object], name: str = "composition") -> dict[str, int]:
    return cast(dict[str, int], mark(result, name)["verdicts"])


class EventParsing(unittest.TestCase):
    def test_sweep_failure_line_is_not_a_boot(self) -> None:
        failure = line("2026-11-15T00:00:01Z", "[Startup] retained checkpoint sweep: unreadable checkpoint x")
        self.assertIsNone(measure.event_of_record(failure))
        for message in (
            "[Startup] retained checkpoint sweep: removed=1 bytes=2 live_references=3 failures=0",
            "[Startup] retained checkpoint sweep raised: Not_found",
            "[Startup] retained checkpoint sweep skipped: no root",
        ):
            event = measure.event_of_record(line("2026-11-15T00:00:00Z", message))
            assert event is not None
            self.assertEqual(event.kind, "restart")

    def test_wait_names_the_provider_row_of_the_runtime(self) -> None:
        event = measure.event_of_record(waits("2026-11-15T00:00:00Z", "k"))
        assert event is not None
        self.assertEqual((event.kind, event.provider_row, event.release), ("wait", ROW, RELEASE))

    def test_the_provider_comes_from_the_error_text(self) -> None:
        event = measure.event_of_record(terminal("2026-11-15T00:00:00Z", "k"))
        assert event is not None
        self.assertEqual((event.kind, event.provider), ("terminal", "claude_code"))

    def test_every_turn_end_is_read_and_the_heartbeat_rest_line_is_not(self) -> None:
        for record in (turn_ended("2026-11-15T00:00:00Z", "k"), succeeded("2026-11-15T00:00:00Z", "k")):
            event = measure.event_of_record(record)
            assert event is not None
            self.assertEqual(event.kind, "turn_end")
        failed = line("2026-11-15T00:00:00Z", f"k: keeper cycle FAILED runtime={ROW}.m lane=l error_origin=o", "k")
        event = measure.event_of_record(failed)
        assert event is not None
        self.assertEqual(event.kind, "turn_end")


class Verdicts(unittest.TestCase):
    def test_second_keeper_on_the_same_row_was_known(self) -> None:
        records = [
            boot("2026-11-15T00:00:00Z"),
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            started("2026-11-15T01:00:30Z", "b"),
            *refused("2026-11-15T01:00:35Z", "b"),
        ]
        self.assertEqual(verdicts(run(records)), {"first": 1, "known_from_another_keeper": 1})

    def test_a_later_noted_release_still_holds_an_earlier_one(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a", release=RELEASE + 3600),
            started("2026-11-15T01:00:30Z", "b"),
            *refused("2026-11-15T01:00:35Z", "b"),
        ]
        self.assertEqual(verdicts(run(records)), {"first": 1, "known_from_another_keeper": 1})

    def test_an_earlier_noted_release_does_not_hold_a_later_one(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a", release=RELEASE - 3600),
            started("2026-11-15T01:00:30Z", "b"),
            *refused("2026-11-15T01:00:35Z", "b"),
        ]
        self.assertEqual(verdicts(run(records)), {"first": 2})

    def test_another_row_is_not_known(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a", row=OTHER_ROW),
            started("2026-11-15T01:00:30Z", "b"),
            *refused("2026-11-15T01:00:35Z", "b"),
        ]
        self.assertEqual(verdicts(run(records)), {"first": 2})

    def test_a_restart_in_between_forgets(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            boot("2026-11-15T01:00:10Z"),
            started("2026-11-15T01:00:30Z", "b"),
            *refused("2026-11-15T01:00:35Z", "b"),
        ]
        self.assertEqual(verdicts(run(records)), {"first": 1, "known_before_restart": 1})

    def test_its_own_earlier_refusal_is_told_apart(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            started("2026-11-15T01:00:30Z", "a"),
            *refused("2026-11-15T01:00:35Z", "a"),
        ]
        self.assertEqual(verdicts(run(records)), {"first": 1, "known_from_itself": 1})

    def test_another_keeper_wins_over_itself(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            started("2026-11-15T01:00:10Z", "b"),
            *refused("2026-11-15T01:00:15Z", "b"),
            started("2026-11-15T01:00:30Z", "a"),
            *refused("2026-11-15T01:00:35Z", "a"),
        ]
        self.assertEqual(verdicts(run(records)), {"first": 1, "known_from_another_keeper": 2})

    def test_this_process_wins_over_an_earlier_one(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            boot("2026-11-15T01:00:10Z"),
            started("2026-11-15T01:00:20Z", "b"),
            *refused("2026-11-15T01:00:25Z", "b"),
            started("2026-11-15T01:00:30Z", "c"),
            *refused("2026-11-15T01:00:35Z", "c"),
        ]
        self.assertEqual(
            verdicts(run(records)), {"first": 1, "known_before_restart": 1, "known_from_another_keeper": 1}
        )

    def test_a_turn_that_did_not_end_on_a_hard_quota_is_not_counted(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            terminal("2026-11-15T01:00:05Z", "a", error="Provider 'claude_code' rate limited"),
            turn_ended("2026-11-15T01:00:05Z", "a"),
            waits("2026-11-15T01:00:05Z", "a"),
        ]
        self.assertEqual(verdicts(run(records)), {})

    def test_an_earlier_turns_hard_quota_does_not_pair_with_a_later_wait(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            started("2026-11-15T01:00:30Z", "a"),
            turn_ended("2026-11-15T01:00:35Z", "a"),
            waits("2026-11-15T01:00:35Z", "a"),
        ]
        self.assertEqual(sum(verdicts(run(records)).values()), 1)

    def test_a_turn_without_its_own_mark_is_not_judged(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "b"),
            succeeded("2026-11-15T01:00:01Z", "b"),
            started("2026-11-15T01:00:02Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            *refused("2026-11-15T01:00:35Z", "b"),
        ]
        self.assertEqual(verdicts(run(records)), {"first": 1, "no_dispatch_mark": 1})

    def test_the_composition_mark_counts_a_note_between_start_and_send(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "b"),
            started("2026-11-15T01:00:01Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            composed("2026-11-15T01:00:20Z", "b"),
            *refused("2026-11-15T01:00:25Z", "b"),
        ]
        result = run(records)
        self.assertEqual(verdicts(result, "composition"), {"first": 1, "known_from_another_keeper": 1})
        self.assertEqual(verdicts(result, "start"), {"first": 2})

    def test_the_cutoff_drops_lines_at_or_after_it(self) -> None:
        records = [
            started("2026-11-15T01:00:00Z", "a"),
            *refused("2026-11-15T01:00:05Z", "a"),
            started("2026-11-15T01:00:30Z", "b"),
            *refused("2026-11-15T01:00:35Z", "b"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = write_log(directory, records)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                measure.main(["--until", "2026-11-15T01:00:35Z", str(path)])
        result = cast(dict[str, object], json.loads(output.getvalue()))
        self.assertEqual(verdicts(result), {"first": 1})


class SourceFormats(unittest.TestCase):
    """The lines this script parses are written by these source lines."""

    def test_the_parsed_formats_are_still_written(self) -> None:
        expected = {
            "lib/keeper/keeper_heartbeat_loop.ml": "the next dispatch waits %.0fs for %s to be released at %.0f",
            "lib/keeper/keeper_unified_turn_terminal_error.ml": "turn terminal (non-exhaustion error) — err=%s runtime=%s",
            "lib/keeper/keeper_event_bridge.ml": "agent started agent=%s",
            "lib/keeper/keeper_claude_code_runtime.ml": "turn composition:",
            "lib/keeper/keeper_unified_turn.ml": '"rested until=%.0f waiting_on=%s"',
            "lib/keeper/keeper_unified_turn_success.ml": '"%s: keeper cycle %s runtime_lane=%s',
            "packages/agent_core/lib/llm_provider/error.ml": "\"Provider '%s' hard quota exhausted: %s%s\"",
            "bin/main_eio.ml": "[Startup] retained checkpoint sweep: removed=%d",
        }
        for relative, fragment in expected.items():
            with self.subTest(file=relative):
                self.assertIn(fragment, (REPO / relative).read_text(encoding="utf-8"))
        unified = (REPO / "lib/keeper/keeper_unified_turn.ml").read_text(encoding="utf-8")
        self.assertIn('"%s: keeper cycle %s runtime=%s lane=%s', unified)


if __name__ == "__main__":
    unittest.main()
