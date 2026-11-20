#!/usr/bin/env python3
"""masc-tui attached to the account server of a multi-account installation.

The fixture answers /health as the account server does and every other
request with the plain 404 the account server gives. The TUI is started on
it in a terminal; the fixture records the requests it sends, and the
navigation trace (MASC_TUI_NAV_TRACE) records which screen each frame drew
and which keys changed nothing. The screen's words are not read.

The account server is asked for nothing but the probe, its screen covers the
others and takes the operator keys. The control is the same fixture answering
as a masc server of the workspace: the TUI reads surfaces from it and Tab
changes its screen, so a TUI that asked nothing, or a key that did nothing
anywhere, would not pass.

Two more cases change what the fixture answers while the TUI runs: the
account server stops answering for a while and comes back, and a masc server
is replaced by the account server. In both the TUI must draw the account
server's screen again, and from then on ask for /health alone.
"""

import fcntl
import http.server
import json
import os
import pathlib
import pty
import select
import signal
import socketserver
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest
import urllib.parse
from typing import Callable, Literal, cast

Mode = Literal["account", "masc", "down"]
VERSION = "0.0.0-account-fixture"
PREFERENCES = ("GET", "/api/v1/tui/preferences")
HEALTH = ("GET", "/health")
# The surface key of the account server's screen in the navigation trace.
ACCOUNT_SCREEN = "account-server"
# Longer than the TUI's reconnect interval (two seconds), so a reconnect loop
# cannot fit between two requests.
QUIET_S = 5.0
# How long the TUI is watched after it drew the account server's screen: past
# the first steps of a doubling backoff (2, 4, 8 seconds).
WATCH_S = 8.0
# How long a person looks at a new screen before pressing a key. A key that
# arrives while a new screen is being presented is turned away with a notice
# (Masc_tui_presented's barrier), and the trace line of that screen can be
# read before the barrier is decided.
LOOK_S = 1.0
# The keys an operator screen acts on. On the account server's screen each
# changes nothing.
OPERATOR_KEYS = (b"\t", b"?", b"s", b"a", b"i", b"/")
Request = tuple[str, str]


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, base: str, mode: Mode) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.base = os.path.realpath(base)
        self.lock = threading.Lock()
        self.mode: Mode = mode
        self.requests: list[Request] = []

    def set_mode(self, mode: Mode) -> None:
        with self.lock:
            self.mode = mode

    def seen(self) -> list[Request]:
        with self.lock:
            return list(self.requests)

    def count(self) -> int:
        with self.lock:
            return len(self.requests)

    def since(self, index: int) -> list[Request]:
        with self.lock:
            return self.requests[index:]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *_args: object) -> None:
        pass

    def handle(self) -> None:
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send(self, status: int, content_type: str, data: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def note(self) -> tuple[Request, Mode]:
        """Record the request and read the mode under one lock, so a request
        counted after a mode change is answered in the new mode."""
        server = cast(Server, self.server)
        request = (self.command, urllib.parse.urlsplit(self.path).path)
        with server.lock:
            server.requests.append(request)
            return request, server.mode

    def answer(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        request, mode = self.note()
        server = cast(Server, self.server)
        if request != HEALTH:
            # The account server's own answer to a route it does not serve.
            self.send(404, "text/plain", b"404 Not Found")
        elif mode == "down":
            self.send(503, "text/plain", b"503 Service Unavailable")
        elif mode == "account":
            # The whole answer of Server_accounts.health.
            body = {"server": "masc", "version": VERSION, "account_mode": "Multi_account"}
            self.send(200, "application/json", json.dumps(body).encode())
        else:
            body = {
                "server": "masc",
                "version": VERSION,
                "status": "ok",
                "startup": {"state_ready": True},
                "paths": {
                    "effective_base_path": server.base,
                    "effective_masc_root": server.base + "/.masc",
                },
            }
            self.send(200, "application/json", json.dumps(body).encode())

    do_GET = answer
    do_POST = answer
    do_PUT = answer
    do_PATCH = answer
    do_DELETE = answer


class Session:
    """The TUI in a terminal, attached to the fixture."""

    def __init__(self, test: unittest.TestCase, server: Server, master: int,
                 process: subprocess.Popen[bytes], trace: pathlib.Path) -> None:
        self.test = test
        self.server = server
        self.master = master
        self.process = process
        self.trace = trace
        self.last_request_at = time.monotonic()
        self.last_count = 0

    def events(self) -> list[dict[str, object]]:
        try:
            text = self.trace.read_text(encoding="utf-8")
        except FileNotFoundError:
            return []
        events: list[dict[str, object]] = []
        for line in text.splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                # The writer may be in the middle of this line.
                break
        return events

    def screens(self) -> list[str]:
        return [str(e["to"]) for e in self.events() if e.get("kind") == "surface"]

    def screen(self) -> str | None:
        screens = self.screens()
        return screens[-1] if screens else None

    def unchanged_keys_on(self, surface: str) -> int:
        return sum(1 for e in self.events()
                   if e.get("kind") == "key_unchanged" and e.get("surface") == surface)

    def drain(self) -> None:
        count = self.server.count()
        if count != self.last_count:
            self.last_count = count
            self.last_request_at = time.monotonic()
        if select.select([self.master], [], [], 0.05)[0]:
            try:
                os.read(self.master, 65536)
            except OSError:
                pass

    def wait_until(self, predicate: Callable[[], bool], label: str,
                   timeout: float = 30.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain()
            if predicate():
                return
            if self.process.poll() is not None:
                break
        self.test.fail(
            f"{label}; exit={self.process.poll()}, screens={self.screens()}, "
            f"seen={self.server.seen()}")

    def settle(self, seconds: float) -> None:
        until = time.monotonic() + seconds
        self.wait_until(lambda: time.monotonic() >= until, "the TUI exited",
                        timeout=seconds + 5)

    def press(self, key: bytes) -> None:
        os.write(self.master, key)

    def comes_to_rest(self, label: str) -> None:
        self.wait_until(lambda: time.monotonic() - self.last_request_at >= QUIET_S, label)

    def draws_the_account_screen(self, label: str) -> int:
        """Wait for the account server's screen; return the request count
        at the moment it was seen."""
        self.wait_until(lambda: self.screen() == ACCOUNT_SCREEN, label)
        return self.server.count()

    def asks_only_the_probe_from(self, index: int, seconds: float) -> None:
        self.settle(seconds)
        others = sorted(set(self.server.since(index)) - {HEALTH})
        self.test.assertEqual(others, [], "requests beside the probe")

    def answers_r_with_the_probe(self) -> None:
        """r reads /health again and nothing else: the TUI is alive and the
        refresh it starts ends at the probe."""
        self.settle(LOOK_S)
        before = self.server.count()
        self.press(b"r")
        self.wait_until(lambda: HEALTH in self.server.since(before), "r did not probe")
        self.asks_only_the_probe_from(before, 2.0)


def run(test: unittest.TestCase, mode: Mode,
        scenario: Callable[[Session], None]) -> list[Request]:
    binary = AccountServerTest.binary
    with tempfile.TemporaryDirectory(prefix="masc-tui-account-") as base:
        config = pathlib.Path(base, ".masc", "config")
        config.mkdir(parents=True)
        (config / "runtime.toml").write_text(
            '[tui]\nopening = "overview"\nhints_visible = false\n'
            "help_hint_shown = true\nreduce_motion = true\n",
            encoding="utf-8",
        )
        trace = pathlib.Path(base, "nav-trace.jsonl")
        server = Server(base, mode)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        master = slave = -1
        process: subprocess.Popen[bytes] | None = None
        try:
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 140, 0, 0))
            process = subprocess.Popen(
                [binary, "--base-path", base, "--port", str(server.server_port)],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                env={
                    "HOME": base,
                    "TMPDIR": base,
                    "PATH": os.defpath,
                    "TERM": "xterm-256color",
                    "LANG": "C.UTF-8",
                    "MASC_TUI_NAV_TRACE": str(trace),
                },
                close_fds=True,
                # Its own process group, so whatever it starts ends with it.
                start_new_session=True,
            )
            os.close(slave)
            slave = -1
            session = Session(test, server, master, process, trace)
            session.wait_until(lambda: HEALTH in server.seen(), "the TUI did not probe")
            scenario(session)
            return server.seen()
        finally:
            if process is not None:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            for fd in (slave, master):
                if fd >= 0:
                    os.close(fd)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


class AccountServerTest(unittest.TestCase):
    binary = ""

    def test_the_account_server_is_asked_for_the_probe_alone(self) -> None:
        def scenario(session: Session) -> None:
            seen_at = session.draws_the_account_screen("the account server's screen was not drawn")
            session.answers_r_with_the_probe()
            # Each operator key changes nothing on the account server's
            # screen and asks the server nothing. The screen covers every
            # frame, so a key that reached an operator binding underneath
            # would leave it as it was too; the request it starts is what
            # shows it (Tab switches the surface underneath and revalidates).
            # Idle, the account server is asked nothing for a minute.
            before = session.server.count()
            unchanged = session.unchanged_keys_on(ACCOUNT_SCREEN)
            for index, key in enumerate(OPERATOR_KEYS, start=1):
                session.press(key)
                session.wait_until(
                    lambda: session.unchanged_keys_on(ACCOUNT_SCREEN) >= unchanged + index,
                    f"{key!r} changed the account server's screen")
            self.assertEqual(session.screen(), ACCOUNT_SCREEN)
            self.assertEqual(session.server.since(before), [], "requests after the keys")
            session.asks_only_the_probe_from(seen_at, 0.0)

        seen = run(self, "account", scenario)
        self.assertEqual(seen.count(PREFERENCES), 1, "the preferences were read again")

    def test_a_masc_server_is_asked_for_its_surfaces(self) -> None:
        def scenario(session: Session) -> None:
            session.wait_until(
                lambda: bool(set(session.server.seen()) - {PREFERENCES, HEALTH}),
                "the control asked for no surface")
            session.settle(2.0)
            first = session.screen()
            self.assertIsNotNone(first, "no screen was drawn")
            # Tab moves an operator screen to the next family.
            session.press(b"\t")
            session.wait_until(lambda: session.screen() != first,
                               "Tab did not change the control's screen")
            self.assertNotIn(ACCOUNT_SCREEN, session.screens())

        run(self, "masc", scenario)

    def test_the_account_screen_returns_after_an_outage(self) -> None:
        def scenario(session: Session) -> None:
            server = session.server
            session.draws_the_account_screen("the account server's screen was not drawn")
            session.settle(LOOK_S)
            server.set_mode("down")
            down_at = server.count()
            session.press(b"r")
            session.wait_until(lambda: HEALTH in server.since(down_at), "r did not probe")
            # The address does not answer: its screen gives way.
            session.wait_until(lambda: session.screen() != ACCOUNT_SCREEN,
                               "the screen stayed while the server did not answer")
            session.settle(4.0)
            server.set_mode("account")
            seen_at = session.draws_the_account_screen(
                "the account server's screen did not return")
            session.asks_only_the_probe_from(seen_at, WATCH_S)
            session.comes_to_rest("the TUI kept asking after the account server came back")
            session.answers_r_with_the_probe()
            # While it was down nothing but the probe and the reconnect
            # attempts went out: no surface was asked.
            others = sorted(set(server.since(down_at)) - {HEALTH, ("POST", "/mcp")})
            self.assertEqual(others, [], "requests beside the probe and the reconnects")

        run(self, "account", scenario)

    def test_the_account_screen_replaces_a_masc_server(self) -> None:
        def scenario(session: Session) -> None:
            server = session.server
            session.wait_until(
                lambda: bool(set(server.seen()) - {PREFERENCES, HEALTH}),
                "the masc server was asked for no surface")
            session.settle(2.0)
            server.set_mode("account")
            # No key: the TUI finds the account server on its own.
            seen_at = session.draws_the_account_screen(
                "the account server's screen was not drawn after the swap")
            session.asks_only_the_probe_from(seen_at, WATCH_S)
            session.comes_to_rest("the TUI kept asking after the account server took the address")
            session.answers_r_with_the_probe()

        run(self, "masc", scenario)


if __name__ == "__main__":
    AccountServerTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
