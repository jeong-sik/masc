from __future__ import annotations

from collections.abc import Callable, Iterator
from contextlib import contextmanager
import base64
import errno
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import select
import signal
import struct
import zlib
import subprocess
import sys
import tempfile
import termios
import threading
import time
from typing import Any, cast

Interaction = Callable[[subprocess.Popen[bytes], int, int, bytearray, str], None]
HttpResponse = tuple[int, object]
Needle = bytes | re.Pattern[bytes]


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


class HeadersHttpResponse:
    """A streaming protocol fixture whose response depends on request headers."""

    def __init__(self, resolve: Callable[[dict[str, str]], RawHttpResponse | StreamingHttpResponse]) -> None:
        self.resolve = resolve


class RequestHttpResponse:
    """A fixture whose JSON-RPC answer must echo fields from the POST body."""

    def __init__(
        self,
        resolve: Callable[[bytes], HttpResponse | RawHttpResponse | StreamingHttpResponse],
    ) -> None:
        self.resolve = resolve


HttpFixture = (
    HttpResponse
    | RawHttpResponse
    | StreamingHttpResponse
    | RequestHttpResponse
    | HeadersHttpResponse
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
        self.release = threading.Event()
        self.completed = threading.Event()
        self.calls = 0
        self.lock = threading.Lock()

    def __call__(self) -> HttpResponse:
        with self.lock:
            call_index = self.calls
            self.calls += 1
        if call_index > 0 and self.subsequent_response is not None:
            return self.subsequent_response
        self.requested.set()
        try:
            if not self.release.wait(timeout=self.hold_seconds):
                return 504, {"error": "fixture response gate timed out"}
            return self.response
        finally:
            self.completed.set()


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
            elif self.path == "/health":
                fixture = (200, {})
            elif self.path == "/health?full=1":
                fixture = fleet_safety_fixture()
            elif path_only in fixtures:
                fixture = fixtures[path_only]
            else:
                fixture = (503, {"error": "fixture endpoint unavailable"})
            if isinstance(fixture, RequestHttpResponse):
                resolved = fixture.resolve(request_body or b"")
            elif isinstance(fixture, HeadersHttpResponse):
                resolved = fixture.resolve({key.lower(): value for key, value in self.headers.items()})
            else:
                resolved = fixture() if callable(fixture) else fixture
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
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            for name, value in extra_headers:
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            self.respond()

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            self.respond(body)
            if requests is not None:
                requests.append((self.path, body))

        def log_message(self, format: str, *args: object) -> None:
            del format, args

    with ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler) as server:
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
def find_needle(
    haystack: bytes | bytearray,
    needle: bytes | re.Pattern[bytes],
    start: int = 0,
) -> int:
    if isinstance(needle, bytes):
        return haystack.find(needle, start)
    found = needle.search(bytes(haystack), start)
    return found.start() if found else -1



def end_of_needle(
    haystack: bytes | bytearray,
    needle: bytes | re.Pattern[bytes],
    start: int = 0,
) -> int:
    if isinstance(needle, bytes):
        return haystack.find(needle, start) + len(needle)
    found = needle.search(bytes(haystack), start)
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


def approvals_header(count: int) -> re.Pattern[bytes]:
    """The Approvals title and the number of asks on it.

    What follows the number inside the parens is where those asks came from --
    held calls, Gate rows, operator entries -- and the renderer writes that
    breakdown whenever the count is above zero. Spelling the header as
    "(3)" asserted the parenthesis closes right after the number, which is a
    fact about that breakdown rather than about how many asks are waiting.
    """
    return re.compile(
        re.escape(b"MASC Approvals")
        + rb"(?:\x1b\[[0-9;]*m)* \("
        + str(count).encode()
        + rb"[ )]"
    )


def selected_row(post_id: bytes) -> re.Pattern[bytes]:
    """The highlighted list row for `post_id`, whatever sits in the gutter.

    Selection is drawn two ways while the band conversion is in flight: the
    legacy reverse-video caret, or a full-row reverse band that opens the
    row and carries no inner escapes.
    """
    return re.compile(
        rb"\x1b\[7m(?:>\x1b\[0m)?(?:\x1b\[[0-9;]*m|[ \xc2\xb7@?])*"
        + re.escape(post_id)
    )


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


# A needle the screen already drew before the keypress is a different failure
# from one it never drew, and the two read identically in a timeout message.
# The TUI refreshes an open surface on its own cadence, so a scenario that
# mutates a fixture and then presses a key races that refresh: the earlier
# draw lands before send_and_wait takes its offset, and the wait that follows
# looks for bytes that are already behind it.
def _needle_before_start(
    output: bytearray, needle: Needle, start: int
) -> str:
    if start <= 0:
        return ""
    earlier = find_needle(output, needle, 0)
    if earlier < 0 or earlier >= start:
        return ""
    return (
        f" (drawn at offset {earlier}, before this wait started at {start}:"
        " a refresh got there first)"
    )


def wait_for_output(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    needle: Needle,
    *,
    start: int,
    timeout: float,
) -> None:
    deadline = time.monotonic() + timeout
    while find_needle(output, needle, start) < 0:
        read_available(master_fd, output)
        if process.poll() is not None:
            raise AssertionError(f"TUI exited before {needle!r}: {bytes(output)!r}")
        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            raise AssertionError(
                f"timed out waiting for {needle!r}"
                f"{_needle_before_start(output, needle, start)}: {bytes(output)!r}"
            )
        select.select([master_fd], [], [], min(0.1, remaining))


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


def drain_until_quiet(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    quiet: float = 0.25,
    cap: float = 3.0,
) -> None:
    """Read until the TUI has written nothing for [quiet] seconds.

    A keypress's consequences are not one frame: the switch redraw can be
    preceded by frames already in flight. The only moment a press can be
    judged is after its output has stopped arriving.
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
            return


def tab_until(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    needle: Needle,
) -> bytes:
    """Press Tab until the screen shows [needle], or give up after a lap.

    Name the surface the walk is going to, not one on the way. The ring is
    not fixed: Masc_tui_types.is_surface_active leaves Approvals out of it
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
    if "~" in rendered_row and "~" not in input_text:
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
        "trace_history": [],
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
        "last_handoff_ts",
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
            },
        ),
        "/api/v1/board?sort_by=hot": (200, {"posts": [post]}),
        "/api/v1/board/post-1?format=flat": (
            200,
            {"post": post, "comments": comments},
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
    }


def fleet_safety_fixture() -> HttpResponse:
    """A fleet reading the TUI can decode.

    Without it the poll fails and the TUI records a "fleet safety data
    unreliable" event, which is correct behaviour but adds a row to scenarios
    that are counting the event list. Only "status" is required; the rest of
    the section defaults.
    """
    return (200, {"keeper_fleet_safety": {"status": "ok"}})


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
                    "dropped_count": 0,
                },
                "task_backlog": {
                    "todo": 0,
                    "claimed": 0,
                    "in_progress": 0,
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
    }


def planning_snapshot(goals: list[dict[str, object]]) -> HttpResponse:
    return (
        200,
        {
            "goals": goals,
            "goal_history": {"unlisted": []},
            "rollup": {
                "active_count": len(goals),
                "verifying_count": 0,
                "awaiting_confirmation_count": 0,
                "done_count": 0,
                "dropped_count": 0,
            },
            "task_backlog": {
                "todo": 0,
                "claimed": 0,
                "in_progress": 0,
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
        {"post": bravo_detail, "comments": []},
    )
    fixtures["/api/v1/board/post-c?format=flat"] = (
        200,
        {"post": charlie_detail, "comments": []},
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
        {"post": posts[0], "comments": []},
    )
    fixtures["/api/v1/board/post-markdown?format=flat"] = (
        200,
        {"post": posts[1], "comments": []},
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
        {
            "post": board_selection_post(
                "a", "Alpha authoritative", "a-authoritative-detail"
            ),
            "comments": [board_detail_comment("comment-a", "a-only-comment")],
        },
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
        {
            "post": board_selection_post("a", "Alpha", "a-detail-body"),
            "comments": [board_detail_comment("comment-a", "a-only-comment")],
        },
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
        {
            "post": board_selection_post("a", "Alpha", "a-recovered-detail"),
            "comments": [],
        },
    )
    fixtures["/api/v1/board/post-b?format=flat"] = (
        200,
        {
            "post": board_selection_post("b", "Bravo", "b-initial-detail"),
            "comments": [board_detail_comment("comment-b", "b-initial-comment")],
        },
    )
    late_b = GatedHttpResponse(
        (
            200,
            {
                "post": board_selection_post("b", "Bravo", "b-late-detail"),
                "comments": [board_detail_comment("comment-b-late", "b-late-comment")],
            },
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


def run_terminal_scenario(
    executable: str,
    *,
    description: str,
    interact: Interaction,
    confirm_exit: bytes = b"q",
    refresh: float = 60.0,
    http_fixtures: HttpFixtures | None = None,
    http_requests: HttpRequests | None = None,
    prepare_workspace: WorkspaceSetup | None = None,
    preload_input: bytes | None = None,
    extra_args: tuple[str, ...] = (),
    extra_env: dict[str, str] | None = None,
    conflicting_env_base_path: bool = False,
) -> None:
    master_fd, slave_fd = os.openpty()
    output = bytearray()
    process: subprocess.Popen[bytes] | None = None
    try:
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.set_blocking(master_fd, False)
        with tempfile.TemporaryDirectory(prefix="masc-tui-keyboard-") as base_path:
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
                environment.pop("LINES", None)
                environment.pop("COLUMNS", None)
                # Same reason as LINES/COLUMNS: the terminal the assertions
                # describe is the harness's, not the shell's. A developer with
                # NO_COLOR set would run this suite against a TUI drawing no
                # colour at all, and pass or fail on a variable nobody chose
                # here. Both directions leave, so neither shell decides.
                environment.pop("NO_COLOR", None)
                environment.pop("MASC_TUI_FORCE_COLOR", None)
                # A scenario's own variables (an $EDITOR stub, say) apply
                # before the fixed set below, so the harness keeps the last
                # word on the terminal it describes.
                if extra_env is not None:
                    environment.update(extra_env)
                environment.update(
                    {
                        "MASC_BASE_PATH": env_base_path,
                        "MASC_BASE_PATH_INPUT": env_base_path,
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
                        "trap '' INT TERM; kill -STOP $$; \"$@\"; tui_status=$?; "
                        'kill -STOP $$; exit "$tui_status"',
                        "masc-tui-test-launcher",
                        executable,
                        "--base-path",
                        base_path,
                        "--workspace",
                        WORKSPACE_PAYLOAD,
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
                wait_for_output(
                    process,
                    master_fd,
                    output,
                    b"MASC Overview",
                    start=0,
                    timeout=30.0,
                )
                wait_for_output(
                    process,
                    master_fd,
                    output,
                    WORKSPACE_RENDERED,
                    start=0,
                    timeout=3.0,
                )
                workspace_offset = output.find(WORKSPACE_RENDERED)
                wait_for_output(
                    process,
                    master_fd,
                    output,
                    FRAME_END,
                    start=workspace_offset + len(WORKSPACE_RENDERED),
                    timeout=3.0,
                )
                read_available(master_fd, output)
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
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
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
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
    send_and_wait(
        process,
        master_fd,
        output,
        b"q",
        b"q: press again to quit",
    )
    # A different key cancels the arm and still performs its surface action.
    tab_until(process, master_fd, output, b"MASC Keepers")
    tab_until(process, master_fd, output, b"MASC Overview")
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
# column. Two thresholds bound it, and 140 sat between them: the column needs
# 118 inner cells (Render_schedule.keeper_runtime_minimum_inner_width), and
# from Masc_tui_acting_pane.threshold_cols (132) the acting pane takes its 56
# columns off the top, which leaves too few again until 180. Measured on the
# built TUI: 118 drops the column, 122 through 131 draw it, 132 through 176 do
# not, 180 does.
KEEPER_RUNTIME_COLUMN_COLUMNS = 126


def keeper_runtime_phase_and_identity_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=KEEPER_RUNTIME_COLUMN_COLUMNS,
        needle=b"MASC Overview",
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"2",
        b"anthropic.claude-opus-5",
    )
    wait_for_output(
        process,
        master_fd,
        output,
        b"LIFECYCLE / RUNTIME",
        start=0,
        timeout=3.0,
    )
    wait_for_output(
        process,
        master_fd,
        output,
        b"paused anthropic.claude-sonnet-4",
        start=0,
        timeout=3.0,
    )
    # Delete is offered for every keeper state, and for one whose configuration
    # failed to read it is the only offer -- `primary` withholds it from the
    # toggle on purpose. The footer named no key for it, so the single action
    # that worked was the one the screen never mentioned. The needle carries the
    # reset that follows the key, which is what separates an offered hint from
    # the dim `\x1b[2mx delete` an unavailable one would draw.
    wait_for_output(
        process,
        master_fd,
        output,
        b"x\x1b[0m delete",
        start=0,
        timeout=3.0,
    )
    os.write(master_fd, b"q")


def keeper_long_runtime_identity_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=KEEPER_RUNTIME_COLUMN_COLUMNS,
        needle=b"MASC Overview",
    )
    # Both keepers run the same provider subscription, so their ids differ
    # only after a 25-character shared prefix. What has to hold is that the
    # elision cuts the shared middle and leaves the tail that tells the two
    # apart. Where exactly it cuts is a function of the column width, so
    # pinning the cut point spells a needle that a wider column retires --
    # the earlier b"antigrav\xe2\x80\xa6.gemini-3-7-flash" was written against a
    # narrower column and stopped matching without the behaviour changing.
    send_and_wait(
        process,
        master_fd,
        output,
        b"2",
        b".gemini-3-7-flash",
    )
    wait_for_output(
        process,
        master_fd,
        output,
        b".claude-sonnet-4",
        start=0,
        timeout=3.0,
    )
    frame = frame_containing(bytes(output), b".claude-sonnet-4")
    for full_id in (
        b"antigravity_subscription.gemini-3-7-flash",
        b"antigravity_subscription.claude-sonnet-4",
    ):
        if full_id in frame:
            raise AssertionError(
                f"{full_id!r} was drawn whole, so this scenario is no longer "
                f"exercising the elision it guards: {frame!r}"
            )
    os.write(master_fd, b"q")


def wheel_scrolls_and_clicks_do_not(
    process: subprocess.Popen[bytes],
    master_fd: int,
    slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    # The enable sequence must be out before any wheel can arrive: without it
    # the terminal keeps the wheel for its own scrollback and the TUI never
    # sees the report at all.
    wait_for_output(
        process, master_fd, output, b"\x1b[?1006;1000h", start=0, timeout=3.0
    )
    wait_for_output(process, master_fd, output, b"Awaiting you", start=0, timeout=3.0)
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
    # An SGR wheel report moves the cursor exactly as the arrow key does.
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[<65;5;5M",
        keeper_row_selected(b"beta"),
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[<64;5;5M",
        keeper_row_selected(b"alpha"),
    )
    # Click press and release must not leak into a key: after both, the next
    # wheel-down still starts from alpha and lands on beta.
    read_available(master_fd, output)
    os.write(master_fd, b"\x1b[<0;5;5M")
    os.write(master_fd, b"\x1b[<0;5;5m")
    time.sleep(0.3)
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[<65;5;5M",
        keeper_row_selected(b"beta"),
    )
    send_and_wait(process, master_fd, output, b"iq2Q", b"to beta q2Q")

    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"\x1b[200~hidden compact paste\x1b[201~")
    os.write(master_fd, b"x\r")
    wait_for_terminal_input_consumed(slave_fd)
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=99,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    restored_message_patch = resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"to beta q2Q",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25h",
    )
    if (
        b"hidden compact paste" in restored_message_patch
        or b"q2Qx" in restored_message_patch
        or b"(sending " in restored_message_patch
    ):
        raise AssertionError(
            "compact viewport accepted hidden message input: "
            f"{restored_message_patch!r}"
        )

    # Esc leaves insert mode: the draft stays on the composer row and the
    # keys belong to the roster again. Enter then opens the selected keeper
    # -- beta, where the wheel left the cursor.
    os.write(master_fd, b"\x1b")
    wait_for_terminal_input_consumed(slave_fd)
    drain_until_quiet(process, master_fd, output)
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")

    # Wait until the process is back inside its input read, then resize and
    # send one surface shortcut without waiting for the compact frame. The
    # SIGWINCH lands after the loop's first resize poll; input must consume
    # that pending resize before it can act on the old normal frame.
    drain_until_quiet(process, master_fd, output)
    os.killpg(process.pid, signal.SIGSTOP)
    wait_for_stop(
        process,
        master_fd,
        output,
        timeout=2.0,
        description="compact resize/input race control point",
    )
    read_available(master_fd, output)
    compact_race_start = len(output)
    fcntl.ioctl(
        master_fd,
        termios.TIOCSWINSZ,
        struct.pack("HHHH", 14, 100, 0, 0),
    )
    os.write(master_fd, b"2")
    os.killpg(process.pid, signal.SIGCONT)
    wait_for_terminal_input_consumed(slave_fd)
    wait_for_output(
        process,
        master_fd,
        output,
        b"terminal too small",
        start=compact_race_start,
        timeout=3.0,
    )
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )

    resize_and_wait(
        process,
        master_fd,
        output,
        # The agenda strip takes one of these fourteen rows. The renderer
        # therefore shows a thirteen-row compact frame; the input gate must
        # measure the same body rather than route this hidden `2`.
        rows=14,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"2")
    wait_for_terminal_input_consumed(slave_fd)
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )

    send_and_wait(process, master_fd, output, b"l", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 logs")
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 logs",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[D",
        b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
    )
    send_and_wait(process, master_fd, output, b"\x1b[D", b"MASC Keepers")
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[A",
        keeper_row_selected(b"alpha"),
    )
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"\x1b[B")
    wait_for_terminal_input_consumed(slave_fd)
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=keeper_row_selected(b"alpha"),
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    # An armed search prefixes the footer with its query at the one seam
    # every surface shares (footer_line). What follows it is the surface's
    # own hint text -- Keepers spells its first hint "j/k move", and at 100
    # columns the strip is elided anyway. The prefix is what says the
    # search is armed.
    send_and_wait(process, master_fd, output, b"/", b"/  ")
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    # The fallback says q quits. A hidden search prompt must not reclaim it.
    os.write(master_fd, b"q")
    wait_for_terminal_input_consumed(slave_fd)


def compact_input_gate_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/keepers/tool-approvals"] = (
        200,
        {
            "pending": [
                {
                    "keeper": "alpha",
                    "tool_call_id": "tool-awaiting-compact-gate",
                    "tool": "Execute",
                    "args": "{}",
                    "question": "Run the compact-gate probe?",
                    "because": None,
                    "asked_at": 1787766400.0,
                    "timeout_sec": 300.0,
                }
            ]
        },
    )
    return fixtures


def select_keeper_row(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    name: bytes,
) -> None:
    """Move the keeper-list cursor onto ``name``, wherever the row sits.

    The roster comes from the fixture plus whatever the live read added, so a
    scenario that presses Enter on the list's first row is asserting an order
    nothing promises. Walking down until the row reports itself selected makes
    the scenario say which keeper it means.
    """
    needle = keeper_row_selected(name)
    if find_needle(output, needle, 0) >= 0:
        return
    for _ in range(KEEPER_ROW_SCAN_BOUND):
        read_available(master_fd, output)
        start = len(output)
        os.write(master_fd, b"\x1b[B")
        wait_for_output(process, master_fd, output, FRAME_END, start=start, timeout=3.0)
        if find_needle(output, needle, start) >= 0:
            return
    raise AssertionError(
        f"keeper row {name!r} never became selected: {bytes(output[-2000:])!r}"
    )


def keeper_detail_overscroll_interaction(
    fixtures: HttpFixtures,
    refresh_gate: GatedHttpResponse,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            wait_for_output(
                process, master_fd, output, b"cluster-a", start=0, timeout=10.0
            )
            cluster_end = output.find(b"cluster-a") + len(b"cluster-a")
            wait_for_output(
                process,
                master_fd,
                output,
                FRAME_END,
                start=cluster_end,
                timeout=3.0,
            )
            send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
            # Confirm which row Enter will open rather than assuming the list
            # opens on its first entry. The roster order is a property of the
            # fixture and of whatever the live read returned, so pressing
            # Enter blind waits for a detail header that may never come.
            select_keeper_row(process, master_fd, output, b"alpha")
            send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"Keepers \xe2\x96\xb8 \x1b[1malpha",
            )
            detail = resize_and_wait(
                process,
                master_fd,
                output,
                rows=16,
                columns=100,
                needle=b"Keepers \xe2\x96\xb8 \x1b[1malpha",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            indicators = re.findall(rb"\[(\d+)/(\d+)\]", detail)
            if not indicators:
                raise AssertionError(
                    f"Keeper detail did not expose a scroll indicator: {detail!r}"
                )
            position_count = int(indicators[-1][1])
            if position_count < 3:
                raise AssertionError(
                    f"Keeper detail fixture has too few scroll positions: {detail!r}"
                )

            bottom = f"[{position_count}/{position_count}]".encode()
            send_and_wait(
                process,
                master_fd,
                output,
                b"j" * (position_count - 1),
                bottom,
            )

            fixtures["/api/v1/dashboard/briefing"] = refresh_gate
            read_available(master_fd, output)
            os.write(master_fd, b"jr")
            if not wait_for_fixture_event(
                process, master_fd, output, refresh_gate.requested, timeout=10.0
            ):
                raise AssertionError(
                    "Keeper detail overscroll refresh did not reach its fixture"
                )
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=16,
                columns=99,
                needle=bottom,
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            refresh_gate.release.set()

            previous = f"[{position_count - 1}/{position_count}]".encode()
            send_and_wait(process, master_fd, output, b"k", previous)
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            send_and_wait(
                process,
                master_fd,
                output,
                b"j",
                keeper_row_selected(b"beta"),
            )
            beta = send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
            )
            top = f"[1/{position_count}]".encode()
            if top not in beta:
                raise AssertionError(
                    f"new Keeper detail did not reset to the top: {beta!r}"
                )
            os.write(master_fd, b"q")
            completed = True
        finally:
            refresh_gate.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


def keeper_selection_identity_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    base_path: str,
) -> None:
    wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=10.0)
    cluster_end = output.find(b"cluster-a") + len(b"cluster-a")
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=cluster_end,
        timeout=3.0,
    )
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
    send_and_wait(
        process,
        master_fd,
        output,
        b"j",
        keeper_row_selected(b"beta"),
    )
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")

    keepers_path = Path(base_path) / ".masc" / "keepers"
    beta_metadata = keeper_metadata("beta")
    # A value the keeper list draws, so pressing r below is observable. This
    # used to ride on the keeper's generation counter, which the schema no
    # longer has; the current task id is drawn in the list's Current Task
    # column and serves the same purpose.
    beta_metadata["current_task_id"] = "task-29453"
    (keepers_path / "beta.json").write_text(json.dumps(beta_metadata), encoding="utf-8")
    (keepers_path / "aardvark.json").write_text(
        json.dumps(keeper_metadata("aardvark")), encoding="utf-8"
    )
    send_and_wait(process, master_fd, output, b"r", b"29453")
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
    escape_to_keeper_detail(process, master_fd, output, name=b"beta")

    (keepers_path / "beta.json").write_text("{", encoding="utf-8")
    read_available(master_fd, output)
    error_start = len(output)
    os.write(master_fd, b"r")
    wait_for_output(
        process,
        master_fd,
        output,
        CONSOLE_DIAGNOSTIC,
        start=error_start,
        timeout=3.0,
    )
    unreliable = resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=99,
        needle=b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    if b"Keepers \xe2\x96\xb8 \x1b[1malpha" in unreliable:
        raise AssertionError(
            f"unreliable Keeper snapshot retargeted beta detail: {unreliable!r}"
        )
    stale_gate = send_and_wait(
        process,
        master_fd,
        output,
        b"ml",
        b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 logs",
    )
    if b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat" in CSI_RE.sub(b"", stale_gate):
        raise AssertionError(
            f"unreliable Keeper snapshot opened message mode: {stale_gate!r}"
        )
    escape_to_keeper_detail(process, master_fd, output, name=b"beta")
    alpha_metadata = keeper_metadata("alpha")
    alpha_metadata["current_task_id"] = "task-29454"
    (keepers_path / "alpha.json").write_text(
        json.dumps(alpha_metadata), encoding="utf-8"
    )
    (keepers_path / "aardvark.json").unlink()
    (keepers_path / "beta.json").unlink()
    missing = send_and_wait(process, master_fd, output, b"r", b"29454")
    missing_plain = CSI_RE.sub(b"", missing)
    failures = []
    if find_needle(missing_plain, screen_header(b"MASC Keepers", b" (1)")) < 0:
        failures.append("missing beta detail did not return to MASC Keepers (1)")
    if b"Keepers \xe2\x96\xb8 alpha" in missing_plain:
        failures.append("missing beta detail silently retargeted to alpha")

    after_selection = send_and_wait(
        process,
        master_fd,
        output,
        b"\r",
        b"Keepers \xe2\x96\xb8 \x1b[1malpha",
    )
    after_selection_plain = CSI_RE.sub(b"", after_selection)
    if b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat" in after_selection_plain:
        failures.append("m opened Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat after beta disappeared")
    if failures:
        raise AssertionError("; ".join(failures))
    os.write(master_fd, b"q")


def cli_base_path_overrides_environment_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=10.0)
    frame = send_and_wait(
        process,
        master_fd,
        output,
        b"2",
        keeper_row_selected(b"alpha"),
    )
    if b"env-only" in frame:
        raise AssertionError(
            f"--base-path leaked Keeper metadata from MASC_BASE_PATH: {frame!r}"
        )
    os.write(master_fd, b"q")


def keeper_message_missing_target_interaction(requests: HttpRequests) -> Interaction:
    draft = b"beta-periodic-draft-29453"
    chat_path = "/api/v1/keepers/chat/stream"

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            keeper_row_selected(b"beta"),
        )
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
        send_and_wait(process, master_fd, output, draft, composer_showing(draft))

        read_available(master_fd, output)
        refresh_start = len(output)
        keeper_path = Path(base_path) / ".masc" / "keepers" / "beta.json"
        keeper_path.unlink()
        unavailable = b"Keeper beta is no longer registered"
        wait_for_output(
            process,
            master_fd,
            output,
            unavailable,
            start=refresh_start,
            timeout=3.0,
        )
        unavailable_end = output.find(unavailable, refresh_start) + len(unavailable)
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=unavailable_end,
            timeout=3.0,
        )

        refreshed = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        refreshed_plain = CSI_RE.sub(b"", refreshed)
        for expected in (
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            unavailable,
            b"Enter:disabled (Keeper unavailable)",
            b"> " + draft,
        ):
            if expected not in refreshed_plain:
                raise AssertionError(
                    f"periodic refresh lost Keeper message state {expected!r}: "
                    f"{refreshed!r}"
                )
        if b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat" in refreshed_plain:
            raise AssertionError(
                f"periodic refresh retargeted the draft to alpha: {refreshed!r}"
            )

        send_and_wait(
            process,
            master_fd,
            output,
            b"\rx",
            composer_showing(draft + b"x"),
        )
        if any(path == chat_path for path, _body in requests):
            raise AssertionError(
                "Enter sent a message after the target Keeper disappeared"
            )

        keepers = send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b",
            screen_header(b"MASC Keepers", b" (1)"),
        )
        keepers_frame = frame_containing(keepers, screen_header(b"MASC Keepers", b" (1)"))
        if b"Keepers \xe2\x96\xb8 alpha" in CSI_RE.sub(b"", keepers_frame):
            raise AssertionError(
                f"Esc opened alpha detail after beta disappeared: {keepers!r}"
            )
        os.write(master_fd, b"q")

    return interact


def keeper_message_unreliable_roster_interaction(
    requests: HttpRequests,
) -> Interaction:
    draft = b"beta-unreliable-draft-29453"
    chat_path = "/api/v1/keepers/chat/stream"

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            keeper_row_selected(b"beta"),
        )
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
        send_and_wait(process, master_fd, output, draft, composer_showing(draft))

        read_available(master_fd, output)
        refresh_start = len(output)
        alpha_path = Path(base_path) / ".masc" / "keepers" / "alpha.json"
        alpha_path.write_text("{", encoding="utf-8")
        wait_for_output(
            process,
            master_fd,
            output,
            CONSOLE_DIAGNOSTIC,
            start=refresh_start,
            timeout=3.0,
        )
        unreliable = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        unreliable_plain = CSI_RE.sub(b"", unreliable)
        for expected in (
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            b"Keeper roster is unavailable",
            b"Enter:disabled (roster unavailable)",
            b"> " + draft,
        ):
            if expected not in unreliable_plain:
                raise AssertionError(
                    f"unreliable roster did not block Keeper message {expected!r}: "
                    f"{unreliable!r}"
                )

        send_and_wait(
            process,
            master_fd,
            output,
            b"\rx",
            composer_showing(draft + b"x"),
        )
        if any(path == chat_path for path, _body in requests):
            raise AssertionError("unreliable Keeper roster allowed a message POST")
        # One Escape, and it lands on the Keepers list rather than on a
        # keeper's detail: a detail is drawn from the roster, and the roster
        # read is the thing this walk broke. Walking to alpha's detail first
        # spent all four presses looking for a title the pane was never going
        # to draw and left the TUI out on Overview.
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def interrupt_with_ctrl_c(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x03",
        b"Ctrl-C: press again to quit",
    )


def terminate_with_sigterm(
    process: subprocess.Popen[bytes],
    _master_fd: int,
    _slave_fd: int,
    _output: bytearray,
    _base_path: str,
) -> None:
    # What `kill` and a service manager send. The handler only records the
    # signal; the loop has to read the record on its next pass and leave the
    # way q does, so the terminal restore and Goodbye the harness checks after
    # this come from that one exit path. A loop that never read it would sit
    # here until the harness's post-exit wait gives up. The launcher shell in
    # the same group ignores TERM (see run_terminal_scenario).
    os.killpg(process.pid, signal.SIGTERM)


def quit_from_compact_message(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"q")


def block_stderr_redirect(base_path: str) -> None:
    """Put a file where masc_tui wants its log directory.

    [redirect_stderr_off_terminal] opens <base>/.masc/logs/masc-tui-<pid>.log
    and gives up on any Unix_error or Sys_error, leaving stderr on the
    terminal. A regular file at .masc/logs makes both the mkdir and the open
    fail, which is the state a read-only or full disk produces.
    """
    masc = Path(base_path) / ".masc"
    masc.mkdir(parents=True, exist_ok=True)
    (masc / "logs").write_text("", encoding="utf-8")


def repair_after_console_diagnostic(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    base_path: str,
) -> None:
    read_available(master_fd, output)
    start = len(output)
    keeper_path = Path(base_path) / ".masc" / "keepers" / "alpha.json"
    keeper_path.write_text("{", encoding="utf-8")
    # This scenario is about the surface repairing itself after a console
    # line lands in the frame, which only happens when masc_tui cannot move
    # stderr off the terminal. [block_stderr_redirect] makes that real by
    # putting a file where the log directory has to go, so the open fails the
    # way a read-only or full disk would.
    #
    # Before masc#31881 the redirect failed on every temporary root -- the log
    # was opened with O_CREAT and nothing made the directory -- so the leak
    # happened by accident and this scenario passed without arranging it.
    wait_for_output(
        process,
        master_fd,
        output,
        CONSOLE_DIAGNOSTIC,
        start=start,
        timeout=3.0,
    )
    diagnostic_end = output.find(CONSOLE_DIAGNOSTIC, start) + len(CONSOLE_DIAGNOSTIC)
    keeper_path.write_text(json.dumps(keeper_metadata("alpha")), encoding="utf-8")
    wait_for_output(
        process,
        master_fd,
        output,
        FULL_REDRAW,
        start=diagnostic_end,
        timeout=3.0,
    )
    redraw_start = output.find(FULL_REDRAW, diagnostic_end)
    wait_for_output(
        process,
        master_fd,
        output,
        b"MASC Overview",
        start=redraw_start,
        timeout=3.0,
    )
    overview_start = output.find(b"MASC Overview", redraw_start)
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=overview_start + len(b"MASC Overview"),
        timeout=3.0,
    )
    os.write(master_fd, b"q")


def assert_row_budgeted_surfaces(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    wait_for_output(
        process,
        master_fd,
        output,
        b"attention-6",
        start=0,
        timeout=10.0,
    )
    wait_for_output(
        process,
        master_fd,
        output,
        b"task-5",
        start=0,
        timeout=3.0,
    )

    overview = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=100,
        needle=b"MASC Overview",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for expected in (b"attention-1", b"attention-2", b"task-1", b"q:quit"):
        if expected not in overview:
            raise AssertionError(f"14-row Overview omitted {expected!r}: {overview!r}")
    if b"attention-3" in overview:
        raise AssertionError(f"14-row Overview exceeded its row budget: {overview!r}")

    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"MASC Overview",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    tab_until(process, master_fd, output, b"MASC Keepers")
    tab_until(process, master_fd, output, b"MASC Board")
    send_and_wait(process, master_fd, output, b"\r", b"comment-5")

    board = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=100,
        needle=b"MASC Board",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    # One comment row at this height. The surface spends the rest on its box,
    # on the key footer, and on the "post rows" line it writes because the
    # thread does not fit -- so the budget the thread is left with is the
    # smallest one this pane hands out.
    for expected in (BOARD_CELL_BODY.encode(), b"comment-1", b"j/k:scroll"):
        if expected not in board:
            raise AssertionError(f"14-row Board omitted {expected!r}: {board!r}")
    if b"**comment-1**" in board:
        raise AssertionError(f"Board comment leaked Markdown source markers: {board!r}")
    for hidden in (b"comment-2", b"comment-3", b"comment-4", b"comment-5"):
        if hidden in board:
            raise AssertionError(f"14-row Board exceeded its row budget: {board!r}")

    # With one comment row, each press moves the thread by one, and the whole
    # thread is still reachable.
    for comment in (b"comment-2", b"comment-3", b"comment-4", b"comment-5"):
        send_and_wait(process, master_fd, output, b"j", comment)
    os.write(master_fd, b"q")


EVENT_RANGE_RE = re.compile(rb"TUI Session Events (\d+)-(\d+)/(\d+)")


def manual_refresh_run(drawn: bytes, where: str) -> int:
    """How many manual refreshes the newest event row stands for.

    The panel folds a run of identical events into one row and writes the
    length as a ×N tail; a run of one carries no tail at all.
    """
    match = re.search(rb"Manual refresh (?:\xc3\x97(\d+))?", screen_text(drawn))
    if match is None:
        raise AssertionError(f"{where} drew no manual refresh row: {drawn!r}")
    return int(match.group(1)) if match.group(1) else 1


def event_total(frame: bytes, where: str) -> int:
    """How many events the pane says it holds, read from the screen.

    The count is not fixed by the fixture: it includes events the TUI raises
    itself, and a runner that surfaces one more load error than a laptop reads
    a different number. Every range below is built from this so the scenario
    asserts scroll positions -- which is its subject -- rather than a list
    length it does not control.
    """
    match = EVENT_RANGE_RE.search(frame)
    if match is None:
        raise AssertionError(f"{where} drew no event range: {frame!r}")
    return int(match.group(3))


def event_range(first: int, last: int, total: int) -> bytes:
    return f"TUI Session Events {first}-{last}/{total}".encode()


def newest_window(height: int, total: int) -> bytes:
    """The window resting against the newest event."""
    return event_range(1, min(height, total), total)


def oldest_window(height: int, total: int) -> bytes:
    """The window resting against the oldest event."""
    return event_range(max(1, total - height + 1), total, total)


# Rows the Overview's event panel may take, mirroring
# Render_schedule.overview_panel_row_cap.
OVERVIEW_PANEL_ROW_CAP = 6


def event_range_span(frame: bytes, where: str) -> int:
    """How many event rows the panel is drawing, read off its own range line."""
    match = EVENT_RANGE_RE.search(frame)
    if match is None:
        raise AssertionError(f"{where} drew no event range: {frame!r}")
    first, last, _total = (int(g) for g in match.groups())
    return last - first + 1


def clamped_window(visible: int, scroll: int, total: int) -> bytes:
    """The range the panel draws for [scroll], mirroring
    Render_schedule.project_overview_event_window.

    The offset is clamped to total - visible, so a scroll made in a short
    viewport survives into a tall one only as far as the taller panel allows.
    Where the list is no longer than the panel that clamp is 0 and every
    window is the newest one -- which is why pinning "1-2" here held while
    the TUI raised exactly six events and stopped when it raised more.
    """
    offset = max(0, min(scroll, total - visible))
    return event_range(offset + 1, offset + min(visible, total - offset), total)


def assert_event_window_at_newest(frame: bytes, where: str) -> None:
    """The event window sits at the newest end of the list.

    This is what growing the viewport is supposed to restore, and it is the
    first number that says so. The total is deliberately unread: it counts
    events the TUI raises itself, so a runner that surfaces one more load
    error than this laptop reads a different number for reasons the scenario
    is not about. Pinning the literal "1-6/6" failed on CI at "1-6/7" -- the
    window was exactly where it belonged.
    """
    match = EVENT_RANGE_RE.search(frame)
    if match is None:
        raise AssertionError(f"{where} drew no event range: {frame!r}")
    first, last, total = (int(g) for g in match.groups())
    if first != 1:
        raise AssertionError(
            f"{where} did not return to the newest event: "
            f"range {first}-{last}/{total}: {frame!r}"
        )
    if not 1 <= last <= total:
        raise AssertionError(
            f"{where} drew an impossible range {first}-{last}/{total}: {frame!r}"
        )


def assert_overview_event_rows(
    process: subprocess.Popen[bytes],
    master_fd: int,
    slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    def scroll_to_oldest(total: int, window: int = 2, start_offset: int = 0) -> None:
        """Press j until the window rests against the oldest event.

        How many presses that takes follows the event total, which the TUI
        raises itself. Four presses against a literal "/6" held only while
        the startup event count happened to equal the panel.

        [start_offset] is the offset the panel already rests at. The second
        walk of the scenario starts where the 22-row surface expansion clamped
        the offset -- with more events than the panel that is not the newest
        window, so counting from 0 would wait for labels the TUI has
        already scrolled past.
        """
        for first in range(start_offset + 2, total - window + 2):
            send_and_wait(
                process,
                master_fd,
                output,
                b"j",
                event_range(first, first + window - 1, total),
            )

    def scroll_to_newest(total: int, window: int = 2) -> None:
        """Press k until the window rests against the newest event.

        That is where the collapsed run of manual refreshes is drawn; the
        oldest window this scenario pins does not carry it.
        """
        for first in range(total - window, 0, -1):
            send_and_wait(
                process,
                master_fd,
                output,
                b"k",
                event_range(first, first + window - 1, total),
            )

    wait_for_output(process, master_fd, output, b"TUI started", start=0, timeout=10.0)
    wait_for_output(process, master_fd, output, b"task-5", start=0, timeout=3.0)
    wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=3.0)
    cluster_end = output.find(b"cluster-a") + len(b"cluster-a")
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=cluster_end,
        timeout=3.0,
    )

    send_and_wait(process, master_fd, output, b"rrrrr2", b"MASC Keepers")
    tab_until(process, master_fd, output, b"MASC Overview")

    # The smallest viewport that still fits the whole Overview budget. It grew
    # by two terminal rows when the surface strip and composer took their
    # fixed lines, so this is 24 rather than 22; the assertions below are the
    # same surface budget, not a larger one.
    overview = resize_and_wait(
        process,
        master_fd,
        output,
        rows=24,
        columns=100,
        needle=b"MASC Overview",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    # "Manual refresh" and not "TUI started": nothing has scrolled yet, so the
    # panel rests on the newest events and the oldest one need not be drawn.
    # That it was drawn held only while the total equalled the panel's rows.
    for expected in (b"Manual refresh", b"task-1", b"task-5", b"q:quit"):
        if expected not in overview:
            raise AssertionError(f"24-row terminal Overview omitted {expected!r}: {overview!r}")
    assert_event_window_at_newest(overview, "24-row terminal Overview")
    span = event_range_span(overview, "24-row terminal Overview")
    # The cap is a ceiling, not a quota: the panel draws every event it has up
    # to six. The total is read off the screen for the reason event_total()
    # gives -- it counts events the TUI raises itself, so it is not the
    # fixture's to fix -- and this line asserted a literal 6 against it, which
    # held only while startup happened to raise at least six.
    expected_span = min(OVERVIEW_PANEL_ROW_CAP, event_total(overview, "24-row terminal Overview"))
    if span != expected_span:
        raise AssertionError(
            f"24-row terminal Overview drew {span} event rows, not the "
            f"{expected_span} it has room for: {overview!r}"
        )

    overview = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=100,
        needle=b"MASC Overview",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for expected in (b"Manual refresh", b"task-1", b"q:quit"):
        if expected not in overview:
            raise AssertionError(f"14-row Overview omitted {expected!r}: {overview!r}")
    total = event_total(overview, "14-row Overview")
    if newest_window(2, total) not in overview:
        raise AssertionError(f"14-row Overview omitted its event range: {overview!r}")
    span = event_range_span(overview, "14-row Overview")
    if span != 2:
        raise AssertionError(
            f"14-row Overview drew {span} event rows, not the two it has room "
            f"for: {overview!r}"
        )
    if b"TUI started" in overview or b"task-2" in overview:
        raise AssertionError(f"14-row Overview exceeded its row budget: {overview!r}")

    scroll_to_oldest(total)
    oldest = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=99,
        needle=oldest_window(2, total),
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    if b"TUI started" not in oldest:
        raise AssertionError(f"Overview could not reach its oldest event: {oldest!r}")

    send_and_wait(process, master_fd, output, b"jk", event_range(total - 2, total - 1, total))
    send_and_wait(process, master_fd, output, b"j", oldest_window(2, total))

    tab_until(process, master_fd, output, b"MASC Keepers")
    tab_until(process, master_fd, output, oldest_window(2, total))
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=99,
        needle=b"terminal too small",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"jk")
    wait_for_terminal_input_consumed(slave_fd)
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=98,
        needle=b"terminal too small",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    restored = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=100,
        needle=oldest_window(2, total),
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    if b"TUI started" not in restored:
        raise AssertionError(
            f"compact viewport changed the hidden event offset: {restored!r}"
        )

    expanded = resize_and_wait(
        process,
        master_fd,
        output,
        rows=24,
        columns=100,
        needle=clamped_window(OVERVIEW_PANEL_ROW_CAP, total, total),
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    if b"TUI started" not in expanded:
        raise AssertionError(f"Overview resize lost a retained event: {expanded!r}")

    resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=100,
        needle=clamped_window(2, max(0, total - OVERVIEW_PANEL_ROW_CAP), total),
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    scroll_to_oldest(total, start_offset=max(0, total - OVERVIEW_PANEL_ROW_CAP))
    # A manual refresh while the newest row is already a manual refresh does
    # not add a row. The panel collapses a run of identical events into one
    # with a ×N tail, keyed on event type and content alone
    # (Masc_tui_types.overview_event_collapse_key), so the count beside the
    # title stays where it is and the run grows instead. Asserting the count
    # went up waited on a row the panel had folded away.
    scroll_to_newest(total)
    before_run = manual_refresh_run(
        bytes(output), "Overview before the refresh"
    )
    scroll_to_oldest(total)
    # Written rather than waited on: the fold leaves every row of the oldest
    # window exactly as it was, and a differential redraw sends nothing for a
    # row that did not change.
    os.write(master_fd, b"r")
    drain_until_quiet(process, master_fd, output)
    anchored = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=99,
        needle=b"MASC Overview",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    after_r_total = event_total(anchored, "99-column Overview")
    if after_r_total != total:
        raise AssertionError(
            f"the folded refresh changed the row count ({total} -> "
            f"{after_r_total}): {anchored!r}"
        )
    if oldest_window(2, after_r_total) not in anchored:
        raise AssertionError(f"the added event broke the oldest pin: {anchored!r}")
    # The oldest event on screen is the whole claim: the pin held while the
    # event arrived. Which younger event shares the two-row window depends on
    # how many feed events the runtime logged, which is not this test's claim.
    if b"TUI started" not in anchored:
        raise AssertionError(f"the added event changed the manual anchor: {anchored!r}")
    scroll_to_newest(total)
    after_run = manual_refresh_run(bytes(output), "Overview after the refresh")
    if after_run <= before_run:
        raise AssertionError(
            f"the refresh did not reach the event log ({before_run} -> {after_run})"
        )
    scroll_to_oldest(total)

    send_and_wait(
        process,
        master_fd,
        output,
        b"k",
        event_range(after_r_total - 2, after_r_total - 1, after_r_total),
    )
    newer = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=100,
        needle=event_range(after_r_total - 2, after_r_total - 1, after_r_total),
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    if b"TUI started" in newer:
        raise AssertionError(f"one k did not move toward newer events: {newer!r}")

    os.write(master_fd, b"q")


# A Keeper's question to a human is not an approval; it sits under the queue on
# the same surface. Nothing in this suite had ever driven it, so the answer flow
# shipped on the word of the compiler alone.
KEEPER_ASKS_PATH = "/api/v1/keepers/asks"
KEEPER_ASK_ANSWER_PATH = "/api/v1/keepers/ask-answer"


def keeper_asks_response(*, long_question: bool = False) -> HttpFixture:
    return (
        200,
        {
            "keeper": None,
            "open_count": 1,
            "asks": [
                {
                    "keeper": "alpha",
                    "ask_id": "ask-1",
                    "asked_at": 1787557669.0,
                    "context": "the rollout needs a call",
                    "resolution": {"state": "open"},
                    "questions": [
                        {
                            "question_id": "q-1",
                            "header": "Rollout",
                            "prompt": "ship the cold-start change now?",
                            "mode": "single",
                            "free_text": {"allowed": False},
                            "choices": [
                                {"choice_id": "c-yes", "label": "ship it"},
                                {"choice_id": "c-no", "label": "hold"},
                            ],
                        },
                        *([
                            {
                                "question_id": "q-2",
                                "header": "Explanation",
                                "prompt": "Explain the rollout decision",
                                "mode": "single",
                                "free_text": {"allowed": True},
                                "choices": [{
                                    "choice_id": "c-long",
                                    "label": "Consider the deployment consequences. " * 80,
                                }],
                            }
                        ] if long_question else []),
                    ],
                }
            ],
        },
    )


def keeper_ask_answer_interaction(
    fixtures: HttpFixtures, ask_requests: HttpRequests
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=10.0)
        cluster_end = output.find(b"cluster-a") + len(b"cluster-a")
        wait_for_output(
            process, master_fd, output, FRAME_END, start=cluster_end, timeout=3.0
        )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=180,
            needle=b"MASC Overview",
            final_cursor=b"\x1b[?25l",
        )
        tab_until(process, master_fd, output, b"MASC Keepers")
        tab_until(process, master_fd, output, b"Questions waiting on you")

        # Open an approval's detail. The answer flow is drawn by the list, so
        # this is where [a] used to set the mode and change nothing on screen.
        detail = send_and_wait(
            process, master_fd, output, b"\r", b"Esc: back to the list"
        )
        if b"Questions waiting on you" in CSI_RE.sub(
            b"", frame_containing(detail, b"Esc: back to the list")
        ):
            raise AssertionError(
                "the detail draws the questions; this scenario no longer tests "
                f"the surface that cannot: {detail!r}"
            )

        answering = send_and_wait(process, master_fd, output, b"a", b"Enter:answer")
        answering_plain = CSI_RE.sub(b"", answering)
        for needle in (b"ship the cold-start change now?", b"ship it", b"hold"):
            if needle not in answering_plain:
                raise AssertionError(
                    f"answering the ask did not draw {needle!r}: {answering!r}"
                )

        # Pick, arm, send. Each step has to be visible: the answer used to be
        # composable and unsendable, because this was the one site in the file
        # waiting for Enter under the name terminals do not send.
        # send_and_wait reads the raw stream and colour sits between the mark
        # and the label, so wait on the mark and check the pairing on the
        # stripped frame.
        picked = send_and_wait(process, master_fd, output, b"1", b"1 (o) ")
        picked_plain = CSI_RE.sub(b"", picked)
        if b"(o) c-yes" not in picked_plain:
            raise AssertionError(f"picking did not mark c-yes: {picked!r}")
        if b"(o) c-no" in picked_plain:
            raise AssertionError(f"picking one choice marked both: {picked!r}")
        send_and_wait(
            process, master_fd, output, b"\r", b"Press Enter again to send"
        )
        os.write(master_fd, b"\r")
        drain_until_quiet(process, master_fd, output)
        sent = [
            body
            for path, body in ask_requests
            if path == KEEPER_ASK_ANSWER_PATH
            and b'"ask_id":"ask-1"' in body
            and b'"c-yes"' in body
        ]
        if not sent:
            raise AssertionError(
                f"the answer never reached the server: {ask_requests!r}"
            )

        os.write(master_fd, b"q")

    return interact


def question_reader_interaction(requests: HttpRequests) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"Questions waiting on you")
        send_and_wait(process, master_fd, output, b"a", b"Question 1/2")
        send_and_wait(process, master_fd, output, b"\x1b[C", b"Question 2/2")
        resized = resize_and_wait(
            process, master_fd, output, rows=24, columns=100,
            needle=b"Question 2/2", final_cursor=b"\x1b[?25l",
        )
        progress = re.search(rb"Lines (\d+)-(\d+)/(\d+)", CSI_RE.sub(b"", resized))
        if progress is None or int(progress[2]) >= int(progress[3]):
            raise AssertionError(f"long question did not overflow: {resized!r}")
        paged = send_and_wait(process, master_fd, output, b"\x1b[6~", b"Lines ")
        progress = re.search(rb"Lines (\d+)-(\d+)/(\d+)", CSI_RE.sub(b"", paged))
        if progress is None or int(progress[1]) <= 1:
            raise AssertionError(f"PageDown did not scroll the question: {paged!r}")
        send_and_wait(process, master_fd, output, b"\x1b[D", b"Question 1/2")
        reset = send_and_wait(process, master_fd, output, b"\x1b[C", b"Question 2/2")
        if b"Lines 1-" not in CSI_RE.sub(b"", reset):
            raise AssertionError(f"question navigation kept the previous scroll: {reset!r}")

        # The choices fill the reader, but opening text entry must reveal the
        # editor immediately and keep its caret visible as the text grows.
        send_and_wait(process, master_fd, output, b"t", b"write: ")
        typed = send_and_wait(
            process, master_fd, output,
            b"operator response " * 100 + b"VISIBLE_EDITOR_TAIL",
            b"VISIBLE_EDITOR_TAIL",
        )
        if "▌".encode() not in CSI_RE.sub(b"", frame_containing(typed, b"VISIBLE_EDITOR_TAIL")):
            raise AssertionError(f"the text caret left the visible reader: {typed!r}")
        resize_and_wait(
            process, master_fd, output, rows=22, columns=90,
            needle=b"VISIBLE_EDITOR_TAIL", final_cursor=b"\x1b[?25l",
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"PgUp/PgDn")
        drain_until_quiet(process, master_fd, output)
        if any(path == KEEPER_ASK_ANSWER_PATH for path, _ in requests):
            raise AssertionError(f"browsing or cancelling text sent an answer: {requests!r}")
        os.write(master_fd, b"q")

    return interact


def gate_mode_picker_interaction(requests: HttpRequests) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"[w] Workspace:")
        mode_paths = {
            "/api/v1/dashboard/gate/mode",
            "/api/v1/dashboard/gate/external-mode",
        }

        def mode_requests() -> list[tuple[str, object]]:
            return [(path, json.loads(body)) for path, body in requests if path in mode_paths]

        send_and_wait(process, master_fd, output, b"w", b"Ask me for each decision")
        send_and_wait(process, master_fd, output, b"\x1b[B", b"Let Auto Judge decide")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Approvals")
        drain_until_quiet(process, master_fd, output)
        if mode_requests():
            raise AssertionError(f"opening, moving or cancelling changed Gate mode: {requests!r}")

        send_and_wait(process, master_fd, output, b"w", b"Ask me for each decision")
        send_and_wait(process, master_fd, output, b"\x1b[B", b"Let Auto Judge decide")
        drain_until_quiet(process, master_fd, output)
        if mode_requests():
            raise AssertionError(f"Gate mode changed before Enter: {requests!r}")
        send_and_wait(process, master_fd, output, b"\r", b"MASC Approvals")
        drain_until_quiet(process, master_fd, output)
        expected = [("/api/v1/dashboard/gate/mode", {"mode": "auto_judge"})]
        if mode_requests() != expected:
            raise AssertionError(f"Enter did not apply only the selected Workspace mode: {requests!r}")

        send_and_wait(process, master_fd, output, b"e", b"Ask me for each decision")
        drain_until_quiet(process, master_fd, output)
        if mode_requests() != expected:
            raise AssertionError(f"opening Outside services changed a mode: {requests!r}")
        send_and_wait(process, master_fd, output, b"\r", b"MASC Approvals")
        drain_until_quiet(process, master_fd, output)
        expected.append(("/api/v1/dashboard/gate/external-mode", {"mode": "manual"}))
        if mode_requests() != expected:
            raise AssertionError(f"Outside services choice used the wrong lane or mode: {requests!r}")
        os.write(master_fd, b"q")

    return interact


BLOCKED_GATE_REASON_PREFIX = b"Auto Judge exact attempt quarantined after provider"
BLOCKED_GATE_REASON_TAIL = b"operator must retain this terminal explanation"


def blocked_gate_detail_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    reason = (
        "Auto Judge exact attempt quarantined after provider transport closed "
        "while decoding the structured verdict; operator must retain this "
        "terminal explanation"
    )
    fixtures["/api/v1/dashboard/gate"] = (
        200,
        {
            "approval_queue": [
                {
                    "id": "appr-blocked-detail",
                    "keeper_name": "alpha",
                    "tool_name": "tool_execute",
                    "input_preview": '{"command":"deploy"}',
                    "input_hash": "a" * 64,
                    "sequence": 41,
                    "exact_attempt": {
                        "state": "bound",
                        "status": "quarantined",
                        "quarantine_cause": "cancellation",
                    },
                    "summary_status": {"status": "failed", "reason": reason},
                    "summary_attempt_disposition": {"code": "settled"},
                }
            ],
            "approval_queue_state": {"state": "ready"},
            "hitl": {
                "gate_mode": {"mode": "auto_judge"},
                "external_gate_mode": {"mode": "manual"},
            },
            "approval_rules": [],
            "approval_rules_state": {"state": "ready"},
        },
    )
    return fixtures


def blocked_gate_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=100,
            needle=b"MASC Overview",
        )
        tab_until(process, master_fd, output, b"MASC Approvals")
        wait_for_output(
            process, master_fd, output, b"AUTO JUDGE BLOCKED", start=0, timeout=5.0
        )
        detail = send_and_wait(
            process, master_fd, output, b"\r", BLOCKED_GATE_REASON_TAIL
        )
        frame = frame_containing(detail, BLOCKED_GATE_REASON_TAIL)
        plain = CSI_RE.sub(b"", frame)
        for needle in (
            b"reason",
            BLOCKED_GATE_REASON_PREFIX,
            BLOCKED_GATE_REASON_TAIL,
            b"this exact attempt cannot be replayed",
        ):
            if needle not in plain:
                raise AssertionError(
                    f"blocked Gate detail omitted {needle!r}: {frame!r}"
                )
        if BLOCKED_GATE_REASON_PREFIX + b"~" in plain:
            raise AssertionError(f"blocked Gate reason was cell-truncated: {frame!r}")
        os.write(master_fd, b"q")

    return interact


def approval_selection_identity_interaction(
    fixtures: HttpFixtures,
    initial_items: list[dict[str, object]],
    approval_new: dict[str, object],
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=10.0)
        cluster_end = output.find(b"cluster-a") + len(b"cluster-a")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=cluster_end,
            timeout=3.0,
        )
        tab_until(process, master_fd, output, b"MASC Keepers")
        tab_until(
            process,
            master_fd,
            output,
            approvals_header(3),
        )
        selected = send_and_wait(process, master_fd, output, b"j", b"keeper_probe")
        selected_plain = CSI_RE.sub(b"", selected)
        if not re.search(
            rb">\s+masc-tui\s+keeper_probe\s+keeper\s+beta", selected_plain
        ):
            raise AssertionError(f"fixture did not select approval B: {selected!r}")

        # An ask names what it is asking about, so the row under the cursor is
        # followable. The kind is read from the typed target, not matched as
        # text: this one targets keeper beta.
        copy_reference(process, master_fd, output, b"masc://keepers/beta")

        fixtures[
            "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
        ] = approval_selection_snapshot([approval_new, *initial_items])
        refreshed = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            approvals_header(4),
        )
        refreshed_frame = frame_containing(
            refreshed,
            approvals_header(4),
        )
        refreshed_plain = CSI_RE.sub(b"", refreshed_frame)
        if not re.search(
            rb">\s+masc-tui\s+keeper_probe\s+keeper\s+beta",
            refreshed_plain,
        ):
            raise AssertionError(
                f"approval refresh changed the selected token: {refreshed!r}"
            )

        armed = send_and_wait(process, master_fd, output, b"y", b"Press y again:")
        expected_arm = b"Press y again: keeper_probe on keeper (masc_keeper_status)"
        if expected_arm not in armed:
            raise AssertionError(f"approval refresh armed the wrong token: {armed!r}")
        os.write(master_fd, b"q")

    return interact


def assert_planning_goal_selected(frame: bytes, title: bytes) -> None:
    """The goal named by [title] is the row the cursor is on.

    Anchored on the gutter marker and the title, with the columns between them
    left unread. Those columns carry a phase label, a proof mark and a priority,
    and each is its own contract with its own tests; pinning their exact shape
    here made this assertion fail whenever one of them changed. It did:
    #29786 put a proof mark between the phase and the priority, and this regex
    had required whitespace there.
    """
    plain = CSI_RE.sub(b"", frame)
    # What sits between the status bracket, priority, goal id, and title is the
    # renderer's business. This assertion means only "this goal is the selected
    # row"; information columns can be inserted without changing that fact.
    selected = re.compile(
        rb">[ \t]+\[[^\]\r\n]+\][^\r\n]*?P1[^\r\n]*?" + re.escape(title)
    )
    if selected.search(plain) is None:
        raise AssertionError(f"Planning did not select {title!r}: {frame!r}")


def open_loaded_planning(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
) -> None:
    # Navigate by named surface so Planning tests do not depend on tab order.
    palette_go(process, master_fd, output, b"go Planning", b"plan-alpha-29424")


def planning_reorder_identity_interaction(fixtures: HttpFixtures) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        open_loaded_planning(process, master_fd, output)
        selected = send_and_wait(process, master_fd, output, b"j", b"plan-beta-29424")
        if b"metric-goal-b-29424" not in CSI_RE.sub(b"", selected):
            raise AssertionError(
                f"Planning selected row omitted its metric/target: {selected!r}"
            )
        assert_planning_goal_selected(
            frame_containing(selected, b"plan-beta-29424"),
            b"plan-beta-29424",
        )

        fixtures[PLANNING_PATH] = planning_snapshot(
            [
                planning_goal("goal-new-29424", "plan-new-reorder-applied-29424"),
                planning_goal("goal-a-29424", "plan-alpha-29424"),
                planning_goal("goal-b-29424", "plan-beta-29424"),
                planning_goal("goal-c-29424", "plan-charlie-29424"),
            ]
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"plan-new-reorder-applied-29424",
        )
        refreshed = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"plan-new-reorder-applied-29424",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        assert_planning_goal_selected(refreshed, b"plan-beta-29424")

        detail = send_and_wait(process, master_fd, output, b"\x1b[C", b"goal-b-29424")
        goal_reference = b"masc://planning/goal-b-29424"
        if (
            b"plan-beta-29424" not in detail
            # The footer is built from the key table now, which spells the
            # pair "Left / Esc:back". The flat "left/Esc:back" is the string
            # this surface carried before it read its hints from the bindings.
            or b"Left / Esc:back" not in detail
            or goal_reference not in detail
        ):
            raise AssertionError(
                f"Planning refresh opened a different goal detail: {detail!r}"
            )
        copy_reference(process, master_fd, output, goal_reference)
        listing = send_and_wait(process, master_fd, output, b"\x1b[D", b"MASC Planning")
        assert_planning_goal_selected(listing, b"plan-beta-29424")
        os.write(master_fd, b"q")

    return interact


def planning_resize_budget_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    open_loaded_planning(process, master_fd, output)
    # The surface strip and composer consume two rows. Exercise the old
    # zero-goal case (19 surface rows) and the minimum supported surface (14).
    for terminal_rows in (21, 16, 17, 20, 24, 16):
        frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=terminal_rows,
            columns=120,
            needle=b"MASC Planning",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        assert_planning_goal_selected(frame, b"plan-alpha-29424")
        footer_row = frame_row_of(frame, b"j/k:move")
        goal_row = frame_row_of(frame, b"plan-alpha-29424")
        # Row addresses include the prepended surface strip; the footer sits
        # immediately above the composer on the terminal's last row.
        if not goal_row < footer_row < terminal_rows:
            raise AssertionError(f"Planning overflowed its surface: {frame!r}")
        selected = send_and_wait(
            process, master_fd, output, b"j", b"plan-beta-29424"
        )
        assert_planning_goal_selected(selected, b"plan-beta-29424")
        restored = send_and_wait(
            process, master_fd, output, b"k", b"plan-alpha-29424"
        )
        assert_planning_goal_selected(restored, b"plan-alpha-29424")

    mode_prefix = re.search(
        rb" MASC Planning[^\r\n]*?filter:active", CSI_RE.sub(b"", frame)
    )
    if mode_prefix is None:
        raise AssertionError(f"Planning wide header omitted its modes: {frame!r}")
    # Four cells belong to the frame margins. At this width the title and
    # modes exactly fill the content area, before the timestamp is appended.
    boundary_cols = fixture_cell_width(mode_prefix.group().decode("utf-8")) + 4
    for columns in (80, boundary_cols):
        narrow = resize_and_wait(
            process,
            master_fd,
            output,
            rows=24,
            columns=columns,
            needle=b"MASC Planning",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        plain_narrow = CSI_RE.sub(b"", narrow)
        if b"filter:active" not in plain_narrow or b"sort:" not in plain_narrow:
            raise AssertionError(f"Planning hid its modes behind the title: {narrow!r}")
    terminal_rows = 24

    # One press, not two. The pane opens on Planning_filter_active, so the
    # first press lands on completed, which these fixtures leave empty --
    # the note this step is about is already on that screen. The old pair
    # was written for a default of Planning_filter_all: it waited for
    # "filter:active", the filter the pane had just left, and then for a note
    # that a second press had already carried past.
    empty = send_and_wait(process, master_fd, output, b"f", b"filter:completed")
    if b"no goals in this filter" not in CSI_RE.sub(b"", empty):
        raise AssertionError(
            f"the empty filter drew no note: {empty!r}"
        )
    if frame_row_of(empty, b"no goals in this filter") >= terminal_rows - 2:
        raise AssertionError(f"Planning empty note overflowed: {empty!r}")
    os.write(master_fd, b"q")


def planning_missing_detail_interaction(fixtures: HttpFixtures) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        open_loaded_planning(process, master_fd, output)
        selected = send_and_wait(process, master_fd, output, b"j", b"plan-beta-29424")
        assert_planning_goal_selected(
            frame_containing(selected, b"plan-beta-29424"),
            b"plan-beta-29424",
        )
        detail = send_and_wait(process, master_fd, output, b"\r", b"goal-b-29424")
        if b"plan-beta-29424" not in detail or b"Esc:back" not in detail:
            raise AssertionError(f"fixture did not open Planning B detail: {detail!r}")

        fixtures[PLANNING_PATH] = planning_snapshot(
            [
                planning_goal("goal-a-29424", "plan-alpha-29424"),
                planning_goal("goal-c-29424", "plan-charlie-29424"),
                planning_goal("goal-d-29424", "plan-delta-missing-applied-29424"),
            ]
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"plan-delta-missing-applied-29424",
        )
        recovered = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"plan-delta-missing-applied-29424",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        assert_planning_goal_selected(recovered, b"plan-charlie-29424")
        # What has to hold is that the surface fell back to the list rather
        # than drawing a detail for a goal the snapshot no longer carries.
        # The footer stopped answering that: it is built from the key table
        # now and publishes "Left / Esc:back" in both modes, and it never says
        # "Enter:detail" -- the Planning row spells that key "Right / Enter"
        # (Masc_tui_keys, Planning) and this width does not reach it anyway.
        # The column header is the list pane's own line and the goal link and
        # timeline heading are the detail pane's, so the two together say
        # which mode drew the screen.
        if (
            not PLANNING_LIST_HEADER.search(recovered)
            or b"masc://planning/" in recovered
            or b"TIMELINE" in recovered
        ):
            raise AssertionError(
                f"missing Planning detail did not render list mode: {recovered!r}"
            )

        moved = send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            b"plan-delta-missing-applied-29424",
        )
        assert_planning_goal_selected(
            frame_containing(moved, b"plan-delta-missing-applied-29424"),
            b"plan-delta-missing-applied-29424",
        )
        delta_detail = send_and_wait(process, master_fd, output, b"\r", b"goal-d-29424")
        if (
            b"plan-delta-missing-applied-29424" not in delta_detail
            or b"Esc:back" not in delta_detail
        ):
            raise AssertionError(
                f"recovered Planning list did not open D detail: {delta_detail!r}"
            )
        os.write(master_fd, b"q")

    return interact


# A body says what it is about by writing the reference the TUI itself writes.
# Two posts naming the same task are about the same thing; a post that merely
# spells the id in prose is not, because nobody wrote that connection down.
#
# The last post carries an id whose percent escapes decode to real terminal
# control bytes. Link.parse decodes, so that row is the one place a board post
# could have driven the reader's terminal.
BOARD_REFERENCE_TASK = "masc://overview/tasks/task-77"
BOARD_REFERENCE_GOAL = "masc://planning/goal-9"


def board_reference_http_fixtures() -> HttpFixtures:
    # One body per post, in the list and in the detail. The related block reads
    # the bodies the list carries, and board_post_dashboard_json sends p.body
    # whole -- a list body that summarised would leave the block permanently
    # empty while every unit test still passed.
    bodies = {
        "r1": ("Retry", f"we changed {BOARD_REFERENCE_TASK} for {BOARD_REFERENCE_GOAL}"),
        "r2": ("Rollout", f"also about {BOARD_REFERENCE_TASK}"),
        "r3": ("Prose", "task-77 and goal-9 in prose only"),
        "r4": ("Hostile", "see masc://board/post%1b%5b2Jdanger"),
    }
    posts = [
        board_selection_post(suffix, title, body)
        for suffix, (title, body) in bodies.items()
    ]
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})
    for suffix, (title, body) in bodies.items():
        fixtures[f"/api/v1/board/post-{suffix}?format=flat"] = (
            200,
            {"post": board_selection_post(suffix, title, body), "comments": []},
        )
    return fixtures


def board_reference_interaction(fixtures: HttpFixtures) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=10.0)
        cluster_end = output.find(b"cluster-a") + len(b"cluster-a")
        wait_for_output(
            process, master_fd, output, FRAME_END, start=cluster_end, timeout=3.0
        )
        tab_until(process, master_fd, output, b"MASC Keepers")
        tab_until(process, master_fd, output, screen_header(b"MASC Board", b" (4)"))
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=180,
            needle=screen_header(b"MASC Board", b" (4)"),
            final_cursor=b"\x1b[?25l",
        )

        opened = send_and_wait(process, master_fd, output, b"\r", b"POINTS AT")
        plain = CSI_RE.sub(b"", frame_containing(opened, b"POINTS AT"))
        for needle in (b"task", b"task-77", b"goal", b"goal-9"):
            if needle not in plain:
                raise AssertionError(
                    f"POINTS AT dropped {needle!r}: {plain!r}"
                )
        if b"ALSO ABOUT THIS (1)" not in plain:
            raise AssertionError(f"related posts miscounted: {plain!r}")
        if b"post-r2" not in plain:
            raise AssertionError(f"the post naming the same task is missing: {plain!r}")
        if b"post-r3" in plain:
            raise AssertionError(
                f"an id spelled in prose became a link: {plain!r}"
            )

        # Down three rows to the hostile post, whose id decodes to control bytes.
        back = send_and_wait(process, master_fd, output, b"\x1b", b"MASC Board")
        del back
        for row in (b"post-r2", b"post-r3", b"post-r4"):
            send_and_wait(process, master_fd, output, b"j", selected_row(row))
        hostile = send_and_wait(process, master_fd, output, b"\r", b"POINTS AT")
        hostile_frame = frame_containing(hostile, b"POINTS AT")
        if rb"\x1B[2Jdanger" not in CSI_RE.sub(b"", hostile_frame):
            raise AssertionError(
                f"the decoded id was not rendered as text: {hostile_frame!r}"
            )
        if b"\x1b[2Jdanger" in hostile_frame:
            raise AssertionError(
                "a board post drove the reader's terminal: "
                f"{hostile_frame!r}"
            )

        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Board")
        # Arm the exit; the harness supplies the confirming press.
        os.write(master_fd, b"q")

    return interact


def board_json_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=10.0)
        tab_until(process, master_fd, output, b"MASC Keepers")
        tab_until(process, master_fd, output, screen_header(b"MASC Board", b" (2)"))
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=160,
            needle=screen_header(b"MASC Board", b" (2)"),
            final_cursor=b"\x1b[?25l",
        )

        opened = send_and_wait(
            process, master_fd, output, b"\r", b'"verification_request"'
        )
        frame = frame_containing(opened, b'"verification_request"')
        plain = CSI_RE.sub(b"", frame)
        for needle in (
            b'"verification_request": {',
            b'"task_id": "task-1200"',
            b'"approved": true',
            b'"attempt": 3',
        ):
            if needle not in plain:
                raise AssertionError(
                    f"Board JSON was not pretty-printed ({needle!r}): {plain!r}"
                )
        if b'{"verification_request":{"id"' in plain:
            raise AssertionError(f"Board kept compact JSON on one line: {plain!r}")
        highlighted_key = re.compile(
            rb'(?:\x1b\[[0-9;]*m)+'
            + re.escape(b'"verification_request"')
            + rb'(?:\x1b\[[0-9;]*m)+'
        )
        if highlighted_key.search(frame) is None:
            raise AssertionError(f"Board JSON key has no syntax colour: {frame!r}")

        markdown = send_and_wait(
            process, master_fd, output, b"]", b"Normal heading"
        )
        markdown_plain = CSI_RE.sub(b"", frame_containing(markdown, b"Normal heading"))
        for needle in (b"Normal heading", b"Markdown stays authored."):
            if needle not in markdown_plain:
                raise AssertionError(
                    f"ordinary Board Markdown lost {needle!r}: {markdown_plain!r}"
                )
        if b"# Normal heading" in markdown_plain or b"**Markdown" in markdown_plain:
            raise AssertionError(
                f"ordinary Board Markdown rendered as source: {markdown_plain!r}"
            )
        os.write(master_fd, b"q")

    return interact


def board_selection_identity_interaction(fixtures: HttpFixtures) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=10.0)
        cluster_end = output.find(b"cluster-a") + len(b"cluster-a")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=cluster_end,
            timeout=3.0,
        )

        tab_until(process, master_fd, output, b"MASC Keepers")
        tab_until(process, master_fd, output, screen_header(b"MASC Board", b" (3)"))
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=180,
            needle=screen_header(b"MASC Board", b" (3)"),
            final_cursor=b"\x1b[?25l",
        )
        selected_b = selected_row(b"post-b")
        selected_a = selected_row(b"post-a")
        selected_new = selected_row(b"post-new")
        send_and_wait(process, master_fd, output, b"j", selected_b)
        detail = send_and_wait(process, master_fd, output, b"\r", b"detail-body-bravo")
        reference = b"masc://board/post-b"
        if reference not in detail:
            raise AssertionError(f"Board detail omitted its stable link: {detail!r}")
        copy_reference(process, master_fd, output, reference)
        wide = send_and_wait(process, master_fd, output, b"z", b"z:wide")
        wide_frame = frame_containing(wide, reference)
        if b"Board (3)" in wide_frame:
            raise AssertionError(
                f"Board wide detail kept the list pane visible: {wide_frame!r}"
            )
        # iTerm reports Ctrl-W as CSI-u after the TUI enables keyboard
        # disambiguation. It must reach the same pane binding as legacy 0x17.
        send_and_wait(process, master_fd, output, b"z", b"h/l:pane")
        # Focus is a caret on the pane title now, not a key list (keys live in
        # the footer): the same press must move focus, observed by the caret.
        send_and_wait(process, master_fd, output, b"\x1b[119;5u", "\u25b8 Board (3)".encode())
        send_and_wait(process, master_fd, output, b"j", b"detail-body-charlie")
        send_and_wait(process, master_fd, output, b"k", b"detail-body-bravo")
        send_and_wait(process, master_fd, output, b"l", b"j/k:scroll")
        send_and_wait(process, master_fd, output, b"\x1b[6~", b"bravo-25")

        board = send_and_wait(process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (3)"))
        if not selected_b.search(board) or selected_a.search(board):
            raise AssertionError(
                f"Board detail return changed the selected post: {board!r}"
            )

        fixtures["/api/v1/board?sort_by=trending"] = (
            200,
            {
                "posts": [
                    board_selection_post(
                        "trend", "Trending order", "server-trending-order"
                    ),
                    board_selection_post("a", "Alpha", "list-body-a"),
                    board_selection_post("b", "Bravo", "list-body-b"),
                    board_selection_post("c", "Charlie", "list-body-c"),
                ]
            },
        )
        board = send_and_wait(
            process, master_fd, output, b"s", b"post-trend"
        )
        if b"sort:trending" not in board:
            raise AssertionError(f"Board sort did not expose its order: {board!r}")

        fixtures["/api/v1/board?sort_by=trending"] = (
            200,
            {
                "posts": [
                    board_selection_post("new", "New", "list-body-new"),
                    board_selection_post("a", "Alpha", "list-body-a"),
                    board_selection_post("b", "Bravo", "list-body-b"),
                    board_selection_post("c", "Charlie", "list-body-c"),
                ]
            },
        )
        send_and_wait(process, master_fd, output, b"r", b"post-new")
        board = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=179,
            needle=screen_header(b"MASC Board", b" (4)"),
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        if not selected_b.search(board) or selected_new.search(board):
            raise AssertionError(
                f"Board list refresh changed the selected post: {board!r}"
            )

        send_and_wait(process, master_fd, output, b"\r", b"detail-body-bravo")
        os.write(master_fd, b"q")

    return interact


def open_loaded_board(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    *,
    post_count: int,
) -> None:
    wait_for_output(process, master_fd, output, b"cluster-a", start=0, timeout=10.0)
    cluster_end = output.find(b"cluster-a") + len(b"cluster-a")
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=cluster_end,
        timeout=3.0,
    )
    tab_until(process, master_fd, output, b"MASC Keepers")
    tab_until(
        process,
        master_fd,
        output,
        screen_header(b"MASC Board", f" ({post_count})".encode()),
    )


def board_detail_isolation_interaction(b_failure: GatedHttpResponse) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            open_loaded_board(process, master_fd, output, post_count=2)
            send_and_wait(process, master_fd, output, b"\r", b"a-only-comment")
            send_and_wait(process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (2)"))
            send_and_wait(
                process,
                master_fd,
                output,
                b"j",
                selected_row(b"post-b"),
            )

            loading = send_and_wait(process, master_fd, output, b"\r", b"list-body-b")
            if b"Loading Board detail" not in loading or b"a-only-comment" in loading:
                raise AssertionError(
                    f"Board B loading leaked the prior detail: {loading!r}"
                )
            if not wait_for_fixture_event(
                process, master_fd, output, b_failure.requested, timeout=10.0
            ):
                raise AssertionError("Board B detail request did not reach its fixture")

            release_and_wait_for_frame(
                process,
                master_fd,
                output,
                b_failure,
                b"b-detail-failed",
            )
            failed = resize_and_wait(
                process,
                master_fd,
                output,
                rows=29,
                columns=100,
                needle=b"b-detail-failed",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            if b"a-only-comment" in failed:
                raise AssertionError(
                    f"Board B failure leaked the prior detail: {failed!r}"
                )
            os.write(master_fd, b"q")
            completed = True
        finally:
            b_failure.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


def board_detail_authority_interaction(
    fixtures: HttpFixtures,
    late_list: GatedHttpResponse,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            open_loaded_board(process, master_fd, output, post_count=2)
            fixtures["/api/v1/board?sort_by=hot"] = late_list
            fixtures["/api/v1/dashboard/briefing"] = (
                200,
                overview_event_briefing("late-list-applied"),
            )

            read_available(master_fd, output)
            os.write(master_fd, b"r")
            if not wait_for_fixture_event(
                process, master_fd, output, late_list.requested, timeout=10.0
            ):
                raise AssertionError(
                    "late Board list request did not reach its fixture"
                )
            detail = send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"a-authoritative-detail",
            )
            if b"a-only-comment" not in detail:
                raise AssertionError(f"Board A detail did not become ready: {detail!r}")

            late_list.release.set()
            tab_until(process, master_fd, output, b"MASC Planning")
            tab_until(process, master_fd, output, b"MASC Activity")
            tab_until(process, master_fd, output, b"late-list-applied")
            tab_until(process, master_fd, output, b"MASC Keepers")
            board = tab_until(
                process,
                master_fd,
                output,
                b"a-authoritative-detail",
            )
            if b"a-late-light-body" in board:
                raise AssertionError(
                    f"late Board list replaced the ready detail post: {board!r}"
                )

            board_list = send_and_wait(
                process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (3)")
            )
            if b"post-c" not in board_list:
                raise AssertionError(
                    f"late Board list application was not observed: {board_list!r}"
                )
            os.write(master_fd, b"q")
            completed = True
        finally:
            late_list.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


def board_paginated_detail_interaction(
    fixtures: HttpFixtures,
    late_b: GatedHttpResponse,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            open_loaded_board(process, master_fd, output, post_count=2)
            send_and_wait(
                process,
                master_fd,
                output,
                b"j",
                selected_row(b"post-b"),
            )
            send_and_wait(process, master_fd, output, b"\r", b"b-initial-comment")

            # An empty recent page is not an exact-ID deletion response.
            fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": []})
            fixtures["/api/v1/board/post-b?format=flat"] = late_b
            os.write(master_fd, b"R")
            if not wait_for_fixture_event(
                process, master_fd, output, late_b.requested, timeout=10.0
            ):
                raise AssertionError("late Board B request did not reach its fixture")
            refreshing = resize_and_wait(
                process, master_fd, output, rows=30, columns=179,
                needle=b"b-initial-comment", controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            if b"b-initial-comment" not in refreshing:
                raise AssertionError("page omission cleared the refreshing exact detail")

            release_and_wait_for_frame(
                process, master_fd, output, late_b, b"b-late-comment"
            )
            # Prove the page is still empty after the exact detail becomes ready.
            # It must not insert the historical detail into the ranked feed.
            fixtures["/api/v1/board/post-b?format=flat"] = (
                404, {"error": "fixture-exact-post-not-found"}
            )
            failed = send_and_wait(
                process, master_fd, output, b"R", b"fixture-exact-post-not-found"
            )
            if b"Board post load failed" not in CSI_RE.sub(b"", failed):
                raise AssertionError("the exact lookup failure was not shown")
            send_and_wait(
                process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (0)")
            )
            os.write(master_fd, b"q")
            completed = True
        finally:
            late_b.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


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


def screen_rows(drawn: bytes) -> dict[int, bytes]:
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
        rows[int(address.group(1))] = CSI_RE.sub(b"", drawn[address.end() : end])
    return rows


def screen_row_of(rows: dict[int, bytes], needle: bytes) -> int:
    """The topmost row [needle] currently occupies, or -1 when it is gone."""
    carrying = [row for row, text in rows.items() if needle in text]
    return min(carrying) if carrying else -1


def screen_text(drawn: bytes) -> bytes:
    """The plain text of the screen, rows joined top to bottom."""
    return b"\n".join(text for _, text in sorted(screen_rows(drawn).items()))


BRACKETED_PASTE_ON = b"\x1b[?2004h"
PASTE_START = b"\x1b[200~"
PASTE_END = b"\x1b[201~"


def paste_into_a_field_interaction() -> Interaction:
    """A paste goes into the field that is taking characters.

    Seven fields take typed characters; paste used to name four, and row
    search and the command palette were not among them. Their text went to
    the chat draft behind the surface -- invisible there, and on a surface
    with no keeper selected, nowhere at all. The operator saw paste work on
    one screen and do nothing on the next."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(
            process, master_fd, output, BRACKETED_PASTE_ON, start=0, timeout=5.0
        )
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")

        # Row search draws its query in the footer, so the pasted characters
        # are asserted where they landed rather than through what they did.
        send_and_wait(process, master_fd, output, b"/", b"MASC Keepers")
        send_and_wait(
            process,
            master_fd,
            output,
            PASTE_START + b"alph" + PASTE_END,
            b"/alph",
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")

        # The palette runs what it was given. Its first entry with an empty
        # query is "settings", so landing on Lanes is only possible if the
        # pasted characters reached the query: a dropped paste sends the
        # operator to Config instead.
        send_and_wait(
            process,
            master_fd,
            output,
            b":" + PASTE_START + b"go lanes" + PASTE_END + b"\r",
            b"MASC Lanes",
        )

        # A board post is written in its own draft, not in the chat composer,
        # and it holds many lines: the paste goes in whole. CR is what a
        # terminal writes for a break in pasted text, which is the byte that
        # would otherwise have been Return.
        palette_go(process, master_fd, output, b"go board", b"MASC Board")
        send_and_wait(process, master_fd, output, b"w", b"MASC Board")
        send_and_wait(
            process,
            master_fd,
            output,
            PASTE_START + b"pasted board line\rsecond board line" + PASTE_END,
            b"second board line",
        )
        # Esc arms the draft's send-or-discard; d throws it away and leaves
        # the pane, where q is draft text rather than quit.
        #
        # The armed footer names more than those two -- editing in $EDITOR and
        # cycling the hearth sit between them -- so the two keys this step is
        # about are matched with what may come between, the way the TOOLS lane
        # needle tolerates padding. A literal "s:send  d:discard" pinned a
        # footer that had since grown, and starved.
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b",
            re.compile(rb"s:send" + rb"[\x1b\x20-\x7e]*?" + rb"d:discard"),
        )
        send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        os.write(master_fd, b"q")

    return interact


def bracketed_paste_interaction(requests: HttpRequests) -> Interaction:
    """A multi-line paste is one draft, not one message per line.

    Without the mode the terminal delivers a paste as the keys it looks like,
    so each newline in it is Return. The three lines below would be three
    sends -- and while a turn was running, three queued fragments."""

    # A terminal writes CR for a line break in pasted text -- the same byte
    # Return sends, which is exactly why a paste without this mode is one
    # message per line. Pasting the shape that breaks is the point.
    on_the_wire = b"first line\rsecond line\r- https://example.invalid/a?b=1"
    expected_draft = "first line\nsecond line\n- https://example.invalid/a?b=1"

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The mode has to be on before a paste can arrive as a paste. Asserted
        # on the stream rather than inferred from the behaviour below: a
        # terminal that never saw the enable would deliver Return, and the
        # difference between "the enable was not written" and "the reader
        # mishandled it" is the thing this pins down.
        wait_for_output(
            process, master_fd, output, BRACKETED_PASTE_ON, start=0, timeout=5.0
        )

        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        frame = send_and_wait(
            process,
            master_fd,
            output,
            PASTE_START + on_the_wire + PASTE_END,
            b"example.invalid",
        )
        plain = CSI_RE.sub(b"", frame)
        for line in (b"first line", b"second line", b"- https://example.invalid"):
            if line not in plain:
                raise AssertionError(f"the draft lost {line!r}: {plain!r}")

        # Three lines, one draft: nothing was sent and nothing is queued.
        posted = [path for path, _ in requests if path.endswith("/chat/stream")]
        if posted:
            raise AssertionError(
                f"a pasted newline was taken as Return: {posted!r}"
            )
        if b"queued 1" in plain or b"(sending " in plain:
            raise AssertionError(f"the paste dispatched something: {plain!r}")

        # Enter still sends, and it sends the whole thing at once.
        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != expected_draft:
            raise AssertionError(
                f"the keeper was sent something other than what was pasted: "
                f"{message!r}"
            )
        # Chat opened from detail, so Esc goes back there first.
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def word_delete_interaction(requests: HttpRequests) -> Interaction:
    """Ctrl-W and Alt+Backspace delete the word behind the composer cursor.

    A chat draft answers two readline muscle memories: Ctrl-W rubs out the
    last word, and Alt+Backspace -- ESC DEL on the wire -- does the same.
    Without a binding Ctrl-W fell through to a no-op, and ESC DEL was
    swallowed as a bare Esc: the draft stayed whole and the chat closed
    under the typist's thumb."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(
            process, master_fd, output, BRACKETED_PASTE_ON, start=0, timeout=5.0
        )
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        # Ctrl-W takes the last word and keeps the separator before it: the
        # draft reads "hello ", and the caret ends one cell past it. The
        # composer row is all a draft edit repaints, so the caret's column is
        # where "kept the separator" can be told from "ate it": 13 is the
        # prompt plus "hello ", 12 is what "hello" would give.
        send_and_wait(process, master_fd, output, b"hello world", b"hello world")
        frame = send_and_wait(process, master_fd, output, b"\x17", b"hello")
        plain = CSI_RE.sub(b"", frame)
        if b"hello world" in plain:
            raise AssertionError(f"Ctrl-W left the whole draft: {plain!r}")
        if b"hello" not in plain:
            raise AssertionError(f"Ctrl-W took more than the word: {plain!r}")
        cursor = CURSOR_RE.search(frame)
        if cursor is None or cursor.group(2) != b"13":
            raise AssertionError(
                f"Ctrl-W did not stop after the kept separator: {frame!r}"
            )

        # Alt+Backspace arrives as ESC DEL: delete-word-back like Ctrl-W, not
        # Esc. A draft edit does not repaint the breadcrumb, so the proof the
        # chat stayed open is that the next letters still land in the
        # composer -- on the detail surface they would bind to keys instead.
        os.write(master_fd, b"\x1b\x7f")
        frame = send_and_wait(process, master_fd, output, b"still here", b"still here")
        plain = CSI_RE.sub(b"", frame)
        if b"hello" in plain:
            raise AssertionError(f"Alt+Backspace left the draft: {plain!r}")

        # Nothing was sent while the draft was being edited.
        posted = [path for path, _ in requests if path.endswith("/chat/stream")]
        if posted:
            raise AssertionError(f"an edit dispatched something: {posted!r}")

        # Enter still sends what survived the editing.
        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "still here":
            raise AssertionError(f"the keeper was sent {message!r}")
        # Chat opened from detail, so Esc goes back there first.
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


GRAPHICS_QUERY_ID = 31
GRAPHICS_SUPPORTED_REPLY = b"\x1b_Gi=%d;OK\x1b\\" % GRAPHICS_QUERY_ID
IMAGE_NAME = "shot.png"


def seed_image_workspace(base_path: str) -> None:
    # A real 8x8 PNG rather than arbitrary bytes: the TUI hands the file
    # straight to the terminal, and a scenario that passed on nonsense would
    # not have shown that a picture can make the trip.
    def chunk(kind: bytes, body: bytes) -> bytes:
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    width = height = 8
    raw = b"".join(b"\x00" + bytes([255, 0, 0, 255] * width) for _ in range(height))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )
    Path(base_path, IMAGE_NAME).write_bytes(png)


def image_view_interaction() -> Interaction:
    """A terminal that says it draws pictures gets one, and gets it taken away.

    The reply to the capability query is preloaded, so this scenario is a
    terminal that answers. What a terminal that stays silent does is the other
    half, asserted below by asking for an image it cannot be given."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        # Asked before the first frame, so it is already on the stream.
        for expected in (b"\x1b_G", b"i=%d" % GRAPHICS_QUERY_ID, b"a=q"):
            if expected not in output:
                raise AssertionError(
                    f"the capability query never went out; missing {expected!r}"
                )

        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        path = str(Path(base_path, IMAGE_NAME))
        command = f"/image {path}".encode()
        # The 100-column fixture leaves 92 cells for the draft. Long Dune
        # sandbox paths therefore draw the composer's omission marker and
        # newest tail, while Enter still submits the complete buffer.
        visible_command = command if len(command) <= 92 else b"~" + command[-91:]
        send_and_wait(
            process,
            master_fd,
            output,
            command,
            composer_showing(visible_command),
        )

        read_available(master_fd, output)
        drawn_from = len(output)
        os.write(master_fd, b"\r")
        wait_for_output(
            process, master_fd, output, b"a=T", start=drawn_from, timeout=5.0
        )
        drawn = bytes(output[drawn_from:])
        for expected in (b"\x1b_G", b"f=100", b"a=T"):
            if expected not in drawn:
                raise AssertionError(
                    f"the image was not placed; missing {expected!r}: {drawn!r}"
                )

        # The terminal keeps a picture in its own layer, so leaving has to say
        # so explicitly; clearing the screen does not remove one.
        read_available(master_fd, output)
        dismissed_from = len(output)
        os.write(master_fd, b" ")
        wait_for_output(
            process, master_fd, output, b"a=d", start=dismissed_from, timeout=5.0
        )

        # Back on the frame, and the space that dismissed the picture is not
        # also a character in the draft.
        wait_for_output(
            process,
            master_fd,
            output,
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            start=dismissed_from,
            timeout=5.0,
        )

        # Short on purpose: every character typed into the composer is a
        # frame, and a long path spends the scenario's patience on redraws
        # rather than on the thing being asserted.
        missing = b"/image /nope.png"
        send_and_wait(process, master_fd, output, missing, composer_showing(missing))
        send_and_wait(process, master_fd, output, b"\r", b"No such file")

        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def paste_spill_interaction(requests: HttpRequests) -> Interaction:
    """A paste too big for the composer shows as one line and is sent whole.

    The composer is five rows. Four hundred lines in it is a draft the
    operator cannot read, and a draft they cannot read is a message they
    cannot check. The text is kept and goes back in on the way out."""

    pasted = "\r".join(f"line {index}" for index in range(400))
    expected = "\n".join(f"line {index}" for index in range(400))

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        read_available(master_fd, output)
        start = len(output)
        write_all(master_fd, output, PASTE_START + pasted.encode() + PASTE_END)
        wait_for_output(process, master_fd, output, b"[pasted ", start=start, timeout=10.0)
        frame = frame_containing(bytes(output[start:]), b"[pasted ")
        plain = CSI_RE.sub(b"", frame)
        if b"400 line(s)" not in plain:
            raise AssertionError(f"the placeholder does not say the size: {plain!r}")
        # The point of the placeholder: the pasted text is not in the composer.
        if b"line 399" in plain:
            raise AssertionError(f"the draft still flooded: {plain!r}")

        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != expected:
            head = "" if message is None else message[:80]
            raise AssertionError(
                f"the keeper was sent the placeholder, not the paste: {head!r}"
            )

        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def seed_playground_workspace(base_path: str) -> None:
    """Give alpha the directory a Docker keeper reads its files from.

    A keeper reads paths relative to its own sandbox root, and the root the
    profile names is the one that has to exist: a Docker keeper's is
    .masc/playground/docker/<name>/. Seeding .masc/playground/<name>/
    instead leaves the declared root absent, and the TUI then has nowhere to
    write -- it falls back to sending the text, and no file is written at
    all."""
    Path(base_path, ".masc", "config", "keepers").mkdir(parents=True, exist_ok=True)
    Path(base_path, ".masc", "config", "keepers", "alpha.toml").write_text(
        '[keeper]\nsandbox_profile = "docker"\n', encoding="utf-8"
    )
    Path(base_path, ".masc", "playground", "docker", "alpha").mkdir(
        parents=True, exist_ok=True
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


def paste_to_file_interaction(requests: HttpRequests) -> Interaction:
    """A spilled paste is written where the keeper can read it, and the
    message names the file instead of carrying the text."""

    pasted = "\r".join(f"line {index}" for index in range(400))
    expected_file = "\n".join(f"line {index}" for index in range(400))

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        read_available(master_fd, output)
        start = len(output)
        write_all(master_fd, output, PASTE_START + pasted.encode() + PASTE_END)
        wait_for_output(process, master_fd, output, b"[pasted ", start=start, timeout=10.0)

        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message") or ""

        playground = Path(base_path, ".masc", "playground", "docker", "alpha")
        written = sorted(playground.glob("pasted-*.txt"))
        if len(written) != 1:
            raise AssertionError(
                f"expected one file in the keeper's directory, found {written!r}"
            )
        if written[0].read_text(encoding="utf-8") != expected_file:
            raise AssertionError("the file is not what was pasted")

        # The message points at the file rather than carrying the text: that
        # is the whole reason for writing one.
        if written[0].name not in message:
            raise AssertionError(f"the message does not name the file: {message!r}")
        if "line 399" in message:
            raise AssertionError(
                f"the message carried the text as well as the file: {message[:120]!r}"
            )

        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def keeper_chat_succeeded_response(request_body: bytes) -> RawHttpResponse:
    request = json.loads(request_body)
    request_id = request.get("request_id")
    keeper_name = request.get("name")
    message = request.get("message")
    run_id = f"keeper-operation-run-{request_id}"
    message_id = f"keeper-operation-message-{request_id}"
    reply = f"reply-{message}"
    thread_id = f"keeper:{keeper_name}"
    events = [
        {
            "type": "CUSTOM",
            "threadId": "default",
            "timestamp": 1.0,
            "name": "KEEPER_CHAT_OPERATION_ACCEPTED",
            "value": {
                "operation_id": request_id,
                "state": "Queued",
                "queued_count": 0,
            },
        },
        {
            "type": "RUN_STARTED",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
        },
        {
            "type": "TEXT_MESSAGE_START",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "messageId": message_id,
            "role": "assistant",
        },
        {
            "type": "TEXT_MESSAGE_CONTENT",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "messageId": message_id,
            "delta": reply,
        },
        {
            "type": "CUSTOM",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "name": "KEEPER_REPLY_DETAILS",
            "value": {
                "reply": reply,
                "turn_outcome": "visible_reply",
                "turn_ref": "trace-pty#1",
            },
        },
        {
            "type": "TEXT_MESSAGE_END",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "messageId": message_id,
        },
        {
            "type": "RUN_FINISHED",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
        },
    ]
    return RawHttpResponse(
        200,
        "".join(f"data: {json.dumps(event)}\n\n" for event in events).encode(),
        content_type="text/event-stream",
    )


ERROR_DETAIL_PREFIX = b"Keeper turn failed: Provider stream parse failed: json decoder"
ERROR_DETAIL_TAIL = b"exact terminal detail survives wrapping"


def keeper_chat_failed_response(request_body: bytes) -> RawHttpResponse:
    request = json.loads(request_body)
    request_id = request.get("request_id")
    keeper_name = request.get("name")
    run_id = f"keeper-operation-run-{request_id}"
    thread_id = f"keeper:{keeper_name}"
    reason = (
        "Provider stream parse failed: json decoder rejected nested payload "
        "at byte 8192; exact terminal detail survives wrapping"
    )
    events = [
        {
            "type": "CUSTOM",
            "threadId": "default",
            "timestamp": 1.0,
            "name": "KEEPER_CHAT_OPERATION_ACCEPTED",
            "value": {
                "operation_id": request_id,
                "state": "Queued",
                "queued_count": 0,
            },
        },
        {
            "type": "RUN_STARTED",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
        },
        {
            "type": "RUN_ERROR",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "message": reason,
        },
    ]
    return RawHttpResponse(
        200,
        "".join(f"data: {json.dumps(event)}\n\n" for event in events).encode(),
        content_type="text/event-stream",
    )


def keeper_chat_error_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process, master_fd, output, rows=24, columns=100, needle=b"MASC Overview"
        )
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"c", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        send_and_wait(process, master_fd, output, b"trigger-error", b"trigger-error")
        failed = send_and_wait(
            process, master_fd, output, b"\r", ERROR_DETAIL_TAIL
        )
        frame = frame_containing(failed, ERROR_DETAIL_TAIL)
        plain = CSI_RE.sub(b"", frame)
        for needle in (b"ERROR", ERROR_DETAIL_PREFIX, ERROR_DETAIL_TAIL):
            if needle not in plain:
                raise AssertionError(
                    f"wrapped Keeper error omitted {needle!r}: {frame!r}"
                )
        if ERROR_DETAIL_PREFIX + b"~" in plain:
            raise AssertionError(f"Keeper error was cell-truncated: {frame!r}")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def chat_queue_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    # Admit the run before holding its terminal reply. Withholding the HTTP
    # response itself truthfully renders WAITING TO START, never IN PROGRESS.
    gate = GatedHttpResponse((200, {}), hold_seconds=30.0)

    def terminal_response(request_body: bytes) -> RawHttpResponse | StreamingHttpResponse:
        with gate.lock:
            call_index = gate.calls
            gate.calls += 1
        response = keeper_chat_succeeded_response(request_body)
        if call_index != 0:
            return response
        blocks = [block for block in response.body.split(b"\n\n") if block]
        start_index = next(index for index, block in enumerate(blocks)
                           if json.loads(block.removeprefix(b"data: "))["type"] == "RUN_STARTED")

        def chunks() -> Iterator[bytes]:
            yield b"\n\n".join(blocks[:start_index + 1]) + b"\n\n"
            gate.requested.set()
            try:
                if gate.release.wait(timeout=gate.hold_seconds):
                    yield b"\n\n".join(blocks[start_index + 1:]) + b"\n\n"
                # A fixture deadline closes the incomplete stream; it must not
                # fabricate RUN_FINISHED before the interaction releases it.
            finally:
                gate.completed.set()

        return StreamingHttpResponse(chunks)

    return {
        "/api/v1/keepers/chat/stream": RequestHttpResponse(terminal_response)
    }, gate


def seed_uncoalesced_queue(base_path: str) -> None:
    """Give every queued line its own turn, which is what this scenario walks.

    [tui].coalesce_queued_input is absent-reads-as-yes, and with it on a line
    typed while an earlier one is still waiting joins that line instead of
    queueing behind it -- one NEXT holding "queued-one\\nqueued-two" rather
    than two. That is the right default (a thought, its correction and the
    part the writer forgot are one message) and it is not what a scenario
    about walking a queue of two can use.
    """
    config = Path(base_path, ".masc", "config", "runtime.toml")
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text("[tui]\ncoalesce_queued_input = false\n", encoding="utf-8")


def chat_queue_interaction(gate: GatedHttpResponse) -> Interaction:
    """Pending input stays in NEXT, outside the active causal turn, and the
    arrows can still edit it."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        send_and_wait(
            process, master_fd, output, b"first-line", composer_showing(b"first-line")
        )
        # The turn has to be running before the next Enter can queue behind
        # it, and the pane says so itself. Waiting on the fixture's own event
        # instead would stop pumping the terminal, and a TUI whose output
        # nobody reads blocks before it ever posts.
        # RUN_STARTED is now present in the fixture stream, so the current
        # Working transcript must render IN PROGRESS before input queues.
        sending = send_and_wait(process, master_fd, output, b"\r", b"IN PROGRESS")
        wait_for_output(
            process,
            master_fd,
            output,
            b"IN PROGRESS",
            start=0,
            timeout=5.0,
        )
        footer_while_sending = frame_row_of(sending, b"  Enter:")

        send_and_wait(
            process, master_fd, output, b"queued-one", composer_showing(b"queued-one")
        )
        first_queued = send_and_wait(
            process, master_fd, output, b"\r", b"queued-one"
        )
        send_and_wait(
            process, master_fd, output, b"queued-two", composer_showing(b"queued-two")
        )
        second_queued = send_and_wait(
            process, master_fd, output, b"\r", b"queued-two"
        )

        # The whole screen, not the frame that carried the second queue row.
        # A frame holds the rows that changed, and the sent line's own row was
        # drawn before either line was queued -- asking one frame for it fails
        # on a screen that has it. second_queued is still the wait that says
        # the second row arrived.
        _ = second_queued
        plain = CSI_RE.sub(b"", screen_text(bytes(output)))
        # Pending messages are visible but not represented as turns the model
        # has already received.
        #
        # The gap between the caret and YOU is column padding, and it has
        # changed width. Matching the pair rather than one spelling of the gap
        # asks what this step is about -- the row is marked as a user turn --
        # without pinning a layout that is free to move.
        turn_user = re.compile("▶\\s+YOU".encode())
        if turn_user.search(plain) is None:
            raise AssertionError(
                f"the sent line is not marked as a user turn: {plain!r}"
            )
        # No needle for the promoted USER row's wording here: this scenario's
        # line is a direct submission, so it renders through the settled-row
        # layout path and the promoted block (which says "sent · the running
        # turn answers it") never draws. Covering that wording needs a
        # scenario that holds the drained turn open with a second gate
        # (task-1517); asserting it here failed on a screen that could not
        # contain it.
        for expected in (
            b"NEXT 1",
            b"queued-one",
            b"NEXT 2",
            b"queued-two",
        ):
            if expected not in plain:
                raise AssertionError(
                    f"a waiting line is not shown in NEXT; "
                    f"missing {expected!r}: {plain!r}"
                )
        # D3: a waiting row names what it waits behind. Both lines queue
        # while this Keeper's turn is still running, so each row carries the
        # running-turn reason -- "pending" alone cannot say whether the wait
        # is behind the turn or behind another line. The queue may coalesce
        # into one NEXT row holding both lines, so the reason is asked of
        # the rows that are there, not of two separate rows.
        if b"behind this Keeper's running turn" not in plain:
            raise AssertionError(
                f"a waiting row does not name what it waits behind: {plain!r}"
            )
        if b"TURN \xc2\xb7 QUEUED" in plain:
            raise AssertionError(f"pending input leaked into the transcript: {plain!r}")
        if turn_user.search(plain).start() > plain.find(b"NEXT 1"):
            raise AssertionError(f"NEXT was drawn inside the causal transcript: {plain!r}")
        if b"Enter:queue(2)" not in plain:
            raise AssertionError(f"the footer lost its count: {plain!r}")

        # NEXT owns fixed rows below history, and the budget hands those rows
        # to active USER entries as they dispatch. The footer remains fixed.
        footer_with_queue = frame_row_of(second_queued, b"  Enter:")
        if footer_with_queue != footer_while_sending:
            raise AssertionError(
                "the pane lost rows to the queue: the footer was on row "
                f"{footer_while_sending} while sending and on row "
                f"{footer_with_queue} with two lines waiting"
            )
        first_plain = CSI_RE.sub(b"", frame_containing(first_queued, b"queued-one"))
        if b"NEXT 1" not in first_plain:
            raise AssertionError(
                f"the first waiting line is not in NEXT: {first_plain!r}"
            )

        # The newest thing the operator typed is the first thing the arrows
        # hand back, whether or not it has been dispatched.
        send_and_wait(
            process, master_fd, output, b"\x1b[A", composer_showing(b"queued-two")
        )
        send_and_wait(
            process, master_fd, output, b"\x1b[A", composer_showing(b"queued-one")
        )

        # Standing on a waiting line makes the next Enter a replacement rather
        # than a second copy, and the footer has to say which one it is: the
        # composer looks identical either way.
        wait_for_output(
            process, master_fd, output, b"Enter:replace", start=0, timeout=5.0
        )
        # Edit it and send. The queue keeps two lines, not three -- the
        # original leaves as the replacement arrives. Before this, the queue
        # still held the original and the composer queued a copy, so the same
        # message went out twice.
        send_and_wait(
            process,
            master_fd,
            output,
            b"-fixed",
            composer_showing(b"queued-one-fixed"),
        )
        replaced = send_and_wait(
            process, master_fd, output, b"\r", b"queued-one-fixed"
        )
        replaced_plain = CSI_RE.sub(b"", frame_containing(replaced, b"queued-one-fixed"))
        if not any(
            marker in replaced_plain
            for marker in (b"Enter:queue(2)", b"2 waiting")
        ):
            raise AssertionError(
                f"the edit did not replace the queued line; the queue should "
                f"still hold two: {replaced_plain!r}"
            )

        # Let the turn settle and the queue drain into it. Until it does, Esc
        # means "interrupt the turn" and q is just a letter in the composer.
        # The Enter above already emptied the composer, so there is nothing to
        # clear -- and nothing would redraw for a Ctrl-U that changed nothing.
        gate.release.set()
        read_available(master_fd, output)
        wait_for_output(
            process,
            master_fd,
            output,
            b"Enter:send",
            start=0,
            timeout=10.0,
        )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def chat_steer_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    fixtures, gate = chat_queue_http_fixtures()

    def interrupt_response(request_body: bytes) -> HttpResponse:
        request_id = json.loads(request_body).get("request_id")
        return 200, {
            "signalled": True,
            "request_id": request_id,
        }

    fixtures["/api/v1/keepers/turn/interrupt"] = RequestHttpResponse(
        interrupt_response
    )
    return fixtures, gate


def chat_steer_interaction(
    gate: GatedHttpResponse, requests: HttpRequests
) -> Interaction:
    """/steer is visibly distinct and dispatches before ordinary NEXT."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Keepers \xe2\x96\xb8 \x1b[1malpha",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"original",
            composer_showing(b"original"),
        )
        send_and_wait(process, master_fd, output, b"\r", b"IN PROGRESS")

        send_and_wait(
            process,
            master_fd,
            output,
            b"ordinary-next",
            composer_showing(b"ordinary-next"),
        )
        send_and_wait(process, master_fd, output, b"\r", b"NEXT 1")
        steer = b"/steer corrected-course"
        send_and_wait(
            process, master_fd, output, steer, composer_showing(steer)
        )
        send_and_wait(process, master_fd, output, b"\r", b"STEER 1")
        # Read the screen, not the frame the steer arrived in. Queueing the
        # steer renumbers the ordinary entry's header row -- NEXT 1 becomes
        # NEXT 2 -- but leaves its body row alone, and a frame carries only
        # the rows that changed. So the frame holds three of these four
        # strings and the fourth has been sitting on screen since it was
        # queued.
        plain = screen_text(bytes(output))
        expected_rows = (
            b"STEER 1",
            b"corrected-course",
            b"NEXT 2",
            b"ordinary-next",
        )
        for expected in expected_rows:
            if expected not in plain:
                raise AssertionError(
                    f"steer/next lanes are incomplete: {plain!r}"
                )
        if plain.find(b"STEER 1") > plain.find(b"NEXT 2"):
            raise AssertionError(
                f"steer does not precede ordinary NEXT: {plain!r}"
            )

        deadline = time.monotonic() + 5.0
        while not any(
            path == "/api/v1/keepers/turn/interrupt"
            for path, _body in requests
        ):
            read_available(master_fd, output)
            if time.monotonic() >= deadline:
                raise AssertionError(
                    "/steer did not signal the current turn"
                )
            time.sleep(0.02)

        gate.release.set()
        deadline = time.monotonic() + 10.0
        while True:
            read_available(master_fd, output)
            chat_bodies = [
                body
                for path, body in requests
                if path == "/api/v1/keepers/chat/stream"
            ]
            if len(chat_bodies) >= 3:
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    "steer queue did not drain three chat requests: "
                    f"{requests!r}"
                )
            time.sleep(0.02)
        messages = [
            json.loads(body).get("message") for body in chat_bodies[:3]
        ]
        expected_messages = [
            "original",
            "corrected-course",
            "ordinary-next",
        ]
        if messages != expected_messages:
            raise AssertionError(
                f"steer dispatch order is not causal: {messages!r}"
            )
        interrupt_bodies = [
            json.loads(body)
            for path, body in requests
            if path == "/api/v1/keepers/turn/interrupt"
        ]
        original_request_id = json.loads(chat_bodies[0]).get("request_id")
        if not interrupt_bodies or interrupt_bodies[0].get("request_id") != original_request_id:
            raise AssertionError(
                "steer interrupt was not bound to the exact original request: "
                f"original={original_request_id!r} interrupts={interrupt_bodies!r}"
            )

        wait_for_output(
            process,
            master_fd,
            output,
            b"Enter:send",
            start=0,
            timeout=10.0,
        )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(
            process, master_fd, output, b"\x1b", b"MASC Keepers"
        )
        os.write(master_fd, b"q")

    return interact


def chat_reconcile_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    gate = GatedHttpResponse((200, {}), hold_seconds=30.0)
    calls = 0
    lock = threading.Lock()

    def response(request_body: bytes) -> HttpResponse | RawHttpResponse:
        nonlocal calls
        with lock:
            call_index = calls
            calls += 1
        if call_index == 0:
            return 503, {"error": "first stream outcome is unknown"}
        if call_index == 1:
            gate.requested.set()
            try:
                if not gate.release.wait(timeout=gate.hold_seconds):
                    return 504, {"error": "reconciliation gate timed out"}
            finally:
                gate.completed.set()
        return keeper_chat_succeeded_response(request_body)

    return {
        "/api/v1/keepers/chat/stream": RequestHttpResponse(response)
    }, gate


def chat_reconcile_interaction(
    gate: GatedHttpResponse, requests: HttpRequests
) -> Interaction:
    """An unknown stream outcome keeps NEXT held until exact re-subscribe ends."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Keepers \xe2\x96\xb8 \x1b[1malpha",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        send_and_wait(
            process, master_fd, output, b"uncertain", composer_showing(b"uncertain")
        )
        # The first connection fails before any RUN_STARTED. Its replacement
        # is intentionally withheld: assert reconciliation, not a running turn.
        send_and_wait(process, master_fd, output, b"\r", b"reconciling")
        if not wait_for_fixture_event(
            process,
            master_fd,
            output,
            gate.requested,
            timeout=5.0,
        ):
            raise AssertionError("exact Keeper chat re-subscribe did not start")
        send_and_wait(
            process, master_fd, output, b"held-next", composer_showing(b"held-next")
        )
        held = send_and_wait(process, master_fd, output, b"\r", b"NEXT 1")
        # The reconciliation line is a STATUS row the pane drew when the
        # subscribe was lost, frames before this one. A frame carries the rows
        # that changed, so asking the queueing frame for it fails on a screen
        # that shows it.
        _ = held
        held_plain = CSI_RE.sub(b"", screen_text(bytes(output)))
        if b"reconciling" not in held_plain:
            raise AssertionError(
                f"unknown outcome did not expose reconciliation state: {held_plain!r}"
            )
        if any(
            json.loads(body).get("message") == "held-next"
            for path, body in requests
            if path == "/api/v1/keepers/chat/stream"
        ):
            raise AssertionError("NEXT dispatched before terminal reconciliation")

        gate.release.set()
        deadline = time.monotonic() + 10.0
        while True:
            read_available(master_fd, output)
            bodies = [
                body
                for path, body in requests
                if path == "/api/v1/keepers/chat/stream"
            ]
            messages = [json.loads(body).get("message") for body in bodies]
            if messages.count("uncertain") >= 2 and "held-next" in messages:
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"terminal reconciliation did not release NEXT: {messages!r}"
                )
            time.sleep(0.02)
        wait_for_output(
            process,
            master_fd,
            output,
            b"Enter:send",
            start=0,
            timeout=10.0,
        )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(
            process, master_fd, output, b"\x1b", b"MASC Keepers"
        )
        os.write(master_fd, b"q")

    return interact

def utf8_message_interaction(requests: HttpRequests) -> Interaction:
    expected_text = "Aé한🙂"
    expected_bytes = expected_text.encode()

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        ascii_frame = send_and_wait(process, master_fd, output, b"A", composer_showing(b"A"))
        assert_message_input_frame(
            ascii_frame,
            row=28,
            columns=100,
            input_text="A",
            cursor_column=8,
        )
        send_and_wait(process, master_fd, output, b"\x15", b"> ")

        combining_text = "e\u0301"
        combining_frame = send_and_wait(
            process,
            master_fd,
            output,
            combining_text.encode(),
            composer_showing(combining_text.encode()),
        )
        assert_message_input_frame(
            combining_frame,
            row=28,
            columns=100,
            input_text=combining_text,
            cursor_column=8,
        )
        send_and_wait(process, master_fd, output, b"\x15", b"> ")

        typed_frame = send_and_wait(
            process, master_fd, output, expected_bytes, composer_showing(expected_bytes)
        )
        typed_frame.decode("utf-8")
        assert_message_input_frame(
            typed_frame,
            row=28,
            columns=100,
            input_text=expected_text,
            cursor_column=13,
        )
        # The narrowest terminal the chat pane draws in. #33096 gated the pane
        # on Masc_tui_message_layout.chat_min_terminal_cols; below it the pane
        # draws "Keeper chat needs a larger terminal" and has no composer at
        # all, so this step waited on a composer that was never going to
        # arrive and stalled the whole lane (#34125).
        #
        # 41, not the 38 that commit's subject named: the constant is derived
        # (4 + 2 + turn_rail_cells + chat_role_label_column + 20) and the
        # derivation has grown by three since. Pinned at the floor rather than
        # comfortably above it -- at 60 this would still pass while the floor
        # moved underneath, which is how it got to 41 unnoticed.
        narrow_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=41,
            needle=composer_showing(b"A"),
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        assert_message_input_frame(
            narrow_frame,
            row=28,
            columns=41,
            input_text=expected_text,
            cursor_column=13,
        )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=100,
            needle=composer_showing(expected_bytes),
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        backspace_cases = (
            (composer_showing("Aé한".encode()), "🙂".encode()),
            (composer_showing("Aé".encode()), "한".encode()),
            (composer_showing(b"A"), "é".encode()),
        )
        for expected, removed in backspace_cases:
            frame = send_and_wait(process, master_fd, output, b"\x7f", expected)
            frame.decode("utf-8")
            if removed[:1] in frame:
                raise AssertionError(
                    f"backspace left part of UTF-8 scalar {removed!r}: {frame!r}"
                )

        send_and_wait(process, master_fd, output, b"\xe2x", composer_showing(b"Ax"))
        send_and_wait(process, master_fd, output, b"\x7f", composer_showing(b"A"))
        send_and_wait(process, master_fd, output, b"\xe2\x15", b"> ")
        send_and_wait(process, master_fd, output, b"A", composer_showing(b"A"))
        os.write(master_fd, b"\xe2")
        wait_for_terminal_input_consumed(slave_fd)
        time.sleep(0.08)
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=29,
            columns=100,
            needle=b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        send_and_wait(process, master_fd, output, b"y", composer_showing(b"Ay"))

        send_and_wait(process, master_fd, output, b"\x15", b"> ")
        send_and_wait(
            process, master_fd, output, expected_bytes, composer_showing(expected_bytes)
        )
        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        payload = json.loads(body)
        if payload.get("message") != expected_text:
            raise AssertionError(f"Keeper chat changed UTF-8 message bytes: {body!r}")

        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


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


def memory_facts_http_fixtures() -> HttpFixtures:
    """The Memory surface's health table plus one keeper's fact listing."""
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/dashboard/keeper-memory-health"] = (
        200,
        {
            "schema": "keeper.memory_os.current_health.v4",
            "generated_at": 1787348000.0,
            "cadence_counter_entries": 0,
            "keepers": [
                {
                    "keeper_id": "alpha",
                    "revision": 7,
                    "facts": 2,
                    "observed_facts": 2,
                    "derived_facts": 0,
                    "support_invalidations": 0,
                    "snapshot_bytes": 512,
                    "added": 1,
                    "removed": 0,
                    "snapshot_present": True,
                    "updated_at": 1700000000.0,
                    "librarian_lane_busy": 0,
                    "librarian_failures": 0,
                    "vision_ingest_errors": 0,
                    "vision_ingest_error_reasons": [],
                    "read_error": None,
                    "source_revision": 2,
                    "source_facts": 1,
                    "source_invalidations": 1,
                    "source_snapshot_bytes": 128,
                    "source_snapshot_present": True,
                    "source_read_error": None,
                    "alerts": [],
                }
            ],
            "totals": {
                "facts": 2,
                "observed_facts": 2,
                "derived_facts": 0,
                "support_invalidations": 0,
                "snapshot_bytes": 512,
                "added": 1,
                "removed": 0,
                "source_facts": 1,
                "source_invalidations": 1,
                "source_snapshot_bytes": 128,
                "librarian_lane_busy": 0,
                "librarian_failures": 0,
                "vision_ingest_errors": 0,
                "read_errors": 0,
                "source_read_errors": 0,
            },
            "alert_summary": {
                "total_alerts": 0,
                "warn_alerts": 0,
                "error_alerts": 0,
                "keepers_with_alerts": 0,
                "snapshot_read_error_keepers": 0,
                "source_snapshot_read_error_keepers": 0,
                "librarian_lane_busy_keepers": 0,
                "librarian_starving_keepers": 0,
            },
        },
    )
    fixtures["/api/v1/keepers/alpha/memory-facts"] = (
        200,
        {
            "keeper": "alpha",
            "dashboard_surface": "/api/v1/keepers/:name/memory-facts",
            "ordinary": {
                "present": True,
                "revision": 7,
                "updated_at": 1787348000.0,
                "facts": [
                    {
                        "claim": "the deploy needs assets",
                        "category": "lesson",
                        "origin": "authored",
                        "first_seen": 1787340000.0,
                        "last_seen": 1787347000.0,
                        "memory_id": "mem-1",
                        "events": {
                            "retrieved_count": 3,
                            "retrieved_distinct_days": 2,
                            "last_retrieved_at": 1787347500.0,
                            "cited_count": 0,
                            "revised_from": [],
                        },
                    },
                    {
                        "claim": "port 8935 is already claimed",
                        "category": "blocker",
                        "origin": "injected",
                        "first_seen": 1787341000.0,
                        "last_seen": 1787346000.0,
                        "memory_id": "mem-2",
                        "events": {
                            "retrieved_count": 0,
                            "retrieved_distinct_days": 0,
                            "last_retrieved_at": None,
                            "cited_count": 0,
                            "revised_from": [],
                        },
                    },
                ],
            },
            "source_bound": {
                "present": True,
                "revision": 2,
                "updated_at": 1787348000.0,
                "facts": [
                    {
                        "claim": "the config floor is masc.core",
                        "first_seen": 1787342000.0,
                        "path": "docs/config.md",
                        "sha256": "cafe0123beef4567cafe0123beef4567",
                    }
                ],
                "invalidations": [
                    {
                        "source_path": "docs/old.md",
                        "invalidated_at": 1787347500.0,
                        "reason": "source_changed",
                    }
                ],
            },
        },
    )
    return fixtures


def memory_facts_interaction() -> Interaction:
    """Enter on a Memory health row opens the fact browser: the rows carry
    the server's category and origin spellings, c cycles the filter through
    the loaded categories, and Esc returns to the health table."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Memory")
        # Enter is a no-op until the health snapshot lands. The fixture has
        # two ordinary facts and one source fact, shown in the overview total.
        wait_for_output(
            process, master_fd, output, b"Total 3 facts",
            start=0, timeout=5.0,
        )
        # The title is bold up to the reset, so needles start after it:
        # "<bold> MASC Memory<reset> ▸ alpha (...)".
        send_and_wait(
            process, master_fd, output, b"\r",
            b"\xe2\x96\xb8 alpha",
        )
        # The listing arrives async after the browser opens.
        wait_for_output(
            process, master_fd, output,
            b"the deploy needs assets",
            start=0, timeout=5.0,
        )
        # Badges use uppercase display labels. At this height the selected
        # dropped row is visible; the source row is below the initial window.
        for needle in (
            b"[DROPPED   ]",
            b"docs/old.md",
            b"source_changed",
            b"(2 ord \xc2\xb7 1 src \xc2\xb7 1 drop)",
        ):
            wait_for_output(
                process, master_fd, output, needle, start=0, timeout=5.0
            )
        # Recency sorting opens on the dropped row, so its detail shows first;
        # one step down lands on an ordinary fact and its origin line.
        send_and_wait(process, master_fd, output, b"j", b"Origin:")
        wait_for_output(
            process, master_fd, output, b"authored", start=0, timeout=5.0
        )
        # Visit every category through its filter so each row is visible even
        # when the selected detail panel leaves a short list viewport.
        for category, badge, text in (
            (b"blocker", b"[BLOCKER   ]", b"port 8935 is already claimed"),
            (b"lesson", b"[LESSON    ]", b"the deploy needs assets"),
            (b"source", b"[SOURCE    ]", b"docs/config.md"),
            (b"dropped", b"[DROPPED   ]", b"docs/old.md"),
        ):
            filtered = send_and_wait(
                process, master_fd, output, b"c", b"\xe2\x97\x8f " + category
            )
            plain = CSI_RE.sub(b"", filtered)
            for expected in (badge, text):
                if expected not in plain:
                    raise AssertionError(
                        f"Memory {category!r} filter omitted {expected!r}: {plain!r}"
                    )
        # The fact browser says Total: with a colon; the overview has this
        # fleet total, so it also proves Esc returned to the health table.
        send_and_wait(process, master_fd, output, b"\x1b", b"Total 3 facts")
        os.write(master_fd, b"q")

    return interact


def memory_journal_fixture() -> HttpResponse:
    return (
        200,
        {
            "keeper": "alpha",
            "returned": 1,
            "undecodable_lines": 0,
            "entries": [
                {
                    "ok": True,
                    "outcome": "committed",
                    "recorded_at": 1788273295.122265,
                    "revision": 9,
                    "source": {"kind": "librarian", "trace_id": "trace-memory"},
                    "change": {
                        "added": [
                            {
                                "category": "fact",
                                "claim": "the Runtime probe shares one provider endpoint",
                            }
                        ],
                        "removed": [
                            {
                                "category": "constraint",
                                "claim": "probe every model separately",
                            }
                        ],
                        "retained": 3,
                    },
                    "dropped": [
                        {
                            "memory_id": "memory-old-probe-rule",
                            "reason": "superseded by provider grouping",
                        }
                    ],
                }
            ],
        },
    )


def memory_journal_backfill_fixture() -> HttpResponse:
    status, payload = memory_journal_fixture()
    entries = payload["entries"]
    if not isinstance(entries, list):
        raise AssertionError("memory journal fixture entries are not a list")
    entries.insert(
        0,
        {
            "ok": True,
            "outcome": "failed",
            "recorded_at": 1788273280.0,
            "trace_id": "trace-backfilled-probe",
            "kind": "backfilled_probe",
            "detail": "older Journal observation",
            "snapshot_present": True,
            "cadence_deferred": False,
        },
    )
    payload["returned"] = 2
    return status, payload


MEMORY_JOURNAL_REQUEST_TS = 1788273291.814646

# The scenario runs a 30-row terminal and the chat pane is shorter than that,
# so this many one-line messages make a transcript taller than the pane. Page-up
# then has something to read back: without them the pane clamps the scroll to
# nothing, says "back at the newest row", and the scroll-pin claim below has
# nothing to measure (#33757).
MEMORY_JOURNAL_FILLER_ROWS = 30

# The filler sits an hour before the turn under test so that turn's own
# civil-hour rail is drawn directly above it and stays on screen with it.
# Filler in the same hour would put that rail at the top of the transcript,
# where the pane's newest window no longer reaches it.
SECONDS_PER_HOUR = 3600.0
MEMORY_JOURNAL_OLDEST_TS = (
    MEMORY_JOURNAL_REQUEST_TS - SECONDS_PER_HOUR - float(MEMORY_JOURNAL_FILLER_ROWS)
)


def memory_journal_filler_rows() -> list[dict[str, object]]:
    """Older conversation, oldest first, one second apart."""
    return [
        {
            "id": f"assistant:filler-{index}",
            "role": "assistant",
            "content": f"older conversation row {index}",
            "ts": MEMORY_JOURNAL_OLDEST_TS + float(index),
            "turn_ref": f"trace-filler#{index}",
            "transcript_slot": {"kind": "terminal_assistant"},
        }
        for index in range(MEMORY_JOURNAL_FILLER_ROWS)
    ]


def memory_journal_chat_fixture() -> HttpResponse:
    # Both conversation rows belong to one direct turn, while the Journal
    # observation lands between their clocks. Keeping the turn physically
    # whole produced the live 23:35:06 -> 23:34:55 regression: causal identity
    # may label the rows, but the shared visible axis must remain monotonic.
    return (
        200,
        memory_journal_filler_rows()
        + [
            {
                "id": "user:before-journal",
                "role": "user",
                "content": "direct turn before Librarian",
                "ts": MEMORY_JOURNAL_REQUEST_TS,
                "delivery_key": {
                    "kind": "operation",
                    "operation_id": "tui-direct-regression",
                },
                "transcript_slot": {"kind": "accepted_user"},
                "speaker_authority": "owner",
                "surface": {"kind": "dashboard"},
            },
            {
                "id": "assistant:after-journal",
                "role": "assistant",
                "content": "direct turn after Librarian",
                "ts": 1788273306.661051,
                "turn_ref": "trace-direct#54",
                "delivery_key": {
                    "kind": "operation",
                    "operation_id": "tui-direct-regression",
                },
                "transcript_slot": {"kind": "terminal_assistant"},
            },
        ],
    )


def autonomous_turn_history_interaction() -> Interaction:
    """The chat pane draws what an autonomous turn did, not a blank line."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        pane_start = len(output)
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        # The transcript is fetched on a background fiber once the pane opens,
        # so the rows land in a later frame than the header.
        wait_for_output(
            process,
            master_fd,
            output,
            b"masc_task_history",
            start=pane_start,
            timeout=5.0,
        )
        # Two calls, each with its own detail rows, do not fit the runner's
        # default 30 rows: the block reaches the first call's identity line
        # and the second is below the fold, so this read used to miss it and
        # report a name that was on screen a few rows further down.
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=60,
            columns=100,
            needle=b"masc_task_history",
            controls=(FULL_REDRAW,),
        )
        pane = bytes(output[pane_start:])
        plain_pane = CSI_RE.sub(b"", pane)
        for needle, what in (
            # Not "content withheld" any more. That wording read as someone
            # holding the text back and sent readers looking for a way to see
            # it; there is none, and the count is the whole fact. The renderer
            # says so in its own words at masc_tui_keeper_chat_history.ml.
            ("2 reasoning steps \u00b7 text not recorded".encode(),
             "the unrecorded reasoning count"),
            ("\u2713 masc_task_history \u00b7 32ms".encode(), "the returned call"),
            ("\u2717 tool_execute \u00b7 1200ms".encode(), "the failed call"),
            ("\u00b7 THINKING".encode(), "the thinking lane"),
            # The label is padded to its column now, so "TOOLS" no longer sits
            # against the rule. The block marker in front of it is what tells
            # this row from the word appearing anywhere else.
            ("\u25a0 TOOLS".encode(), "the tool block header"),
        ):
            if needle not in plain_pane:
                raise AssertionError(
                    f"Autonomous turn history did not draw {what}: {pane!r}"
                )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def memory_journal_timeline_interaction(
    memory: SequencedHttpResponse,
) -> Interaction:
    def assert_monotonic_direct_turn(drawn: bytes) -> None:
        """Every claim here is about the screen, so it reads the screen.

        The pane resends only the rows that changed, so the frame that
        expands the Journal entry does not carry the request row above it or
        the hour rail above that -- both were written once, when they first
        appeared, and nothing has changed them since."""
        rows = screen_rows(drawn)
        plain = screen_text(drawn)
        hour = time.strftime(
            "%Y-%m-%d · %H:00", time.localtime(MEMORY_JOURNAL_REQUEST_TS)
        ).encode()
        styled_rail = re.compile(
            rb"\x1b\[[0-9;]*m\x1b\[1m"
            + "── ".encode()
            + re.escape(hour)
        )
        if styled_rail.search(drawn) is None:
            raise AssertionError(
                "Civil-hour rail was not drawn in semantic colour and bold "
                f"weight for {hour!r}: {drawn!r}"
            )
        # The renderer groups by civil hour (checked above) and does not
        # also draw a per-message HH:MM:SS clock in the resting chat body
        # (no such formatting exists in bin/masc_tui_render.ml). The three
        # exact-second clock checks below are a fossil from a design that
        # predates hour-grouping; only content ordering still applies.
        ordered = (
            hour,
            b"direct turn before Librarian",
            b"Librarian committed current memory revision 9",
            b"direct turn after Librarian",
        )
        positions = [screen_row_of(rows, needle) for needle in ordered]
        if any(position < 0 for position in positions) or positions != sorted(
            positions
        ):
            raise AssertionError(
                "The direct-turn request, Journal entry, and reply did not "
                f"share one monotonic axis: {dict(zip(ordered, positions))!r}"
            )
        for pattern, label in (
            (re.compile("▶\\s+YOU".encode()), "direct turn start"),
            (re.compile("●\\s+alpha".encode()), "post-Journal continuation"),
        ):
            if find_needle(plain, pattern) < 0:
                raise AssertionError(f"Missing {label} label: {plain!r}")
        # Speaker labels are dim-styled, not reverse-video, in the current
        # renderer (observed: b"\\x1b[2mYOU" / b"\\x1b[2malpha"). The colored
        # bold arrow/circle glyph checked above is what actually marks the
        # causal role; this only confirms the label itself still renders.
        for label in (b"YOU", b"alpha"):
            if b"\x1b[2m" + label not in drawn:
                raise AssertionError(
                    f"Direct causal label lost its dim-styled badge {label!r}: "
                    f"{drawn!r}"
                )

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        start = len(output)
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        # This scenario verifies the complete timestamp axis. Chat itself now
        # rests in the clock-free reading layout, so opt into full metadata.
        #
        # One press, not two. The header names only the two densities away
        # from the resting one: Origin_bare draws "metadata:off", Origin_row
        # draws "metadata:full", and Origin_inline -- the default this pane
        # opens in -- draws nothing, because a label saying you are where you
        # started is not news. So "metadata:inline" is not a string this
        # header can produce, and waiting for it starved.
        send_and_wait(process, master_fd, output, b"\x06", b"metadata:full")
        # At rest the journal draws only its one-line summary: the header
        # with source, revision, and counts. The change fence under it is a
        # keypress away.
        wait_for_output(
            process,
            master_fd,
            output,
            b"Librarian committed current memory revision 9",
            start=start,
            timeout=5.0,
        )
        last_row_end = output.find(
            b"Librarian committed current memory revision 9", start
        ) + len(b"Librarian committed current memory revision 9")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=last_row_end,
            timeout=3.0,
        )
        frame_end = output.find(FRAME_END, last_row_end) + len(FRAME_END)
        resting = frame_containing(
            bytes(output[start:frame_end]),
            b"Librarian committed current memory revision 9",
        )
        plain_resting = CSI_RE.sub(b"", resting)
        assert_monotonic_direct_turn(bytes(output))
        if b"\xc2\xb7 Ctrl-N" not in plain_resting:
            raise AssertionError(
                f"Journal summary did not expose its detail key: {resting!r}"
            )
        # What the key does is the footer's line, which is on screen with
        # this row; saying it again per row is what the row stopped doing.
        if b"Ctrl-N: journal detail" in plain_resting:
            raise AssertionError(
                f"Journal summary spelled the footer's own words: {resting!r}"
            )
        if re.search("\u25c8\\s+JOURNAL".encode(), plain_resting) is None:
            raise AssertionError(
                f"Memory timeline did not draw its distinct Journal marker: {resting!r}"
            )
        if "\u250a".encode() not in plain_resting:
            raise AssertionError(
                f"Memory timeline did not draw its parallel dotted rail: {resting!r}"
            )
        for fence_only in (
            b"one provider endpoint",
            b"superseded by provider grouping",
        ):
            if fence_only in resting:
                raise AssertionError(
                    f"Summary mode drew the change fence {fence_only!r}: {resting!r}"
                )

        # /memory steps the lane from summary to full, where the change
        # fence draws in whole.
        send_and_wait(process, master_fd, output, b"/memory", composer_showing(b"/memory"))
        full_start = len(output)
        send_and_wait(process, master_fd, output, b"\r", b"journal:full")
        wait_for_output(
            process,
            master_fd,
            output,
            b"superseded by provider grouping",
            start=full_start,
            timeout=5.0,
        )
        last_row_end = output.find(
            b"superseded by provider grouping", full_start
        ) + len(b"superseded by provider grouping")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=last_row_end,
            timeout=3.0,
        )
        frame_end = output.find(FRAME_END, last_row_end) + len(FRAME_END)
        visible = frame_containing(
            bytes(output[full_start:frame_end]),
            b"superseded by provider grouping",
        )
        plain_visible = CSI_RE.sub(b"", visible)
        assert_monotonic_direct_turn(bytes(output))
        # Read off the screen, not this frame: expanding the entry rewrote
        # the rows under its header, and the header itself did not change,
        # so the pane had no reason to send it again.
        if re.search("◈\\s+JOURNAL".encode(), screen_text(bytes(output))) is None:
            raise AssertionError(
                "Memory timeline did not draw its distinct Journal marker: "
                f"{screen_text(bytes(output))!r}"
            )
        if "\u250a".encode() not in plain_visible:
            raise AssertionError(
                f"Memory timeline did not draw its parallel dotted rail: {visible!r}"
            )
        # The kind tag carries its own colour, so SGR lands between the
        # bracket, the word inside it, and the text after it. A flat byte
        # needle spanning that boundary cannot match a coloured tag -- the two
        # below were written while the tag was drawn in the body's colour.
        tag = rb"(?:\x1b\[[0-9;]*m)*"
        for needle in (
            re.compile(
                rb"\[" + tag + rb"fact" + tag + rb"\]" + tag
                + rb" the Runtime probe shares"
            ),
            b"one provider endpoint",
            re.compile(rb"\[" + tag + rb"constraint" + tag + rb"\]" + tag + rb" probe"),
            b"every model separately",
            b"drop memory-old-probe-rule",
            b"superseded by provider grouping",
        ):
            if find_needle(visible, needle) < 0:
                raise AssertionError(f"Memory timeline did not draw {needle!r}: {visible!r}")

        # The changed facts ride a ```diff fence, which is what colours the two
        # directions and keeps a leading + out of markdown's list grammar. The
        # renderer used to escape that + instead, and nothing consumed the
        # escape, so every changed fact reached the pane behind a literal
        # backslash. Asserted on the drawn bytes because that is where it
        # showed: the decoder was honest the whole time.
        for escaped in (b"\\+ ", b"\\- "):
            if escaped in visible:
                raise AssertionError(
                    f"Memory timeline drew an unconsumed escape {escaped!r}: {visible!r}"
                )

        # A wheel notch reads back, and it is the shallow way to do it: a
        # page would carry the pinned row below off the newest window, and
        # this block is about where that row sits, not about how far the
        # pane can travel. A single row per press was the arrow key's old
        # behaviour and is gone.
        #
        # The status row names its row count only while an older page
        # exists, so the needle is the part that marks reading back in
        # either wording.
        reading_back = b"Ctrl-E returns to the newest"
        # The producer's older journal rows have to land before the pane is
        # read back, because a pane that is read back does not ask for them:
        # the tick reloads the transcript only at the newest row, and the
        # journal comes down that same load (bin/masc_tui.ml, the msg_scroll
        # guard on launch_keeper_history_load). What the pin below is about
        # is where the row sits once they are in.
        memory.responses.append(memory_journal_backfill_fixture())
        served_before_backfill = memory.served
        wait_for_fixture_served(
            process,
            master_fd,
            output,
            memory,
            after=served_before_backfill,
            description="Journal producer backfill",
            timeout=5.0,
        )
        drain_until_quiet(process, master_fd, output)
        scrolled = send_and_wait(
            process, master_fd, output, b"\x1b[<64;5;5M", reading_back
        )
        scrolled_frame = frame_containing(scrolled, reading_back)
        anchor = b"Librarian committed current memory revision 9"
        if anchor not in CSI_RE.sub(b"", scrolled_frame):
            raise AssertionError(
                f"Scroll setup did not keep the intended Journal anchor: {scrolled_frame!r}"
            )
        anchor_row_before = frame_row_of(scrolled_frame, anchor)
        status_row_before = frame_row_of(scrolled_frame, reading_back)
        anchor_offset_before = anchor_row_before - status_row_before
        refreshed_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=100,
            needle=reading_back,
            controls=(FULL_REDRAW,),
        )
        if anchor not in CSI_RE.sub(b"", refreshed_frame):
            raise AssertionError(
                "A redraw moved the pinned row out of the read-back window: "
                f"{refreshed_frame!r}"
            )
        anchor_row_after = frame_row_of(refreshed_frame, anchor)
        status_row_after = frame_row_of(refreshed_frame, reading_back)
        anchor_offset_after = anchor_row_after - status_row_after
        if anchor_offset_after != anchor_offset_before:
            raise AssertionError(
                "A redraw changed the pinned row's footer-relative slot: "
                f"before={anchor_offset_before} after={anchor_offset_after} "
                f"frame={refreshed_frame!r}"
            )
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x05",
            b"direct turn after Librarian",
        )

        # Ctrl-N walks the same cycle without the composer: full -> hidden.
        hidden = send_and_wait(process, master_fd, output, b"\x0e", b"journal:off")
        if b"Librarian committed current memory revision 9" in hidden:
            raise AssertionError(f"Hidden Memory timeline still drew its row: {hidden!r}")

        # ... and hidden -> summary, the resting default.
        restored = send_and_wait(
            process,
            master_fd,
            output,
            b"\x0e",
            b"Librarian committed current memory revision 9",
        )
        if b"journal:off" in restored:
            raise AssertionError(f"Restored Memory timeline stayed off: {restored!r}")
        if b"superseded by provider grouping" in restored:
            raise AssertionError(
                f"Summary mode drew the change fence after restore: {restored!r}"
            )

        # A chat pane too narrow for the composer still owes the display
        # toggles a working gate. Twelve columns keeps the frame painted
        # (the global compact fallback is row-driven and owns every key on
        # its screen), draws only the "needs a larger terminal" notice, and
        # makes keeper_message_input_supported false — the regime where the
        # gate decides. Ctrl-R/Ctrl-D always passed it while Ctrl-F and then
        # Ctrl-N (#32367) were swallowed, because the gate admitted keys one
        # by one instead of the display-toggle set. The toggles land on the
        # notice screen and prove themselves on the way back up.
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=12,
            needle=b"Keeper ch~",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        # FIONREAD only observes the kernel queue: the TUI can read both
        # toggles into its input buffer before dispatching either. Resizing
        # at that point invalidates the old frame and correctly suppresses
        # input until the new one is painted. Ctrl-T's emitted mouse mode
        # acknowledges dispatch after the preceding keys, even when their
        # changed header is hidden by this narrow notice. Restore tracking
        # before widening; the journal assertion below still proves Ctrl-N.
        read_available(master_fd, output)
        tracking_ack_start = len(output)
        os.write(master_fd, b"\x0e\x06\x14\x14")
        wait_for_output(
            process,
            master_fd,
            output,
            b"\x1b[?1006;1000h",
            start=tracking_ack_start,
            timeout=3.0,
        )
        try:
            widened = resize_and_wait(
                process,
                master_fd,
                output,
                rows=31,
                columns=100,
                needle=b"journal:full",
                controls=(FULL_REDRAW,),
            )
        except AssertionError:
            # The raw byte dump this would otherwise carry runs to a hundred
            # kilobytes and is cut by the CI log before it says anything. The
            # screen is the part that answers what the toggles did.
            raise AssertionError(
                "Widening back never showed journal:full. Screen:\n"
                + screen_text(bytes(output)).decode("utf8", "replace")
            ) from None
        if b"journal:full" not in CSI_RE.sub(b"", widened):
            raise AssertionError(
                "A display toggle pressed on the narrow-pane notice screen "
                f"was swallowed by the composer gate: {widened!r}"
            )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


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


def context_inspector_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process, master_fd, output, rows=50, columns=140, needle=b"MASC Overview"
        )
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        send_and_wait(
            process, master_fd, output, b"/context", composer_showing(b"/context")
        )
        composition = send_and_wait(
            process, master_fd, output, b"\r", b"HISTORY REACH"
        )
        composition_plain = CSI_RE.sub(b"", composition)
        for needle in (
            b"claude-opus-5",
            b"50.0k / 200.0k tokens",
            b"Tool schemas",
            b"User messages",
            b"Tool results",
            # The section is headed in plain words now, and the count reads
            # "of" rather than a fraction. Both are pinned: the heading says
            # which section this is, the count says what it carried.
            b"how far back this turn looked",
            b"7 of 9 atoms",
        ):
            if needle not in composition_plain:
                raise AssertionError(
                    f"Context composition omitted {needle!r}: {composition!r}"
                )

        exact_input = send_and_wait(
            process, master_fd, output, b"2", b"SELECTED INPUT"
        )
        exact_input_plain = CSI_RE.sub(b"", exact_input)
        for needle in (
            b"trace-context#42",
            b"REQUEST ITEMS",
            b"System prompt",
            b"Message \xc2\xb7 system",
            b"Message \xc2\xb7 tool",
            b"Tool schema \xc2\xb7 masc_execute",
            b"Prepared request  anthropic",
            b"RETAINED ITEM",
        ):
            if needle not in exact_input_plain:
                raise AssertionError(
                    f"Exact provider input omitted {needle!r}: {exact_input!r}"
                )

        send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            b"exact dynamic context from the turn",
        )
        exact = send_and_wait(
            process, master_fd, output, b"\r", b"exact dynamic context from the turn"
        )
        if b"SELECTED INPUT" in CSI_RE.sub(b"", exact):
            raise AssertionError(
                f"Exact item view retained the list disclosure: {exact!r}"
            )

        send_and_wait(
            process, master_fd, output, b"\x1b", b"SELECTED INPUT"
        )
        input_map = send_and_wait(
            process, master_fd, output, b"3", b"Provider request map"
        )
        input_map_plain = CSI_RE.sub(b"", input_map)
        for needle in (
            b"CONTEXT STACK",
            b"SELECTED BLOCK",
            b"EXACT TURN JOIN",
            b"VERIFIED",
            b"SERIALIZED",
        ):
            if needle not in input_map_plain:
                raise AssertionError(
                    f"Provider request map omitted {needle!r}: {input_map!r}"
                )

        narrow_map = resize_and_wait(
            process,
            master_fd,
            output,
            rows=35,
            columns=109,
            needle=b"SELECTED BLOCK",
        )
        # The whole screen, not the frame the resize returned: a frame holds
        # only the rows it wrote, and the resize repaints the map over more
        # than one. The clear it starts with makes the wait matter -- until
        # the later frames land, the evidence rows are blank rather than
        # still holding what they said at the old width.
        drain_until_quiet(process, master_fd, output)
        narrow_map_plain = screen_text(bytes(output))
        for forbidden in (b"reached the provider", b"provider accepted", b"ON WIRE"):
            if forbidden in narrow_map_plain:
                raise AssertionError(
                    f"Narrow provider map overstated pre-dispatch evidence as "
                    f"{forbidden!r}: {narrow_map!r}"
                )
        for needle in (
            b"turn prompt assembly",
            b"digest",
            b"retained text",
            b"Keeper instruction text",
        ):
            if needle not in narrow_map_plain:
                raise AssertionError(
                    f"Narrow provider map omitted selected evidence {needle!r}: "
                    f"{narrow_map!r}"
                )

        serialized_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            b"pre-dispatch serialization snapshot exists",
        )
        serialized_detail_plain = CSI_RE.sub(b"", serialized_detail)
        for needle in (b"SERIALIZED", b"turn prompt assembly", b"digest"):
            if needle not in serialized_detail_plain:
                raise AssertionError(
                    f"Narrow serialized detail omitted {needle!r}: "
                    f"{serialized_detail!r}"
                )
        send_and_wait(
            process,
            master_fd,
            output,
            b"k",
            b"Keeper instruction text",
        )

        map_exact = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Keeper instruction text",
        )
        if b"turn prompt assembly" not in CSI_RE.sub(b"", map_exact):
            raise AssertionError(f"Input map exact view lost provenance: {map_exact!r}")

        send_and_wait(process, master_fd, output, b"\x1b", b"Provider request map")
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        # The overlay is headed "MASC Cheat Sheet" now; "Slash commands" was a
        # section title it no longer carries.
        send_and_wait(process, master_fd, output, b"?", b"MASC Cheat Sheet")
        # The /context disclosure this step used to assert is not here any
        # more: the cheat sheet lists keys, and the slash commands announce
        # themselves in the composer's hint line as the word is typed
        # (Masc_tui_command.hint_spans, drawn at masc_tui_render.ml). That
        # surface has no coverage yet and wants its own scenario rather than
        # a tail on this one.
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def clipboard_paste_key_interaction() -> Interaction:
    """Ctrl-V reaches the composer at all.

    Ctrl-V is VLNEXT's default character. While IEXTEN is set the tty layer
    consumes that byte and passes the *following* one through uninterpreted, so
    the pane would see the letter after Ctrl-V and never Ctrl-V itself -- which
    is what a handler alone could not fix. The pane answering is the evidence
    the key arrived.

    What the answer says depends on the host: a machine with no clipboard
    reader installed says so, and one with a reader and no image on the
    clipboard says that instead. Both are answers. The success path needs an
    image on the running machine's clipboard, so it is not asserted here and
    stays a local check.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x16",
            re.compile(rb"Ctrl-V: |pasted \[Image #1\]"),
        )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def chat_visibility_modes_interaction(
    tool_calls_gate: GatedHttpResponse | None = None,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=180,
            needle=b"MASC Overview",
        )
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        # Keep the roster cursor on beta, then open alpha through the palette.
        # Durable call details belong to the chat target, not that unrelated
        # cursor; the old response guard discarded this successful GET.
        select_keeper_row(process, master_fd, output, b"beta")
        pane_start = len(output)
        initial = palette_go(
            process,
            master_fd,
            output,
            b"keeper alpha",
            b"ci-red-attribution",
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"anthropic.claude-opus-5",
            start=pane_start,
            timeout=5.0,
        )
        # The TOOLS lane colours each token separately and pads columns,
        # so a literal "✗ masc_fusion · 1200ms" never exists as contiguous
        # bytes. Match the tokens while tolerating SGR runs and padding
        # between them, like the [tag]constraint probe needle tolerates
        # tags between words.
        wait_for_output(
            process,
            master_fd,
            output,
            re.compile(
                re.escape("\u2717".encode())
                + rb"[\x1b\x20-\x7e]*?"
                + rb"masc_fusion"
                + rb"[\x1b\x20-\x7e]*?"
                + rb"\xc2\xb7"
                + rb"[\x1b\x20-\x7e]*?"
                + rb"1200ms"
            ),
            start=pane_start,
            timeout=5.0,
        )
        # Same TOOLS-lane token colouring: cross-check needles that span
        # word boundaries must tolerate SGR runs and padding inside them.
        for needle in (
            b"gate:auto_judge",
            "\u25c6".encode(),
            re.compile(
                rb"AUTO[\x1b\x20-\x7e]*?\xc2\xb7[\x1b\x20-\x7e]*?gate"
            ),
            # The skill row names an outcome now, not a chain of receipts.
            # "DELIVERED · USED" was the evidence path; the label says what
            # came of it, and the mark above already carries the state.
            re.compile(
                "받아서".encode() + rb"[\x1b\x20-\x7e]*?" + "씀".encode()
            ),
            re.compile(
                rb"masc_fusion[\x1b\x20-\x7e]*?\xc2\xb7[\x1b\x20-\x7e]*?observed"
            ),
        ):
            wait_for_output(
                process,
                master_fd,
                output,
                needle,
                start=pane_start,
                timeout=5.0,
            )
        initial += bytes(output[pane_start:])
        initial_frame = frame_containing(initial, b"ci-red-attribution")
        plain_initial_frame = CSI_RE.sub(b"", initial_frame)
        # frame_row_of reads the absolute row addresses, which are CSI
        # sequences -- strip them and there is no address left to read.
        # Search the raw frame; the census showed both needles contiguous
        # there, and the plain copy stays for the text assertions below.
        title_row = frame_row_of(
            initial_frame, b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat"
        )
        identity_row = frame_row_of(initial_frame, b"gate:auto_judge")
        if identity_row != title_row + 1:
            raise AssertionError(
                "chat navigation and operational identity did not occupy "
                f"adjacent dedicated rows: {initial_frame!r}"
            )
        if b"2 reasoning steps \xc2\xb7 text not recorded" in initial:
            raise AssertionError(f"hidden reasoning was still drawn: {initial!r}")
        if re.search("◆\\s+SKILL".encode(), CSI_RE.sub(b"", initial)) is None:
            raise AssertionError(
                f"the exact Skill evidence did not start its turn: {initial!r}"
            )
        if b"\x1b[1mci-red-attribution" not in initial:
            raise AssertionError(f"the Skill name was not bold: {initial!r}")

        folded = send_and_wait(
            process, master_fd, output, b"\x12", b"reasoning:folded"
        )
        # The fold marker's wording changed: the count line now reads
        # "THINKING · 2 reasoning steps · text not recorded"; the old
        # "Reasoning / N line(s) folded" labels no longer exist.
        if b"2 reasoning steps" not in folded or b"text not recorded" not in folded:
            raise AssertionError(f"folded reasoning did not draw its count: {folded!r}")

        # \x12 flips reasoning visibility and the renderer answers with a
        # diff frame: the header tag (reasoning:folded -> reasoning:full)
        # is what gets re-emitted. The THINKING count row is unchanged by
        # the flip, so it is not redrawn -- asserting its reappearance
        # here starves even though the row stays on screen.
        full = send_and_wait(
            process,
            master_fd,
            output,
            b"\x12",
            b"reasoning:full",
        )
        if b"reasoning:full" not in full:
            raise AssertionError(f"full reasoning did not flip the tag: {full!r}")

        tools_start = len(output)
        tools = send_and_wait(
            process,
            master_fd,
            output,
            b"\x04",
            b"reasoning:full tools:full",
        )
        if tool_calls_gate is not None:
            if not wait_for_fixture_event(
                process,
                master_fd,
                output,
                tool_calls_gate.requested,
                timeout=3.0,
            ):
                raise AssertionError("tool-call detail GET did not reach fixture gate")
            # A second forced open while the first GET is held must coalesce
            # into one follow-up, not advance generation and orphan both.
            # While the gate holds the GET, a further \x04 press may or may
            # not redraw the header (that redraw is timing luck, not a
            # guaranteed emission), so assert nothing about the screen here:
            # press twice and let the gate count prove the coalescing.
            os.write(master_fd, b"\x04")
            time.sleep(0.2)
            os.write(master_fd, b"\x04")
            time.sleep(0.3)
            if tool_calls_gate.calls != 1:
                raise AssertionError(
                    "same-Keeper in-flight detail refresh was duplicated: "
                    f"{tool_calls_gate.calls} GETs"
                )
            tool_calls_gate.release.set()
        # The tools pane redraw never re-emits the transcript rows above it:
        # "observed action" and the proof/turn line belong to the folded
        # world and are asserted there. The pane's own first badge is the
        # fusion row's state (FAILED) at tools_start.
        wait_for_output(
            process,
            master_fd,
            output,
            b"FAILED",
            start=tools_start,
            timeout=5.0,
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"execution=exec-fusion-1",
            start=tools_start,
            timeout=5.0,
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"provider-call=call-fusion-1",
            start=tools_start,
            timeout=5.0,
        )
        tools += bytes(output[tools_start:])
        # "batch 2"/"width 3" are colour-split per token in the pane, so
        # they are asserted as token regexes; the turn= proof row is not
        # part of the pane's redraw at all.
        for needle in (
            b"masc_fusion",
            b"state",
            b"FAILED",
            b"DEFERRED",
            b"ASYNC CONTINUATION",
            b"concurrent",
            re.compile(rb"batch[\x1b\x20-\x7e]*?2"),
            re.compile(rb"width[\x1b\x20-\x7e]*?3"),
            b"panel-input-exact",
            b"panel-output-exact",
            b"execution=exec-fusion-1",
        ):
            if find_needle(tools, needle, 0) < 0:
                raise AssertionError(
                    f"full tool view did not restore {needle!r}: {tools!r}"
                )
        if b"keeper_skill" in CSI_RE.sub(b"", tools):
            raise AssertionError(
                f"exact Skill evidence was duplicated as a generic tool: {tools!r}"
            )
        send_and_wait(process, master_fd, output, b"\x1b", keeper_row_selected(b"beta"))
        os.write(master_fd, b"q")

    return interact


def chat_clarity_http_fixtures() -> HttpFixtures:
    fixtures = context_inspector_fixtures()
    history = autonomous_turn_history_fixture()
    history_rows = history[1]
    if not isinstance(history_rows, list):
        raise AssertionError("chat clarity history fixture is not a list")
    trace = history_rows[0]["blocks"][0]["trace"]
    trace[1]["name"] = "keeper_skill"
    trace[3]["name"] = "masc_fusion"
    trace[3]["execution_id"] = "exec-fusion-1"
    history_rows[0]["skill_activations"] = {
        "schema": "masc.keeper_chat.skill_activations.v1",
        "status": "available",
        "activations": [
            {
                "identity": {
                    "source_id": "workspace",
                    "package_id": "ops",
                    "name": "ci-red-attribution",
                },
                "content_revision": "sha256:content-rev-1",
                "snapshot_revision": "sha256:snapshot-rev-1",
                "turn_ref": "trace-1787333555531-00020#54",
                "runtime_id": "anthropic.claude-opus-5",
                "skill_tool_use_id": "skill-use-1",
                "agent_core_turn": 54,
                "invocation": {"kind": "instruction"},
                "delivery": {"boundary": {"kind": "model_response"}},
                "actions": [
                    {
                        "tool_name": "masc_fusion",
                        "runtime_id": "anthropic.claude-opus-5",
                    }
                ],
                "activated_at": "2026-09-01T08:00:00Z",
            }
        ],
    }
    fixtures["/api/v1/keepers/alpha/chat/history"] = history
    fixtures["/api/v1/dashboard/gate"] = (
        200,
        {
            "approval_queue": [],
            "approval_queue_state": None,
            "hitl": {
                "gate_mode": {"mode": "auto_judge"},
                "external_gate_mode": {"mode": "manual"},
            },
            "approval_rules": None,
            "approval_rules_state": None,
        },
    )
    fixtures["/api/v1/dashboard/gate/keeper-settings"] = (
        200,
        {"modes": [], "judges": []},
    )
    fixtures["/api/v1/keepers/tool-approval-mode"] = (200, {"overrides": []})
    fixtures["/api/v1/keepers/alpha/tool-calls?limit=100"] = (
        200,
        {
            "keeper": "alpha",
            "count": 1,
            "health": "ok",
            "entries": [
                {
                    "ts": 1787348490.3,
                    "keeper": "alpha",
                    "tool": "masc_fusion",
                    "input": {"prompt": "panel-input-exact"},
                    "output": "panel-output-exact",
                    "success": False,
                    "duration_ms": 1200.0,
                    "execution_id": "exec-fusion-1",
                    "tool_use_id": "call-fusion-1",
                    "planned_index": 4,
                    "batch_index": 1,
                    "batch_size": 3,
                    "execution_mode": "concurrent",
                    "disposition": "deferred",
                    "result_bytes": 18,
                }
            ],
        },
    )
    return fixtures


def skills_usage_clarity_http_fixtures(
    *, ledgers_loaded: int = 19, unavailable: tuple[str, ...] = (), observed: bool = True
) -> HttpFixtures:
    fixtures = keeper_runtime_http_fixtures()
    fixtures["/api/v1/dashboard/tools?keeper=alpha"] = (
        200,
        {
            "tool_inventory": {"tools": [], "count": 0},
            "effective_keeper_surface": None,
            "skill_activations": None,
        },
    )
    fixtures["/api/v1/async-requests"] = (200, {"requests": []})
    fixtures["/api/v1/skills"] = (
        200,
        {
            "schema": "masc.skill-snapshot/v1",
            "state": "ready",
            "usage_coverage": {
                "ledgers_loaded": ledgers_loaded,
                "unavailable": list(unavailable),
            },
            "snapshot": {
                "snapshot_revision": "snapshot-rev1",
                "catalog_revision": "catalog-rev1",
                "config": {"kind": "unreadable"},
                "sources": [],
                "skills": [],
                "effective_skills": [],
                "shadows": [],
                "rejections": [],
            },
            "surfaces": [
                {
                    "reference": {
                        "identity": {
                            "source_id": "workspace",
                            "package_id": "pkg",
                            "name": "work-intake",
                        },
                        "content_revision": "rev1",
                    },
                    "kind": "instruction",
                    "usage": ([
                        {
                            "keeper": "alpha",
                            "invocations": 12,
                            "deliveries": 12,
                            "actions": 9,
                            "last_used_at": "2026-08-28T03:04:05Z",
                        }
                    ] if observed else []),
                    "profile": {"flow": None, "plan": {}, "context": {}},
                },
                {
                    "reference": {
                        "identity": {"source_id": "workspace", "package_id": "pkg", "name": "unobserved-skill"},
                        "content_revision": "rev2",
                    },
                    "kind": "composition",
                    "usage": [],
                    "profile": {"flow": None, "plan": {}, "context": {}},
                },
            ],
        },
    )
    return fixtures


def skills_usage_clarity_interaction(
    *, ledgers_loaded: int = 19, unavailable: tuple[str, ...] = (), observed: bool = True
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=160,
            needle=b"MASC Overview",
        )
        # Tools hangs off Config under [t] now, so the walk goes to the
        # parent stop and hops from there.
        tab_until(process, master_fd, output, b"MASC Config")
        send_and_wait(process, master_fd, output, b"t", b"MASC Tools")
        usage = send_and_wait(
            process,
            master_fd,
            output,
            b"p" * 3,
            f"{1 if observed else 0} of 2 catalog Skills observed".encode(),
        )
        rendered = CSI_RE.sub(b"", usage)
        expected = [
            f"{1 if observed else 0} of 2 catalog Skills observed; {1 if observed else 2} without retained invocation".encode(),
            b"Scope: exact Skill revisions in current Keeper sessions",
            f"Activation ledgers loaded: {ledgers_loaded}; unavailable: {len(unavailable)}".encode(),
        ]
        expected.extend(f"Unavailable: {reason}".encode() for reason in unavailable)
        if observed:
            expected.extend((b"work-intake", b"alpha 12/12/9", b"2026-08-28T03:04:05Z"))
        for needle in expected:
            if needle not in rendered:
                raise AssertionError(f"Skill usage did not show {needle!r}: {usage!r}")
        if b"never invoked" in rendered:
            raise AssertionError(f"Unknown historical usage was called never invoked: {usage!r}")
        if not observed and b"alpha 12/12/9" in rendered:
            raise AssertionError(f"Unobserved usage inherited a previous count: {usage!r}")
        os.write(master_fd, b"q")

    return interact


def run_skill_usage_coverage_regression(executable: str) -> None:
    for description, loaded, unavailable, observed in (
        ("loaded current sessions do not prove lifetime non-use", 19, (), True),
        ("partial ledger coverage preserves known usage", 1, ("bravo: metadata unavailable",), True),
        ("unavailable inventory is not global zero usage", 0, ("keeper catalog: unavailable",), False),
    ):
        run_terminal_scenario(
            executable,
            description=f"Skill usage coverage: {description}",
            interact=skills_usage_clarity_interaction(
                ledgers_loaded=loaded, unavailable=unavailable, observed=observed
            ),
            http_fixtures=skills_usage_clarity_http_fixtures(
                ledgers_loaded=loaded, unavailable=unavailable, observed=observed
            ),
        )


def run_skill_usage_coverage_error_regression(executable: str) -> None:
    for initial_error in (True, False):
        fixtures = skills_usage_clarity_http_fixtures()
        good = fixtures["/api/v1/skills"]
        if not isinstance(good, tuple):
            raise AssertionError("Skill catalog fixture must be a JSON response")
        bad_payload = dict(good[1])
        del bad_payload["usage_coverage"]
        fail_reads = threading.Event()
        if initial_error:
            fail_reads.set()
        fixtures["/api/v1/skills"] = lambda: (200, bad_payload) if fail_reads.is_set() else good

        def interact(process, master_fd, _slave_fd, output, _base_path):
            resize_and_wait(process, master_fd, output, rows=30, columns=160, needle=b"MASC Overview")
            tab_until(process, master_fd, output, b"MASC Config")
            send_and_wait(process, master_fd, output, b"t", b"MASC Tools")
            frame = send_and_wait(
                process, master_fd, output, b"p" * 3,
                b"Skill catalog read failed:" if initial_error else b"1 of 2 catalog Skills observed",
            )
            if not initial_error:
                fail_reads.set()
                frame = send_and_wait(process, master_fd, output, b"r", b"Previous catalog reading; refresh failed")
            rendered = CSI_RE.sub(b"", frame)
            if b"Skill catalog read failed:" not in rendered or b"usage_coverage" not in rendered:
                raise AssertionError(f"Coverage decode failure was hidden: {frame!r}")
            if initial_error:
                if b"unavailable (no catalog reading)" not in rendered:
                    raise AssertionError(f"First failed reading still looked like loading: {frame!r}")
            elif b"alpha 12/12/9" not in rendered:
                raise AssertionError(f"Refresh failure lost the previous known counts: {frame!r}")
            os.write(master_fd, b"q")

        run_terminal_scenario(
            executable,
            description=f"Skill usage coverage error: {'initial' if initial_error else 'refresh'}",
            interact=interact, http_fixtures=fixtures,
        )


def run_tools_request_identity_regression(executable: str) -> None:
    fixtures = skills_usage_clarity_http_fixtures()

    def inventory(keeper: str, tool: str) -> HttpResponse:
        return 200, {
            "tool_inventory": {"count": 0, "tools": []},
            "effective_keeper_surface": {
                "status": "available", "keeper_name": keeper,
                "runtime_id": "fixture.tools", "official_client_kind": "agent_core",
                "tool_delivery": {"status": "delivered"}, "native_posture": None,
                "skill_snapshot_revision": "c" * 64,
                "instruction_skills": [], "composition_skills": [], "skill_profiles": [],
                "skill_discovery_bytes": 0, "skill_eager_body_bytes": 0, "skills_left_out": [],
                "count": 1, "tools": [{"name": tool, "origin": {"kind": "descriptor"}}],
                "tool_surface_sha256": None,
            },
            "skill_activations": {"status": "no_session", "keeper_name": keeper},
        }

    alpha_late = GatedHttpResponse(inventory("alpha", "keeper_alpha_late"), hold_seconds=30.0)
    beta_refresh_error = GatedHttpResponse(
        (503, {"error": "obsolete beta refresh failure"}),
        subsequent_response=inventory("beta", "keeper_beta_newest"), hold_seconds=30.0,
    )
    fixtures["/api/v1/dashboard/tools?keeper=alpha"] = alpha_late
    fixtures["/api/v1/dashboard/tools?keeper=beta"] = inventory("beta", "keeper_beta_current")
    async_calls = 0
    async_lock = threading.Lock()
    settled = {n: threading.Event() for n in range(1, 5)}

    def async_read() -> HttpResponse:
        nonlocal async_calls
        # launch_tools_load enqueues Tools_loaded before this sequential GET.
        # This is a response-settlement barrier, not an arbitrary sleep.
        with async_lock:
            async_calls += 1
            event = settled.get(async_calls)
        if event is not None:
            event.set()
        return 200, {
            "schema": "masc.async-request-observation/v1", "status": "ready",
            "summary": {"active": 0, "runtime_owned": 0, "ownership_unknown": 0, "record_errors": 0},
            "requests": [], "record_errors": [], "startup_recovery": None,
        }

    fixtures["/api/v1/async-requests"] = async_read

    def interact(process, master_fd, _slave_fd, output, _base_path):
        def await_event(event: threading.Event, description: str) -> None:
            if not wait_for_fixture_event(process, master_fd, output, event, timeout=10.0):
                raise AssertionError(description)

        def assert_current(expected: bytes, *, columns: int) -> None:
            # The main loop handles resize, drains async_messages, then calls
            # Render_schedule.take/present_frame. Require that completed full
            # redraw, not merely an earlier frame containing the same label.
            read_available(master_fd, output)
            before_resize = len(output)
            resize_and_wait(process, master_fd, output, rows=30, columns=columns,
                            needle=expected, controls=(FULL_REDRAW,))
            redraw = output.find(FULL_REDRAW, before_resize)
            wait_for_output(process, master_fd, output, FRAME_END, start=redraw, timeout=3.0)
            screen = screen_text(bytes(output))
            for stale in (b"keeper_alpha_late", b"obsolete beta refresh failure"):
                if stale in screen:
                    raise AssertionError(f"stale Tools response replaced the current view: {screen!r}")

        try:
            resize_and_wait(process, master_fd, output, rows=30, columns=120, needle=b"MASC Overview")
            tab_until(process, master_fd, output, b"MASC Config")
            os.write(master_fd, b"t")
            await_event(alpha_late.requested, "alpha Tools request did not start")
            send_and_wait(process, master_fd, output, b"]", b"keeper_beta_current")
            await_event(settled[1], "beta Tools response did not settle")
            with async_lock:
                if async_calls != 1:
                    raise AssertionError("held alpha request settled before its fixture response")
            alpha_late.release.set()
            await_event(settled[2], "late alpha response did not settle")
            assert_current(b"keeper_beta_current", columns=119)

            fixtures["/api/v1/dashboard/tools?keeper=beta"] = beta_refresh_error
            os.write(master_fd, b"r")
            await_event(beta_refresh_error.requested, "older beta refresh did not start")
            send_and_wait(process, master_fd, output, b"r", b"keeper_beta_newest")
            await_event(settled[3], "newer beta refresh did not settle")
            with async_lock:
                if async_calls != 3:
                    raise AssertionError("held beta error settled before its fixture response")
            beta_refresh_error.release.set()
            await_event(settled[4], "obsolete same-keeper error did not settle")
            assert_current(b"keeper_beta_newest", columns=120)
            captured = bytes(output)
            end = captured.rfind(FRAME_END) + len(FRAME_END)
            redraw = captured.rfind(FULL_REDRAW, 0, end)
            start = captured.rfind(FRAME_START, 0, redraw)
            if min(start, redraw) < 0:
                raise AssertionError("Tools request identity evidence has no completed redraw")
            print("TOOLS_REQUEST_IDENTITY_PTY_EVIDENCE " + json.dumps({
                "fixture": "A slow / B fast / A late; older same-Keeper error after newer success",
                "settled_tool_responses": async_calls, "rows": 30, "columns": 120,
                "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                "encoding": "base64", "pty": base64.b64encode(captured[start:end]).decode(),
            }), flush=True)
            os.write(master_fd, b"q")
        finally:
            alpha_late.release.set()
            beta_refresh_error.release.set()

    run_terminal_scenario(executable, description="Tools responses retain requested Keeper and generation",
                          interact=interact, http_fixtures=fixtures)


def run_tools_purpose_regression(executable: str) -> None:
    fixtures = skills_usage_clarity_http_fixtures()
    # Alpha has an empty current ledger; the workspace aggregate retains
    # another Keeper's usage. The two panes must keep those scopes distinct.
    skills = fixtures["/api/v1/skills"]
    assert isinstance(skills, tuple)
    skills[1]["surfaces"][0]["usage"][0]["keeper"] = "bravo"
    suppressed = threading.Event()
    ledger_contents = {
        "workspace_key": "1" * 64, "session_id": "trace-alpha",
        "activations": [], "transition_rejections": [],
    }
    ledger_revision = hashlib.sha256(
        json.dumps(ledger_contents, separators=(",", ":")).encode()
    ).hexdigest()
    effective = {
        "status": "available", "keeper_name": "alpha", "runtime_id": "fixture.tools",
        "official_client_kind": "agent_core", "tool_delivery": {"status": "delivered"},
        "native_posture": None, "skill_snapshot_revision": "c" * 64,
        "instruction_skills": [], "composition_skills": [], "skill_profiles": [],
        "skill_discovery_bytes": 0, "skill_eager_body_bytes": 0, "skills_left_out": [],
        "count": 1, "tools": [{"name": "keeper_status", "origin": {"kind": "descriptor"}}],
        "tool_surface_sha256": None,
    }
    inventory = {
        "count": 1,
        "tools": [{
            "name": "masc_board_post", "description": "Registered fixture tool",
            "registered_schema": True, "direct_call_allowed": False,
            "doc_refs": [], "prompt_hints": [], "surfaces": [],
        }],
    }
    fixtures["/api/v1/dashboard/tools?keeper=alpha"] = lambda: (200, {
        "tool_inventory": inventory,
        "effective_keeper_surface": ({**effective, "tools": [], "count": 0,
            "tool_delivery": {"status": "suppressed", "reason": "runtime_tools_unsupported"}}
            if suppressed.is_set() else effective),
        "skill_activations": {
            "status": "available", "keeper_name": "alpha",
            "ledger": {"schema": "masc.skill-activations/v5", **ledger_contents, "revision": ledger_revision},
        },
    })
    async_payload = {
        "schema": "masc.async-request-observation/v1", "status": "ready",
        "summary": {"active": 1, "runtime_owned": 0, "ownership_unknown": 1, "record_errors": 0},
        "requests": [{"request_id": "request-unowned", "keeper_name": "alpha", "status": "queued",
                      "elapsed_sec": 2, "worker_ownership": "disk_only_ownership_unknown"}],
        "record_errors": [], "startup_recovery": None,
    }
    fixtures["/api/v1/async-requests"] = lambda: (200, async_payload)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        resize_and_wait(process, master_fd, output, rows=30, columns=120, needle=b"MASC Overview")
        tab_until(process, master_fd, output, b"MASC Config")
        send_and_wait(process, master_fd, output, b"t", b"keeper_status")

        def require(*labels: str) -> None:
            screen = screen_text(bytes(output))
            for label in labels:
                if label.encode() not in screen:
                    raise AssertionError(f"Tools pane omitted {label!r}: {screen!r}")

        require("선택 Keeper의 도구·Skill 노출 범위", "ORIGIN=도구 출처", "Runtime 도구 전달: 지원")
        if b"masc_board_post" in screen_text(bytes(output)):
            raise AssertionError("Catalog-only tool appeared on selected Keeper surface")
        send_and_wait(process, master_fd, output, b"p", b"request-unowned")
        require("워크스페이스의 비동기 요청·복구 상태", "소유 확인 안 됨", "ownership-unknown=1")
        # Broken API data must not be presented as a healthy empty broker.
        for broken in ("unknown", None, -1):
            async_payload["summary"]["active"] = broken
            send_and_wait(process, master_fd, output, b"r", "읽기 실패:".encode())
            require("active")
            if b"active=0" in screen_text(bytes(output)) or b"request-unowned" in screen_text(bytes(output)):
                raise AssertionError("Malformed counter retained a healthy summary or stale request")
            async_payload["summary"]["active"] = 1
            send_and_wait(process, master_fd, output, b"r", b"request-unowned")
        del async_payload["summary"]["runtime_owned"]
        send_and_wait(process, master_fd, output, b"r", "읽기 실패:".encode())
        require("runtime_owned")
        async_payload["summary"]["runtime_owned"] = 0
        async_payload["startup_recovery"] = {"lost": 0}
        send_and_wait(process, master_fd, output, b"r", b"finalized")
        require("읽기 실패:")
        if b"finalized=0" in screen_text(bytes(output)):
            raise AssertionError("Missing recovery counter became zero")
        captured = bytes(output)
        end = captured.rfind(FRAME_END) + len(FRAME_END)
        redraw = captured.rfind(FULL_REDRAW, 0, end)
        start = captured.rfind(FRAME_START, 0, redraw)
        if min(start, redraw) < 0:
            raise AssertionError("Async error evidence has no completed redraw")
        print("ASYNC_OBSERVATION_PTY_EVIDENCE " + json.dumps({
            "fixture": "incomplete recovery report must fail visibly", "rows": 30, "columns": 120,
            "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
            "encoding": "base64", "pty": base64.b64encode(captured[start:end]).decode(),
        }), flush=True)
        async_payload["startup_recovery"] = None
        async_payload["requests"][0]["worker_ownership"] = "new_unknown_owner"
        send_and_wait(process, master_fd, output, b"r", b"unknown worker ownership")
        require("읽기 실패:")
        async_payload["requests"][0]["worker_ownership"] = "disk_only_ownership_unknown"
        send_and_wait(process, master_fd, output, b"r", b"request-unowned")
        saved_requests = async_payload["requests"]
        async_payload["requests"] = []
        async_payload["summary"].update(active=0, ownership_unknown=0)
        send_and_wait(process, master_fd, output, b"r", b"active=0")
        if "읽기 실패:".encode() in screen_text(bytes(output)):
            raise AssertionError("Valid empty broker was rejected")
        async_payload["requests"] = saved_requests
        async_payload["summary"].update(active=1, ownership_unknown=1)
        send_and_wait(process, master_fd, output, b"r", b"request-unowned")
        send_and_wait(process, master_fd, output, b"p", b"Skill Use")
        require("현재 세션에 보존된 Skill 증거", "호출·전달·이후 행동은 별도 증거", "0 receipts", "invoked=0")
        send_and_wait(process, master_fd, output, b"p", b"bravo 12/12/9")
        require("현재 Keeper 세션들에서 읽힌 Skill revision별 사용 집계", "inv/delivered/actions=호출/전달/이후 행동",
                "1 of 2 catalog Skills observed", "Activation ledgers loaded: 19; unavailable: 0")
        send_and_wait(process, master_fd, output, b"p", b"masc_board_post")
        require("MASC 전체 등록 도구 목록", "DIRECT=직접 호출 허용", "surfaces=none은 노출 경로 없음")
        send_and_wait(process, master_fd, output, b"p", b"keeper_status")
        resize_and_wait(process, master_fd, output, rows=30, columns=90, needle=b"MASC Tools")
        require("호출 범위", "비동기 작업", "Skill 기록", "사용 집계", "전체 도구", "p:다음 탭",
                "사용 증거: Skill 기록", "Tool 호출별 입출력: Acting")
        suppressed.set()
        send_and_wait(process, master_fd, output, b"r", "Runtime 도구 전달: 미지원으로 제외".encode())
        require("Runtime 도구 전달: 미지원으로 제외", "0 tools")
        if b"keeper_status" in screen_text(bytes(output)):
            raise AssertionError("Suppressed surface retained a previously callable tool")
        captured = bytes(output)
        end = captured.rfind(FRAME_END)
        if end < 0:
            raise AssertionError("Tools evidence has no completed terminal frame")
        end += len(FRAME_END)
        redraw = captured.rfind(FULL_REDRAW, 0, end)
        start = captured.rfind(FRAME_START, 0, redraw) if redraw >= 0 else -1
        if start < 0:
            raise AssertionError("Tools evidence has no complete redraw origin")
        print("TOOLS_PURPOSE_PTY_EVIDENCE " + json.dumps({
            "fixture": "isolated tool purpose and scope", "rows": 30, "columns": 90,
            "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
            "encoding": "base64", "pty": base64.b64encode(captured[start:end]).decode(),
        }), flush=True)
        os.write(master_fd, b"q")

    run_terminal_scenario(executable, description="Tools purposes distinguish visibility, receipts and usage",
                          interact=interact, http_fixtures=fixtures)


def message_origin_history_fixture() -> HttpResponse:
    return (
        200,
        [
            {
                "id": "origin-user",
                "role": "user",
                "content": "operator-body-neutral",
                "ts": 1787348490.3,
                "speaker_name": "vincent",
                "surface": {"kind": "dashboard"},
            },
            {
                "id": "origin-keeper",
                "role": "assistant",
                "content": "keeper-body-neutral",
                "ts": 1787348491.3,
            },
        ],
    )


def viewport_gap_history_fixture() -> HttpResponse:
    return (
        200,
        [
            {
                "id": "oversized-keeper-reply",
                "role": "assistant",
                "content": "\n".join(f"line-{index:02d}" for index in range(24)),
                "ts": 1787348491.3,
            }
        ],
    )


def viewport_gap_history_page_fixture() -> HttpResponse:
    # The only stored message is already in the initial history. The server
    # answers strictly before its timestamp, so this page must be empty;
    # repeating that message fabricates an older row and moves the scroll pin.
    return (200, {"messages": [], "has_more": False, "next_before": None})


LIVE_MARKDOWN_REPLY = """@keeper-haneul-agent — 고마워요! Execute가 작동하는 세션이 있다면 정말 큰 도움이 됩니다.

## 정확한 5개 git 명령 (task478 worktree에서 실행):

```bash
cd <task478 worktree path>   # 저도 경로를 잃어버렸습니다 — branch: task478-server-unreadable-store
git status --short
git add lib/keeper/keeper_meta_store.ml lib/keeper/keeper_meta_store.mli
git commit --amend -m 'feat(keeper): extend Problem_report_state with unreadable-store entries (task-478)'
git fetch origin && git rebase origin/main
git push --force-with-lease
```

## 작업 내역 (이미 working tree에 적용됨):
- `keeper_meta_store.ml`: Problem_report_state에 entry type (detail+first_observed), snapshot(), snapshot_to_yojson(), unreadable_store_snapshot_to_yojson 추가
- `keeper_meta_store.mli`: unreadable_store_snapshot_to_yojson 노출
- `store_unreadable.ml`, `test_store_unreadable.ml`, `test_store_unreadable.inc`: `git rm`으로 삭제 (이미 staged)
- `test/dune`: include 제거, entangled hunk revert

## 참고:
- task-470 릴리스는 operator에게 요청해야 할 수 있습니다 (제가 제3자 task를 릴리스하는 도구가 없음)
- worktree 경로는 `git worktree list`로 찾을 수 있을 것입니다
- PR #29815가 업데이트됩니다. CI는 이미 복구됨 (#29837 merged)"""


def live_markdown_history_fixture() -> HttpResponse:
    # Production reply msg-1787516761351436-321. The concrete Keeper identity
    # is replaced with the same-length fixture identity required by the suite.
    return (
        200,
        [
            {
                "id": "msg-1787516761351436-321",
                "role": "assistant",
                "content": LIVE_MARKDOWN_REPLY,
                "ts": 1787516761.351436,
            }
        ],
    )


def live_markdown_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=80,
        columns=90,
        needle=b"MASC Overview",
    )
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    pane_start = len(output)
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
    tail_head = b"task478-server"
    tail_rest = b"-unreadable-store"
    wait_for_output(
        process,
        master_fd,
        output,
        tail_head,
        start=pane_start,
        timeout=5.0,
    )
    tail_end = end_of_needle(output, tail_head, pane_start)
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=tail_end,
        timeout=3.0,
    )
    frame = frame_containing(bytes(output[pane_start:]), tail_head)
    plain = CSI_RE.sub(b"", frame)
    header = "┌─ bash".encode()
    footer = "└".encode()
    prose = "작업 내역".encode()
    positions = [plain.find(needle) for needle in (header, tail_head, tail_rest, footer, prose)]
    if any(position < 0 for position in positions):
        raise AssertionError(
            "live Markdown frame omitted its language header, complete long line, "
            f"closing border, or following prose: {frame!r}"
        )
    if positions != sorted(positions):
        raise AssertionError(f"live Markdown rows were reordered: {frame!r}")
    if b"\x1b[7m" + header not in frame:
        raise AssertionError(f"language header has no neutral background: {frame!r}")
    if b"```bash" in plain:
        raise AssertionError(f"raw fence marker leaked into the chat: {frame!r}")
    escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
    os.write(master_fd, b"q")


# The three metadata densities differ in where the origin sits, not in what it
# says, so the reading that tells them apart is which screen row each piece
# landed on. A frame is no help: it addresses rows absolutely and writes no
# newlines, so two rows read as one string and "name then body" matches the
# stacked layout as readily as the inline one.
def origin_screen_shape(
    output: bytearray, badge: bytes, body: bytes
) -> tuple[bytes, int]:
    """The screen row carrying [badge], and how far below it [body] sits."""
    rows = screen_rows(bytes(output))
    badge_row = screen_row_of(rows, badge)
    body_row = screen_row_of(rows, body)
    if badge_row < 0 or body_row < 0:
        raise AssertionError(
            f"chat screen lost {badge!r} or {body!r}: "
            f"{screen_text(bytes(output))!r}"
        )
    return rows[badge_row], body_row - badge_row


# The speaker's colour belongs to the badge. A body drawn in it turns the whole
# message into the speaker's colour and the pane loses the one contrast it has.
# Written as the escape rather than as the three colours a speaker happens to
# use today, so a wash in a fourth is caught the day someone writes it.
BODY_WASH = rb"\x1b\[(?:3[0-7]|4[0-7]|9[0-7]|10[0-7])m *"


def assert_bodies_unwashed(frame: bytes, description: str) -> None:
    for body in (b"operator-body-neutral", b"keeper-body-neutral"):
        washed = re.search(BODY_WASH + re.escape(body), frame)
        if washed is not None:
            raise AssertionError(
                f"{description} washed {body!r} in the speaker's colour: {frame!r}"
            )


def message_origin_badge_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    pane_start = len(output)
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
    # The pane draws before its history arrives, and every step below reads a
    # row the history draws, so the walk starts once the later speaker is on
    # screen.
    wait_for_output(
        process,
        master_fd,
        output,
        b"keeper-body-neutral",
        start=pane_start,
        timeout=5.0,
    )
    # The fixture names a speaker, so the operator's line arrives here as
    # someone else's and takes the inbound mark rather than the one a line
    # typed at this pane would take.
    operator_badge = "◀ vincent".encode()
    keeper_badge = "● alpha".encode()
    operator_body = b"operator-body-neutral"
    keeper_body = b"keeper-body-neutral"

    # Ctrl-F walks bare -> inline -> row -> bare and the pane opens on inline,
    # which is the one stop with no header word: the summary names the two
    # projections away from the resting layout ("metadata:off" and
    # "metadata:full") and stays silent about the layout itself. So the first
    # press lands on the full row, and the press that comes back to inline is
    # waited on by the short clock instead -- the one thing neither other stop
    # draws.
    full_row = send_and_wait(process, master_fd, output, b"\x06", b"metadata:full")
    for badge, body, description in (
        (operator_badge, operator_body, "operator"),
        (keeper_badge, keeper_body, "Keeper"),
    ):
        row, gap = origin_screen_shape(output, badge, body)
        if gap != 1:
            raise AssertionError(
                f"the full origin row did not put the {description} body on the "
                f"row below its origin (gap {gap}): {screen_text(bytes(output))!r}"
            )
        if re.search(rb"\[\d\d:\d\d:\d\d\]", row) is None:
            raise AssertionError(
                f"the full {description} origin row carried no timestamp: {row!r}"
            )
    for name in (b"vincent", b"alpha"):
        if b"\x1b[7m" + name not in full_row:
            raise AssertionError(
                f"chat origin did not keep its reverse-video badge for {name!r}: "
                f"{full_row!r}"
            )
    assert_bodies_unwashed(full_row, "the full origin row")

    bare = send_and_wait(process, master_fd, output, b"\x06", b"metadata:off")
    for badge, body, description in (
        (operator_badge, operator_body, "operator"),
        (keeper_badge, keeper_body, "Keeper"),
    ):
        row, gap = origin_screen_shape(output, badge, body)
        if gap != 0:
            raise AssertionError(
                f"the clock-free layout did not keep the {description} body beside "
                f"its origin (gap {gap}): {screen_text(bytes(output))!r}"
            )
        if body not in row:
            raise AssertionError(
                f"the clock-free {description} row lost its body: {row!r}"
            )
        if re.search(rb"\d\d:\d\d", row) is not None:
            raise AssertionError(
                f"the clock-free {description} row still drew a clock: {row!r}"
            )
    assert_bodies_unwashed(bare, "the clock-free layout")

    inline = send_and_wait(
        process,
        master_fd,
        output,
        b"\x06",
        re.compile(rb"\d\d:\d\d " + re.escape("◀".encode())),
    )
    for badge, body, description in (
        (operator_badge, operator_body, "operator"),
        (keeper_badge, keeper_body, "Keeper"),
    ):
        row, gap = origin_screen_shape(output, badge, body)
        if gap != 0:
            raise AssertionError(
                f"the inline layout did not keep the {description} body beside its "
                f"origin (gap {gap}): {screen_text(bytes(output))!r}"
            )
        if body not in row:
            raise AssertionError(
                f"the inline {description} row lost its body: {row!r}"
            )
    # Only the first row of a minute draws the clock, so the operator's row
    # carries it and the Keeper's row a second later does not.
    operator_row, _ = origin_screen_shape(output, operator_badge, operator_body)
    if re.search(rb"\d\d:\d\d " + re.escape("◀".encode()), operator_row) is None:
        raise AssertionError(
            f"the inline layout drew no clock beside the operator origin: "
            f"{operator_row!r}"
        )
    assert_bodies_unwashed(inline, "the inline layout")

    draft_frame = send_and_wait(
        process, master_fd, output, b"draft-neutral", b"draft-neutral"
    )
    if b"\x1b[96m  > \x1b[0mdraft-neutral" not in draft_frame:
        raise AssertionError(
            f"chat composer did not limit accent to its prompt: {draft_frame!r}"
        )
    escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
    os.write(master_fd, b"q")


def viewport_gap_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    # This fixture has no agenda strip. Fourteen physical rows leave only
    # thirteen below navigation; the hint must name the usable physical size.
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=14,
        columns=100,
        needle=b"resize to at least 15 rows",
    )
    # Following the displayed size must restore the surface, not the warning.
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=15,
        columns=100,
        needle=b"MASC Overview",
    )
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    # The opened title row renders "Keepers ▸ alpha" plainly now (the bold
    # run was dropped from the renderer); asserting the old \x1b[1m spelling
    # starves on the plain bytes.
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 alpha")
    opened = send_and_wait(process, master_fd, output, b"m", b"hidden")
    plain = CSI_RE.sub(b"", opened)
    marker = "⋯".encode()
    positions = [plain.find(needle) for needle in (b"line-00", marker, b"line-23")]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise AssertionError(
            f"oversized live edge did not order opening, gap, and latest row: {opened!r}"
        )

    complete = send_and_wait(
        process, master_fd, output, b"\x1b[5~", b"line-18"
    )
    complete_plain = CSI_RE.sub(b"", complete)
    if marker in complete_plain or b"hidden" in complete_plain:
        raise AssertionError(
            f"PgUp retained a synthetic gap inside transcript rows: {complete!r}"
        )
    # An exhausted older page leaves the transcript intact. PgDn must restore
    # the oversized live-edge projection in this response, including its gap
    # and newest row; previously emitted bytes cannot prove that transition.
    newest = send_and_wait(process, master_fd, output, b"\x1b[6~", b"line-23")
    newest_plain = CSI_RE.sub(b"", newest)
    positions = [newest_plain.find(needle) for needle in (b"line-00", marker, b"line-23")]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise AssertionError(
            "PgDn did not restore the oversized live-edge projection "
            f"after one PgUp: {newest!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 alpha")
    os.write(master_fd, b"q")


def keeper_message_switch_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    fixtures = keeper_runtime_http_fixtures()
    alpha_history = GatedHttpResponse(
        (
            200,
            [
                {
                    "id": "alpha-stale-history",
                    "role": "assistant",
                    "content": "alpha-stale-history-marker",
                    "ts": 1787348500.3,
                }
            ],
        ),
        subsequent_response=(
            200,
            [
                {
                    "id": "alpha-current-history",
                    "role": "assistant",
                    "content": "alpha-current-history-marker",
                    "ts": 1787348502.3,
                }
            ],
        ),
    )
    fixtures["/api/v1/keepers/alpha/chat/history"] = alpha_history
    fixtures["/api/v1/keepers/beta/chat/history"] = (
        200,
        [
            {
                "id": "beta-current-history",
                "role": "assistant",
                "content": "beta-current-history-marker",
                "ts": 1787348501.3,
            }
        ],
    )
    return fixtures, alpha_history


# The width at which the roster shares the screen with the chat and nothing
# else does. Two thresholds bound it, and 140 sat between them: the roster
# needs the surface at Masc_tui_roster_pane.threshold_cols (110), and from
# Masc_tui_acting_pane.threshold_cols (132) the acting pane takes its 56
# columns off the top, which leaves the surface 76 and takes the roster away
# again. Measured on the built TUI: 120 and 131 draw the roster, 132 does not,
# 166 draws both panes.
# The status row names the keeper, then its automation and gate, then the
# runtime. Joining the health word to the runtime pinned that order, and the
# two fields that arrived between them broke both readings at once. The pair
# these scenarios care about is "this keeper's own health and its own
# runtime", which is a question about one row.
def assert_runtime_row(
    frame: bytes, *, health: bytes, runtime: bytes, description: str
) -> None:
    rows = screen_rows(frame)
    row = screen_row_of(rows, runtime)
    if row < 0 or health not in rows[row]:
        raise AssertionError(
            f"{description} did not carry {health!r} beside {runtime!r}: {frame!r}"
        )


ROSTER_BESIDE_CHAT_COLUMNS = 120


def keeper_message_switch_interaction(alpha_history: GatedHttpResponse) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"MASC Overview",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"2",
            b"anthropic.claude-opus-5",
        )
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        if not wait_for_fixture_event(
            process, master_fd, output, alpha_history.requested, timeout=10.0
        ):
            raise AssertionError("alpha history request did not reach its fixture")
        send_and_wait(
            process,
            master_fd,
            output,
            b"alpha-draft",
            composer_showing(b"alpha-draft"),
        )

        # The roster is put away until it is asked for, so this scenario asks.
        # Ctrl-B is refused below Masc_tui_roster_pane.threshold_cols, and the
        # width above is chosen to clear it.
        send_and_wait(process, master_fd, output, b"\x02", b"KEEPERS")

        beta_start = len(output)
        # A drawn roster is an input pane: Left focuses it, Down moves its
        # cursor, and Enter opens that Keeper without changing the draft.
        send_and_wait(process, master_fd, output, b"\x1b[D", b"Enter:open")
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[B",
            b"\x1b[7m \xc2\xb7 beta",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"beta-current-history-marker",
            start=beta_start,
            timeout=3.0,
        )
        beta_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        beta_plain = CSI_RE.sub(b"", beta_frame)
        assert_runtime_row(
            beta_frame,
            health=b"idle",
            runtime=b"paused anthropic.claude-sonnet-4",
            description="switched beta chat",
        )
        for expected in (
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            b"beta-current-history-marker",
        ):
            if expected not in beta_plain:
                raise AssertionError(
                    f"switched beta chat omitted {expected!r}: {beta_frame!r}"
                )
        if b"alpha-draft" in beta_plain:
            raise AssertionError(f"alpha draft leaked into beta chat: {beta_frame!r}")
        send_and_wait(
            process,
            master_fd,
            output,
            b"beta-draft",
            composer_showing(b"beta-draft"),
        )

        alpha_start = len(output)
        send_and_wait(process, master_fd, output, b"\x07", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        wait_for_output(
            process,
            master_fd,
            output,
            b"alpha-current-history-marker",
            start=alpha_start,
            timeout=3.0,
        )
        alpha_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        alpha_plain = CSI_RE.sub(b"", alpha_frame)
        assert_runtime_row(
            alpha_frame,
            health=b"healthy",
            runtime=b"running anthropic.claude-opus-5",
            description="restored alpha chat",
        )
        for expected in (
            b"alpha-current-history-marker",
            b"> alpha-draft",
        ):
            if expected not in alpha_plain:
                raise AssertionError(
                    f"restored alpha chat omitted {expected!r}: {alpha_frame!r}"
                )

        # The first alpha request now finishes after alpha was left and opened
        # again. Keeper identity matches; only the load generation can reject
        # this ABA response in favour of the second alpha request above.
        alpha_history.release.set()
        if not wait_for_fixture_event(
            process, master_fd, output, alpha_history.completed, timeout=10.0
        ):
            raise AssertionError("released alpha history fixture did not complete")
        time.sleep(0.1)
        stale_check = resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        stale_plain = CSI_RE.sub(b"", stale_check)
        if b"alpha-current-history-marker" not in stale_plain:
            raise AssertionError(
                f"late first alpha response replaced current history: {stale_check!r}"
            )
        if b"alpha-stale-history-marker" in stale_plain:
            raise AssertionError(
                f"late first alpha response survived generation guard: {stale_check!r}"
            )

        beta_again_start = len(output)
        send_and_wait(process, master_fd, output, b"\x07", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
        wait_for_output(
            process,
            master_fd,
            output,
            b"beta-current-history-marker",
            start=beta_again_start,
            timeout=3.0,
        )
        beta_again = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        beta_again_plain = CSI_RE.sub(b"", beta_again)
        for expected in (b"beta-current-history-marker", b"> beta-draft"):
            if expected not in beta_again_plain:
                raise AssertionError(
                    f"beta chat did not restore {expected!r}: {beta_again!r}"
                )
        escape_to_keeper_detail(process, master_fd, output, name=b"beta")
        os.write(master_fd, b"q")

    return interact


def keeper_calls_fixture() -> HttpResponse:
    return (
        200,
        {
            "keeper": "alpha",
            "count": 2,
            "health": "ok",
            "latest_age_s": 8.0,
            "stale_reason": "fresh",
            "entries": [
                {
                    "ts": 1787534998.4,
                    "keeper": "alpha",
                    "tool": "Read",
                    "input": '{"file_path": "lib/a.ml"}',
                    "output": "sentinel-digest-31506",
                    "success": True,
                    "duration_ms": 28.4,
                    "turn": 2143,
                },
                {
                    "ts": 1787535017.4,
                    "keeper": "alpha",
                    "tool": "tool_execute",
                    "input": '{"argv": ["dune", "build"]}',
                    "success": False,
                    "duration_ms": 14534.0,
                    "turn": 2144,
                },
            ],
        },
    )


def keeper_calls_interaction() -> Interaction:
    """t on the roster opens the keeper's durable call log."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        pane_start = len(output)
        send_and_wait(
            process,
            master_fd,
            output,
            b"t",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 calls",
        )
        wait_for_output(
            process, master_fd, output, b"tool_execute", start=pane_start, timeout=5.0
        )
        pane = bytes(output[pane_start:])
        for needle, what in (
            (b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 calls (2)", "the count"),
            ("ok \u00b7 latest 8s ago".encode(), "the freshness verdict"),
            ("\u2713".encode(), "the returned-call verdict"),
            (b"#1 tool Read", "the returned-call tool"),
            (b"28ms", "its duration"),
            ("\u2717".encode(), "the failed-call verdict"),
            (b"#2 tool tool_execute", "the failed-call tool"),
            (b"14.5s", "the failure's duration"),
            (b"lib/a.ml", "the recorded input path"),
            (b"sentinel-digest-31506", "the returned call output"),
        ):
            if needle not in pane:
                raise AssertionError(f"Keeper Calls did not draw {what}: {pane!r}")
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def verification_unread_interaction(gate: GatedHttpResponse) -> Interaction:
    """A surface that has not been read says so; only a read that came back
    empty says the queue is empty.

    The Verification surface used to print "(nothing waiting on a verdict)"
    under a header that still said "(not loaded)", so the two rows disagreed
    about whether anything had been asked. The fixture holds the response
    until the first frame has been read off.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Planning")
        unread = send_and_wait(
            process, master_fd, output, b"v", b"Task Review"
        )
        if b"(not loaded)" not in unread:
            raise AssertionError(
                f"Verification header did not say not loaded: {unread!r}"
            )
        if b"(not loaded yet" not in unread:
            raise AssertionError(
                f"Verification body claimed a reading before one was made: {unread!r}"
            )
        if b"nothing waiting" in unread:
            raise AssertionError(
                f"Verification body read an empty queue off no reading: {unread!r}"
            )
        if not wait_for_fixture_event(
            process, master_fd, output, gate.requested, timeout=10.0
        ):
            raise AssertionError("Verification surface did not ask for its queue")
        loaded = release_and_wait_for_frame(
            process, master_fd, output, gate, b"(nothing waiting on a verdict)"
        )
        # The title and the count are asserted apart: a style reset may sit
        # between them once surface titles carry their own styling.
        if (
            b"MASC Planning" not in loaded
            or b"Task Review" not in loaded
            or b"(0 of 0)" not in loaded
        ):
            raise AssertionError(
                f"Verification header did not report the read: {loaded!r}"
            )
        os.write(master_fd, b"q")

    return interact


def planning_review_hierarchy_interaction() -> Interaction:
    """Planning owns Goals and Task Review while Tab sees one parent."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        goals = tab_until(process, master_fd, output, b"MASC Planning")
        for needle in (
            b"\xe2\x96\xb8Goals",
            b"Task Review",
            b"Task Verdicts",
        ):
            if needle not in goals:
                raise AssertionError(
                    f"Planning did not expose its ordered child views "
                    f"({needle!r}): {goals!r}"
                )
        review = send_and_wait(
            process, master_fd, output, b"v", b"\xe2\x96\xb8Task Review"
        )
        wait_for_output(process, master_fd, output, b"task-901", start=0, timeout=3.0)
        plain_review = CSI_RE.sub(b"", review)
        if b"MASC Planning" not in plain_review:
            raise AssertionError(f"Task Review lost its Planning parent: {plain_review!r}")
        verdicts = send_and_wait(
            process,
            master_fd,
            output,
            b"v",
            b"\xe2\x96\xb8Task Verdicts",
        )
        verdicts_plain = CSI_RE.sub(b"", verdicts)
        for needle in (b"automatic Gate rulings on Tasks", b"not Goal proof", b"Task Verdicts"):
            if needle not in verdicts_plain:
                raise AssertionError(
                    f"Task Verdicts did not explain itself ({needle!r}): "
                    f"{verdicts_plain!r}"
                )
        # Planning's [v] strip has exactly three stops — Goals, Task Review,
        # Task Verdicts — and wraps back round to Goals. The walk used to
        # keep two extra children, Schedules and Fusion, but Schedules was
        # promoted to its own top-level surface (palette: "go Schedules";
        # the wake-schedule scenario asserts that entry point) and Fusion
        # became a tab of the selected Keeper (RFC-tui-operator-ia 3.1).
        # Waiting for their boxed titles here starved with the strip
        # redrawn every stop but theirs never drawn.
        goals_again = send_and_wait(
            process, master_fd, output, b"v", b"\xe2\x96\xb8Goals"
        )
        if b"Task Review" not in goals_again:
            raise AssertionError(
                f"Goals did not retain the Task Review sibling: {goals_again!r}"
            )
        # The children are [v] stops, not the next top-level Tab destination.
        # From Planning, the ring's next stop is Fusion (surface_ring:
        # ... Planning; Fusion; Workspace/Repositories; ...), so one Tab
        # lands on Fusion's boxed title, not on Workspace two stops later.
        send_and_wait(process, master_fd, output, b"\t", b"MASC Fusion")
        os.write(master_fd, b"q")

    return interact


def planning_activity_actor_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Planning")
        detail = send_and_wait(
            process, master_fd, output, b"\r", b"completed by beta"
        )
        plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"RELATED ACTIVITY",
            b"latest state per linked item",
            b"task-actor",
            b"completed by beta",
            b"handoff by",
            b"alpha:",
        ):
            if needle not in plain:
                raise AssertionError(
                    f"Planning activity omitted {needle!r}: {plain!r}"
                )
        os.write(master_fd, b"q")

    return interact


REPOSITORIES_PATH = "/api/v1/repositories"


def repositories_fixture() -> tuple[int, dict[str, object]]:
    return (
        200,
        {
            "repositories": [
                {"id": "masc", "name": "masc",
                 "codebase": "github.com_jeong-sik_masc",
                 "url": "git@github.com:jeong-sik/masc.git",
                 "local_path": "workspace/masc",
                 "resolved_local_path": "/srv/masc/workspace/masc",
                 "default_branch": "main",
                 "status": "ready", "keepers": ["alpha"], "auto_sync": True},
            ],
            "total": 1,
        },
    )


@contextmanager
def repository_declaration_editor_script() -> Iterator[str]:
    """An $EDITOR that fills the repository declaration form and exits 0."""
    fd, path = tempfile.mkstemp(prefix="masc-tui-repo-editor-", suffix=".sh")
    try:
        os.write(
            fd,
            b'#!/bin/sh\nprintf %s \'{"name": "kirin", '
            b'"url": "git@github.com:jeong-sik/kirin.git", '
            b'"default_branch": "main", "auto_sync": false, '
            b'"sync_interval": 300}\' > "$1"\n',
        )
        os.close(fd)
        os.chmod(path, 0o755)
        yield path
    finally:
        os.unlink(path)


def repository_add_interaction(requests: HttpRequests) -> Interaction:
    """Pressing a on Repositories registers a repository, and the surface the
    key was pressed on says what happened.

    Every outcome of this action -- the registration, a refused declaration,
    an editor that never started -- went to the event log, and the event log
    is drawn by Overview alone. So the operator who pressed the key stood on
    the one surface that could not answer them, and a repository that was
    registered looked exactly like nothing at all."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Workspace")
        wait_for_output(
            process, master_fd, output, b"ready", start=0, timeout=3.0
        )
        os.write(master_fd, b"a")
        body = wait_for_http_request(
            process, master_fd, output, requests, path=REPOSITORIES_PATH
        )
        payload = json.loads(body)
        if payload.get("name") != "kirin":
            raise AssertionError(f"repository POST body: {payload!r}")
        # The footer, not the event log: this is the surface the key was
        # pressed on, and it is the one that has to answer.
        wait_for_output(
            process,
            master_fd,
            output,
            b"kirin: repository added",
            start=0,
            timeout=5.0,
        )
        os.write(master_fd, b"q")

    return interact


def repositories_path_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """Show paths, inspect Git changes, then enter the repository."""
    tab_until(process, master_fd, output, b"MASC Workspace")
    narrow = resize_and_wait(
        process,
        master_fd,
        output,
        rows=18,
        columns=80,
        needle=b"/srv/masc/workspace/masc",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    wide = resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=140,
        needle=b"/srv/masc/workspace/masc",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for width, frame in ((80, narrow), (140, wide)):
        plain = CSI_RE.sub(b"", frame).decode("utf-8")
        for needle in ("Path", "Stored as: workspace/masc", "Keepers: alpha"):
            if needle not in plain:
                raise AssertionError(
                    f"{width}-column Repositories omitted {needle!r}: {plain!r}"
                )
    changes_wide = send_and_wait(
        process, master_fd, output, b"d", b"lib/changed file.ml"
    )
    changes_narrow = resize_and_wait(
        process,
        master_fd,
        output,
        rows=18,
        columns=80,
        needle=b"lib/changed file.ml",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for width, frame in ((80, changes_narrow), (140, changes_wide)):
        changes_plain = CSI_RE.sub(b"", frame).decode("utf-8")
        for needle in (
            "MASC Git Changes",
            "staged+worktree",
            "lib/changed file.ml",
            "untracked",
            "새 파일.txt",
        ):
            if needle not in changes_plain:
                raise AssertionError(
                    f"{width}-column Repository Git changes omitted "
                    f"{needle!r}: {changes_plain!r}"
                )
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=140,
        needle=b"lib/changed file.ml",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Workspace")
    code = send_and_wait(process, master_fd, output, b"\r", b"src")
    code_plain = CSI_RE.sub(b"", code).decode("utf-8")
    if "masc ▸ /" not in code_plain:
        raise AssertionError(
            f"the Code header does not name the repository: {code_plain!r}"
        )
    os.write(master_fd, b"q")


def project_changes_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """List an unregistered project's Git changes from Code, return to the
    tree, leave for Workspace with Esc at the root and walk back in, then
    reopen the list and enter the selected file."""
    palette_go(process, master_fd, output, b"go code", b"README.md")
    changes_wide = send_and_wait(process, master_fd, output, b"d", b"lib/a.ml")
    changes_narrow = resize_and_wait(
        process,
        master_fd,
        output,
        rows=18,
        columns=80,
        needle=b"lib/a.ml",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for width, frame in ((80, changes_narrow), (140, changes_wide)):
        plain = CSI_RE.sub(b"", frame).decode("utf-8")
        for needle in (
            "MASC Git Changes",
            "Project workspace",
            "worktree",
            "lib/a.ml",
            "untracked",
            "새 파일.txt",
        ):
            if needle not in plain:
                raise AssertionError(
                    f"{width}-column project Git changes omitted "
                    f"{needle!r}: {plain!r}"
                )
    tree = send_and_wait(process, master_fd, output, b"\x1b", b"README.md")
    if "MASC Git Changes" in CSI_RE.sub(b"", tree).decode("utf-8"):
        raise AssertionError("Esc did not return from project changes to Code")
    # With nothing open and the project root under foot, Esc leaves for
    # Workspace, the ring parent; the palette walks back in for the rest.
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Workspace")
    palette_go(process, master_fd, output, b"go code", b"README.md")
    send_and_wait(process, master_fd, output, b"d", b"lib/a.ml")
    # The diff view's header now reads "MASC Git Diff lib/a.ml vs HEAD
    # [connected]" -- no "[j/k]" scroll hint survives in this frame (that
    # was the Git Changes list's own footer hint, from before this Enter).
    # "MASC Git Diff" and " lib/a.ml" sit either side of an SGR reset
    # (bold-off after the title), so the needle must stay inside the one
    # plain run that follows it. The header paints instantly but the diff
    # body ("(reading the tree)" -> the actual lines) loads afterward, so
    # send_and_wait's single returned frame is the loading placeholder --
    # wait for the body separately and grab the frame that contains it.
    diff_start = len(output)
    os.write(master_fd, b"\r")
    wait_for_output(
        process, master_fd, output, b"lib/a.ml  vs HEAD", start=diff_start, timeout=3.0
    )
    wait_for_output(
        process, master_fd, output, b"let x = 1", start=diff_start, timeout=5.0
    )
    loaded_end = output.find(b"let x = 1", diff_start) + len(b"let x = 1")
    wait_for_output(
        process, master_fd, output, FRAME_END, start=loaded_end, timeout=3.0
    )
    frame_end = output.find(FRAME_END, loaded_end) + len(FRAME_END)
    opened = frame_containing(bytes(output[diff_start:frame_end]), b"let x = 1")
    opened_plain = CSI_RE.sub(b"", opened).decode("utf-8")
    if "let x = 1" not in opened_plain:
        raise AssertionError(
            f"Enter opened the file without its highlighted content: {opened_plain!r}"
        )
    if "Project workspace" in opened_plain:
        raise AssertionError(
            "Enter left the project changes overlay open instead of opening code"
        )
    os.write(master_fd, b"q")


def repositories_enter_interaction() -> Interaction:
    """Enter on a Repositories row opens that repository's own tree on the
    Code surface, through the ?repo_id= axis; the header names whose tree
    it is. Then m lists the memos the file carries as comments, read off
    the lexed rows rather than fetched."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Workspace")
        wait_for_output(
            process, master_fd, output, b"ready", start=0, timeout=3.0
        )
        code = send_and_wait(process, master_fd, output, b"\r", b"src")
        code_plain = CSI_RE.sub(b"", code).decode("utf-8")
        if "masc ▸ /" not in code_plain:
            raise AssertionError(
                f"the Code header does not name the repository: {code_plain!r}"
            )
        # Open a file in the repository scope, then m: the memo is the
        # comment on line 1, in the file's own syntax, so the list needs no
        # request and names the line, the author, the kind and the text.
        send_and_wait(process, master_fd, output, b"j\r", b"let")
        notes = send_and_wait(
            process, master_fd, output, b"m", b"keep n at three"
        )
        notes_plain = CSI_RE.sub(b"", notes).decode("utf-8")
        for needle in ("notes: note.ml", "L1", "alpha", "(decision)"):
            if needle not in notes_plain:
                raise AssertionError(
                    f"the notes view missed {needle!r}: {notes_plain!r}"
                )
        back = send_and_wait(process, master_fd, output, b"\x1b", b"let")
        # The memo decorates the gutter: line 1 carries the anchor mark.
        if "●".encode() not in back:
            raise AssertionError(
                f"the memo mark is missing from the gutter: {back!r}"
            )
        # H over the repo-scoped file: the commits that touched it,
        # newest first.
        history = send_and_wait(process, master_fd, output, b"H", b"abc1234")
        history_plain = CSI_RE.sub(b"", history).decode("utf-8")
        for needle in ("history: note.ml", "seed the file"):
            if needle not in history_plain:
                raise AssertionError(
                    f"the history missed {needle!r}: {history_plain!r}"
                )
        # Enter on the top row (the newest commit): its subject's (#N) plus
        # the registered remote become the PR link.
        send_and_wait(
            process, master_fd, output, b"\r",
            b"github.com/jeong-sik/masc/pull/1256",
        )
        os.write(master_fd, b"q")

    return interact


VERIFICATION_VERDICT_PATH = "/api/v1/verification/verdict"


def verification_request_row(task_id: str) -> dict[str, object]:
    return {
        "request_id": f"vr-{task_id}",
        "task_id": task_id,
        "task_title": f"finish {task_id}",
        # request_kind, request_summary and next_action are gone from the
        # producer: Verification_protocol wrote them as the fixed literals
        # "normal", "" and "", so three rows of the detail pane said the same
        # thing on every request ever drawn. Nothing reads them now.
        "submitted_by": "keeper-alpha",
        "created_at": "2026-08-25T14:00:00+09:00",
        "required_artifacts": ["diff"],
        "submitted_evidence": ["diff"],
    }


def verification_verdict_fixtures() -> HttpFixtures:
    rows = [
        verification_request_row("task-901"),
        verification_request_row("task-902"),
    ]
    return {
        "/api/v1/verification/requests?limit=200": (
            200,
            {"requests": rows, "total": 2},
        ),
        VERIFICATION_VERDICT_PATH: (
            200,
            {"ok": True, "message": "verdict recorded for task-901", "noop": False},
        ),
    }


@contextmanager
def reject_editor_script() -> Iterator[str]:
    """An $EDITOR that writes the reject reason into the form and exits 0.

    The TUI hands the editor the temp file as its one argument; a real editor
    is a human typing, this one is the same save without the human.
    """
    fd, path = tempfile.mkstemp(prefix="masc-tui-reject-editor-", suffix=".sh")
    try:
        os.write(fd, b'#!/bin/sh\nprintf %s \'{"reason": "needs a repro"}\' > "$1"\n')
        os.close(fd)
        os.chmod(path, 0o755)
        yield path
    finally:
        os.unlink(path)


def verification_verdict_interaction(requests: HttpRequests) -> Interaction:
    """Enter explains what the request asks for and which evidence exists.
    Then `a` arms and only the second `a` sends the approve; `x` collects a
    reason through $EDITOR and sends the reject. The verdict assertions read
    the recorded POST bodies -- the wire, not the paint -- and the frame
    between the two presses proves the first one sent nothing.
    """

    def verdict_bodies() -> list[bytes]:
        return [
            body
            for request_path, body in requests
            if request_path == VERIFICATION_VERDICT_PATH
        ]

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Planning")
        send_and_wait(process, master_fd, output, b"v", b"Task Review")
        wait_for_output(
            process, master_fd, output, b"task-901", start=0, timeout=3.0
        )
        detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"HOW TO READ THIS",
        )
        detail_plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"vr-task-901",
            b"finish task-901",
            b"Submitted by",
            b"REQUIRED ARTIFACTS (1)",
            b"SUBMITTED EVIDENCE (1)",
            b"diff",
            b"Left / Esc:back",
        ):
            if needle not in detail_plain:
                raise AssertionError(
                    f"Verification detail omitted {needle!r}: {detail_plain!r}"
                )
        send_and_wait(process, master_fd, output, b"\x1b", b"task-901")
        send_and_wait(
            process,
            master_fd,
            output,
            b"a",
            b"armed: approve task-901 -- same key again to send",
        )
        if verdict_bodies():
            raise AssertionError("the first press already sent the verdict")
        os.write(master_fd, b"a")
        approve_body = wait_for_http_request(
            process, master_fd, output, requests, path=VERIFICATION_VERDICT_PATH
        )
        approve_payload = json.loads(approve_body)
        if approve_payload != {"task_id": "task-901", "verdict": "approve"}:
            raise AssertionError(f"approve body: {approve_payload!r}")
        # Let the approve completion and its queue reload settle before the
        # editor temporarily gives up the alternate screen. Otherwise the
        # redraw from that reload can race the terminal handoff and leave the
        # editor wait with no frame to drain.
        drain_until_quiet(process, master_fd, output)
        # Reject on the same row: the $EDITOR stub saves the reason form, so
        # the second verdict body carries it.
        read_available(master_fd, output)
        reject_start = len(output)
        os.write(master_fd, b"x")
        deadline = time.monotonic() + 10.0
        while len(verdict_bodies()) < 2:
            read_available(master_fd, output)
            if process.poll() is not None:
                raise AssertionError("TUI exited before the reject verdict")
            if time.monotonic() > deadline:
                raise AssertionError(
                    f"reject verdict never posted: {bytes(output[reject_start:])!r}"
                )
            select.select([master_fd], [], [], 0.05)
        reject_payload = json.loads(verdict_bodies()[1])
        if reject_payload != {
            "task_id": "task-901",
            "verdict": "reject",
            "reason": "needs a repro",
        }:
            raise AssertionError(f"reject body: {reject_payload!r}")
        # The verdict events live on the Overview's TUI Session Events pane, so
        # the visible trace is asserted there, not on the Verification frame.
        tab_until(process, master_fd, output, b"MASC Overview")
        wait_for_output(
            process,
            master_fd,
            output,
            b"rejecting task-901",
            start=reject_start,
            timeout=3.0,
        )
        # The events pane trims long rows, so the completion needle stops
        # before the width does.
        wait_for_output(
            process,
            master_fd,
            output,
            b"Verification: verdict recorded",
            start=reject_start,
            timeout=3.0,
        )
        os.write(master_fd, b"q")

    return interact


KEEPER_LANES_PATH = "/api/v1/keepers/composite"
STANDALONE_LANES_PATH = "/api/v1/dashboard/standalone-lanes"


def standalone_lane_fixture(
    lane_id: str, label: str, *, status: str = "idle"
) -> dict[str, object]:
    """One row of the observation matrix, in the wire shape the strict
    decoder accepts: every known lane exactly once, observation_only set."""
    lane_contracts = {
        "board_attention_exact": (
            "Judges one durable Board candidate for Keeper attention.",
            True,
        ),
        "hitl_auto_judge": (
            "Produces the structured judgment for one held approval.",
            True,
        ),
        "librarian_exact": (
            "Selects the next Memory OS snapshot from immutable Keeper history.",
            False,
        ),
        "verifier_exact": (
            "Reviews Task completion and Goal proof evidence.",
            False,
        ),
    }
    purpose, required = lane_contracts[lane_id]
    return {
        "lane_id": lane_id,
        "label": label,
        "purpose": purpose,
        "required": required,
        "observation_only": True,
        "configured": True,
        "configuration_state": "ready",
        "admitted_slots": ["glm-coding.glm-5-turbo"],
        # The projection writes three slot lists, not one: what the lane
        # admitted, what it reaches over a CLI, and what its admission
        # dropped. Omitting the last two fails the row decode, and the whole
        # snapshot with it, so the observation matrix simply never draws --
        # the surface has no per-row gap to show.
        "cli_slots": [],
        "dropped_slots": [],
        "admission_error": None,
        "status": status,
        "retained_run_count": 12,
        "running_count": 0,
        "succeeded_count": 12,
        "failed_count": 0,
        "cancelled_count": 0,
        "last_started_at": 1787557600.0,
        "last_terminal_at": 1787557660.0,
        "last_outcome": "succeeded",
        "p50_elapsed_s": 8.0,
        "selected_slots": [{"slot_id": "glm-coding.glm-5-turbo", "count": 12}],
    }


def standalone_lanes_response() -> HttpResponse:
    return (
        200,
        {
            "schema": "masc.standalone_llm_lanes.v1",
            "generated_at": "2026-08-27T20:36:29Z",
            "observed_at_unix": 1787557669.715736,
            "exact_run_projection_count": 60,
            "exact_run_source_total": 60,
            "exact_run_projection_truncated": False,
            "observation_only": True,
            "lanes": [
                standalone_lane_fixture(
                    "board_attention_exact", "Board Attention", status="running"
                ),
                standalone_lane_fixture("hitl_auto_judge", "HITL Auto Judge"),
                standalone_lane_fixture("librarian_exact", "Librarian"),
                standalone_lane_fixture("verifier_exact", "Verifier"),
            ],
        },
    )


def lane_runs_path(lane_id: str) -> str:
    return f"/api/v1/dashboard/exact-lane-runs?limit=50&lane={lane_id}"


def lane_runs_response(lane_id: str, count: int) -> HttpResponse:
    """One page of exact-lane runs, in the wire shape the paged decoder
    accepts: every run carries the lane the caller filters on, and has_more
    is false so no cursor page follows."""
    return (
        200,
        {
            "runs": [
                {
                    "run_id": f"lr-{index:03d}",
                    "lane": lane_id,
                    "actor": "fixture",
                    "started_at": 1787557000.0 + index,
                    "status": "succeeded",
                    "elapsed_s": 1.5,
                    "selected_slot": "glm-coding.glm-5-turbo",
                }
                for index in range(count)
            ],
            "has_more": False,
        },
    )


def verifier_lane_runs_response() -> HttpResponse:
    return (
        200,
        {
            "runs": [
                {
                    "run_id": "vrf-fixture",
                    "run_kind": "task_verification",
                    "lane": "verifier_exact",
                    "subject_id": "task-9",
                    "actor": "verifier_exact",
                    "started_at": 1787557000.0,
                    "status": "rejected",
                    "elapsed_s": 3.0,
                    "selected_slot": "verifier-primary",
                }
            ],
            "has_more": False,
        },
    )


def standalone_lane_runtime_config_response() -> HttpResponse:
    return (
        200,
        {
            **runtime_config_read_metadata(),
            "path": "/workspace/config/runtime.toml",
            "source_text": "\n".join(
                [
                    "[runtime.exact_output_lanes.board_attention_exact]",
                    'slots = ["glm-coding.glm-5-turbo"]',
                    "",
                    "[runtime.exact_output_lanes.hitl_auto_judge]",
                    'slots = ["glm-coding.glm-5-turbo"]',
                    "",
                    "[runtime.exact_output_lanes.librarian_exact]",
                    'slots = ["glm-coding.glm-5-turbo"]',
                    "",
                    "[runtime.exact_output_lanes.verifier_exact]",
                    'slots = ["glm-coding.glm-5-turbo"]',
                ]
            ),
        },
    )


def verifier_lane_run_detail_response() -> HttpResponse:
    return (
        200,
        {
            "run": {
                "run_id": "vrf-fixture",
                "run_kind": "task_verification",
                "lane": "verifier_exact",
                "subject_id": "task-9",
                "actor": "verifier_exact",
                "started_at": 1787557000.0,
                "status": "rejected",
                "elapsed_s": 3.0,
                "selected_slot": "verifier-primary",
                "skill_evidence": {"state": "no_keeper_skills"},
                "payload_availability": {
                    "input": {"state": "available"},
                    "output": {"state": "available"},
                },
                "input": {
                    "kind": "exact",
                    "payload": {
                        "kind": "task_verification",
                        "task_id": "task-9",
                        "producer": "alpha",
                        "evidence": [
                            f"request-evidence-{index:02d}" for index in range(24)
                        ],
                    },
                },
                "output": {
                    "reason": "missing proof",
                    "checks": [f"verifier-check-{index:02d}" for index in range(24)],
                    "tools": [
                        {
                            "tool_name": "masc_task_get",
                            "input": {"task_id": "task-9"},
                            "disposition": "completed",
                            "output_excerpt": "awaiting verification",
                            "output_truncated": False,
                            "duration_ms": 12.0,
                        },
                        {
                            "tool_name": "tool_read_file",
                            "input": {"file_path": "proof.json"},
                            "disposition": "failed",
                            "output_excerpt": "proof missing",
                            "output_truncated": False,
                            "duration_ms": 7.0,
                        }
                    ],
                },
            }
        },
    )


def hitl_lane_runs_response() -> HttpResponse:
    return (
        200,
        {
            "runs": [
                {
                    "run_id": "hitl-fixture",
                    "run_kind": "exact_output",
                    "lane": "hitl_auto_judge",
                    "actor": "auto_judge",
                    "started_at": 1787557000.0,
                    "status": "succeeded",
                    "elapsed_s": 2.0,
                    "selected_slot": "judge-primary",
                }
            ],
            "has_more": False,
        },
    )


def hitl_lane_run_detail_response() -> HttpResponse:
    return (
        200,
        {
            "run": {
                "run_id": "hitl-fixture",
                "run_kind": "exact_output",
                "lane": "hitl_auto_judge",
                "actor": "auto_judge",
                "started_at": 1787557000.0,
                "status": "succeeded",
                "elapsed_s": 2.0,
                "selected_slot": "judge-primary",
                "skill_evidence": {"state": "no_keeper_skills"},
                "payload_availability": {
                    "input": {"state": "available"},
                    "output": {"state": "available"},
                },
                "input": {
                    "kind": "exact",
                    "payload": {"tool_name": "network_read"},
                },
                "output": {
                    "summary_version": 2,
                    "judgment": "approve",
                    "rationale": "the requested read is bounded",
                },
            }
        },
    )


def assert_verifier_tool_color_summary(frame: bytes) -> None:
    """The executed PTY path must preserve typed severity and per-call color."""
    plain = CSI_RE.sub(b"", frame)
    expected = (
        b"TOOLS  \xe2\x9c\x97 FAILED 1   \xe2\x9c\x93 COMPLETED 1   "
        b"\xe2\x94\x80\xe2\x94\x80  2 CALLS  \xe2\x94\x82  "
        b"\xe2\x9c\x93 masc_task_get \xe2\x80\xb9completed \xc2\xb7 12ms\xe2\x80\xba  "
        b"\xe2\x94\x82  \xe2\x9c\x97 tool_read_file "
        b"\xe2\x80\xb9failed \xc2\xb7 7ms\xe2\x80\xba"
    )
    if expected not in plain:
        raise AssertionError(
            f"Verifier detail omitted its typed Tool rollup/calls: {frame!r}"
        )
    if b"\x1b[1mTOOLS\x1b[0m \x1b[91m\x1b[7m\x1b[1m" not in frame:
        raise AssertionError(
            "Verifier detail did not put the worst severity immediately after "
            f"the emphasized Tool label as an ANSI badge: {frame!r}"
        )
    for style, mark, count, status, tool in (
        (b"\x1b[91m", b"\xe2\x9c\x97", b"1", b"failed", b"tool_read_file"),
        (b"\x1b[92m", b"\xe2\x9c\x93", b"1", b"completed", b"masc_task_get"),
    ):
        rollup = (
            style
            + b"\x1b[7m\x1b[1m "
            + mark
            + b" "
            + status.upper()
            + b" "
            + count
            + b" "
        )
        detail = style + b"\x1b[1m" + mark + b" " + tool
        if rollup not in frame or detail not in frame:
            raise AssertionError(
                f"Verifier detail did not map {status!r} to its semantic "
                f"color/glyph for {tool!r}: {frame!r}"
            )


def keeper_lanes_response(lanes: list[dict[str, object]]) -> HttpResponse:
    return (
        200,
        {
            "generated_at": 1787557669.715736,
            "count": len(lanes),
            "snapshots": lanes,
        },
    )


def keeper_lane_row(
    keeper: str,
    *,
    phase: str,
    turn_phase: str,
    idle_seconds: int,
    runtime_state: str | None,
    selected_model: str | None,
    diagnosis: str | None,
) -> dict[str, object]:
    last_outcome: object = None
    if runtime_state is not None:
        last_outcome = {
            "runtime_state": runtime_state,
            "selected_model": selected_model,
        }
    return {
        "keeper": keeper,
        "phase": phase,
        "turn_phase": turn_phase,
        "idle_seconds": idle_seconds,
        "last_outcome": last_outcome,
        "phase_diagnosis": {"determining_condition": diagnosis},
    }


def keeper_lanes_interaction(
    fixtures: HttpFixtures,
    gate: GatedHttpResponse,
    history: SequencedHttpResponse,
    memory: SequencedHttpResponse,
    file_changes: SequencedHttpResponse,
) -> Interaction:
    """One visit covers lane readings, exact chat, and an unmatched Keeper."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Keepers")
        send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            keeper_row_selected(b"beta"),
        )
        unread = palette_go(process, master_fd, output, b"go lanes", b"MASC Lanes")
        # The body note is "(not loaded yet — press r)": #30945 added the
        # key hint without updating this needle.
        if b"(not loaded)" not in unread or b"(not loaded yet" not in unread:
            raise AssertionError(
                f"Lanes claimed a reading before one arrived: {unread!r}"
            )
        unread_plain = CSI_RE.sub(b"", unread).decode("utf-8")
        for column in (
            "KEEPER",
            "LIFECYCLE",
            "TURN STEP",
            "IDLE",
            "LAST OUTCOME",
            "DIAGNOSIS",
        ):
            if column not in unread_plain:
                raise AssertionError(
                    f"Lanes did not draw the {column!r} column: {unread_plain!r}"
                )
        if not wait_for_fixture_event(
            process, master_fd, output, gate.requested, timeout=10.0
        ):
            raise AssertionError("Lanes did not request the composite snapshot")

        empty = release_and_wait_for_frame(
            process,
            master_fd,
            output,
            gate,
            b"(no keeper lane snapshots)",
        )
        if b"MASC Lanes" not in empty or b"(0 keepers)" not in empty:
            raise AssertionError(f"Lanes did not draw the empty reading: {empty!r}")

        fixtures[KEEPER_LANES_PATH] = (503, {"error": "lane fixture failed"})
        failed = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"(load failed; nothing here is a reading)",
        )
        if b"keeper lanes load failed" not in failed:
            raise AssertionError(f"Lanes hid the load error: {failed!r}")

        # Lane order intentionally differs from the canonical roster, whose
        # cursor still points at beta. Detail navigation must join kl_keeper
        # to k_name; copying either numeric cursor would open beta for alpha.
        fixtures[KEEPER_LANES_PATH] = keeper_lanes_response(
            [
                keeper_lane_row(
                    "beta",
                    phase="new_phase",
                    turn_phase="new_turn",
                    idle_seconds=3661,
                    runtime_state=None,
                    selected_model=None,
                    diagnosis=None,
                ),
                keeper_lane_row(
                    "alpha",
                    phase="running",
                    turn_phase="executing",
                    idle_seconds=75,
                    runtime_state="done",
                    selected_model="claude-opus-5",
                    diagnosis="running_fiber_alive",
                ),
            ]
        )
        populated = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"new_phase",
        )
        banded_beta = re.compile(rb"\x1b\[7m[^\x1b\n]*beta")
        if banded_beta.search(populated) is None:
            raise AssertionError(
                f"Lanes did not band the cursor row: {populated!r}"
            )
        # Lifecycle colour is a pointer, not a band over the whole status
        # word. This is the real refreshed Lanes frame: the green SGR must end
        # immediately after the running glyph, before the producer-owned word.
        running_mark_only = re.compile(
            rb"alpha[^\r\n]*\x1b\[[0-9;]*m"
            rb"\xe2\x97\x8f\x1b\[0m running"
        )
        if running_mark_only.search(populated) is None:
            raise AssertionError(
                f"Lanes did not limit lifecycle colour to the glyph: {populated!r}"
            )
        banded_alpha = re.compile(rb"\x1b\[7m[^\x1b\n]*alpha")
        send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            banded_alpha,
        )
        send_and_wait(process, master_fd, output, b"k", banded_beta)
        # "/" arms the row search on any surface with row texts: the footer
        # shows the query, typing jumps the cursor live, Enter keeps the
        # query for n. The list itself never narrows.
        send_and_wait(process, master_fd, output, b"/", b"/  j/k:move")
        send_and_wait(process, master_fd, output, b"alp", banded_alpha)
        send_and_wait(process, master_fd, output, b"\rk", banded_beta)
        send_and_wait(process, master_fd, output, b"n", banded_alpha)
        # A lane names its keeper, so the row under the cursor is followable.
        # This surface answered None before, which left Ctrl-] doing nothing on
        # a screen that had the id in hand.
        copy_reference(process, master_fd, output, b"masc://keepers/alpha")
        plain = CSI_RE.sub(b"", populated).decode("utf-8")
        for needle in (
            "MASC Lanes (2 keepers)",
            "alpha",
            "running",
            "executing",
            "1m",
            "done",
            "claude-opus-5",
            "running_fiber_alive",
            "beta",
            "new_phase",
            "new_turn",
            "1h",
        ):
            if needle not in plain:
                raise AssertionError(f"Lanes did not draw {needle!r}: {plain!r}")

        fixtures[KEEPER_LANES_PATH] = (503, {"error": "lane refresh failed"})
        send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"keeper lanes load failed",
        )
        # The error row inserts above the Keeper rows, so only the rows at or
        # below it repaint; the header -- whose timestamp may not have ticked
        # -- can legitimately be absent from the slice send_and_wait returns
        # (#31288). A resize forces a full redraw, and the assertion reads
        # that complete frame instead. The band streams after the error row.
        stale = resize_and_wait(
            process,
            master_fd,
            output,
            rows=29,
            columns=140,
            needle=banded_alpha,
            controls=(FULL_REDRAW,),
        )
        stale_plain = CSI_RE.sub(b"", stale).decode("utf-8")
        for needle in (
            "MASC Lanes (2 keepers)",
            "alpha",
            "beta",
        ):
            if needle not in stale_plain:
                raise AssertionError(
                    f"Lanes did not preserve {needle!r} after refresh failure: "
                    f"{stale_plain!r}"
                )
        if "nothing here is a reading" in stale_plain:
            raise AssertionError(
                "Lanes discarded the prior reading after refresh failure: "
                f"{stale_plain!r}"
            )

        # A later successful reading can shrink the list. The old numeric
        # cursor was 1; retaining it would leave no selected row and make the
        # advertised detail key a no-op. The logical alpha selection survives
        # at its new index 0.
        fixtures[KEEPER_LANES_PATH] = keeper_lanes_response(
            [
                keeper_lane_row(
                    "alpha",
                    phase="running",
                    turn_phase="executing",
                    idle_seconds=75,
                    runtime_state="done",
                    selected_model="claude-opus-5",
                    diagnosis="running_fiber_alive",
                )
            ]
        )
        shrunk = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"(1 keepers)",
        )
        if banded_alpha.search(shrunk) is None:
            raise AssertionError(
                "successful lane shrink left no selected Keeper row: "
                f"{shrunk!r}"
            )
        # k from the first Keeper row walks up onto the observation matrix's
        # last lane. A refresh must leave the band there: landing the Keeper
        # cursor unconditionally dragged the selection down into the table on
        # every tick, which made the standalone drill-down unreachable in
        # practice. The fixture's idle cell changes ("1m" -> "1h") so the
        # refresh's arrival is observable; an unchanged reading redraws
        # nothing, and an empty diff would leave the needle wait hanging.
        banded_verifier = re.compile(rb"\x1b\[7m[^\x1b\n]*Verifier")
        send_and_wait(process, master_fd, output, b"k", banded_verifier)
        fixtures[KEEPER_LANES_PATH] = keeper_lanes_response(
            [
                keeper_lane_row(
                    "alpha",
                    phase="running",
                    turn_phase="executing",
                    idle_seconds=3661,
                    runtime_state="done",
                    selected_model="claude-opus-5",
                    diagnosis="running_fiber_alive",
                )
            ]
        )
        send_and_wait(process, master_fd, output, b"r", b"1h")
        drain_until_quiet(process, master_fd, output)
        standalone_refresh = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=140,
            needle=b"Verifier",
            controls=(FULL_REDRAW,),
        )
        if banded_verifier.search(standalone_refresh) is None:
            raise AssertionError(
                "refresh dragged the standalone selection into the Keeper "
                f"table: {standalone_refresh!r}"
            )
        # Verifier is a real drill-down now: task/Goal review registries are
        # joined server-side before pagination, so the list carries the
        # subject and verdict and detail carries durable tool evidence.
        fixtures[lane_runs_path("verifier_exact")] = verifier_lane_runs_response()
        fixtures[
            "/api/v1/dashboard/exact-lane-runs/vrf-fixture"
        ] = verifier_lane_run_detail_response()
        verifier_runs = send_and_wait(
            process, master_fd, output, b"\r", b"rejected"
        )
        verifier_runs_plain = CSI_RE.sub(b"", verifier_runs)
        if b"task task-9" not in verifier_runs_plain:
            raise AssertionError(
                f"Verifier run list did not name its task subject: {verifier_runs!r}"
            )
        verifier_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE (2 CALLS)",
        )
        verifier_detail_plain = CSI_RE.sub(b"", verifier_detail)
        for evidence in (
            b"DECISION  REJECTED",
            b"INPUT \xc2\xb7 VERIFICATION REQUEST",
        ):
            if evidence not in verifier_detail_plain:
                raise AssertionError(
                    "Verifier detail omitted its split decision/tool summary "
                    f"{evidence!r}: {verifier_detail!r}"
                )
        assert_verifier_tool_color_summary(verifier_detail)
        split_heading = next(
            (
                line
                for line in verifier_detail_plain.splitlines()
                if b"INPUT \xc2\xb7 VERIFICATION REQUEST" in line
                and b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE" in line
            ),
            None,
        )
        if split_heading is None or b"\xe2\x94\x82" not in split_heading:
            raise AssertionError(
                "Verifier detail did not draw Input and Output on one split row: "
                f"{verifier_detail!r}"
            )
        scrolled_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            b"INPUT \xc2\xb7 VERIFICATION REQUEST  2-",
        )
        scrolled_detail_plain = CSI_RE.sub(b"", scrolled_detail)
        scrolled_heading = next(
            (
                line
                for line in scrolled_detail_plain.splitlines()
                if b"INPUT \xc2\xb7 VERIFICATION REQUEST  2-" in line
            ),
            None,
        )
        if (
            scrolled_heading is None
            or b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE (2 CALLS)  2-"
            not in scrolled_heading
        ):
            raise AssertionError(
                "Lane detail did not scroll both evidence panes together: "
                f"{scrolled_detail!r}"
            )
        send_and_wait(
            process,
            master_fd,
            output,
            b"k",
            b"INPUT \xc2\xb7 VERIFICATION REQUEST  1-",
        )
        stacked_detail = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=100,
            needle=b"INPUT \xc2\xb7 VERIFICATION REQUEST",
            controls=(FULL_REDRAW,),
        )
        stacked_detail_plain = CSI_RE.sub(b"", stacked_detail)
        if not any(
            b"INPUT \xc2\xb7 VERIFICATION REQUEST" in line
            for line in stacked_detail_plain.splitlines()
        ) or any(
            b"INPUT \xc2\xb7 VERIFICATION REQUEST" in line
            and b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE" in line
            for line in stacked_detail_plain.splitlines()
        ):
            raise AssertionError(
                "Narrow Lane detail did not fold the comparison into one column: "
                f"{stacked_detail!r}"
            )
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[6~",
            b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE (2 CALLS)",
        )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=140,
            needle=b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE (2 CALLS)",
            controls=(FULL_REDRAW,),
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"rejected")
        send_and_wait(process, master_fd, output, b"\x1b", banded_verifier)
        # One k walks the band from Verifier to Librarian, whose run list is
        # the exact-output summary.
        banded_librarian = re.compile(rb"\x1b\[7m[^\x1b\n]*Librarian")
        send_and_wait(process, master_fd, output, b"k", banded_librarian)
        # PgDn moves the run cursor by a page and the window must follow
        # (#31290): before the follow, the selected row walked off the frame
        # while the footer kept claiming scroll 0. The fetch caps the list at
        # 50 (lane_run_list_limit), and 50 rows are taller than one window,
        # so the scroll note renders and names the window's offset.
        fixtures[lane_runs_path("librarian_exact")] = lane_runs_response(
            "librarian_exact", 50
        )
        run_list = send_and_wait(
            process, master_fd, output, b"\r", b"[50 runs, scroll 0]"
        )
        if re.search(rb"\x1b\[7m[^\x1b\n]*lr-000", run_list) is None:
            raise AssertionError(
                f"run list did not band its first row: {run_list!r}"
            )
        paged = send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[6~",
            re.compile(rb"\[50 runs, scroll [1-9]"),
        )
        if re.search(rb"\x1b\[7m[^\x1b\n]*lr-\d\d\d", paged) is None:
            raise AssertionError(
                f"PgDn left the selected run off the frame: {paged!r}"
            )
        send_and_wait(process, master_fd, output, b"\x1b", banded_librarian)
        # Back on the last standalone row, so the j below still lands on the
        # first Keeper row.
        send_and_wait(process, master_fd, output, b"j", banded_verifier)
        # j past the last standalone row lands back on the first Keeper row.
        send_and_wait(process, master_fd, output, b"j", banded_alpha)
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=140,
            needle=b"(1 keepers)",
        )
        chat_get_counts = history.served, memory.served, file_changes.served
        lane_chat = send_and_wait(
            process,
            master_fd,
            output,
            b"c",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        lane_chat_plain = CSI_RE.sub(b"", lane_chat)
        if b"Esc:Lanes" not in lane_chat_plain:
            raise AssertionError(
                f"chat opened from Lanes did not name its return: {lane_chat!r}"
            )
        wait_for_fixture_served(
            process,
            master_fd,
            output,
            history,
            after=chat_get_counts[0],
            description="alpha chat history GET",
        )
        wait_for_fixture_served(
            process,
            master_fd,
            output,
            memory,
            after=chat_get_counts[1],
            description="alpha memory journal GET",
        )
        wait_for_fixture_served(
            process,
            master_fd,
            output,
            file_changes,
            after=chat_get_counts[2],
            description="alpha chat file changes GET",
        )
        lanes_return = send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b",
            b"(1 keepers)",
        )
        if banded_alpha.search(lanes_return) is None:
            raise AssertionError(
                "Esc from lane chat did not preserve the selected lane: "
                f"{lanes_return!r}"
            )
        right_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[C",
            b"Keepers \xe2\x96\xb8 \x1b[1malpha",
        )
        # The detail pane pads labels to 22 columns ("  %-22s"), so the plain
        # text is "Name:" + 18 spaces + "alpha" -- a literal "Name: alpha"
        # needle can never match. (This suite is not wired into CI, so the
        # drift went unnoticed since #30915.)
        if re.search(rb"Name:\s+alpha", CSI_RE.sub(b"", right_detail)) is None:
            raise AssertionError(
                "Right did not open the selected lane's existing Keeper detail: "
                f"{right_detail!r}"
            )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        palette_go(process, master_fd, output, b"go lanes", b"MASC Lanes")
        enter_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Keepers \xe2\x96\xb8 \x1b[1malpha",
        )
        if re.search(rb"Name:\s+alpha", CSI_RE.sub(b"", enter_detail)) is None:
            raise AssertionError(
                "Enter did not preserve the lane-to-Keeper selection: "
                f"{enter_detail!r}"
            )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        palette_go(process, master_fd, output, b"go lanes", b"MASC Lanes")
        orphan_count = 24
        fixtures[KEEPER_LANES_PATH] = keeper_lanes_response(
            [
                keeper_lane_row(
                    f"orphan-{index:02d}",
                    phase="running",
                    turn_phase="idle",
                    idle_seconds=0,
                    runtime_state=None,
                    selected_model=None,
                    diagnosis=None,
                )
                for index in range(orphan_count)
            ]
        )
        orphan = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"orphan-00",
        )
        os.write(master_fd, b"j" * (orphan_count - 1))
        wait_for_terminal_input_consumed(slave_fd)
        drain_until_quiet(process, master_fd, output)
        orphan_name = f"orphan-{orphan_count - 1:02d}".encode()
        orphan = resize_and_wait(
            process,
            master_fd,
            output,
            rows=32,
            columns=140,
            needle=orphan_name,
            controls=(FULL_REDRAW,),
        )
        banded_orphan = re.compile(rb"\x1b\[7m[^\x1b\n]*" + re.escape(orphan_name))
        if banded_orphan.search(orphan) is None:
            raise AssertionError(f"orphan lane was not selected: {orphan!r}")
        chat_get_counts = history.served, memory.served, file_changes.served
        os.write(master_fd, b"c")
        wait_for_terminal_input_consumed(slave_fd)
        drain_until_quiet(process, master_fd, output)
        # NOTE: the repaint is driven by SIGWINCH, and XNU only signals when
        # the size actually changes -- a same-size TIOCSWINSZ produces no
        # redraw and this wait would hang. The row counts below step 32/29/30/31
        # so each resize is a real change.
        # The error line renders above the Keeper rows, so waiting on it
        # returns mid-frame; wait on the scroll note instead (it streams
        # after) and check the error text in the accumulated frame. The band
        # cannot be the needle here: the 32 -> 29 shrink leaves the scroll at
        # 11 while only ~10 Keeper rows fit, so the selected orphan-23 row is
        # legitimately below the window -- the table re-follows the cursor on
        # the next move, not on resize.
        orphan_after_c = resize_and_wait(
            process,
            master_fd,
            output,
            rows=29,
            columns=140,
            needle=b"keepers, scroll",
            controls=(FULL_REDRAW,),
        )
        if (
            b"Cannot open chat: Keeper orphan-23 is not registered"
            not in CSI_RE.sub(b"", orphan_after_c)
        ):
            raise AssertionError(
                f"unmatched lane c did not surface its error: {orphan_after_c!r}"
            )
        # A refresh must not wipe an unread action error: Lanes_loaded's Ok
        # arm cleared lanes_action_error on every tick, so the notice vanished
        # before the operator could read it. The fixture's idle cell changes
        # ("0s" -> "1h") so the refresh's arrival is observable, and the
        # resize then forces a full redraw of the post-refresh state -- the
        # error line is only proven present if it is in that frame.
        fixtures[KEEPER_LANES_PATH] = keeper_lanes_response(
            [
                keeper_lane_row(
                    f"orphan-{index:02d}",
                    phase="running",
                    turn_phase="idle",
                    idle_seconds=3661,
                    runtime_state=None,
                    selected_model=None,
                    diagnosis=None,
                )
                for index in range(orphan_count)
            ]
        )
        send_and_wait(process, master_fd, output, b"r", b"1h")
        refreshed_with_error = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=140,
            needle=b"keepers, scroll",
            controls=(FULL_REDRAW,),
        )
        if (
            b"Cannot open chat: Keeper orphan-23 is not registered"
            not in CSI_RE.sub(b"", refreshed_with_error)
        ):
            raise AssertionError(
                f"refresh wiped the unread action error: {refreshed_with_error!r}"
            )
        if chat_get_counts != (
            history.served,
            memory.served,
            file_changes.served,
        ):
            raise AssertionError("unmatched lane c loaded another Keeper's chat data")
        os.write(master_fd, b"k")
        wait_for_terminal_input_consumed(slave_fd)
        drain_until_quiet(process, master_fd, output)
        moved_from_error = resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=140,
            needle=b"orphan-22",
            controls=(FULL_REDRAW,),
        )
        if b"Cannot open chat" in CSI_RE.sub(b"", moved_from_error):
            raise AssertionError("moving the lane cursor kept a stale action error")
        if re.search(rb"\x1b\[7m[^\x1b\n]*orphan-22", moved_from_error) is None:
            raise AssertionError(
                f"moving after the action error lost its selected row: {moved_from_error!r}"
            )
        os.write(master_fd, b"q")

    return interact


def keeper_lanes_ia_interaction(
    gate: GatedHttpResponse, fixtures: HttpFixtures
) -> Interaction:
    """Keeper composite facts live on Keepers; Lanes is Standalone-only."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Keepers")
        send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            keeper_row_selected(b"beta"),
        )
        if not wait_for_fixture_event(
            process, master_fd, output, gate.requested, timeout=10.0
        ):
            raise AssertionError("Keepers did not request the composite snapshot")
        keepers = release_and_wait_for_frame(
            process, master_fd, output, gate, b"OPERATIONS"
        )
        keepers_plain = CSI_RE.sub(b"", keepers).decode("utf-8")
        for needle in (
            "OPERATIONS",
            "lifecycle failing",
            "turn executing",
            "idle 59m",
            "last done",
            "failing_unhealthy",
        ):
            if needle not in keepers_plain:
                raise AssertionError(
                    f"Keepers did not draw composite fact {needle!r}: "
                    f"{keepers_plain!r}"
                )

        palette_go(process, master_fd, output, b"go lanes", b"MASC Lanes")
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=220,
            needle=b"Standalone LLM lanes",
            controls=(FULL_REDRAW,),
        )
        # The resize clears the screen and repaints the lane list -- ten rows
        # -- and the selected lane's detail arrives in a later frame. So the
        # frame that carries the list carries none of the detail below it,
        # and the reading waits for the frames to stop before asking the
        # screen.
        drain_until_quiet(process, master_fd, output)
        lanes_plain = screen_text(bytes(output)).decode("utf-8")
        if "MASC Lanes · Standalone" not in lanes_plain:
            raise AssertionError(
                f"Lanes did not name the standalone scope: {lanes_plain!r}"
            )
        for duplicate in ("TURN STEP", "LAST OUTCOME", "DIAGNOSIS"):
            if duplicate in lanes_plain:
                raise AssertionError(
                    f"Lanes still repeated Keeper column {duplicate!r}: "
                    f"{lanes_plain!r}"
                )
        for detail in (
            "Judges one durable Board candidate for Keeper attention.",
            "Config: [runtime.exact_output_lanes.board_attention_exact]",
            "Catalog attempts (admitted order): 1 glm-coding.glm-5-turbo",
            "Then CLI (after catalog exhaustion): (none)",
            "Lane configuration is TOML. Run Input/Output is retained JSON evidence.",
            "Output meaning: the accepted candidate judgment JSON.",
            "Evidence: structured-output generation, not a MASC tool loop;",
        ):
            if detail not in lanes_plain:
                raise AssertionError(
                    f"Lanes omitted selected-lane detail {detail!r}: "
                    f"{lanes_plain!r}"
                )

        banded_hitl = re.compile(rb"\x1b\[7m[^\x1b\n]*HITL Auto Judge")
        banded_librarian = re.compile(rb"\x1b\[7m[^\x1b\n]*Librarian")
        banded_verifier = re.compile(rb"\x1b\[7m[^\x1b\n]*Verifier")
        banded_board = re.compile(rb"\x1b\[7m[^\x1b\n]*Board Attention")
        send_and_wait(process, master_fd, output, b"j", banded_hitl)
        send_and_wait(process, master_fd, output, b"j", banded_librarian)
        send_and_wait(process, master_fd, output, b"j", banded_verifier)
        verifier_runs = send_and_wait(
            process, master_fd, output, b"\r", b"task task-9"
        )
        if b"rejected" not in CSI_RE.sub(b"", verifier_runs):
            raise AssertionError(
                f"Verifier run list omitted its rejection: {verifier_runs!r}"
            )
        verifier_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE (2 CALLS)",
        )
        verifier_detail_plain = CSI_RE.sub(b"", verifier_detail)
        for evidence in (
            b"DECISION  REJECTED",
            b"SKILLS  none",
        ):
            if evidence not in verifier_detail_plain:
                raise AssertionError(
                    f"Verifier detail omitted {evidence!r}: {verifier_detail!r}"
                )
        assert_verifier_tool_color_summary(verifier_detail)
        narrow_detail = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=28,
            needle=b"TOOLS",
            controls=(FULL_REDRAW,),
        )
        if (
            b"\x1b[1mTOOLS\x1b[0m \x1b[91m\x1b[7m\x1b[1m \xe2\x9c\x97"
            not in narrow_detail
        ):
            raise AssertionError(
                "Ultra-narrow Verifier detail clipped the worst Tool severity "
                f"before its badge: {narrow_detail!r}"
            )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=220,
            needle=b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE (2 CALLS)",
            controls=(FULL_REDRAW,),
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"rejected")
        send_and_wait(process, master_fd, output, b"\x1b", banded_verifier)
        send_and_wait(process, master_fd, output, b"k", banded_librarian)
        send_and_wait(process, master_fd, output, b"k", banded_hitl)
        send_and_wait(process, master_fd, output, b"\r", b"succeeded")
        hitl_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"GATE RESOLUTION  NOT PROVEN BY THIS RUN",
        )
        hitl_detail_plain = CSI_RE.sub(b"", hitl_detail)
        for evidence in (
            b"DECISION  NOT A VERDICT",
            b"JUDGMENT  ADVISORY APPROVE",
            b"TOOLS  none",
            b"SKILLS  none",
        ):
            if evidence not in hitl_detail_plain:
                raise AssertionError(
                    f"HITL detail omitted {evidence!r}: {hitl_detail!r}"
                )
        compact_hitl_detail = resize_and_wait(
            process,
            master_fd,
            output,
            # 14 surface rows plus navigation; this fixture's agenda is silent
            # and the composer yields its row at this minimum size.
            rows=15,
            columns=220,
            needle=b"Left / Esc",
            controls=(FULL_REDRAW,),
        )
        if b"Left / Esc" not in CSI_RE.sub(b"", compact_hitl_detail):
            raise AssertionError(
                "Minimum-height HITL detail clipped its footer: "
                f"{compact_hitl_detail!r}"
            )
        compact_narrow_hitl_detail = resize_and_wait(
            process,
            master_fd,
            output,
            # 14 surface rows plus navigation; this fixture's agenda is silent
            # and the composer yields its row at this minimum size.
            rows=15,
            columns=100,
            needle=b"Left / Esc",
            controls=(FULL_REDRAW,),
        )
        if b"Left / Esc" not in CSI_RE.sub(b"", compact_narrow_hitl_detail):
            raise AssertionError(
                "Minimum-height narrow HITL detail clipped its footer: "
                f"{compact_narrow_hitl_detail!r}"
            )
        fixtures[
            "/api/v1/dashboard/exact-lane-runs/hitl-fixture"
        ] = (503, {"error": "stale hitl detail"})
        compact_narrow_refresh_error = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"lane run detail returned 503",
        )
        compact_narrow_refresh_error_plain = CSI_RE.sub(
            b"", compact_narrow_refresh_error
        )
        stale_evidence = (
            b"lane run detail returned 503",
            b"JUDGMENT  ADVISORY APPROVE",
            b"Left / Esc",
        )
        for evidence in stale_evidence:
            if evidence not in compact_narrow_refresh_error_plain:
                raise AssertionError(
                    "Minimum-height narrow stale HITL detail clipped evidence "
                    f"{evidence!r}: {compact_narrow_refresh_error!r}"
                )
        compact_wide_refresh_error = resize_and_wait(
            process,
            master_fd,
            output,
            # 14 surface rows plus navigation; this fixture's agenda is silent
            # and the composer yields its row at this minimum size.
            rows=15,
            columns=220,
            needle=b"Left / Esc",
            controls=(FULL_REDRAW,),
        )
        compact_wide_refresh_error_plain = CSI_RE.sub(
            b"", compact_wide_refresh_error
        )
        for evidence in stale_evidence:
            if evidence not in compact_wide_refresh_error_plain:
                raise AssertionError(
                    "Minimum-height wide stale HITL detail clipped evidence "
                    f"{evidence!r}: {compact_wide_refresh_error!r}"
                )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=220,
            needle=b"GATE RESOLUTION  NOT PROVEN BY THIS RUN",
            controls=(FULL_REDRAW,),
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"succeeded")
        send_and_wait(process, master_fd, output, b"\x1b", banded_hitl)
        send_and_wait(process, master_fd, output, b"k", banded_board)
        send_and_wait(
            process,
            master_fd,
            output,
            b"c",
            b"Standalone lanes have no Keeper; use Keepers",
        )
        config = send_and_wait(
            process,
            master_fd,
            output,
            b"e",
            b"runtime.exact_output_lanes.board_attention_exact",
        )
        config_plain = CSI_RE.sub(b"", config).decode("utf-8")
        if 'slots = ["glm-coding.glm-5-turbo"]' not in config_plain:
            raise AssertionError(
                f"Lanes e did not land on the selected TOML table: {config_plain!r}"
            )
        os.write(master_fd, b"q")

    return interact


FILE_CHANGES_ALPHA_PATH = "/api/v1/keepers/alpha/file-changes?window_hours=24"
FILE_CHANGES_BETA_PATH = "/api/v1/keepers/beta/file-changes?window_hours=24"


def file_changes_alpha_response() -> tuple[int, dict[str, object]]:
    return (
        200,
        {
            "keeper": "alpha",
            "window_hours": 24.0,
            "calls_in_window": 3,
            "changes": [
                {
                    "at": 1787600000.0,
                    "keeper": "alpha",
                    "turn": 7,
                    "task_id": "task-1",
                    "location": {
                        "kind": "repo",
                        "repo_id": "masc",
                        "path": "lib/example.ml",
                    },
                    "change": {
                        "kind": "edit",
                        "before": "let a = 1",
                        "after": "let a = 2",
                    },
                    "succeeded": True,
                },
                # A second row, so the arrow keys have somewhere to go. With
                # one row the marked row and the window's top row are the same
                # index whether or not the code keeps them apart.
                {
                    "at": 1787600100.0,
                    "keeper": "alpha",
                    "turn": 9,
                    "task_id": "task-9",
                    "location": {
                        "kind": "repo",
                        "repo_id": "masc",
                        "path": "lib/second.ml",
                    },
                    "change": {
                        "kind": "edit",
                        "before": "let b = 1",
                        "after": "let b = 2\nlet c = 3",
                    },
                    "succeeded": True,
                },
                {
                    "at": 1787600200.0,
                    "keeper": "alpha",
                    "turn": 11,
                    "task_id": "task-11",
                    "location": {
                        "kind": "repo",
                        "repo_id": "masc",
                        "path": "lib/long.ml",
                    },
                    "change": {
                        "kind": "edit",
                        "before": "let x = 0",
                        # Taller than the diff view, so the view has somewhere
                        # to scroll and says how far it scrolled.
                        "after": "\n".join(f"let x{n} = {n}" for n in range(40)),
                    },
                    "succeeded": True,
                },
            ],
            "over_budget": 0,
            "malformed": 0,
        },
    )


def file_changes_beta_response() -> tuple[int, dict[str, object]]:
    status, payload = file_changes_alpha_response()
    payload["keeper"] = "beta"
    change = cast(list[dict[str, Any]], payload["changes"])[0]
    change["keeper"] = "beta"
    change["turn"] = 8
    change["task_id"] = "task-2"
    cast(dict[str, Any], change["location"])["path"] = "lib/beta.ml"
    change["change"] = {
        "kind": "edit",
        "before": "let beta = false",
        "after": "let beta = true",
    }
    payload["changes"] = [change]
    return status, payload


def open_changes(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
) -> bytes:
    """Reach the Changes surface the way the key map says it is reached.

    Changes is not on the Tab ring -- test_tui_keys pins that with
    "Changes is not a top-level ring entry" -- it is a Keepers child opened
    with [f] ("files: file changes this keeper wrote"). These scenarios tabbed
    for it, which walks the ring past a surface that is not on it, so they
    could not arrive however many presses they were given.
    """
    tab_until(process, master_fd, output, b"MASC Keepers")
    return send_and_wait(process, master_fd, output, b"f", b"masc:lib/example.ml")


def changes_keeper_and_arrow_detail_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    open_changes(process, master_fd, output)
    # The cursor row's diff previews under the list without Enter -- the
    # recorded before/after pair, rendered locally.
    wait_for_output(
        process, master_fd, output, b"preview masc:lib/example.ml",
        start=0, timeout=3.0,
    )
    preview_plain = CSI_RE.sub(b"", bytes(output)).decode("utf-8")
    for needle in ("EDIT", "APPLIED", "-1 +1", "let a = 1", "let a = 2"):
        if needle not in preview_plain:
            raise AssertionError(
                f"the preview missed {needle!r}: {preview_plain[-600:]!r}"
            )
    raw = bytes(output)
    for badge in (b"EDIT", b"APPLIED"):
        if re.search(rb"\x1b\[[0-9;]*m" + badge + rb"[^\x1b]*\x1b\[0m", raw) is None:
            raise AssertionError(f"Changes badge {badge!r} was not highlighted")
    # Down moves the marked row, not just the window. The mark used to be the
    # window's top row, so on a list that fits the screen it could not move at
    # all and Enter opened the first change whatever the operator pressed.
    second = send_and_wait(
        process, master_fd, output, b"\x1b[B", b"preview masc:lib/second.ml"
    )
    second_plain = CSI_RE.sub(b"", second).decode("utf-8")
    for needle in ("-1 +2", "let b = 1", "let c = 3"):
        if needle not in second_plain:
            raise AssertionError(
                f"down did not move the mark to the second change ({needle!r} "
                f"missing): {second_plain[-600:]!r}"
            )
    second_diff = send_and_wait(
        process, master_fd, output, b"\x1b[C", b"turn 9  task task-9  applied"
    )
    second_diff_plain = CSI_RE.sub(b"", second_diff).decode("utf-8")
    for needle in ("MASC Change", "masc:lib/second.ml", "let c = 3"):
        if needle not in second_diff_plain:
            raise AssertionError(
                f"right opened a diff that is not the marked row ({needle!r} "
                f"missing): {second_diff_plain!r}"
            )
    # The row that says how to leave. The screen tallied its own chrome one
    # row short, which put it a row over its budget, and a surface over budget
    # loses its last rows -- the footer being the last of them. Nothing else
    # on this screen names the key that closes it.
    if "open in editor" not in second_diff_plain:
        raise AssertionError(
            f"the diff drew no footer: {second_diff_plain[-800:]!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b[D", b"TURN")
    # An open diff scrolls to its end and stops there. The keypress steps
    # without a bound -- the rows are the drawing's -- so the frame reports
    # what it could use and the loop stores that. Without the report the
    # stored value kept climbing, and coming back up took one press per step
    # taken past the end.
    send_and_wait(
        process, master_fd, output, b"\x1b[B", b"preview masc:lib/long.ml"
    )
    tall = send_and_wait(
        process, master_fd, output, b"\x1b[C", b"turn 11  task task-11  applied"
    )
    if b"scroll 0]" not in CSI_RE.sub(b"", tall):
        raise AssertionError(
            f"the tall diff did not open at the top: {CSI_RE.sub(b'', tall)!r}"
        )
    mark = len(output)
    os.write(master_fd, b"j" * 60)
    wait_for_terminal_input_consumed(slave_fd)
    drain_until_quiet(process, master_fd, output)
    settled = CSI_RE.sub(b"", bytes(output[mark:])).decode("utf-8")
    at_end = re.findall(r"scroll (\d+)\]", settled)
    if not at_end:
        raise AssertionError(
            f"the tall diff drew no scroll indicator: {settled[-800:]!r}"
        )
    bottom = int(at_end[-1])
    if bottom == 0:
        raise AssertionError(
            f"the tall diff did not scroll at all: {settled[-800:]!r}"
        )
    send_and_wait(
        process, master_fd, output, b"k", f"scroll {bottom - 1}]".encode("ascii")
    )
    send_and_wait(process, master_fd, output, b"\x1b[D", b"TURN")
    send_and_wait(
        process, master_fd, output, b"\x1b[A", b"preview masc:lib/second.ml"
    )
    send_and_wait(
        process, master_fd, output, b"\x1b[A", b"preview masc:lib/example.ml"
    )
    beta = send_and_wait(process, master_fd, output, b"]", b"masc:lib/beta.ml")
    if b"MASC Changes beta" not in CSI_RE.sub(b"", beta):
        raise AssertionError(f"Changes did not switch to beta: {beta!r}")
    alpha = send_and_wait(process, master_fd, output, b"[", b"masc:lib/example.ml")
    if b"MASC Changes alpha" not in CSI_RE.sub(b"", alpha):
        raise AssertionError(f"Changes did not switch back to alpha: {alpha!r}")
    detail = send_and_wait(process, master_fd, output, b"\x1b[C", b"-1 +1")
    if b"MASC Change" not in CSI_RE.sub(b"", detail):
        raise AssertionError(f"Right did not open the selected diff: {detail!r}")
    listing = send_and_wait(process, master_fd, output, b"\x1b[D", b"TURN")
    if b"MASC Changes alpha" not in CSI_RE.sub(b"", listing):
        raise AssertionError(f"Left did not return to the Changes list: {listing!r}")
    # v opens the row's file on the Code surface, read through the keeper's
    # own workspace (?keeper=alpha), so the header names whose tree it is
    # and the bytes arrive lexed.
    code = send_and_wait(
        process, master_fd, output, b"v", LEXED_LET
    )
    code_plain = CSI_RE.sub(b"", code).decode("utf-8")
    if "alpha ▸ repos/masc/lib" not in code_plain:
        raise AssertionError(
            f"the Code header does not name the keeper workspace: {code_plain!r}"
        )
    if "example.ml" not in code_plain:
        raise AssertionError(f"the jumped file is not open: {code_plain!r}")
    os.write(master_fd, b"q")


def keeper_gate_mode_footer_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    tab_until(process, master_fd, output, b"MASC Keepers")
    footer = resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=200,
        needle=re.compile(rb"g\x1b\[0m auto"),
        final_cursor=b"\x1b[?25l",
    )
    if b"g yolo" in CSI_RE.sub(b"", footer):
        raise AssertionError(f"YOLO mode still advertised the wrong action: {footer!r}")
    os.write(master_fd, b"q")


def enter_outside_changes_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """Enter pressed off the Changes surface must not arm its diff view.

    The widened Enter arm sent Acting/Approvals/Schedules/Verify/Harness into
    the Changes handler; with changes loaded, coming back to Changes then drew
    a diff nobody opened. Lanes now owns Enter, so this no-op guard uses Acting.
    """
    populated = open_changes(process, master_fd, output)
    populated_plain = CSI_RE.sub(b"", populated).decode("utf-8")
    if "MASC Changes" not in populated_plain:
        raise AssertionError(
            f"Changes did not draw the fixture row as a list: {populated_plain!r}"
        )
    acting = tab_until(process, master_fd, output, b"MASC Activity")
    if b"MASC Activity" not in acting:
        raise AssertionError(f"did not reach Activity: {acting!r}")
    # System logs hang off Activity under [l]; Esc walks back to the parent.
    send_and_wait(process, master_fd, output, b"l", b"[1 Events | 2 Logs*]")
    send_and_wait(process, master_fd, output, b"1", b"[1 Events* | 2 Logs]")
    send_and_wait(process, master_fd, output, b"2", b"[1 Events | 2 Logs*]")
    send_and_wait(process, master_fd, output, b"\x1b", b"[1 Events* | 2 Logs]")
    os.write(master_fd, b"\r")
    back = open_changes(process, master_fd, output)
    back_plain = CSI_RE.sub(b"", back).decode("utf-8")
    if "TURN" not in back_plain:
        raise AssertionError(
            "returning to Changes did not draw the list columns; Enter on "
            f"Acting armed a view it does not own: {back_plain!r}"
        )
    # What says a diff is open is the diff view's own frame, not a pair of
    # counts: the marked row previews its diff under the list now, so "-1 +1"
    # is what an unopened list looks like.
    if "esc closes" in back_plain:
        raise AssertionError(
            "returning to Changes drew a diff nobody opened; Enter on Acting "
            f"reached the Changes handler: {back_plain!r}"
        )
    os.write(master_fd, b"q")




WORKSPACE_TREE_ROOT_PATH = "/api/v1/workspace/children?path=&limit=2000"
WORKSPACE_CHILDREN_LIB_PATH = "/api/v1/workspace/children?path=lib&limit=2000"
WORKSPACE_FILE_AML_PATH = "/api/v1/workspace/file?path=lib/a.ml"


def code_lane_fixtures() -> HttpFixtures:
    fixtures = keeper_runtime_http_fixtures()
    fixtures[WORKSPACE_TREE_ROOT_PATH] = (
        200,
        [
            {"path": "lib", "label": "lib", "depth": 0, "parent": "",
             "hasChildren": True, "diff": None, "keeperId": None,
             "hueIndex": None},
            {"path": "README.md", "label": "README.md", "depth": 0,
             "parent": "", "hasChildren": False, "diff": None,
             "keeperId": None, "hueIndex": None},
        ],
    )
    fixtures[WORKSPACE_CHILDREN_LIB_PATH] = (
        200,
        [
            {"path": "lib/a.ml", "label": "a.ml", "depth": 1, "parent": "lib",
             "hasChildren": False, "diff": None, "keeperId": None,
             "hueIndex": None},
        ],
    )
    file_response = (
        200, {"ok": True, "content": "let x = 1\n(* hi *)\nlet y = x\n"})
    fixtures[WORKSPACE_FILE_AML_PATH] = file_response
    # uri's Query_value encoding may or may not spell the slash; serve both.
    fixtures["/api/v1/workspace/file?path=lib%2Fa.ml"] = file_response
    history_response = (
        200,
        {
            "ok": True,
            "commits": [
                {"hash": "abc1234", "timestamp_ms": 1787000000000,
                 "author": "keeper-alpha", "subject": "feat: add x"},
                {"hash": "def5678", "timestamp_ms": 1786900000000,
                 "author": "vincent", "subject": "chore: seed the file"},
            ],
        },
    )
    fixtures["/api/v1/git/log?path=lib/a.ml&limit=50"] = history_response
    fixtures["/api/v1/git/log?path=lib%2Fa.ml&limit=50"] = history_response
    diff_response = (
        200,
        {
            "has_changes": True,
            "unified": [
                {"kind": "delete", "oldLine": 1, "newLine": None,
                 "text": "let a = 1"},
                # The added row is the working tree's line 1, so its text
                # agrees with the file fixture -- the renderer now resolves
                # it back to the lexed row by that number.
                {"kind": "add", "oldLine": None, "newLine": 1,
                 "text": "let x = 1"},
            ],
        },
    )
    for diff_path in (
        "/api/v1/git/diff?path=lib/a.ml&base_ref=HEAD",
        "/api/v1/git/diff?path=lib%2Fa.ml&base_ref=HEAD",
    ):
        fixtures[diff_path] = diff_response
    hover_response = (200, {"ok": True, "data": {"kind": "hover", "text": "int"}})
    definition_response = (
        200,
        {"ok": True, "data": {"kind": "locations", "locations": [
            {"path": "lib/a.ml", "inside_workspace": True, "line": 2,
             "character": 1},
        ]}},
    )
    y_definition_response = (
        200,
        {"ok": True, "data": {"kind": "locations", "locations": [
            {"path": "lib/a.ml", "inside_workspace": True, "line": 1,
             "character": 5},
        ]}},
    )
    for enc in ("lib/a.ml", "lib%2Fa.ml"):
        fixtures[
            f"/api/v1/lsp/question?question=hover&path={enc}&line=1&symbol=x"
        ] = hover_response
        fixtures[
            f"/api/v1/lsp/question?question=definition&path={enc}&line=1&symbol=x"
        ] = definition_response
        fixtures[
            f"/api/v1/lsp/question?question=definition&path={enc}&line=3&symbol=y"
        ] = y_definition_response
    return fixtures


CODE_MEMO_FILE_PATH = "/api/v1/workspace/file?path=init.lua"
# The gutter mark a memo row wears (RFC-0429 §3.1); a Keeper's own change
# wears a dimmer one, so the two are told apart by glyph.
MEMO_GUTTER_MARK = "\u25cf".encode()
# What the title says while the cursor sits on the memo's line. Truncated by
# the frame if the pane is narrow, so the needle stops well before the end of
# the memo's text.
MEMO_CURSOR_RIDER = b"memo alpha (decision) keep the coroutine"

CODE_MEMO_SOURCE = (
    "local lock = 1\n"
    "-- masc(alpha) decision: keep the coroutine, the pool is single threaded\n"
    "local function read() return lock end\n"
)


def code_memo_fixtures() -> HttpFixtures:
    """A Lua file with a memo in it. Lua has no lexer in the TUI, so this is
    the case the memo list used to miss: it read only rows the lexer had
    marked as a comment, and an unlexed file has none."""
    fixtures = keeper_runtime_http_fixtures()
    fixtures[WORKSPACE_TREE_ROOT_PATH] = (
        200,
        [
            {"path": "init.lua", "label": "init.lua", "depth": 0, "parent": "",
             "hasChildren": False, "diff": None, "keeperId": None,
             "hueIndex": None},
        ],
    )
    fixtures[CODE_MEMO_FILE_PATH] = (200, {"ok": True, "content": CODE_MEMO_SOURCE})
    return fixtures


def code_memo_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """m on an open file lists the memos written in that file's own comment
    syntax. The file here is Lua, whose comments the TUI does not colour, so
    the list is the proof that the reader looks for the file's markers rather
    than for something the lexer marked."""
    palette_go(process, master_fd, output, b"go code", b"init.lua")
    send_and_wait(process, master_fd, output, b"\r", b"local lock = 1")
    # The wait needle has to be text only the overlay draws: the memo's own
    # words are line 2 of the file and are already on screen before m, so a
    # redraw arriving in the wait window would satisfy a needle taken from
    # the file pane and read the wrong frame back.
    listed = send_and_wait(process, master_fd, output, b"m", b"(decision)")
    plain = CSI_RE.sub(b"", listed).decode("utf-8")
    for needle in ("notes: init.lua", "L2", "alpha", "(decision)"):
        if needle not in plain:
            raise AssertionError(
                f"the memo list missed {needle!r}: {plain!r}"
            )
    if "no memo in this file" in plain:
        raise AssertionError(
            f"the memo list called a file with a memo empty: {plain!r}"
        )
    # The same key puts the list away and the file comes back.
    closed = send_and_wait(
        process, master_fd, output, b"m", b"local function read"
    )
    if "notes: init.lua" in CSI_RE.sub(b"", closed).decode("utf-8"):
        raise AssertionError(
            f"a second m left the memo list open: {closed!r}"
        )

    # RFC-0429 §3.1: the memo is a margin, not a replacement. With the body
    # back, the row that carries the memo wears a mark in the gutter, and
    # putting the cursor on that row says what the mark marks without opening
    # the list again. These run after the list is closed on purpose: the
    # rider repeats the memo's words in the title, and asserting them earlier
    # would let a title redraw satisfy a needle meant for the overlay.
    rows = screen_rows(bytes(output))
    memo_rows = [text for text in rows.values() if b"masc(alpha) decision" in text]
    if not memo_rows:
        raise AssertionError(f"the memo's own row is not on screen: {rows!r}")
    if not any(MEMO_GUTTER_MARK in text for text in memo_rows):
        raise AssertionError(
            f"the row carrying a memo wears no gutter mark: {memo_rows!r}"
        )

    # The memo sits on line 2 and the file opens on line 1. The needle is the
    # memo's own row: the cursor line carries its gutter in reverse video, so
    # landing there redraws that row whatever the title does. A needle taken
    # from the title would make this wait, not the assertion below, the thing
    # that notices a missing rider.
    on_the_memo = send_and_wait(process, master_fd, output, b"j", b"masc(alpha)")
    title = screen_text(bytes(output))
    if MEMO_CURSOR_RIDER not in title:
        raise AssertionError(
            "the cursor on a memo line did not say what the memo says: "
            f"{CSI_RE.sub(b'', on_the_memo)!r}"
        )
    os.write(master_fd, b"q")


def code_lane_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """The Code surface: one directory level, Enter drills, a file opens
    lexed. The keyword's yellow span and the dim gutter are the claim that
    the file was lexed, not just printed."""
    listing = palette_go(process, master_fd, output, b"go code", b"README.md")
    plain = CSI_RE.sub(b"", listing).decode("utf-8")
    for needle in ("lib", "README.md"):
        if needle not in plain:
            raise AssertionError(f"Code did not list {needle!r}: {plain!r}")
    send_and_wait(process, master_fd, output, b"\r", b"a.ml")
    # Which colour a keyword wears belongs to the theme, and the theme moves:
    # #30723 turned it bright magenta and this waited out its timeout on the
    # old yellow. What this scenario is about is that the file arrived lexed,
    # so it asks for a style around the span and not for a particular one.
    opened = send_and_wait(process, master_fd, output, b"\r", LEXED_LET)
    if re.search(rb"\x1b\[7m\s+1\x1b\[0m", opened) is None:
        raise AssertionError(
            f"the cursor line's gutter is not highlighted: {opened!r}"
        )
    if re.search(rb"\x1b\[[0-9;]*m" + re.escape(b"(* hi *)") + rb"\x1b\[0m", opened) is None:
        raise AssertionError(f"the comment did not colour: {opened!r}")
    # Shift-Right pans the open file sideways by one cell: lowercase h/l now
    # choose the split pane. The keyword span is cut mid-word but its colour
    # still opens the remainder, and the title says the view is shifted.
    panned = send_and_wait(
        process, master_fd, output, b"\x1b[1;2C\x1b[1;2C", b"(col 3)"
    )
    cut_under_style = re.compile(
        rb"\x1b\[[0-9;]*m" + re.escape(b"t") + rb"\x1b\[0m x = "
        rb"\x1b\[[0-9;]*m" + re.escape(b"1") + rb"\x1b\[0m"
    )
    if cut_under_style.search(panned) is None:
        raise AssertionError(f"pan did not cut by cells under the style: {panned!r}")
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[1;2D\x1b[1;2D",
        LEXED_LET,
    )
    # With the file focused, "/" searches its lines: typing jumps the line
    # cursor (the reverse gutter) to the match, and Enter keeps the query.
    searched = send_and_wait(process, master_fd, output, b"/hi", b"/hi")
    if re.search(rb"\x1b\[7m\s+2\x1b\[0m", searched) is None:
        raise AssertionError(
            f"the file search did not move the cursor gutter: {searched!r}"
        )
    # Enter keeps the query for n/N and closes the prompt; the redrawn
    # footer (query gone, hints back at the front) is the needle, because
    # the diff renderer resends only the rows that changed.
    send_and_wait(
        process, master_fd, output, b"\r",
        b"\x1b[2m  j/k:scroll  h/l:pan",
    )
    # d swaps the content for the working tree's diff against HEAD; Esc
    # swaps back to the lexed content.
    # The added row now arrives lexed, so the wait needle is the keyword
    # span rather than the plain text the styles split apart.
    diff_frame = send_and_wait(
        process, master_fd, output, b"d", LEXED_LET
    )
    diff_plain = CSI_RE.sub(b"", diff_frame).decode("utf-8")
    for needle in ("diff vs HEAD: lib/a.ml", "let a = 1", "let x = 1"):
        if needle not in diff_plain:
            raise AssertionError(
                f"the diff view missed {needle!r}: {diff_plain!r}"
            )
    # The added row is the working tree's own line, so it carries the
    # lexer's colours (the keyword span) inside the diff band.
    if LEXED_LET.search(diff_frame) is None:
        raise AssertionError(
            f"the added diff row lost the lexer's colours: {diff_frame!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", LEXED_LET)
    # H swaps the content for the commits that touched the file; Esc swaps
    # back (the lexed keyword span is the proof the content returned).
    # The needle is a commit hash so the wait crosses the "(loading
    # history)" frame and lands on the fetched listing.
    history = send_and_wait(process, master_fd, output, b"H", b"abc1234")
    history_plain = CSI_RE.sub(b"", history).decode("utf-8")
    for needle in ("history: lib/a.ml", "feat: add x", "def5678", "vincent"):
        if needle not in history_plain:
            raise AssertionError(
                f"history missed {needle!r}: {history_plain!r}"
            )
    if "Left / Esc:back" not in history_plain:
        raise AssertionError(
            f"history footer does not offer the way back: {history_plain!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", LEXED_LET)
    # The search above left the cursor on line 2; the lsp fixtures answer
    # about line 1, so put the cursor back where the question is.
    send_and_wait(process, master_fd, output, b"k", b"\x1b[7m   1\x1b[0m")
    # The cursor line holds one name (let is a keyword, 1 a number), so K
    # asks about it at once -- no palette between the keypress and the
    # answer beside the title.
    send_and_wait(process, master_fd, output, b"K", b"x: int")
    # D likewise jumps straight to the definition; the answer is inside the
    # same file, so the cursor (the reverse gutter) moves to its line.
    landed = send_and_wait(process, master_fd, output, b"D", b"x: lib/a.ml:2")
    if re.search(rb"\x1b\[7m\s+2\x1b\[0m", landed) is None:
        raise AssertionError(
            f"the definition jump did not move the cursor gutter: {landed!r}"
        )
    # B walks back to where the jump left from: the cursor gutter returns
    # to line 1.
    returned = send_and_wait(
        process, master_fd, output, b"B",
        re.compile(rb"\x1b\[7m\s+1\x1b\[0m"),
    )
    if re.search(rb"\x1b\[7m\s+2\x1b\[0m", returned) is not None:
        raise AssertionError(
            f"B left the cursor on the jumped-to line: {returned!r}"
        )
    # A line with several names (let y = x) opens the palette with each as
    # an entry instead of guessing one.
    send_and_wait(
        process, master_fd, output, b"jj",
        re.compile(rb"\x1b\[7m\s+3\x1b\[0m"),
    )
    choices = send_and_wait(process, master_fd, output, b"D", b"[Enter] Ask")
    choices_plain = CSI_RE.sub(b"", choices).decode("utf-8")
    if ("definition" not in choices_plain or "2 names on line 3" not in choices_plain
            or "▸ y" not in choices_plain
            or re.search(r"│\s+x\s+│", choices_plain) is None):
        raise AssertionError(
            f"the candidate list missed the second name: {choices!r}"
        )
    # Enter alone runs the highlighted candidate (y): the answer names
    # the location and the cursor jumps to it.
    picked = send_and_wait(
        process, master_fd, output, b"\r", b"y: lib/a.ml:1"
    )
    if re.search(rb"\x1b\[7m\s+1\x1b\[0m", picked) is None:
        raise AssertionError(
            f"the candidate jump did not move the cursor gutter: {picked!r}"
        )
    os.write(master_fd, b"q")


RUNTIME_PROBE_PATH = "/api/v1/dashboard/runtime-probe"
RUNTIME_PROBE_FORCE_PATH = f"{RUNTIME_PROBE_PATH}?force=1"
RUNTIME_RESOLVED_PATH = "/api/v1/runtime/resolved"
RUNTIME_CONFIG_RAW_PATH = "/api/v1/runtime/config/raw"


def runtime_config_read_metadata() -> dict[str, object]:
    return {
        "ok": True,
        "source_revision": "fixture-read-revision",
        "validation": {
            "valid": True, "schema_version": 1, "current_schema_version": 1,
            "forward_schema": False, "issues": [],
        },
        "application": {
            "operation": "read",
            "routing": {"status": "active", "requires_restart": False},
            "keeper_overlay": {
                "status": "pending_restart", "configured_count": 1,
                "requires_restart": True, "pending_keys": ["keeper.pending"],
                "applied_keys": [], "preempted_keys": [],
            },
        },
    }


def config_navigation_source() -> str:
    lines = [
        "# operator notes stay visible",
        "first-value = 1",
        "# another note",
        "",
        "second-value = 2",
    ]
    lines.extend(f"# context row {index}" for index in range(5, 27))
    lines.extend(
        [
            "[models.alpha]",
            "temperature = 0.7",
            'reasoning-effort = "high"',
            "# model comment",
            "[ollama_cloud.alpha]",
            "max-tokens = 16384",
        ]
    )
    return "\n".join(lines)


def config_navigation_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Config")
        wait_for_output(
            process,
            master_fd,
            output,
            b"first-value = ",
            start=0,
            timeout=3.0,
        )

        status = send_and_wait(
            process, master_fd, output, b"v", b"Pending restart: keeper.pending"
        )
        status_plain = CSI_RE.sub(b"", status)
        for needle in (b"fixture-read-revision", b"Validation: valid", b"Keeper restart: required"):
            if needle not in status_plain:
                raise AssertionError(f"Config status omitted {needle!r}: {status_plain!r}")
        send_and_wait(
            process, master_fd, output, b"r", b"fixture-reloaded-revision"
        )
        # Source-only input must not open an editor or a hidden-source search.
        # If / stole focus, v would become search text instead of returning.
        # Nothing should happen, which is the whole point -- so there is no
        # new frame to wait for. A frame carries the rows that changed, and
        # inert keys change none; waiting for the title to arrive again
        # starves on a screen that is already correct. Read the screen.
        os.write(master_fd, b"e/")
        time.sleep(0.4)
        read_available(master_fd, output)
        if b"runtime.toml status" not in screen_text(bytes(output)):
            raise AssertionError(
                "e or / moved the Config status screen: "
                f"{screen_text(bytes(output))!r}"
            )
        reloaded_source = send_and_wait(process, master_fd, output, b"v", b"first-value = ")
        if b"first-value = 9" not in CSI_RE.sub(b"", reloaded_source):
            raise AssertionError("Config reload changed revision without its new source")

        next_field = send_and_wait(
            process, master_fd, output, b"j", b"second-value = "
        )
        if b"second-value = " not in CSI_RE.sub(b"", next_field):
            raise AssertionError("j did not skip comments and blank rows")

        page_down = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"temperature = "
        )
        if b"temperature = " not in CSI_RE.sub(b"", page_down):
            raise AssertionError("PgDn did not land on the next page's value")

        page_up = send_and_wait(
            process, master_fd, output, b"\x1b[5~", b"second-value = "
        )
        if b"second-value = " not in CSI_RE.sub(b"", page_up):
            raise AssertionError("PgUp did not return to the previous value")

        models = send_and_wait(process, master_fd, output, b"p", b"MASC Models")
        models_plain = CSI_RE.sub(b"", models)
        for needle in (b"temperature", b"0.7", b"high", b"16384"):
            if needle not in models_plain:
                raise AssertionError(
                    f"Models pane omitted {needle!r}: {models_plain!r}"
                )
        os.write(master_fd, b"q")

    return interact


def runtime_probe_provider(
    runtime_id: str,
    *,
    status: str,
) -> dict[str, object]:
    cli = status == "skipped_cli"
    reachable = status == "reachable"
    failed = not cli and not reachable
    return {
        "runtime_id": runtime_id,
        "provider_id": f"probe-{runtime_id}",
        "provider_display_name": "Probe label must not render",
        "model_id": f"probe-model-{runtime_id}",
        "model_api_name": f"probe-api-{runtime_id}",
        "protocol": "openai",
        "runtime_kind": "cli" if cli else "http",
        "transport": "cli" if cli else "http",
        "auth_kind": "none",
        "credential_required": False,
        "auth_present": False,
        "status": status,
        "reachable": None if cli else reachable,
        "http_status": 200 if reachable else None,
        "latency_ms": None if cli else (18.0 if reachable else 41.0),
        "model_count": 4 if reachable else None,
        "content_type": "application/json" if reachable else None,
        "downloaded_bytes": 256 if reachable else None,
        "endpoint_url": None if cli else "https://runtime.invalid/v1",
        "probe_url": None if cli else "https://runtime.invalid/v1/models",
        "error": (
            "CLI runtimes do not expose an HTTP reachability endpoint"
            if cli
            else ("connection refused" if failed else None)
        ),
        "checked_at": "2026-08-24T10:20:00Z",
    }


def runtime_probe_response(*, fresh: bool) -> HttpResponse:
    providers = [
        runtime_probe_provider("runtime-a", status="reachable"),
        runtime_probe_provider("runtime-b", status="skipped_cli"),
        runtime_probe_provider(
            "runtime-c",
            status="reachable" if fresh else "network_error",
        ),
    ]
    failed = 0 if fresh else 1
    return (
        200,
        {
            "generated_at": "2026-08-24T10:20:01Z",
            "refreshed_at_unix": 1787566800.0,
            "cache_ttl_sec": 15.0,
            "cache_age_sec": 1.0 if fresh else 16.0,
            "cache_hit": fresh,
            "refresh_state": "fresh" if fresh else "served_stale",
            "probe": {
                "source": "runtime.toml",
                # The overall probe status is written from Health_status, which
                # spells the healthy reading "ok". "reachable" belongs to the
                # per-provider vocabulary a few lines below and is not a word
                # this field can carry, so a fixture using it here fails the
                # snapshot decode -- and that failure is an inner result, so
                # the surface keeps the previous reading and only marks the
                # header "read failed" rather than saying what broke.
                "status": "ok" if fresh else "degraded",
                "probe_ok": fresh,
                "checked_at": "2026-08-24T10:20:00Z",
                "summary": {
                    "runtimes": 3,
                    "probed": 2,
                    "reachable": 2 if fresh else 1,
                    "failed": failed,
                    "skipped": 1,
                    "default_runtime_id": "runtime-a",
                },
                "providers": providers,
                "errors": [] if fresh else ["runtime-c: network_error"],
                "observations": ["provider metadata endpoints only"],
                "limitations": ["no completion request"],
            },
        },
    )


def runtime_resolved_runtime(
    runtime_id: str,
    provider: str,
    model: str,
) -> dict[str, object]:
    return {
        "id": runtime_id,
        "provider": provider,
        "model": model,
        "effective_max_context": 200_000,
        "max_context_source": "capability",
        "max_output_tokens": 8192,
        "is_local": False,
        # This binding flag is independent of the fleet's top-level default.
        "is_default": False,
        "keeper_dispatchable": True,
        "keeper_dispatch_blocked_reason": None,
    }


def runtime_resolved_response() -> HttpResponse:
    runtime_a = runtime_resolved_runtime("runtime-a", "Resolved A", "model-a")
    return (
        200,
        {
            "generated_at_iso": "2026-08-24T10:20:02Z",
            "source": RUNTIME_RESOLVED_PATH,
            "config_path": "/workspace/config/runtime.toml",
            "default_runtime": runtime_a,
            "runtimes": [
                runtime_a,
                runtime_resolved_runtime("runtime-b", "Resolved B", "model-b"),
                runtime_resolved_runtime("runtime-c", "Resolved C", "model-c"),
                runtime_resolved_runtime("runtime-d", "Resolved D", "model-d"),
                runtime_resolved_runtime("runtime-e", "Resolved E", "model-e"),
            ],
            "lanes": [
                {
                    "id": "primary",
                    "runtime_ids": ["runtime-a", "runtime-b"],
                    "preferred_candidate": "runtime-b",
                    "preferred_at_ts": 1787566700.0,
                },
                {
                    "id": "degraded",
                    "runtime_ids": ["runtime-c"],
                    "preferred_candidate": None,
                    "preferred_at_ts": None,
                },
                {
                    "id": "unobserved",
                    "runtime_ids": ["runtime-d"],
                    "preferred_candidate": None,
                    "preferred_at_ts": None,
                },
            ],
            "assignments": [
                {
                    "keeper": "sangsu",
                    "assignment_source": "default",
                    "resolved": {"kind": "lane", "id": "primary"},
                }
            ],
        },
    )


def runtime_http_fixtures() -> tuple[
    HttpFixtures,
    GatedHttpResponse,
    SequencedHttpResponse,
]:
    fixtures = overview_event_http_fixtures()
    initial_probe = GatedHttpResponse(
        runtime_probe_response(fresh=False),
        subsequent_response=runtime_probe_response(fresh=True),
    )
    force_probe = SequencedHttpResponse(
        [(503, {"error": "forced probe refresh failed"})]
    )
    fixtures[RUNTIME_PROBE_PATH] = initial_probe
    fixtures[RUNTIME_PROBE_FORCE_PATH] = force_probe
    fixtures[RUNTIME_RESOLVED_PATH] = runtime_resolved_response()
    return fixtures, initial_probe, force_probe


def runtime_surface_interaction(
    fixtures: HttpFixtures,
    initial_probe: GatedHttpResponse,
    force_probe: SequencedHttpResponse,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            # Runtime is a Config child. Verify the parent before opening it;
            # keep [9] bare so the probe request is observed after [start].
            tab_until(process, master_fd, output, b"MASC Config")
            read_available(master_fd, output)
            start = len(output)
            os.write(master_fd, b"9")  # Config -> Runtime
            if not wait_for_fixture_event(
                process, master_fd, output, initial_probe.requested, timeout=10.0
            ):
                raise AssertionError("Runtime did not request provider probe")
            # Several 50 ms ticks pass while the authenticated probe is held.
            # The resolved request may finish, but the joined generation must
            # remain single-flight until both authorities settle.
            time.sleep(0.2)
            if initial_probe.calls != 1:
                raise AssertionError(
                    "Runtime stacked probe reads while one was in flight: "
                    f"{initial_probe.calls} calls"
                )
            initial_probe.release.set()
            wait_for_output(
                process,
                master_fd,
                output,
                b"network_error",
                start=start,
                timeout=3.0,
            )
            stale_end = output.find(b"network_error", start) + len(b"network_error")
            wait_for_output(
                process,
                master_fd,
                output,
                FRAME_END,
                start=stale_end,
                timeout=3.0,
            )
            stale_frame_end = output.find(FRAME_END, stale_end) + len(FRAME_END)
            stale_plain = CSI_RE.sub(b"", bytes(output[start:stale_frame_end])).decode(
                "utf-8"
            )
            for needle in (
                "MASC Config / Runtime",
                "LANE",
                "CANDIDATE",
                "PROVIDER / MODEL",
                "ROUTE / PROBE",
                "primary",
                "1/2 runtime-a",
                "Resolved A / model-a",
                "ready / reachable",
                "CLI not probed",
                "last success",
                "unobserved",
                "single candidate",
            ):
                if needle not in stale_plain:
                    raise AssertionError(
                        f"Runtime did not draw {needle!r}: {stale_plain!r}"
                    )
            if "Probe label must not render" in stale_plain:
                raise AssertionError(
                    f"Runtime used probe identity instead of resolved SSOT: {stale_plain!r}"
                )

            # The next ordinary poll carries the refreshed cache value. This
            # proves served_stale is a state, not a local health inference.
            fresh_start = stale_frame_end
            wait_for_output(
                process,
                master_fd,
                output,
                b"fresh",
                start=fresh_start,
                timeout=3.0,
            )
            wait_for_output(
                process,
                master_fd,
                output,
                # The header writes the overall reading back with the word the
                # producer sent -- Health_status spells the healthy one "ok".
                # "reachable" is the per-provider word and never appears here.
                re.compile(
                    rb"ok(?:\x1b\[[0-9;]*m)* / "
                    rb"(?:\x1b\[[0-9;]*m)*fresh"
                ),
                start=fresh_start,
                timeout=3.0,
            )

            lane_detail = send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"MASC Config / Runtime detail",
            )
            lane_detail_plain = CSI_RE.sub(b"", lane_detail)
            for needle in (
                b"primary / runtime-a",
                b"Runtime ID: runtime-a",
                b"Provider: Resolved A",
                b"Model: model-a",
                b"Effective context: 200000 tokens",
                b"Context source: capability",
                b"Max output: 8192 tokens",
                b"Local runtime: no",
                b"Used by lanes: primary",
                b"Lane position: 1 of 2",
                b"Probe status: reachable",
                b"Probe transport: http",
                b"Checked at: 2026-08-24T10:20:00Z",
                b"Reachable: yes",
                b"HTTP status: 200",
                b"Latency: 18ms",
            ):
                if needle not in lane_detail_plain:
                    raise AssertionError(
                        f"Runtime lane detail omitted {needle!r}: "
                        f"{lane_detail_plain!r}"
                    )

            send_and_wait(
                process,
                master_fd,
                output,
                b"\x1b[D",
                b"CANDIDATE",
            )
            # Candidate identity also appears in the detail. Wait for the
            # list-only column header, then inspect the replayed screen.
            lane_screen = screen_text(bytes(output))
            if b"1/2 runtime-a" not in lane_screen:
                raise AssertionError("Runtime list lost the selected lane candidate")
            if b"MASC Config / Runtime detail" in lane_screen:
                raise AssertionError("Runtime left arrow did not return to the lane list")

            all_list = send_and_wait(
                process,
                master_fd,
                output,
                b"p",
                b"All runtimes (5)",
            )
            if b"runtime-a" not in CSI_RE.sub(b"", all_list):
                raise AssertionError("Runtime catalog did not keep the selected runtime")
            if b"Lanes (3 lanes, 4 slots)" not in CSI_RE.sub(b"", all_list):
                raise AssertionError("Runtime catalog counted runtimes as lane slots")
            if b"ready / reachable" not in CSI_RE.sub(b"", all_list):
                raise AssertionError("Runtime catalog omitted independent probe status")
            catalog_detail = send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"MASC Config / Runtime detail",
            )
            catalog_detail_plain = CSI_RE.sub(b"", catalog_detail)
            for needle in (
                b"Runtime ID: runtime-a",
                b"Provider: Resolved A",
                b"Model: model-a",
                b"Used by lanes: primary",
                b"Probe status: reachable",
            ):
                if needle not in catalog_detail_plain:
                    raise AssertionError(
                        f"Runtime catalog detail omitted {needle!r}: "
                        f"{catalog_detail_plain!r}"
                    )
            send_and_wait(process, master_fd, output, b"\x1b", b"All runtimes (5)")
            # b10d25cc12 turned [p] into a three-stop circuit: lanes tab,
            # catalog, then the standalone Lanes surface ("off the ring"),
            # and [p] there returns to the lanes tab. The old two-stop step
            # waited for the tab header right after leaving the catalog and
            # starved on the standalone surface instead, whose header stays
            # "(not loaded)" because this fixture serves no
            # /api/v1/dashboard/standalone-lanes body. Walk the full circuit
            # so the return leg is what gets asserted.
            send_and_wait(process, master_fd, output, b"p", b"MASC Lanes")
            send_and_wait(process, master_fd, output, b"p", b"Lanes (3 lanes, 4 slots)")

            # The overflow scroll hint is unreachable with this fixture: it
            # renders only when candidates exceed the listing height, but the
            # compact-frame gate (minimum_fixed_chrome_rows = 14) replaces any
            # viewport short enough for 4 candidates to overflow. A hint
            # assertion would need a 6+ candidate fixture at a viable height.
            # A shorter-but-viable pass proves the listing survives resize.
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=20,
                columns=100,
                needle=b"MASC Config / Runtime",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=30,
                columns=100,
                needle=b"MASC Config / Runtime",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )

            fixtures[RUNTIME_PROBE_PATH] = (503, {"error": "probe refresh failed"})
            read_available(master_fd, output)
            refresh_start = len(output)
            os.write(master_fd, b"r")
            # Prove the key reached Runtime's forced-probe endpoint. A
            # generic listing refresh used to intercept lowercase r, leaving
            # only ordinary polls and never reaching this request.
            wait_for_fixture_served(
                process,
                master_fd,
                output,
                force_probe,
                after=0,
                description="Runtime r forced provider probe",
            )
            # The next ordinary poll can replace the force failure's wording;
            # both must leave the failed reading visible with the prior rows.
            wait_for_output(
                process, master_fd, output, b"runtime probe load failed",
                start=refresh_start, timeout=3.0,
            )
            if force_probe.served != 1:
                raise AssertionError(
                    "Runtime did not coalesce manual refresh into one force request: "
                    f"{force_probe.served} calls"
                )
            preserved = resize_and_wait(
                process,
                master_fd,
                output,
                rows=30,
                columns=99,
                needle=b"runtime-a",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            preserved_plain = CSI_RE.sub(b"", preserved)
            for needle in (b"runtime probe load failed", b"runtime-a", b"runtime-d"):
                if needle not in preserved_plain:
                    raise AssertionError(
                        f"Runtime discarded its prior rows after failure: {preserved_plain!r}"
                    )
            # Verify the selected parent pane and its Runtime entry remain
            # visible at 99 columns, even when later pane names are clipped.
            config_start = len(output)
            send_and_wait(
                process, master_fd, output, b"\x1b", "▸runtime.toml".encode()
            )
            if b"9:Runtime" not in CSI_RE.sub(b"", bytes(output[config_start:])):
                raise AssertionError("Config hides its Runtime entry at 99 columns")
            os.write(master_fd, b"q")
            completed = True
        finally:
            initial_probe.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


SCHEDULES_PATH = "/api/v1/dashboard/scheduled-automation"


def schedule_detail_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    fixtures[SCHEDULES_PATH] = (
        200,
        {
            "status": "ok",
            "schedule_store_read_error": None,
            "request_count": 1,
            "truncated": False,
            "fsm": {"next_due_at_iso": "2026-08-25T10:30:00Z"},
            "requests": [
                {
                    "schedule_instance_id": "instance-proof-701",
                    "schedule_id": "schedule-proof-701",
                    "status": "running",
                    "source": "operator",
                    "requested_by": {
                        "id": "operator-701",
                        "kind": "human_operator",
                        "display_name": "Operator Proof",
                    },
                    "scheduled_by": {
                        "id": "keeper-701",
                        "kind": "automated_actor",
                        "display_name": None,
                    },
                    "requested_at_iso": "2026-08-25T09:00:00Z",
                    "due_at_iso": "2026-08-25T10:00:00Z",
                    "next_due_at_iso": "2026-08-25T10:30:00Z",
                    "expires_at_iso": "2026-08-26T10:00:00Z",
                    # The loader requires this beside the summary. It was
                    # missing until 2026-09-08: the scenario that reads this
                    # fixture sits behind the stall in the default keyboard
                    # lane (#34125), so nothing rejected it.
                    "recurrence": {"kind": "interval", "interval_sec": 1800},
                    "recurrence_summary": "every 30 minutes",
                    "payload_digest": "digest-proof-701",
                    "payload": {
                        "kind": "masc.keeper_wake",
                        "body": {
                            "keeper_name": "alpha",
                            "title": "detailed scheduled sweep",
                        },
                    },
                    "payload_kind": "keeper_wake",
                    "payload_support": "supported",
                    "payload_dispatch_tool": "keeper_wake",
                    "payload_target": "alpha",
                    "payload_summary": "Run the detailed scheduled sweep.",
                    "last_wake": {
                        "status": "succeeded",
                        "started_at_iso": "2026-08-25T09:30:00Z",
                        "error": None,
                    },
                    "keeper_queue_evidence": {
                        "projection_status": "matched_pending",
                        "pending_count": 2,
                    },
                    "keeper_reaction_evidence": {
                        "projection_status": "matched_consumed_ack",
                        "keeper_name": "alpha",
                        "stimulus_id": "schedule-stimulus-proof-701",
                        "post_id": "schedule-occurrence-proof-701",
                        "reaction_kind": "turn_started",
                        "stimulus_seen": True,
                        "turn_started_seen": True,
                        "event_queue_ack_seen": True,
                        "event_queue_cancelled_seen": False,
                        "quarantined_record_count": 0,
                        "stimulus_recorded_at_iso": "2026-08-25T09:30:10Z",
                        "turn_started_recorded_at_iso": "2026-08-25T09:30:20Z",
                        "event_queue_ack_recorded_at_iso": "2026-08-25T09:31:00Z",
                        "event_queue_cancelled_recorded_at_iso": None,
                        "latest_recorded_at_iso": "2026-08-25T09:31:00Z",
                        "reason": None,
                    },
                }
            ],
        },
    )
    fixtures[SCHEDULES_PATH + "?schedule_id=schedule-proof-701"] = (
        200,
        {"status": "found", "schedule_id": "schedule-proof-701",
         "wakes": [{"status": "succeeded", "started_at_iso": "2026-08-25T09:30:00Z",
                    "finished_at_iso": "2026-08-25T09:30:01Z", "error": None}],
         "wake_retention_per_schedule": 32},
    )
    return fixtures


def schedule_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        listing = palette_go(
            process, master_fd, output, b"go schedules", b"MASC Schedules"
        )
        listing_plain = CSI_RE.sub(b"", listing)
        for needle in (
            b"wake:succeeded",
            # What became of the wake, on the row itself. The enqueue result
            # beside it is "succeeded" on a wake the queue cancelled forty
            # seconds later, so the list said nothing about delivery until
            # the cursor was moved onto the row. The separator is part of the
            # needle because the word alone also appears in the reaction line
            # below the list, which is the surface this is not testing.
            "\u00b7consumed_ack".encode(),
            # The list used to carry a dispatch chip beside these. #31562
            # dropped it because it only ever repeated the row's own status,
            # which the identity line above the delivery row already names.
            b"status:running",
            b"queue:matched_pending/2 pending",
            b"reaction:matched_consumed_ack",
        ):
            if needle not in listing_plain:
                raise AssertionError(
                    f"Schedule list omitted {needle!r}: {listing_plain!r}"
                )
        detail = send_and_wait(
            process, master_fd, output, b"\x1b[C", b"instance-proof-701"
        )
        plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"masc://schedules/schedule-proof-701",
            b"masc://keepers/alpha",
            b"Dispatch",
            b"Operator Proof (human_operator)",
            b"keeper_wake",
            b"digest-proof-701",
            b"PgUp/PgDn:page",
        ):
            if needle not in plain:
                raise AssertionError(f"Schedule detail omitted {needle!r}: {plain!r}")
        copy_reference(
            process,
            master_fd,
            output,
            b"masc://schedules/schedule-proof-701",
        )
        evidence = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"WAKES (1 retained"
        )
        evidence_plain = CSI_RE.sub(b"", evidence)
        for needle in (
            b"WAKES (1 retained, ceiling 32 per schedule)",
            b"DELIVERY EVIDENCE",
            b"pending=2",
            b"matched_consumed_ack",
        ):
            if needle not in evidence_plain:
                raise AssertionError(
                    f"Schedule wake/delivery page omitted {needle!r}: {evidence_plain!r}"
                )
        # Delivery identity and the work-result boundary follow the queue
        # summary. Read their page rather than treating one viewport as all
        # retained evidence; the operator can reach both with PgDn.
        result_page = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"Keeper Calls or Activity"
        )
        result_plain = CSI_RE.sub(b"", result_page)
        for needle in (
            b"Keeper evidence",
            b"masc://keepers/alpha",
            b"schedule-stimulus-proof-701",
            b"schedule-occurrence-proof-701",
            b"2026-08-25T09:30:20",
            b"Turn finished",
            b"WORK RESULT",
            b"bounded by its start and finish rows",
            b"Keeper Calls or Activity",
        ):
            if needle not in result_plain:
                raise AssertionError(
                    f"Schedule turn/result page omitted {needle!r}: {result_plain!r}"
                )
        returned = send_and_wait(process, master_fd, output, b"\x1b[D", b"j/k:move")
        returned_plain = CSI_RE.sub(b"", returned)
        for needle in (b"schedule-proof-701", b"status:running", b"queue:matched_pending/2 pending"):
            if needle not in returned_plain:
                raise AssertionError(f"Left did not restore the selected Schedule row: {returned_plain!r}")
        # The harness is 100 columns wide. Padding the id to a reserved width
        # used to push the instruction tail past the box border, so require
        # the words an operator needs to press the key a second time.
        send_and_wait(
            process,
            master_fd,
            output,
            b"x",
            b"armed: cancel schedule-proof-701 -- same key again to send",
        )
        os.write(master_fd, b"q")

    return interact


FUSION_RUNS_PATH = "/api/v1/dashboard/fusion-runs"


def fusion_run(
    run_id: str,
    *,
    keeper: str,
    status: str = "completed",
) -> dict[str, object]:
    return {
        "run_id": run_id,
        "keeper": keeper,
        "preset": "trio",
        "topology": "simple",
        "started_at": 1787557669.715736,
        "finished_at": None if status == "running" else 1787557684.715736,
        "status": status,
        "stage": "accepted" if status == "running" else status,
        "progress": {} if status == "running" else None,
    }


# The Registry list fits a run id into a 14-cell column, so what it draws is
# the truncated head with the pane's "~" marker after it. The full id is what
# the detail pane and the copy links carry, and those assertions keep it.
FUSION_TARGET_LISTED = b"fusion-target"


def fusion_runs_response(runs: list[dict[str, object]]) -> HttpResponse:
    return (
        200,
        {
            "generated_at": "2026-08-24T09:00:00Z",
            "count": len(runs),
            "replay": {"status": "not_replayed"},
            "historical_evidence": [],
            "runs": runs,
        },
    )


def fusion_detail_response(run: dict[str, object], judge_reason: str) -> HttpResponse:
    run_id = str(run["run_id"])
    return (
        200,
        {
            "generated_at": "2026-08-24T09:00:01Z",
            "run": run,
            "evidence": {
                "status": "recorded",
                "post": {
                    "id": f"post-{run_id}",
                    "title": f"Fusion evidence for {run_id}",
                    "origin": {
                        "source": "fusion",
                        "fusion_run_id": run_id,
                    },
                    "meta": {
                        "question": "question-proof-501",
                        "panel": [
                            {
                                "model": "panel-first-501",
                                "status": "answered",
                                "answer": "panel-answer-first-501",
                                "input_tokens": 10,
                                "output_tokens": 20,
                            },
                            {
                                "model": "panel-second-501",
                                "status": "failed",
                                "reason_code": "timeout",
                                "reason_detail": "panel-failure-second-501",
                            },
                        ],
                        "judge": {
                            "status": "synthesized",
                            "decision": "answer",
                            "resolved_answer": "judge-resolved-501",
                            "synthesis": judge_reason,
                        },
                        # RFC-0284 judge nodes: a judge-of-judges run's
                        # first-pass lenses and the meta above them. The
                        # canonical single judge stays -- the array is the
                        # additive observation the TUI detail renders.
                        "judges": [
                            {
                                "role": "first",
                                "identity": "ollama_cloud.minimax-m3",
                                "status": "synthesized",
                                "decision": "answer",
                                "resolved_answer": "first-evidence-resolved-501",
                                "synthesis": "first-evidence-synthesis-501",
                                "input_tokens": 30,
                                "output_tokens": 40,
                            },
                            {
                                "role": "first",
                                "identity": "ollama_cloud.deepseek-v4-pro",
                                "status": "failed",
                                "error": "first judge body timed out",
                                "failure_code": "timeout",
                                "input_tokens": 50,
                                "output_tokens": 0,
                                "elapsed_s": None,
                                "timed_out": True,
                            },
                            {
                                "role": "meta",
                                "identity": "meta",
                                "status": "synthesized",
                                "decision": "answer",
                                "resolved_answer": "meta-evidence-resolved-501",
                                "synthesis": "meta-evidence-synthesis-501",
                                "input_tokens": 60,
                                "output_tokens": 70,
                            },
                        ],
                        # Required since #32512: the wire always carries the
                        # tool trace, and an empty ledger says "complete with
                        # nothing observed" without dropping the field.
                        "tool_trace": {
                            "status": "complete",
                            "observed_actors": [],
                            "dropped_events": 0,
                            "gaps": [],
                            "events": [],
                        },
                    },
                },
            },
        },
    )


def fusion_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    alpha = fusion_run("fusion-alpha-501", keeper="alpha")
    target = fusion_run("fusion-target-501", keeper="beta")
    new = fusion_run("fusion-new-501", keeper="gamma")
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/dashboard/planning"] = (
        200,
        {
            "goals": [
                {
                    "id": "goal-ssim-501",
                    "title": "raise SSIM to 0.95",
                    "phase": "executing",
                    "priority": 1,
                    "metric": "SSIM",
                    "target_value": "0.95",
                    "proof": {"state": "unreviewed"},
                }
            ],
            "rollup": {"active": 1, "verifying": 0, "done": 0, "dropped": 0},
            "backlog": {
                "todo": 1,
                "claimed": 0,
                "running": 0,
                "done": 0,
                "cancelled": 0,
            },
            "generated_at": "2026-08-27T00:00:00Z",
        },
    )
    fixtures["/api/v1/dashboard/harness-health"] = (
        200,
        {
            "generated_at": 1787557669.0,
            "recent_verdicts": [
                {
                    "timestamp": 1787557668.0,
                    "task_id": "task-linked-501",
                    "task_title": "linked Harness task",
                    "agent_name": "beta",
                    "gate": "verify",
                    "verdict": "approve",
                    "evaluator_runtime": "glm-coding",
                    "fallback_reason": None,
                    # SHA256(task_title + "\n" + completion_notes). The
                    # recorder writes it on every verdict and the reader takes
                    # it as opaque, but it is required: without it the whole
                    # harness snapshot fails to decode, the surface draws
                    # "(not loaded)" with its column headers and no rows, and
                    # the footer offers no verdict key because there is no row
                    # to open.
                    "notes_hash": "a51844ac8e12b5bf11f1c6db0021521298e5788cd64e4ec9b566dbf36a16fa51",
                }
            ],
            "calibration": {},
        },
    )
    initial_runs = GatedHttpResponse(fusion_runs_response([alpha, target]))
    fixtures[FUSION_RUNS_PATH] = initial_runs
    fixtures[f"{FUSION_RUNS_PATH}/fusion-alpha-501"] = fusion_detail_response(
        alpha, "wrong-alpha-judge-501"
    )
    fixtures[f"{FUSION_RUNS_PATH}/fusion-target-501"] = fusion_detail_response(
        target, "judge-proof-501"
    )
    fixtures[f"{FUSION_RUNS_PATH}/fusion-new-501"] = fusion_detail_response(
        new, "wrong-new-judge-501"
    )
    return fixtures, initial_runs


def seed_goal_linked_task(base_path: str) -> None:
    """Write the task the harness verdict judges, and the goal it serves.

    Tasks come off the local backlog and the goal link lives in its own
    registry -- the task record carries no goal on purpose. Both have to be on
    disk before the TUI starts or the chain has a hole at its middle hop.
    """
    tasks_dir = os.path.join(base_path, ".masc", "tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    with open(os.path.join(tasks_dir, "backlog.json"), "w", encoding="utf-8") as handle:
        json.dump(
            {
                "tasks": [
                    {
                        "id": "task-linked-501",
                        "title": "linked Harness task",
                        "status": "todo",
                        "priority": 1,
                        "created_at": "2026-08-27T00:00:00Z",
                        "updated_at": "2026-08-27T00:00:00Z",
                    }
                ],
                "last_updated": "2026-08-27T00:00:00Z",
                "version": 1,
            },
            handle,
        )
    with open(
        os.path.join(tasks_dir, "goal_task_links.json"), "w", encoding="utf-8"
    ) as handle:
        json.dump({"links": [{"goal_id": "goal-ssim-501", "task_ids": ["task-linked-501"]}]}, handle)


def fusion_list_detail_interaction(
    fixtures: HttpFixtures,
    initial_runs: GatedHttpResponse,
) -> Interaction:
    """Select by run id across reorder, then read the four-stage flow."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # Task Verdicts belongs to Planning; Tab cycles top-level families,
        # whereas v selects the three Planning tabs without skipping coverage.
        palette_go(process, master_fd, output, b"go planning", b"MASC Planning")
        send_and_wait(process, master_fd, output, b"v", b"Task Review")
        send_and_wait(process, master_fd, output, b"v", b"automatic Gate rulings")
        # One full repaint, because the pane redraws only the rows that change
        # and the column headers are written once. The assertions below are
        # about the whole list, so they need the whole list in one frame.
        harness_plain = CSI_RE.sub(
            b"",
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=30,
                columns=220,
                needle=b"EVALUATOR",
                controls=(FULL_REDRAW,),
            ),
        )
        # The column row is upper case. Spelled in title case, "Verdict" was
        # still found -- in the tab label "Task Verdicts" one row above -- so
        # only two of these three ever said anything about the list.
        for needle in (b"GATE", b"VERDICT", b"EVALUATOR"):
            if needle not in harness_plain:
                raise AssertionError(
                    f"Harness list omitted {needle!r}: {harness_plain!r}"
                )
        # The verdict key used to be asserted here. The key strip is drawn on
        # its own row and only when it changes, so it is not in the frame the
        # list rows arrive in and often not in the repaint either -- the check
        # was reading a region this frame does not carry. The Enter below opens
        # the verdict, which proves the key works rather than that it is
        # spelled on screen.
        copy_reference(
            process,
            master_fd,
            output,
            b"masc://overview/tasks/task-linked-501",
        )
        verdict = send_and_wait(
            process, master_fd, output, b"\r", b"EVALUATOR VERDICT"
        )
        verdict_plain = CSI_RE.sub(b"", verdict)
        # The verdict names a task; the task names its goals; a goal declares
        # the metric it is measured by. All three were present and none of them
        # met on a screen, so a verdict said "approve" without saying what it
        # was approving towards.
        for needle in (
            b"linked Harness task",
            b"Agent",
            b"beta",
            b"approve",
            b"glm-coding",
            b"Fallback",
            b"masc://planning/goal-ssim-501",
            b"left/Esc:list",
        ):
            if needle not in verdict_plain:
                raise AssertionError(
                    f"Harness detail omitted {needle!r}: {verdict_plain!r}"
                )
        # The verdict names a task, the task names its goals, and a goal
        # declares its metric. All three were present before and none of them
        # met on a screen. Whichever way the chain resolves, the detail has to
        # say so rather than drawing nothing -- "not linked" and "not in this
        # backlog" are different facts and both are answers.
        if not any(
            marker in verdict_plain
            for marker in (b"TOWARDS", b"Towards")
        ):
            raise AssertionError(
                f"the verdict says nothing about what it aims at: {verdict_plain!r}"
            )
        # Back on the list, whose tab label carries the count. The word came
        # off when the count was split into page and ledger: it reads "(1)"
        # here and "(8 of 4197)" against a server with a backlog.
        send_and_wait(
            process, master_fd, output, b"\x1b[D", b"\xe2\x96\xb8Task Verdicts (1)"
        )
        read_available(master_fd, output)
        start = len(output)
        os.write(master_fd, b"\t")
        if not wait_for_fixture_event(
            process, master_fd, output, initial_runs.requested, timeout=10.0
        ):
            raise AssertionError("Fusion did not request its Registry list")
        # Several periodic ticks pass while the first read is held. The TUI
        # must keep that one request authoritative instead of continually
        # superseding it with a newer generation that will also be held.
        time.sleep(0.2)
        if initial_runs.calls != 1:
            raise AssertionError(
                "Fusion stacked Registry reads while one was in flight: "
                f"{initial_runs.calls} calls"
            )
        initial_runs.release.set()
        wait_for_output(
            process,
            master_fd,
            output,
            FUSION_TARGET_LISTED,
            start=start,
            timeout=3.0,
        )
        target_end = output.find(FUSION_TARGET_LISTED, start) + len(
            FUSION_TARGET_LISTED
        )
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=target_end,
            timeout=3.0,
        )
        frame_end = output.find(FRAME_END, target_end) + len(FRAME_END)
        loaded = bytes(output[start:frame_end])
        plain = CSI_RE.sub(b"", loaded)
        for column in (
            b"STARTED",
            b"AGE",
            b"STATE",
            b"KEEPER",
            b"PRESET",
            # No TOPOLOGY column: the header row is STARTED AGE STATE KEEPER
            # PRESET RUN, and the keeper column took the width the run id used
            # to sit whole in.
            b"RUN",
            b"Flow: Question",
        ):
            if column not in plain:
                raise AssertionError(
                    f"Fusion did not draw the {column!r} source column: {plain!r}"
                )
        footer = (
            b"j/k:move  PgUp/PgDn:page  [ / ]:previous / next  "
            b"K:calling Keeper  B:Board evidence  Enter:open  "
            b"Y:copy  Esc:back  r:refresh  Tab:next  q:quit"
        )
        resize_and_wait(
            process, master_fd, output, rows=30, columns=200,
            needle=b"MASC Fusion", controls=(FULL_REDRAW,),
        )
        # The footer is one row and the resize repaints the list before it, so
        # the frame that carries the title does not carry the hints. Wait for
        # the frames to stop and read the screen.
        drain_until_quiet(process, master_fd, output)
        footer_frame = bytes(output)
        if footer not in screen_text(footer_frame):
            raise AssertionError(
                f"Fusion list footer disagrees with its exercised keys: {footer_frame!r}"
            )
        resize_and_wait(
            process, master_fd, output, rows=30, columns=120,
            needle=b"MASC Fusion", controls=(FULL_REDRAW,),
        )

        selected = send_and_wait(
            process, master_fd, output, b"j", FUSION_TARGET_LISTED
        )
        if re.search(rb">[^\r\n]*fusion-target", CSI_RE.sub(b"", selected)) is None:
            raise AssertionError(f"Fusion did not select the target run: {selected!r}")

        target = fusion_run("fusion-target-501", keeper="beta")
        new = fusion_run("fusion-new-501", keeper="gamma")
        alpha = fusion_run("fusion-alpha-501", keeper="alpha")
        fixtures[FUSION_RUNS_PATH] = fusion_runs_response([target, new, alpha])
        refreshed = send_and_wait(process, master_fd, output, b"r", b"fusion-new-501")
        if (
            re.search(rb">[^\r\n]*fusion-target", CSI_RE.sub(b"", refreshed))
            is None
        ):
            raise AssertionError(
                f"Fusion refresh moved selection off its run id: {refreshed!r}"
            )

        detail = send_and_wait(
            process, master_fd, output, b"\r", b"Flow: Question"
        )
        detail_plain = CSI_RE.sub(b"", detail)
        question_index = detail_plain.find(b"1  QUESTION")
        first_panel_index = detail_plain.find(b"2  PANEL RESPONSES")
        if question_index < 0 or first_panel_index < question_index:
            raise AssertionError(
                f"Fusion detail did not start with question then panel: {detail_plain!r}"
            )
        for needle in (
            b"masc://fusion/fusion-target-501",
            b"masc://keepers/beta",
            b"1  QUESTION",
            b"2  PANEL RESPONSES",
            b"PgUp/PgDn:page",
        ):
            if needle not in detail_plain:
                raise AssertionError(
                    f"Fusion detail omitted the {needle!r} summary: {detail_plain!r}"
                )
        copy_reference(
            process,
            master_fd,
            output,
            b"masc://fusion/fusion-target-501",
        )
        send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"panel-failure-second-501"
        )
        # The page lands over several frames -- the responses, then the judge
        # section under them -- so the frame the first row arrives in does not
        # hold the rest. Wait for the frames to stop and read the screen.
        drain_until_quiet(process, master_fd, output)
        panel_plain = screen_text(bytes(output))
        for needle in (
            b"panel-answer-first-501",
            b"panel-failure-second-501",
            b"1 answered / 1 failed",
            b"10 input / 20 output tokens",
        ):
            if needle not in panel_plain:
                raise AssertionError(
                    f"Fusion panel page omitted {needle!r}: {panel_plain!r}"
                )
        for needle in (
            b"3  JUDGE",
            b"judge-proof-501",
            # The topology was a sentence ("Judge topology: judge-of-judges")
            # and is now the row that draws it: the lens counts, then the
            # shape they add up to.
            "first ×2".encode(),
            "meta ×1".encode(),
            b"judge-of-judges",
            b"First 1 [synthesized] ollama_cloud.minimax-m3",
            b"First 2 [failed] ollama_cloud.deepseek-v4-pro",
        ):
            if needle not in panel_plain:
                raise AssertionError(
                    f"Fusion detail lost its judge section or lenses "
                    f"({needle!r}): {panel_plain!r}"
                )
        # The lens cards grew the detail past one page: the flow now ends on
        # the page after the panel one.
        tail = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"5  EVIDENCE RECORDED"
        )
        tail_plain = CSI_RE.sub(b"", tail)
        for needle in (
            b"4  TOOL EXECUTIONS",
            b"5  EVIDENCE RECORDED",
            b"masc://board/post-fusion-target-501",
        ):
            if needle not in tail_plain:
                raise AssertionError(
                    f"Fusion flow did not end with Tool then Evidence: {tail_plain!r}"
                )
        if (
            b"wrong-alpha-judge-501" in detail_plain
            or b"wrong-new-judge-501" in detail_plain
        ):
            raise AssertionError(
                f"Fusion opened the numeric cursor, not the run id: {detail_plain!r}"
            )

        send_and_wait(process, master_fd, output, b"\x1b", b"fusion-new-501")
        os.write(master_fd, b"q")

    return interact


def fusion_live_reload_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse, SequencedHttpResponse]:
    """The feed initialize is held at the gate so the frame lands while the
    operator is already on the Fusion surface.

    Releasing the gate is what makes the causality readable: with the cadence
    at its 60-second default, the only things that can fetch the run list are
    the surface entry and the status frame the stream then pushes. The list
    answer changes between the two fetches -- the second run appears -- so the
    reload draws a row that was not on the first screen.
    """
    alpha = fusion_run("fusion-alpha-601", keeper="alpha", status="running")
    target = fusion_run("fusion-target-601", keeper="beta")
    fixtures = overview_event_http_fixtures()
    mcp_initialize = GatedHttpResponse(
        RawHttpResponse(
            200,
            json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode(),
            content_type="application/json",
            headers=(("Mcp-Session-Id", "mcp_fixture_session"),),
        )
    )
    fixtures["/mcp"] = mcp_initialize
    fixtures["/mcp?sse_kind=observer"] = RawHttpResponse(
        200,
        (
            b'event: message\n'
            b'data: {"type":"fusion_run_status","run":{"run_id":"fusion-target-601",'
            b'"keeper":"beta","preset":"trio","topology":"simple",'
            b'"started_at":1787557669.7,"finished_at":1787557684.7,"status":"completed"}}\n\n'
        ),
        content_type="text/event-stream",
    )
    run_list = SequencedHttpResponse(
        [
            fusion_runs_response([alpha]),
            fusion_runs_response([alpha, target]),
        ]
    )
    fixtures[FUSION_RUNS_PATH] = run_list
    return fixtures, mcp_initialize, run_list


def fusion_live_reload_interaction(
    run_list: SequencedHttpResponse, mcp_initialize: GatedHttpResponse
) -> Interaction:
    """Tab lands on Fusion (the ring stop this scenario exists to prove), one
    status frame on the observer feed refetches the list, and the new run
    draws. Exactly two list loads in total -- the entry and the trigger."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        def list_loads() -> int:
            # HttpRequests records POST bodies; this list is fetched by GET.
            return run_list.served

        landed = tab_until(process, master_fd, output, b"fusion-alpha")
        if list_loads() != 1:
            raise AssertionError(
                f"surface entry alone should load the list once, saw {list_loads()}"
            )
        mcp_initialize.release.set()
        wait_for_output(
            process,
            master_fd,
            output,
            b"fusion-target",
            start=len(landed),
            timeout=10.0,
        )
        if list_loads() != 2:
            raise AssertionError(
                f"the status frame should reload the list exactly once, "
                f"saw {list_loads()} loads"
            )
        os.write(master_fd, b"q")

    return interact


OBSERVER_TOOL_CALLED_FRAME = (
    b"id: 1\n"
    b"event: message\n"
    b'data: {"type":"agent_core:tool_called","event_type":"tool_called",'
    b'"event_id":"evt-1","ts_unix":1787505641.28,"correlation_id":"trace-1",'
    b'"run_id":"wr-1","parent_event_id":null,"agent_name":"alpha",'
    b'"task_id":"task-1","tool_name":"read_file","payload":{"agent_name":"alpha",'
    b'"tool_name":"read_file","tool_use_id":"tu-1","turn":7}}\n\n'
)


def observer_http_fixtures() -> HttpFixtures:
    """The MCP session handshake and a one-frame observer stream."""

    return {
        # The feed opens only after a refresh reaches the server, and the
        # connection reading counts the overview, board, planning, and
        # approval loads - so one of those must answer.
        "/api/v1/dashboard/briefing": (200, overview_event_briefing()),
        "/api/v1/board?sort_by=hot": (200, {"posts": []}),
        "/mcp": RawHttpResponse(
            200,
            json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode(),
            content_type="application/json",
            headers=(("Mcp-Session-Id", "mcp_fixture_session"),),
        ),
        "/mcp?sse_kind=observer": RawHttpResponse(
            200,
            OBSERVER_TOOL_CALLED_FRAME,
            content_type="text/event-stream",
        ),
    }


def run_observer_reconnect_regression(executable: str) -> None:
    releases = [threading.Event() for _ in range(8)]
    seen: list[dict[str, str]] = []
    requests: HttpRequests = []

    def frame(event_id: int, call: str) -> bytes:
        value = {
            "type": "keeper_tool_call", "name": "alpha", "tool_name": "keeper_skill",
            "ts_unix": 100.0, "turn": 7, "tool_use_id": call,
            "tool_args": {"skill": "input-" + call},
            "tool_result": {"receipt": "output-" + call},
        }
        return f"id: {event_id}\ndata: ".encode() + json.dumps(value).encode() + b"\n\n"

    def respond(headers: dict[str, str]) -> StreamingHttpResponse:
        index = len(seen)
        seen.append(headers)
        handshake = [
            (("x-masc-sse-instance-id", "epoch-a"), ("x-masc-sse-replay", "fresh")),
            (("x-masc-sse-instance-id", "epoch-a"), ("x-masc-sse-replay", "resumed")),
            (("x-masc-sse-instance-id", "epoch-a"), ("x-masc-sse-replay", "resumed")),
            (("x-masc-sse-instance-id", "epoch-b"), ("x-masc-sse-replay", "reset-instance-changed")),
            (("x-masc-sse-instance-id", "epoch-c"),),  # malformed: no replay contract
            (("x-masc-sse-instance-id", "epoch-c"), ("x-masc-sse-replay", "fresh")),
            (),  # peer no longer implements scoped replay
            (),
        ][min(index, 7)]

        def chunks():
            if index == 0:
                yield frame(41, "before-disconnect")
                releases[0].wait(timeout=20)
                yield b"id: 42\n"  # an ID-only partial frame was never delivered
            elif index == 1:
                yield frame(41, "before-disconnect") + frame(42, "during-disconnect")
                releases[1].wait(timeout=20)
            elif index == 2:
                return  # same epoch EOF with zero new events must retain session/cursor
            elif index == 3:
                yield frame(1, "after-restart")
                releases[3].wait(timeout=20)
            elif index in (4, 6):
                # No data: an old peer may suppress all events under our old
                # high numeric cursor. The client must close after headers.
                releases[index].wait(timeout=20)
            elif index == 5:
                yield frame(1, "after-malformed")
                releases[5].wait(timeout=20)
            else:
                yield frame(1, "unsupported-live-only")
                releases[7].wait(timeout=20)

        return StreamingHttpResponse(chunks, headers=handshake)

    fixtures = observer_http_fixtures()
    fixtures["/mcp?sse_kind=observer"] = HeadersHttpResponse(respond)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            resize_and_wait(process, master_fd, output, rows=38, columns=150, needle=b"MASC Overview")
            wait_for_output(process, master_fd, output, b"feed: live 1", start=0, timeout=10)
            send_and_wait(process, master_fd, output, b"\t", b"MASC Activity")
            send_and_wait(process, master_fd, output, b"f", b"actions)")
            send_and_wait(process, master_fd, output, b"\r", b"Tool use ID: before-disconnect")
            releases[0].set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 2", start=0, timeout=10)
            drain_until_quiet(process, master_fd, output)
            plain = screen_text(bytes(output))
            for needle in (b"Tool use ID: before-disconnect", b"output-before-disconnect",
                           b"retained window resumed; history completeness unknown"):
                if needle not in plain:
                    raise AssertionError(f"Replayed call retargeted selection or lost replay coverage: {plain!r}")
            releases[1].set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 3", start=0, timeout=10)
            wait_for_output(process, master_fd, output, b"disconnected history not recovered", start=0, timeout=10)
            releases[3].set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 4", start=0, timeout=10)
            releases[5].set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 5", start=0, timeout=10)
            drain_until_quiet(process, master_fd, output)
            plain = screen_text(bytes(output))
            if b"Replay unavailable (live only)" not in plain or b"before-disconnect" not in plain:
                raise AssertionError(f"Unsupported peer claimed replay or changed pinned evidence: {plain!r}")
            expected = [(None, None), ("epoch-a", "41"), ("epoch-a", "42"),
                        ("epoch-a", "42"), ("epoch-b", "1"), (None, None),
                        ("epoch-c", "1"), (None, None)]
            actual = [(h.get("x-masc-sse-instance-id"), h.get("last-event-id")) for h in seen]
            if actual != expected:
                raise AssertionError(f"HTTP cursor/epoch sequence differs: {actual!r}")
            if len([path for path, _ in requests if path == "/mcp"]) != 1:
                raise AssertionError("Transient zero-event close replaced the MCP session")
            if any(h.get("mcp-session-id") != "mcp_fixture_session" for h in seen):
                raise AssertionError("Reconnect did not retain the initialized MCP session")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Activity")
            detail = send_and_wait(process, master_fd, output, b"g\r", b"Tool use ID: unsupported-live-only")
            if b"output-unsupported-live-only" not in screen_text(bytes(output)):
                raise AssertionError(f"Live-only call did not expose its I/O: {detail!r}")
            captured = bytes(output)
            end = captured.rfind(FRAME_END) + len(FRAME_END)
            redraw = captured.rfind(FULL_REDRAW, 0, end)
            start = captured.rfind(FRAME_START, 0, redraw)
            if end < len(FRAME_END) or start < 0:
                raise AssertionError("Reconnect evidence has no completed redraw frame")
            print("OBSERVER_RECONNECT_EVIDENCE " + json.dumps({
                "fixture": "actual HTTP disconnect/restart/capability negotiation with canonical Keeper I/O",
                "requests": actual, "retained_unique_events": 5,
                "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                "pre_open_history_tested": False, "replay_completeness_proven": False,
                "rows": 38, "columns": 150, "encoding": "base64",
                "pty": base64.b64encode(captured[start:end]).decode(),
            }), flush=True)
            os.write(master_fd, b"q")
        finally:
            for release in releases:
                release.set()

    run_terminal_scenario(executable, description="Observer reconnect preserves scoped exact-call I/O",
                          interact=interact, refresh=0.5, http_fixtures=fixtures,
                          http_requests=requests)


def run_acting_call_evidence_regression(executable: str) -> None:
    release_next = threading.Event()
    keep_open = threading.Event()
    binary_sha256 = hashlib.sha256(Path(executable).read_bytes()).hexdigest()

    def emit_frame(phase: str, output: bytearray) -> None:
        captured = bytes(output)
        end = captured.rfind(FRAME_END)
        if end < 0:
            raise AssertionError("Acting evidence has no completed terminal frame")
        end += len(FRAME_END)
        redraw = captured.rfind(FULL_REDRAW, 0, end)
        start = captured.rfind(FRAME_START, 0, redraw) if redraw >= 0 else -1
        if start < 0:
            raise AssertionError("Acting evidence has no complete redraw origin")
        # A full redraw replaces every row; only its frame and later complete
        # deltas are needed to reproduce this exact screen. Session history
        # made the second evidence record exceed Dune's output allowance.
        current_frame = captured[start:end]
        print("ACTING_PTY_EVIDENCE " + json.dumps({
            "phase": phase, "fixture": "synthetic exact-event inspector",
            "binary_sha256": binary_sha256, "rows": 35, "columns": 140,
            "encoding": "base64", "pty": base64.b64encode(current_frame).decode(),
        }), flush=True)

    def frame(value):
        return b"event: message\ndata: " + json.dumps(value).encode() + b"\n\n"

    keeper = {
        "type": "keeper_tool_call", "name": "alpha", "tool_name": "keeper_skill",
        "ts_unix": 100.0, "turn": 7, "tool_use_id": "skill-call-exact",
        "planned_index": 3, "batch_index": 1, "batch_size": 2, "execution_mode": "concurrent",
        "tool_args": {"skill": "research-plan-exact"},
        "tool_result": {"receipt_sha256": "receipt-exact", "status": "served"},
        "tool_args_preview": "safe-input-preview-exact",
        "tool_output_preview": "safe-output-preview-exact\n\n\x1b[2Jforged-preview-text",
    }
    core = {
        "type": "agent_core:tool_completed", "event_type": "tool_completed",
        "agent_name": "runtime-lane-exact", "tool_name": "masc_fusion", "ts_unix": 101.0,
        "event_id": "event-exact", "run_id": "run-exact", "caused_by": "cause-exact",
        "parent_event_id": "parent-exact", "correlation_id": "trace-exact",
        "payload": {"turn": 7, "tool_use_id": "call-exact", "execution_id": "exec-exact"},
    }
    late = dict(core, event_id="new-event-must-not-replace", tool_name="other_tool")
    late["payload"] = {"turn": 8, "tool_use_id": "new-call-must-not-replace"}

    def chunks():
        yield frame(keeper) + frame(core)
        if release_next.wait(timeout=15):
            yield frame(late)
            keep_open.wait(timeout=15)

    fixtures = observer_http_fixtures()
    fixtures["/mcp?sse_kind=observer"] = StreamingHttpResponse(chunks)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            resize_and_wait(process, master_fd, output, rows=35, columns=140, needle=b"MASC Overview")
            wait_for_output(process, master_fd, output, b"feed: live 2", start=0, timeout=10)
            send_and_wait(process, master_fd, output, b"\t", b"MASC Activity")
            # A folded turn is never silently opened as one of its calls.
            aggregate_start = len(output)
            os.write(master_fd, b"\r")
            drain_until_quiet(process, master_fd, output)
            if b"ACTING EVENT EVIDENCE" in output[aggregate_start:]:
                raise AssertionError("Aggregated turn opened as an exact call")
            send_and_wait(process, master_fd, output, b"f", b"actions)")
            io_head = send_and_wait(process, master_fd, output, b"j\r", b"Tool use ID: skill-call-exact")
            for scheduling in (b"Execution mode: concurrent", b"Planned index (zero-based): 3",
                               b"Batch index (zero-based) / size: 1 / 2"):
                if scheduling not in io_head:
                    raise AssertionError(f"Keeper scheduling evidence missing: {scheduling!r}")
            # Narrow the viewport so the I/O requires scrolling even when
            # scheduling metadata is present above it.
            resize_and_wait(process, master_fd, output, rows=22, columns=140,
                            needle=b"ACTING EVENT EVIDENCE")
            io_tail = send_and_wait(process, master_fd, output, b"\x1b[6~", b"safe-output-preview-exact")
            for needle in (b"skill-call-exact", b"research-plan-exact", b"receipt-exact", b"producer-redacted"):
                if needle not in io_head + io_tail:
                    raise AssertionError(f"Selected Keeper event lost I/O evidence {needle!r}: {bytes(output)!r}")
            visible_io = screen_text(bytes(output))
            if b"\x1b[2Jforged-preview-text" in io_head + io_tail:
                raise AssertionError("Tool output preview emitted a terminal clear command")
            for needle in (b"safe-output-preview-exact", b"[2Jforged-preview-text"):
                if needle not in visible_io:
                    raise AssertionError(f"Terminal-safe multiline preview lost text {needle!r}: {visible_io!r}")
            resize_and_wait(process, master_fd, output, rows=35, columns=140,
                            needle=b"safe-output-preview-exact")
            emit_frame("redacted-io", output)
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Activity")
            detail = send_and_wait(process, master_fd, output, b"k\r", b"Execution ID: exec-exact")
            for needle in (b"Event ID: event-exact", b"Run ID: run-exact", b"Parent event ID: parent-exact", b"Caused by: cause-exact", b"Correlation ID: trace-exact"):
                if needle not in CSI_RE.sub(b"", detail):
                    raise AssertionError(f"Selected runtime event lost exact reference {needle!r}: {detail!r}")
            start = len(output)
            release_next.set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 3", start=start, timeout=8)
            drain_until_quiet(process, master_fd, output)
            pinned = bytes(output[start:])
            plain = screen_text(bytes(output))
            if b"Execution ID: exec-exact" not in plain or b"new-call-must-not-replace" in plain:
                raise AssertionError(f"New SSE event retargeted the open detail: {pinned!r}")
            emit_frame("pinned-exact-event", output)
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Activity")
            # The newly arrived event is independently selectable after closing.
            latest = send_and_wait(process, master_fd, output, b"g\r", b"new-call-must-not-replace")
            if b"Execution ID: not carried" not in screen_text(bytes(output)):
                raise AssertionError(f"Absent execution identity inherited the previous call: {latest!r}")
            keep_open.set()
            os.write(master_fd, b"q")
        finally:
            release_next.set()
            keep_open.set()

    run_terminal_scenario(executable, description="Acting exact event evidence stays pinned across SSE",
                          interact=interact, http_fixtures=fixtures)


def observer_feed_interaction(requests: HttpRequests) -> Interaction:
    """The TUI opens an MCP session after its first refresh reaches the
    server, subscribes to the observer feed with that session, and counts
    the frames it receives on the Overview row."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The fixture closes the stream right after its one frame, so the
        # row the test can rely on is the closed one; it keeps the count.
        wait_for_output(
            process, master_fd, output, b"feed: closed after 1", start=0, timeout=10.0
        )
        initialize = [body for path, body in requests if path == "/mcp"]
        if len(initialize) != 1:
            raise AssertionError(
                f"expected one MCP initialize, saw {len(initialize)}: {requests!r}"
            )
        payload = json.loads(initialize[0])
        if payload.get("method") != "initialize":
            raise AssertionError(f"MCP POST was not an initialize: {payload!r}")
        # The one frame the fixture streamed is a row on the Acting surface.
        # The default view folds it into a turn chunk: the running turn names
        # its in-flight call.
        acting = send_and_wait(process, master_fd, output, b"\t", b"MASC Activity")
        for needle, what in (
            (b"(1 of 1 held, turns)", "the held and shown counts"),
            (b"alpha", "the keeper that acted"),
            (b"turn 7", "the turn"),
            (b"read_file", "the in-flight tool"),
        ):
            if needle not in acting:
                raise AssertionError(f"Acting did not draw {what}: {acting!r}")
        # One f lands on the flat actions log, where the call is its own row
        # and carries the task.
        flat = send_and_wait(
            process, master_fd, output, b"f", b"(1 of 1 held, actions)"
        )
        for needle, what in (
            ("\u25b6 call".encode(), "the call glyph and label"),
            (b"read_file", "the tool"),
            (b"turn 7", "the turn"),
            (b"task-1", "the task"),
        ):
            if needle not in flat:
                raise AssertionError(f"Actions did not draw {what}: {flat!r}")
        os.write(master_fd, b"q")

    return interact


TASK_TOOL_ANSWER = RawHttpResponse(
    200,
    (
        b'event: message\n'
        b'data: {"jsonrpc":"2.0","result":{"content":[{"type":"text",'
        b'"text":"{\\"ok\\":true,\\"task_id\\":\\"task-9\\"}"}],"isError":false}}\n\n'
    ),
    content_type="text/event-stream",
)


def task_dispatch_http_fixtures() -> HttpFixtures:
    fixtures = observer_http_fixtures()
    fixtures["/mcp"] = SequencedHttpResponse(
        [
            RawHttpResponse(
                200,
                json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode(),
                content_type="application/json",
                headers=(("Mcp-Session-Id", "mcp_fixture_session"),),
            ),
            TASK_TOOL_ANSWER,
        ]
    )
    fixtures["/api/v1/keepers/chat/stream"] = (
        503,
        {"error": "stop after the dispatch request capture"},
    )
    return fixtures


def task_dispatch_interaction(requests: HttpRequests) -> Interaction:
    """/task in the composer creates the task over MCP and hands the keeper
    the operator's words with the task id in front."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(
            process, master_fd, output, b"feed: closed after 1", start=0, timeout=10.0
        )
        send_and_wait(process, master_fd, output, b"i", b"\xe2\x80\xba to alpha")
        send_and_wait(process, master_fd, output, b"/task Lanes surface", b"/task Lanes surface")
        os.write(master_fd, b"\r")
        chat_body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        tool_calls = [
            json.loads(body) for path, body in requests if path == "/mcp"
        ]
        add_task = [
            p for p in tool_calls
            if p.get("method") == "tools/call"
            and p.get("params", {}).get("name") == "masc_add_task"
        ]
        if len(add_task) != 1:
            raise AssertionError(f"expected one masc_add_task call: {tool_calls!r}")
        arguments = add_task[0]["params"]["arguments"]
        if arguments.get("title") != "Lanes surface" or "description" in arguments:
            raise AssertionError(f"unexpected add_task arguments: {arguments!r}")
        message = json.loads(chat_body).get("message")
        if message != "[task-9] Lanes surface":
            raise AssertionError(f"keeper message did not carry the task id: {message!r}")
        # The dispatch lands the operator in the keeper's chat, where the
        # send (and its 503 from the fixture) is on screen; the POST bodies
        # above are the proof of what went out.
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def duplicated_attention_briefing() -> HttpResponse:
    item = {
        "kind": "keeper_attention",
        "severity": "warning",
        "summary": "sangsu has external attention from discord",
        "target_type": "keeper",
        "target_id": "sangsu",
    }
    other = dict(item, summary="analyst needs operator attention")
    return (
        200,
        {
            "summary": {
                "workspace_health": "ok",
                "cluster": "cluster-a",
                "project": "project-a",
            },
            "generated_at": "2026-08-24T00:00:00Z",
            # The same row on both lists, the way the live briefing serves an
            # incident that is also queued for attention.
            "incidents": [item, other],
            "attention_queue": [item],
            "attention_items": [],
            "agent_briefs": [],
            "keeper_briefs": [],
        },
    )


def attention_drawn_once_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(
            process,
            master_fd,
            output,
            b"sangsu has external attention",
            start=0,
            timeout=10.0,
        )
        wait_for_output(
            process, master_fd, output, b"analyst needs operator", start=0, timeout=3.0
        )
        # One full repaint to count rows in: the ordinary paints are row
        # diffs, so counting in the raw stream would count repaints.
        frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"sangsu has external attention",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        repeated = frame.count(b"sangsu has external attention")
        if repeated != 1:
            raise AssertionError(
                f"an attention fact on two briefing lists drew {repeated} rows: {frame!r}"
            )
        if frame.count(b"analyst needs operator") != 1:
            raise AssertionError(f"the distinct item vanished: {frame!r}")

        os.write(master_fd, b"q")

    return interact


def composer_newline_interaction(requests: HttpRequests) -> Interaction:
    """Ctrl-J and Shift+Enter open lines; Return sends.

    Ctrl-J and Return are one byte apart only because the TUI turns off the
    terminal's CR-to-LF translation. With it on, Return arrives as LF -- the
    byte Ctrl-J sends -- and the composer cannot tell them apart. Enhanced
    keys keep Shift+Enter separate as the raw CSI sequence driven below.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        send_and_wait(process, master_fd, output, b"first", composer_showing(b"first"))
        # Ctrl-J. The prompt stays on the first line and the second is indented
        # under it, so the two rows read as one message.
        second_frame = send_and_wait(
            process,
            master_fd,
            output,
            b"\nsecond",
            composer_showing(b"second", prefix=b"    "),
        )
        rendered = CSI_RE.sub(b"", second_frame).decode("utf-8")
        if "> first" not in rendered:
            raise AssertionError(f"composer lost its first line: {rendered!r}")
        if "firstsecond" in rendered:
            raise AssertionError(f"composer joined the two lines: {rendered!r}")

        # Kitty keyboard disambiguation reports Shift+Enter as CSI 13;2u.
        # It opens another line and, like Ctrl-J, must not send on its own.
        third_frame = send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[13;2uthird",
            composer_showing(b"third", prefix=b"    "),
        )
        third_rendered = CSI_RE.sub(b"", third_frame).decode("utf-8")
        if "first" not in third_rendered or "second" not in third_rendered:
            raise AssertionError(
                f"Shift+Enter lost an earlier composer line: {third_rendered!r}"
            )
        posted = [path for path, _body in requests if path.endswith("/chat/stream")]
        if posted:
            raise AssertionError(f"Shift+Enter sent the composer: {posted!r}")

        # Return sends what Ctrl-J and Shift+Enter composed, newlines and all.
        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body)["message"]
        if message != "first\nsecond\nthird":
            raise AssertionError(f"the newline did not survive the send: {message!r}")
        # The fixture answers 503, so the turn settles rather than streaming.
        # Esc then leaves the pane instead of interrupting, and q quits from
        # the detail view -- in the pane it would be typed into the composer.
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def flow_control_is_off_interaction() -> Interaction:
    """Ctrl-S has to reach the key layer, not the tty.

    IXON lives in c_iflag and ICANON in c_lflag, so raw mode did not clear it:
    the terminal answered Ctrl-S by stopping output and Ctrl-Q by resuming,
    and neither byte ever reached the program. With IXANY also on, the next
    key released it, so what an operator saw was a stall rather than a freeze
    -- and what it cost was a key that could not be bound to anything.

    Read off the tty rather than inferred from the drawing: the flag is the
    fact, and a screen that repaints cannot tell the difference."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        wait_for_output(
            process, master_fd, output, b"MASC Overview", start=0, timeout=30.0
        )
        attributes = termios.tcgetattr(slave_fd)
        if attributes[0] & termios.IXON:
            raise AssertionError(
                "the tty still answers Ctrl-S itself; c_ixon must be cleared "
                "with the rest of raw mode or the key cannot be bound"
            )
        send_and_wait(process, master_fd, output, b"q", b"q: press again to quit")

    return interact


def run_keyboard_regression(executable: str) -> None:
    utf8_requests: HttpRequests = []
    missing_target_requests: HttpRequests = []
    unreliable_roster_requests: HttpRequests = []
    keeper_scroll_fixtures = overview_event_http_fixtures()
    # The gate holds a refresh open so the scenario can resize while one is in
    # flight, so it has to sit on a request every refresh makes. The board list
    # is fetched only while the board is on screen, which the scenario is not,
    # so the briefing -- which every surface asks for -- carries the gate.
    keeper_scroll_gate = GatedHttpResponse((200, overview_event_briefing()))
    approval_fixtures, approval_items, approval_new = approval_selection_http_fixtures()
    planning_reorder_fixtures = planning_selection_http_fixtures()
    planning_missing_fixtures = planning_selection_http_fixtures()
    board_selection_fixtures = board_selection_http_fixtures()
    board_authority_fixtures, late_list = board_detail_authority_http_fixtures()
    board_detail_fixtures, b_failure = board_detail_isolation_http_fixtures()
    missing_target_fixtures, late_b = board_paginated_detail_http_fixtures()
    message_switch_fixtures, alpha_history = keeper_message_switch_http_fixtures()
    chat_visibility_fixtures = chat_clarity_http_fixtures()
    lanes_fixtures = keeper_runtime_http_fixtures()
    lanes_gate = GatedHttpResponse(
        keeper_lanes_response(
            [
                keeper_lane_row(
                    "alpha",
                    phase="running",
                    turn_phase="idle",
                    idle_seconds=75,
                    runtime_state="done",
                    selected_model="claude-opus-5",
                    diagnosis="running_fiber_alive",
                ),
                keeper_lane_row(
                    "beta",
                    phase="failing",
                    turn_phase="executing",
                    idle_seconds=3599,
                    runtime_state="done",
                    selected_model=None,
                    diagnosis="failing_unhealthy",
                ),
            ]
        )
    )
    lanes_fixtures[KEEPER_LANES_PATH] = lanes_gate
    lanes_fixtures[STANDALONE_LANES_PATH] = standalone_lanes_response()
    lanes_fixtures[RUNTIME_CONFIG_RAW_PATH] = standalone_lane_runtime_config_response()
    lanes_fixtures[lane_runs_path("verifier_exact")] = verifier_lane_runs_response()
    lanes_fixtures[
        "/api/v1/dashboard/exact-lane-runs/vrf-fixture"
    ] = verifier_lane_run_detail_response()
    lanes_fixtures[lane_runs_path("hitl_auto_judge")] = hitl_lane_runs_response()
    lanes_fixtures[
        "/api/v1/dashboard/exact-lane-runs/hitl-fixture"
    ] = hitl_lane_run_detail_response()
    runtime_fixtures, runtime_initial_probe, runtime_force_probe = (
        runtime_http_fixtures()
    )
    schedule_fixtures = schedule_detail_http_fixtures()
    fusion_fixtures, fusion_initial_runs = fusion_http_fixtures()
    run_terminal_scenario(
        executable,
        description="flow control leaves Ctrl-S to the key layer",
        interact=flow_control_is_off_interaction(),
    )
    run_terminal_scenario(
        executable,
        description="Image view over the frame",
        interact=image_view_interaction(),
        prepare_workspace=seed_image_workspace,
        preload_input=GRAPHICS_SUPPORTED_REPLY,
    )
    run_terminal_scenario(
        executable,
        description="Memory fact browser lists both stores and filters",
        interact=memory_facts_interaction(),
        http_fixtures=memory_facts_http_fixtures(),
    )
    to_file_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="A spilled paste is written where the keeper reads",
        interact=paste_to_file_interaction(to_file_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after the spill-to-file request capture"},
            )
        },
        http_requests=to_file_requests,
        prepare_workspace=seed_playground_workspace,
    )
    spill_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="A big paste is one line in the draft",
        interact=paste_spill_interaction(spill_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after the spill request capture"},
            )
        },
        http_requests=spill_requests,
    )
    paste_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Bracketed paste is one draft",
        interact=bracketed_paste_interaction(paste_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after the paste request capture"},
            )
        },
        http_requests=paste_requests,
    )
    run_terminal_scenario(
        executable,
        description="A paste goes into the field taking characters",
        interact=paste_into_a_field_interaction(),
    )
    word_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Ctrl-W and Alt+Backspace delete a word in the composer",
        interact=word_delete_interaction(word_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after the word-delete request capture"},
            )
        },
        http_requests=word_requests,
    )
    chat_queue_fixtures, chat_queue_gate = chat_queue_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Keeper chat queue is drawn and walked",
        interact=chat_queue_interaction(chat_queue_gate),
        http_fixtures=chat_queue_fixtures,
        prepare_workspace=seed_uncoalesced_queue,
    )
    steer_requests: HttpRequests = []
    steer_fixtures, steer_gate = chat_steer_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Keeper chat steer interrupts and precedes NEXT",
        interact=chat_steer_interaction(steer_gate, steer_requests),
        http_fixtures=steer_fixtures,
        http_requests=steer_requests,
    )
    reconcile_requests: HttpRequests = []
    reconcile_fixtures, reconcile_gate = chat_reconcile_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Unknown Keeper chat outcome holds NEXT until terminal",
        interact=chat_reconcile_interaction(reconcile_gate, reconcile_requests),
        http_fixtures=reconcile_fixtures,
        http_requests=reconcile_requests,
    )
    run_terminal_scenario(
        executable,
        description="UTF-8 message input",
        interact=utf8_message_interaction(utf8_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after UTF-8 request capture"},
            )
        },
        http_requests=utf8_requests,
    )
    run_terminal_scenario(
        executable,
        description="Autonomous turn history",
        interact=autonomous_turn_history_interaction(),
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": autonomous_turn_history_fixture(),
        },
        extra_args=("--reasoning", "full", "--tool-view", "full"),
    )
    run_memory_journal_regression(executable)
    run_terminal_scenario(
        executable,
        description="Keeper provider-input Context Inspector",
        interact=context_inspector_interaction(),
        http_fixtures=context_inspector_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Ctrl-V is not swallowed by the terminal",
        interact=clipboard_paste_key_interaction(),
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": (200, []),
        },
    )
    run_terminal_scenario(
        executable,
        description="Keeper chat visibility modes",
        interact=chat_visibility_modes_interaction(),
        http_fixtures=chat_visibility_fixtures,
    )
    error_detail_fixtures = keeper_runtime_http_fixtures()
    error_detail_fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    error_detail_fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
        200,
        {"keeper": "alpha", "entries": []},
    )
    error_detail_fixtures["/api/v1/keepers/chat/stream"] = RequestHttpResponse(
        keeper_chat_failed_response
    )
    run_terminal_scenario(
        executable,
        description="Keeper chat errors preserve their complete detail",
        interact=keeper_chat_error_detail_interaction(),
        http_fixtures=error_detail_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Keeper message origin badges",
        interact=message_origin_badge_interaction,
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": message_origin_history_fixture(),
        },
    )
    run_terminal_scenario(
        executable,
        description="Keeper oversized viewport gap under NO_COLOR",
        interact=viewport_gap_interaction,
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": viewport_gap_history_fixture(),
            "/api/v1/keepers/alpha/chat/history/page": (
                viewport_gap_history_page_fixture()
            ),
        },
        extra_env={"NO_COLOR": "1"},
    )
    run_terminal_scenario(
        executable,
        description="Keeper live Markdown code frame",
        interact=live_markdown_interaction,
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": live_markdown_history_fixture(),
        },
    )
    run_terminal_scenario(
        executable,
        description="Keeper message Ctrl-G switch",
        interact=keeper_message_switch_interaction(alpha_history),
        http_fixtures=message_switch_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Keepers operations and Standalone-only Lanes",
        interact=keeper_lanes_ia_interaction(lanes_gate, lanes_fixtures),
        http_fixtures=lanes_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Code lane lists, drills, and lexes",
        interact=code_lane_interaction,
        http_fixtures=code_lane_fixtures(),
    )
    run_code_memo_regression(executable)
    enter_split_fixtures = keeper_runtime_http_fixtures()
    enter_split_fixtures[FILE_CHANGES_ALPHA_PATH] = file_changes_alpha_response()
    run_terminal_scenario(
        executable,
        description="Enter off the Changes surface does not arm its diff",
        interact=enter_outside_changes_interaction,
        http_fixtures=enter_split_fixtures,
    )
    changes_navigation_fixtures = keeper_runtime_http_fixtures()
    changes_navigation_fixtures[FILE_CHANGES_ALPHA_PATH] = file_changes_alpha_response()
    changes_navigation_fixtures[FILE_CHANGES_BETA_PATH] = file_changes_beta_response()
    # The v jump reads the row's file through the keeper axis; both query
    # encodings of the slash are served, as the workspace fixtures do.
    code_children = (
        200,
        [
            {"path": "repos/masc/lib/example.ml", "label": "example.ml",
             "depth": 0, "parent": "repos/masc/lib", "hasChildren": False,
             "diff": None, "keeperId": None, "hueIndex": None},
        ],
    )
    code_file = (200, {"ok": True, "content": "let a = 2\n"})
    for children_path in (
        "/api/v1/workspace/children?path=repos/masc/lib&limit=2000&keeper=alpha",
        "/api/v1/workspace/children?path=repos%2Fmasc%2Flib&limit=2000&keeper=alpha",
    ):
        changes_navigation_fixtures[children_path] = code_children
    for file_path in (
        "/api/v1/workspace/file?path=repos/masc/lib/example.ml&keeper=alpha",
        "/api/v1/workspace/file?path=repos%2Fmasc%2Flib%2Fexample.ml&keeper=alpha",
    ):
        changes_navigation_fixtures[file_path] = code_file
    run_terminal_scenario(
        executable,
        description="Changes keeper switch and arrow detail navigation",
        interact=changes_keeper_and_arrow_detail_interaction,
        http_fixtures=changes_navigation_fixtures,
    )
    gate_mode_fixtures = keeper_runtime_http_fixtures()
    gate_mode_fixtures["/api/v1/keepers/tool-approval-mode"] = (
        200,
        {"overrides": [{"keeper": "alpha", "mode": "yolo"}]},
    )
    run_terminal_scenario(
        executable,
        description="Keeper gate footer offers Auto from YOLO",
        interact=keeper_gate_mode_footer_interaction,
        http_fixtures=gate_mode_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Runtime lane candidates from joined projections",
        interact=runtime_surface_interaction(
            runtime_fixtures,
            runtime_initial_probe,
            runtime_force_probe,
        ),
        refresh=0.05,
        http_fixtures=runtime_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Schedule operational detail and page navigation",
        interact=schedule_detail_interaction(),
        http_fixtures=schedule_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Fusion list identity and panel-to-judge detail",
        interact=fusion_list_detail_interaction(
            fusion_fixtures,
            fusion_initial_runs,
        ),
        refresh=0.05,
        http_fixtures=fusion_fixtures,
        # The harness verdict in these fixtures judges task-linked-501. Seeding
        # that task and the goal it serves is what lets the detail say what the
        # verdict was aiming at, rather than naming a task and stopping.
        prepare_workspace=seed_goal_linked_task,
    )
    fusion_live_fixtures, fusion_mcp_gate, fusion_run_list = fusion_live_reload_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Fusion live reload on an observer status push",
        interact=fusion_live_reload_interaction(fusion_run_list, fusion_mcp_gate),
        http_fixtures=fusion_live_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Keeper tool-call log",
        interact=keeper_calls_interaction(),
        http_fixtures={
            "/api/v1/keepers/alpha/tool-calls?limit=100": keeper_calls_fixture(),
        },
    )
    verification_gate = GatedHttpResponse((200, {"requests": [], "total": 0}))
    run_terminal_scenario(
        executable,
        description="Verification unread before read",
        interact=verification_unread_interaction(verification_gate),
        http_fixtures={
            "/api/v1/verification/requests?limit=200": verification_gate,
        },
    )
    verdict_requests: HttpRequests = []
    with reject_editor_script() as reject_editor:
        run_terminal_scenario(
            executable,
            description="Verification verdict keys",
            interact=verification_verdict_interaction(verdict_requests),
            http_fixtures=verification_verdict_fixtures(),
            http_requests=verdict_requests,
            extra_env={"EDITOR": reject_editor},
        )
    observer_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Observer feed subscription",
        interact=observer_feed_interaction(observer_requests),
        http_fixtures=observer_http_fixtures(),
        http_requests=observer_requests,
    )
    dispatch_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Composer task dispatch",
        interact=task_dispatch_interaction(dispatch_requests),
        http_fixtures=task_dispatch_http_fixtures(),
        http_requests=dispatch_requests,
    )
    run_terminal_scenario(
        executable,
        description="Attention drawn once",
        interact=attention_drawn_once_interaction(),
        http_fixtures={
            "/api/v1/dashboard/briefing": duplicated_attention_briefing(),
        },
    )
    composer_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Composer newline and send",
        interact=composer_newline_interaction(composer_requests),
        http_fixtures={
            "/health?full=1": fleet_safety_fixture(),
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after composer request capture"},
            ),
        },
        http_requests=composer_requests,
    )
    run_terminal_scenario(
        executable,
        description="Keeper detail overscroll normalization",
        interact=keeper_detail_overscroll_interaction(
            keeper_scroll_fixtures,
            keeper_scroll_gate,
        ),
        http_fixtures=keeper_scroll_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Keeper selection identity",
        interact=keeper_selection_identity_interaction,
        http_fixtures=overview_event_http_fixtures(),
        prepare_workspace=block_stderr_redirect,
    )
    run_terminal_scenario(
        executable,
        description="CLI base path overrides inherited environment",
        interact=cli_base_path_overrides_environment_interaction,
        http_fixtures=overview_event_http_fixtures(),
        conflicting_env_base_path=True,
    )
    run_terminal_scenario(
        executable,
        description="Keeper message unreliable roster",
        interact=keeper_message_unreliable_roster_interaction(
            unreliable_roster_requests
        ),
        refresh=0.05,
        http_fixtures=overview_event_http_fixtures(),
        http_requests=unreliable_roster_requests,
        prepare_workspace=block_stderr_redirect,
    )
    run_terminal_scenario(
        executable,
        description="Keeper message missing target",
        interact=keeper_message_missing_target_interaction(missing_target_requests),
        refresh=0.05,
        http_fixtures=overview_event_http_fixtures(),
        http_requests=missing_target_requests,
    )
    run_terminal_scenario(
        executable,
        description="event-budgeted Overview",
        interact=assert_overview_event_rows,
        http_fixtures=keeper_runtime_http_fixtures(),
        prepare_workspace=seed_row_budget_workspace,
    )
    run_terminal_scenario(
        executable,
        description="approval selection identity",
        interact=approval_selection_identity_interaction(
            approval_fixtures,
            approval_items,
            approval_new,
        ),
        http_fixtures=approval_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Planning preserves selected goals and footer across resize",
        interact=planning_resize_budget_interaction,
        http_fixtures=planning_selection_http_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Planning selection identity",
        interact=planning_reorder_identity_interaction(planning_reorder_fixtures),
        http_fixtures=planning_reorder_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Planning missing detail recovery",
        interact=planning_missing_detail_interaction(planning_missing_fixtures),
        http_fixtures=planning_missing_fixtures,
    )
    board_reference_fixtures = board_reference_http_fixtures()
    keeper_ask_fixtures, _ask_initial, _ask_new = approval_selection_http_fixtures()
    keeper_ask_fixtures[KEEPER_ASKS_PATH] = keeper_asks_response()
    keeper_ask_fixtures[KEEPER_ASK_ANSWER_PATH] = (200, {"ok": True})
    ask_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Blocked Gate reason remains whole in approval detail",
        interact=blocked_gate_detail_interaction(),
        http_fixtures=blocked_gate_detail_http_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Answering a Keeper's question from an approval detail",
        interact=keeper_ask_answer_interaction(keeper_ask_fixtures, ask_requests),
        http_fixtures=keeper_ask_fixtures,
        http_requests=ask_requests,
    )
    reader_fixtures, _, _ = approval_selection_http_fixtures()
    reader_fixtures[KEEPER_ASKS_PATH] = keeper_asks_response(long_question=True)
    reader_fixtures[KEEPER_ASK_ANSWER_PATH] = (200, {"ok": True})
    reader_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Question arrows, overflow and visible free-text editing",
        interact=question_reader_interaction(reader_requests),
        http_fixtures=reader_fixtures,
        http_requests=reader_requests,
    )
    mode_fixtures = blocked_gate_detail_http_fixtures()
    mode_fixtures["/api/v1/dashboard/gate/mode"] = (200, {"ok": True})
    mode_fixtures["/api/v1/dashboard/gate/external-mode"] = (200, {"ok": True})
    mode_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Gate mode chooser applies only after Enter",
        interact=gate_mode_picker_interaction(mode_requests),
        http_fixtures=mode_fixtures,
        http_requests=mode_requests,
    )
    run_terminal_scenario(
        executable,
        description="Board references and related posts",
        interact=board_reference_interaction(board_reference_fixtures),
        http_fixtures=board_reference_fixtures,
    )
    run_board_json_regression(executable)
    run_terminal_scenario(
        executable,
        description="Board selection identity",
        interact=board_selection_identity_interaction(board_selection_fixtures),
        http_fixtures=board_selection_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Board detail post authority",
        interact=board_detail_authority_interaction(
            board_authority_fixtures,
            late_list,
        ),
        http_fixtures=board_authority_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Board detail isolation",
        interact=board_detail_isolation_interaction(b_failure),
        http_fixtures=board_detail_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Board exact detail survives page omission",
        interact=board_paginated_detail_interaction(missing_target_fixtures, late_b),
        http_fixtures=missing_target_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="row-budgeted Overview and Board",
        interact=assert_row_budgeted_surfaces,
        http_fixtures=row_budget_http_fixtures(),
        prepare_workspace=seed_row_budget_workspace,
    )
    run_terminal_scenario(
        executable,
        description="console diagnostic repair",
        interact=repair_after_console_diagnostic,
        prepare_workspace=block_stderr_redirect,
        refresh=0.05,
    )
    run_terminal_scenario(
        executable,
        description="Keeper phase and runtime identity",
        interact=keeper_runtime_phase_and_identity_interaction,
        http_fixtures=keeper_runtime_http_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Keeper long runtime identities remain distinguishable",
        interact=keeper_long_runtime_identity_interaction,
        http_fixtures=keeper_runtime_http_fixtures(
            alpha_runtime_id="antigravity_subscription.gemini-3-7-flash",
            beta_runtime_id="antigravity_subscription.claude-sonnet-4",
        ),
    )
    run_terminal_scenario(
        executable,
        description="q",
        interact=navigate_with_arrows_and_quit,
    )
    run_terminal_scenario(
        executable,
        description="wheel scrolls, clicks do not",
        interact=wheel_scrolls_and_clicks_do_not,
        http_fixtures=compact_input_gate_http_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="compact q",
        interact=quit_from_compact_message,
    )
    run_terminal_scenario(
        executable,
        description="Ctrl-C",
        interact=interrupt_with_ctrl_c,
        confirm_exit=b"\x03",
    )
    # No confirming key: the signal is the whole exit.
    run_terminal_scenario(
        executable,
        description="SIGTERM",
        interact=terminate_with_sigterm,
        confirm_exit=b"",
    )


def run_cli_base_path_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="CLI base path overrides inherited environment",
        interact=cli_base_path_overrides_environment_interaction,
        http_fixtures=overview_event_http_fixtures(),
        conflicting_env_base_path=True,
    )


def run_planning_review_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Planning preserves selected goals and footer across resize",
        interact=planning_resize_budget_interaction,
        http_fixtures=planning_selection_http_fixtures(),
    )
    verification_gate = GatedHttpResponse((200, {"requests": [], "total": 0}))
    run_terminal_scenario(
        executable,
        description="Planning Task Review unread before read",
        interact=verification_unread_interaction(verification_gate),
        http_fixtures={
            "/api/v1/verification/requests?limit=200": verification_gate,
        },
    )
    run_terminal_scenario(
        executable,
        description="Planning owns Goals and Task Review",
        interact=planning_review_hierarchy_interaction(),
        http_fixtures=verification_verdict_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Planning activity names actor role and handoff author",
        interact=planning_activity_actor_interaction(),
        http_fixtures=planning_activity_http_fixtures(),
    )


def run_repositories_regression(executable: str) -> None:
    fixtures = keeper_runtime_http_fixtures()
    fixtures[REPOSITORIES_PATH] = repositories_fixture()
    fixtures["/api/v1/repositories/masc/changes"] = (
        200,
        {
            "scope": {"kind": "repository", "repository_id": "masc"},
            "changes": [
                {"path": "lib/changed file.ml", "staged": True,
                 "unstaged": True, "untracked": False, "conflicted": False},
                {"path": "새 파일.txt", "staged": False,
                 "unstaged": False, "untracked": True, "conflicted": False},
            ],
            "total": 2,
        },
    )
    fixtures["/api/v1/workspace/children?path=&limit=2000&repo_id=masc"] = (
        200,
        [
            {"path": "src", "label": "src", "depth": 0, "parent": "",
             "hasChildren": True, "diff": None, "keeperId": None,
             "hueIndex": None},
        ],
    )
    run_terminal_scenario(
        executable,
        description="Repositories show paths, Git changes, and the Code tree",
        interact=repositories_path_interaction,
        http_fixtures=fixtures,
    )
    # The two scenarios below opened a repository's own tree and declared a
    # new repository from the default group, where a failure earlier in the
    # run kept them from running at all. They are repository scenarios, so
    # they run under the repositories alias with the one above.
    repositories_fixtures = keeper_runtime_http_fixtures()
    repositories_fixtures[REPOSITORIES_PATH] = repositories_fixture()
    repositories_fixtures["/api/v1/workspace/children?path=&limit=2000&repo_id=masc"] = (
        200,
        [
            {"path": "src", "label": "src", "depth": 0, "parent": "",
             "hasChildren": True, "diff": None, "keeperId": None,
             "hueIndex": None},
            {"path": "note.ml", "label": "note.ml", "depth": 0, "parent": "",
             "hasChildren": False, "diff": None, "keeperId": None,
             "hueIndex": None},
        ],
    )
    repo_file = (
        200,
        {
            "ok": True,
            "content": (
                "(* masc(alpha) decision: keep n at three until the probe lands *)\n"
                "let n = 3\n"
            ),
        },
    )
    for file_path in (
        "/api/v1/workspace/file?path=note.ml&repo_id=masc",
    ):
        repositories_fixtures[file_path] = repo_file
    repositories_fixtures[
        "/api/v1/git/log?path=note.ml&limit=50&repo_id=masc"
    ] = (
        200,
        {"ok": True, "commits": [
            {"hash": "abc1234", "timestamp_ms": 1787650000000,
             "author": "keeper", "subject": "docs: seed the file (#1256)"},
        ]},
    )
    run_terminal_scenario(
        executable,
        description="Repositories Enter opens the Code tree",
        interact=repositories_enter_interaction(),
        http_fixtures=repositories_fixtures,
    )
    add_requests: HttpRequests = []
    with repository_declaration_editor_script() as repo_editor:
        run_terminal_scenario(
            executable,
            description="Repositories add says what it did",
            interact=repository_add_interaction(add_requests),
            http_fixtures=repositories_fixtures,
            http_requests=add_requests,
            extra_env={"EDITOR": repo_editor},
        )


def run_project_changes_regression(executable: str) -> None:
    fixtures = code_lane_fixtures()
    fixtures["/api/v1/git/status"] = (
        200,
        {
            "scope": {"kind": "project"},
            "changes": [
                {"path": "lib/a.ml", "staged": False,
                 "unstaged": True, "untracked": False,
                 "conflicted": False},
                {"path": "새 파일.txt", "staged": False,
                 "unstaged": False, "untracked": True,
                 "conflicted": False},
            ],
            "total": 2,
        },
    )
    run_terminal_scenario(
        executable,
        description="Code lists current project Git changes and opens a file",
        interact=project_changes_interaction,
        http_fixtures=fixtures,
    )


def run_browser_client_picker_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    firefox = "11111111-1111-4111-8111-111111111111"
    zen = "22222222-2222-4222-8222-222222222222"
    active = [{"clientId": firefox, "browser": "firefox"}, {"clientId": zen, "browser": "zen"}]
    reads: list[dict[str, object]] = []

    def read(body: bytes) -> HttpResponse:
        request = json.loads(body)
        reads.append(request)
        client = request.get("clientId")
        if client not in [row["clientId"] for row in active]:
            return 409, {"ok": False, "error": "client_not_connected"}
        text = "Zen selected page" if client == zen else "Firefox selected page"
        return 200, {"ok": True, "data": {
            "source": "live", "clientId": client, "elapsed_ms": 1.0,
            "tabs": [{"id": 2, "title": text, "url": "https://example.org/", "active": True}],
            "page": {"tabId": 2, "title": text, "url": "https://example.org/",
                     "text": text, "chars": len(text), "truncated": False}}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = SequencedHttpResponse([
        (200, {"ok": True, "data": {"clients": list(active)}}),
        (200, {"ok": True, "data": {"clients": list(active)}}),
        (200, {"ok": True, "data": {"clients": [active[1]]}}),
    ])
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)

    def interact(process, master_fd, slave_fd, output, _base):
        palette_go(process, master_fd, output, b"go Browser Lane", b"Choose a connected browser")
        if reads:
            raise AssertionError("unselected multi-client view sent a browser read")
        os.write(master_fd, b"j")
        wait_for_terminal_input_consumed(slave_fd)
        send_and_wait(process, master_fd, output, b"\r", b"Zen selected page")
        if reads != [{"lane": "live", "clientId": zen}]:
            raise AssertionError("Zen choice did not pin its client ID")
        read_available(master_fd, output)
        chooser_start = len(output)
        send_and_wait(process, master_fd, output, b"b", b"Choose a connected browser")
        # b clears the displayed inventory until discovery settles. Require a
        # row from this request, not Firefox text in an earlier chooser frame.
        wait_for_output(process, master_fd, output, b"Firefox", start=chooser_start, timeout=3.0)
        send_and_wait(process, master_fd, output, b"\r", b"Firefox selected page")
        if reads[-1] != {"lane": "live", "clientId": firefox}:
            raise AssertionError("browser switch reused the old browser's tab ID")
        active[:] = [active[1]]
        send_and_wait(process, master_fd, output, b"r", b"Selected browser disconnected")
        if len(reads) != 2:
            raise AssertionError("stale Firefox pin silently rebound to the remaining Zen client")
        if b"Firefox selected page" in screen_text(bytes(output)):
            raise AssertionError("disconnected browser content remained under the chooser")
        send_and_wait(process, master_fd, output, b"\r", b"Zen selected page")
        if reads[-1] != {"lane": "live", "clientId": zen}:
            raise AssertionError("explicit reconnect carried the stale tab ID")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
        os.write(master_fd, b"q")

    run_terminal_scenario(executable, description="Browser client pinning and disconnected selection",
        interact=interact, http_fixtures=fixtures)


def run_browser_scene_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    client = "11111111-1111-4111-8111-111111111111"
    target = {"lane": "live", "clientId": client, "tabId": 2}
    url = "https://example.org/scene"
    scenes, actions = [], []

    def node(identity, kind, text):
        result = {"nodeId": identity, "kind": kind, "tag": "button" if kind == "control" else "p",
            "text": text, "rects": [{"x": 0, "y": 0, "width": 100, "height": 20}],
            "color": "rgb(0,0,0)", "fontSize": 16, "fontWeight": "400", "whiteSpace": "normal"}
        if kind == "control":
            result.update(clickable=True, editable=False, disabled=False)
        return result

    def read(_body):
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "elapsed_ms": 12.5, "tabs": [{"id": 2, "title": "scene", "url": url, "active": True}],
            "page": {"tabId": 2, "title": "scene", "url": url,
                "text": "scene reader ready", "chars": 18, "truncated": False}}}

    def scene(body):
        request = json.loads(body)
        scenes.append(request)
        assert {k:request[k] for k in target} == target, "scene read lost client/tab ownership"
        changed = bool(actions)
        view = request.get("view")
        scope = request.get("scope")
        assert view in ("content","regions")
        region = dict(node("channel-region","region","Channel messages"),role="main")
        if view == "regions":
            nodes = [region]
        elif scope:
            assert scope == {"documentId":"document-after","nodeId":"channel-region"}
            nodes = [node("message","text","SCOPED CHANNEL CONTENT")]
        else:
            nodes = [node("body", "text", "SCENE CLICK VERIFIED" if changed else "SCENE BEFORE CLICK"),
                node("first-control", "control", "First action"),
                node("second-control", "control", "Second action"),
                node("image", "raster", "Scene illustration")]
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "tabId": 2, "elapsed_ms": 13.0, "schema": "masc.browser.scene.v1", "view":view, "scope":scope,
            "documentId": "document-after" if changed else "document-before",
            "url": url, "title": "scene", "truncated": False,
            "viewport": {"width": 800, "height": 600, "scrollX": 0, "scrollY": 0},
            "nodes": nodes}}

    def click(body):
        request = json.loads(body)
        assert request == dict(target, action="click", documentId="document-before",
            nodeId="second-control", expectedUrl=url), "click lost the selected observed reference"
        actions.append(request)
        return 200, {"ok": True, "data": {"clicked": True}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True,
        "data": {"clients": [{"clientId": client, "browser": "zen"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/scene"] = RequestHttpResponse(scene)
    fixtures["/api/v1/dashboard/browser-lane/interact"] = RequestHttpResponse(click)

    def interact(process, master, _slave, output, _base):
        palette_go(process, master, output, b"go Browser Lane", b"scene reader ready")
        frame = send_and_wait(process, master, output, b"s", b"SCENE BEFORE CLICK")
        visible = screen_text(frame)
        # Source-context selection includes text and raster observations,
        # not only clickable controls. Preserve their document order.
        for text in (b"[>1] SCENE BEFORE CLICK", b"[2 button/link] First action",
                     b"[3 button/link] Second action",
                     "[4 image · Ctrl-O] Scene illustration".encode()):
            assert text in visible, f"scene projection missing {text!r}"
        send_and_wait(process, master, output, b"n", b"[>2 button/link] First action")
        send_and_wait(process, master, output, b"n", b"[>3 button/link] Second action")
        send_and_wait(process, master, output, b"p", b"[>2 button/link] First action")
        send_and_wait(process, master, output, b"n", b"[>3 button/link] Second action")
        assert len(scenes) == 1 and not actions, "selection triggered a browser effect"
        send_and_wait(process, master, output, b"\r", b"SCENE CLICK VERIFIED")
        assert len(actions) == 1 and len(scenes) == 2, "click was not followed by one fresh scene"
        send_and_wait(process, master, output, b"v", b"Channel messages")
        assert scenes[-1]["view"] == "regions" and len(actions)==1
        send_and_wait(process, master, output, b"\r", b"SCOPED CHANNEL CONTENT")
        focused = scenes[-1]
        send_and_wait(process, master, output, b"r", b"SCOPED CHANNEL CONTENT")
        assert scenes[-1] == focused and len(actions)==1, "scoped refresh widened or caused an effect"
        send_and_wait(process, master, output, b"\x1b", b"MASC Overview")
        os.write(master, b"q")

    run_terminal_scenario(executable, description="Browser scene text, selection and observed click refresh",
        interact=interact, http_fixtures=fixtures)


def run_browser_viewport_regression(executable: str, *, cell_geometry: bool = True) -> None:
    fixtures = overview_event_http_fixtures()
    client = "11111111-1111-4111-8111-111111111111"
    captures, actions = [], []
    png = [""]
    changed = [False]
    blocked, release = threading.Event(), threading.Event()
    target = {"lane": "live", "clientId": client, "tabId": 2}
    url = "https://example.org/"

    def prepare(base):
        seed_image_workspace(base)
        png[0] = base64.b64encode(Path(base, IMAGE_NAME).read_bytes()).decode()

    def read(body):
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "elapsed_ms": 12.5, "tabs": [{"id": 2, "title": "owned", "url": url, "active": True}],
            "page": {"tabId": 2, "title": "owned", "url": url,
                "text": "owned browser body", "chars": 18, "truncated": False}}}

    def screenshot(body):
        request = json.loads(body)
        captures.append(request)
        assert request == target, "viewport capture lost its explicit target"
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "tabId": 2, "title": "owned", "url": url + "changed" if changed[0] else url,
            "mimeType": "image/png", "data": png[0], "viewport": {"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0}, "elapsed_ms": 13.0}}

    def scroll(body):
        request = json.loads(body)
        actions.append(request)
        expected_point = {"x":0.5,"y":0.5} if len(actions)==1 or not cell_geometry else {"x":9.5/60,"y":6.5/30}
        assert request == dict(target, expectedUrl=url, action="scroll_at", x=0, y=120,
            point=expected_point,viewport={"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0})
        if len(actions) == 2:
            blocked.set()
            if not release.wait(timeout=10):
                return 504, {"ok": False, "error": "fixture timeout"}
        return 200, {"ok": True, "data": {"scrollY": len(actions) * 120}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True,
        "data": {"clients": [{"clientId": client, "browser": "zen"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/screenshot"] = RequestHttpResponse(screenshot)
    fixtures["/api/v1/dashboard/browser-lane/interact"] = RequestHttpResponse(scroll)

    def interact(process, master, slave, output, _base):
        def image_input(data: bytes) -> bytes:
            # draw_image writes its own image layer and footer, without the
            # Frame_presenter FRAME_END emitted by ordinary text frames.
            read_available(master, output)
            start = len(output)
            os.write(master, data)
            wait_for_output(process, master, output, b"a=T", start=start, timeout=3)
            image_end = end_of_needle(output, b"a=T", start)
            # Include the wheel hint before checking pane/center fallback.
            # Esc: back is only the beginning of the footer.
            footer = b"j/k:center"
            wait_for_output(process, master, output, footer, start=image_end, timeout=3)
            return bytes(output[start:end_of_needle(output, footer, image_end)])

        palette_go(process, master, output, b"go Browser Lane", b"owned browser body")
        initial_image = image_input(b"\x0f")
        if not cell_geometry:
            assert b"wheel:center" in initial_image, "missing center-wheel fallback hint"
        image_input(b"j")
        assert len(actions) == 1 and len(captures) == 2
        # Global shortcuts and pasted text belong to the visible viewport.
        os.write(master, b"a\x1b[200~hidden-draft\x1b[201~")
        wait_for_terminal_input_consumed(slave)
        image_input(b"r")
        assert len(actions) == 1 and len(captures) == 3
        resize_and_wait(process, master, output, rows=35, columns=110, needle=b"Esc: back")
        assert len(captures) == 3, "resize must redraw cached bytes without browser effects"
        os.write(master, b"\x1b[<65;10;10M")
        assert wait_for_fixture_event(process, master, output, blocked, timeout=3)
        os.write(master, b"jr")
        wait_for_terminal_input_consumed(slave)
        send_and_wait(process, master, output, b"\x1b", b"Scrolling selected browser viewport")
        read_available(master, output)
        start = len(output)
        release.set()
        wait_for_output(process, master, output, b"Read 12.5 ms", start=start, timeout=3)
        assert b"a=T" not in output[start:], "late frame reopened a closed viewport"
        assert len(actions) == 2 and len(captures) == 4, "busy input was queued or replayed"
        image_input(b"\x0f")
        changed[0] = True
        # The long ownership error is clipped to the viewport width. Its
        # visible prefix plus the assertions below establish refusal without
        # requiring text that is correctly outside the rendered frame.
        restored = send_and_wait(process, master, output, b"r", b"Read/action failed: screenshot source")
        assert FULL_REDRAW in restored, "async image dismissal reused the cleared text frame"
        visible = screen_text(restored[restored.rfind(FULL_REDRAW):])
        for row in (b"MASC Browser Lane", b"owned browser body", b"b:choose browser"):
            assert row in visible, f"async image dismissal did not restore {row!r}"
        assert b"Esc: back" not in visible, "viewport footer remained after async dismissal"
        assert len(captures) == 6
        send_and_wait(process, master, output, b"\x1b", b"MASC Overview")
        os.write(master, b"q")

    try:
        run_terminal_scenario(executable, description="Browser visual viewport input and late frame ownership",
            interact=interact, http_fixtures=fixtures, prepare_workspace=prepare,
            preload_input=(b"\x1b[6;20;10t" if cell_geometry else b"")+GRAPHICS_SUPPORTED_REPLY)
    finally:
        release.set()


def run_browser_pointer_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    client = "11111111-1111-4111-8111-111111111111"
    actions, captures, png = [], [], [""]
    viewport = {"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0}
    url = "https://example.org/"

    def prepare(base):
        seed_image_workspace(base)
        png[0] = base64.b64encode(Path(base, IMAGE_NAME).read_bytes()).decode()

    def read(body):
        request = json.loads(body)
        return 200, {"ok":True,"data":{"source":request["lane"],"clientId":request.get("clientId"),
            "elapsed_ms":0,"tabs":[{"id":2,"title":"owned","url":url,"active":True}],
            "page":{"tabId":2,"title":"owned","url":url,"text":"pointer fixture","chars":15,"truncated":False}}}

    def screenshot(body):
        request = json.loads(body)
        captures.append(request)
        return 200, {"ok":True,"data":{"source":request["lane"],"clientId":request.get("clientId"),
            "tabId":2,"title":"owned","url":url,"mimeType":"image/png","data":png[0],"viewport":viewport,"elapsed_ms":0}}

    def act(body):
        request = json.loads(body)
        assert request["lane"] == "automation" and request["tabId"] == 2
        assert "clientId" not in request and request["expectedUrl"] == url
        assert request["viewport"] == viewport
        actions.append(request)
        return 200, {"ok":True,"data":{}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200,{"ok":True,"data":{"clients":[{"clientId":client,"browser":"firefox"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/screenshot"] = RequestHttpResponse(screenshot)
    fixtures["/api/v1/dashboard/browser-lane/interact"] = RequestHttpResponse(act)

    def interact(process, master, slave, output, _base):
        palette_go(process, master, output, b"go Browser Lane", b"pointer fixture")
        send_and_wait(process, master, output, b"a", b"pointer fixture")
        def image_input(data):
            read_available(master, output)
            start = len(output)
            os.write(master, data)
            wait_for_output(process, master, output, b"Esc: back", start=start, timeout=3)
            return bytes(output[start:])
        image = image_input(b"\x0f")
        assert b"f=100,a=T,r=25," in image, "fullscreen screenshot must use all 30 physical terminal rows"
        # Caption clicks are consumed without dispatch; no double action on press.
        os.write(master, b"\x1b[<0;2;1M\x1b[<0;2;1m")
        wait_for_terminal_input_consumed(slave)
        assert not actions
        image_input(b"\x1b[<0;2;5M\x1b[<0;2;5m")
        assert len(actions)==1 and actions[0]["action"]=="click_at"
        # 30x100 terminal, 10x20 cells, square PNG: 25 rows x 50 columns,
        # after the three caption rows. Mouse reports target cell centers.
        assert actions[0]["point"] == {"x":0.03,"y":0.06}, actions[0]
        image_input(b"\x1b[<0;2;5M\x1b[<0;5;8m")
        assert len(actions)==2 and actions[1]["action"]=="drag"
        assert actions[1]["from"] == {"x":0.03,"y":0.06}, actions[1]["from"]
        assert actions[1]["to"] == {"x":0.09,"y":0.18}, actions[1]["to"]
        assert len(captures)==3
        send_and_wait(process, master, output, b"\x1b", b"pointer fixture")
        send_and_wait(process, master, output, b"\x1b", b"MASC Overview")
        os.write(master,b"q")

    run_terminal_scenario(executable, description="Browser screenshot mouse click and drag routing",
        interact=interact,http_fixtures=fixtures,prepare_workspace=prepare,
        preload_input=b"\x1b[6;20;10t"+GRAPHICS_SUPPORTED_REPLY)


def run_browser_screenshot_regression(executable: str) -> None:
    run_browser_pointer_regression(executable)
    run_browser_viewport_regression(executable)
    run_browser_viewport_regression(executable, cell_geometry=False)
    fixtures = overview_event_http_fixtures()
    client_id = "11111111-1111-4111-8111-111111111111"
    requests: list[dict[str, object]] = []
    png = [""]
    requested, release = threading.Event(), threading.Event()

    def prepare(base: str) -> None:
        seed_image_workspace(base)
        png[0] = base64.b64encode(Path(base, IMAGE_NAME).read_bytes()).decode()

    def read(body: bytes) -> HttpResponse:
        request = json.loads(body)
        tab_id = request.get("tabId", 2)
        title = "first" if tab_id == 1 else "second"
        return 200, {"ok": True, "data": {
            "source": request["lane"], "clientId": request.get("clientId"), "elapsed_ms": 12.5,
            "tabs": [{"id": n, "title": name, "url": "https://example.org/", "active": n == 2}
                     for n, name in [(1, "first"), (2, "second")]],
            "page": {"tabId": tab_id, "title": title, "url": "https://example.org/",
                     "text": title + " page body", "chars": 16, "truncated": False}}}

    def screenshot(body: bytes) -> HttpResponse:
        request = json.loads(body)
        requests.append(request)
        if len(requests) == 2:
            requested.set()
            if not release.wait(timeout=10):
                return 504, {"ok": False, "error": "fixture timeout"}
        if len(requests) == 4:
            return 404, {"ok": False, "error": "selected Firefox tab closed"}
        return 200, {"ok": True, "data": {
            "source": request["lane"], "clientId": request.get("clientId"), "tabId": request["tabId"], "title": "selected Firefox tab",
            "url": "https://example.org/", "mimeType": "image/png", "data": png[0], "viewport": {"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0}, "elapsed_ms": 13.0}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True, "data": {"clients": [{"clientId": client_id, "browser": "firefox"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/screenshot"] = RequestHttpResponse(screenshot)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        if hasattr(termios, "VDISCARD"):
            cc = termios.tcgetattr(_slave_fd)[6][termios.VDISCARD]
            discard = cc if isinstance(cc, int) else cc[0]
            if discard != os.fpathconf(_slave_fd, "PC_VDISABLE"):
                raise AssertionError("raw mode did not reclaim Ctrl-O from VDISCARD")
        palette_go(process, master_fd, output, b"go Browser Lane", b"second page body")

        def capture() -> None:
            read_available(master_fd, output)
            start = len(output)
            os.write(master_fd, b"\x0f")
            wait_for_output(process, master_fd, output, b"a=T", start=start, timeout=3.0)
            if b"f=100" not in bytes(output[start:]):
                raise AssertionError("screenshot did not use the PNG image viewer")

        capture()
        if requests != [{"lane": "live", "clientId": client_id, "tabId": 2}]:
            raise AssertionError(f"screenshot did not bind the selected live tab: {requests!r}")
        send_and_wait(process, master_fd, output, b"\x1b", b"second page body")
        send_and_wait(process, master_fd, output, b"a", b"second page body")
        send_and_wait(process, master_fd, output, b"g", b"Ctrl-U:clear")
        draft = b"https://example.org/?q=draft"
        send_and_wait(process, master_fd, output, b"\x1b[200~" + draft + b"\x1b[201~", draft)
        os.write(master_fd, b"\x0f")
        if not wait_for_fixture_event(process, master_fd, output, requested, timeout=3.0):
            raise AssertionError("screenshot request never reached the fixture")
        send_and_wait(process, master_fd, output, b"x", draft + b"x")
        # Enter intentionally does not change this busy frame. Observe its
        # state after a real resize, rather than requiring unchanged rows to
        # be emitted again by the differential frame presenter.
        os.write(master_fd, b"\r")
        wait_for_terminal_input_consumed(_slave_fd)
        drain_until_quiet(process, master_fd, output)
        retained = resize_and_wait(process, master_fd, output,
            rows=31, columns=101, needle=b"Enter after completion", controls=(FULL_REDRAW,))
        if draft + b"x" not in CSI_RE.sub(b"", retained):
            raise AssertionError("pending screenshot lost the URL or its deferred Enter explanation")
        read_available(master_fd, output)
        cancelled_from = len(output)
        release.set()
        wait_for_output(process, master_fd, output, b"Read 12.5 ms", start=cancelled_from, timeout=3.0)
        if b"a=T" in bytes(output[cancelled_from:]):
            raise AssertionError("cancelled screenshot interrupted the URL draft")
        # A cancelled preview still settles its operation, so another capture works.
        capture()
        restored = send_and_wait(process, master_fd, output, b"\x1b", draft + b"x")
        if draft + b"x " in CSI_RE.sub(b"", restored).split(b"\xe2\x96\x8f")[0]:
            raise AssertionError("image dismissal typed into the retained URL draft")
        send_and_wait(process, master_fd, output, b"\x1b", b"g:URL")
        send_and_wait(process, master_fd, output, b"]", b"first page body")
        send_and_wait(process, master_fd, output, b"\x0f", b"selected Firefox tab closed")
        if requests[-1] != {"lane": "automation", "tabId": 1}:
            raise AssertionError("closed-tab screenshot silently changed target")
        send_and_wait(process, master_fd, output, b"r", b"second page body")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
        os.write(master_fd, b"q")

    try:
        run_terminal_scenario(executable, description="Browser screenshot ownership and URL preservation",
            interact=interact, http_fixtures=fixtures, prepare_workspace=prepare,
            preload_input=GRAPHICS_SUPPORTED_REPLY)
    finally:
        release.set()


def run_config_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    initial = {
        **runtime_config_read_metadata(),
        "path": "/workspace/config/runtime.toml",
        "source_text": config_navigation_source(),
    }
    reloaded = {
        **initial,
        "source_revision": "fixture-reloaded-revision",
        "source_text": config_navigation_source().replace("first-value = 1", "first-value = 9"),
    }
    fixtures[RUNTIME_CONFIG_RAW_PATH] = SequencedHttpResponse([(200, initial), (200, reloaded)])
    run_terminal_scenario(
        executable,
        description="Config value navigation, paging, and model temperature",
        interact=config_navigation_interaction(),
        http_fixtures=fixtures,
    )


# RFC-0429 §3.3 draws a mermaid fence rather than lexing it, and §4 asks a
# chat PTY scenario to show that the drawing reaches the screen. The golden
# suite (test_tui_mermaid) already pins what the renderer produces; what it
# cannot see is the wiring -- chat text goes through Masc_tui_render's
# [chat_markdown], which reaches Masc_tui_markdown under a local alias, and a
# fence whose language is not routed there falls through to the plain code
# path and prints its own source.
MERMAID_CHAT_SOURCE_ARROW = b"-->"
MERMAID_CHAT_LABELS = (b"Intake", b"Gate", b"Keeper")


def mermaid_chat_history_fixture() -> HttpResponse:
    return (
        200,
        [
            {
                "id": "mermaid-chat-reply",
                "role": "assistant",
                "content": (
                    "Here is the shape:\n\n"
                    "```mermaid\n"
                    "graph TD\n"
                    "  intake[Intake] --> gate{Gate}\n"
                    "  gate --> keeper[Keeper]\n"
                    "```\n"
                ),
                "ts": 1787348491.3,
            }
        ],
    )


def mermaid_chat_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    # run_terminal_scenario already opens the pty at 30x100, so resizing to
    # that size draws nothing and a wait on the first screen starves.
    wait_for_output(
        process, master_fd, output, b"MASC Overview", start=0, timeout=5.0
    )
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    # Enter opens the keeper's Info tabs; the transcript hangs off the palette.
    # The wait needle is a node label because the fallback prints the source,
    # which carries the labels too -- the assertions below, not this wait,
    # decide whether it was drawn.
    drawn = palette_go(
        process, master_fd, output, b"keeper alpha", MERMAID_CHAT_LABELS[0]
    )
    # A frame carries only the rows that changed, so the box may have been
    # written before the row this wait returned on. Ask the reconstructed
    # screen, not the last frame.
    screen = screen_text(drawn)

    missing = [label for label in MERMAID_CHAT_LABELS if label not in screen]
    if missing:
        raise AssertionError(
            "the mermaid fence lost its node labels "
            f"{[label.decode() for label in missing]}: {screen!r}"
        )
    if MERMAID_CHAT_SOURCE_ARROW in screen:
        raise AssertionError(
            "the mermaid fence printed its own source instead of a drawing -- "
            "either the fence never reached Masc_tui_mermaid, or the render "
            f"failed and fell back to the source: {screen!r}"
        )
    # Labels without a frame around them would also satisfy the two checks
    # above, and that is what the plain code path draws.
    if not any(glyph in screen for glyph in ("┌".encode(), "─".encode(), "│".encode())):
        raise AssertionError(
            f"the node labels are on screen but nothing was drawn around them: {screen!r}"
        )

    # Leaving the transcript before q: the chat surface does not quit on q,
    # and where Escape lands (keeper detail or the list) is not what this
    # scenario is about. send_and_wait only scans bytes written after the key,
    # so the repainted tab bar is enough to say the surface changed.
    send_and_wait(process, master_fd, output, b"\x1b", b"Keepers")
    os.write(master_fd, b"q")


def run_mermaid_chat_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="A mermaid fence in keeper chat is drawn, not printed",
        interact=mermaid_chat_interaction,
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": mermaid_chat_history_fixture(),
            "/api/v1/keepers/alpha/chat/history/page": (
                200,
                {"messages": [], "has_more": False, "next_before": None},
            ),
        },
    )


# RFC-0429 §1.3 and §4. The second recorded change carries
# "let b = 2\nlet c = 3", and the Changes list has one line per row to say it
# in. Printing the newline writes the rest of the row wherever the terminal's
# cursor lands; Tui_decode.preview_line projects it to one cell instead.
#
# This is its own lane rather than an assertion inside the default keyboard
# regression: that lane stops before reaching the Changes surface, at the exit
# step of "A spilled paste is written where the keeper reads" (issue filed), so
# an assertion added there would never run and would read as green.
CHANGES_NEWLINE_PROJECTED = "let b = 2\u23celet c = 3".encode()


def changes_newline_projection_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    open_changes(process, master_fd, output)
    send_and_wait(process, master_fd, output, b"\x1b[B", b"preview masc:lib/second.ml")

    rows = screen_rows(bytes(output))
    carrying_a_newline = sorted(row for row, text in rows.items() if b"\n" in text)
    if carrying_a_newline:
        raise AssertionError(
            "the Changes frame printed a raw newline on row(s) "
            f"{carrying_a_newline}: { {row: rows[row] for row in carrying_a_newline} !r}"
        )
    if CHANGES_NEWLINE_PROJECTED not in screen_text(bytes(output)):
        naming = [text for text in rows.values() if b"second.ml" in text]
        raise AssertionError(
            f"the WHAT column did not project the newline to one cell: {naming!r}"
        )
    os.write(master_fd, b"q")


def run_changes_newline_regression(executable: str) -> None:
    fixtures = keeper_runtime_http_fixtures()
    fixtures[FILE_CHANGES_ALPHA_PATH] = file_changes_alpha_response()
    run_terminal_scenario(
        executable,
        description="A recorded newline is one cell in the Changes list",
        interact=changes_newline_projection_interaction,
        http_fixtures=fixtures,
    )


# The schedule scenario lives inside the default keyboard lane, which stops
# at an earlier scenario's exit step (#34125): an assertion added there is
# never reached. This lane runs the one scenario, so the assertion is
# measured rather than assumed.
def run_schedule_delivery_regression(executable: str) -> None:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        listing = palette_go(
            process, master_fd, output, b"go schedules", b"MASC Schedules"
        )
        plain = CSI_RE.sub(b"", listing)
        for needle in (
            # The enqueue result, which the row already carried.
            b"wake:succeeded",
            # What became of the wake, beside it. The separator is part of
            # the needle: the word alone also appears in the reaction line
            # under the list, which is the surface this is not testing.
            "\u00b7consumed_ack".encode(),
        ):
            if needle not in plain:
                raise AssertionError(
                    f"Schedule list omitted {needle!r}: {plain!r}"
                )
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="Schedule list rows say what became of the wake",
        interact=interact,
        http_fixtures=schedule_detail_http_fixtures(),
    )


def run_schedule_source_status_regression(executable: str) -> None:
    binary_sha256 = hashlib.sha256(Path(executable).read_bytes()).hexdigest()
    for initial_error in (True, False):
        fixtures = schedule_detail_http_fixtures()
        good = fixtures[SCHEDULES_PATH]
        assert isinstance(good, tuple)
        recovered = json.loads(json.dumps(good[1]))
        recovered["requests"][0]["status"] = "scheduled"
        recovered["requests"][0]["payload_target"] = "recovered-keeper"
        recovered["requests"][0]["payload"]["body"]["keeper_name"] = "recovered-keeper"
        fail_reads = threading.Event()
        recovered_reads = threading.Event()
        if initial_error:
            fail_reads.set()
        fixtures[SCHEDULES_PATH] = lambda: (
            (503, {"error": "unavailable"}) if fail_reads.is_set()
            else (200, recovered) if recovered_reads.is_set()
            else good
        )
        fixtures[SCHEDULES_PATH + "?schedule_id=schedule-proof-701"] = (
            200, {"status": "found", "schedule_id": "schedule-proof-701",
                  "wakes": [], "wake_retention_per_schedule": 1},
        )

        def interact(process, master_fd, _slave_fd, output, _base_path):
            def require(*labels: str) -> bytes:
                screen = screen_text(bytes(output))
                for label in labels:
                    if label.encode() not in screen:
                        raise AssertionError(f"Schedules omitted {label!r}: {screen!r}")
                return screen

            def evidence(phase: str) -> None:
                captured = bytes(output)
                end = captured.rfind(FRAME_END)
                if end < 0:
                    raise AssertionError("Schedules evidence has no completed terminal frame")
                end += len(FRAME_END)
                redraw = captured.rfind(FULL_REDRAW, 0, end)
                start = captured.rfind(FRAME_START, 0, redraw) if redraw >= 0 else -1
                if start < 0:
                    raise AssertionError("Schedules evidence has no complete redraw origin")
                # Preserve exact ANSI, including all complete deltas since
                # the last full redraw. Compression keeps all four measured
                # screens within Dune's output allowance for browser replay.
                print("SCHEDULE_SOURCE_PTY_EVIDENCE " + json.dumps({
                    "phase": phase, "initial_error": initial_error,
                    "fixture": "isolated HTTP source status", "rows": 30, "columns": 100,
                    "binary_sha256": binary_sha256, "encoding": "zlib+base64",
                    "pty": base64.b64encode(zlib.compress(captured[start:end])).decode(),
                }), flush=True)

            palette_go(process, master_fd, output, b"go schedules",
                       b"503" if initial_error else b"status:running")
            if initial_error:
                screen = require("data unreliable:", "schedule load failed:", "503")
                for absent in (b"Requests: 0", b"no scheduled automation", b"schedule-proof-701"):
                    if absent in screen:
                        raise AssertionError(f"Failed initial source invented data: {screen!r}")
                evidence("initial-read-failed")
            else:
                require("schedule-proof-701", "status:running", "Requests: 1")
                fail_reads.set()
                send_and_wait(process, master_fd, output, b"r", b"503")
                require("이전 조회 유지 ·", "503", "schedule-proof-701",
                        "status:running", "Requests: 1")
                evidence("retained-list-refresh-failed")
                send_and_wait(process, master_fd, output, b"\x1b[C", b"instance-proof-701")
                require("이전 조회 유지 ·", "503", "instance-proof-701")
                # The warning belongs to the source, so it remains visible
                # while the retained detail body is scrolled.
                send_and_wait(process, master_fd, output, b"\x1b[6~", b"DELIVERY EVIDENCE")
                require("이전 조회 유지 ·", "503")
                send_and_wait(process, master_fd, output, b"\x1b[D", b"status:running")

            recovered_reads.set()
            fail_reads.clear()
            send_and_wait(process, master_fd, output, b"r", b"recovered-keeper")
            screen = require("status:scheduled", "Requests: 1", "schedule-proof-701")
            for absent in ("조회 실패:", "갱신 실패:", "503", "status:running"):
                if absent.encode() in screen:
                    raise AssertionError(f"Recovered source retained old status: {screen!r}")
            evidence("source-recovered")
            os.write(master_fd, b"q")

        run_terminal_scenario(
            executable,
            description=f"Schedules source status: {'initial' if initial_error else 'refresh'}",
            interact=interact, http_fixtures=fixtures,
        )


# The Board draft is written in the default keyboard lane, which stops at an
# earlier scenario's exit step (#34125). This lane runs the one thing: the
# footer's offer and what the key it offered actually does.
def run_board_compose_footer_regression(executable: str) -> None:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        palette_go(process, master_fd, output, b"go board", b"MASC Board")
        writing = send_and_wait(process, master_fd, output, b"w", b"type to write")
        if b"q:quit" in CSI_RE.sub(b"", writing):
            raise AssertionError(
                "the writing footer offers q:quit, and q types a q: "
                f"{CSI_RE.sub(b'', writing)!r}"
            )
        # The other half of the same fact. The footer may not name a key as
        # quit while the draft takes it as a letter, so the letter has to be
        # seen landing.
        try:
            send_and_wait(process, master_fd, output, b"quit-goes-in", b"quit-goes-in")
        except AssertionError as timed_out:
            raise AssertionError(
                "the draft did not take 'quit-goes-in' as text, so whether the "
                f"footer may name q as quit is unmeasured here: {timed_out}"
            ) from timed_out
        # Out the way the armed footer names, not the way the old one did.
        send_and_wait(process, master_fd, output, b"\x1b", b"d:discard")
        send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="The Board writing footer offers no key that types",
        interact=interact,
    )


def run_chat_clarity_regression(executable: str) -> None:
    fixtures = chat_clarity_http_fixtures()
    tool_calls_path = "/api/v1/keepers/alpha/tool-calls?limit=100"
    tool_calls_response = fixtures[tool_calls_path]
    if not isinstance(tool_calls_response, tuple):
        raise AssertionError("chat clarity tool-call fixture must be a JSON response")
    tool_calls_gate = GatedHttpResponse(
        tool_calls_response,
        subsequent_response=tool_calls_response,
    )
    fixtures[tool_calls_path] = tool_calls_gate
    run_terminal_scenario(
        executable,
        description="Keeper chat mode and Tool detail clarity",
        interact=chat_visibility_modes_interaction(tool_calls_gate),
        http_fixtures=fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Skill usage date clarity",
        interact=skills_usage_clarity_interaction(),
        http_fixtures=skills_usage_clarity_http_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Keeper oversized viewport gap under NO_COLOR",
        interact=viewport_gap_interaction,
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": viewport_gap_history_fixture(),
            "/api/v1/keepers/alpha/chat/history/page": (
                viewport_gap_history_page_fixture()
            ),
        },
        extra_env={"NO_COLOR": "1"},
    )


def run_runtime_regression(executable: str) -> None:
    fixtures, initial_probe, force_probe = runtime_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Runtime lane and catalog exact detail",
        interact=runtime_surface_interaction(fixtures, initial_probe, force_probe),
        refresh=0.05,
        http_fixtures=fixtures,
    )


def resources_mcp_fixture() -> HttpFixtures:
    events = {"status": "ok", "count": 2}
    for index in range(32):
        events[f"event_{index:02d}"] = f"event value {index:02d}"
    events["tail_marker"] = "visible after scrolling"
    handbook_lines = "\n".join(
        f"- handbook evidence line {index:02d}" for index in range(28)
    )
    handbook = (
        "# Operator handbook\n\n"
        "- Read the description before the payload.\n\n"
        "```toml\nslots = 4\n```\n\n"
        f"{handbook_lines}\n\n"
        "```json\n{\n  \"nested\": true,\n  \"proof\": 42\n}\n```\n\n"
        "markdown_tail_marker"
    )

    def answer(body: bytes) -> RawHttpResponse:
        request = json.loads(body)
        request_id = request.get("id")
        method = request.get("method")
        headers: tuple[tuple[str, str], ...] = ()
        if method == "initialize":
            result: object = {}
            headers = (("Mcp-Session-Id", "resource_fixture_session"),)
        elif method == "resources/list":
            result = {
                "resources": [
                    {
                        "uri": "masc://events.json?limit=50",
                        "name": "Recent Events (JSON)",
                        "title": "Event Log (JSON)",
                        "description": "Recent event log snapshot as JSON",
                        "mimeType": "application/json",
                        "size": 321,
                    },
                    {
                        "uri": "masc://operator-handbook.md",
                        "name": "Operator Handbook",
                        "title": "Operator Handbook",
                        "description": "How an operator reads MCP resources",
                        "mimeType": "text/markdown",
                        "size": 96,
                    },
                ]
            }
        elif method == "resources/read":
            uri = request.get("params", {}).get("uri")
            if uri == "masc://events.json?limit=50":
                result = {
                    "contents": [
                        {
                            "uri": uri,
                            "mimeType": "application/json",
                            "text": json.dumps(events, separators=(",", ":")),
                        }
                    ]
                }
            elif uri == "masc://operator-handbook.md":
                result = {
                    "contents": [
                        {
                            "uri": uri,
                            "mimeType": "text/markdown",
                            "text": handbook,
                        }
                    ]
                }
            else:
                result = {"contents": []}
        else:
            result = {}
        payload = {"jsonrpc": "2.0", "id": request_id, "result": result}
        return RawHttpResponse(
            200,
            json.dumps(payload).encode(),
            content_type="application/json",
            headers=headers,
        )

    fixtures = overview_event_http_fixtures()
    fixtures["/mcp"] = RequestHttpResponse(answer)
    return fixtures


def resources_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # Resources hangs off Config under [s]; the listing row proves
        # the surface arrived loaded through the hop.
        tab_until(process, master_fd, output, b"MASC Config")
        send_and_wait(process, master_fd, output, b"s", b"Event Log (JSON)")
        detail = send_and_wait(
            process, master_fd, output, b"\r", b'"status"'
        )
        plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"MCP resource",
            b"read-only data exposed by this server",
            b"masc://events.json?limit=50",
            b"application/json",
            b"321 bytes",
            b'"status": "ok"',
        ):
            if needle not in plain:
                raise AssertionError(
                    f"Resources JSON detail omitted {needle!r}: {plain!r}"
                )
        lexed_key = re.compile(
            rb"\x1b\[[0-9;]*m" + re.escape(b'"status"') + rb"\x1b\[0m"
        )
        if lexed_key.search(detail) is None:
            raise AssertionError(
                f"Resources JSON was pretty but not syntax-highlighted: {detail!r}"
            )

        narrow = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=80,
            needle=b"MCP resource",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        narrow_plain = CSI_RE.sub(b"", narrow)
        for needle in (b"Recent event log snapshot", b"application/json"):
            if needle not in narrow_plain:
                raise AssertionError(
                    f"80-column Resources detail omitted {needle!r}: {narrow_plain!r}"
                )

        wide = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=140,
            needle=b"masc://events.json?limit=50",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        if b'"status": "ok"' not in CSI_RE.sub(b"", wide):
            raise AssertionError(f"140-column JSON detail lost its payload: {wide!r}")

        markdown = send_and_wait(
            process, master_fd, output, b"]", b"Operator handbook"
        )
        markdown_plain = CSI_RE.sub(b"", markdown)
        for needle in (b"Operator handbook", b"slots = 4", b"96 bytes"):
            if needle not in markdown_plain:
                raise AssertionError(
                    f"] did not open the next resource detail ({needle!r}): "
                    f"{markdown_plain!r}"
                )
        markdown_tail = send_and_wait(
            process,
            master_fd,
            output,
            b"j" * 48,
            b"markdown_tail_marker",
        )
        markdown_tail_plain = CSI_RE.sub(b"", markdown_tail)
        for needle in (b'"nested": true', b"markdown_tail_marker"):
            if needle not in markdown_tail_plain:
                raise AssertionError(
                    f"Markdown fenced-code scrolling omitted {needle!r}: "
                    f"{markdown_tail_plain!r}"
                )

        previous = send_and_wait(
            process, master_fd, output, b"[", b'"status"'
        )
        if b"Event Log (JSON)" not in CSI_RE.sub(b"", previous):
            raise AssertionError(f"[ did not reopen the previous resource: {previous!r}")
        tail = send_and_wait(
            process,
            master_fd,
            output,
            b"j" * 48,
            b"visible after scrolling",
        )
        if b"tail_marker" not in CSI_RE.sub(b"", tail):
            raise AssertionError(f"long JSON could not be scrolled to its tail: {tail!r}")
        os.write(master_fd, b"q")

    return interact


def run_resources_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Resources metadata, pretty payload, and detail stepping",
        interact=resources_detail_interaction(),
        http_fixtures=resources_mcp_fixture(),
    )


def run_keeper_lanes_regression(executable: str) -> None:
    fixtures = keeper_runtime_http_fixtures()
    gate = GatedHttpResponse(
        keeper_lanes_response(
            [
                keeper_lane_row(
                    "alpha",
                    phase="running",
                    turn_phase="idle",
                    idle_seconds=75,
                    runtime_state="done",
                    selected_model="claude-opus-5",
                    diagnosis="running_fiber_alive",
                ),
                keeper_lane_row(
                    "beta",
                    phase="failing",
                    turn_phase="executing",
                    idle_seconds=3599,
                    runtime_state="done",
                    selected_model=None,
                    diagnosis="failing_unhealthy",
                ),
            ]
        )
    )
    fixtures[KEEPER_LANES_PATH] = gate
    fixtures[STANDALONE_LANES_PATH] = standalone_lanes_response()
    fixtures[lane_runs_path("verifier_exact")] = verifier_lane_runs_response()
    fixtures[
        "/api/v1/dashboard/exact-lane-runs/vrf-fixture"
    ] = verifier_lane_run_detail_response()
    fixtures[lane_runs_path("hitl_auto_judge")] = hitl_lane_runs_response()
    fixtures[
        "/api/v1/dashboard/exact-lane-runs/hitl-fixture"
    ] = hitl_lane_run_detail_response()
    fixtures[RUNTIME_CONFIG_RAW_PATH] = standalone_lane_runtime_config_response()
    run_terminal_scenario(
        executable,
        description="Keepers operations and Standalone-only Lanes",
        interact=keeper_lanes_ia_interaction(gate, fixtures),
        http_fixtures=fixtures,
    )


def run_code_memo_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Code lane lists a memo in a language with no lexer",
        interact=code_memo_interaction,
        http_fixtures=code_memo_fixtures(),
    )


def run_memory_journal_regression(executable: str) -> None:
    memory_journal_sequence = SequencedHttpResponse([memory_journal_fixture()])
    run_terminal_scenario(
        executable,
        description="Keeper Memory journal timeline",
        interact=memory_journal_timeline_interaction(memory_journal_sequence),
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": memory_journal_chat_fixture(),
            # Reading back asks for the page behind the oldest row it holds,
            # matched independent of its timestamp. Without an answer the pane
            # draws the load error instead of the reading-back status row,
            # and the scroll-pin claim below has nothing to measure against.
            "/api/v1/keepers/alpha/chat/history/page": (
                200, {"messages": [], "has_more": False, "next_before": None}
            ),
            "/api/v1/keepers/alpha/memory-journal?limit=20": memory_journal_sequence,
        },
        refresh=0.5,
    )


def run_board_json_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Board JSON pretty-print and syntax highlighting",
        interact=board_json_interaction(),
        http_fixtures=board_json_http_fixtures(),
    )


def run_theme_scheme_regression(executable: str) -> None:
    """Picking a scheme sends the whole scheme, colour codes included.

    The gap this closes: between #30781 and the OSC 4 change, a pick sent the
    page and the default text and nothing else. Everything masc says with
    colour is drawn by naming a code, so a scheme reached the two quietest
    colours on the screen and stopped. The catalogue's high-contrast schemes
    were hit hardest -- the readability lift was the only path a chosen colour
    had to a code, and a scheme that needs no lift got none, so picking the
    top row changed nothing at all.

    Driven through the picker rather than the presenter because the presenter
    already has unit cover. What was missing was nobody asking whether the key
    the reader presses reaches it.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Config")
        # [p] cycles the Config panes and themes is the last of them, so the
        # walk stops on the header rather than counting presses.
        for _ in range(8):
            if b"MASC Themes" in CSI_RE.sub(b"", bytes(output)):
                break
            send_and_wait(process, master_fd, output, b"p", b"MASC ")
        else:
            raise AssertionError("[p] never reached the themes pane")

        # A scheme that ships only as TOML. Until the catalogue started
        # reading config/themes out of the binary, these loaded from the
        # reader's base path and a live workspace is not this repo, so the
        # picker listed only what OCaml carried and cyber was measured by the
        # contracts while nobody could choose it.
        pane = CSI_RE.sub(b"", bytes(output))
        if b"cyber" not in pane:
            raise AssertionError(
                "the picker does not list cyber: a shipped TOML scheme is not "
                "reaching the reader"
            )

        before = len(output)
        # The cursor opens on the first row, which the picker sorts to be a
        # native-pass scheme -- the case that used to send nothing.
        send_and_wait(process, master_fd, output, b"\r", b"Enter picks another")
        sent = bytes(output[before:])

        if b"\x1b]4;" not in sent:
            raise AssertionError(
                "picking a scheme sent no OSC 4: the colour codes stayed the "
                "terminal's, so nothing masc says with colour moved"
            )
        if b"\x1b]10;" not in sent or b"\x1b]11;" not in sent:
            raise AssertionError("picking a scheme stopped sending the page")

        # Back to Overview, then arm the quit the harness confirms with its
        # own second press.
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
        send_and_wait(
            process, master_fd, output, b"q", b"q: press again to quit"
        )

    run_terminal_scenario(
        executable,
        description="picking a theme sends its colour codes",
        interact=interact,
    )


# What the MSX screen draws when it opens. RFC-0439 3.7 has it open the load
# menu first, so this is the title an arrival is proved by; the spectator's own
# "no machine loaded" line belongs to the screen behind the menu.
MSX_MENU_TITLE = "MSX \u2014 pick a game".encode()

# The machine's frame, as the server sends it (server_routes_http_routes_msx:
# 256x192x3 raw RGB, base64 in the JSON).
MSX_FRAME_WIDTH = 256
MSX_FRAME_HEIGHT = 192
MSX_HALF_BLOCK = "\u2580".encode()
MSX_LEFT_HALF = b"38;2;255;0;0"
MSX_RIGHT_HALF = b"38;2;0;0;255"
# What fit_grid picks for this frame in the harness's 30-row, 100-column
# window: the height binds (2*(30-2) = 56 rows), so the width follows the
# frame's ratio at 56*256/192 = 74. Filling the window instead would draw 100,
# which is the frame a third wider than itself.
MSX_EXPECTED_CELLS = 74


def msx_loaded_frame_fixture() -> HttpResponse:
    """A frame split down the middle: red left, blue right.

    Two flat halves rather than a picture, because what the drawn rows have to
    say is geometric -- how many cells the picture is wide, and that the halves
    stayed halves. A photograph would say it too and could not be checked by
    reading the bytes.
    """
    row = (
        bytes([255, 0, 0]) * (MSX_FRAME_WIDTH // 2)
        + bytes([0, 0, 255]) * (MSX_FRAME_WIDTH - MSX_FRAME_WIDTH // 2)
    )
    return (
        200,
        {
            "loaded": True,
            "number": 1,
            "width": MSX_FRAME_WIDTH,
            "height": MSX_FRAME_HEIGHT,
            "mode": "SCREEN2",
            "cartridge": "split.rom",
            "rgb_base64": base64.b64encode(row * MSX_FRAME_HEIGHT).decode("ascii"),
        },
    )


def msx_spectator_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """Watch a loaded machine, and read the shape of what was drawn.

    The screen paints the whole terminal itself, outside the frame presenter,
    so there is no frame-end marker to wait on -- the raw output carries the
    title, as the palette scenario already relies on.
    """
    read_available(master_fd, output)
    start = len(output)
    os.write(master_fd, b":go msx\r")
    # A loaded machine puts a watch row at the top of the menu (RFC-0439 3.7).
    wait_for_output(process, master_fd, output, b"watch split.rom", start=start,
                    timeout=5.0)
    # Entering the spectator paints past the frame presenter too, so the wait
    # is on raw output; send_and_wait would starve on a frame-end marker that
    # this screen never writes.
    watched_from = len(output)
    os.write(master_fd, b"\r")
    # The footer is the last line the screen writes, so waiting on it is
    # waiting for every mosaic row to have been written. Waiting on the title
    # instead read rows that were still going out, and a half-written row is
    # narrower than the picture.
    wait_for_output(process, master_fd, output, b"Esc: back",
                    start=watched_from, timeout=5.0)
    watching = bytes(output)[watched_from:]
    if b"spectating the server" not in watching:
        raise AssertionError(f"the spectator title is missing: {watching[:200]!r}")

    drawn = [
        line
        for line in CSI_RE.sub(b"", watching).split(b"\n")
        if MSX_HALF_BLOCK in line
    ]
    if not drawn:
        raise AssertionError(f"the spectator drew no picture: {watching!r}")

    odd = [line for line in drawn if line.count(MSX_HALF_BLOCK) != MSX_EXPECTED_CELLS]
    if odd:
        raise AssertionError(
            "the picture is not the frame's shape: this frame asks for "
            f"{MSX_EXPECTED_CELLS} cells a row and "
            f"{[(line.count(MSX_HALF_BLOCK), line[:60]) for line in odd[:3]]!r}"
        )
    # Pillarboxed, not stretched: the leftover columns stay blank, and the
    # picture sits between them.
    if not all(line.startswith(b" ") for line in drawn):
        raise AssertionError(f"the picture was not centred: {drawn[0]!r}")

    # The halves stayed halves. Both colours are on every row, and the row's
    # own bytes say which came first.
    if MSX_LEFT_HALF not in watching or MSX_RIGHT_HALF not in watching:
        raise AssertionError(
            "a flat red half and a flat blue half did not both reach the "
            f"terminal: {watching[:400]!r}"
        )
    if watching.find(MSX_LEFT_HALF) > watching.find(MSX_RIGHT_HALF):
        raise AssertionError("the halves were drawn in the wrong order")

    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
    os.write(master_fd, b"q")


def msx_size_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """The size keys step how much of the screen the picture takes.

    The footer carries the current size, so each key press is verified by the
    number that lands after it -- the fraction steps in eighths, so the marks
    are 100, 87, 75.
    """
    read_available(master_fd, output)
    start = len(output)
    os.write(master_fd, b":go msx\r")
    wait_for_output(process, master_fd, output, b"watch split.rom", start=start,
                    timeout=5.0)
    watched_from = len(output)
    os.write(master_fd, b"\r")
    wait_for_output(process, master_fd, output, b"+/-: 100%", start=watched_from,
                    timeout=5.0)

    down_from = len(output)
    os.write(master_fd, b"-")
    wait_for_output(process, master_fd, output, b"+/-: 87%", start=down_from,
                    timeout=5.0)

    down_again = len(output)
    os.write(master_fd, b"-")
    wait_for_output(process, master_fd, output, b"+/-: 75%", start=down_again,
                    timeout=5.0)

    up_from = len(output)
    os.write(master_fd, b"+")
    wait_for_output(process, master_fd, output, b"+/-: 87%", start=up_from,
                    timeout=5.0)

    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
    os.write(master_fd, b"q")


def run_msx_retained_regression(executable: str, *, retained_tick: bool = False) -> None:
    """Exercise retained Kitty pixels through the real TUI and private HTTP."""
    number = [1]
    changed = threading.Event()
    original = msx_loaded_frame_fixture()[1]
    pixel_responses: list[dict[str, object]] = []

    def tick(request_body: bytes = b""):
        number[0] += 1
        body = dict(original, number=number[0])
        if changed.is_set():
            body["rgb_base64"] = base64.b64encode(
                bytes([0, 255, 0]) * MSX_FRAME_WIDTH * MSX_FRAME_HEIGHT
            ).decode("ascii")
        if retained_tick:
            request = json.loads(request_body)
            assert request.get("pixel_response") == "retained", request
            encoded = body.pop("rgb_base64")
            reference = {
                "revision": hashlib.sha256(base64.b64decode(encoded)).hexdigest(),
                "width": body["width"], "height": body["height"],
            }
            retained = request.get("known_pixels") == reference
            body["pixels"] = dict(reference, kind="retained" if retained else "inline")
            if not retained:
                body["pixels"]["rgb_base64"] = encoded
            pixel_responses.append({
                "number": number[0], "kind": body["pixels"]["kind"],
                "revision": reference["revision"], "bytes": len(json.dumps(body)),
            })
        return 200, body

    def interact(process, master, _slave, output, _base):
        def footer_after(marker, start):
            wait_for_output(process, master, output, marker, start=start, timeout=5.0)
            marker_end = output.index(marker, start) + len(marker)
            footer = b"F8: disk"
            wait_for_output(process, master, output, footer,
                            start=marker_end, timeout=5.0)
            return output.index(footer, marker_end) + len(footer)

        def key(value, needle):
            start = len(output)
            os.write(master, value)
            wait_for_output(process, master, output, needle, start=start, timeout=5.0)
            return bytes(output[start:])

        key(b":go msx\r", b"watch split.rom")
        first = key(b"\r", b"F6: save quick")
        assert b"f=24" in first, "Kitty path was not negotiated"
        start = len(output)
        target = number[0] + 3
        end = footer_after(f"frame {target} ".encode(), start)
        steady = bytes(output[start:end])
        assert b"f=24" not in steady, "unchanged pixels were retransmitted"
        assert b"\x1b[2J" not in steady, "unchanged pixels erased the display"
        assert b"a=d" not in steady, "unchanged pixels deleted the image"
        if retained_tick:
            assert pixel_responses[0]["kind"] == "inline", pixel_responses
            assert sum(row["kind"] == "retained" for row in pixel_responses) >= 2, pixel_responses
            assert all(row["bytes"] < pixel_responses[0]["bytes"]
                       for row in pixel_responses if row["kind"] == "retained")
        before_change = len(pixel_responses)
        start = len(output)
        changed.set()
        end = footer_after(b"i=32,p=1,C=1", start)
        replacement = bytes(output[start:end])
        assert b"f=24" in replacement, "changed pixels were not transmitted"
        if retained_tick:
            replacements = pixel_responses[before_change:]
            assert any(row["kind"] == "inline"
                       and row["revision"] != pixel_responses[0]["revision"]
                       for row in replacements), replacements
        assert b"\x1b[2J" not in replacement, "replacement erased the display"
        start = len(output)
        os.write(master, b"-")
        end = footer_after(b"+/-: 87%", start)
        resized = bytes(output[start:end])
        assert b"d=I,i=32" in resized, "resize retained the old placement"
        assert b"f=24" in resized, "resize did not place pixels again"
        exited = key(b"\x1b", b"MASC Overview")
        assert b"d=I,i=32" in exited, "exit left the image behind"
        key(b":go msx\r", b"watch split.rom")
        reopened = key(b"\r", b"F6: save quick")
        assert b"f=24" in reopened, "reopening reused a deleted image"
        print(f"MSX PTY wire: first={len(first)} steady_three_polls={len(steady)} "
              f"replacement={len(replacement)} bytes", flush=True)
        key(b"\x1b", b"MASC Overview")
        os.write(master, b"q")

    run_terminal_scenario(
        executable, description="MSX retains Kitty pixels between live polls",
        interact=interact, preload_input=GRAPHICS_SUPPORTED_REPLY,
        http_fixtures={"/api/v1/msx/frame": (200, original),
                       "/api/v1/msx/tick": RequestHttpResponse(tick) if retained_tick else tick},
    )
    if retained_tick:
        print(json.dumps({"msx_tick_pixels": pixel_responses}), flush=True)


def run_msx_background_poll_regression(executable: str) -> None:
    """A pending mutation must not own the terminal's input loop."""
    original = msx_loaded_frame_fixture()[1]
    late = dict(original, number=999, rgb_base64=base64.b64encode(
        bytes([0, 255, 0]) * MSX_FRAME_WIDTH * MSX_FRAME_HEIGHT).decode("ascii"))
    pending = GatedHttpResponse((200, late), hold_seconds=20.0)
    failed = GatedHttpResponse((503, {"error": "tick unavailable"}), hold_seconds=20.0)
    calls = []
    get_frames = []

    def frame():
        get_frames.append(len(get_frames) + 1)
        return 200, dict(original, number=100 + len(get_frames))

    def tick(body):
        calls.append(json.loads(body))
        if len(calls) == 1:
            return pending()
        if len(calls) == 2:
            return failed()
        return 503, {"error": "unexpected automatic mutation retry"}

    def kitty_rgb_transfers(wire):
        transfers = []
        chunks = None
        geometry = None
        for match in re.finditer(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\", wire):
            fields = dict(field.split(b"=", 1) for field in match[1].split(b",") if b"=" in field)
            if fields.get(b"f") == b"24":
                assert chunks is None, "new image interrupted a pending transfer"
                chunks = []
                geometry = (int(fields[b"s"]), int(fields[b"v"]))
            if chunks is not None:
                chunks.append(match[2])
                if fields.get(b"m", b"0") == b"0":
                    rgb = base64.b64decode(b"".join(chunks), validate=True)
                    assert len(rgb) == geometry[0] * geometry[1] * 3
                    transfers.append((geometry, rgb))
                    chunks = None
        assert chunks is None, "incomplete Kitty RGB transfer"
        return transfers

    def interact(process, master, slave, output, _base):
        def await_marker(marker, start):
            wait_for_output(process, master, output, marker, start=start, timeout=2.0)

        def key(keys, marker):
            start = len(output)
            os.write(master, keys)
            await_marker(marker, start)
            return start

        def observe_for(seconds):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                read_available(master, output)
                assert process.poll() is None, "TUI exited during observation"
                select.select([master], [], [], min(0.05, max(0, deadline - time.monotonic())))
            read_available(master, output)

        try:
            key(b":go msx\r", b"watch split.rom")
            key(b"\r", b"F8: disk")
            assert wait_for_fixture_event(process, master, output, pending.requested, timeout=5.0)
            assert not pending.completed.is_set(), "fixture did not hold the tick"
            # Scaling is a keyboard resize, and SIGWINCH is a physical resize.
            start = key(b"-", b"+/-: 87%")
            await_marker(b"F8: disk", start)
            assert not pending.completed.is_set(), "resize waited for the HTTP response"
            start = len(output)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 110, 0, 0))
            os.kill(process.pid, signal.SIGWINCH)
            await_marker(b"F8: disk", start)
            assert not pending.completed.is_set(), "terminal resize waited for the HTTP response"
            key(b"\x1b", b"MASC Overview")
            assert not pending.completed.is_set(), "Esc waited for the HTTP response"
            observe_for(0.8)  # More than two 0.3-second spectator poll intervals.
            assert len(calls) == 1, f"pending/closed view issued more ticks: {len(calls)}"
            before_get = len(get_frames)
            key(b":go msx\r", b"watch split.rom")
            assert len(get_frames) > before_get, "reopening skipped fresh observation"
            start = key(b"\r", b"F8: disk")
            assert b"f=24" in bytes(output[start:]), "fresh reopen did not restore image"
            expected_frame = 100 + len(get_frames)
            assert f"frame {expected_frame} ".encode() in bytes(output[start:])
            observe_for(0.8)
            assert not pending.completed.is_set(), "old tick finished before reopened-view test"
            assert len(calls) == 1, "reopening issued another mutation while one was pending"
            # The view is open again: msx_open alone cannot suppress this old
            # reply. Only the request's captured view identity distinguishes it.
            start = len(output)
            pending.release.set()
            assert wait_for_fixture_event(process, master, output, pending.completed, timeout=3.0)
            assert wait_for_fixture_event(process, master, output, failed.requested, timeout=5.0)
            # The next tick entering its gate proves the old completion was
            # consumed, while preventing another response from hiding damage.
            read_available(master, output)
            stale = bytes(output[start:])
            assert b"frame 999 " not in stale, "late metadata replaced the reopened snapshot"
            expected_pixels = ((original["width"], original["height"]),
                               base64.b64decode(original["rgb_base64"]))
            assert all(pixels == expected_pixels for pixels in kitty_rgb_transfers(stale)), "late green pixels replaced the reopened snapshot"
            assert len(calls) == 2, "settlement did not release exactly one pending slot"
            start = len(output)
            failed.release.set()
            await_marker(b"Refresh outcome unknown; reopen", start)
            observe_for(0.8)
            failure_output = bytes(output[start:])
            assert len(calls) == 2, f"failed mutation retried automatically: {len(calls)}"
            # The notice adds a header row, legitimately relocating/repainting
            # the image. Verify its contents and frame, not absence of commands.
            repaints = kitty_rgb_transfers(failure_output)
            assert repaints, "notice relayout did not repaint the cached image"
            expected_pixels = ((original["width"], original["height"]),
                               base64.b64decode(original["rgb_base64"]))
            assert all(pixels == expected_pixels for pixels in repaints), "failure repaint changed cached RGB"
            assert f"frame {expected_frame} ".encode() in failure_output, "failure lost cached frame identity"
            assert b"frame 999 " not in failure_output, "failure resurrected stale response"
            key(b"\x1b", b"MASC Overview")
            before_get = len(get_frames)
            key(b":go msx\r", b"watch split.rom")
            assert len(get_frames) > before_get, "failure recovery skipped fresh GET"
            assert len(calls) == 2, "menu entry advanced the machine"
            key(b"\x1b", b"F8: disk")
            key(b"\x1b", b"MASC Overview")
            os.write(master, b"q")
            print(json.dumps({"result": "PASS", "tick_calls": len(calls),
                "fresh_gets": len(get_frames), "pending_resize_and_escape": True,
                "late_frame_discarded": True, "failure_retry_suppressed": True}), flush=True)
        finally:
            pending.release.set()
            failed.release.set()

    run_terminal_scenario(executable, description="MSX asynchronous poll preserves terminal input",
        interact=interact, preload_input=GRAPHICS_SUPPORTED_REPLY,
        http_fixtures={"/api/v1/msx/frame": frame,
                       "/api/v1/msx/tick": RequestHttpResponse(tick)})


def run_msx_size_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="the size keys step the spectator's picture",
        interact=msx_size_interaction,
        http_fixtures={"/api/v1/msx/frame": msx_loaded_frame_fixture()},
    )


def run_msx_spectator_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="the spectator draws the machine's frame in its own shape",
        interact=msx_spectator_interaction,
        http_fixtures={"/api/v1/msx/frame": msx_loaded_frame_fixture()},
    )


def run_msx_palette_regression(executable: str) -> None:
    """The command palette opens the MSX screen by name.

    [&] opens the MSX spectator, but a key is found only by someone who
    already knows it; the palette is where an operator looks for a screen by
    name. This drives the typed path end to end: `:` then `go msx` must take
    the terminal over with the MSX screen, and Esc must hand it back.

    The harness serves no machine and no cartridges, so the screen opens on
    the load menu's own title (RFC-0439 3.7: the screen opens the menu
    first). That line is the proof the palette reached the screen at all; the
    Overview header afterwards is the proof Esc left it.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The MSX screen paints the whole terminal itself, outside the frame
        # presenter, so no frame-end marker follows it. Wait on the raw
        # output for its title line, the way the Browser screenshot
        # regression waits for its overlay.
        read_available(master_fd, output)
        start = len(output)
        os.write(master_fd, b":go msx\r")
        wait_for_output(
            process,
            master_fd,
            output,
            MSX_MENU_TITLE,
            start=start,
            timeout=3.0,
        )
        # Esc hands the terminal back to the presenter, whose frame ends the
        # normal way, so the plain helper serves from here on.
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
        send_and_wait(
            process, master_fd, output, b"q", b"q: press again to quit"
        )

    run_terminal_scenario(
        executable,
        description="the palette opens the MSX screen by name",
        interact=interact,
    )


def held_back_prompts_http_fixtures() -> HttpFixtures:
    """One prompt whose override the registry declined to restore.

    The registry keeps a rejected override on disk and reports it under
    `held_back`. The row itself still reads from its file, so without a mark
    of its own it renders exactly like a prompt nobody ever customized -- and
    an operator loses an override without learning they lost it.
    """
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/prompts"] = (
        200,
        {
            "prompts": [
                {
                    "key": "keeper",
                    "category": "keeper",
                    "operator_surface": "primary",
                    "description": "the keeper turn prompt",
                    "effective": "You are a keeper.",
                    "file_path": "config/prompts/keeper.md",
                    "source": "file",
                    "template_variables": [],
                }
            ],
            "held_back": [
                {
                    "key": "keeper",
                    "bytes": 1240,
                    "reason": "Unknown template variables: facts_json",
                }
            ],
        },
    )
    return fixtures


def run_held_back_override_regression(executable: str) -> None:
    """A held-back override is visible on the prompts screen.

    Before this the screen drew the row from its file with a blank mark, the
    same as an untouched prompt. The wire had carried `held_back` the whole
    time and the TUI snapshot dropped the field.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Config")
        for _ in range(8):
            if b"MASC \xed\x94\x84\xeb\xa1\xac\xed\x94\x84\xed\x8a\xb8" in bytes(output):
                break
            send_and_wait(process, master_fd, output, b"p", b"MASC ")
        else:
            raise AssertionError("[p] never reached the prompts pane")

        screen = screen_text(bytes(output))
        if "적용 안 된 오버라이드 1개".encode() not in screen:
            raise AssertionError(
                "the header does not count the held-back override, so a reader "
                "cannot see it without landing on the row"
            )
        if "\u2298".encode() not in screen:
            raise AssertionError("the held-back row carries no mark of its own")
        if b"Unknown template variables: facts_json" not in screen:
            raise AssertionError("the rejected variable is not visible beside recovery guidance")
        if b"You are a keeper." not in screen:
            raise AssertionError("override notices hid the effective template body")
        if "다시 저장하면".encode() not in screen:
            raise AssertionError(
                "the screen says the override is not applied and does not say "
                "how to put it back"
            )

        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
        send_and_wait(
            process, master_fd, output, b"q", b"q: press again to quit"
        )

    run_terminal_scenario(
        executable,
        description="a held-back override is visible",
        interact=interact,
        http_fixtures=held_back_prompts_http_fixtures(),
    )


def run_fusion_history_regression(executable: str) -> None:
    """Historical evidence remains inspectable without a retained run or recent Board row."""
    fixtures = overview_event_http_fixtures()
    run = fusion_run("history-701", keeper="not-a-proven-caller")
    post = fusion_detail_response(run, "historical-judge-synthesis-701")[1]["evidence"]["post"]
    post.update(author="board-author-701", body="original-board-body-701")
    # A recorded zero remains a chart observation; a failed panel has no usage.
    post["meta"]["panel"].append({
        "model": "panel-zero-701", "status": "answered",
        "answer": "zero-usage-answer-701", "input_tokens": 0, "output_tokens": 0,
    })
    post["meta"]["observed_usage"] = {"input_tokens": 101, "output_tokens": 202}
    refreshed = json.loads(json.dumps(post))
    refreshed["meta"]["observed_usage"]["input_tokens"] = 303
    wrong_post = json.loads(json.dumps(refreshed))
    wrong_post["origin"]["fusion_run_id"] = "different-run-702"
    response = fusion_runs_response([])
    response[1]["replay"] = {
        "status": "complete", "lines_read": 68,
        "malformed_lines": 34, "dropped_running": 34,
    }
    response[1]["historical_evidence"] = [{
        "run_id": "history-701", "post_id": post["id"],
        "title": post["title"], "created_at": 1787557684.0,
    }]
    second_post = json.loads(json.dumps(post))
    second_post.update(id="post-history-702", title="Second historical Fusion", author="board-author-702")
    second_post["origin"]["fusion_run_id"] = "history-702"
    second_post["meta"]["panel"] = [second_post["meta"]["panel"][1]]
    response[1]["historical_evidence"].append({
        "run_id": "history-702", "post_id": second_post["id"],
        "title": second_post["title"], "created_at": 1787557600.0,
    })
    fixtures[FUSION_RUNS_PATH] = response
    fixtures[f"/api/v1/board/{second_post['id']}"] = (200, second_post)
    fixtures[f"/api/v1/board/{post['id']}"] = SequencedHttpResponse([
        (200, post), (200, refreshed), (200, wrong_post), (200, refreshed),
    ])

    def interact(process, master_fd, slave_fd, output, base_path):
        palette_go(process, master_fd, output, b"go fusion", b"MASC Fusion")
        send_and_wait(process, master_fd, output, b"\r", b"HISTORICAL BOARD EVIDENCE")
        read_available(master_fd, output)
        before_resize = len(output)
        resize_and_wait(
            process, master_fd, output, rows=110, columns=170,
            needle=b"BOARD ORIGINAL", controls=(FULL_REDRAW,),
        )
        redraw = output.find(FULL_REDRAW, before_resize)
        if redraw < 0:
            raise AssertionError("historical inspector resize did not fully redraw")
        wait_for_output(process, master_fd, output, FRAME_END, start=redraw, timeout=3.0)
        end = output.find(FRAME_END, redraw) + len(FRAME_END)
        start = output.rfind(FRAME_START, before_resize, redraw)
        frame = bytes(output[redraw if start < 0 else start:end])
        visible = CSI_RE.sub(b"", frame)
        for marker in (
            b"This Board evidence does not provide execution status or finish time",
            b"Board author: board-author-701", b"Run reference: history-701",
            b"Observed tokens: 101 input / 202 output", b"Observed cost: not recorded",
            b"question-proof-501", b"panel-answer-first-501",
            b"historical-judge-synthesis-701", b"TOOL EXECUTIONS",
            b"original-board-body-701",
            b"measured 2/3 panels: 10 input / 20 output tokens",
            b"Panel 3 [answered] panel-zero-701  (0 in / 0 out)",
        ):
            if marker not in visible:
                raise AssertionError(f"historical inspector missing {marker!r}: {visible!r}")
        if b"not-a-proven-caller" in visible:
            raise AssertionError("historical evidence invented a retained run caller")
        chart = visible.split(b"Model token distribution (measured 2/3 panels):", 1)[1]
        chart = chart.split(b"Panel 1 [answered]", 1)[0]
        for model in (b"panel-first-501", b"panel-zero-701"):
            if model not in chart:
                raise AssertionError(f"recorded panel usage missing from chart: {chart!r}")
        if b"panel-second-501" in chart:
            raise AssertionError(f"unobserved failed-panel usage was charted: {chart!r}")
        failed_card = visible.split(b"Panel 2 [failed]", 1)[1].split(b"Panel 3 [answered]", 1)[0]
        if b"Token usage: not recorded" not in failed_card:
            raise AssertionError(f"failed-panel usage must remain unknown: {failed_card!r}")
        print("FUSION_HISTORY_PTY_FRAME=" + json.dumps({
            "rows": 110, "columns": 170,
            "ansi_zlib_base64": base64.b64encode(zlib.compress(frame)).decode("ascii"),
            "ansi_bytes": len(frame),
        }), flush=True)
        send_and_wait(
            process, master_fd, output, b"r",
            b"Observed tokens: 303 input / 202 output",
        )
        send_and_wait(
            process, master_fd, output, b"r",
            b"historical Fusion Board identity does not match the selected run and post",
        )
        stale = resize_and_wait(
            process, master_fd, output, rows=111, columns=170,
            needle=b"Previous Board reading (refresh failed)", controls=(FULL_REDRAW,),
        )
        if b"different-run-702" in CSI_RE.sub(b"", stale):
            raise AssertionError("mismatched Board origin replaced selected evidence")
        send_and_wait(process, master_fd, output, b"r", b"Observed tokens: 303 input / 202 output")
        all_failed = send_and_wait(
            process, master_fd, output, b"]", b"panel token usage: not recorded",
        )
        all_failed = CSI_RE.sub(b"", frame_containing(all_failed, b"panel token usage: not recorded"))
        if b"Board author: board-author-702" not in all_failed:
            raise AssertionError(f"all-failed summary lost exact Board identity: {all_failed!r}")
        send_and_wait(process, master_fd, output, b"[", b"Board author: board-author-701")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Fusion")
        send_and_wait(process, master_fd, output, b"\r", b"HISTORICAL BOARD EVIDENCE")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Fusion")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Overview")
        send_and_wait(process, master_fd, output, b"q", b"q: press again to quit")

    run_terminal_scenario(
        executable, description="historical Fusion evidence inspection and refresh",
        interact=interact, http_fixtures=fixtures,
    )


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[2] == "browser-scene":
        run_browser_scene_regression(os.path.abspath(sys.argv[1]))
        print("tui Browser scene regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "fusion-history":
        run_fusion_history_regression(os.path.abspath(sys.argv[1]))
        print("tui historical Fusion inspection: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "cli-base-path":
        run_cli_base_path_regression(os.path.abspath(sys.argv[1]))
        print("tui CLI base-path regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "planning-review":
        run_planning_review_regression(os.path.abspath(sys.argv[1]))
        print("tui Planning Task Review regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "repositories":
        run_repositories_regression(os.path.abspath(sys.argv[1]))
        print("tui Repositories regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "project-changes":
        run_project_changes_regression(os.path.abspath(sys.argv[1]))
        print("tui project Git changes regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "browser-screenshot":
        run_browser_screenshot_regression(os.path.abspath(sys.argv[1]))
        run_browser_client_picker_regression(os.path.abspath(sys.argv[1]))
        run_browser_scene_regression(os.path.abspath(sys.argv[1]))
        print("tui Browser screenshot regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "config":
        run_config_regression(os.path.abspath(sys.argv[1]))
        print("tui Config regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "held-back-override":
        run_held_back_override_regression(os.path.abspath(sys.argv[1]))
        print("tui held-back override regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "theme-scheme":
        run_theme_scheme_regression(os.path.abspath(sys.argv[1]))
        print("tui theme scheme regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "msx-palette":
        run_msx_palette_regression(os.path.abspath(sys.argv[1]))
        print("tui MSX palette regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "msx-spectator":
        run_msx_spectator_regression(os.path.abspath(sys.argv[1]))
        print("tui MSX spectator regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "msx-retained":
        run_msx_retained_regression(os.path.abspath(sys.argv[1]))
        raise SystemExit(0)
    if len(sys.argv) == 3 and sys.argv[2] == "msx-retained-tick":
        run_msx_retained_regression(os.path.abspath(sys.argv[1]), retained_tick=True)
        raise SystemExit(0)

    if len(sys.argv) == 3 and sys.argv[2] == "msx-background-poll":
        run_msx_background_poll_regression(os.path.abspath(sys.argv[1]))
        raise SystemExit(0)

    if len(sys.argv) == 3 and sys.argv[2] == "msx-size":
        run_msx_size_regression(os.path.abspath(sys.argv[1]))
        print("tui MSX size regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "board-compose-footer":
        run_board_compose_footer_regression(os.path.abspath(sys.argv[1]))
        print("tui board compose footer regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "schedule-delivery":
        run_schedule_delivery_regression(os.path.abspath(sys.argv[1]))
        print("tui schedule delivery regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "schedule-source-status":
        run_schedule_source_status_regression(os.path.abspath(sys.argv[1]))
        print("tui schedule source status regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "changes-newline":
        run_changes_newline_regression(os.path.abspath(sys.argv[1]))
        print("tui Changes newline projection regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "mermaid-chat":
        run_mermaid_chat_regression(os.path.abspath(sys.argv[1]))
        print("tui mermaid chat regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "chat-clarity":
        run_chat_clarity_regression(os.path.abspath(sys.argv[1]))
        print("tui chat clarity regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "runtime":
        run_runtime_regression(os.path.abspath(sys.argv[1]))
        print("tui Runtime regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "resources":
        run_resources_regression(os.path.abspath(sys.argv[1]))
        print("tui Resources regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "keepers-lanes":
        run_keeper_lanes_regression(os.path.abspath(sys.argv[1]))
        print("tui Keepers/Lanes regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "board-json":
        run_board_json_regression(os.path.abspath(sys.argv[1]))
        print("tui Board JSON regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "code-memo":
        run_code_memo_regression(os.path.abspath(sys.argv[1]))
        print("tui Code memo regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "memory-journal":
        run_memory_journal_regression(os.path.abspath(sys.argv[1]))
        print("tui Memory journal regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "skill-usage-coverage":
        run_skill_usage_coverage_regression(os.path.abspath(sys.argv[1]))
        run_skill_usage_coverage_error_regression(os.path.abspath(sys.argv[1]))
        print("tui Skill usage coverage regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "tools-request-identity":
        run_tools_request_identity_regression(os.path.abspath(sys.argv[1]))
        print("tui Tools request identity regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "tools-purpose":
        run_tools_purpose_regression(os.path.abspath(sys.argv[1]))
        print("tui Tools purpose regression: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[2] == "observer-reconnect":
        run_observer_reconnect_regression(os.path.abspath(sys.argv[1]))
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[2] == "acting-call-evidence":
        run_acting_call_evidence_regression(os.path.abspath(sys.argv[1]))
        print("tui Acting call evidence regression: PASS")
        return
    if len(sys.argv) != 2:
        raise SystemExit(
            "usage: test_tui_keyboard_input.py <masc_tui.exe> "
            "[cli-base-path|planning-review|repositories|project-changes|config|"
            "chat-clarity|mermaid-chat|changes-newline|schedule-delivery|"
            "schedule-source-status|board-compose-footer|runtime|resources|"
            "keepers-lanes|board-json|code-memo|memory-journal|"
            "skill-usage-coverage|tools-purpose|tools-request-identity]"
        )
    run_keyboard_regression(os.path.abspath(sys.argv[1]))
    print("tui keyboard PTY regression: PASS")


if __name__ == "__main__":
    main()
