#!/usr/bin/env python3
"""The native tasks and the child content of the Keeper the chat pane shows
read again when the server announces a record in that journal, and again
after a failed read (RFC-0480 L8).

The refresh cadence is pushed out of the test's lifetime, so every read
after the chat opens comes from an announcement or a failed read. One case
runs the cadence every second and checks that it does not read them.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


NATIVE_HINTS = "/api/v1/keepers/analyst/native-tasks/hints"
CHILD_HINTS = "/api/v1/keepers/analyst/child-content/hints"


def native_hints() -> dict[str, object]:
    return {
        "schema": "masc.native_tasks.hints.v1",
        "historical_integrity": "unchecked",
        "hints": [],
        "keeper_name": "analyst",
        "observed_persistence_health": {
            "coverage": "issues_observed_in_this_process_only",
            "process_epoch": "process",
            "historical_failure_coverage": "unknown",
            "issues": [],
        },
        "cleanup_failures": [],
        "provider_completeness": "unknown",
        "historical_persistence_failures": "unknown",
    }


def child_hints() -> dict[str, object]:
    return {
        "schema": "masc.child_content.hints.v1",
        "persistence_failure_history": "unavailable",
        "provider_completeness": "unknown",
        "liveness": "unknown",
        "keeper_name": "analyst",
        "cleanup_failures": [],
        "hints": [],
    }


class JournalsHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(JournalsServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/health":
            with server.condition:
                server.health_reads += 1
        if request.path in (NATIVE_HINTS, CHILD_HINTS):
            phase = server.record(request.path)
            fail = False
            if request.path == NATIVE_HINTS:
                with server.condition:
                    server.native_times.append(time.monotonic())
                    fail = server.native_failures_left > 0
                    if fail:
                        server.native_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "native tasks unavailable"})
            else:
                body = native_hints() if request.path == NATIVE_HINTS else child_hints()
                sent = self.respond(200, body)
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class JournalsServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = JournalsHandler
        self.native_times: list[float] = []
        self.native_failures_left = 0
        self.health_reads = 0


def appended(kind: str, keeper: str = "analyst") -> dict[str, object]:
    return {"type": kind, "name": keeper, "ts_unix": 1.0}


NATIVE_APPENDED = "keeper_native_tasks_appended"
CHILD_APPENDED = "keeper_child_content_appended"


class ChatJournalsSignalTest(unittest.TestCase):
    binary = ""

    def run_journals(
        self,
        scenario: Callable[[JournalsServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
    ) -> None:
        owed.ChatServer = JournalsServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def chat_open(server: owed.ChatServer, step: Callable[..., None]) -> None:
            journals = cast(JournalsServer, server)
            journals.set_phase("open")
            step("keys", "c")
            step(
                "wait",
                lambda: journals.response_count("open", NATIVE_HINTS) >= 1
                and journals.response_count("open", CHILD_HINTS) >= 1,
                "opening the chat did not read its journals",
            )
            step("drain", 1.0)
            scenario(journals, step)

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), chat_open, refresh_seconds
        )

    def test_a_journal_record_reads_that_journal(self) -> None:
        def scenario(server: JournalsServer, step: Callable[..., None]) -> None:
            self.assertEqual(server.count("open", NATIVE_HINTS), 1, "opening read native twice")
            self.assertEqual(server.count("open", CHILD_HINTS), 1, "opening read child twice")
            server.set_phase("other")
            server.events.put(appended(NATIVE_APPENDED, keeper="someone-else"))
            server.events.put(appended(CHILD_APPENDED, keeper="someone-else"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 2,
                "the other Keeper's records were not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", NATIVE_HINTS), 0)
            self.assertEqual(server.count("other", CHILD_HINTS), 0)
            server.set_phase("native")
            server.events.put(appended(NATIVE_APPENDED))
            step(
                "wait",
                lambda: server.response_count("native", NATIVE_HINTS) == 1,
                "a native task record did not read the native tasks",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("native", NATIVE_HINTS), 1)
            self.assertEqual(server.count("native", CHILD_HINTS), 0)
            server.set_phase("child")
            server.events.put(appended(CHILD_APPENDED))
            step(
                "wait",
                lambda: server.response_count("child", CHILD_HINTS) == 1,
                "a child content record did not read the child content",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("child", CHILD_HINTS), 1)
            self.assertEqual(server.count("child", NATIVE_HINTS), 0)

        self.run_journals(scenario)

    def test_the_cadence_does_not_read_the_journals(self) -> None:
        def scenario(server: JournalsServer, step: Callable[..., None]) -> None:
            server.set_phase("cadence")
            with server.condition:
                health_before = server.health_reads
            step("drain", 3.5)
            with server.condition:
                cadence_passes = server.health_reads - health_before
            self.assertGreaterEqual(cadence_passes, 2, "the cadence did not run")
            self.assertEqual(server.count("cadence", NATIVE_HINTS), 0)
            self.assertEqual(server.count("cadence", CHILD_HINTS), 0)

        self.run_journals(scenario, refresh_seconds=1.0)

    def test_failed_journal_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: JournalsServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.native_failures_left = 2
                server.native_times.clear()
            server.events.put(appended(NATIVE_APPENDED))
            step(
                "wait",
                lambda: len(server.native_times) >= 3,
                "two failed reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.native_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_journals(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_chat_journals_signal.py /path/to/masc_tui.exe")
    ChatJournalsSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
