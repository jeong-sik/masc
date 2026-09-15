#!/usr/bin/env python3
"""CI-built host against real HTTP and native messaging pipes; no browser writes."""
import http.server
import json
import os
from pathlib import Path
import queue
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

HOST = Path(sys.argv.pop(1)).resolve()
TOKEN = "browser-host-test-token-no-secret"
# The host waits reconnect_delay_sec (5 s, browser_host.ml) after a failed poll
# before reading the workspace connection again; this leaves room for that wait
# and the poll that follows.
POLL_RETRY_WAIT_SEC = 15
# How long the fake server holds an empty poll. The scenarios that fail a poll
# on purpose answer quickly so the failure is not queued behind a long wait.
LONG_POLL_SEC = 10
SHORT_POLL_SEC = 0.2
# Tests whose host takes its port from the workspace connection or the
# environment rather than --server.
FOLLOWS_WORKSPACE = {
    "test_workspace_connection_port_is_followed",
    "test_failed_poll_reads_the_workspace_port_again",
    "test_a_failed_poll_stays_while_the_server_still_answers",
    "test_the_host_moves_once_the_named_server_answers",
}


def closed_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def start_peer(test_name):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Peer)
    server.commands = queue.Queue()
    server.results = queue.Queue()
    server.poll_seen = threading.Event()
    server.ping_seen = threading.Event()
    server.fail_next_poll = threading.Event()
    server.failed_poll_answered = threading.Event()
    server.polls_after_failure = threading.Event()
    server.disconnected = threading.Event()
    server.identities = []
    server.poll_wait_sec = SHORT_POLL_SEC if test_name in {
        "test_a_failed_poll_stays_while_the_server_still_answers",
        "test_the_host_moves_once_the_named_server_answers",
        "test_an_exported_port_is_never_followed",
    } else LONG_POLL_SEC
    server.reject_client = test_name == "test_retired_client_exits_for_fresh_identity"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def stop_peer(server, thread):
    server.shutdown()
    server.server_close()
    thread.join()


def encode_frame(value):
    payload = json.dumps(value, ensure_ascii=False).encode()
    return struct.pack("<I", len(payload)) + payload


def read_exact(pipe, length):
    data = bytearray()
    deadline = time.monotonic() + 5
    while len(data) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([pipe], [], [], remaining)[0]:
            raise AssertionError("native frame timed out")
        chunk = os.read(pipe.fileno(), length - len(data))
        if not chunk:
            raise AssertionError("native frame unexpectedly closed")
        data.extend(chunk)
    return bytes(data)


def read_frame(pipe):
    length, = struct.unpack("<I", read_exact(pipe, 4))
    return json.loads(read_exact(pipe, length))


class Peer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";", 1)[0], 16)
                if size == 0:
                    self.rfile.readline()
                    return json.loads(b"".join(chunks))
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
        return json.loads(self.rfile.read(int(self.headers["Content-Length"])))

    def do_POST(self):
        body = self.body()
        if self.headers.get("x-lane-token") != TOKEN or self.headers.get("x-lane") != "live":
            self.send_error(403)
            return
        client_id = self.headers.get("x-browser-client-id")
        try:
            uuid.UUID(client_id)
        except (ValueError, TypeError, AttributeError):
            self.send_error(400)
            return
        self.server.identities.append((client_id, self.headers.get("x-browser-name"),
            self.headers.get("x-browser-version"), self.headers.get("x-browser-engine-version")))
        if self.path == "/browser-lane/ping":
            # The lane answers without registering a client.
            self.server.ping_seen.set()
            response = {"ok": True}
        elif self.path == "/browser-lane/poll":
            self.server.poll_seen.set()
            if self.server.failed_poll_answered.is_set():
                self.server.polls_after_failure.set()
            if self.server.reject_client:
                self.send_error(400)
                return
            if self.server.fail_next_poll.is_set():
                self.server.fail_next_poll.clear()
                self.server.failed_poll_answered.set()
                self.send_error(500)
                return
            try:
                response = self.server.commands.get(timeout=self.server.poll_wait_sec)
            except queue.Empty:
                response = {"ok": True, "empty": True}
        elif self.path == "/browser-lane/result":
            self.server.results.put(body)
            response = {"ok": True}
        elif self.path == "/browser-lane/disconnect":
            self.server.disconnected.set()
            response = {"ok": True}
        else:
            self.send_error(404)
            return
        data = json.dumps(response).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


class NativeHost(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        token = base / ".masc/browser-lane/token"
        token.parent.mkdir(parents=True)
        token.write_text(TOKEN)
        self.server, self.thread = start_peer(self._testMethodName)
        self.peers = []
        # The FOLLOWS_WORKSPACE tests omit --server so the workspace
        # connection.toml decides the destination; every other client is
        # fixed to this server with --server. The one that starts on a port
        # nothing listens on reaches this server only by reading the file
        # again after its failed poll.
        workspace_connection_port = closed_port() \
            if self._testMethodName == "test_failed_poll_reads_the_workspace_port_again" \
            else self.server.server_port
        argv = [str(HOST), "--base-path", str(base)]
        self.connection = base / ".masc/config/connection.toml"
        # An exported MASC_HTTP_BASE_URL or MASC_HTTP_PORT outranks the file.
        env = {key: value for key, value in os.environ.items() if not key.startswith("MASC_")}
        if self._testMethodName == "test_an_exported_port_is_never_followed":
            # The file names a port nothing listens on; the environment names
            # this server, and a fixed address is never pinged or moved.
            self.connection.parent.mkdir(parents=True)
            self.connection.write_text(f"[server]\nhttp_port = {closed_port()}\n")
            env["MASC_HTTP_PORT"] = str(self.server.server_port)
        elif self._testMethodName in FOLLOWS_WORKSPACE:
            self.connection.parent.mkdir(parents=True)
            self.connection.write_text(f"[server]\nhttp_port = {workspace_connection_port}\n")
        else:
            argv += ["--server", f"http://127.0.0.1:{self.server.server_port}"]
        self.process = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        metadata = read_frame(self.process.stdout)
        self.assertEqual(metadata["verb"], "browser.info")
        self.assertFalse(self.server.poll_seen.is_set(), "must discover actual browser before polling")
        browser = {"name": "Firefox", "vendor": "Mozilla", "version": "155.0.1"}
        if self._testMethodName != "test_firefox_metadata":
            browser["zen"] = {"version": "1.22b"}
        if self._testMethodName == "test_bad_metadata_never_polls":
            browser["zen"] = {"version": ""}
        self.process.stdin.write(encode_frame({"id": metadata["id"], "ok": True, "data": browser}))
        self.process.stdin.flush()


    def tearDown(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()
        self.process.stderr.close()
        if not self.process.stdin.closed:
            self.process.stdin.close()
        stop_peer(self.server, self.thread)
        for server, thread in self.peers:
            stop_peer(server, thread)
        self.temporary.cleanup()

    def assert_command(self, command):
        received = read_frame(self.process.stdout)
        deadline = received.pop("deadlineMs")
        self.assertIsInstance(deadline, (int, float))
        self.assertGreater(deadline, time.time() * 1000)
        self.assertEqual(received, command)

    def test_firefox_metadata(self):
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        self.assertTrue(all(row[1:] == ("firefox", "155.0.1", "155.0.1") for row in self.server.identities))

    def test_workspace_connection_port_is_followed(self):
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        self.assertTrue(self.server.identities)

    def test_failed_poll_reads_the_workspace_port_again(self):
        # The server restarted on another port and rewrote connection.toml.
        # The host's first poll went to the port it read at launch and failed.
        self.connection.write_text(f"[server]\nhttp_port = {self.server.server_port}\n")
        self.assertTrue(self.server.poll_seen.wait(timeout=POLL_RETRY_WAIT_SEC))
        self.assertEqual(len({identity[0] for identity in self.server.identities}), 1)

    def test_a_failed_poll_stays_while_the_server_still_answers(self):
        # connection.toml is only the desired port: another command may name
        # a port while this server keeps serving. A failed poll alone moves
        # nothing, even when a server also answers at the named port.
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        other, other_thread = start_peer(self._testMethodName)
        self.peers.append((other, other_thread))
        self.connection.write_text(f"[server]\nhttp_port = {other.server_port}\n")
        self.server.fail_next_poll.set()
        self.assertTrue(self.server.polls_after_failure.wait(timeout=POLL_RETRY_WAIT_SEC))
        self.assertTrue(self.server.ping_seen.is_set(), "the host asks its server before staying")
        self.assertFalse(other.ping_seen.is_set(), "a server that still answers is not left")
        self.assertEqual(other.identities, [])

    def test_the_host_moves_once_the_named_server_answers(self):
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        other, other_thread = start_peer(self._testMethodName)
        self.peers.append((other, other_thread))
        self.connection.write_text(f"[server]\nhttp_port = {other.server_port}\n")
        stop_peer(self.server, self.thread)
        self.assertTrue(other.poll_seen.wait(timeout=POLL_RETRY_WAIT_SEC))
        self.assertTrue(other.ping_seen.is_set(), "the host moves only after the new server answers")
        self.assertEqual(len({identity[0] for identity in self.server.identities + other.identities}), 1)

    def test_an_exported_port_is_never_followed(self):
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        self.server.fail_next_poll.set()
        self.assertTrue(self.server.polls_after_failure.wait(timeout=POLL_RETRY_WAIT_SEC))
        self.assertFalse(self.server.ping_seen.is_set(), "a fixed address has nothing to compare")

    def test_retired_client_exits_for_fresh_identity(self):
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        self.assertNotEqual(self.process.wait(timeout=5), 0)
        self.assertTrue(self.server.disconnected.is_set())
        self.assertEqual(len({identity[0] for identity in self.server.identities}), 1)

    def test_bad_metadata_never_polls(self):
        self.assertNotEqual(self.process.wait(timeout=2), 0)
        self.assertFalse(self.server.poll_seen.is_set())

    def test_tabs_and_page_roundtrip_fragmented_utf8(self):
        for index, verb in enumerate(["tabs.list", "page.read", "page.capture", "page.interact", "page.scene"]):
            command = {"id": str(index), "verb": verb, "args": {"tabId": 42} if index else {}}
            self.server.commands.put(command)
            self.assert_command(command)
            stale = {"id": "other-id", "ok": True, "data": "must not resolve"}
            self.process.stdin.write(encode_frame(stale))
            self.process.stdin.flush()
            reply = {"id": str(index), "ok": True, "data": {"text": "Firefox 읽기", "tabId": 42}}
            framed = encode_frame(reply)
            for part in [framed[:1], framed[1:3], framed[3:8], framed[8:]]:
                self.process.stdin.write(part)
                self.process.stdin.flush()
            self.assertEqual(self.server.results.get(timeout=5), reply)

    def test_interaction_pre_effect_metadata_roundtrip(self):
        command = {"id": "pre-effect", "verb": "page.interact", "args": {"tabId": 42}}
        self.server.commands.put(command)
        self.assert_command(command)
        reply = {"id": "pre-effect", "ok": False, "error": "scene_node_detached", "effectPhase": "not_started"}
        self.process.stdin.write(encode_frame(reply))
        self.process.stdin.flush()
        self.assertEqual(self.server.results.get(timeout=5), reply)

    def test_screenshot_reply_larger_than_command_limit(self):
        command = {"id": "screenshot", "verb": "page.capture", "args": {"tabId": 73}}
        self.server.commands.put(command)
        self.assert_command(command)
        reply = {"id": "screenshot", "ok": True, "data": {
            "tabId": 73, "data": "A" * (2 * 1024 * 1024),
            "url": "https://example.org", "title": "Screenshot"}}
        self.process.stdin.write(encode_frame(reply))
        self.process.stdin.flush()
        self.assertEqual(self.server.results.get(timeout=10), reply)

    def test_unsupported_verb_is_not_forwarded(self):
        for verb, args in [
            ("page.goto", {"url": "https://example.com"}),
            ("page.act", {"action": "click", "tabId": 73, "selector": "button"}),
        ]:
            with self.subTest(verb=verb):
                self.server.commands.put({"id": "rejected", "verb": verb, "args": args})
                reply = self.server.results.get(timeout=5)
                self.assertFalse(reply["ok"])
                self.assertEqual(reply["id"], "rejected")
                self.assertFalse(select.select([self.process.stdout], [], [], 0)[0])

    def test_elements_roundtrip_preserves_target_and_control_observation(self):
        for index, args in enumerate([{}, {"tabId": 73}]):
            with self.subTest(args=args):
                command = {"id": f"elements-{index}", "verb": "page.elements", "args": args}
                self.server.commands.put(command)
                self.assert_command(command)
                reply = {
                    "id": command["id"], "ok": True,
                    "data": {
                        "tabId": 73, "url": "https://example.org/form", "title": "폼",
                        "total": 1, "truncated": False,
                        "elements": [{
                            "selector": "html > body > select:nth-of-type(1)",
                            "tag": "select", "value": "draft-id", "multiple": False,
                            "options": [{"value": "draft-id", "label": "초안",
                                         "selected": True, "disabled": False}],
                        }],
                    },
                }
                framed = encode_frame(reply)
                self.process.stdin.write(framed[:3])
                self.process.stdin.flush()
                self.process.stdin.write(framed[3:])
                self.process.stdin.flush()
                self.assertEqual(self.server.results.get(timeout=5), reply)

    def test_eof_cancels_waiting_http(self):
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        self.process.stdin.close()
        self.assertEqual(self.process.wait(timeout=2), 0)
        self.assertEqual(self.process.stdout.read(), b"")
        self.assertTrue(self.server.disconnected.is_set())
        ids = {row[0] for row in self.server.identities}
        self.assertEqual(len(ids), 1, "one native process owns one client UUID")
        self.assertTrue(all(row[1:] == ("zen", "1.22b", "155.0.1") for row in self.server.identities))

    def test_oversized_frame_rejected_before_payload(self):
        self.process.stdin.write(struct.pack("<I", 8 * 1024 * 1024 + 1))
        self.process.stdin.flush()
        self.assertNotEqual(self.process.wait(timeout=2), 0)
        diagnostics = self.process.stderr.read()
        self.assertIn(b"frame", diagnostics)
        self.assertNotIn(TOKEN.encode(), diagnostics)

    def test_truncated_frame_is_failure(self):
        self.process.stdin.write(b"\x10\x00")
        self.process.stdin.close()
        self.assertNotEqual(self.process.wait(timeout=2), 0)
        self.assertIn(b"truncated native frame", self.process.stderr.read())

    def test_unread_stdout_closes_partial_frame_stream(self):
        self.server.commands.put({"id": "blocked-write", "verb": "page.read", "args": {"padding": "x" * (512 * 1024)}})
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        self.assertNotEqual(self.process.wait(timeout=25), 0)
        self.assertIn(b"native frame write timed out", self.process.stderr.read())

    def test_eof_cancels_partial_frame_write(self):
        self.server.commands.put({"id": "eof-during-write", "verb": "page.read", "args": {"padding": "x" * (512 * 1024)}})
        # The header proves the write began. Leave the large payload unread
        # and close the browser's sending pipe while stdout has backpressure.
        length, = struct.unpack("<I", read_exact(self.process.stdout, 4))
        self.assertGreater(length, 512 * 1024)
        self.process.stdin.close()
        self.assertEqual(self.process.wait(timeout=2), 0)


class Destination(unittest.TestCase):
    def test_remote_and_credentialed_origins_rejected(self):
        for server in ["http://example.com", "http://127.0.0.1.evil.test", "http://user:password@localhost", "http://localhost/path", "http://localhost?token=secret"]:
            with self.subTest(server=server):
                result = subprocess.run([str(HOST), "--base-path", "/unused-browser-host-base", "--server", server], input=b"", capture_output=True, timeout=3)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"loopback http origin", result.stderr)
                self.assertNotIn(b"password", result.stderr)
                self.assertNotIn(b"secret", result.stderr)
                self.assertEqual(result.stdout, b"")

    def test_inherited_remote_server_rejected(self):
        env = dict(os.environ, MASC_HTTP_BASE_URL="http://example.com")
        result = subprocess.run([str(HOST), "--base-path", "/unused-browser-host-base"], env=env, input=b"", capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"loopback http origin", result.stderr)

    def test_malformed_workspace_port_is_an_error_not_a_default(self):
        with tempfile.TemporaryDirectory() as raw:
            base = Path(raw)
            connection = base / ".masc/config/connection.toml"
            connection.parent.mkdir(parents=True)
            connection.write_text('[server]\nhttp_port = "banana"\n')
            env = {key: value for key, value in os.environ.items() if not key.startswith("MASC_")}
            result = subprocess.run([str(HOST), "--base-path", str(base)], env=env, input=b"", capture_output=True, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"http_port", result.stderr)
            self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
