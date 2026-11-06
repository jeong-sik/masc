#!/usr/bin/env python3
"""Measure the selected Browser's reads during a fixed post-initial idle window."""

import json
import os
import subprocess
import sys
import time
from typing import cast

import test_tui_chat_owed_history as owed
import test_tui_browser_push as browser_fixture


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: measure_browser_idle.py /path/to/masc_tui.exe")
    binary = os.path.abspath(sys.argv[1])
    build_commit = subprocess.check_output([binary, "--build-commit"], text=True).strip()
    case = browser_fixture.BrowserPushTest("test_scoped_reads_trailing_retry_and_reconnect")
    case.binary = binary
    owed.ChatServer = browser_fixture.BrowserServer

    def scenario(server: owed.ChatServer, step) -> None:
        browser = cast(browser_fixture.BrowserServer, server)
        browser.set_phase("open")
        step("keys", ":go Browser Lane")
        step("drain", 0.3)
        step("keys", "\r")
        step("wait", lambda: browser.response_count("open", f"read:{browser_fixture.CLIENT_A}:2") == 1,
             "the selected Browser did not complete its initial read")
        started = time.monotonic()
        step("drain", 2.4)
        elapsed = time.monotonic() - started
        print("IDLE_SUMMARY=" + json.dumps({
            "binary": binary,
            "build_commit": build_commit,
            "idle_elapsed_seconds": elapsed,
            "selected_tab_read_posts": browser.response_count("open", f"read:{browser_fixture.CLIENT_A}:2"),
            "clients_gets": browser.response_count("open", "clients"),
            "scoped_observer_opens": browser.count("open", f"observer:live:{browser_fixture.CLIENT_A}:2:read"),
            "all_open_requests": [list(item) for item in sorted(browser.requests.items()) if item[0][0] == "open"],
        }, sort_keys=True))

    owed.ChatOwedHistoryTest.run_chat(case, scenario)


if __name__ == "__main__":
    main()
