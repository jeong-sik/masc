#!/usr/bin/env python3
"""CI-built host against real HTTP and native messaging pipes; no browser writes."""
import http.server
import json
import os
from pathlib import Path
import queue
import select
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HOST = Path(sys.argv.pop(1)).resolve()
TOKEN = "browser-host-test-token-no-secret"


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
        if self.path == "/browser-lane/poll":
            self.server.poll_seen.set()
            try:
                response = self.server.commands.get(timeout=10)
            except queue.Empty:
                response = {"ok": True, "empty": True}
        elif self.path == "/browser-lane/result":
            self.server.results.put(body)
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
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Peer)
        self.server.commands = queue.Queue()
        self.server.results = queue.Queue()
        self.server.poll_seen = threading.Event()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.process = subprocess.Popen([str(HOST), "--base-path", str(base), "--server", f"http://127.0.0.1:{self.server.server_port}"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

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
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def test_tabs_and_page_roundtrip_fragmented_utf8(self):
        for index, verb in enumerate(["tabs.list", "page.read", "page.capture", "page.interact"]):
            command = {"id": str(index), "verb": verb, "args": {"tabId": 42} if index else {}}
            self.server.commands.put(command)
            self.assertEqual(read_frame(self.process.stdout), command)
            stale = {"id": "other-id", "ok": True, "data": "must not resolve"}
            self.process.stdin.write(encode_frame(stale))
            self.process.stdin.flush()
            reply = {"id": str(index), "ok": True, "data": {"text": "Firefox 읽기", "tabId": 42}}
            framed = encode_frame(reply)
            for part in [framed[:1], framed[1:3], framed[3:8], framed[8:]]:
                self.process.stdin.write(part)
                self.process.stdin.flush()
            self.assertEqual(self.server.results.get(timeout=5), reply)

    def test_unsupported_verb_is_not_forwarded(self):
        self.server.commands.put({"id": "rejected", "verb": "page.goto", "args": {"url": "https://example.com"}})
        reply = self.server.results.get(timeout=5)
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["id"], "rejected")
        self.assertFalse(select.select([self.process.stdout], [], [], 0)[0])

    def test_eof_cancels_waiting_http(self):
        self.assertTrue(self.server.poll_seen.wait(timeout=5))
        self.process.stdin.close()
        self.assertEqual(self.process.wait(timeout=2), 0)
        self.assertEqual(self.process.stdout.read(), b"")

    def test_oversized_frame_rejected_before_payload(self):
        self.process.stdin.write(struct.pack("<I", 1024 * 1024 + 1))
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


if __name__ == "__main__":
    unittest.main()
