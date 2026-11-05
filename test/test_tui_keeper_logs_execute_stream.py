#!/usr/bin/env python3
"""The logs view follows a Keeper's Execute output over the stream the
Terminal tab follows (RFC-0480 L6).

The TUI reads nothing on a clock, so what the logs
view asks the server for is what opening it asks for.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


STREAM_PATH = "/api/v1/dashboard/execute-output/analyst"
# The stream is held open with the server's heartbeat comment until the TUI
# closes it or this many seconds pass.
STREAM_HELD_SECONDS = 60.0
HEARTBEAT_SECONDS = 0.5


class ExecuteHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(ExecuteServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == STREAM_PATH:
            server.record(request.path)
            self.hold_stream()
        else:
            super().do_GET()

    def hold_stream(self) -> None:
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("x-masc-workspace-read", "matched-v1")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            deadline = time.monotonic() + STREAM_HELD_SECONDS
            while time.monotonic() < deadline:
                self.wfile.write(b": heartbeat\n\n")
                self.wfile.flush()
                time.sleep(HEARTBEAT_SECONDS)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


class ExecuteServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = ExecuteHandler


class KeeperLogsExecuteStreamTest(unittest.TestCase):
    binary = ""

    def test_the_logs_view_opens_the_stream_and_keeps_it(self) -> None:
        owed.ChatServer = ExecuteServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("logs")
            step("keys", "l")
            step(
                "wait",
                lambda: server.count("logs", STREAM_PATH) >= 1,
                "the logs view did not open the Execute output stream",
            )
            step("drain", 3.0)
            # The held stream stays the one the view follows.
            self.assertEqual(server.count("logs", STREAM_PATH), 1)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_keeper_logs_execute_stream.py /path/to/masc_tui.exe")
    KeeperLogsExecuteStreamTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
