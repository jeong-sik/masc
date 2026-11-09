#!/usr/bin/env python3
"""Usage's account emails read once on arrival and once per server push
(RFC-0480 §3.4).

The TUI publishes each dataset of a surface read as soon as it arrives, before
the rest of the bundle. That early answer is the only one the dataset gets, so
it has to settle the owed read; an owed read left in flight was read again on
every loop iteration, about fifty reads a second.

The refresh cadence is pushed out of the test's lifetime, so every account
email read after Usage opens comes from arriving there or from a push.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


ACCOUNT_EMAILS_PATH = "/api/v1/setup/account-emails"

# The run below rebinds [owed.ChatServer]; this name keeps the base class.
BaseChatServer = owed.ChatServer


class UsageHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(UsageServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == ACCOUNT_EMAILS_PATH:
            phase = server.record(request.path)
            if self.respond(200, {"account_emails": []}, workspace_receipt=True):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class UsageServer(BaseChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = UsageHandler


def account_emails_changed() -> dict[str, object]:
    return {"type": "workspace_dataset_changed", "dataset": "account_emails"}


class UsagePushedReadsTest(unittest.TestCase):
    binary = ""

    def test_account_emails_read_once_per_reason(self) -> None:
        owed.ChatServer = UsageServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: BaseChatServer, step: Callable[..., None]) -> None:
            usage = cast(UsageServer, server)
            usage.set_phase("open")
            # Keepers -> Usage via the palette (#50465 took Usage off the tab ring).
            step("keys", ":go Operations / Usage")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: usage.response_count("open", ACCOUNT_EMAILS_PATH) >= 1,
                "Usage did not read the account emails",
            )
            step("drain", 1.5)
            self.assertEqual(usage.count("open", ACCOUNT_EMAILS_PATH), 1)
            usage.set_phase("changed")
            usage.events.put(account_emails_changed())
            step(
                "wait",
                lambda: usage.response_count("changed", ACCOUNT_EMAILS_PATH) >= 1,
                "an account emails push did not read them",
            )
            step("drain", 1.5)
            self.assertEqual(usage.count("changed", ACCOUNT_EMAILS_PATH), 1)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_usage_pushed_reads.py /path/to/masc_tui.exe")
    UsagePushedReadsTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
