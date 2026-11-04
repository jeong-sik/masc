#!/usr/bin/env python3
"""The visible Browser reads follow its scoped SSE, never a shared cadence."""

import json
import os
import sys
import threading
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed
import test_tui_lane_inventory_push as lane_fixture


CLIENT_A = "01a16363-ef67-7000-ad62-05bcd0320d99"
CLIENT_B = "01a16363-ef68-7000-aee1-37e1be230202"
READ_PATH = "/api/v1/dashboard/browser-lane/read"
CLIENTS_PATH = "/api/v1/dashboard/browser-lane/clients"


def browser_event(*, client: str = CLIENT_A, tab: int = 2, revision: str) -> dict[str, object]:
    return {
        "type": "workspace_dataset_changed",
        "dataset": "browser_observation",
        "source": "live",
        "clientId": client,
        "tabId": tab,
        "view": "read",
        "revision": revision,
    }


def client_payload(client: str) -> dict:
    return {
        "clientId": client,
        "browser": "firefox",
        "version": "158.0.1",
        "engineVersion": "158.0.1",
        "transport": "web_extension",
        "space": None,
        "interactions": [],
        "lastActivities": [],
        "spaceObservation": None,
        "spacePresence": None,
    }


def read_payload(client: str, text: str) -> dict:
    tabs = [
        {"id": 1, "title": "first", "url": "https://example.org/first", "active": False},
        {"id": 2, "title": "second", "url": "https://example.org/second", "active": True},
    ]
    return {
        "ok": True,
        "data": {
            "source": "live",
            "clientId": client,
            "elapsed_ms": 1.0,
            "tabs": tabs,
            "selection": {"kind": "requested", "tabId": 2},
            "page": {
                "tabId": 2,
                "title": "second",
                "url": "https://example.org/second",
                "text": text,
                "chars": len(text),
                "truncated": False,
            },
        },
    }


class BrowserHandler(lane_fixture.LaneHandler):
    def do_GET(self) -> None:
        server = cast(BrowserServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == CLIENTS_PATH:
            phase = server.record("clients")
            response = {
                "ok": True,
                "data": {
                    "clients": [client_payload(CLIENT_A)],
                    "automatic": {
                        "browse": {
                            "ok": True,
                            "data": {
                                "lane": "live",
                                "clientId": CLIENT_A,
                                "reason": "available_connected_browser",
                            },
                        },
                        "work": {
                            "ok": True,
                            "data": {
                                "lane": "automation",
                                "clientId": None,
                                "reason": "existing_work_session",
                            },
                        },
                    },
                },
            }
            if self.respond(200, response):
                server.responded(phase, "clients")
            return
        if request.path == "/mcp":
            query = urllib.parse.parse_qs(request.query)
            if "source" in query:
                identity = ":".join([
                    query.get("source", [""])[0],
                    query.get("clientId", [""])[0],
                    query.get("tabId", [""])[0],
                    query.get("view", [""])[0],
                ])
                server.record("observer:" + identity)
        super().do_GET()

    def do_POST(self) -> None:
        server = cast(BrowserServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path != READ_PATH:
            super().do_POST()
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.loads(body)
        label = f"read:{payload.get('clientId')}:{payload.get('tabId')}"
        phase = server.record(label)
        if server.hold_read.is_set():
            server.hold_read.clear()
            server.read_held.set()
            server.release_read.wait()
        with server.condition:
            fail = server.failures_left > 0
            server.failures_left = max(0, server.failures_left - 1)
        if fail:
            sent = self.respond(503, {"ok": False, "error": "fixture read failed"})
        else:
            sent = self.respond(200, read_payload(CLIENT_A, server.visible_text))
        if sent:
            server.responded(phase, label)


class BrowserServer(lane_fixture.LaneServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = BrowserHandler
        self.hold_read = threading.Event()
        self.read_held = threading.Event()
        self.release_read = threading.Event()
        self.visible_text = "first browser frame"


class BrowserPushTest(unittest.TestCase):
    binary = ""

    def test_scoped_reads_trailing_retry_and_reconnect(self) -> None:
        owed.ChatServer = BrowserServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            browser = cast(BrowserServer, server)
            browser.set_phase("open")
            step("keys", ":go Browser Lane\n")
            step("wait", lambda: browser.response_count("open", f"read:{CLIENT_A}:2") == 1,
                 "the selected Browser did not complete its initial read")
            step("wait", lambda: browser.count("open", f"observer:live:{CLIENT_A}:2:read") >= 1,
                 "the observer did not carry the exact Browser target")
            step("drain", 2.4)
            self.assertEqual(browser.response_count("open", f"read:{CLIENT_A}:2"), 1,
                             "the Browser kept reading while idle")

            browser.set_phase("unrelated")
            browser.events.put(browser_event(client=CLIENT_B, revision="b" * 64))
            browser.events.put(browser_event(tab=7, revision="c" * 64))
            step("drain", 0.5)
            self.assertEqual(browser.count("unrelated", f"read:{CLIENT_B}:2"), 0)
            self.assertEqual(browser.count("unrelated", f"read:{CLIENT_A}:7"), 0)
            self.assertEqual(browser.count("unrelated", f"read:{CLIENT_A}:2"), 0)

            browser.set_phase("changed")
            browser.visible_text = "changed browser frame"
            browser.events.put(browser_event(revision="a" * 64))
            step("wait", lambda: browser.response_count("changed", f"read:{CLIENT_A}:2") == 1,
                 "a matching Browser observation did not read exactly once")

            browser.set_phase("trailing")
            browser.hold_read.set()
            browser.events.put(browser_event(revision="d" * 64))
            step("wait", browser.read_held.is_set, "the first Browser change read did not start")
            browser.events.put(browser_event(revision="e" * 64))
            browser.events.put(browser_event(revision="f" * 64))
            step("drain", 0.3)
            browser.release_read.set()
            step("wait", lambda: browser.response_count("trailing", f"read:{CLIENT_A}:2") == 2,
                 "a burst did not produce one trailing Browser read")
            step("drain", 0.5)
            self.assertEqual(browser.response_count("trailing", f"read:{CLIENT_A}:2"), 2)

            browser.set_phase("retry")
            with browser.condition:
                browser.failures_left = 1
            browser.events.put(browser_event(revision="1" * 64))
            step("wait", lambda: browser.response_count("retry", f"read:{CLIENT_A}:2") == 2,
                 "a failed Browser read was not retried")

            browser.set_phase("reconnect")
            browser.events.put("close")
            step("wait", lambda: browser.response_count("reconnect", f"read:{CLIENT_A}:2") >= 1,
                 "observer replacement did not revalidate the visible Browser")

            browser.set_phase("hidden")
            step("keys", "\x1b")
            browser.events.put(browser_event(revision="2" * 64))
            step("drain", 0.5)
            self.assertEqual(browser.count("hidden", f"read:{CLIENT_A}:2"), 0,
                             "a hidden Browser still read after a notification")

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_browser_push.py /path/to/masc_tui.exe")
    BrowserPushTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
