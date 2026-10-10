#!/usr/bin/env python3
"""The BiDi host between a MASC server that restarts and a Firefox that leaves.

Usage: python3 test_browser_bidi_host_link.py HOST
The CI-built host runs against a local HTTP lane and a scripted BiDi endpoint;
no browser. test_browser_bidi_host.py is the one that drives a real Firefox.
"""
import base64
import errno
import fcntl
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import signal
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
# How long the scripted Firefox holds a command's answer back in the case
# that stops the host under it.
SLOW_ANSWER_SEC = 1
PAGE = {"url": "https://example.test/", "title": "Fixture", "text": "fixture text",
        "active": True, "scrollX": 0, "scrollY": 0}
# The host starts through this, so each case states the signals the host
# begins ignoring and the terminal it holds, whatever the suite inherited.
# argv: the ignored signal names, "controlling" or "none", then the host's own.
LAUNCHER = """
import fcntl, os, signal, sys, termios
ignored = sys.argv[1].split(",")
for name in ("SIGINT", "SIGTERM", "SIGHUP"):
    signal.signal(getattr(signal, name), signal.SIG_IGN if name in ignored else signal.SIG_DFL)
if sys.argv[2] == "controlling":
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
os.execv(sys.argv[3], sys.argv[3:])
"""


class LaneState:
    def __init__(self):
        self.commands = queue.Queue()
        self.results = queue.Queue()
        self.polls = []
        self.polled = threading.Event()
        self.result_posts = []
        # Results and the disconnect, in the order they reached the server.
        self.arrivals = []
        # The client ID each result and each disconnect came under.
        self.result_clients = []
        self.disconnect_clients = []
        self.drop_next_result = threading.Event()
        self.drop_every_result = False
        # Take the next result as the real route does, lose the answer, and
        # refuse the same result when it comes again.
        self.take_then_drop_next_result = threading.Event()
        self.taken = set()
        # Take the next result and answer 200 with a body that is no JSON.
        self.garble_next_ack = threading.Event()
        # Hold the acknowledgement of the next result until the case lets go.
        self.hold_ack = threading.Event()
        self.release_ack = threading.Event()
        self.result_received = threading.Event()
        self.disconnected = threading.Event()
        self.refuse_registration = False
        # Client IDs the lane has ended. A poll under one is answered as the
        # real route answers it; [retire_next_poll] ends the next poller, and
        # [retire_every_client] ends each one on its first poll.
        self.retired = set()
        self.retire_next_poll = threading.Event()
        self.retire_every_client = False
        # The lane's answer for an ID it holds as another browser.
        self.identity_changed = False
        # A refusal whose error field is a sentence, as the routes send for
        # a request they cannot read.
        self.refuse_in_prose = None
        # The first poll arrives, which is when the real lane registers its
        # ID; the answer is lost, and the lane goes on to end the ID.
        self.lose_first_answer_then_retire = False
        self.stall_next_refusal = threading.Event()
        self.release_stalled = threading.Event()
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

    def refuse(self, code):
        """A refusal as the lane's routes send it: 400 with the code."""
        data = json.dumps({"ok": False, "error": code}).encode()
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

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
            if state.identity_changed:
                self.refuse("client_identity_changed")
                return
            if state.refuse_in_prose is not None:
                self.refuse(state.refuse_in_prose)
                return
            if state.lose_first_answer_then_retire:
                state.lose_first_answer_then_retire = False
                state.retired.add(client)
                self.drop()
                return
            if state.retire_every_client or state.retire_next_poll.is_set():
                state.retire_next_poll.clear()
                state.retired.add(client)
            if client in state.retired:
                self.refuse("client_disconnected")
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
            state.result_clients.append(client)
            state.arrivals.append(("result", body.get("id")))
            if state.stall_next_refusal.is_set():
                # A refusal whose status arrives and whose body never does.
                state.stall_next_refusal.clear()
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", "64")
                self.end_headers()
                self.wfile.flush()
                state.release_stalled.wait(HELD_POLL_SEC)
                self.close_connection = True
                return
            state.result_received.set()
            if body.get("id") in state.taken:
                # The real route resolves a request once; the same result
                # again finds nothing waiting for it.
                self.refuse("request_not_owned_by_client")
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
            if state.garble_next_ack.is_set():
                state.garble_next_ack.clear()
                data = b"<html>taken</html>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if state.hold_ack.is_set():
                state.hold_ack.clear()
                state.release_ack.wait(HELD_POLL_SEC)
            response = {"ok": True}
        elif self.path == "/browser-lane/disconnect":
            state.arrivals.append(("disconnect", None))
            state.disconnect_clients.append(client)
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
        self.slow_on = None
        self.silent_on = None
        # The error Firefox answers session.new with, when it gives no
        # session. "session not created" is what it says while it holds one.
        self.refuses_the_session_with = None
        self.browser_name = "firefox"
        self.answers_session_end = True
        self.refuses_session_end_with = None
        self.answers_the_upgrade = True
        # Bytes something that is no Firefox says in place of the upgrade.
        self.says_instead = None
        self.connected = threading.Event()
        self.connections = 0


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
        state.connections += 1
        state.connected.set()
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.request.recv(4096)
        if state.says_instead is not None:
            self.request.sendall(state.says_instead)
            return
        if not state.answers_the_upgrade:
            # Something listens here and never speaks WebSocket.
            while self.request.recv(4096):
                pass
            return
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
                if message["method"] == state.slow_on:
                    time.sleep(SLOW_ANSWER_SEC)
                if message["method"] == state.silent_on:
                    continue
                if message["method"] == "session.end":
                    if not state.answers_session_end:
                        continue
                    if state.refuses_session_end_with is not None:
                        self.send_message({"type": "error", "id": message["id"],
                                           "error": state.refuses_session_end_with,
                                           "message": "scripted session end refusal"})
                        continue
                    # Firefox answers, then closes the socket itself.
                    self.send_message({"type": "success", "id": message["id"], "result": {}})
                    return
                if message["method"] == "session.new":
                    if state.refuses_the_session_with is not None:
                        self.send_message({"type": "error", "id": message["id"],
                                           "error": state.refuses_the_session_with,
                                           "message": "said by the scripted Firefox"})
                        continue
                    result = {"sessionId": "scripted", "capabilities":
                              {"browserName": state.browser_name, "browserVersion": "157.0-scripted"}}
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

    def start(self, fixed, terminal=None, ignoring=(), query=""):
        """Start the host. [fixed] pins it to the lane with --server; without
        it the workspace connection file names the port. [terminal] is a pty
        slave the host takes as its controlling terminal and writes its log
        to; without one the log goes to a file. [ignoring] names the signals
        it is started ignoring, as nohup does for SIGHUP. [query] is added to
        the BiDi address."""
        argv = [str(HOST), "--base-path", str(self.base),
                "--bidi-url", f"ws://127.0.0.1:{self.firefox.server_address[1]}/session{query}"]
        if fixed:
            argv += ["--server", f"http://127.0.0.1:{self.lane.server_port}"]
        else:
            self.connection.write_text(f"[server]\nhttp_port = {self.lane.server_port}\n")
        # An exported MASC_HTTP_BASE_URL or MASC_HTTP_PORT outranks the file.
        env = {key: value for key, value in os.environ.items() if not key.startswith("MASC_")}
        launch = [sys.executable, "-c", LAUNCHER, ",".join(ignoring)]
        if terminal is None:
            self.process = subprocess.Popen(launch + ["none"] + argv, env=env, stdin=subprocess.DEVNULL,
                                            stdout=self.log, stderr=self.log)
        else:
            # A session of its own whose controlling terminal is the pty, as
            # for a host started from a terminal window.
            self.process = subprocess.Popen(launch + ["controlling"] + argv, env=env,
                                            stdin=terminal, stdout=terminal, stderr=terminal)
        self.processes.append(self.process)

    def attach(self, fixed, terminal=None, ignoring=()):
        self.start(fixed, terminal, ignoring)
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

    def record(self):
        """What the host wrote about itself, or None before it wrote any."""
        path = self.base / ".masc/browser-lane/bidi-host.json"
        return json.loads(path.read_text()) if path.exists() else None

    def record_lock_held(self):
        """Whether a process other than this one holds the host's lock."""
        with (self.base / ".masc/browser-lane/bidi-host.lock").open("r+b") as lock:
            try:
                fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                self.assertIn(error.errno, (errno.EACCES, errno.EAGAIN))
                return True
            return False

    def record_bytes(self):
        return (self.base / ".masc/browser-lane/bidi-host.json").read_bytes()

    def unacknowledged(self):
        """The results the host holds no acknowledgement for, oldest first."""
        return self.record()["unacknowledged"]

    def stop_with_an_ack_held(self, command):
        """Give the host [command], hold the acknowledgement of its result,
        and stop the host while it waits for it."""
        self.lane.state.hold_ack.set()
        self.lane.state.commands.put(command)
        self.assertTrue(self.lane.state.result_received.wait(EXIT_WAIT_SEC), self.host_log())
        self.process.send_signal(signal.SIGTERM)
        try:
            self.assert_ends("stopped by SIGTERM", code=0)
        finally:
            self.lane.state.release_ack.set()

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

    def assert_ends(self, reason, code=1, within=EXIT_WAIT_SEC):
        try:
            exited = self.process.wait(timeout=within)
        except subprocess.TimeoutExpired:
            self.fail("the host is still running\n" + self.host_log())
        self.assertEqual(exited, code, self.host_log())
        self.assertIn(reason, self.host_log())

    def assert_session_ended_last(self):
        self.assertEqual(self.firefox.state.methods.count("session.end"), 1, self.firefox.state.methods)
        self.assertEqual(self.firefox.state.methods[-1], "session.end")

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
        self.assertIn("result not delivered: the server answered the re-sent result with "
                      "HTTP 400, request_not_owned_by_client; it may have taken an earlier attempt",
                      self.host_log())

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
        # Over a closed socket no session can be ended; the host says so.
        self.assertIn("the BiDi session was not ended (BiDi EOF)", self.host_log())

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
        # A host that ends by itself leaves no session in Firefox either.
        self.assert_session_ended_last()

    def test_a_session_firefox_refuses_leaves_none_to_end(self):
        # What a second host meets while another holds the one session.
        self.firefox.state.refuses_the_session_with = "session not created"
        self.start(fixed=True)
        self.assert_ends("BiDi command rejected: session not created", within=ATTACH_WAIT_SEC)
        self.assertEqual(self.firefox.state.methods, ["session.new"])
        self.assertNotIn("was not ended", self.host_log())
        self.assertEqual(self.lane.state.polls, [])

    def test_a_session_is_ended_when_the_host_turns_its_browser_down(self):
        # The session exists by the time the host learns what answered.
        self.firefox.state.browser_name = "chromium"
        self.start(fixed=True)
        self.assert_ends("BiDi peer must be Firefox", within=ATTACH_WAIT_SEC)
        self.assertEqual(self.firefox.state.methods, ["session.new", "session.end"])
        self.assertEqual(self.lane.state.polls, [])
        # It was given a session and ended it: nothing is left, and nothing
        # was refused.
        self.assertEqual(self.record()["ended"]["session_in_firefox"], "none")

    def test_a_host_the_server_retired_registers_again_as_a_new_client(self):
        # What a host meets after its laptop slept: the server ended the
        # connection for want of a poll, and nothing starts another host.
        self.attach(fixed=True)
        self.assertTrue(self.call(self.lane)["ok"])
        first = self.lane.state.polls[0]
        self.lane.state.retire_next_poll.set()
        self.wait_until(lambda: self.lane.state.polls[-1] != first, "the host did not register again",
                        within=RETRY_WAIT_SEC)
        polls = list(self.lane.state.polls)
        again = polls[-1]
        # The ended ID was asked about once more, then only the new one.
        self.assertEqual(polls, [first] * polls.index(again) + [again] * polls.count(again))
        answer = self.call(self.lane)
        self.assertTrue(answer["ok"], answer)
        self.assertEqual(answer["data"][0]["url"], PAGE["url"])
        self.assertEqual(self.lane.state.result_clients[-1], again, "the result came under the ended ID")
        self.assertEqual(self.record()["client_id"], again)
        self.assertIn(f"registering again as client {again}", self.host_log())
        # The same Firefox session throughout, and the host is still there.
        self.assertEqual(self.firefox.state.methods.count("session.new"), 1)
        self.assertNotIn("session.end", self.firefox.state.methods)
        self.assertIsNone(self.process.poll(), self.host_log())
        # It leaves as the client it now is.
        self.process.send_signal(signal.SIGTERM)
        self.assert_ends("stopped by SIGTERM", code=0)
        self.assertTrue(self.lane.state.disconnected.wait(EXIT_WAIT_SEC))
        self.assertEqual(self.lane.state.disconnect_clients, [again])

    def test_a_client_whose_first_answer_was_lost_is_registered_again(self):
        # The lane registers an ID when its poll arrives. This ID's answer
        # never reached the host, the lane ended the ID for its silence, and
        # the host's next poll is told so. A new ID is served.
        self.lane.state.lose_first_answer_then_retire = True
        self.attach(fixed=True)
        self.wait_until(lambda: len(set(self.lane.state.polls)) == 2, "the host did not register again",
                        within=RETRY_WAIT_SEC)
        polls = list(self.lane.state.polls)
        self.assertEqual(polls[:2], [polls[0], polls[0]], "the lost poll, then the one told it was ended")
        self.assertTrue(self.call(self.lane)["ok"])
        self.assertIsNone(self.process.poll(), self.host_log())
        self.assertEqual(self.firefox.state.methods.count("session.new"), 1)

    def test_a_refusal_whose_body_never_arrives_is_still_the_servers_answer(self):
        # The status says the server took the result and refused it. Waiting
        # out a body that does not come would turn that into "no answer" and
        # send the result again.
        self.attach(fixed=True)
        self.lane.state.stall_next_refusal.set()
        self.lane.state.commands.put({"id": str(uuid.uuid4()), "verb": "tabs.list", "args": {}})
        try:
            self.wait_until(
                lambda: "the server received the result and did not accept it (HTTP 400)" in self.host_log(),
                "the host waited on the refusal's body")
        finally:
            self.lane.state.release_stalled.set()
        self.assertTrue(self.call(self.lane)["ok"], "the host did not go on to the next command")
        self.assertEqual(len(self.lane.state.result_posts), 2, "one result for each command, none sent again")

    def test_a_client_the_server_holds_as_another_browser_ends_the_host(self):
        self.lane.state.identity_changed = True
        self.attach(fixed=True)
        self.assert_ends("native client registration rejected (client_identity_changed)")
        # The same answer would come again, so it is not asked again.
        self.assertEqual(len(self.lane.state.polls), 1)
        self.assert_session_ended_last()

    def test_a_refusal_in_prose_is_not_carried_into_the_log(self):
        # The host's log takes a code from the server, never a sentence that
        # could quote a request.
        self.lane.state.refuse_in_prose = "body must be a JSON object, got: page text"
        self.attach(fixed=True)
        self.assert_ends("native client registration rejected")
        self.assertNotIn("page text", self.host_log())
        self.assertNotIn("native client registration rejected (", self.host_log())
        self.assertEqual(len(self.lane.state.polls), 1)

    def test_a_server_that_ends_a_client_on_its_first_poll_ends_the_host(self):
        # An ID called ended on the first poll it ever sent did not fall
        # silent. A host that took another one would be told the same,
        # without end.
        self.lane.state.retire_every_client = True
        self.attach(fixed=True)
        self.assert_ends("native client registration rejected (the server calls a client ID ended on its first poll)")
        self.assertEqual(len(set(self.lane.state.polls)), 1)
        self.assert_session_ended_last()

    def test_a_server_that_ends_the_new_client_too_ends_the_host(self):
        self.attach(fixed=True)
        self.assertTrue(self.call(self.lane)["ok"])
        self.lane.state.retire_every_client = True
        self.assert_ends("native client registration rejected (the server calls a client ID ended on its first poll)",
                         within=RETRY_WAIT_SEC)
        # The one it served, and the one it took after that.
        self.assertEqual(len(set(self.lane.state.polls)), 2)
        self.assert_session_ended_last()

    def test_an_attached_host_says_who_it_is_and_holds_its_lock(self):
        self.attach(fixed=True)
        self.assertTrue(self.call(self.lane)["ok"])
        record = self.record()
        self.assertEqual(sorted(record), ["attached_at", "bidi_url", "client_id", "ended", "pid", "schema",
                                          "started_at", "unacknowledged"])
        self.assertEqual(record["unacknowledged"], [])
        self.assertEqual(record["pid"], self.process.pid)
        self.assertEqual(record["client_id"], self.lane.state.polls[0])
        self.assertEqual(record["bidi_url"], f"ws://127.0.0.1:{self.firefox.server_address[1]}/session")
        self.assertIsNotNone(record["attached_at"])
        self.assertIsNone(record["ended"])
        self.assertTrue(self.record_lock_held())
        # Nothing of the lane's secret or of a page is in it.
        self.assertNotIn(TOKEN, json.dumps(record))
        self.assertNotIn(PAGE["text"], json.dumps(record))

    def test_a_stopped_host_leaves_why_it_ended(self):
        self.attach(fixed=True)
        self.process.send_signal(signal.SIGTERM)
        self.assert_ends("stopped by SIGTERM", code=0)
        record = self.record()
        self.assertEqual(sorted(record["ended"]), ["at", "because", "reason", "session_in_firefox"])
        self.assertEqual(record["ended"]["because"], {"kind": "reason_only"})
        self.assertEqual(record["ended"]["reason"], "stopped by SIGTERM")
        self.assertEqual(record["ended"]["session_in_firefox"], "none")
        self.assertIsNotNone(record["attached_at"])
        self.assertFalse(self.record_lock_held())

    def test_a_killed_host_leaves_no_ending_and_no_lock(self):
        # What a reader takes for a host that died: it never said it ended,
        # and nothing holds its lock.
        self.attach(fixed=True)
        self.process.kill()
        self.process.wait(timeout=EXIT_WAIT_SEC)
        self.assertIsNone(self.record()["ended"])
        self.assertFalse(self.record_lock_held())

    def test_a_second_host_for_the_workspace_is_refused_and_changes_nothing(self):
        self.attach(fixed=True)
        first, record = self.process, self.record()
        self.start(fixed=True)
        self.assert_ends(f"another BiDi host (pid {first.pid}) is running for this workspace; stop it first")
        # It never reached for Firefox, and the first one's record stands.
        self.assertEqual(self.firefox.state.connections, 1)
        self.assertEqual(self.firefox.state.methods.count("session.new"), 1)
        self.assertEqual(self.record(), record)
        self.process = first
        self.assertTrue(self.record_lock_held())
        self.assertTrue(self.call(self.lane)["ok"])

    def test_a_host_firefox_refused_leaves_that_as_its_ending(self):
        self.firefox.state.refuses_the_session_with = "session not created"
        self.start(fixed=True)
        self.assert_ends("BiDi command rejected: session not created", within=ATTACH_WAIT_SEC)
        record = self.record()
        self.assertEqual(record["ended"]["reason"], "BiDi command rejected: session not created")
        self.assertIsNone(record["attached_at"])
        # Firefox says this while it holds a session that is not this host's.
        # That session was there when this host asked, so the record says
        # which refusal it was.
        self.assertEqual(record["ended"]["session_in_firefox"], "refused")

    def test_a_session_firefox_did_not_start_is_not_one_it_holds(self):
        # Any other error is Firefox failing to start a session. It says
        # nothing of one that is there, and this host got none.
        self.firefox.state.refuses_the_session_with = "unknown error"
        self.start(fixed=True)
        self.assert_ends("BiDi command rejected: unknown error", within=ATTACH_WAIT_SEC)
        record = self.record()
        self.assertEqual(record["ended"]["reason"], "BiDi command rejected: unknown error")
        self.assertEqual(record["ended"]["session_in_firefox"], "none")

    def test_a_session_left_in_firefox_is_in_the_ending(self):
        self.firefox.state.answers_session_end = False
        self.attach(fixed=True)
        self.process.send_signal(signal.SIGTERM)
        self.assert_ends("stopped with its BiDi session left in Firefox", within=2 * EXIT_WAIT_SEC)
        ending = self.record()["ended"]
        self.assertEqual(ending["session_in_firefox"], "left")
        self.assertEqual(ending["reason"], "stopped with its BiDi session left in Firefox")

    def test_a_host_whose_firefox_left_does_not_claim_a_session_is_left(self):
        # Over a closed socket the host could not ask. A Firefox that quit
        # holds no session, so the record says the host does not know.
        self.attach(fixed=True)
        self.assertTrue(self.call(self.lane)["ok"])
        self.firefox_leaves()
        self.assert_ends("BiDi connection ended: BiDi EOF")
        ending = self.record()["ended"]
        self.assertEqual(ending["reason"], "BiDi connection ended: BiDi EOF")
        self.assertEqual(ending["session_in_firefox"], "unknown")

    def test_a_result_the_server_did_not_acknowledge_is_listed(self):
        # The lane here takes the result, as the real route does before it
        # answers, and the answer never comes. The host cannot tell that from
        # a result that was lost, and says so.
        self.attach(fixed=True)
        ident = str(uuid.uuid4())
        self.stop_with_an_ack_held({"id": ident, "verb": "tabs.list", "args": {}})
        listed = self.unacknowledged()
        self.assertEqual(len(listed), 1, listed)
        self.assertEqual(sorted(listed[0]), ["at", "cause", "outcome", "request_id", "verb"])
        self.assertEqual(listed[0]["request_id"], ident)
        self.assertEqual(listed[0]["verb"], "tabs.list")
        self.assertEqual(listed[0]["outcome"], "succeeded")
        self.assertEqual(listed[0]["cause"], "unconfirmed")
        self.assertNotIn(PAGE["url"], json.dumps(self.record()))

    def test_a_result_the_server_refused_is_listed_as_refused(self):
        # The server answers the first attempt and does not accept it: this
        # one it does not have. The host goes on.
        self.attach(fixed=True)
        ident = str(uuid.uuid4())
        self.lane.state.taken.add(ident)
        self.lane.state.commands.put({"id": ident, "verb": "tabs.list", "args": {}})
        self.wait_until(lambda: len(self.unacknowledged()) == 1, "the refused result was not listed")
        listed = self.unacknowledged()[0]
        self.assertEqual((listed["request_id"], listed["outcome"], listed["cause"]), (ident, "succeeded", "refused"))
        self.assertTrue(self.call(self.lane)["ok"], "the host did not go on to the next command")
        self.assertIsNone(self.record()["ended"])

    def test_an_answer_the_host_cannot_read_is_not_the_servers_refusal(self):
        # The route answers a result after it took it. An answer that is no
        # acknowledgement the host can read says nothing against that.
        self.attach(fixed=True)
        self.lane.state.garble_next_ack.set()
        ident = str(uuid.uuid4())
        self.lane.state.commands.put({"id": ident, "verb": "tabs.list", "args": {}})
        self.wait_until(lambda: len(self.unacknowledged()) == 1, "the result was not listed")
        listed = self.unacknowledged()[0]
        self.assertEqual((listed["request_id"], listed["outcome"], listed["cause"]),
                         (ident, "succeeded", "unconfirmed"))
        self.assertEqual(self.lane.state.results.get(timeout=EXIT_WAIT_SEC)["id"], ident)
        self.assertTrue(self.call(self.lane)["ok"], "the host did not go on to the next command")

    def test_a_result_that_cannot_be_sent_again_may_have_arrived_the_first_time(self):
        # The first attempt reached the server, which took it; its answer was
        # lost. Before the host sends it again the lane token is unreadable,
        # so nothing more is sent. The record does not say the server lacks
        # the result: one attempt went out.
        self.attach(fixed=True)
        token = self.base / ".masc/browser-lane/token"
        self.lane.state.take_then_drop_next_result.set()
        ident = str(uuid.uuid4())
        self.lane.state.commands.put({"id": ident, "verb": "tabs.list", "args": {}})
        self.assertTrue(self.lane.state.result_received.wait(EXIT_WAIT_SEC), self.host_log())
        token.write_text("")
        try:
            self.wait_until(lambda: len(self.unacknowledged()) == 1, "the result was not listed",
                            within=RETRY_WAIT_SEC)
        finally:
            token.write_text(TOKEN)
        listed = self.unacknowledged()[0]
        self.assertEqual((listed["request_id"], listed["outcome"], listed["cause"]),
                         (ident, "succeeded", "unconfirmed"))
        self.assertEqual(len(self.lane.state.result_posts), 1)
        # The host writes its record before it logs, so the record can be
        # read a moment before the line is.
        said = "so the result was not sent again; the server may have taken an earlier attempt"
        self.wait_until(lambda: said in self.host_log(), "the host did not log why it stopped sending")
        # The server does have it: the one attempt arrived.
        self.assertEqual(self.lane.state.results.get(timeout=EXIT_WAIT_SEC)["id"], ident)
        self.assertTrue(self.call(self.lane)["ok"], "the host did not go on once it could read the token")

    def test_a_request_the_host_cannot_name_is_listed_without_the_servers_words(self):
        # A verb this host does not know and an ID that is no UUID are the
        # server's own text. The host answers them; its record keeps neither.
        self.attach(fixed=True)
        self.stop_with_an_ack_held({"id": "https://example.test/private", "verb": "page.teleport",
                                    "args": {}})
        answered = self.lane.state.results.get(timeout=EXIT_WAIT_SEC)
        self.assertEqual((answered["id"], answered["ok"]), ("https://example.test/private", False))
        listed = self.unacknowledged()
        self.assertEqual(len(listed), 1, listed)
        self.assertIsNone(listed[0]["request_id"])
        self.assertIsNone(listed[0]["verb"])
        self.assertEqual((listed[0]["outcome"], listed[0]["cause"]), ("not_started", "unconfirmed"))
        self.assertNotIn(b"teleport", self.record_bytes())
        self.assertNotIn(b"example.test", self.record_bytes())

    def test_what_something_that_is_no_firefox_said_is_recorded_as_ascii(self):
        # The host quotes the first line it was answered with. Whatever bytes
        # those were, the record is text any reader loads.
        self.firefox.state.says_instead = b"\xff\xfe\x00\x1b[31m no WebSocket here\r\n\r\n"
        self.start(fixed=True)
        self.assert_ends("BiDi connection", within=ATTACH_WAIT_SEC)
        self.assertTrue(self.record_bytes().isascii(), self.record_bytes())
        ending = self.record()["ended"]
        self.assertIn("\\xFF\\xFE\\x00\\x1B[31m no WebSocket here", ending["reason"])
        logged = (self.base / "host.log").read_bytes()
        self.assertIn(b"\\xFF\\xFE\\x00\\x1B[31m no WebSocket here", logged)
        self.assertTrue(all(byte == 10 or 32 <= byte <= 126 for byte in logged), logged)
        self.assertIsNone(self.record()["attached_at"])

    def test_the_address_is_recorded_without_its_query(self):
        self.start(fixed=True, query="?token=not-for-the-record")
        self.assertTrue(self.lane.state.polled.wait(ATTACH_WAIT_SEC), self.host_log())
        self.assertEqual(self.record()["bidi_url"], f"ws://127.0.0.1:{self.firefox.server_address[1]}/session")
        self.assertNotIn(b"not-for-the-record", self.record_bytes())

    def test_the_next_host_replaces_the_record_of_the_last(self):
        self.attach(fixed=True)
        self.stop_with_an_ack_held({"id": str(uuid.uuid4()), "verb": "tabs.list", "args": {}})
        self.assertEqual(len(self.unacknowledged()), 1)
        last = self.process.pid
        self.lane.state.polled.clear()
        self.attach(fixed=True)
        record = self.record()
        self.assertEqual(record["pid"], self.process.pid)
        self.assertNotEqual(record["pid"], last)
        self.assertIsNone(record["ended"])
        self.assertEqual(record["unacknowledged"], [])

    def stopped_by(self, stop):
        self.attach(fixed=True)
        self.assertTrue(self.call(self.lane)["ok"])
        self.process.send_signal(stop)
        self.assert_ends(f"stopped by {stop.name}", code=0)
        self.assertIn(f"{stop.name} received", self.host_log())
        # The server is told and Firefox is left free for the next host.
        self.assertTrue(self.lane.state.disconnected.wait(EXIT_WAIT_SEC))
        self.assert_session_ended_last()
        self.assertNotIn("was not ended", self.host_log())

    def test_sigterm_stops_the_host_and_ends_its_session(self):
        self.stopped_by(signal.SIGTERM)

    def test_ctrl_c_stops_the_host_and_ends_its_session(self):
        self.stopped_by(signal.SIGINT)

    def test_a_hangup_stops_the_host_and_ends_its_session(self):
        self.stopped_by(signal.SIGHUP)

    def test_a_host_started_ignoring_the_hangup_stays_through_it(self):
        # nohup starts the host with SIGHUP ignored so that it outlives its
        # terminal. The host does not take that back.
        self.attach(fixed=True, ignoring=("SIGHUP",))
        self.process.send_signal(signal.SIGHUP)
        self.assert_stays()
        self.assertTrue(self.call(self.lane)["ok"])
        self.assertNotIn("session.end", self.firefox.state.methods)
        self.process.send_signal(signal.SIGTERM)
        self.assert_ends("stopped by SIGTERM", code=0)
        self.assert_session_ended_last()

    def test_a_closed_terminal_stops_the_host_and_ends_its_session(self):
        # The host runs in a terminal and the window is closed. Its log went
        # to that terminal, so every later write to it fails; the host still
        # tells the server and ends its session.
        controller, terminal = os.openpty()
        try:
            self.attach(fixed=True, terminal=terminal)
        finally:
            os.close(terminal)
        self.assertTrue(self.call(self.lane)["ok"])
        os.close(controller)
        try:
            exited = self.process.wait(timeout=EXIT_WAIT_SEC)
        except subprocess.TimeoutExpired:
            self.fail("the host outlived its terminal")
        self.assertEqual(exited, 0)
        self.assertTrue(self.lane.state.disconnected.wait(EXIT_WAIT_SEC))
        self.assert_session_ended_last()

    def test_a_second_ctrl_c_ends_the_host_at_once(self):
        # Firefox never answers the command, so the host that was asked to
        # stop is waiting for it. The operator does not wait with it.
        self.attach(fixed=True)
        self.firefox.state.silent_on = "browsingContext.getTree"
        self.lane.state.commands.put({"id": str(uuid.uuid4()), "verb": "tabs.list", "args": {}})
        self.wait_until(lambda: "browsingContext.getTree" in self.firefox.state.methods,
                        "the command did not reach Firefox")
        self.process.send_signal(signal.SIGINT)
        # The first one has to be taken before the second is sent: two that
        # are pending together are delivered as one.
        self.wait_until(lambda: "SIGINT received" in self.host_log(), "the first Ctrl-C was not taken")
        self.assertIn("A second one ends the host at once", self.host_log())
        self.process.send_signal(signal.SIGINT)
        try:
            exited = self.process.wait(timeout=EXIT_WAIT_SEC)
        except subprocess.TimeoutExpired:
            self.fail("the host is still running\n" + self.host_log())
        self.assertEqual(exited, -signal.SIGINT, self.host_log())
        # Its price, which the first one's log line names: the session stays.
        self.assertNotIn("session.end", self.firefox.state.methods)

    def test_a_stop_under_a_command_answers_it_first(self):
        self.attach(fixed=True)
        self.firefox.state.slow_on = "browsingContext.getTree"
        ident = str(uuid.uuid4())
        self.lane.state.commands.put({"id": ident, "verb": "tabs.list", "args": {}})
        self.wait_until(lambda: "browsingContext.getTree" in self.firefox.state.methods,
                        "the command did not reach Firefox")
        self.process.send_signal(signal.SIGTERM)
        answer = self.lane.state.results.get(timeout=EXIT_WAIT_SEC)
        self.assertEqual(answer["id"], ident)
        self.assertTrue(answer["ok"], answer)
        self.assert_ends("stopped by SIGTERM", code=0)
        # Answered once, the server told after that, and the session ended.
        self.assertTrue(self.lane.state.disconnected.wait(EXIT_WAIT_SEC))
        self.assertEqual(self.lane.state.arrivals, [("result", ident), ("disconnect", None)])
        self.assert_session_ended_last()

    def test_a_stop_while_a_result_is_unacknowledged_does_not_wait_for_it(self):
        self.attach(fixed=True)
        self.lane.state.hold_ack.set()
        self.lane.state.commands.put({"id": str(uuid.uuid4()), "verb": "tabs.list", "args": {}})
        self.assertTrue(self.lane.state.result_received.wait(EXIT_WAIT_SEC), self.host_log())
        self.process.send_signal(signal.SIGTERM)
        try:
            self.assert_ends("stopped by SIGTERM", code=0)
        finally:
            self.lane.state.release_ack.set()
        self.assertIn("result not delivered: the host was stopped before the server acknowledged the result",
                      self.host_log())
        self.assert_session_ended_last()

    def test_session_end_refusal_cannot_write_control_bytes_to_the_log(self):
        self.firefox.state.refuses_session_end_with = "session-end-\x1b[31m\x00\nrefused"
        self.attach(fixed=True)
        self.process.send_signal(signal.SIGTERM)
        self.assert_ends("stopped with its BiDi session left in Firefox", code=1)
        self.assert_session_ended_last()
        logged = (self.base / "host.log").read_bytes()
        self.assertIn(b"session-end-\\x1B[31m\\x00\\x0Arefused", logged)
        self.assertTrue(all(byte == 10 or 32 <= byte <= 126 for byte in logged), logged)
        self.assertEqual(self.record()["ended"]["session_in_firefox"], "left")

    def test_a_stop_that_leaves_its_session_is_an_error(self):
        self.firefox.state.answers_session_end = False
        self.attach(fixed=True)
        self.process.send_signal(signal.SIGTERM)
        # Exit 0 would say the same Firefox takes the next host. The host
        # waits two seconds for the answer before it gives up.
        self.assert_ends("the BiDi session was not ended (no answer to session.end in time)", code=1,
                         within=2 * EXIT_WAIT_SEC)
        self.assertIn("restart it before attaching again", self.host_log())
        self.assertIn("stopped with its BiDi session left in Firefox", self.host_log())
        self.assertTrue(self.lane.state.disconnected.wait(EXIT_WAIT_SEC))

    def test_a_stop_before_the_host_is_attached_abandons_the_attempt(self):
        self.firefox.state.answers_the_upgrade = False
        self.start(fixed=True)
        self.assertTrue(self.firefox.state.connected.wait(ATTACH_WAIT_SEC), self.host_log())
        self.process.send_signal(signal.SIGTERM)
        self.assert_ends("stopped by SIGTERM before it was attached", code=0)
        self.assertEqual(self.host_log().count("before it was attached"), 1, self.host_log())
        self.assertEqual(self.lane.state.polls, [])
        self.assertEqual(self.firefox.state.methods, [])

    def test_a_stop_while_the_session_is_being_asked_for_ends_that_session(self):
        # The WebSocket is up and session.new is written: Firefox may hold
        # the session whatever happens next, so the host waits for the answer
        # and ends it. It never registers with the server.
        self.firefox.state.slow_on = "session.new"
        self.start(fixed=True)
        self.wait_until(lambda: "session.new" in self.firefox.state.methods,
                        "the host did not ask for a session", within=ATTACH_WAIT_SEC)
        self.process.send_signal(signal.SIGTERM)
        self.assert_ends("stopped by SIGTERM", code=0)
        self.assertNotIn("before it was attached", self.host_log())
        self.assertEqual(self.firefox.state.methods, ["session.new", "session.end"])
        self.assertEqual(self.lane.state.polls, [])


if __name__ == "__main__":
    unittest.main()
