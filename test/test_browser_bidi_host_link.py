#!/usr/bin/env python3
"""The BiDi host between a MASC server that restarts and a Firefox that leaves.

Usage: python3 test_browser_bidi_host_link.py HOST
The CI-built host runs against a local HTTP lane and a scripted BiDi endpoint;
no browser. test_browser_bidi_host.py is the one that drives a real Firefox.
"""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

HOST = Path(sys.argv.pop(1)).resolve()
TOKEN = "bidi-host-link-test-token-no-secret"
# The host waits reconnect_delay_sec (5 s, browser_host.ml) after a request
# that did not reach the server; this leaves room for that wait and the
# request that follows.
RETRY_WAIT_SEC = 15
# The lane answers an empty poll quickly, so a server that stops is noticed
# by the next poll rather than at the end of a long one.
POLL_WAIT_SEC = 0.2
# A host that is going to exit does so well within this.
EXIT_WAIT_SEC = 5
# Long enough for a host that would wrongly exit to have done so.
STAYS_ALIVE_SEC = 2
PAGE = {"url": "https://example.test/", "title": "Fixture", "text": "fixture text",
        "active": True, "scrollX": 0, "scrollY": 0}


class LaneState:
    def __init__(self):
        self.commands = queue.Queue()
        self.results = queue.Queue()
        self.polls = []
        self.polled = threading.Event()
        self.result_posts = []
        self.drop_next_result = threading.Event()
        self.drop_every_result = False
        self.disconnected = threading.Event()
        self.refuse_registration = False


class LaneServer(http.server.ThreadingHTTPServer):
    def __init__(self, port):
        super().__init__(("127.0.0.1", port), Lane)
        self.state = LaneState()


class Lane(http.server.BaseHTTPRequestHandler):
    """The MASC server's side of the live lane."""

    server: LaneServer

    def log_message(self, format, *args):
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
        state = self.server.state
        if self.headers.get("x-lane-token") != TOKEN or self.headers.get("x-lane") != "live":
            self.send_error(403)
            return
        client = self.headers.get("x-browser-client-id")
        if self.path == "/browser-lane/ping":
            response = {"ok": True}
        elif self.path == "/browser-lane/poll":
            state.polls.append(client)
            state.polled.set()
            if state.refuse_registration:
                self.send_error(400)
                return
            try:
                response = state.commands.get(timeout=POLL_WAIT_SEC)
            except queue.Empty:
                response = {"ok": True, "empty": True}
        elif self.path == "/browser-lane/result":
            state.result_posts.append(body)
            if state.drop_every_result or state.drop_next_result.is_set():
                # The request arrived and no answer leaves: to the host this
                # is a result that may not have reached the server.
                state.drop_next_result.clear()
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            state.results.put(body)
            response = {"ok": True}
        elif self.path == "/browser-lane/disconnect":
            state.disconnected.set()
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


def start_lane(port=0):
    server = LaneServer(port)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def stop_lane(server, thread):
    server.shutdown()
    server.server_close()
    thread.join()


class FirefoxState:
    def __init__(self):
        self.methods = []
        self.sockets = []
        self.leave_on = None


class FirefoxServer(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Firefox)
        self.state = FirefoxState()


class Firefox(socketserver.BaseRequestHandler):
    """The few BiDi commands the host sends, answered over a WebSocket."""

    server: FirefoxServer

    def read_exact(self, length):
        data = bytearray()
        while len(data) < length:
            chunk = self.request.recv(length - len(data))
            if not chunk:
                raise EOFError
            data.extend(chunk)
        return bytes(data)

    def read_message(self):
        first, second = self.read_exact(2)
        length = second & 0x7F
        if length == 126:
            length, = struct.unpack(">H", self.read_exact(2))
        elif length == 127:
            length, = struct.unpack(">Q", self.read_exact(8))
        mask = self.read_exact(4)
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(self.read_exact(length)))
        if first & 0x0F == 8:
            raise EOFError
        return json.loads(payload)

    def send_message(self, value):
        data = json.dumps(value).encode()
        header = bytes([0x81])
        if len(data) < 126:
            header += bytes([len(data)])
        else:
            header += bytes([126]) + struct.pack(">H", len(data))
        self.request.sendall(header + data)

    def handle(self):
        state = self.server.state
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.request.recv(4096)
        key = next(line.split(b":", 1)[1].strip() for line in head.split(b"\r\n")
                   if line.lower().startswith(b"sec-websocket-key:"))
        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        self.request.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                             b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        state.sockets.append(self.request)
        try:
            while True:
                message = self.read_message()
                state.methods.append(message["method"])
                if message["method"] == state.leave_on:
                    # Firefox quits with this command unanswered.
                    return
                if message["method"] == "session.new":
                    result = {"sessionId": "scripted", "capabilities":
                              {"browserName": "firefox", "browserVersion": "157.0-scripted"}}
                elif message["method"] == "browsingContext.getTree":
                    result = {"contexts": [{"context": "context-1", "url": PAGE["url"]}]}
                elif message["method"] == "script.callFunction":
                    result = {"type": "success", "realm": "realm-1",
                              "result": {"type": "string", "value": json.dumps(PAGE)}}
                else:
                    self.send_message({"type": "error", "id": message["id"], "error": "unknown command"})
                    continue
                self.send_message({"type": "success", "id": message["id"], "result": result})
        except (EOFError, OSError):
            pass


class BidiHostLink(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        token = self.base / ".masc/browser-lane/token"
        token.parent.mkdir(parents=True)
        token.write_text(TOKEN)
        self.connection = self.base / ".masc/config/connection.toml"
        self.connection.parent.mkdir(parents=True)
        self.lanes = []
        self.lane, _ = self.lane_on(0)
        self.firefox = FirefoxServer()
        self.firefox_thread = threading.Thread(target=self.firefox.serve_forever, daemon=True)
        self.firefox_thread.start()
        self.log = (self.base / "host.log").open("wb")
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=EXIT_WAIT_SEC)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        self.log.close()
        for server, thread in self.lanes:
            stop_lane(server, thread)
        self.firefox.shutdown()
        self.firefox.server_close()
        self.firefox_thread.join()
        self.temporary.cleanup()

    def lane_on(self, port):
        server, thread = start_lane(port)
        self.lanes.append((server, thread))
        return server, thread

    def stop(self, server):
        entry = next(entry for entry in self.lanes if entry[0] is server)
        self.lanes.remove(entry)
        stop_lane(*entry)

    def attach(self, fixed):
        """Start the host. [fixed] pins it to the lane with --server; without
        it the workspace connection file names the port."""
        argv = [str(HOST), "--base-path", str(self.base),
                "--bidi-url", f"ws://127.0.0.1:{self.firefox.server_address[1]}/session"]
        if fixed:
            argv += ["--server", f"http://127.0.0.1:{self.lane.server_port}"]
        else:
            self.connection.write_text(f"[server]\nhttp_port = {self.lane.server_port}\n")
        # An exported MASC_HTTP_BASE_URL or MASC_HTTP_PORT outranks the file.
        env = {key: value for key, value in os.environ.items() if not key.startswith("MASC_")}
        self.process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                                        stdout=self.log, stderr=self.log)
        self.processes.append(self.process)
        self.assertTrue(self.lane.state.polled.wait(EXIT_WAIT_SEC), self.host_log())

    def host_log(self):
        self.log.flush()
        return (self.base / "host.log").read_text(errors="replace")

    def call(self, lane, verb="tabs.list"):
        ident = str(uuid.uuid4())
        lane.state.commands.put({"id": ident, "verb": verb, "args": {}})
        try:
            result = lane.state.results.get(timeout=RETRY_WAIT_SEC)
        except queue.Empty:
            self.fail("no result reached the server\n" + self.host_log())
        self.assertEqual(result["id"], ident)
        return result

    def assert_stays(self):
        time.sleep(STAYS_ALIVE_SEC)
        self.assertIsNone(self.process.poll(), self.host_log())

    def assert_ends(self, reason):
        try:
            code = self.process.wait(timeout=EXIT_WAIT_SEC)
        except subprocess.TimeoutExpired:
            self.fail("the host is still running\n" + self.host_log())
        self.assertEqual(code, 1)
        self.assertIn(reason, self.host_log())

    def test_a_server_restarted_on_its_port_finds_the_host_still_attached(self):
        self.attach(fixed=True)
        self.assertTrue(self.call(self.lane)["ok"])
        client = self.lane.state.polls[0]
        port = self.lane.server_port
        self.stop(self.lane)
        self.assert_stays()
        restarted, _ = self.lane_on(port)
        self.assertTrue(restarted.state.polled.wait(RETRY_WAIT_SEC), self.host_log())
        # The same client, and the same BiDi session: Firefox was not asked
        # for a second one.
        self.assertEqual(restarted.state.polls[0], client)
        answer = self.call(restarted)
        self.assertTrue(answer["ok"], answer)
        self.assertEqual(answer["data"][0]["url"], PAGE["url"])
        self.assertEqual(self.firefox.state.methods.count("session.new"), 1)

    def test_a_server_restarted_on_another_port_is_followed(self):
        self.attach(fixed=False)
        client = self.lane.state.polls[0]
        self.stop(self.lane)
        moved, _ = self.lane_on(0)
        self.connection.write_text(f"[server]\nhttp_port = {moved.server_port}\n")
        self.assertTrue(moved.state.polled.wait(RETRY_WAIT_SEC), self.host_log())
        self.assertEqual(moved.state.polls[0], client)
        self.assertTrue(self.call(moved)["ok"])
        self.assertEqual(self.firefox.state.methods.count("session.new"), 1)

    def test_a_result_that_may_not_have_arrived_is_sent_again_not_run_again(self):
        self.attach(fixed=True)
        self.lane.state.drop_next_result.set()
        answer = self.call(self.lane)
        self.assertTrue(answer["ok"], answer)
        # The server saw the same result twice and took it once; the browser
        # ran the command once.
        self.assertEqual(len(self.lane.state.result_posts), 2)
        self.assertEqual(self.lane.state.result_posts[0], self.lane.state.result_posts[1])
        self.assertEqual(self.firefox.state.methods.count("browsingContext.getTree"), 1)
        self.assertIsNone(self.process.poll(), self.host_log())

    def test_firefox_leaving_ends_a_host_that_waits_for_work(self):
        self.attach(fixed=True)
        self.assertTrue(self.call(self.lane)["ok"])
        for sock in self.firefox.state.sockets:
            sock.shutdown(socket.SHUT_RDWR)
        self.assert_ends("BiDi connection ended: BiDi EOF")
        # The server is told, so the dead connection is not listed.
        self.assertTrue(self.lane.state.disconnected.wait(EXIT_WAIT_SEC))

    def test_firefox_leaving_ends_a_host_that_is_sending_a_result_again(self):
        self.attach(fixed=True)
        self.lane.state.drop_every_result = True
        self.lane.state.commands.put({"id": str(uuid.uuid4()), "verb": "tabs.list", "args": {}})
        deadline = time.monotonic() + EXIT_WAIT_SEC
        while not self.lane.state.result_posts:
            self.assertLess(time.monotonic(), deadline, self.host_log())
            time.sleep(0.05)
        for sock in self.firefox.state.sockets:
            sock.shutdown(socket.SHUT_RDWR)
        self.assert_ends("BiDi connection ended: BiDi EOF")
        # The host does not wait out a server that is not answering once the
        # browser is gone, and it says what became of the result.
        self.assertIn("result not delivered: the browser connection ended before the server took the result",
                      self.host_log())

    def test_a_command_firefox_left_under_is_answered_before_the_host_ends(self):
        self.attach(fixed=True)
        self.firefox.state.leave_on = "browsingContext.getTree"
        answer = self.call(self.lane)
        self.assertFalse(answer["ok"])
        self.assertEqual(answer.get("effectPhase"), "not_started")
        self.assertEqual(answer["error"], "BiDi EOF")
        self.assert_ends("BiDi connection ended: BiDi EOF")

    def test_a_refused_registration_ends_the_host(self):
        self.lane.state.refuse_registration = True
        self.attach(fixed=True)
        self.assert_ends("native client registration rejected")
        # One refusal is the answer; the host does not ask it again.
        self.assertEqual(len(self.lane.state.polls), 1)


if __name__ == "__main__":
    unittest.main()
