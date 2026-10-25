"""Interrupted real HTTP peers must release OAuth locks without replay."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
import fcntl
import importlib.util
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib import request
from urllib.parse import parse_qs, urlsplit

from onepassword_store_fixture import MemoryRecords


SOURCE = Path(__file__).resolve().parents[1] / "onepassword" / "oauth.py"
SPEC = importlib.util.spec_from_file_location("onepassword_transport_oauth", SOURCE)
oauth = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = oauth
SPEC.loader.exec_module(oauth)


class TransportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name) / "private"
        directory.mkdir(mode=0o700)
        self.records = MemoryRecords(str(directory))
        self.store = oauth.PrivateStore(directory, records=self.records)
        self.configuration = oauth.Configuration("fixture-client", "FIXTURE_SECRET",
                                                 "https://masc.example/callback")
        self.clock = 1000.0
        self.connector = oauth.Connector(self.configuration, self.store, now=lambda: self.clock)

    @contextmanager
    def stalled_peer(self, *, body, truncated=False):
        entered, release = threading.Event(), threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                if body:
                    self.send_response(200)
                    self.send_header("Content-Length", "100")
                    self.end_headers()
                    self.wfile.write(b"{")
                    self.wfile.flush()
                entered.set()
                if not truncated:
                    release.wait(5)

            def log_message(self, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        server.timeout = 5
        serving = threading.Thread(target=server.handle_request)
        serving.start()
        # Keep the production URL and redirect handler intact. Only this test's
        # opener routes its synthetic credentials to the owned loopback peer.
        opener = request.build_opener(request.ProxyHandler({}), oauth.NoRedirect)

        class LocalOpener:
            def open(self, req, *, timeout=socket._GLOBAL_DEFAULT_TIMEOUT):
                local = request.Request("http://127.0.0.1:" + str(server.server_port)
                                        + urlsplit(req.full_url).path, data=req.data,
                                        headers=dict(req.header_items()), method=req.method)
                return opener.open(local, timeout=timeout)

        try:
            with patch.object(oauth.request, "build_opener", return_value=LocalOpener()) as opened:
                # Shorten only this fixture's socket inactivity limit. The
                # future/event waits are cleanup watchdogs, not elapsed-time
                # assertions or Keeper/approval deadlines.
                with patch.object(oauth, "OAUTH_SOCKET_TIMEOUT_S", 0.05, create=True):
                    yield entered, release, opened
        finally:
            release.set()
            serving.join(5)
            server.server_close()
            self.assertFalse(serving.is_alive())

    def stalled_operation(self, *, refresh, body, truncated=False):
        authorization = self.connector.begin()
        state = parse_qs(urlsplit(authorization["authorization_url"]).query)["state"][0]
        if refresh:
            tokens = {"access_token": "FIXTURE_ACCESS", "refresh_token": "FIXTURE_REFRESH",
                      "token_type": "Bearer", "expires_in": 1, "scope": oauth.SCOPES}
            self.connector.transport = lambda *args: tokens
            self.connector.complete(state=state, code="FIXTURE_CODE", integration_key="FIXTURE_KEY")
            self.clock += 2
        with self.store.locked() as root:
            original = self.store.read(root)
        self.connector.transport = oauth.post

        def operation():
            if refresh:
                return self.connector.credentials(lambda *args: self.fail("uncertain token was used"),
                                                   expected_connection_id=original["connection_id"])
            return self.connector.complete(state=state, code="FIXTURE_CODE", integration_key="FIXTURE_KEY")

        with self.stalled_peer(body=body, truncated=truncated) as (entered, release, opened):
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(operation)
                try:
                    self.assertTrue(entered.wait(5), "OAuth request never reached the stalled peer")
                    with self.assertRaisesRegex(oauth.ConnectionError, "^oauth_transport_or_response_failure$"):
                        future.result(timeout=2)
                finally:
                    release.set()
            # Both the original RLock (on another thread) and an independently
            # opened flock must be available after the transport error.
            self.assertTrue(self.store.thread_lock.acquire(blocking=False), "thread lock was retained")
            self.store.thread_lock.release()
            lock = os.open(self.store.directory / "connection.lock", os.O_RDWR | os.O_NOFOLLOW)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(lock)
            with self.store.locked() as root:
                retained = self.store.read(root)
            other = oauth.PrivateStore(self.store.directory, records=self.records)
            with other.locked() as root:
                self.assertEqual(other.read(root), retained)
            expected = oauth.Phase.REFRESHING if refresh else oauth.Phase.EXCHANGING
            self.assertEqual(retained["phase"], expected.value)
            self.assertEqual(retained["integration_key"], "FIXTURE_KEY")
            self.assertEqual(retained["connection_id"], original["connection_id"])
            if refresh:
                self.assertEqual(retained["refresh_token"], original["refresh_token"])
            self.assertEqual(self.connector.status(), {"phase": "reconnect_required", "connected": False})
            with self.assertRaises(oauth.ConnectionError):
                operation()
            self.assertEqual(opened.call_count, 1, "uncertain one-use request was replayed")

    def test_exchange_with_stalled_headers_releases_locks_without_replaying(self):
        self.stalled_operation(refresh=False, body=False)

    def test_exchange_with_stalled_body_releases_locks_without_replaying(self):
        self.stalled_operation(refresh=False, body=True)

    def test_refresh_with_stalled_headers_releases_locks_without_replaying(self):
        self.stalled_operation(refresh=True, body=False)

    def test_refresh_with_stalled_body_releases_locks_without_replaying(self):
        self.stalled_operation(refresh=True, body=True)

    def test_exchange_with_truncated_body_preserves_safe_failure_and_no_replay(self):
        self.stalled_operation(refresh=False, body=True, truncated=True)

    def test_refresh_with_truncated_body_preserves_safe_failure_and_no_replay(self):
        self.stalled_operation(refresh=True, body=True, truncated=True)


if __name__ == "__main__":
    unittest.main()
