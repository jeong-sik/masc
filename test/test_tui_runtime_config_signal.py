#!/usr/bin/env python3
"""The runtime.toml panes read the text again when the server announces a
commit while they are on screen, when a reopened feed revalidates them, and
when the [p] key arrives on one from a pane that does not draw it. The refresh
cadence does not read it (RFC-0482 L4).

The fixture serves a fixed, valid reading, so every read is one request and a
failed read never adds a retry.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


RAW_PATH = "/api/v1/runtime/config/raw"

READING: dict[str, object] = {
    "ok": True,
    "path": "/fixture/.masc/config/runtime.toml",
    "source_text": "",
    "source_revision": "fixture-revision",
    "validation": {
        "valid": True,
        "issues": [],
        "schema_version": 1,
        "current_schema_version": 1,
        "forward_schema": False,
    },
    "application": {
        "routing": {"status": "active", "requires_restart": False},
        "keeper_overlay": {
            "status": "not_configured",
            "requires_restart": False,
            "configured_count": 0,
            "pending_keys": [],
            "applied_keys": [],
            "preempted_keys": [],
        },
    },
}


class RuntimeConfigHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(RuntimeConfigServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == RAW_PATH:
            phase = server.record(request.path)
            if self.respond(200, READING, workspace_receipt=True):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class RuntimeConfigServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = RuntimeConfigHandler


def runtime_config_changed() -> dict[str, object]:
    return {"type": "runtime_config_changed", "ts_unix": 1.0}


class RuntimeConfigSignalTest(unittest.TestCase):
    binary = ""

    def run_runtime_config(
        self,
        scenario: Callable[[RuntimeConfigServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
    ) -> None:
        owed.ChatServer = RuntimeConfigServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            runtime = cast(RuntimeConfigServer, server)
            runtime.set_phase("open")
            step("keys", ":")
            step("drain", 0.3)
            step("keys", "runtime.toml")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: runtime.response_count("open", RAW_PATH) >= 1,
                "the runtime.toml pane did not read on arrival",
            )
            step("drain", 1.0)
            scenario(runtime, step)

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), opened, refresh_seconds=refresh_seconds
        )

    def test_a_commit_reads_the_text(self) -> None:
        def scenario(server: RuntimeConfigServer, step: Callable[..., None]) -> None:
            server.set_phase("quiet")
            step("drain", 2.0)
            self.assertEqual(server.count("quiet", RAW_PATH), 0)
            server.set_phase("changed")
            server.events.put(runtime_config_changed())
            step(
                "wait",
                lambda: server.response_count("changed", RAW_PATH) == 1,
                "a runtime.toml commit did not read the text",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", RAW_PATH), 1)

        self.run_runtime_config(scenario)

    def test_arriving_with_p_reads_the_text(self) -> None:
        # [p] moves between the Config panes inside one view, so the read
        # owed on arrival cannot come from the surface change. From
        # runtime.toml, [p] twice reaches params, which does not draw it, and
        # three more reach themes, which does.
        def scenario(server: RuntimeConfigServer, step: Callable[..., None]) -> None:
            step("keys", "p")
            step("drain", 0.3)
            step("keys", "p")
            step("drain", 1.0)
            server.set_phase("away")
            server.events.put(runtime_config_changed())
            step("drain", 1.5)
            self.assertEqual(server.count("away", RAW_PATH), 0)
            server.set_phase("back")
            for _ in range(3):
                step("keys", "p")
                step("drain", 0.3)
            step(
                "wait",
                lambda: server.response_count("back", RAW_PATH) >= 1,
                "arriving on themes with [p] did not read runtime.toml",
            )

        self.run_runtime_config(scenario)

    def test_a_reopened_feed_reads_the_text_again(self) -> None:
        # A commit while the feed was closed reached nobody; the revalidation
        # that follows the reopen reads the text.
        def scenario(server: RuntimeConfigServer, step: Callable[..., None]) -> None:
            server.set_phase("reopen")
            server.events.put("close")
            step(
                "wait",
                lambda: server.observer_connections >= 2,
                "the observer feed did not reconnect",
            )
            step(
                "wait",
                lambda: server.response_count("reopen", RAW_PATH) >= 1,
                "the reopened feed did not read runtime.toml again",
            )

        self.run_runtime_config(scenario)

    def test_the_cadence_does_not_read_the_text(self) -> None:
        def scenario(server: RuntimeConfigServer, step: Callable[..., None]) -> None:
            server.set_phase("cadence")
            step(
                "wait",
                lambda: server.response_count("cadence", "/health") >= 2,
                "the cadence did not run",
            )
            self.assertEqual(server.count("cadence", RAW_PATH), 0)

        self.run_runtime_config(scenario, refresh_seconds=1.0)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_runtime_config_signal.py /path/to/masc_tui.exe")
    RuntimeConfigSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
