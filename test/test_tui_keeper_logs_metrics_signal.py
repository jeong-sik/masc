#!/usr/bin/env python3
"""The logs view reads its Keeper's metrics again when the server announces a
row appended to that Keeper's metrics file (RFC-0480 L8).

The first test pushes the refresh cadence out of its lifetime, so every
metrics read after the view opens comes from an announcement, and the
second sees a quiet stretch read nothing more. The metrics file is read
from the local workspace, so the reads are counted in the TUI's own log.
"""

import glob
import json
import os
import sys
import unittest
from typing import Callable, cast

import test_tui_chat_owed_history as owed


LOG_PREFIX = "tui_keeper_logs="


def metrics_appended(keeper: str) -> dict[str, object]:
    return {"type": "keeper_metrics_appended", "name": keeper, "ts_unix": 1.0}


def in_turn_heartbeat(keeper: str) -> dict[str, object]:
    # The in-turn liveness pulse: same type as the heartbeat snapshot, but it
    # writes no metrics row.
    return {
        "type": "keeper_heartbeat",
        "name": keeper,
        "ts_unix": 1.0,
        "phase": "turn_running",
        "in_turn": True,
    }


def started_reads(base: str, keeper: str) -> int:
    count = 0
    for path in glob.glob(os.path.join(base, ".masc", "logs", "masc-tui-*.log")):
        with open(path, encoding="utf-8", errors="replace") as log:
            for line in log:
                at = line.find(LOG_PREFIX)
                if at < 0:
                    continue
                try:
                    fields = json.loads(line[at + len(LOG_PREFIX):].strip())
                except json.JSONDecodeError:
                    continue
                if fields.get("phase") == "started" and fields.get("keeper") == keeper:
                    count += 1
    return count


class KeeperLogsMetricsSignalTest(unittest.TestCase):
    binary = ""

    def test_only_an_append_for_the_shown_keeper_is_read(self) -> None:
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            base = server.base
            step("keys", "l")
            step(
                "wait",
                lambda: started_reads(base, "analyst") >= 1,
                "the logs view did not read its Keeper's metrics",
            )
            step("drain", 1.5)
            opened = started_reads(base, "analyst")

            server.set_phase("other")
            server.events.put(metrics_appended("someone-else"))
            server.events.put(in_turn_heartbeat("analyst"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 2,
                "the other Keeper's append and the pulse were not sent",
            )
            step("drain", 1.5)
            self.assertEqual(started_reads(base, "analyst"), opened)

            server.set_phase("appended")
            server.events.put(metrics_appended("analyst"))
            step(
                "wait",
                lambda: started_reads(base, "analyst") == opened + 1,
                "the shown Keeper's append did not cause a metrics read",
            )
            step("drain", 1.5)
            self.assertEqual(started_reads(base, "analyst"), opened + 1)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)

    def test_a_quiet_stretch_does_not_read_the_metrics(self) -> None:
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            base = server.base
            step("keys", "l")
            step(
                "wait",
                lambda: started_reads(base, "analyst") >= 1,
                "the logs view did not read its Keeper's metrics",
            )
            step("drain", 1.0)
            opened = started_reads(base, "analyst")
            server.set_phase("quiet")
            step("drain", 3.5)
            self.assertEqual(started_reads(base, "analyst"), opened)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_keeper_logs_metrics_signal.py /path/to/masc_tui.exe")
    KeeperLogsMetricsSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
