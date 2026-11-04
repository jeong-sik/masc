#!/usr/bin/env python3
"""The Dashboard briefing is read only while Home is on screen: it feeds
Home's Health line alone. The cadence runs every second here, so the test
sees it read Home's briefing and leave it alone on Keepers.
"""

import os
import sys
import unittest
from typing import Callable, cast

import test_tui_chat_owed_history as owed


BRIEFING_PATH = "/api/v1/dashboard/briefing"
# The harness ends on Keepers, two Tabs from the opening Dashboard.
BACK = "\x1b[Z"


class BriefingOnHomeTest(unittest.TestCase):
    binary = ""

    def test_only_home_reads_the_briefing(self) -> None:
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("keepers")
            step("drain", 3.5)
            self.assertGreaterEqual(
                server.count("keepers", "/health"), 2, "the cadence did not run"
            )
            self.assertEqual(server.count("keepers", BRIEFING_PATH), 0)
            server.set_phase("home")
            step("sequence", BACK)
            step("drain", 0.3)
            step("sequence", BACK)
            step(
                "wait",
                lambda: server.count("home", BRIEFING_PATH) >= 1,
                "Home did not read its briefing",
            )

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), scenario, refresh_seconds=1.0
        )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_briefing_on_home.py /path/to/masc_tui.exe")
    BriefingOnHomeTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
