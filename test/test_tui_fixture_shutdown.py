"""Closing the fixture endpoint waits for its in-flight HTTP handler."""

from __future__ import annotations

import http.client
import threading
import unittest
from unittest.mock import patch

import test_tui_keyboard_input as h

SOURCE_MODULES = ("test/test_tui_keyboard_input.py",)


class FixtureShutdown(unittest.TestCase):
    def test_context_exit_names_handler_at_cleanup_deadline(self) -> None:
        entered = threading.Event()
        release = threading.Event()
        handler: threading.Thread | None = None
        client: http.client.HTTPConnection | None = None
        original_join = threading.Thread.join

        def response() -> h.HttpResponse:
            nonlocal handler
            handler = threading.current_thread()
            entered.set()
            release.wait()
            return 200, {"finished": True}

        def join(thread: threading.Thread, timeout: float | None = None) -> None:
            # Rescue the unbounded baseline so it fails this assertion rather
            # than hanging the test process. A bounded join keeps the gate held.
            if thread is handler and timeout is None:
                release.set()
            original_join(thread, timeout)

        try:
            with (
                patch.object(h, "FIXTURE_HANDLER_CLEANUP_TIMEOUT_S", 0.0, create=True),
                patch.object(threading.Thread, "join", join),
                self.assertRaisesRegex(
                    AssertionError, "HTTP fixture handlers did not stop"
                ) as error,
            ):
                with h.test_http_endpoint({"/held": response}, None) as (
                    port,
                    start,
                    _,
                ):
                    start()
                    try:
                        client = http.client.HTTPConnection(
                            "127.0.0.1", port, timeout=3.0
                        )
                        client.request("GET", "/held")
                        self.assertTrue(
                            entered.wait(timeout=3.0), "HTTP handler did not enter"
                        )
                    except BaseException:
                        release.set()
                        if client is not None:
                            client.close()
                        raise
            assert handler is not None
            self.assertIn(handler.name, str(error.exception))
            self.assertTrue(
                handler.is_alive(), "fixture must report the still-held handler"
            )
        finally:
            release.set()
            if handler is not None:
                original_join(handler, timeout=3.0)
            if client is not None:
                client.close()
            if handler is not None:
                self.assertFalse(
                    handler.is_alive(), f"test cleanup left {handler.name} alive"
                )

    def test_context_exit_joins_inflight_response(self) -> None:
        entered = threading.Event()
        release = threading.Event()
        handler: threading.Thread | None = None
        client: http.client.HTTPConnection | None = None
        original_join = threading.Thread.join

        def response() -> h.HttpResponse:
            nonlocal handler
            handler = threading.current_thread()
            entered.set()
            release.wait()
            return 200, {"finished": True}

        def join(thread: threading.Thread, timeout: float | None = None) -> None:
            # Release exactly when cleanup waits for this live handler. A
            # daemon handler omitted from cleanup stays held until finally,
            # so the regression fails without a scheduling delay or sleep.
            if thread is handler:
                release.set()
            original_join(thread, timeout)

        try:
            with patch.object(threading.Thread, "join", join):
                with h.test_http_endpoint({"/held": response}, None) as (
                    port,
                    start,
                    _,
                ):
                    start()
                    try:
                        # Match the harness's ordinary HTTP/frame response wait.
                        client = http.client.HTTPConnection(
                            "127.0.0.1", port, timeout=3.0
                        )
                        client.request("GET", "/held")
                        self.assertTrue(
                            entered.wait(timeout=3.0), "HTTP handler did not enter"
                        )
                    except BaseException:
                        # Release before endpoint.__exit__ joins request threads.
                        release.set()
                        if client is not None:
                            client.close()
                        raise
                assert handler is not None
                self.assertFalse(handler.is_alive(), "endpoint left its handler alive")
                reply = client.getresponse()
                self.assertEqual(reply.status, 200)
                self.assertEqual(reply.read(), b'{"finished": true}')
        finally:
            release.set()
            if handler is not None:
                original_join(handler, timeout=3.0)
            if client is not None:
                client.close()
            if handler is not None:
                self.assertFalse(
                    handler.is_alive(), f"test cleanup left {handler.name} alive"
                )


if __name__ == "__main__":
    unittest.main()
