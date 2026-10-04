from __future__ import annotations

import argparse
import base64
import errno
import fcntl
import hashlib
import json
import os
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager, redirect_stdout
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
from pathlib import Path
from typing import Any, assert_never, cast

Interaction = Callable[[subprocess.Popen[bytes], int, int, bytearray, str], None]
HttpResponse = tuple[int, object]
Needle = bytes | re.Pattern[bytes]

# The composer row redrawn focused: its prompt "› to <keeper>" with nothing
# after the name but blanks. Unfocused it ends in "(i to write)". The voice
# keys hint used to be what a step waited for after i, but it is drawn only
# where speech-to-text is set up, and a fixture without a voice config is the
# ordinary case.
COMPOSER_FOCUSED = re.compile(
    rb"\xe2\x80\xba to [^\s\x1b]+(?=\s|\x1b)(?! *\(i to write\))"
)


class RawHttpResponse:
    """A response the fixture sends byte for byte: its own content type and
    headers, no JSON encoding. The MCP transport answers ``initialize`` with
    the session id in a header, and the observer feed is an SSE body, so
    neither fits the JSON tuple."""

    def __init__(
        self,
        status: int,
        body: bytes,
        *,
        content_type: str,
        headers: tuple[tuple[str, str], ...] = (),
    ) -> None:
        self.status = status
        self.body = body
        self.content_type = content_type
        self.headers = headers


class StreamingHttpResponse:
    """SSE chunks released by the interaction while one connection stays open."""

    def __init__(self, chunks: Callable[[], Iterator[bytes]], *,
                 headers: tuple[tuple[str, str], ...] = ()) -> None:
        self.chunks = chunks
        self.headers = headers


class DroppedHttpResponse:
    """Close before writing a status line to exercise the client's transport error."""


class HeadersHttpResponse:
    """A streaming protocol fixture whose response depends on request headers."""

    def __init__(self, resolve: Callable[[dict[str, str]], RawHttpResponse | StreamingHttpResponse]) -> None:
        self.resolve = resolve


class PathHttpResponse:
    """A fixture whose answer depends on the request's query. The live route
    names the machine and the counter already drawn in its query string, and
    the plain fixtures see only the path."""

    def __init__(self, resolve: Callable[[str], HttpResponse]) -> None:
        self.resolve = resolve


class RequestHttpResponse:
    """A fixture whose JSON-RPC answer must echo fields from the POST body."""

    def __init__(
        self,
        resolve: Callable[[bytes], HttpResponse | RawHttpResponse | StreamingHttpResponse],
        *,
        get_response: HttpResponse | None = None,
    ) -> None:
        self.resolve = resolve
        self.get_response = get_response



class MethodHttpResponse:
    """A fixture that can assert the HTTP method for a mutation route."""

    def __init__(self, resolve: Callable[[str], HttpResponse]) -> None:
        self.resolve = resolve


HttpFixture = (
    HttpResponse
    | RawHttpResponse
    | StreamingHttpResponse
    | DroppedHttpResponse
    | RequestHttpResponse
    | MethodHttpResponse
    | HeadersHttpResponse
    | PathHttpResponse
    | Callable[[], HttpResponse]
)
HttpFixtures = dict[str, HttpFixture]
HttpRequests = list[tuple[str, bytes]]
WorkspaceSetup = Callable[[str], None]
WORKSPACE_PAYLOAD = "workspace\x1b]8;;https://attacker.invalid\x07owned"
WORKSPACE_RENDERED = b"workspace\\x1B]8;;https://attacker.invalid\\x07owned"
FRAME_END = b"\x1b[?7h"
FRAME_START = b"\x1b[?7l"
FULL_REDRAW = b"\x1b[2J"
CONSOLE_DIAGNOSTIC = b"[masc-tui] decode failed for "
CURSOR_RE = re.compile(rb"\x1b\[(\d+);(\d+)H\x1b\[\?25h")
POSITION_RE = re.compile(rb"\x1b\[(\d+);(\d+)H")
# A lexed OCaml keyword, whichever colour the theme dresses it in. Pinning the
# code -- yellow, once -- meant #30723's palette change failed four scenarios
# with a timeout that named a colour instead of the thing under test: that the
# file arrived lexed rather than printed.
LEXED_LET = re.compile(rb"\x1b\[[0-9;]*m" + re.escape(b"let") + rb"\x1b\[0m")

CSI_RE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
OSC_RE = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

# Masc_tui_scroll.window_text: where a scrolled window stands in its list,
# "first-last/count". The Keeper detail pane draws it on its own row; the diff
# surfaces put it in "[lines ...]".
WINDOW_TEXT_RE = re.compile(rb"(?<![\d/-])(\d+)-(\d+)/(\d+)(?![\d/])")
LINES_WINDOW_RE = re.compile(rb"\[lines (\d+)-(\d+)/(\d+)\]")

def composer_showing(text: bytes, *, prefix: bytes = b"> ") -> re.Pattern[bytes]:
    """The composer's prefix and what was typed after it are styled separately
    -- the origin colour ends with the prefix and the body starts after a reset
    -- so the two are not adjacent in the byte stream even though they are
    adjacent on screen. Waiting on the literal bytes made every needle that
    spanned the two time out on a frame that showed exactly what it asked for.
    [prefix] is the prompt on the first row and the indent under it on the
    rows a Ctrl-J opens."""
    return re.compile(
        re.escape(prefix) + rb"(?:" + CSI_RE.pattern + rb")*" + re.escape(text)
    )

BOARD_CELL_BODY = ("한" * 20) + " " + ("한" * 20)


class SequencedHttpResponse:
    """One response per call, in order; the last repeats. The MCP endpoint
    answers initialize and tools/call on the same path, so a scenario that
    does both needs the fixture to change under it."""

    def __init__(self, responses: list) -> None:
        self.responses = list(responses)
        self.served = 0

    def __call__(self):
        index = min(self.served, len(self.responses) - 1)
        self.served += 1
        return self.responses[index]


class GatedHttpResponse:
    def __init__(
        self,
        response: HttpResponse,
        *,
        subsequent_response: HttpResponse | None = None,
        hold_seconds: float = 5.0,
    ) -> None:
        self.response = response
        self.subsequent_response = subsequent_response
        self.hold_seconds = hold_seconds
        self.requested = threading.Event()
        self.subsequent_requested = threading.Event()
        self.release = threading.Event()
        self.completed = threading.Event()
        self.calls = 0
        self.lock = threading.Lock()

    def __call__(self) -> HttpResponse:
        with self.lock:
            call_index = self.calls
            self.calls += 1
        if call_index > 0 and self.subsequent_response is not None:
            self.subsequent_requested.set()
            return self.subsequent_response
        self.requested.set()
        try:
            if not self.release.wait(timeout=self.hold_seconds):
                return 504, {"error": "fixture response gate timed out"}
            return self.response
        finally:
            self.completed.set()


# Same test-only allowance as the harness's ordinary response waits.
FIXTURE_HANDLER_CLEANUP_TIMEOUT_S = 3.0


class FixtureHTTPServer(ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], handler: type[BaseHTTPRequestHandler]) -> None:
        self.handlers: list[threading.Thread] = []
        super().__init__(address, handler)

    def process_request(
        self, request: socket.socket | tuple[bytes, socket.socket], client_address: tuple[str, int]
    ) -> None:
        thread = threading.Thread(
            target=self.process_request_thread,
            args=(request, client_address),
            daemon=True,
        )
        self.handlers.append(thread)
        thread.start()

    def server_close(self) -> None:
        HTTPServer.server_close(self)
        deadline = time.monotonic() + FIXTURE_HANDLER_CLEANUP_TIMEOUT_S
        for handler in self.handlers:
            handler.join(max(0.0, deadline - time.monotonic()))
        pending = [handler.name for handler in self.handlers if handler.is_alive()]
        if pending:
            raise AssertionError("HTTP fixture handlers did not stop: " + ", ".join(pending))


@contextmanager
def test_http_endpoint(
    fixtures: HttpFixtures | None,
    requests: HttpRequests | None,
) -> Iterator[tuple[int, Callable[[], None], Callable[[str], None]]]:
    fixtures = {} if fixtures is None else fixtures
    workspace_base_path: str | None = None

    def set_workspace_base_path(base_path: str) -> None:
        nonlocal workspace_base_path
        workspace_base_path = base_path

    class FixtureHandler(BaseHTTPRequestHandler):
        def respond(self, request_body: bytes | None = None) -> None:
            # Resolution order is load-bearing: exact fixture keys and the
            # /health specials keep their legacy meaning (an exact path is
            # still required), and only then does a query-stripped path get
            # a second chance -- paged endpoints carry a float timestamp
            # (e.g. /chat/history/page?before=1788678…) a scenario cannot
            # key on. Everything else still falls to the 503 sentinel.
            path_only = self.path.split("?", 1)[0]
            if self.path in fixtures:
                fixture = fixtures[self.path]
            elif path_only == "/api/v1/gate/keepers" and "/api/v1/gate/keepers?detailed=true" in fixtures:
                fixture = fixtures["/api/v1/gate/keepers?detailed=true"]
            elif self.path == "/health":
                fixture = (200, {})
            elif self.path == "/health?full=1":
                fixture = fleet_safety_fixture()
            elif path_only in fixtures:
                fixture = fixtures[path_only]
            elif path_only == DASHBOARD_GOALS_PATH:
                fixture = empty_goals_fixture()
            elif path_only == RUNTIME_RESOLVED_PATH:
                fixture = empty_runtime_resolved_fixture()
            elif path_only == ACCOUNT_EMAILS_PATH:
                fixture = empty_account_emails_fixture()
            else:
                fixture = (503, {"error": "fixture endpoint unavailable"})
            if isinstance(fixture, RequestHttpResponse):
                if self.command == "GET" and fixture.get_response is not None:
                    resolved = fixture.get_response
                else:
                    resolved = fixture.resolve(request_body or b"")
            elif isinstance(fixture, MethodHttpResponse):
                resolved = fixture.resolve(self.command)
            elif isinstance(fixture, PathHttpResponse):
                resolved = fixture.resolve(self.path)
            elif isinstance(fixture, HeadersHttpResponse):
                resolved = fixture.resolve({key.lower(): value for key, value in self.headers.items()})
            else:
                resolved = fixture() if callable(fixture) else fixture
            if isinstance(resolved, DroppedHttpResponse):
                self.close_connection = True
                self.connection.close()
                return
            if isinstance(resolved, StreamingHttpResponse):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                for key, value in resolved.headers:
                    self.send_header(key, value)
                self.end_headers()
                try:
                    for chunk in resolved.chunks():
                        self.wfile.write(chunk)
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            extra_headers: tuple[tuple[str, str], ...] = ()
            if isinstance(resolved, RawHttpResponse):
                status = resolved.status
                body = resolved.body
                content_type = resolved.content_type
                extra_headers = resolved.headers
            else:
                status, payload = resolved
                if (
                    self.path in ("/health", "/health?full=1")
                    and status == 200
                    and isinstance(payload, dict)
                    and workspace_base_path is not None
                ):
                    payload = dict(payload)
                    paths = dict(payload.get("paths", {}))
                    paths.update(
                        {
                            "effective_base_path": workspace_base_path,
                            "effective_masc_root": os.path.join(
                                workspace_base_path, ".masc"
                            ),
                        }
                    )
                    payload["paths"] = paths
                body = json.dumps(payload).encode()
                content_type = "application/json"
            # A TUI client may drop the connection before the reply is
            # written (quiet leaves, screen switches, process exit). The
            # streaming branch above already swallows that; a plain reply
            # must too, or the fixture thread kills the whole suite run.
            try:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                for name, value in extra_headers:
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self) -> None:
            self.respond()

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            self.respond(body)
            if requests is not None:
                requests.append((self.path, body))

        def do_DELETE(self) -> None:
            self.respond()
            if requests is not None:
                requests.append((self.path, b""))

        def log_message(self, format: str, *args: object) -> None:
            del format, args

    with FixtureHTTPServer(("127.0.0.1", 0), FixtureHandler) as server:
        thread: threading.Thread | None = None

        def start_endpoint() -> None:
            nonlocal thread
            if thread is not None:
                raise AssertionError("fixture HTTP server started twice")
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()

        try:
            yield (
                int(server.server_address[1]),
                start_endpoint,
                set_workspace_base_path,
            )
        finally:
            if thread is not None:
                server.shutdown()
                thread.join(timeout=2.0)
                if thread.is_alive():
                    raise AssertionError("fixture HTTP server did not stop")



def assert_workspace_payload_is_inert(output: bytearray) -> None:
    if WORKSPACE_PAYLOAD.encode() in output:
        raise AssertionError(
            f"workspace emitted raw terminal controls: {bytes(output)!r}"
        )


# A needle is either literal bytes or a compiled pattern. Patterns exist so an
# assertion can name what it means -- "this row is highlighted" -- without also
# pinning the column widths around it. #29777 widened the Board row by one
# column and every literal that had baked the old gutter into itself stopped
# matching, which reads as "the selection broke" rather than "the row moved".
#
# A pattern searches the buffer in place: `re` reads a bytearray through the
# buffer protocol with the same match positions as bytes. Copying it first
# cost a whole-session copy per check, and a timed transition checks at least
# three times, so an input-to-frame observation grew with everything the
# session had printed before it.
def find_needle(
    haystack: bytes | bytearray,
    needle: bytes | re.Pattern[bytes],
    start: int = 0,
) -> int:
    if isinstance(needle, bytes):
        return haystack.find(needle, start)
    found = needle.search(haystack, start)
    return found.start() if found else -1



def end_of_needle(
    haystack: bytes | bytearray,
    needle: bytes | re.Pattern[bytes],
    start: int = 0,
) -> int:
    if isinstance(needle, bytes):
        return haystack.find(needle, start) + len(needle)
    found = needle.search(haystack, start)
    assert found is not None
    return found.end()


# The Planning goal table's column row, which Render_schedule.planning_header_row
# writes and only the list pane draws. The widths between the names follow the
# terminal, so the names are what the pattern pins.
PLANNING_LIST_HEADER = re.compile(rb"PHASE\s+JUDGE\s+PRI\s+OPEN\s+TITLE")


def screen_header(name: bytes, rest: bytes = b"") -> re.Pattern[bytes]:
    """A screen header, matched across the emphasis that closes the title.

    The words naming the screen carry the emphasis, so the reset that ends it
    sits between the name and the counts after it. Spelling a header as one
    literal asserted that those bytes are adjacent, which is a fact about
    styling rather than about what the screen is showing.
    """
    return re.compile(re.escape(name) + rb"(?:\x1b\[[0-9;]*m)*" + re.escape(rest))


def empty_gate_snapshot() -> tuple[int, dict[str, object]]:
    """GET /api/v1/dashboard/gate answering with an empty, readable queue.

    The Approvals surface says "(no pending approvals)", and its title carries
    no note, only when the Gate queue was read along with the confirm queue,
    the held calls and the questions. A scenario that leaves this path
    unserved gets a 503 and a screen that says the Gate queue was not read.
    The shape follows lib/tui_decode.ml (decode_gate_snapshot).
    """
    return (
        200,
        {
            "approval_queue": [],
            "approval_queue_state": {"state": "ready"},
            "hitl": {
                "gate_mode": {"mode": "auto_judge"},
                "external_gate_mode": {"mode": "manual"},
            },
            "approval_rules": [],
            "approval_rules_state": {"state": "ready"},
        },
    )


def approvals_header(count: int) -> re.Pattern[bytes]:
    """The Approvals title and the number of asks on it.

    What follows the number inside the parens is where those asks came from --
    held calls, Gate rows, operator entries, only the ones with rows. With one
    kind the number is that kind's, painted in its colour ("(3 op)"); with
    more the total leads ("(5: 2 gate · 3 op)"). Spelling the header as "(3)"
    asserted the parenthesis closes right after the number, which is a fact
    about that breakdown rather than about how many asks are waiting.
    """
    return re.compile(
        re.escape(b"MASC Approvals")
        + rb"(?:\x1b\[[0-9;]*m)* \((?:\x1b\[[0-9;]*m)*"
        + str(count).encode()
        + rb"[ ):]"
    )


# The Board list draws a post's id only while it keeps every column: the
# named columns and their gaps take 66 cells and the title's floor 30
# (Masc_tui_render_schedule.board_layout), and the frame and the row's lead
# take 8 more. Below 104 the id is the first column it gives up, so a case
# that finds a Board row by its id opens this wide. It stays short of the
# roster pane (Masc_tui_roster_pane.threshold_cols) and the Activity pane
# (Masc_tui_acting_pane.threshold_cols), which would take cells off the body.
BOARD_ID_DRAWN_COLS = 104


def selected_row(post_id: bytes) -> re.Pattern[bytes]:
    """The highlighted list row for `post_id`, whatever sits in the gutter.

    On the Board the id is a column the list gives up when narrow, so the
    terminal must be at least BOARD_ID_DRAWN_COLS wide.

    Selection is drawn two ways while the band conversion is in flight: the
    legacy reverse-video caret, or a full-row reverse band that opens the
    row and carries no inner escapes.
    """
    return re.compile(
        rb"\x1b\[7m(?:>\x1b\[0m)?(?:\x1b\[[0-9;]*m|[ \xc2\xb7@?])*"
        + re.escape(post_id)
    )


class PtyOutput(bytearray):
    """Output and its last observed byte belong to the same terminal session."""

    pid: int | None = None
    last_byte_at: float | None = None
    last_byte_ticks: tuple[int, int] | None = None


def read_available(master_fd: int, output: bytearray) -> None:
    while True:
        try:
            chunk = os.read(master_fd, 65536)
        except BlockingIOError:
            return
        except OSError as error:
            if error.errno in (errno.EIO, errno.EBADF):
                return
            raise
        if not chunk:
            return
        output.extend(chunk)
        if isinstance(output, PtyOutput):
            output.last_byte_at = time.monotonic()
            output.last_byte_ticks = (
                _child_cpu_ticks(output.pid) if output.pid is not None else None
            )


# A needle the screen already drew before the keypress is a different failure
# from one it never drew, and the two read identically in a timeout message.
# The TUI refreshes an open surface on its own cadence, so a scenario that
# mutates a fixture and then presses a key races that refresh: the earlier
# draw lands before send_and_wait takes its offset, and the wait that follows
# looks for bytes that are already behind it.
#
# This reads the first draw, so it only separates the two for a needle the
# surface draws once. For one it draws every frame the offset is the opening
# paint and says nothing about why this wait came up empty, which is why the
# note states what it found rather than a cause.
def _needle_before_start(
    output: bytearray, needle: Needle, start: int
) -> str:
    if start <= 0:
        return ""
    earlier = find_needle(output, needle, 0)
    if earlier < 0 or earlier >= start:
        return ""
    return (
        f" (first drawn at offset {earlier}, none after this wait began at"
        f" {start})"
    )


def _child_cpu_ticks(pid: int) -> tuple[int, int] | None:
    """(utime, stime) of a still-running child, in clock ticks, from /proc.

    None where /proc does not exist (macOS) or the child is already reaped:
    both make the delta unmeasurable, and the diagnostic line says so instead
    of guessing a zero.
    """
    try:
        with open(f"/proc/{pid}/stat", "rb") as stat:
            fields = stat.read().rsplit(b")", 1)[-1].split()
    except OSError:
        return None
    try:
        # fields[0] is state (field 3); utime and stime are fields 14 and 15.
        return int(fields[11]), int(fields[12])
    except (IndexError, ValueError):
        return None


def _stall_line(
    process: subprocess.Popen[bytes],
    output: bytearray,
    *,
    started_at: float,
    started_len: int,
    last_byte_at: float | None,
    last_byte_ticks: tuple[int, int] | None,
) -> str:
    """One bracketed line for a wait that timed out, task-1776.

    The three readings separate the ways a PTY wait dies: silence counts from
    the last byte the PTY delivered, so a screen that froze mid-draw reads
    differently from one that never drew; loadavg is copied from /proc at the
    timeout; the child CPU snapshot and delta use the last byte as their
    baseline. No timeout, needle or wait behaviour changes because of it.
    """
    now = time.monotonic()
    try:
        with open("/proc/loadavg", "rt", encoding="ascii") as loadavg:
            load = loadavg.read().rstrip("\n")
    except OSError:
        load = "unavailable"
    silence = (
        f"silence {now - last_byte_at:.2f}s"
        if last_byte_at is not None else "last byte unavailable"
    )
    parts = [
        silence
        + f" (wait ran {now - started_at:.2f}s,"
        f" bytes {started_len} -> {len(output)})",
        f"loadavg(at timeout) {load}",
    ]
    ended = (
        _child_cpu_ticks(process.pid) if process.pid is not None else None
    )
    if last_byte_ticks is None or ended is None:
        parts.append("child utime/stime unavailable")
    else:
        try:
            hz = os.sysconf("SC_CLK_TCK")
            last_user, last_system = (value / hz for value in last_byte_ticks)
            end_user, end_system = (value / hz for value in ended)
            user_delta = end_user - last_user
            system_delta = end_system - last_system
            parts.append(
                "child utime/stime "
                f"at last byte {last_user:.2f}s/{last_system:.2f}s; "
                f"at timeout {end_user:.2f}s/{end_system:.2f}s; "
                f"delta +{user_delta:.2f}s/+{system_delta:.2f}s"
            )
        except (OSError, ValueError):
            parts.append("child utime/stime unavailable")
    return " [stall: " + "; ".join(parts) + "]"


def poll_for_output(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    needle: Needle,
    *,
    start: int,
    timeout: float,
) -> bool:
    """True once ``needle`` lands at or after ``start``, False once ``timeout`` passes.

    A caller that has something to do when it does not arrive -- press the key
    again, say -- needs the answer rather than the exception. An exited TUI
    still raises: no amount of waiting brings it back. ``read_available``
    records byte observations across all waits in the terminal session.
    """
    deadline = time.monotonic() + timeout
    while find_needle(output, needle, start) < 0:
        read_available(master_fd, output)
        if process.poll() is not None:
            raise AssertionError(f"TUI exited before {needle!r}: {bytes(output)!r}")
        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            return False
        select.select([master_fd], [], [], min(0.1, remaining))
    return True


def wait_for_output(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    needle: Needle,
    *,
    start: int,
    timeout: float,
) -> None:
    started_at = time.monotonic()
    started_len = len(output)
    if poll_for_output(
        process,
        master_fd,
        output,
        needle,
        start=start,
        timeout=timeout,
    ):
        return
    stall = _stall_line(
        process,
        output,
        started_at=started_at,
        started_len=started_len,
        last_byte_at=output.last_byte_at if isinstance(output, PtyOutput) else None,
        last_byte_ticks=output.last_byte_ticks if isinstance(output, PtyOutput) else None,
    )
    raise AssertionError(
        f"timed out waiting for {needle!r}"
        f"{_needle_before_start(output, needle, start)}"
        f"{stall}: {bytes(output)!r}"
    )


def wait_for_fixture_state(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    ready: Callable[[], bool],
    *,
    timeout: float,
) -> bool:
    """Wait for a fixture to record something, as its sibling waits for a signal.

    A key whose whole effect is a request the screen is already showing the
    answer to cannot be waited for on the screen. Frame_presenter.present
    writes nothing at all -- not even a frame terminator -- when a frame equals
    the one before it, so a refresh that is meant to come back with the same
    scene draws no bytes, and send_and_wait waits out its three seconds for a
    needle that is already on the screen and will not be written again.
    """
    deadline = time.monotonic() + timeout
    while not ready():
        read_available(master_fd, output)
        if process.poll() is not None:
            return False
        if time.monotonic() >= deadline:
            return False
        select.select([master_fd], [], [], 0.02)
    return True


def wait_for_fixture_event(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    event: threading.Event,
    *,
    timeout: float,
) -> bool:
    """Wait for a fixture thread without letting the TUI's PTY fill up."""
    deadline = time.monotonic() + timeout
    while not event.is_set():
        read_available(master_fd, output)
        if process.poll() is not None:
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            return False
        event.wait(timeout=min(0.05, remaining))
    return True


def wait_for_fixture_served(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    fixture: SequencedHttpResponse,
    *,
    after: int,
    description: str,
    timeout: float = 3.0,
) -> None:
    """Wait for a callable GET fixture without relying on POST capture."""
    deadline = time.monotonic() + timeout
    while fixture.served <= after:
        read_available(master_fd, output)
        if process.poll() is not None:
            raise AssertionError(f"TUI exited before {description}")
        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            raise AssertionError(f"timed out waiting for {description}")
        select.select([master_fd], [], [], min(0.05, remaining))


def write_all(master_fd: int, output: bytearray, data: bytes) -> None:
    """Write every byte, draining the TUI as it goes.

    A terminal's input queue is small -- 1024 bytes on macOS -- and the master
    is non-blocking here, so one os.write of a real paste returns short and
    the rest is simply gone. A scenario that pastes 4 kB and asserts on what
    arrived would be asserting on the first kilobyte. Reading between writes
    is what lets the TUI drain the queue so the next chunk fits.
    """
    offset = 0
    while offset < len(data):
        try:
            offset += os.write(master_fd, data[offset : offset + 512])
        except BlockingIOError:
            pass
        read_available(master_fd, output)


def send_and_wait(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    data: bytes,
    needle: Needle,
) -> bytes:
    read_available(master_fd, output)
    start = len(output)
    # Through write_all, not os.write: the master is non-blocking and the
    # terminal's input queue holds about a kilobyte, so a single write of a
    # longer payload returns short and the rest is dropped without an error.
    # A scenario that types 1,819 bytes and waits for the tail was waiting on
    # bytes the terminal never received -- 1,022 of them arrived.
    write_all(master_fd, output, data)
    wait_for_output(process, master_fd, output, needle, start=start, timeout=3.0)
    needle_end = end_of_needle(output, needle, start)
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=needle_end,
        timeout=3.0,
    )
    frame_end = output.find(FRAME_END, needle_end) + len(FRAME_END)
    return bytes(output[start:frame_end])


def palette_go(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    query: bytes,
    needle: Needle,
) -> bytes:
    """Jump through the command palette. Surfaces that hang off a parent
    instead of holding a Tab stop (Lanes, Connectors, Task Review, Code) keep a
    'go <label>' palette entry, so this is how a scenario reaches them."""
    return send_and_wait(process, master_fd, output, b":" + query + b"\r", needle)


def copy_reference(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    reference: bytes,
) -> bytes:
    """Press the shared copy key and require the exact OSC 52 payload."""
    osc52 = b"\x1b]52;c;" + base64.b64encode(reference) + b"\x07"
    return send_and_wait(process, master_fd, output, b"Y", osc52)


# How many screens the Tab cycle holds is a property of the code under test,
# not of this test. Spelling it as a literal run of tabs made every screen
# added to the cycle silently retarget these assertions: #29768 added five
# screens, and the five tabs that used to close the loop stopped at the first
# new one, so the assertion timed out on a needle that was never going to
# arrive.
#
# Walking one press at a time asserts what the assertions meant -- this screen
# is reachable by tabbing -- and survives the cycle changing length. Adjacency
# is still asserted directly by the single-tab calls elsewhere; this helper is
# only for the calls that were closing a loop.
#
# The bound is a liveness guard, not the cycle length: it has to exceed the
# cycle so a reachable screen is always found, and it reports the screen it
# never reached instead of leaving a bare needle timeout behind.
TAB_CYCLE_BOUND = 24
# How many j presses a walk down one Keeper detail may take. Info at the
# harness height is under fifty lines, so a walk past this has lost its way.
KEEPER_DETAIL_SCROLL_BOUND = 60


def drain_until_quiet(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    quiet: float = 0.25,
    cap: float = 3.0,
) -> bool:
    """Read until the TUI has written nothing for [quiet] seconds. True when
    it went quiet, False when [cap] passed with output still arriving.

    A keypress's consequences are not one frame: the switch redraw can be
    preceded by frames already in flight. The only moment a press can be
    judged is after its output has stopped arriving. A screen that animates
    never stops, and a caller that needs the quiet asserts the answer rather
    than reading a screen [cap] happened to cut.
    """
    deadline = time.monotonic() + cap
    grown_at = time.monotonic()
    length = len(output)
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"TUI exited while draining: {bytes(output)!r}")
        select.select([master_fd], [], [], 0.05)
        read_available(master_fd, output)
        if len(output) != length:
            length = len(output)
            grown_at = time.monotonic()
        elif time.monotonic() - grown_at >= quiet:
            return True
    return False


def tab_until(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    needle: Needle,
) -> bytes:
    """Press Tab until the screen shows [needle], or give up after a lap.

    Name the surface the walk is going to, not one on the way. The ring is
    not fixed: Masc_tui_surface_navigation.is_surface_active leaves Approvals out of it
    while nothing is pending, so a walk that stopped there first burned
    every press on a screen that did not exist. Six scenarios used it as a
    waypoint to Board, and a seventh fabricated a pending tool approval in
    its fixtures to keep the waypoint alive.
    """
    for _ in range(TAB_CYCLE_BOUND):
        read_available(master_fd, output)
        start = len(output)
        os.write(master_fd, b"\t")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=start,
            timeout=3.0,
        )
        # Asynchronous frames (a feed event row, a clock tick, the previous
        # surface's redraw still in flight) can land between the press and
        # the switch redraw. Judging the first frame pressed Tab again over
        # surfaces that had already drawn, and the walk lapped its target
        # without ever reading it; judging everything since the walk began
        # returned while the walk had already overshot. So the press is
        # judged only once its frames have stopped arriving: after the
        # quiet, everything since the press belongs to this press.
        drain_until_quiet(process, master_fd, output)
        found = find_needle(output, needle, start)
        if found < 0:
            continue
        frame_end = output.find(FRAME_END, found)
        if frame_end < 0:
            wait_for_output(
                process,
                master_fd,
                output,
                FRAME_END,
                start=found,
                timeout=3.0,
            )
            frame_end = output.find(FRAME_END, found)
        frame_end += len(FRAME_END)
        frame_begin = output.rfind(FRAME_END, start, found)
        frame_begin = start if frame_begin < 0 else frame_begin + len(FRAME_END)
        return bytes(output[frame_begin:frame_end])
    raise AssertionError(
        f"tabbed {TAB_CYCLE_BOUND} times without reaching {needle!r}; "
        f"last frame: {bytes(output[-1500:])!r}"
    )


def release_and_wait_for_frame(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    response: GatedHttpResponse,
    needle: bytes,
) -> bytes:
    read_available(master_fd, output)
    start = len(output)
    response.release.set()
    wait_for_output(process, master_fd, output, needle, start=start, timeout=3.0)
    needle_end = end_of_needle(output, needle, start)
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=needle_end,
        timeout=3.0,
    )
    frame_end = output.find(FRAME_END, needle_end) + len(FRAME_END)
    return bytes(output[start:frame_end])


def frame_containing(
    segment: bytes, needle: bytes | re.Pattern[bytes]
) -> bytes:
    needle_offset = find_needle(segment, needle)
    frame_start = segment.rfind(FRAME_START, 0, needle_offset + 1)
    frame_end = segment.find(FRAME_END, needle_offset)
    if needle_offset < 0 or frame_start < 0 or frame_end < 0:
        raise AssertionError(
            f"could not isolate frame containing {needle!r}: {segment!r}"
        )
    return segment[frame_start : frame_end + len(FRAME_END)]


def fixture_cell_width(text: str) -> int:
    widths = {"\u0301": 0, "한": 2, "🙂": 2}
    return sum(widths.get(character, 1) for character in text)


def assert_message_input_frame(
    segment: bytes,
    *,
    row: int,
    columns: int,
    input_text: str,
    cursor_column: int,
) -> None:
    frame_start = segment.rfind(FRAME_START)
    if frame_start >= 0:
        frame = segment[frame_start:]
    else:
        frame_start = segment.rfind(FULL_REDRAW)
        if frame_start >= 0:
            frame = segment[frame_start:]
        else:
            frame = b""
    if not frame:
        raise AssertionError(f"message update has no frame boundary: {segment!r}")
    cursors = list(CURSOR_RE.finditer(frame))
    if not cursors:
        raise AssertionError(f"message frame has no visible cursor: {frame!r}")
    cursor = cursors[-1]
    actual_cursor = (int(cursor.group(1)), int(cursor.group(2)))
    if actual_cursor != (row, cursor_column):
        raise AssertionError(
            f"message cursor {actual_cursor!r}, expected {(row, cursor_column)!r}: "
            f"{frame!r}"
        )

    row_marker = f"\x1b[{row};1H".encode()
    row_start = frame.rfind(row_marker, 0, cursor.start())
    if row_start < 0:
        raise AssertionError(f"message frame has no row {row}: {frame!r}")
    content_start = row_start + len(row_marker)
    next_position = POSITION_RE.search(frame, content_start)
    if next_position is None:
        raise AssertionError(f"message row {row} has no end boundary: {frame!r}")
    row_bytes = frame[content_start : next_position.start()]
    rendered_row = CSI_RE.sub(b"", row_bytes).decode("utf-8").rstrip("\r\n")
    if f"> {input_text}" not in rendered_row:
        raise AssertionError(f"message row lost {input_text!r}: {rendered_row!r}")
    # The outer frame is gone (clutter audit); the row boundary is the
    # positioning escape the regex above already found, not a border glyph.
    if "…" in rendered_row and "…" not in input_text:
        raise AssertionError(f"message row truncated fitting input: {rendered_row!r}")
    actual_width = fixture_cell_width(rendered_row)
    if actual_width != columns:
        raise AssertionError(
            f"message row uses {actual_width} cells, expected {columns}: "
            f"{rendered_row!r}"
        )


def wait_for_terminal_input_consumed(slave_fd: int) -> None:
    deadline = time.monotonic() + 3.0
    while True:
        pending = struct.unpack(
            "I",
            fcntl.ioctl(slave_fd, termios.FIONREAD, struct.pack("I", 0)),
        )[0]
        if pending == 0:
            return
        if time.monotonic() >= deadline:
            raise AssertionError(f"terminal still has {pending} unread input bytes")
        time.sleep(0.01)


def resize_and_wait(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    *,
    rows: int,
    columns: int,
    needle: bytes | re.Pattern[bytes],
    controls: tuple[bytes, ...] = (),
    final_cursor: bytes | None = None,
) -> bytes:
    read_available(master_fd, output)
    start = len(output)
    fcntl.ioctl(
        master_fd,
        termios.TIOCSWINSZ,
        struct.pack("HHHH", rows, columns, 0, 0),
    )
    frame_start = start
    for control in controls:
        wait_for_output(
            process,
            master_fd,
            output,
            control,
            start=frame_start,
            timeout=3.0,
        )
        if control == FULL_REDRAW:
            frame_start = output.find(control, frame_start)
    wait_for_output(
        process,
        master_fd,
        output,
        needle,
        start=frame_start,
        timeout=3.0,
    )
    frame_needle_end = end_of_needle(output, needle, frame_start)
    if final_cursor is not None:
        wait_for_output(
            process,
            master_fd,
            output,
            final_cursor,
            start=frame_needle_end,
            timeout=3.0,
        )
        cursor_start = output.find(final_cursor, frame_needle_end)
        wait_for_output(
            process,
            master_fd,
            output,
            b"\x1b[?7h",
            start=cursor_start,
            timeout=3.0,
        )
        frame_end = output.find(FRAME_END, cursor_start) + len(FRAME_END)
        segment = bytes(output[frame_start:frame_end])
        last_hidden = segment.rfind(b"\x1b[?25l")
        last_visible = segment.rfind(b"\x1b[?25h")
        actual_cursor = b"\x1b[?25h" if last_visible > last_hidden else b"\x1b[?25l"
        if actual_cursor != final_cursor:
            raise AssertionError(
                f"resize ended in {actual_cursor!r}, expected {final_cursor!r}: "
                f"{segment!r}"
            )
        return segment
    return bytes(output[frame_start:])


def kill_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        try:
            process.kill()
        except ProcessLookupError:
            pass


def configure_child_terminal() -> None:
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    os.tcsetpgrp(0, os.getpgrp())
    if os.tcgetpgrp(0) != os.getpgrp():
        raise OSError("child process group does not own the controlling terminal")


def stable_termios(attributes: list[Any]) -> list[Any]:
    stable = attributes.copy()
    # The kernel may set PENDIN while canonical input is restored and the
    # launcher is stopped. It is transient input state, not a saved tty mode.
    stable[3] = int(stable[3]) & ~int(getattr(termios, "PENDIN", 0))
    return stable


# How far down the keeper list a scan may walk. The fixture roster is small;
# the bound exists so a keeper that never reports itself selected fails here
# instead of looping.
KEEPER_ROW_SCAN_BOUND = 24

# How long one arrow press has to land the selection band. The surface redraws
# on a 16ms interval, so a step that moves the cursor shows within a few frames;
# a step that cannot move it shows nothing however long it is given. The bound
# above times this is what a run spends before it reports the row unreachable.
KEEPER_ROW_STEP_TIMEOUT_S = 1.0


def keeper_row_selected(name: bytes) -> re.Pattern[bytes]:
    """A needle that matches only while ``name`` is the selected keeper row.

    Selection is a full-row reverse band: the row opens with reverse video
    and, because the band folds every cell colour, carries no other escape
    before the name. The legacy caret-plus-bold-name shape is still accepted
    while unconverted builds circulate.
    """
    return re.compile(
        rb"(?:\x1b\[7m[^\x1b\n]*" + re.escape(name)
        + rb"|\x1b\[0m \x1b\[1m" + re.escape(name) + rb")"
    )


def keeper_metadata(name: str) -> dict[str, object]:
    # No agent_name: RFC-0393 (#31198) cut name-encoded identity out of the
    # keeper meta schema, and the current-schema validator rejects metas
    # carrying fields it does not know.
    metadata: dict[str, object] = {
        "schema": "masc.keeper_meta.v2",
        "name": name,
        "instructions": "",
        "trace_id": f"trace-{name}",
        "created_at": "2026-08-22T00:00:00Z",
        "updated_at": "2026-08-22T00:00:00Z",
        "last_proactive_outcome": "never_started",
        "last_proactive_reason": "",
        "last_proactive_preview": "",
        "message_scope_ack_id": None,
        "usage_cursor": None,
        "last_usage_resolution": None,
        "last_runtime_attempt": None,
        "paused": False,
        "latched_reason": None,
        "current_task_id": None,
        "keeper_id": None,
        "agent_core_env": {},
    }
    for field in (
        "total_turns",
        "total_input_tokens",
        "total_output_tokens",
        "total_tokens",
        "total_cost_usd",
        "last_turn_ts",
        "last_input_tokens",
        "last_output_tokens",
        "last_total_tokens",
        "last_latency_ms",
        "proactive_count_total",
        "last_proactive_ts",
        "proactive_visible_count_total",
        "last_visible_proactive_ts",
    ):
        metadata[field] = 0
    return metadata


def seed_workspace(
    base_path: str,
    keeper_names: tuple[str, ...] = ("alpha", "beta"),
) -> None:
    masc_path = Path(base_path) / ".masc"
    keepers_path = masc_path / "keepers"
    keepers_path.mkdir(parents=True)
    for name in keeper_names:
        (keepers_path / f"{name}.json").write_text(
            json.dumps(keeper_metadata(name)), encoding="utf-8"
        )
    tasks_path = masc_path / "tasks"
    tasks_path.mkdir()
    (tasks_path / "backlog.json").write_text(
        json.dumps(
            {
                "tasks": [],
                "last_updated": "2026-08-22T00:00:00Z",
                "version": 1,
            }
        ),
        encoding="utf-8",
    )


def seed_row_budget_workspace(base_path: str) -> None:
    tasks = [
        {
            "id": f"task-{index}",
            "title": f"Task task-{index}",
            "status": "todo",
            "priority": index,
            "created_at": "2026-08-22T00:00:00Z",
        }
        for index in range(1, 6)
    ]
    backlog_path = Path(base_path) / ".masc" / "tasks" / "backlog.json"
    backlog_path.write_text(
        json.dumps(
            {
                "tasks": tasks,
                "last_updated": "2026-08-22T00:00:00Z",
                "version": 1,
            }
        ),
        encoding="utf-8",
    )


def transport_health_fixture() -> HttpFixture:
    """A quiet transport: sse carries the stream, the other paths are down.

    The TUI reads this surface on every refresh, so a fixture set without it
    would add a load-failure event and push the oldest event out of a short
    viewport.
    """
    return (
        200,
        {
            "summary": {"primary_path": "sse", "queue_pressure": "steady"},
            "sse": {"sessions_total": 1},
            "websocket": {"listening": False},
            "grpc": {"listening": False, "events_dropped": 0},
        },
    )


def row_budget_http_fixtures() -> HttpFixtures:
    attention_items = [
        {
            "kind": "incident",
            "severity": "warning",
            "summary": f"attention-{index}",
            "target_type": "task",
            "target_id": f"task-{index}",
        }
        for index in range(1, 7)
    ]
    post = {
        "id": "post-1",
        "author": "board-author",
        "title": "Row budget fixture",
        "body": BOARD_CELL_BODY,
        "votes": 1,
        "comment_count": 5,
        "created_at_iso": "2026-08-22T00:00:00Z",
    }
    comments = [
        {
            "id": f"comment-{index}",
            "author": f"author-{index}",
            "content": (
                f"**comment-{index}**" if index == 1 else f"comment-{index}"
            ),
            "created_at_iso": "2026-08-22T00:00:00Z",
        }
        for index in range(1, 6)
    ]
    return {
        # This layout scenario has no currency. Answer the Overview's roster
        # read so an unrelated fixture failure does not consume a body row.
        "/api/v1/gate/keepers?detailed=true": (
            200,
            {"candle": {"status": "off"}, "count": 0, "total": 0,
             "truncated": False, "keepers": []},
        ),
        "/api/v1/dashboard/transport-health": transport_health_fixture(),
        "/api/v1/dashboard/briefing": (
            200,
            {
                "summary": {
                    "workspace_health": "ok",
                    "cluster": "cluster-a",
                    "project": "project-a",
                },
                "generated_at": "2026-08-22T00:00:00Z",
                "incidents": attention_items,
                "attention_queue": [],
                "attention_items": [],
                "agent_briefs": [],
                "keepers_listing": {"state": "listed"},
                "keepers_unread": [],
            },
        ),
        "/api/v1/board?sort_by=hot": (200, {"posts": [post]}),
        "/api/v1/board/post-1?format=flat": (
            200,
            board_detail_page(post, comments),
        ),
    }


def overview_event_briefing(cluster: str = "cluster-a") -> dict[str, object]:
    return {
        "summary": {
            "workspace_health": "ok",
            "cluster": cluster,
            "project": "project-a",
        },
        "generated_at": "2026-08-22T00:00:00Z",
        "incidents": [],
        "attention_queue": [],
        "attention_items": [],
        "agent_briefs": [],
        "keepers_listing": {"state": "listed"},
        "keepers_unread": [],
    }


DASHBOARD_GOALS_PATH = "/api/v1/dashboard/goals"
ACCOUNT_EMAILS_PATH = "/api/v1/setup/account-emails"


def empty_account_emails_fixture() -> HttpResponse:
    """No account email, the shape the server sends when no loaded runtime
    runs on an account.

    Usage reads it for the Plan usage section on every refresh. Unmocked,
    the 503 sentinel would add an "account emails unread" note to every
    Usage scenario whose providers draw rows. A scenario about the
    emails keys this path itself.
    """
    return (200, {"account_emails": []})


def empty_goals_fixture() -> HttpResponse:
    """A goal tree with no goals, the shape the server sends for a workspace
    that has none.

    The Overview reads it for its GOALS section. Unmocked, the 503 sentinel
    would draw "goals unavailable" in every Overview scenario instead of the
    section a scenario actually meets. A scenario that is about goals keys
    this path itself.
    """
    return (200, {
        "generated_at": "2026-09-23T00:00:00Z",
        "tree": [],
        "summary": {
            "total_goals": 0,
            "active_goals": 0,
            "phase_counts": {
                "executing": 0,
                "verifying": 0,
                "awaiting_confirmation": 0,
                "completed": 0,
                "dropped": 0,
            },
            "total_tasks": 0,
            "done_tasks": 0,
            "pending_approvals": 0,
        },
    })


def empty_runtime_resolved_fixture() -> HttpResponse:
    """A runtime catalogue with no runtime, the shape the server sends for a
    workspace that configured none.

    The Overview reads it for its Providers section. Unmocked, the 503
    sentinel would draw "providers unavailable" in every Overview scenario
    and take its rows from the tasks. With no provider account the section
    draws nothing. A scenario that is about runtimes keys this path itself.
    """
    return (200, {
        "generated_at_iso": "2026-09-23T00:00:00Z",
        "source": RUNTIME_RESOLVED_PATH,
        "config_path": None,
        "default_runtime": None,
        "media_failover": [],
        "media_failover_declared": [],
        "runtimes": [],
        "lanes": [],
        "assignments": [],
        "provider_usage_windows_since": 1790179140.2,
        "provider_usage_windows": [],
    })


def fleet_safety_fixture() -> HttpResponse:
    """A fleet reading the TUI can decode.

    Without it the poll fails and the TUI records a "fleet safety data
    unreliable" event, which is correct behaviour but adds a row to scenarios
    that are counting the event list. Every field the TUI reads is here,
    with the schema that marks a reading: the TUI requires each one, because
    a missing observation must not become a zero count. The snapshot beside
    it says the reading is current; without it the TUI refuses the reading,
    because a stale snapshot serves a past one.
    """
    return (200, {"full_health_snapshot": {"status": "ready"}, "keeper_fleet_safety": {
        "schema": "masc.keeper_fleet_operator.v1",
        "status": "ok",
        "blocker": None,
        "operator_action_required": False,
        "bootable_keeper_count": 0,
        "bootable_keeper_names": [],
        "running_keeper_fiber_count": 0,
        "running_keeper_names": [],
        "executable_keeper_fiber_count": 0,
        "executable_keeper_names": [],
        "failing_keeper_fiber_count": 0,
        "recovering_keeper_fiber_count": 0,
        "turn_configuration_error_keeper_count": 0,
        "turn_configuration_error_keeper_names": [],
        "official_client_recovery_required_keeper_count": 0,
        "official_client_recovery_required_keeper_names": [],
        "paused_keeper_count": 0,
        "target_reaction_capacity_count": 0,
        "reaction_capacity_shortfall_count": 0,
        "active_task_owner_without_executable_fiber_count": 0,
        "completion_authority_pending_task_count": 0,
        "active_task_owner_scan_error_count": 0,
    }})


def with_workspace_identity(
    fixtures: HttpFixtures | None, base_path: str
) -> HttpFixtures:
    """Answer /health?full=1 with the workspace the harness actually chose.

    The TUI canonicalises its own base path against the one this reports and
    refuses local Keeper/context/metrics reads when they differ. A fixture
    that names no path leaves every scenario reading an unproven workspace,
    which is not the state any of them mean to describe.

    Scenario-owned health fixtures keep their fields; only the paths block is
    filled in. A raw or callable response is left alone -- a scenario that
    writes its own health body owns what it says.
    """
    # In place, not a copy: a scenario keeps the dict it handed over and swaps
    # a response into it mid-run (a lane read that starts failing, a board list
    # that arrives late). A copy leaves the server reading the original, and
    # nine scenarios waited out their timeouts for a response that had already
    # been written somewhere the server could not see.
    merged: dict[str, HttpFixture] = fixtures if fixtures is not None else {}
    paths = {
        "cwd": base_path,
        "effective_base_path": base_path,
        "effective_masc_root": os.path.join(base_path, ".masc"),
        "effective_has_masc_dir": True,
    }
    # The identity probe reads the compact /health; the fleet reading reads
    # /health?full=1. Both carry the paths block, and a scenario may declare
    # either, so both keys are filled.
    for key in ("/health", "/health?full=1"):
        existing = merged.get(key)
        if existing is None:
            merged[key] = (200, {"paths": paths})
            continue
        if isinstance(existing, tuple):
            status, payload = existing
            if isinstance(payload, dict):
                body = dict(cast(dict[str, object], payload))
                body["paths"] = {
                    **cast(dict[str, object], body.get("paths", {})),
                    **paths,
                }
                merged[key] = (status, body)
    return merged


def overview_event_http_fixtures() -> HttpFixtures:
    return {
        "/health?full=1": fleet_safety_fixture(),
        # The Overview reads the roster for its Candle observation even when
        # the Keeper pane is hidden. An unrelated scenario has no currency.
        "/api/v1/gate/keepers?detailed=true": (
            200,
            {"candle": {"status": "off"}, "count": 0, "total": 0,
             "truncated": False, "keepers": []},
        ),
        "/api/v1/dashboard/transport-health": transport_health_fixture(),
        "/api/v1/dashboard/briefing": (200, overview_event_briefing()),
        "/api/v1/operator?view=summary&include_messages=0&include_keepers=0": (
            200,
            {
                "pending_confirm_envelope": {
                    "items": [],
                    "summary": {
                        "actor_filter": "masc-tui",
                        "filter_active": True,
                        "visible_count": 0,
                        "total_count": 0,
                        "hidden_count": 0,
                        "hidden_actors": [],
                        "confirm_required_actions": [],
                    },
                }
            },
        ),
        "/api/v1/board?sort_by=hot": (200, {"posts": []}),
        "/api/v1/dashboard/planning": (
            200,
            {
                "goals": [],
                "goal_history": {"unlisted": []},
                "rollup": {
                    "active_count": 0,
                    "verifying_count": 0,
                    "awaiting_confirmation_count": 0,
                    "done_count": 0,
                    "dropped_count": 0, "paused_count": 0, "blocked_count": 0,
                },
                "task_backlog": {
                    "todo": 0,
                    "claimed": 0,
                    "in_progress": 0,
                    "awaiting_verification": 0,
                    "done": 0,
                    "cancelled": 0,
                },
                "generated_at": "2026-08-22T00:00:00Z",
            },
        ),
    }


def keeper_roster_meta(name: str) -> dict[str, object]:
    # The roster row nests the keeper's own declaration under [meta], and the
    # decoder reads sandbox_profile from there rather than from a second
    # top-level copy (lib/tui_decode.ml, decode_keeper_runtime). A row without
    # [meta] is not a smaller server response -- keeper_brief_meta_json always
    # writes it -- and dropping it fails the whole list decode, which the TUI
    # reports as a malformed roster rather than as a per-row gap. Every runtime
    # column then draws as absent.
    return {
        "name": name,
        "trace_id": f"trace-{name}",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "sandbox_profile": "docker",
    }


def keeper_runtime_http_fixtures(
    *,
    alpha_runtime_id: str = "anthropic.claude-opus-5",
    beta_runtime_id: str = "anthropic.claude-sonnet-4",
) -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/gate/keepers?detailed=true"] = (
        200,
        {
            "candle": {"status": "off"},
            "count": 2,
            "total": 2,
            "truncated": False,
            "keepers": [
                {
                    "runtime_class": "keeper",
                    "name": "alpha",
                    "meta": keeper_roster_meta("alpha"),
                    "status": "active",
                    "health": "healthy",
                    "paused": False,
                    "phase": "running",
                    "keepalive_running": True,
                    "activation_mode": "autonomous",
                    "runtime_id": alpha_runtime_id,
                    "runtime_blocker_summary": None,
                    "candle_balance_milli": None,
                    "candle_account_revision": None,
                    "portrait": {"state": "ready", "equipment": {"face": "bare_face", "neck": "bare_neck", "head": "bare_head", "hand": "empty_hand", "base": "no_dish"}},
                },
                {
                    "runtime_class": "keeper",
                    "name": "beta",
                    "meta": keeper_roster_meta("beta"),
                    "status": "idle",
                    "health": "idle",
                    "paused": True,
                    "phase": "paused",
                    "keepalive_running": True,
                    "activation_mode": "on_demand",
                    "runtime_id": beta_runtime_id,
                    "runtime_blocker_summary": None,
                    "candle_balance_milli": None,
                    "candle_account_revision": None,
                    "portrait": {"state": "ready", "equipment": {"face": "bare_face", "neck": "bare_neck", "head": "bare_head", "hand": "empty_hand", "base": "no_dish"}},
                },
            ],
        },
    )
    return fixtures



PLANNING_PATH = "/api/v1/dashboard/planning"


def planning_goal(goal_id: str, title: str) -> dict[str, object]:
    # The verification block is not optional on the wire. The server writes a
    # default completion record for a goal with no ledger row precisely so an
    # absent state cannot be read as "not verified yet", and the TUI marks a
    # goal whose block is missing rather than guessing. A fixture that leaves
    # it out is not a smaller server response, it is one the server never
    # sends -- and it puts a warning mark on every row here.
    return {
        "id": goal_id,
        "title": title,
        "phase": "executing",
        "priority": 1,
        "metric": f"metric-{goal_id}",
        "target_value": "100%",
        "verification": {"completion": {"state": "idle"}},
        "verifier_unreconciled": None,
    }


def planning_snapshot(goals: list[dict[str, object]]) -> HttpResponse:
    return (
        200,
        {
            "goals": goals,
            # Include retained history so resize tests account for its two
            # non-selectable rows above the active goal list.
            "goal_history": {
                "unlisted": [
                    {
                        "goal_id": "goal-history-29424",
                        "title": "earlier-plan-29424",
                        "opened_at": "2026-08-20T00:00:00Z",
                        "closed_at": "2026-08-21T00:00:00Z",
                        "final_phase": "completed",
                        "lifetime_hours": 24.0,
                    }
                ]
            },
            "rollup": {
                "active_count": len(goals),
                "verifying_count": 0,
                "awaiting_confirmation_count": 0,
                "done_count": 0,
                "dropped_count": 0, "paused_count": 0, "blocked_count": 0,
            },
            "task_backlog": {
                "todo": 0,
                "claimed": 0,
                "in_progress": 0,
                "awaiting_verification": 0,
                "done": 0,
                "cancelled": 0,
            },
            "generated_at": "2026-08-22T00:00:00Z",
        },
    )


def planning_selection_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    fixtures[PLANNING_PATH] = planning_snapshot(
        [
            planning_goal("goal-a-29424", "plan-alpha-29424"),
            planning_goal("goal-b-29424", "plan-beta-29424"),
            planning_goal("goal-c-29424", "plan-charlie-29424"),
        ]
    )
    return fixtures


def planning_activity_http_fixtures() -> HttpFixtures:
    goal_id = "goal-actor-clarity"
    fixtures = overview_event_http_fixtures()
    fixtures[PLANNING_PATH] = planning_snapshot(
        [planning_goal(goal_id, "Actor-visible goal activity")]
    )
    fixtures[f"/api/v1/dashboard/goals/detail?goal_id={goal_id}"] = (
        200,
        {
            "approval_queue_state": {"state": "ready"},
            "timeline": [
                {
                    "ts": "2026-08-21T04:00:00Z",
                    "kind": "task",
                    "lane": "task:task-actor",
                    "title": "Actor-visible task",
                    "summary": (
                        "done · completed by beta · handoff by alpha: "
                        "continue from the saved checkpoint"
                    ),
                    "severity": "ok",
                }
            ],
        },
    )
    return fixtures


def approval_selection_item(
    token: str,
    *,
    action_type: str,
    target_type: str,
    target_id: str | None,
    delegated_tool: str,
    created_at: str,
) -> dict[str, object]:
    return {
        "confirm_token": token,
        "trace_id": f"trace-{token}",
        "actor": "masc-tui",
        "action_type": action_type,
        "target_type": target_type,
        "target_id": target_id,
        "payload": {"reason": f"reason-{token}"},
        "delegated_tool": delegated_tool,
        "created_at": created_at,
        "expires_at": None,
    }


def approval_selection_snapshot(
    items: list[dict[str, object]],
) -> tuple[int, object]:
    count = len(items)
    return (
        200,
        {
            "pending_confirm_envelope": {
                "items": items,
                "summary": {
                    "actor_filter": "masc-tui",
                    "filter_active": True,
                    "visible_count": count,
                    "total_count": count,
                    "hidden_count": 0,
                    "hidden_actors": [],
                    "confirm_required_actions": [],
                },
            }
        },
    )


def approval_selection_http_fixtures() -> tuple[
    HttpFixtures,
    list[dict[str, object]],
    dict[str, object],
]:
    approval_a = approval_selection_item(
        "token-a",
        action_type="namespace_pause",
        target_type="workspace",
        target_id=None,
        delegated_tool="masc_pause",
        created_at="2026-08-22T00:03:00Z",
    )
    approval_b = approval_selection_item(
        "token-b",
        action_type="keeper_probe",
        target_type="keeper",
        target_id="beta",
        delegated_tool="masc_keeper_status",
        created_at="2026-08-22T00:02:00Z",
    )
    approval_c = approval_selection_item(
        "token-c",
        action_type="keeper_message",
        target_type="keeper",
        target_id="gamma",
        delegated_tool="masc_keeper_delegate",
        created_at="2026-08-22T00:01:00Z",
    )
    approval_new = approval_selection_item(
        "token-new",
        action_type="keeper_recover",
        target_type="keeper",
        target_id="delta",
        delegated_tool="masc_keeper_recover",
        created_at="2026-08-22T00:04:00Z",
    )
    initial_items = [approval_a, approval_b, approval_c]
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/operator?view=summary&include_messages=0&include_keepers=0"] = (
        approval_selection_snapshot(initial_items)
    )
    # The surface also polls the held tool calls. An unanswered poll is not a
    # quiet zero here: the header says ", held calls stale" beside the count,
    # because a list that survived a failed refresh is the one an operator
    # decides against. This scenario is about selection, so it answers the
    # poll with the honest empty queue.
    fixtures["/api/v1/keepers/tool-approvals"] = (200, {"pending": []})
    # The questions poll is the same: left unanswered, the header says
    # ", questions unread" beside the count.
    fixtures[KEEPER_ASKS_PATH] = (200, {"keeper": None, "open_count": 0, "asks": []})
    # And the Gate queue: left unanswered, the header says ", Gate queue
    # unread" beside the count.
    fixtures["/api/v1/dashboard/gate"] = empty_gate_snapshot()
    return fixtures, initial_items, approval_new


def board_selection_post(suffix: str, title: str, body: str) -> dict[str, object]:
    return {
        "id": f"post-{suffix}",
        "author": "board-author",
        "title": title,
        "body": body,
        "votes": 1,
        "comment_count": 0,
        "created_at_iso": "2026-08-22T00:00:00Z",
    }


def board_detail_page(
    post: dict[str, object], comments: list[dict[str, object]],
    *, offset: int | None = None, limit: int = 20,
) -> dict[str, object]:
    total = len(comments)
    first = max(0, total - limit) if offset is None else offset
    page = comments[first:first + limit]
    next_offset = first + len(page) if first + len(page) < total else None
    by_id = {comment["id"]: comment for comment in comments}
    context_ids = set()
    for comment in page:
        current = comment
        while current["id"] not in context_ids:
            context_ids.add(current["id"])
            parent = by_id.get(current.get("parent_id"))
            if parent is None:
                break
            current = parent
    return {
        "post": {**post, "comment_count": total},
        "comments": page,
        "comment_context": [comment for comment in comments if comment["id"] in context_ids],
        "comment_revision": hashlib.sha256(json.dumps(
            [[comment["id"], comment.get("parent_id")] for comment in comments],
            ensure_ascii=False, separators=(",", ":")).encode()).hexdigest(),
        "comment_page": {
            "offset": first,
            "returned": len(page),
            "total": total,
            "has_more": next_offset is not None,
            "next_offset": next_offset,
        },
    }


def board_selection_http_fixtures() -> HttpFixtures:
    posts = [
        board_selection_post("a", "Alpha", "list-body-a"),
        board_selection_post("b", "Bravo", "list-body-b"),
        board_selection_post("c", "Charlie", "list-body-c"),
    ]
    bravo_body = "detail-body-bravo\n" + "\n".join(
        f"bravo-{index:02d}" for index in range(1, 46)
    )
    bravo_detail = board_selection_post("b", "Bravo", bravo_body)
    charlie_detail = board_selection_post("c", "Charlie", "detail-body-charlie")
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})
    fixtures["/api/v1/board/post-b?format=flat"] = (
        200,
        board_detail_page(bravo_detail, []),
    )
    fixtures["/api/v1/board/post-c?format=flat"] = (
        200,
        board_detail_page(charlie_detail, []),
    )
    return fixtures


def board_json_http_fixtures() -> HttpFixtures:
    json_body = json.dumps(
        {
            "verification_request": {
                "id": "vrf-board-json",
                "task_id": "task-1200",
                "worker": "lane-smith",
                "approved": True,
                "attempt": 3,
            }
        },
        separators=(",", ":"),
    )
    markdown_body = "# Normal heading\n\n**Markdown stays authored.**"
    posts = [
        board_selection_post("json", "JSON evidence", json_body),
        board_selection_post("markdown", "Markdown note", markdown_body),
    ]
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})
    fixtures["/api/v1/board/post-json?format=flat"] = (
        200,
        board_detail_page(
            posts[0],
            [board_detail_comment("json-comment", 'Evidence note: {"probe": true}')],
        ),
    )
    fixtures["/api/v1/board/post-markdown?format=flat"] = (
        200,
        board_detail_page(posts[1], []),
    )
    return fixtures


def board_detail_comment(comment_id: str, content: str) -> dict[str, object]:
    return {
        "id": comment_id,
        "author": "detail-author",
        "content": content,
        "created_at_iso": "2026-08-22T00:00:00Z",
    }


def board_detail_authority_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    posts = [
        board_selection_post("a", "Alpha", "list-body-a"),
        board_selection_post("b", "Bravo", "list-body-b"),
    ]
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})
    fixtures["/api/v1/board/post-a?format=flat"] = (
        200,
        board_detail_page(
            board_selection_post("a", "Alpha authoritative", "a-authoritative-detail"),
            [board_detail_comment("comment-a", "a-only-comment")],
        ),
    )
    late_list = GatedHttpResponse(
        (
            200,
            {
                "posts": [
                    board_selection_post("a", "Alpha light", "a-late-light-body"),
                    board_selection_post("b", "Bravo", "list-body-b"),
                    board_selection_post("c", "Charlie", "list-body-c"),
                ]
            },
        )
    )
    return fixtures, late_list


def board_detail_isolation_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    posts = [
        board_selection_post("a", "Alpha", "list-body-a"),
        board_selection_post("b", "Bravo", "list-body-b"),
    ]
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})
    fixtures["/api/v1/board/post-a?format=flat"] = (
        200,
        board_detail_page(
            board_selection_post("a", "Alpha", "a-detail-body"),
            [board_detail_comment("comment-a", "a-only-comment")],
        ),
    )
    b_failure = GatedHttpResponse((503, {"error": "b-detail-failed"}))
    fixtures["/api/v1/board/post-b?format=flat"] = b_failure
    return fixtures, b_failure


def board_paginated_detail_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    posts = [
        board_selection_post("a", "Alpha", "list-body-a"),
        board_selection_post("b", "Bravo", "list-body-b"),
    ]
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})
    fixtures["/api/v1/board/post-a?format=flat"] = (
        200,
        board_detail_page(board_selection_post("a", "Alpha", "a-recovered-detail"), []),
    )
    fixtures["/api/v1/board/post-b?format=flat"] = (
        200,
        board_detail_page(
            board_selection_post("b", "Bravo", "b-initial-detail"),
            [board_detail_comment("comment-b", "b-initial-comment")],
        ),
    )
    late_b = GatedHttpResponse(
        (
            200,
            board_detail_page(
                board_selection_post("b", "Bravo", "b-late-detail"),
                [board_detail_comment("comment-b-late", "b-late-comment")],
            ),
        )
    )
    return fixtures, late_b


def wait_for_stop(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    *,
    timeout: float,
    description: str,
) -> None:
    deadline = time.monotonic() + timeout
    while True:
        read_available(master_fd, output)
        waited_pid, wait_status = os.waitpid(process.pid, os.WNOHANG | os.WUNTRACED)
        if waited_pid == process.pid:
            if os.WIFSTOPPED(wait_status):
                return
            process.returncode = os.waitstatus_to_exitcode(wait_status)
            raise AssertionError(
                f"TUI launcher exited before {description}: status={process.returncode}"
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            kill_process_group(process)
            process.wait(timeout=2.0)
            raise AssertionError(f"timed out waiting for {description}")
        select.select([master_fd], [], [], min(0.05, remaining))


def path_without_masc(path: str) -> str:
    """PATH with every directory that holds an executable [masc] left out."""
    return os.pathsep.join(
        entry
        for entry in path.split(os.pathsep)
        if entry
        and not (
            os.path.isfile(os.path.join(entry, "masc"))
            and os.access(os.path.join(entry, "masc"), os.X_OK)
        )
    )


@dataclass(frozen=True)
class RunEveryScenario:
    """Every scenario a family calls runs. A suite importing this module gets this."""


@dataclass(frozen=True)
class RunNamedScenarios:
    """Only scenarios whose description is in ``names`` run; each one that does is kept in ``ran``."""

    names: frozenset[str]
    ran: list[str]


@dataclass(frozen=True)
class CollectScenarioNames:
    """No terminal is opened; each description a family would run is kept in ``names``."""

    names: list[str]


ScenarioSelection = RunEveryScenario | RunNamedScenarios | CollectScenarioNames

# run_family sets this for the length of one family and puts RunEveryScenario
# back when the family ends, raised or not. It is a module value and not a
# parameter because a family reaches run_terminal_scenario through nested
# helpers, and the focused suites that import this module call the runner
# directly; none of them should have to thread a selection through.
# run_terminal_scenario is its only reader.
scenario_selection: ScenarioSelection = RunEveryScenario()


def scenario_admitted(selection: ScenarioSelection, description: str) -> bool:
    """Whether the scenario described as [description] opens a terminal.

    --scenario picks by description, so a family that used one description
    twice could only ever run both. Collecting the family's names is where that
    shows, and it fails there instead of listing the name twice.
    """
    match selection:
        case RunEveryScenario():
            return True
        case RunNamedScenarios(names=names, ran=ran):
            if description not in names:
                return False
            ran.append(description)
            return True
        case CollectScenarioNames(names=collected):
            if description in collected:
                raise AssertionError(
                    f"two scenarios in one family are described as {description!r}; "
                    "give each its own description so --scenario can pick one"
                )
            collected.append(description)
            return False
        case _:
            assert_never(selection)


def tui_executable(path: str) -> str:
    """[path] made absolute, once it is known to name an executable file.

    The launcher shell reports a missing file and stops itself, as it does
    after any exit. Without this check the harness sees a live process and
    waits 30s for "MASC Dashboard" on a screen that is never drawn, and the
    real cause sits at the end of the timeout message.
    """
    executable = os.path.abspath(path)
    if not (os.path.isfile(executable) and os.access(executable, os.X_OK)):
        raise AssertionError(
            f"no executable TUI at {executable} (build it first: dune build bin/masc_tui.exe)"
        )
    return executable


def run_terminal_scenario(
    executable: str,
    *,
    description: str,
    interact: Interaction,
    confirm_exit: bytes = b"q",
    refresh: float = 60.0,
    terminal_cols: int = 100,
    terminal_rows: int = 30,
    workspace: str = WORKSPACE_PAYLOAD,
    http_fixtures: HttpFixtures | None = None,
    http_requests: HttpRequests | None = None,
    prepare_workspace: WorkspaceSetup | None = None,
    preload_input: bytes | None = None,
    extra_args: tuple[str, ...] = (),
    extra_env: dict[str, str] | None = None,
    conflicting_env_base_path: bool = False,
    omit_operator_token: bool = False,
    starts_in_chat: bool = False,
    launch_count: int = 1,
) -> None:
    if not scenario_admitted(scenario_selection, description):
        return
    if launch_count < 1:
        raise ValueError("launch_count must be positive")
    executable = tui_executable(executable)
    workspace_rendered = (
        WORKSPACE_RENDERED if workspace == WORKSPACE_PAYLOAD else workspace.encode()
    )
    master_fd, slave_fd = os.openpty()
    output = PtyOutput()
    process: subprocess.Popen[bytes] | None = None
    try:
        fcntl.ioctl(
            slave_fd, termios.TIOCSWINSZ,
            struct.pack("HHHH", terminal_rows, terminal_cols, 0, 0),
        )
        os.set_blocking(master_fd, False)
        with tempfile.TemporaryDirectory(prefix="masc-tui-keyboard-") as base_path:
            # Health and route fixtures must publish the same workspace identity.
            base_path = os.path.realpath(base_path)
            with test_http_endpoint(
                with_workspace_identity(http_fixtures, base_path), http_requests
            ) as (
                server_port,
                start_http_endpoint,
                set_workspace_base_path,
            ):
                seed_workspace(base_path)
                set_workspace_base_path(base_path)
                env_base_path = base_path
                if conflicting_env_base_path:
                    inherited_base_path = str(Path(base_path, "inherited"))
                    seed_workspace(inherited_base_path, ("env-only",))
                    env_base_path = inherited_base_path
                if prepare_workspace is not None:
                    prepare_workspace(base_path)
                environment = os.environ.copy()
                # The harness owns this temporary workspace. An inherited
                # config override would read the caller's live TUI settings.
                environment.pop("MASC_CONFIG_DIR", None)
                environment.pop("LINES", None)
                environment.pop("COLUMNS", None)
                # Same reason as LINES/COLUMNS: the terminal the assertions
                # describe is the harness's, not the shell's. A developer with
                # NO_COLOR set would run this suite against a TUI drawing no
                # colour at all, and pass or fail on a variable nobody chose
                # here. Both directions leave, so neither shell decides.
                environment.pop("NO_COLOR", None)
                environment.pop("MASC_TUI_FORCE_COLOR", None)
                # Under TMUX the TUI wraps every picture escape for tmux, so a
                # suite run from a tmux shell reads bytes no scenario expects.
                environment.pop("TMUX", None)
                # A scenario's own variables (an $EDITOR stub, say) apply
                # before the fixed set below, so the harness keeps the last
                # word on the terminal it describes.
                # A TUI that reaches no server starts one, and it looks for
                # [masc] beside itself and then on PATH. A developer with an
                # installed masc had scenarios whose fixture did not answer
                # start a real server on the temporary workspace, which
                # outlives the TUI by design and so outlived the test. CI has
                # no masc on PATH, so only a developer's machine did this.
                # The inherited PATH is filtered; a PATH a scenario sets below
                # is that scenario's choice.
                environment["PATH"] = path_without_masc(environment.get("PATH", ""))
                if extra_env is not None:
                    environment.update(extra_env)
                environment.update(
                    {
                        "MASC_BASE_PATH": env_base_path,
                        "MASC_HOST": "127.0.0.1",
                        "MASC_TUI_SYNC": "off",
                        "TERM": "xterm-256color",
                        # The environment is inherited, so whether the TUI finds
                        # a bearer was decided by whoever ran the test. Without
                        # one it posts a seventh event saying so, the events
                        # pane takes the row for it, and the task the Overview
                        # budget assertions look for falls off the bottom --
                        # which passes on a developer's shell and fails in CI.
                        # The harness decides this, like it decides the port and
                        # the terminal.
                        "MASC_TOKEN": "masc-tui-keyboard-regression-token",
                    }
                )
                if omit_operator_token:
                    # A first install holds no bearer yet, and the boot decision
                    # it takes is the one this scenario describes. The harness
                    # sets MASC_TOKEN above for every other scenario, so the one
                    # that means "no token" takes it back out here rather than
                    # leaving the choice to whoever ran the suite.
                    environment.pop("MASC_TOKEN", None)
                process = subprocess.Popen(
                    [
                        "/bin/sh",
                        "-c",
                        # TERM beside INT: the SIGTERM scenario signals the
                        # process group, because this shell is the pid the
                        # harness holds and the TUI is its child. The TUI
                        # installs its own handlers for both, so ignoring
                        # them here only keeps the shell alive to stop
                        # itself after the TUI exits.
                        (
                            "trap '' INT TERM; kill -STOP $$; \"$@\"; tui_status=$?; "
                            'kill -STOP $$; exit "$tui_status"'
                            if launch_count == 1 else
                            "trap '' INT TERM; kill -STOP $$; "
                            f"launches_left={launch_count}; "
                            'while [ "$launches_left" -gt 0 ]; do '
                            '"$@"; tui_status=$?; kill -STOP $$; '
                            'launches_left=$((launches_left - 1)); done; '
                            'exit "$tui_status"'
                        ),
                        "masc-tui-test-launcher",
                        executable,
                        "--base-path",
                        base_path,
                        "--workspace",
                        workspace,
                        "--port",
                        str(server_port),
                        "--refresh",
                        str(refresh),
                        *extra_args,
                    ],
                    stdin=slave_fd,
                    stdout=slave_fd,
                    stderr=slave_fd,
                    env=environment,
                    preexec_fn=configure_child_terminal,
                    close_fds=True,
                )
                output.pid = process.pid
                wait_for_stop(
                    process,
                    master_fd,
                    output,
                    timeout=2.0,
                    description="pre-exec terminal snapshot",
                )
                original_termios: list[Any] = termios.tcgetattr(slave_fd)
                start_http_endpoint()
                if preload_input is not None:
                    # Bytes waiting in the terminal before the process reads
                    # anything. A terminal that answers a capability query
                    # answers within microseconds; this scenario cannot write
                    # the answer later, because the TUI asks and gives up
                    # before the first frame the harness waits for.
                    os.write(master_fd, preload_input)
                os.kill(process.pid, signal.SIGCONT)
                startup_needle = b" \xe2\x96\xb8 chat" if starts_in_chat else b"MASC Dashboard"
                wait_for_output(
                    process,
                    master_fd,
                    output,
                    startup_needle,
                    start=0,
                    timeout=30.0,
                )
                if not starts_in_chat:
                    wait_for_output(
                        process,
                        master_fd,
                        output,
                        workspace_rendered,
                        start=0,
                        timeout=3.0,
                    )
                    frame_offset = output.find(workspace_rendered) + len(workspace_rendered)
                else:
                    frame_offset = output.find(startup_needle) + len(startup_needle)
                wait_for_output(
                    process,
                    master_fd,
                    output,
                    FRAME_END,
                    start=frame_offset,
                    timeout=3.0,
                )
                read_available(master_fd, output)
                if workspace == WORKSPACE_PAYLOAD and not starts_in_chat:
                    assert_workspace_payload_is_inert(output)
                active_lflag = int(termios.tcgetattr(slave_fd)[3])
                if active_lflag & (termios.ICANON | termios.ECHO):
                    raise AssertionError(
                        f"TUI did not enter noncanonical no-echo mode: {active_lflag:#x}"
                    )
                interact(process, master_fd, slave_fd, output, base_path)
                # Most interactions finish by pressing q once. Exit is now an
                # armed action, so the harness supplies the matching confirming
                # input. The dedicated q and Ctrl-C interactions verify that a
                # first press stays alive before asking for the second one.
                if process.poll() is None:
                    os.write(master_fd, confirm_exit)
                wait_for_stop(
                    process,
                    master_fd,
                    output,
                    timeout=5.0,
                    description=f"post-{description} terminal snapshot",
                )
                wait_for_output(
                    process,
                    master_fd,
                    output,
                    b"Goodbye!",
                    start=0,
                    timeout=1.0,
                )
                read_available(master_fd, output)
                if workspace == WORKSPACE_PAYLOAD:
                    assert_workspace_payload_is_inert(output)
                restored_termios = termios.tcgetattr(slave_fd)
                if stable_termios(restored_termios) != stable_termios(original_termios):
                    raise AssertionError(
                        f"{description} did not restore the original terminal mode: "
                        f"before={original_termios!r} after={restored_termios!r}"
                    )
                os.kill(process.pid, signal.SIGCONT)
                return_code = process.wait(timeout=2.0)
                if return_code != 0:
                    raise AssertionError(
                        f"{description} exited with status {return_code}"
                    )
    finally:
        if process is not None and process.poll() is None:
            kill_process_group(process)
            try:
                process.wait(timeout=10.0)
            except subprocess.TimeoutExpired:
                # A raise here replaces whatever the body raised, and the
                # body's exception is the one that says why the scenario
                # failed. Four scenarios were reported as
                # "Command ... timed out after 10.0 seconds" -- the cleanup
                # struggling to reap a TUI that was already wedged -- with the
                # assertion that got them there thrown away. Only re-raise
                # when the body finished cleanly and this is the failure.
                if sys.exc_info()[0] is None:
                    raise
        os.close(master_fd)
        os.close(slave_fd)



def navigate_with_arrows_and_quit(
    process: subprocess.Popen[bytes],
    master_fd: int,
    slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    # The header is drawn before the asynchronous roster, and Down on a list
    # that has not arrived moves nothing, so the wait for beta ran out on the
    # Linux runner while a faster machine got the roster first. Start from a
    # roster that exists; the arrows below are still what this scenario checks.
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[B",
        keeper_row_selected(b"beta"),
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[A",
        keeper_row_selected(b"alpha"),
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"c",
        b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
    )
    send_and_wait(process, master_fd, output, b"q2Q", composer_showing(b"q2Q"))
    # That the letters became draft text is the claim above. Leave the pane,
    # then move to Overview where system events are visible.
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
    # The same claim for the command palette, which is the other place a
    # printable key is text rather than a command. The quit key used to name
    # three fields and let the rest through, so a typed "q" armed the exit and
    # the next one ended the process -- from inside a field showing a cursor.
    send_and_wait(process, master_fd, output, b":", b"MASC Command palette")
    palette = send_and_wait(
        process,
        master_fd,
        output,
        b"qqq",
        # The prompt is styled, then a plain space, then the query, so the
        # colon and what was typed are not adjacent bytes.
        re.compile(rb":(?:" + CSI_RE.pattern + rb")* qqq"),
    )
    if b"press again to quit" in CSI_RE.sub(b"", palette):
        raise AssertionError("a q typed into the palette armed the exit")
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
    send_and_wait(
        process,
        master_fd,
        output,
        b"q",
        b"q: press again to quit",
    )
    # A different key cancels the arm and still performs its surface action.
    tab_until(process, master_fd, output, b"MASC Keepers")
    tab_until(process, master_fd, output, b"MASC Dashboard")
    # Arm once more, then Ctrl-C must withdraw q's separate confirmation. Both
    # notices are events, so waiting for them also synchronizes the signal path.
    send_and_wait(
        process,
        master_fd,
        output,
        b"q",
        b"q: press again to quit",
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x03",
        b"Ctrl-C: press again to quit",
    )
    # If Ctrl-C left q armed, this press would end the process. Instead it
    # starts q's own confirmation; run_terminal_scenario sends the second q.
    send_and_wait(
        process,
        master_fd,
        output,
        b"q",
        b"q: press again to quit",
    )


# The width at which the Keepers table still draws its LIFECYCLE / RUNTIME
# column. The column needs 118 inner cells
# (Render_schedule.keeper_runtime_minimum_inner_width); measured on the built
# TUI, 118 columns drop it and 122 draw it. From
# Masc_tui_acting_pane.threshold_cols (158) the acting pane takes its 56
# columns, so by that arithmetic the column is gone again from 158 until 178.
# 126 is below the pane and above the column's need.
KEEPER_RUNTIME_COLUMN_COLUMNS = 126


# Ctrl-L walks the Activity pane narrow, wide, hidden. The widths are
# Masc_tui_acting_pane.pane_cols and wide_pane_cols; 180 columns holds the
# wide pane (wide_threshold_cols is 176). The pane's header row starts with
# its one-cell border, so "[Recent]" sits one cell inside the pane's left
# edge: the pane's width is read off where that header begins.
ACTING_PANE_CYCLE_COLUMNS = 180
ACTING_PANE_NARROW_COLUMNS = 56
ACTING_PANE_WIDE_COLUMNS = 74

# The pane opens only where the surface keeps
# Masc_tui_acting_pane.surface_floor_cols beside it: the frame's border and
# padding (Masc_tui_frame, four cells) around the inner width the Keepers list
# needs for its flag columns
# (Render_schedule.keeper_flags_minimum_inner_width, 98). Its threshold_cols
# is the narrow pane plus that floor.
ACTING_PANE_SURFACE_FLOOR_COLUMNS = 102
ACTING_PANE_THRESHOLD_COLUMNS = (
    ACTING_PANE_NARROW_COLUMNS + ACTING_PANE_SURFACE_FLOOR_COLUMNS
)

# A terminal that holds the narrow pane and not the wide one: past
# Masc_tui_acting_pane.threshold_cols (158), short of wide_threshold_cols
# (176). Scenarios that need the pane on screen open at this width.
ACTING_PANE_NARROW_TERMINAL_COLUMNS = 160

# A terminal below the pane's threshold where the Keeper detail's nine tabs do
# not fit the row, so its strip has to cut around the entry it marks.
STRIP_CUT_COLUMNS = 94


def select_keeper_row(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    name: bytes,
) -> None:
    """Move the keeper-list cursor onto ``name``, wherever the row sits.

    The roster comes from the fixture plus whatever the live read added, so a
    scenario that presses Enter on the list's first row is asserting an order
    nothing promises. Read the current completed screen after draining pending
    bytes: a roster refresh may have selected the target during that drain.
    Historical highlights do not prove which row is selected now.

    A boundary arrow can produce no frame. Poll without throwing in that case,
    then reconstruct the current screen again before deciding on another key.
    A band in an intermediate frame is not proof of the final selection.
    """
    needle = keeper_row_selected(name)
    for _ in range(KEEPER_ROW_SCAN_BOUND):
        read_available(master_fd, output)
        last_end = output.rfind(FRAME_END)
        completed_end = 0 if last_end < 0 else last_end + len(FRAME_END)
        if output.rfind(FRAME_START) >= completed_end:
            wait_for_output(process, master_fd, output, FRAME_END,
                            start=completed_end, timeout=3.0)
            continue
        rows = screen_rows(bytes(output[:completed_end]), preserve_styles=True)
        if any(find_needle(row, needle) >= 0 for row in rows.values()):
            return
        selected = [row for row, text in rows.items() if b"\x1b[7m" in text]
        if not selected:
            # The list header can arrive before its asynchronous roster. A
            # Down here would race the first selected row and overshoot it.
            wait_for_output(process, master_fd, output, FRAME_END,
                            start=completed_end, timeout=3.0)
            continue
        target = screen_row_of(rows, name)
        key = b"\x1b[A" if 0 <= target < min(selected) else b"\x1b[B"
        start = len(output)
        os.write(master_fd, key)
        poll_for_output(
            process, master_fd, output, FRAME_END,
            start=start, timeout=KEEPER_ROW_STEP_TIMEOUT_S,
        )
    raise AssertionError(
        f"keeper row {name!r} never became selected: {bytes(output[-2000:])!r}"
    )


# A Keeper's question to a human is not an approval; it sits under the queue on
# the same surface. Nothing in this suite had ever driven it, so the answer flow
# shipped on the word of the compiler alone.
KEEPER_ASKS_PATH = "/api/v1/keepers/asks"


def wait_for_http_request(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    requests: HttpRequests,
    *,
    path: str,
) -> bytes:
    deadline = time.monotonic() + 3.0
    while True:
        for request_path, body in requests:
            if request_path == path:
                return body
        read_available(master_fd, output)
        if process.poll() is not None:
            raise AssertionError(f"TUI exited before HTTP request {path!r}")
        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            raise AssertionError(f"timed out waiting for HTTP request {path!r}")
        select.select([master_fd], [], [], min(0.05, remaining))


CURSOR_ROW_RE = re.compile(rb"\x1b\[(\d+);1H")


def frame_row_of(frame: bytes, needle: bytes) -> int:
    """Which terminal row the given text was drawn on.

    The pane redraws only the rows that changed, addressing each one
    absolutely, so a frame is a set of (row, text) pairs rather than a picture
    -- reading a row number out of it is reading what the pane decided, not
    inferring it."""
    offset = frame.find(needle)
    if offset < 0:
        raise AssertionError(f"frame does not contain {needle!r}: {frame!r}")
    positions = [
        match for match in CURSOR_ROW_RE.finditer(frame) if match.start() < offset
    ]
    if not positions:
        raise AssertionError(f"no row address before {needle!r}: {frame!r}")
    return int(positions[-1].group(1))


def screen_rows(drawn: bytes, *, preserve_styles: bool = False) -> dict[int, bytes]:
    """The screen the pane has painted, as row number to plain text.

    A frame is a set of (row, text) pairs, not a picture, so no single frame
    holds the whole screen: a row keeps whatever was written to it until
    something writes it again. Replaying every absolute row address in
    arrival order and keeping the last write to each row reconstructs what
    is on screen. The pane never scrolls the terminal -- it addresses rows
    absolutely -- so nothing moves a row's text to another row behind this.

    A clear ends that inheritance. Everything painted before the last
    FULL_REDRAW is gone from the terminal, and a row the redraw has not
    reached yet is blank rather than holding what it said before -- a
    resize redraws the top of a surface first and the rest a frame later.
    Replaying across a clear reported text the reader could no longer see."""
    cleared = drawn.rfind(FULL_REDRAW)
    if cleared >= 0:
        drawn = drawn[cleared:]
    rows: dict[int, bytes] = {}
    addresses = list(CURSOR_ROW_RE.finditer(drawn))
    for index, address in enumerate(addresses):
        end = (
            addresses[index + 1].start()
            if index + 1 < len(addresses)
            else len(drawn)
        )
        # OSC changes terminal state (such as the title), not screen cells.
        text = OSC_RE.sub(b"", drawn[address.end() : end])
        rows[int(address.group(1))] = text if preserve_styles else CSI_RE.sub(b"", text)
    return rows


def screen_row_of(rows: dict[int, bytes], needle: bytes) -> int:
    """The topmost row [needle] currently occupies, or -1 when it is gone."""
    carrying = [row for row, text in rows.items() if needle in text]
    return min(carrying) if carrying else -1


def screen_text(drawn: bytes) -> bytes:
    """The plain text of the screen, rows joined top to bottom."""
    return b"\n".join(text for _, text in sorted(screen_rows(drawn).items()))


def assert_pane_surface_title_over_gap(
    drawn: bytes, title: bytes, heading: bytes
) -> None:
    """A pane surface puts its gap row above its title, as every screen does.

    Code and Resources drew the title straight under the strip and left the
    gap to the pane, so alone on the surface the blank row fell between the
    title and the pane's own heading. On the screen that reads as the title
    one row higher than everywhere else and the heading as a detached block.
    """
    rows = screen_rows(drawn)
    title_row = screen_row_of(rows, title)
    if title_row < 3:
        raise AssertionError(
            f"{title!r} is at row {title_row}, not under the strip and a gap: "
            f"{rows!r}"
        )
    if rows.get(title_row - 1, b"").strip():
        raise AssertionError(
            f"the row above {title!r} is not the gap: {rows.get(title_row - 1)!r}"
        )
    heading_row = screen_row_of(rows, heading)
    if heading_row != title_row + 1:
        raise AssertionError(
            f"{heading!r} is at row {heading_row}, not under {title!r} at "
            f"{title_row}: {rows!r}"
        )


def escape_to_keeper_detail(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    *,
    name: bytes,
    presses: int = 4,
) -> None:
    """Leave a keeper's chat for its detail, however many Escapes that takes.

    Escape does not mean one thing here, and the footer says which at each
    moment: while a turn is running it reads "Esc:interrupt turn", and only
    once none is does it read "Esc:detail". A scenario that just sent a
    message is leaving with a turn running, so its first press interrupts
    rather than leaves. Where the fixture answers the stream with 503 the
    interrupt gets no answer either -- the pane says so -- and how many
    presses it then takes is not a number a scenario can write down.

    Waiting for the footer to change instead of counting does not work: the
    composer's own footer already names Esc:detail, so that needle is
    satisfied by bytes drawn before the first press.

    The bound is here so a surface that never leaves fails as a test rather
    than hangs. Arriving is the assertion; the number of presses is not.
    """
    title = b"Keepers \xe2\x96\xb8 \x1b[1m" + name
    for _ in range(presses):
        start = len(output)
        os.write(master_fd, b"\x1b")
        try:
            wait_for_output(process, master_fd, output, title, start=start, timeout=2.0)
            return
        except AssertionError:
            continue
    raise AssertionError(
        f"{presses} Escapes did not leave the chat for {name!r}'s detail: "
        f"{bytes(output)[-600:]!r}"
    )


def autonomous_turn_history_fixture() -> HttpResponse:
    """One transcript row the way an autonomous turn persists it.

    Blank ``content`` and a ``trace`` block behind it: on one live keeper 32
    of 183 assistant rows looked like this, and every one drew as a timestamp
    over an empty line.
    """

    return (
        200,
        [
            {
                "id": "autonomous:trace-1787333555531-00020#54",
                "role": "assistant",
                "content": "",
                "ts": 1787348490.3,
                "turn_ref": "trace-1787333555531-00020#54",
                "autonomous_turn": {"turn_id": "trace-1787333555531-00020#54"},
                # The server writes null, not "", when the turn said nothing.
                # (content is set above; the marker is what the decoder keys on.)
                "blocks": [
                    {
                        "t": "trace",
                        "trace": [
                            {"kind": "think", "text": "", "content_withheld": True},
                            {
                                "kind": "tool",
                                "name": "masc_task_history",
                                "status": "ok",
                                "dur": "32ms",
                            },
                            {"kind": "think", "text": "", "content_withheld": True},
                            {
                                "kind": "tool",
                                "name": "tool_execute",
                                "status": "err",
                                "dur": "1200ms",
                            },
                        ],
                    }
                ],
            },
            {
                "id": "autonomous:trace-1787333555531-00021#55",
                "role": "assistant",
                "content": "",
                "ts": 1787348491.3,
                "turn_ref": "trace-1787333555531-00021#55",
                "autonomous_turn": {"turn_id": "trace-1787333555531-00021#55"},
                "blocks": [],
            },
        ],
    )


def context_inspector_fixtures() -> HttpFixtures:
    prompt_texts = {
        "keeper_instructions": "Keeper instruction text",
        "dynamic_context": "exact dynamic context from the turn",
        "memory_os_recall": "remember the operator preference",
    }

    def prompt_record(block_id: str) -> dict[str, object]:
        text = prompt_texts[block_id]
        return {
            "block": block_id,
            "bytes": len(text.encode()),
            "digest": hashlib.sha256(text.encode()).hexdigest(),
        }

    def input_prompt_component(block_id: str) -> dict[str, object]:
        return {
            "component": f"prompt.{block_id}",
            "bytes": len(prompt_texts[block_id].encode()),
        }

    fixtures = keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
        200,
        {"keeper": "alpha", "entries": []},
    )
    fixtures["/api/v1/keepers/alpha/turn-records?limit=50"] = (
        200,
        {
            "entries": [
                {
                    "record": {
                        "execution_ids": [],
                        "keeper": "alpha",
                        "agent_name": "keeper-alpha",
                        "turn_kind": "direct",
                        "trace_id": "trace-context",
                        "absolute_turn": 42,
                        "turn_ref": "trace-context#42",
                        "blocks": [
                            prompt_record("keeper_instructions"),
                            prompt_record("dynamic_context"),
                            prompt_record("memory_os_recall"),
                        ],
                        "input_components": [
                            input_prompt_component("keeper_instructions"),
                            input_prompt_component("dynamic_context"),
                            input_prompt_component("memory_os_recall"),
                            {"component": "tool_schemas", "bytes": 2048},
                            {"component": "message_user", "bytes": 512},
                            {"component": "message_assistant_text", "bytes": 768},
                            {"component": "message_tool_result", "bytes": 256},
                        ],
                        "runtime_profile": "anthropic.claude-opus-5",
                        "request_runtime_profile": "anthropic.claude-opus-5",
                        "request_body_bytes": 4608,
                        "transmitted_atoms": 7,
                        "total_atoms": 9,
                        "model_input_measurement": "wire_shape",
                        "model_input_front": {"kind": "at_atom", "digest": hashlib.sha256(b"front atom").hexdigest()},
                        # These two keys are a pair. Turn_record.of_json
                        # defaults a missing usage_scope to
                        # Usage_scope_unavailable, and /context then omits
                        # the token count instead of failing loudly (task-1635:
                        # deleting only usage_scope reproduced "Context
                        # composition omitted 50.0k / 200.0k tokens").
                        "response_observed_model_input": None,
                        "usage_scope": "per_request",
                        "raw_trace_run_ref": None,
                        "selected_model": "claude-opus-5",
                        "context_window": 200000,
                        "input_tokens": 50000,
                        "output_tokens": 1200,
                        "cache_read_input_tokens": 32000,
                        "ts": 1787600000.0,
                    },
                    "diff_vs_prev": None,
                }
            ]
        },
    )
    provider_body = b'{"model":"claude-opus-5","messages":[]}'

    def exact_message(index: int, role: str, text: str) -> dict[str, object]:
        content = {
            "role": role,
            "content_blocks": [{"type": "text", "text": text}],
        }
        encoded = json.dumps(content, separators=(",", ":")).encode()
        return {
            "index": index,
            "role": role,
            "bytes": len(encoded),
            "sha256": hashlib.sha256(encoded).hexdigest(),
            "content": content,
        }

    tool_schema = {
        "name": "masc_execute",
        "description": "Execute one command",
        "input_schema": {"type": "object"},
    }
    encoded_tool_schema = json.dumps(tool_schema, separators=(",", ":")).encode()
    fixtures["/api/v1/keepers/alpha/provider-input?turn_ref=trace-context%2342"] = (
        200,
        {
            "dashboard_surface": "/api/v1/keepers/:name/provider-input",
            "schema": "masc.resolved-provider-input.v1",
            "keeper": "alpha",
            "trace_id": "trace-context",
            "absolute_turn": 42,
            "turn_ref": "trace-context#42",
            "runtime_profile": "anthropic.claude-opus-5",
            "captured_at": 1787600000.0,
            "wire": {
                # A nullary variant is a one-element list in
                # ppx_deriving_yojson's encoding, not a bare string.
                "phase": ["Pre_dispatch_serialization"],
                "capture_id": "capture-context",
                "provider": "anthropic",
                "model": "claude-opus-5",
                "http_codec": "anthropic_messages",
                "stream": True,
                "body_bytes": len(provider_body),
                "body_sha256": hashlib.sha256(provider_body).hexdigest(),
            },
            "system_prompt": {
                "bytes": len(prompt_texts["keeper_instructions"].encode()),
                "sha256": hashlib.sha256(
                    prompt_texts["keeper_instructions"].encode()
                ).hexdigest(),
                "text": prompt_texts["keeper_instructions"],
            },
            "messages": [
                exact_message(0, "system", prompt_texts["dynamic_context"]),
                exact_message(1, "system", prompt_texts["memory_os_recall"]),
                exact_message(2, "user", "operator request"),
                exact_message(3, "assistant", "assistant response"),
                exact_message(4, "tool", "tool result body"),
            ],
            "tool_schemas": [
                {
                    "index": 0,
                    "name": "masc_execute",
                    "bytes": len(encoded_tool_schema),
                    "sha256": hashlib.sha256(encoded_tool_schema).hexdigest(),
                    "content": tool_schema,
                }
            ],
        },
    )
    return fixtures
RUNTIME_RESOLVED_PATH = "/api/v1/runtime/resolved"


@dataclass(frozen=True)
class ScenarioFamily:
    """Scenarios run together under one name: a dune lane, or the default walk."""

    name: str
    label: str
    runs: tuple[Callable[[str], None], ...]


def run_family(family: ScenarioFamily, executable: str, selection: ScenarioSelection) -> None:
    global scenario_selection
    scenario_selection = selection
    try:
        for run in family.runs:
            run(executable)
    finally:
        scenario_selection = RunEveryScenario()


def collect_scenario_names(family: ScenarioFamily, executable: str) -> list[str]:
    """The descriptions [family] runs, in order, without opening a terminal.

    The binary is still needed: two families hash it for their evidence
    before their first scenario. A family's own prints (msx-retained-tick
    writes its pixel log after its scenario) go to stderr, so stdout holds
    only the names.
    """
    selection = CollectScenarioNames([])
    with redirect_stdout(sys.stderr):
        run_family(family, executable, selection)
    return selection.names


def main(
    argv: list[str], families: tuple[ScenarioFamily, ...], default: ScenarioFamily
) -> None:
    """The command line over [families]; with no family named, [default] runs."""
    by_name = {family.name: family for family in families}
    parser = argparse.ArgumentParser(
        allow_abbrev=False,
        usage="%(prog)s <masc_tui.exe> [family] [--list | --scenario DESCRIPTION ...]",
        description=(
            "Drive masc_tui through a real PTY. With no family the keyboard walk "
            "runs; each dune rule for this file names one family."
        ),
    )
    parser.add_argument("operands", nargs="*", help=argparse.SUPPRESS)
    parser.add_argument(
        "--scenario",
        action="append",
        default=[],
        metavar="DESCRIPTION",
        help=(
            "run only the scenario with this description inside the family; "
            "repeat for more than one"
        ),
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help=(
            "print the scenario descriptions instead of running them: "
            "every family's, or only the named family's"
        ),
    )
    args = parser.parse_intermixed_args(argv)
    match args.operands:
        case [executable]:
            chosen = None
        case [executable, family_name] if family_name in by_name:
            chosen = by_name[family_name]
        case [_, family_name]:
            parser.error(f"unknown family {family_name!r}; --list prints the names")
        case _:
            parser.error("expected <masc_tui.exe> and at most one family")
    executable = tui_executable(executable)
    if args.list:
        if args.scenario:
            parser.error("--list and --scenario do not go together")
        for family in families if chosen is None else (chosen,):
            print(family.name)
            for name in collect_scenario_names(family, executable):
                print(f"  {name}")
        return
    family = default if chosen is None else chosen
    if not args.scenario:
        run_family(family, executable, RunEveryScenario())
        print(f"tui {family.label}: PASS")
        return
    known = set(collect_scenario_names(family, executable))
    unknown = [name for name in args.scenario if name not in known]
    if unknown:
        # A description copied from a traceback may belong to another family;
        # say which, so the next command is the right one.
        by_family = {
            other.name: set(collect_scenario_names(other, executable))
            for other in families
        }
        parser.error(
            f"no scenario in family {family.name!r} is described as: "
            + "; ".join(
                f"{name!r} (it is in: {', '.join(n for n, names in by_family.items() if name in names)})"
                if any(name in names for names in by_family.values())
                else repr(name)
                for name in unknown
            )
        )
    selection = RunNamedScenarios(frozenset(args.scenario), [])
    run_family(family, executable, selection)
    # Collection saw every name, but a description a family computes from
    # what its earlier scenarios did could still differ on the real run.
    not_run = [name for name in args.scenario if name not in selection.ran]
    if not_run:
        raise SystemExit(
            f"tui {family.label}: these selected scenarios did not run: {not_run!r}"
        )
    print(f"tui {family.label}: PASS ({len(selection.ran)} selected scenario runs)")


def press_and_settle(
    process: "subprocess.Popen[bytes]",
    master_fd: int,
    output: bytearray,
    data: bytes,
    cap: float = 3.0,
) -> bytes:
    """Send [data] and answer everything drawn once the drawing stops.

    Not send_and_wait: each keystroke in a typed word repaints the whole
    screen, so a word arrives across as many frames as it has letters and a
    single needle wait judges a frame that is still half a word behind. The
    press is judged after its output stops, the way tab_until judges a
    surface switch.
    """
    read_available(master_fd, output)
    start = len(output)
    write_all(master_fd, output, data)
    wait_for_output(process, master_fd, output, FRAME_END, start=start, timeout=5.0)
    drain_until_quiet(process, master_fd, output, cap=cap)
    return CSI_RE.sub(b"", bytes(output[start:]))
