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
# A poll held longer than EXIT_WAIT_SEC, for the cases that need the host to
# be inside one wait rather than between two.
HELD_POLL_SEC = 10
# A host that is going to exit does so well within this.
EXIT_WAIT_SEC = 5
# Process start, the WebSocket upgrade, session.new and the first poll.
ATTACH_WAIT_SEC = 20
# Once Firefox has left, the host gives a result already in flight
# leaving_window_sec (0.25 s, browser_host.ml) to be acknowledged. The lane
# holds its acknowledgement this long after Firefox left: inside that
# window, with room on both sides.
ACK_AFTER_LEAVING_SEC = 0.1
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
        # Take the next result as the real route does, lose the answer, and
        # refuse the same result when it comes again.
        self.take_then_drop_next_result = threading.Event()
        self.taken = set()
        # Hold the acknowledgement of the next result until the case lets go.
        self.hold_ack = threading.Event()
        self.release_ack = threading.Event()
        self.result_received = threading.Event()
        self.disconnected = threading.Event()
        self.refuse_registration = False
        self.poll_wait_sec = POLL_WAIT_SEC
        # Statuses, or bodies the host cannot read, for the next polls.
        self.poll_answers = queue.Queue()


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

    def answer(self, response):
        data = response if isinstance(response, bytes) else json.dumps(response).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def drop(self):
        # The request arrived and no answer leaves.
        self.close_connection = True
        self.connection.shutdown(socket.SHUT_RDWR)

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
                scripted = state.poll_answers.get_nowait()
            except queue.Empty:
                pass
            else:
                if isinstance(scripted, int):
                    self.send_error(scripted)
                else:
                    self.answer(scripted)
                return
            try:
                response = state.commands.get(timeout=state.poll_wait_sec)
            except queue.Empty:
                response = {"ok": True, "empty": True}
        elif self.path == "/browser-lane/result":
            state.result_posts.append(body)
            state.result_received.set()
            if body.get("id") in state.taken:
                # The real route resolves a request once; the same result
                # again finds nothing waiting for it.
                self.send_error(400)
                return
            if state.take_then_drop_next_result.is_set():
                state.take_then_drop_next_result.clear()
                state.taken.add(body.get("id"))
                state.results.put(body)
                self.drop()
                return
            if state.drop_every_result or state.drop_next_result.is_set():
                # Not taken either: to the host this is a result that may not
                # have reached the server, and here it did not.
                state.drop_next_result.clear()
                self.drop()
                return
            state.results.put(body)
            if state.hold_ack.is_set():
                state.hold_ack.clear()
                state.release_ack.wait(HELD_POLL_SEC)
            response = {"ok": True}
        elif self.path == "/browser-lane/disconnect":
            state.disconnected.set()
            response = {"ok": True}
        else:
            self.send_error(404)
            return
        self.answer(response)


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
        """Start the host and wait for its first poll. [fixed] pins it to the
        lane with --server; without it the workspace connection file names
        the port."""
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
        self.assertTrue(self.lane.state.polled.wait(ATTACH_WAIT_SEC), self.host_log())

    def firefox_leaves(self):
        for sock in self.firefox.state.sockets:
            sock.shutdown(socket.SHUT_RDWR)

    def wait_until(self, condition, what, within=EXIT_WAIT_SEC):
        deadline = time.monotonic() + within
        while not condition():
            self.assertLess(time.monotonic(), deadline, what + "\n" + self.host_log())
            time.sleep(0.02)

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
        # Nothing listens on the port while the server is down, and nothing
        # else takes it: a bound socket that does not listen refuses.
        with socket.socket() as held:
            held.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            held.bind(("127.0.0.1", port))
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

    def test_a_result_the_server_never_handled_is_sent_again_not_run_again(self):
        # The connection closed before the server handled the request at
        # all. The server is still the same one, so the result sent again is
        # the first it sees for that request.
        self.attach(fixed=True)
        self.lane.state.drop_next_result.set()
        answer = self.call(self.lane)
        self.assertTrue(answer["ok"], answer)
        # The same result arrived twice and was taken once; the browser ran
        # the command once.
        self.assertEqual(len(self.lane.state.result_posts), 2)
        self.assertEqual(self.lane.state.result_posts[0], self.lane.state.result_posts[1])
        self.assertEqual(self.firefox.state.methods.count("browsingContext.getTree"), 1)
        self.assertIsNone(self.process.poll(), self.host_log())

    def test_a_result_the_server_took_is_refused_when_sent_again(self):
        # What the real route does when only its answer was lost: the request
        # was resolved by the first attempt, so the second finds nothing
        # waiting. The host says which case this may be and goes on.
        self.attach(fixed=True)
        self.lane.state.take_then_drop_next_result.set()
        answer = self.call(self.lane)
        self.assertTrue(answer["ok"], answer)
        self.wait_until(lambda: len(self.lane.state.result_posts) == 2, "the result was not sent again",
                        within=RETRY_WAIT_SEC)
        self.assertEqual(self.firefox.state.methods.count("browsingContext.getTree"), 1)
        self.assertTrue(self.call(self.lane)["ok"], "the host did not go on to the next command")
        self.assertIn("result not delivered: the server answered the re-sent result with HTTP 400; "
                      "it may have taken an earlier attempt", self.host_log())

    def test_a_poll_the_server_fails_or_garbles_is_asked_again(self):
        # A status the server gave, then a body that is JSON and not a poll
        # answer. Each is followed by the host's pause and another poll.
        self.attach(fixed=True)
        self.lane.state.poll_answers.put(500)
        self.lane.state.poll_answers.put(b'{"ok": true}')
        self.wait_until(lambda: self.lane.state.poll_answers.qsize() == 0, "the polls were not asked again",
                        within=RETRY_WAIT_SEC)
        self.assertIsNone(self.process.poll(), self.host_log())
        answer = self.call(self.lane)
        self.assertTrue(answer["ok"], answer)
        self.assertEqual(self.firefox.state.methods.count("session.new"), 1)

    def test_firefox_leaving_ends_a_host_that_waits_for_work(self):
        # The lane holds an empty poll longer than the host is given to exit,
        # so only a host that leaves its wait can pass.
        self.lane.state.poll_wait_sec = HELD_POLL_SEC
        self.attach(fixed=True)
        self.assertTrue(self.call(self.lane)["ok"])
        polls = len(self.lane.state.polls)
        self.wait_until(lambda: len(self.lane.state.polls) > polls, "the host did not poll again")
        self.firefox_leaves()
        self.assert_ends("BiDi connection ended: BiDi EOF")
        # The server is told, so the dead connection is not listed.
        self.assertTrue(self.lane.state.disconnected.wait(EXIT_WAIT_SEC))

    def test_firefox_leaving_ends_a_host_whose_server_is_down(self):
        self.attach(fixed=True)
        self.stop(self.lane)
        self.wait_until(lambda: "poll failed" in self.host_log(), "the host did not notice the server")
        self.firefox_leaves()
        self.assert_ends("BiDi connection ended: BiDi EOF")

    def test_firefox_leaving_ends_a_host_that_is_sending_a_result_again(self):
        self.attach(fixed=True)
        self.lane.state.drop_every_result = True
        self.lane.state.commands.put({"id": str(uuid.uuid4()), "verb": "tabs.list", "args": {}})
        self.wait_until(lambda: self.lane.state.result_posts, "no result was posted")
        self.firefox_leaves()
        self.assert_ends("BiDi connection ended: BiDi EOF")
        # The pause before the next attempt is not waited out once the
        # browser is gone, and the host says what became of the result.
        self.assertIn("result not delivered: the browser connection ended before the server acknowledged the result",
                      self.host_log())

    def test_a_result_acknowledged_just_after_firefox_left_is_not_reported_lost(self):
        self.attach(fixed=True)
        self.lane.state.hold_ack.set()
        self.lane.state.commands.put({"id": str(uuid.uuid4()), "verb": "tabs.list", "args": {}})
        self.assertTrue(self.lane.state.result_received.wait(EXIT_WAIT_SEC), self.host_log())
        self.firefox_leaves()
        time.sleep(ACK_AFTER_LEAVING_SEC)
        self.lane.state.release_ack.set()
        self.assert_ends("BiDi connection ended: BiDi EOF")
        self.assertNotIn("result not delivered", self.host_log())

    def test_a_result_never_acknowledged_does_not_hold_a_host_firefox_left(self):
        self.attach(fixed=True)
        self.lane.state.hold_ack.set()
        self.lane.state.commands.put({"id": str(uuid.uuid4()), "verb": "tabs.list", "args": {}})
        self.assertTrue(self.lane.state.result_received.wait(EXIT_WAIT_SEC), self.host_log())
        self.firefox_leaves()
        try:
            self.assert_ends("BiDi connection ended: BiDi EOF")
        finally:
            self.lane.state.release_ack.set()
        self.assertIn("result not delivered: the browser connection ended before the server acknowledged the result",
                      self.host_log())

    def test_a_command_firefox_left_under_is_answered_before_the_host_ends(self):
        self.attach(fixed=True)
        self.firefox.state.leave_on = "browsingContext.getTree"
        answer = self.call(self.lane)
        self.assertFalse(answer["ok"])
        self.assertEqual(answer.get("effectPhase"), "not_started")
        self.assertEqual(answer["error"], "BiDi EOF")
        self.assert_ends("BiDi connection ended: BiDi EOF")
        self.assertEqual(len(self.lane.state.result_posts), 1, "answered once")

    def test_a_refused_registration_ends_the_host(self):
        self.lane.state.refuse_registration = True
        self.attach(fixed=True)
        self.assert_ends("native client registration rejected")
        # One refusal is the answer; the host does not ask it again.
        self.assertEqual(len(self.lane.state.polls), 1)


if __name__ == "__main__":
    unittest.main()
