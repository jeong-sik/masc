#!/usr/bin/env python3
"""masc-tui attached to the account server of a multi-account installation.

The fixture answers /health as the account server does and every other
request with a 404, as the account server does for the operator routes. The
TUI is started on it in a terminal, and the requests it sends are recorded:
after the probe it asks for nothing but the probe again. The control is the
same fixture answering /health as a masc server of the workspace, which the
TUI goes on to read surfaces from: without it the test could pass on a TUI
that asked nothing at all.

Two more cases change what the fixture answers while the TUI runs. The
account server stops answering for a while and comes back; a masc server is
replaced by the account server. In both the TUI must come to rest: no
request for a few seconds. A TUI that kept reconnecting to an MCP endpoint
the account server does not serve posts to it every two seconds.
"""

import fcntl
import http.server
import json
import os
import pathlib
import pty
import select
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
# What the TUI reads before it knows which server answers: the operator's
# saved screen preferences, read once at start.
BEFORE_THE_PROBE = frozenset({("GET", "/api/v1/tui/preferences")})
HEALTH = ("GET", "/health")
# Longer than the TUI's reconnect interval (two seconds), so a reconnect loop
# cannot fit between two requests.
QUIET_S = 5.0


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, base: str, mode: Mode) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.base = os.path.realpath(base)
        self.lock = threading.Lock()
        self.mode: Mode = mode
        self.requests: list[tuple[float, str, str]] = []

    def set_mode(self, mode: Mode) -> None:
        with self.lock:
            self.mode = mode

    def current_mode(self) -> Mode:
        with self.lock:
            return self.mode

    def seen(self) -> list[tuple[str, str]]:
        with self.lock:
            return [(method, path) for _, method, path in self.requests]

    def seen_since(self, since: float) -> list[tuple[str, str]]:
        with self.lock:
            return [(m, p) for at, m, p in self.requests if at >= since]

    def last_request_at(self) -> float:
        with self.lock:
            return self.requests[-1][0] if self.requests else 0.0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *_args: object) -> None:
        pass

    def handle(self) -> None:
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def answer(self, status: int, body: object) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def note(self) -> tuple[str, str]:
        server = cast(Server, self.server)
        request = (self.command, urllib.parse.urlsplit(self.path).path)
        with server.lock:
            server.requests.append((time.monotonic(), *request))
        return request

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        self.note()
        self.answer(404, {"error": "not found"})

    def do_GET(self) -> None:
        server = cast(Server, self.server)
        mode = server.current_mode()
        if self.note() != HEALTH:
            self.answer(404, {"error": "not found"})
        elif mode == "down":
            self.answer(503, {"error": "unavailable"})
        elif mode == "account":
            # The whole answer of Server_accounts.health.
            self.answer(
                200,
                {"server": "masc", "version": VERSION, "account_mode": "Multi_account"},
            )
        else:
            self.answer(
                200,
                {
                    "server": "masc",
                    "version": VERSION,
                    "status": "ok",
                    "startup": {"state_ready": True},
                    "paths": {
                        "effective_base_path": server.base,
                        "effective_masc_root": server.base + "/.masc",
                    },
                },
            )


class Session:
    """The TUI in a terminal, attached to the fixture."""

    def __init__(self, test: unittest.TestCase, server: Server, master: int,
                 process: subprocess.Popen[bytes]) -> None:
        self.test = test
        self.server = server
        self.master = master
        self.process = process

    def wait_until(self, predicate: Callable[[], bool], label: str,
                   timeout: float = 20.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.process.poll() is not None:
                break
            if select.select([self.master], [], [], 0.05)[0]:
                try:
                    os.read(self.master, 65536)
                except OSError:
                    break
        self.test.fail(
            f"{label}; exit={self.process.poll()}, seen={self.server.seen()}")

    def settle(self, seconds: float) -> None:
        until = time.monotonic() + seconds
        self.wait_until(lambda: time.monotonic() >= until, "the TUI exited",
                        timeout=seconds + 5)

    def press(self, key: bytes) -> None:
        os.write(self.master, key)

    def comes_to_rest(self, label: str, timeout: float = 30.0) -> None:
        self.wait_until(
            lambda: time.monotonic() - self.server.last_request_at() >= QUIET_S,
            label, timeout=timeout)


def run(test: unittest.TestCase, mode: Mode,
        scenario: Callable[[Session], None]) -> list[tuple[str, str]]:
    binary = AccountServerTest.binary
    with tempfile.TemporaryDirectory(prefix="masc-tui-account-") as base:
        config = pathlib.Path(base, ".masc", "config")
        config.mkdir(parents=True)
        (config / "runtime.toml").write_text(
            '[tui]\nopening = "overview"\nhints_visible = false\n'
            "help_hint_shown = true\nreduce_motion = true\n",
            encoding="utf-8",
        )
        server = Server(base, mode)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        master, slave = pty.openpty()
        process: subprocess.Popen[bytes] | None = None
        try:
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
                },
                close_fds=True,
            )
            os.close(slave)
            slave = -1
            session = Session(test, server, master, process)
            session.wait_until(lambda: HEALTH in server.seen(), "the TUI did not probe")
            scenario(session)
            return server.seen()
        finally:
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if slave >= 0:
                os.close(slave)
            os.close(master)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


def probe_and_r(session: Session) -> None:
    # The first refresh, then the one [r] asks for, and a while for whatever
    # either led to.
    session.settle(2.0)
    session.press(b"r")
    session.wait_until(lambda: session.server.seen().count(HEALTH) >= 2,
                       "r did not probe again")
    session.settle(3.0)


class AccountServerTest(unittest.TestCase):
    binary = ""

    def test_the_account_server_is_asked_for_the_probe_alone(self) -> None:
        def probe_r_and_operator_keys(session: Session) -> None:
            probe_and_r(session)
            # The account server screen takes every key: the operator
            # screens' bindings ask nothing of it.
            for key in (b"s", b"a", b"i", b"\t", b"?", b"/"):
                session.press(key)
                session.settle(0.5)
            session.settle(2.0)

        seen = run(self, "account", probe_r_and_operator_keys)
        others = sorted(set(seen) - BEFORE_THE_PROBE - {HEALTH})
        self.assertEqual(others, [], "requests beside the probe")

    def test_a_masc_server_is_asked_for_its_surfaces(self) -> None:
        seen = run(self, "masc", probe_and_r)
        others = set(seen) - BEFORE_THE_PROBE - {HEALTH}
        self.assertNotEqual(others, set(), "the control asked for no surface")

    def test_the_tui_rests_after_the_account_server_comes_back(self) -> None:
        def blip(session: Session) -> None:
            server = session.server
            session.settle(2.0)
            server.set_mode("down")
            down_at = time.monotonic()
            session.press(b"r")
            # While it is down the TUI keeps trying to reconnect.
            session.wait_until(
                lambda: ("POST", "/mcp") in server.seen_since(down_at),
                "the TUI did not try to reconnect while the server was down")
            server.set_mode("account")
            back_at = time.monotonic()
            session.comes_to_rest("the TUI kept asking after the account server came back")
            self.assertIn(HEALTH, server.seen_since(back_at),
                          "the TUI did not probe after the server came back")
            # A probe that fails after the address said account server ends
            # its pass: no surface goes out, only the reconnect attempts.
            others = sorted(set(server.seen_since(down_at)) - {HEALTH, ("POST", "/mcp")})
            self.assertEqual(others, [], "requests beside the probe and the reconnects")

        run(self, "account", blip)

    def test_the_tui_rests_after_the_account_server_replaces_a_masc_server(self) -> None:
        def swap(session: Session) -> None:
            server = session.server
            session.wait_until(
                lambda: bool(set(server.seen()) - BEFORE_THE_PROBE - {HEALTH}),
                "the masc server was asked for no surface")
            session.settle(2.0)
            server.set_mode("account")
            swapped_at = time.monotonic()
            session.comes_to_rest("the TUI kept asking after the account server took the address")
            self.assertIn(HEALTH, server.seen_since(swapped_at),
                          "the TUI did not probe after the swap")

        run(self, "masc", swap)


if __name__ == "__main__":
    AccountServerTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
