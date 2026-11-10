#!/usr/bin/env python3
"""Usage's transport health reads again when the server's transport refresh
loop pushes a new measurement, and again after a failed read (RFC-0480 §3.4).

The refresh cadence is pushed out of the test's lifetime, so every transport
read after Usage opens comes from a push or a failed read.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


TRANSPORT_PATH = "/api/v1/dashboard/transport-health"


def transport_health() -> dict[str, object]:
    return {
        "summary": {"primary_path": "sse", "queue_pressure": "steady"},
        "sse": {"sessions_total": 1},
        "websocket": {"listening": False},
        "grpc": {"listening": False, "events_dropped": 0},
    }


class TransportHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(TransportServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == TRANSPORT_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.read_times.append(time.monotonic())
                fail = server.failures_left > 0
                if fail:
                    server.failures_left -= 1
            if fail:
                sent = self.respond(
                    503, {"error": "transport health unavailable"}, workspace_receipt=True
                )
            else:
                sent = self.respond(200, transport_health(), workspace_receipt=True)
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class TransportServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = TransportHandler
        self.read_times: list[float] = []
        self.failures_left = 0


def transport_measured() -> dict[str, object]:
    return {"type": "transport_health_snapshot", "summary": {}}


def operator_digest() -> dict[str, object]:
    return {"type": "operator_digest"}


class TransportSignalTest(unittest.TestCase):
    binary = ""

    def run_usage(
        self, scenario: Callable[[TransportServer, Callable[..., None]], None]
    ) -> None:
        owed.ChatServer = TransportServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            usage = cast(TransportServer, server)
            usage.set_phase("open")
            # Keepers -> Usage via the palette (#50465 took Usage off the tab ring).
            step("keys", ":go Operations / Usage")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: usage.response_count("open", TRANSPORT_PATH) >= 1,
                "Usage did not read the transport health",
            )
            step("drain", 1.0)
            scenario(usage, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_a_transport_measurement_reads_the_transport(self) -> None:
        def scenario(server: TransportServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(operator_digest())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the digest push was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", TRANSPORT_PATH), 0)
            server.set_phase("measured")
            server.events.put(transport_measured())
            step(
                "wait",
                lambda: server.response_count("measured", TRANSPORT_PATH) == 1,
                "a transport measurement did not read the transport",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("measured", TRANSPORT_PATH), 1)

        self.run_usage(scenario)

    def test_failed_transport_reads_are_read_again(self) -> None:
        def scenario(server: TransportServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.failures_left = 1
                server.read_times.clear()
            server.events.put(transport_measured())
            step(
                "wait",
                lambda: len(server.read_times) >= 2,
                "a failed read was not read again",
            )
            step("drain", 4.0)
            with server.condition:
                times = list(server.read_times)
            # The second read succeeded, so nothing reads again.
            self.assertEqual(len(times), 2)
            self.assertGreater(times[1] - times[0], 1.0)

        self.run_usage(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_transport_signal.py /path/to/masc_tui.exe")
    TransportSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
