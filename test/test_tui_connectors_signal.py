#!/usr/bin/env python3
"""The Connectors list reads again when the server announces a connector
change while it is on screen, and the refresh cadence does not read it
(RFC-0480).

The fixture serves an empty connector list, so a read is one request and no
name pages follow.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


CONNECTORS_PATH = "/api/v1/gate/connectors"


class ConnectorsHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(ConnectorsServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == CONNECTORS_PATH:
            phase = server.record(request.path)
            body = {"connectors": [], "total": 0, "active_count": 0}
            if self.respond(200, body, workspace_receipt=True):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class ConnectorsServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = ConnectorsHandler


def connector_changed(connector: str) -> dict[str, object]:
    return {"type": "gate_connector_changed", "connector": connector, "ts_unix": 1.0}


class ConnectorsSignalTest(unittest.TestCase):
    binary = ""

    def run_connectors(
        self,
        scenario: Callable[[ConnectorsServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
    ) -> None:
        owed.ChatServer = ConnectorsServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            connectors = cast(ConnectorsServer, server)
            connectors.set_phase("open")
            step("keys", ":")
            step("drain", 0.3)
            step("keys", "connectors")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: connectors.response_count("open", CONNECTORS_PATH) >= 1,
                "the Connectors list did not read on arrival",
            )
            step("drain", 1.0)
            scenario(connectors, step)

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), opened, refresh_seconds=refresh_seconds
        )

    def test_a_connector_change_reads_the_list(self) -> None:
        def scenario(server: ConnectorsServer, step: Callable[..., None]) -> None:
            server.set_phase("quiet")
            step("drain", 2.0)
            self.assertEqual(server.count("quiet", CONNECTORS_PATH), 0)
            server.set_phase("changed")
            server.events.put(connector_changed("slack"))
            step(
                "wait",
                lambda: server.response_count("changed", CONNECTORS_PATH) == 1,
                "a connector change did not read the list",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", CONNECTORS_PATH), 1)

        self.run_connectors(scenario)

    def test_the_cadence_does_not_read_the_list(self) -> None:
        def scenario(server: ConnectorsServer, step: Callable[..., None]) -> None:
            server.set_phase("cadence")
            step(
                "wait",
                lambda: server.response_count("cadence", "/health") >= 2,
                "the cadence did not run",
            )
            self.assertEqual(server.count("cadence", CONNECTORS_PATH), 0)

        self.run_connectors(scenario, refresh_seconds=1.0)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_connectors_signal.py /path/to/masc_tui.exe")
    ConnectorsSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
