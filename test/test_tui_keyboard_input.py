from __future__ import annotations

from collections.abc import Callable, Iterator
from contextlib import contextmanager
import errno
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
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


HttpFixture = HttpResponse | RawHttpResponse | Callable[[], HttpResponse]
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
) -> Iterator[tuple[int, Callable[[], None]]]:
    if fixtures is None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as stalled_endpoint:
            stalled_endpoint.bind(("127.0.0.1", 0))
            stalled_endpoint.listen(1)

            def start_endpoint() -> None:
                pass

            yield int(stalled_endpoint.getsockname()[1]), start_endpoint
        return

    class FixtureHandler(BaseHTTPRequestHandler):
        def respond(self) -> None:
            fixture = fixtures.get(
                self.path,
                (503, {"error": "fixture endpoint unavailable"}),
            )
            resolved = fixture() if callable(fixture) else fixture
            extra_headers: tuple[tuple[str, str], ...] = ()
            if isinstance(resolved, RawHttpResponse):
                status = resolved.status
                body = resolved.body
                content_type = resolved.content_type
                extra_headers = resolved.headers
            else:
                status, payload = resolved
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
            self.respond()
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
            yield int(server.server_address[1]), start_endpoint
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


def screen_header(name: bytes, rest: bytes = b"") -> re.Pattern[bytes]:
    """A screen header, matched across the emphasis that closes the title.

    The words naming the screen carry the emphasis, so the reset that ends it
    sits between the name and the counts after it. Spelling a header as one
    literal asserted that those bytes are adjacent, which is a fact about
    styling rather than about what the screen is showing.
    """
    return re.compile(re.escape(name) + rb"(?:\x1b\[[0-9;]*m)*" + re.escape(rest))


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
            raise AssertionError(f"timed out waiting for {needle!r}: {bytes(output)!r}")
        select.select([master_fd], [], [], min(0.1, remaining))


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
    os.write(master_fd, data)
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
    metadata: dict[str, object] = {
        "schema": "masc.keeper_meta.v1",
        "name": name,
        "agent_name": f"keeper-{name}-agent",
        "instructions": "",
        "autonomous_instructions": None,
        "trace_id": f"trace-{name}",
        "trace_history": [],
        "created_at": "2026-08-22T00:00:00Z",
        "updated_at": "2026-08-22T00:00:00Z",
        "last_proactive_outcome": "never_started",
        "last_proactive_reason": "",
        "last_proactive_preview": "",
        "message_scope_ack_id": None,
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
        "compaction_count",
        "last_compaction_ts",
        "last_compaction_before_tokens",
        "last_compaction_after_tokens",
        "proactive_count_total",
        "last_proactive_ts",
        "proactive_visible_count_total",
        "last_visible_proactive_ts",
        "consecutive_noop_count",
    ):
        metadata[field] = 0
    return metadata


def seed_workspace(base_path: str) -> None:
    masc_path = Path(base_path) / ".masc"
    keepers_path = masc_path / "keepers"
    keepers_path.mkdir(parents=True)
    for name in ("alpha", "beta"):
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
        "/api/v1/board": (200, {"posts": [post]}),
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
        "/api/v1/board": (200, {"posts": []}),
        "/api/v1/dashboard/planning": (
            200,
            {
                "goals": [],
                "rollup": {
                    "active_count": 0,
                    "paused_count": 0,
                    "verifying_count": 0,
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


def keeper_runtime_http_fixtures() -> HttpFixtures:
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
                    "status": "active",
                    "health": "healthy",
                    "paused": False,
                    "phase": "running",
                    "keepalive_running": True,
                    "autoboot_enabled": True,
                    "proactive_enabled": True,
                    "runtime_id": "anthropic.claude-opus-5",
                },
                {
                    "runtime_class": "keeper",
                    "name": "beta",
                    "status": "idle",
                    "health": "idle",
                    "paused": True,
                    "phase": "paused",
                    "keepalive_running": True,
                    "autoboot_enabled": True,
                    "proactive_enabled": False,
                    "runtime_id": "anthropic.claude-sonnet-4",
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
        "verification": {"completion": {"state": "idle"}},
    }


def planning_snapshot(goals: list[dict[str, object]]) -> HttpResponse:
    return (
        200,
        {
            "goals": goals,
            "rollup": {
                "active_count": len(goals),
                "paused_count": 0,
                "verifying_count": 0,
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
    fixtures["/api/v1/board"] = (200, {"posts": posts})
    fixtures["/api/v1/board/post-b?format=flat"] = (
        200,
        {"post": bravo_detail, "comments": []},
    )
    fixtures["/api/v1/board/post-c?format=flat"] = (
        200,
        {"post": charlie_detail, "comments": []},
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
    fixtures["/api/v1/board"] = (200, {"posts": posts})
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
    fixtures["/api/v1/board"] = (200, {"posts": posts})
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


def board_missing_target_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    posts = [
        board_selection_post("a", "Alpha", "list-body-a"),
        board_selection_post("b", "Bravo", "list-body-b"),
    ]
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/board"] = (200, {"posts": posts})
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
) -> None:
    master_fd, slave_fd = os.openpty()
    output = bytearray()
    process: subprocess.Popen[bytes] | None = None
    try:
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.set_blocking(master_fd, False)
        with test_http_endpoint(http_fixtures, http_requests) as (
            server_port,
            start_http_endpoint,
        ):
            with tempfile.TemporaryDirectory(prefix="masc-tui-keyboard-") as base_path:
                seed_workspace(base_path)
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
                        "MASC_BASE_PATH": base_path,
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
                        "trap '' INT; kill -STOP $$; \"$@\"; tui_status=$?; "
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
                    timeout=10.0,
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
            process.wait(timeout=2.0)
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
    send_and_wait(process, master_fd, output, b"c", b"Esc:list")
    send_and_wait(process, master_fd, output, b"q2Q", composer_showing(b"q2Q"))
    # That the letters became draft text is the claim above. Leave the pane,
    # then move to Overview where system events are visible.
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
    tab_until(process, master_fd, output, b"MASC Overview")
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


def keeper_runtime_phase_and_model_interaction(
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
        columns=140,
        needle=b"MASC Overview",
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"2",
        b"running claude-opus-5",
    )
    wait_for_output(
        process,
        master_fd,
        output,
        b"paused claude-sonnet-4",
        start=0,
        timeout=3.0,
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
    if b"q2Qx" in restored_message_patch or b"(sending " in restored_message_patch:
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
    os.write(master_fd, b"q")


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
                rows=14,
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
            if not refresh_gate.requested.wait(timeout=3.0):
                raise AssertionError(
                    "Keeper detail overscroll refresh did not reach its fixture"
                )
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=14,
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
    send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")

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
    send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")
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
        rows=14,
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
    if "└".encode() not in overview:
        raise AssertionError(f"14-row Overview omitted its bottom border: {overview!r}")

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
    tab_until(process, master_fd, output, b"MASC Approvals")
    tab_until(process, master_fd, output, b"MASC Board")
    send_and_wait(process, master_fd, output, b"\r", b"comment-5")

    board = resize_and_wait(
        process,
        master_fd,
        output,
        rows=14,
        columns=100,
        needle=b"MASC Board",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for expected in (
        BOARD_CELL_BODY.encode(),
        b"comment-1",
        b"comment-2",
        b"comment-3",
        b"j/k:scroll",
    ):
        if expected not in board:
            raise AssertionError(f"14-row Board omitted {expected!r}: {board!r}")
    if b"**comment-1**" in board:
        raise AssertionError(f"Board comment leaked Markdown source markers: {board!r}")
    if b"comment-4" in board or b"comment-5" in board:
        raise AssertionError(f"14-row Board exceeded its row budget: {board!r}")
    if "└".encode() not in board:
        raise AssertionError(f"14-row Board omitted its bottom border: {board!r}")

    send_and_wait(process, master_fd, output, b"j", b"comment-4")
    send_and_wait(process, master_fd, output, b"j", b"comment-5")
    os.write(master_fd, b"q")


EVENT_RANGE_RE = re.compile(rb"Recent Events (\d+)-(\d+)/(\d+)")


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
    return f"Recent Events {first}-{last}/{total}".encode()


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
        walk of the scenario starts where the 22-row expansion clamped the
        offset -- with more events than the panel that is not the newest
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
    # by one row when the composer took the terminal's last line, so this is
    # 23 rather than 22; the assertions below are the same budget, not a
    # larger one.
    overview = resize_and_wait(
        process,
        master_fd,
        output,
        rows=23,
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
            raise AssertionError(f"23-row Overview omitted {expected!r}: {overview!r}")
    assert_event_window_at_newest(overview, "23-row Overview")
    span = event_range_span(overview, "23-row Overview")
    if span != OVERVIEW_PANEL_ROW_CAP:
        raise AssertionError(
            f"23-row Overview drew {span} event rows, not the "
            f"{OVERVIEW_PANEL_ROW_CAP} it has room for: {overview!r}"
        )

    overview = resize_and_wait(
        process,
        master_fd,
        output,
        rows=14,
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
    if "└".encode() not in overview:
        raise AssertionError(f"14-row Overview omitted its bottom border: {overview!r}")

    scroll_to_oldest(total)
    oldest = resize_and_wait(
        process,
        master_fd,
        output,
        rows=14,
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
        rows=14,
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
        rows=22,
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
        rows=14,
        columns=100,
        needle=clamped_window(2, max(0, total - OVERVIEW_PANEL_ROW_CAP), total),
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    scroll_to_oldest(total, start_offset=max(0, total - OVERVIEW_PANEL_ROW_CAP))
    # The r adds the manual-refresh event, and the observer may add a feed
    # event of its own on the same refresh. How many arrive is the runtime's
    # business; what is asserted is that the pin held. So the total is read
    # back off the redrawn frame rather than predicted.
    send_and_wait(
        process,
        master_fd,
        output,
        b"r",
        re.compile(rb"Recent Events \d+-\d+/\d+"),
    )
    drain_until_quiet(process, master_fd, output)
    anchored = resize_and_wait(
        process,
        master_fd,
        output,
        rows=14,
        columns=99,
        needle=b"MASC Overview",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    after_r_total = event_total(anchored, "99-column Overview")
    if after_r_total <= total:
        raise AssertionError(
            f"the refresh did not add an event ({total} -> {after_r_total}): {anchored!r}"
        )
    if oldest_window(2, after_r_total) not in anchored:
        raise AssertionError(f"event prepend broke the oldest pin: {anchored!r}")
    # The oldest event on screen is the whole claim: the pin followed the
    # prepend. Which younger event shares the two-row window depends on how
    # many feed events the runtime logged, which is not this test's claim.
    if b"TUI started" not in anchored:
        raise AssertionError(f"event prepend changed the manual anchor: {anchored!r}")

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
        rows=14,
        columns=100,
        needle=event_range(after_r_total - 2, after_r_total - 1, after_r_total),
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    if b"TUI started" in newer:
        raise AssertionError(f"one k did not move toward newer events: {newer!r}")

    os.write(master_fd, b"q")


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
            screen_header(
                b"MASC Approvals", b" (3/3, hidden 0, actor masc-tui)"
            ),
        )
        selected = send_and_wait(process, master_fd, output, b"j", b"keeper_probe")
        selected_plain = CSI_RE.sub(b"", selected)
        if not re.search(
            rb">\s+masc-tui\s+keeper_probe\s+keeper\s+beta", selected_plain
        ):
            raise AssertionError(f"fixture did not select approval B: {selected!r}")

        fixtures[
            "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
        ] = approval_selection_snapshot([approval_new, *initial_items])
        refreshed = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            screen_header(
                b"MASC Approvals", b" (4/4, hidden 0, actor masc-tui)"
            ),
        )
        refreshed_frame = frame_containing(
            refreshed,
            screen_header(
                b"MASC Approvals", b" (4/4, hidden 0, actor masc-tui)"
            ),
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
    # What sits between the status bracket and the priority is the renderer's
    # business: #29786 put a proof mark there and this assertion, which only
    # means "this goal is the selected row", started failing as a shape
    # mismatch.
    selected = re.compile(
        rb">[ \t]+\[[^\]\r\n]+\][^\r\n]*?P1[ \t]+" + re.escape(title)
    )
    if selected.search(plain) is None:
        raise AssertionError(f"Planning did not select {title!r}: {frame!r}")


def open_loaded_planning(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
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
    tab_until(process, master_fd, output, b"MASC Approvals")
    tab_until(process, master_fd, output, screen_header(b"MASC Board", b" (0)"))
    tab_until(process, master_fd, output, b"plan-alpha-29424")


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
        if b"plan-beta-29424" not in detail or b"left/Esc:back" not in detail:
            raise AssertionError(
                f"Planning refresh opened a different goal detail: {detail!r}"
            )
        listing = send_and_wait(process, master_fd, output, b"\x1b[D", b"MASC Planning")
        assert_planning_goal_selected(listing, b"plan-beta-29424")
        os.write(master_fd, b"q")

    return interact


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
        if b"Enter:detail" not in recovered or b"Esc:back" in recovered:
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
        tab_until(process, master_fd, output, b"MASC Approvals")
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
        send_and_wait(process, master_fd, output, b"\r", b"detail-body-bravo")
        # iTerm reports Ctrl-W as CSI-u after the TUI enables keyboard
        # disambiguation. It must reach the same pane binding as legacy 0x17.
        send_and_wait(process, master_fd, output, b"\x1b[119;5u", b"Board (3)  [j/k]")
        send_and_wait(process, master_fd, output, b"j", b"detail-body-charlie")
        send_and_wait(process, master_fd, output, b"k", b"detail-body-bravo")
        send_and_wait(process, master_fd, output, b"l", b"j/k:scroll")
        send_and_wait(process, master_fd, output, b"\x1b[6~", b"bravo-25")

        board = send_and_wait(process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (3)"))
        if not selected_b.search(board) or selected_a.search(board):
            raise AssertionError(
                f"Board detail return changed the selected post: {board!r}"
            )

        fixtures["/api/v1/board"] = (
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
        board = send_and_wait(process, master_fd, output, b"r", b"post-new")
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
    tab_until(process, master_fd, output, b"MASC Approvals")
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
            if not b_failure.requested.wait(timeout=3.0):
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
            fixtures["/api/v1/board"] = late_list
            fixtures["/api/v1/dashboard/briefing"] = (
                200,
                overview_event_briefing("late-list-applied"),
            )

            read_available(master_fd, output)
            os.write(master_fd, b"r")
            if not late_list.requested.wait(timeout=3.0):
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
            tab_until(process, master_fd, output, b"MASC System Logs")
            tab_until(process, master_fd, output, b"late-list-applied")
            tab_until(process, master_fd, output, b"MASC Keepers")
            tab_until(process, master_fd, output, b"MASC Approvals")
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


def board_missing_target_interaction(
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

            fixtures["/api/v1/board"] = (
                200,
                {"posts": [board_selection_post("a", "Alpha", "list-body-a")]},
            )
            fixtures["/api/v1/board/post-b?format=flat"] = late_b
            board_update = send_and_wait(
                process, master_fd, output, b"r", screen_header(b"MASC Board", b" (1)")
            )
            board = frame_containing(board_update, screen_header(b"MASC Board", b" (1)"))
            if not late_b.requested.wait(timeout=3.0):
                raise AssertionError("late Board B request did not reach its fixture")
            for expected in (
                selected_row(b"post-a"),
                b"Enter:read",
            ):
                if find_needle(board, expected) < 0:
                    raise AssertionError(
                        f"missing Board target did not restore list mode: {board!r}"
                    )
            for stale in (b"b-initial-comment", b"Esc:back"):
                if stale in board:
                    raise AssertionError(
                        f"missing Board target retained detail state: {board!r}"
                    )

            send_and_wait(process, master_fd, output, b"\r", b"a-recovered-detail")
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


BRACKETED_PASTE_ON = b"\x1b[?2004h"
PASTE_START = b"\x1b[200~"
PASTE_END = b"\x1b[201~"


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
        send_and_wait(
            process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
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
        send_and_wait(process, master_fd, output, command, composer_showing(command))

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

        send_and_wait(
            process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
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

        send_and_wait(
            process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def seed_playground_workspace(base_path: str) -> None:
    """Give alpha the directory a local keeper reads its files from.

    A keeper reads paths relative to its own sandbox root. For a local
    keeper that is .masc/playground/<name>/; a Docker one has a `docker`
    directory in the middle. Declaring the profile here is what makes this
    scenario about the first."""
    Path(base_path, ".masc", "config", "keepers").mkdir(parents=True, exist_ok=True)
    Path(base_path, ".masc", "config", "keepers", "alpha.toml").write_text(
        '[keeper]\nsandbox_profile = "local"\n', encoding="utf-8"
    )
    Path(base_path, ".masc", "playground", "alpha").mkdir(parents=True, exist_ok=True)


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

        playground = Path(base_path, ".masc", "playground", "alpha")
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

        send_and_wait(
            process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def chat_queue_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    # The turn has to still be running while the scenario types the lines that
    # queue behind it, so the fixture holds the answer rather than sending one.
    gate = GatedHttpResponse(
        (503, {"error": "released after the queue was read"}),
        hold_seconds=30.0,
    )
    return {"/api/v1/keepers/chat/stream": gate}, gate


def chat_queue_interaction(gate: GatedHttpResponse) -> Interaction:
    """A line typed during a turn is shown, not just counted, and the arrows
    walk back to it.

    #29818 rewrote the in-flight rows and took the queue rows with them,
    leaving the row budget that reserves them behind. The count in the footer
    kept saying "2 waiting" over a pane that had lost two rows of conversation
    and showed neither line."""

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
        sending = send_and_wait(process, master_fd, output, b"\r", b"(sending ")
        footer_while_sending = frame_row_of(sending, b"  Enter:")

        send_and_wait(
            process, master_fd, output, b"queued-one", composer_showing(b"queued-one")
        )
        first_queued = send_and_wait(process, master_fd, output, b"\r", b"queued 1")
        send_and_wait(
            process, master_fd, output, b"queued-two", composer_showing(b"queued-two")
        )
        second_queued = send_and_wait(process, master_fd, output, b"\r", b"queued 2")

        frame = frame_containing(second_queued, b"queued 2")
        plain = CSI_RE.sub(b"", frame)
        for expected in (b"queued 1: queued-one", b"queued 2: queued-two"):
            if expected not in plain:
                raise AssertionError(
                    f"the pane counted a waiting line it did not draw; "
                    f"missing {expected!r}: {plain!r}"
                )
        if b"Enter:queue (2 waiting)" not in plain:
            raise AssertionError(f"the footer lost its count: {plain!r}")

        # Every variable row -- sending, queued, errors -- comes out of the
        # history above it, so the pane ends on the same terminal row whatever
        # it is saying. When rows are reserved and not drawn, the pane comes
        # out short and everything below walks up the screen: one row per
        # waiting line, which is exactly what an operator sees.
        footer_with_queue = frame_row_of(second_queued, b"  Enter:")
        if footer_with_queue != footer_while_sending:
            raise AssertionError(
                "the pane lost rows to the queue: the footer was on row "
                f"{footer_while_sending} while sending and on row "
                f"{footer_with_queue} with two lines waiting"
            )
        del first_queued

        # The newest thing the operator typed is the first thing the arrows
        # hand back, whether or not it has been dispatched.
        send_and_wait(
            process, master_fd, output, b"\x1b[A", composer_showing(b"queued-two")
        )
        send_and_wait(
            process, master_fd, output, b"\x1b[A", composer_showing(b"queued-one")
        )

        # Let the turn settle and the queue drain into it. Until it does, Esc
        # means "interrupt the turn" and q is just a letter in the composer.
        send_and_wait(process, master_fd, output, b"\x15", b"> ")
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
        send_and_wait(
            process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
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
        narrow_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=16,
            needle=composer_showing(b"A"),
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        assert_message_input_frame(
            narrow_frame,
            row=28,
            columns=16,
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

        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
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
                "autonomous_turn": {"turn_id": "trace-1787333555531-00021#55"},
                "blocks": [],
            },
        ],
    )


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
                    "recorded_at": 1787348490.35,
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
        pane = bytes(output[pane_start:])
        for needle, what in (
            (b"2 reasoning steps, content withheld", "the withheld reasoning count"),
            ("\u2713 masc_task_history \u00b7 32ms".encode(), "the returned call"),
            ("\u2717 tool_execute \u00b7 1200ms".encode(), "the failed call"),
            ("\u00b7 auto".encode(), "the autonomous origin badge"),
        ):
            if needle not in pane:
                raise AssertionError(
                    f"Autonomous turn history did not draw {what}: {pane!r}"
                )
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        os.write(master_fd, b"q")

    return interact


def memory_journal_timeline_interaction() -> Interaction:
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
        send_and_wait(process, master_fd, output, b"m", b"memory:on")
        wait_for_output(
            process,
            master_fd,
            output,
            b"Librarian committed memory revision 9",
            start=start,
            timeout=5.0,
        )
        visible = bytes(output[start:])
        for needle in (
            b"+ [fact] the Runtime probe shares one provider endpoint",
            b"- [constraint] probe every model separately",
            b"drop memory-old-probe-rule",
            b"superseded by provider grouping",
        ):
            if needle not in visible:
                raise AssertionError(f"Memory timeline did not draw {needle!r}: {visible!r}")

        send_and_wait(process, master_fd, output, b"/memory", composer_showing(b"/memory"))
        hidden = send_and_wait(process, master_fd, output, b"\r", b"memory:off")
        if b"Librarian committed memory revision 9" in hidden:
            raise AssertionError(f"Hidden Memory timeline still drew its row: {hidden!r}")

        send_and_wait(process, master_fd, output, b"/memory", composer_showing(b"/memory"))
        restored = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Librarian committed memory revision 9",
        )
        if b"memory:on" not in restored:
            raise AssertionError(f"Memory timeline did not return to on: {restored!r}")
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        os.write(master_fd, b"q")

    return interact


def context_inspector_fixtures() -> HttpFixtures:
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
                            {
                                "block": "keeper_instructions",
                                "bytes": 24,
                                "digest": "a" * 64,
                            },
                            {
                                "block": "dynamic_context",
                                "bytes": 36,
                                "digest": "b" * 64,
                            },
                            {
                                "block": "memory_os_recall",
                                "bytes": 31,
                                "digest": "c" * 64,
                            },
                        ],
                        "input_components": [
                            {"component": "prompt.keeper_instructions", "bytes": 24},
                            {"component": "prompt.dynamic_context", "bytes": 36},
                            {"component": "prompt.memory_os_recall", "bytes": 31},
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
    fixtures["/api/v1/keepers/alpha/last-prompt"] = (
        200,
        {
            "keeper": "alpha",
            "dashboard_surface": "/api/v1/keepers/:name/last-prompt",
            "captured_at": 1787600000.0,
            "trace_id": "trace-context",
            "absolute_turn": 42,
            "blocks": [
                {
                    "id": "keeper_instructions",
                    "bytes": 24,
                    "text": "Keeper instruction text",
                },
                {
                    "id": "dynamic_context",
                    "bytes": 36,
                    "text": "exact dynamic context from the turn",
                },
                {
                    "id": "memory_os_recall",
                    "bytes": 31,
                    "text": "remember the operator preference",
                },
            ],
            "assembled": "Keeper instruction text\nexact dynamic context from the turn\nremember the operator preference",
            "assembled_bytes": 93,
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
            process, master_fd, output, rows=35, columns=140, needle=b"MASC Overview"
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
            process, master_fd, output, b"\r", b"Input composition"
        )
        composition_plain = CSI_RE.sub(b"", composition)
        for needle in (
            b"claude-opus-5",
            b"50.0k / 200.0k tokens",
            b"Tool schemas",
            b"User messages",
            b"Tool results",
            b"Conversation history  7 / 9 atoms",
        ):
            if needle not in composition_plain:
                raise AssertionError(
                    f"Context composition omitted {needle!r}: {composition!r}"
                )

        prompt = send_and_wait(process, master_fd, output, b"2", b"Exact turn-added prompt text")
        prompt_plain = CSI_RE.sub(b"", prompt)
        for needle in (b"Keeper instructions", b"Dynamic context", b"Memory recall"):
            if needle not in prompt_plain:
                raise AssertionError(f"Prompt block list omitted {needle!r}: {prompt!r}")

        send_and_wait(process, master_fd, output, b"j", b"Dynamic context")
        exact = send_and_wait(
            process, master_fd, output, b"\r", b"exact dynamic context from the turn"
        )
        if b"Base prompt" in CSI_RE.sub(b"", exact):
            raise AssertionError(f"Exact block view retained the list disclosure: {exact!r}")

        send_and_wait(process, master_fd, output, b"\x1b", b"Exact turn-added prompt text")
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        help_frame = send_and_wait(process, master_fd, output, b"?", b"Slash commands")
        if b"/context" not in CSI_RE.sub(b"", help_frame):
            raise AssertionError(f"Help did not disclose /context: {help_frame!r}")
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        os.write(master_fd, b"q")

    return interact


def chat_visibility_modes_interaction() -> Interaction:
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
        initial = send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            "\u2717 Ran 2 tools".encode(),
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"2 details folded",
            start=pane_start,
            timeout=5.0,
        )
        initial += bytes(output[pane_start:])
        if b"2 reasoning steps, content withheld" in initial:
            raise AssertionError(f"hidden reasoning was still drawn: {initial!r}")

        folded = send_and_wait(
            process, master_fd, output, b"\x12", b"reasoning:folded"
        )
        if b"Reasoning" not in folded or b"line(s) folded" not in folded:
            raise AssertionError(f"folded reasoning did not draw its count: {folded!r}")

        full = send_and_wait(process, master_fd, output, b"\x12", b"reasoning:full")
        if b"2 reasoning steps, content withheld" not in full:
            raise AssertionError(f"full reasoning did not restore content: {full!r}")

        tools = send_and_wait(process, master_fd, output, b"\x04", b"tools:full")
        for needle in (b"masc_task_history", b"tool_execute"):
            if needle not in tools:
                raise AssertionError(
                    f"full tool view did not restore {needle!r}: {tools!r}"
                )
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        os.write(master_fd, b"q")

    return interact


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
    send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    os.write(master_fd, b"q")


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
    wait_for_output(
        process,
        master_fd,
        output,
        b"keeper-body-neutral",
        start=pane_start,
        timeout=5.0,
    )
    frame = frame_containing(bytes(output[pane_start:]), b"keeper-body-neutral")
    for needle, description in (
        (b"\x1b[36m\x1b[7m vincent", "cyan operator origin badge"),
        (b"\x1b[34m\x1b[7m alpha", "blue Keeper origin badge"),
        (b"\x1b[36m\xe2\x94\x82\x1b[0m \x1b[0moperator-body-neutral", "gutter-marked operator body"),
        (b"\x1b[34m\xe2\x94\x82\x1b[0m \x1b[0mkeeper-body-neutral", "gutter-marked Keeper body"),
    ):
        if needle not in frame:
            raise AssertionError(f"chat frame omitted {description}: {frame!r}")
    for forbidden, description in (
        (b"\x1b[36m  operator-body-neutral", "operator body cyan wash"),
        (b"\x1b[34m  keeper-body-neutral", "Keeper body blue wash"),
        (b"\x1b[32m  keeper-body-neutral", "Keeper body green wash"),
    ):
        if forbidden in frame:
            raise AssertionError(f"chat frame retained {description}: {frame!r}")

    draft_start = len(output)
    send_and_wait(process, master_fd, output, b"draft-neutral", b"draft-neutral")
    draft_frame = frame_containing(bytes(output[draft_start:]), b"draft-neutral")
    if b"\x1b[36m  > \x1b[0mdraft-neutral" not in draft_frame:
        raise AssertionError(
            f"chat composer did not limit accent to its prompt: {draft_frame!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
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
            columns=140,
            needle=b"MASC Overview",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"2",
            b"running claude-opus-5",
        )
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        if not alpha_history.requested.wait(timeout=3.0):
            raise AssertionError("alpha history request did not reach its fixture")
        send_and_wait(
            process,
            master_fd,
            output,
            b"alpha-draft",
            composer_showing(b"alpha-draft"),
        )

        beta_start = len(output)
        # iTerm reports Ctrl-G as CSI-u after keyboard disambiguation is on.
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[103;5u",
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
            columns=140,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        beta_plain = CSI_RE.sub(b"", beta_frame)
        for expected in (
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            b"idle \xc2\xb7 paused claude-sonnet-4",
            b"Ctrl-G:next Keeper",
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
            columns=140,
            needle=b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        alpha_plain = CSI_RE.sub(b"", alpha_frame)
        for expected in (
            b"healthy \xc2\xb7 running claude-opus-5",
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
        if not alpha_history.completed.wait(timeout=3.0):
            raise AssertionError("released alpha history fixture did not complete")
        time.sleep(0.1)
        stale_check = resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=140,
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
            columns=140,
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
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")
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
            ("\u2713 Read".encode(), "the returned call"),
            (b"28ms", "its duration"),
            ("\u2717 tool_execute".encode(), "the failed call"),
            (b"14.5s", "the failure's duration"),
            (b"lib/a.ml", "the subject the trail names"),
        ):
            if needle not in pane:
                raise AssertionError(f"Keeper Calls did not draw {what}: {pane!r}")
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
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
        unread = tab_until(process, master_fd, output, b"MASC Verification")
        if b"(not loaded)" not in unread:
            raise AssertionError(
                f"Verification header did not say not loaded: {unread!r}"
            )
        if b"(not loaded yet)" not in unread:
            raise AssertionError(
                f"Verification body claimed a reading before one was made: {unread!r}"
            )
        if b"nothing waiting" in unread:
            raise AssertionError(
                f"Verification body read an empty queue off no reading: {unread!r}"
            )
        if not gate.requested.wait(timeout=3.0):
            raise AssertionError("Verification surface did not ask for its queue")
        loaded = release_and_wait_for_frame(
            process, master_fd, output, gate, b"(nothing waiting on a verdict)"
        )
        # The title and the count are asserted apart: a style reset may sit
        # between them once surface titles carry their own styling.
        if b"MASC Verification" not in loaded or b"(0 of 0)" not in loaded:
            raise AssertionError(
                f"Verification header did not report the read: {loaded!r}"
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
                 "local_path": "workspace/masc", "default_branch": "main",
                 "status": "ready", "keepers": ["alpha"], "auto_sync": True},
            ],
            "total": 1,
        },
    )


def repositories_enter_interaction(requests: HttpRequests) -> Interaction:
    """Enter on a Repositories row opens that repository's own tree on the
    Code surface, through the ?repo_id= axis; the header names whose tree
    it is. Then m reads the notes anchored to a file, and w adds one
    through the $EDITOR form -- the assertion is the recorded POST body."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Repositories")
        wait_for_output(
            process, master_fd, output, b"ready", start=0, timeout=3.0
        )
        code = send_and_wait(process, master_fd, output, b"\r", b"src")
        code_plain = CSI_RE.sub(b"", code).decode("utf-8")
        if "masc ▸ /" not in code_plain:
            raise AssertionError(
                f"the Code header does not name the repository: {code_plain!r}"
            )
        # Open a file in the repository scope, then m: the notes anchored to
        # it arrive through the codebase slug the repositories row carries.
        send_and_wait(process, master_fd, output, b"j\r", b"let")
        notes = send_and_wait(
            process, master_fd, output, b"m", b"keep n at three"
        )
        notes_plain = CSI_RE.sub(b"", notes).decode("utf-8")
        for needle in ("notes: note.ml", "L1", "alpha", "Decision", "task-77"):
            if needle not in notes_plain:
                raise AssertionError(
                    f"the notes view missed {needle!r}: {notes_plain!r}"
                )
        # w: the $EDITOR stub saves the form, and the wire carries it.
        os.write(master_fd, b"w")
        body = wait_for_http_request(
            process, master_fd, output, requests,
            path="/api/v1/ide/annotations?codebase=github.com_jeong-sik_masc",
        )
        payload = json.loads(body)
        if payload != {"file_path": "note.ml", "line_start": 1,
                       "line_end": 1, "kind": "Question",
                       "content": "why three?"}:
            raise AssertionError(f"note POST body: {payload!r}")
        send_and_wait(process, master_fd, output, b"\x1b", b"let")
        # c: which keeper wrote which lines, through what, and when.
        activity = send_and_wait(
            process, master_fd, output, b"c", b"Edit (turn 7)"
        )
        activity_plain = CSI_RE.sub(b"", activity).decode("utf-8")
        for needle in ("activity: note.ml", "L1", "alpha"):
            if needle not in activity_plain:
                raise AssertionError(
                    f"the activity view missed {needle!r}: {activity_plain!r}"
                )
        send_and_wait(process, master_fd, output, b"\x1b", b"let")
        os.write(master_fd, b"q")

    return interact


VERIFICATION_VERDICT_PATH = "/api/v1/verification/verdict"


def verification_request_row(task_id: str) -> dict[str, object]:
    return {
        "request_id": f"vr-{task_id}",
        "task_id": task_id,
        "task_title": f"finish {task_id}",
        "request_kind": "completion",
        "request_summary": f"prove {task_id} is done",
        "submitted_by": "keeper-alpha",
        "created_at": "2026-08-25T14:00:00+09:00",
        "required_artifacts": ["diff"],
        "submitted_evidence": ["diff"],
        "next_action": "review the diff",
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


@contextmanager
def note_editor_script() -> Iterator[str]:
    """An $EDITOR that fills the note form and exits 0 -- the saved form."""
    fd, path = tempfile.mkstemp(prefix="masc-tui-note-editor-", suffix=".sh")
    try:
        os.write(
            fd,
            b'#!/bin/sh\nprintf %s \'{"line_start": 1, "line_end": 1, '
            b'"kind": "Question", "content": "why three?"}\' > "$1"\n',
        )
        os.close(fd)
        os.chmod(path, 0o755)
        yield path
    finally:
        os.unlink(path)


def verification_verdict_interaction(requests: HttpRequests) -> Interaction:
    """`a` arms and only the second `a` sends the approve; `x` collects a
    reason through $EDITOR and sends the reject. Both assertions read the
    recorded POST bodies -- the wire, not the paint -- and the frame between
    the two presses proves the first one sent nothing.
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
        tab_until(process, master_fd, output, b"MASC Verification")
        wait_for_output(
            process, master_fd, output, b"task-901", start=0, timeout=3.0
        )
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
        # Reject on the same row: the $EDITOR stub saves the reason form, so
        # the second verdict body carries it.
        read_available(master_fd, output)
        reject_start = len(output)
        os.write(master_fd, b"x")
        deadline = time.monotonic() + 5.0
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
        # The verdict events live on the Overview's Recent Events pane, so
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
) -> Interaction:
    """One visit distinguishes unread, empty, failed, and populated lanes."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        unread = tab_until(process, master_fd, output, b"MASC Lanes")
        if b"(not loaded)" not in unread or b"(not loaded yet)" not in unread:
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
        if not gate.requested.wait(timeout=3.0):
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
                ),
                keeper_lane_row(
                    "beta",
                    phase="new_phase",
                    turn_phase="new_turn",
                    idle_seconds=3661,
                    runtime_state=None,
                    selected_model=None,
                    diagnosis=None,
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
        banded_alpha = re.compile(rb"\x1b\[7m[^\x1b\n]*alpha")
        if banded_alpha.search(populated) is None:
            raise AssertionError(
                f"Lanes did not band the cursor row: {populated!r}"
            )
        send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            re.compile(rb"\x1b\[7m[^\x1b\n]*beta"),
        )
        send_and_wait(process, master_fd, output, b"k", banded_alpha)
        # "/" arms the row search on any surface with row texts: the footer
        # shows the query, typing jumps the cursor live, Enter keeps the
        # query for n. The list itself never narrows.
        send_and_wait(process, master_fd, output, b"/", b"/  j/k:scroll")
        banded_beta = re.compile(rb"\x1b\[7m[^\x1b\n]*beta")
        send_and_wait(process, master_fd, output, b"bet", banded_beta)
        send_and_wait(process, master_fd, output, b"\rk", banded_alpha)
        send_and_wait(process, master_fd, output, b"n", banded_beta)
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
        stale = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"keeper lanes load failed",
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
                }
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
    return status, payload


def changes_keeper_and_arrow_detail_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    tab_until(process, master_fd, output, b"masc:lib/example.ml")
    beta = send_and_wait(process, master_fd, output, b"]", b"masc:lib/beta.ml")
    if b"MASC Changes beta" not in CSI_RE.sub(b"", beta):
        raise AssertionError(f"Changes did not switch to beta: {beta!r}")
    alpha = send_and_wait(process, master_fd, output, b"[", b"masc:lib/example.ml")
    if b"MASC Changes alpha" not in CSI_RE.sub(b"", alpha):
        raise AssertionError(f"Changes did not switch back to alpha: {alpha!r}")
    detail = send_and_wait(process, master_fd, output, b"\x1b[C", b"-1 +1")
    if b"MASC Change" not in CSI_RE.sub(b"", detail):
        raise AssertionError(f"Right did not open the selected diff: {detail!r}")
    listing = send_and_wait(process, master_fd, output, b"\x1b[D", b"Turn")
    if b"MASC Changes alpha" not in CSI_RE.sub(b"", listing):
        raise AssertionError(f"Left did not return to the Changes list: {listing!r}")
    # v opens the row's file on the Code surface, read through the keeper's
    # own workspace (?keeper=alpha), so the header names whose tree it is
    # and the bytes arrive lexed.
    code = send_and_wait(
        process, master_fd, output, b"v", b"\x1b[33mlet\x1b[0m"
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

    The widened Enter arm sent Acting/Lanes/Approvals/Schedules/Verify/Harness
    into the Changes handler; with changes loaded, coming back to Changes then
    drew a diff nobody opened.
    """
    populated = tab_until(process, master_fd, output, b"masc:lib/example.ml")
    populated_plain = CSI_RE.sub(b"", populated).decode("utf-8")
    if "MASC Changes" not in populated_plain:
        raise AssertionError(
            f"Changes did not draw the fixture row as a list: {populated_plain!r}"
        )
    lanes = tab_until(process, master_fd, output, b"MASC Lanes")
    if b"MASC Lanes" not in lanes:
        raise AssertionError(f"did not reach Lanes: {lanes!r}")
    os.write(master_fd, b"\r")
    back = tab_until(process, master_fd, output, b"masc:lib/example.ml")
    back_plain = CSI_RE.sub(b"", back).decode("utf-8")
    if "Turn" not in back_plain:
        raise AssertionError(
            "returning to Changes did not draw the list columns; Enter on "
            f"Lanes armed a view it does not own: {back_plain!r}"
        )
    if "-1 +1" in back_plain:
        raise AssertionError(
            "returning to Changes drew a diff nobody opened; Enter on Lanes "
            f"reached the Changes handler: {back_plain!r}"
        )
    os.write(master_fd, b"q")




WORKSPACE_TREE_ROOT_PATH = "/api/v1/workspace/tree?depth=0&limit=200"
WORKSPACE_CHILDREN_LIB_PATH = "/api/v1/workspace/children?path=lib&limit=500"
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
    file_response = (200, {"ok": True, "content": "let x = 1\n(* hi *)\n"})
    fixtures[WORKSPACE_FILE_AML_PATH] = file_response
    # uri's Query_value encoding may or may not spell the slash; serve both.
    fixtures["/api/v1/workspace/file?path=lib%2Fa.ml"] = file_response
    history_response = (
        200,
        {
            "ok": True,
            "commits": [
                {"hash": "abc1234", "date": "2026-08-25",
                 "author": "keeper-alpha", "subject": "feat: add x"},
                {"hash": "def5678", "date": "2026-08-24",
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
                {"kind": "add", "oldLine": None, "newLine": 1,
                 "text": "let a = 2"},
            ],
        },
    )
    for diff_path in (
        "/api/v1/git/diff?path=lib/a.ml&base_ref=HEAD",
        "/api/v1/git/diff?path=lib%2Fa.ml&base_ref=HEAD",
    ):
        fixtures[diff_path] = diff_response
    return fixtures


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
    listing = tab_until(process, master_fd, output, b"README.md")
    plain = CSI_RE.sub(b"", listing).decode("utf-8")
    for needle in ("lib", "README.md"):
        if needle not in plain:
            raise AssertionError(f"Code did not list {needle!r}: {plain!r}")
    send_and_wait(process, master_fd, output, b"\r", b"a.ml")
    opened = send_and_wait(
        process, master_fd, output, b"\r", b"\x1b[33mlet\x1b[0m"
    )
    if re.search(rb"\x1b\[2m\s+1\x1b\[0m", opened) is None:
        raise AssertionError(f"no line-number gutter: {opened!r}")
    if b"\x1b[90m(* hi *)\x1b[0m" not in opened:
        raise AssertionError(f"the comment did not colour: {opened!r}")
    # l pans the open file sideways by one cell: the keyword span is cut
    # mid-word but its colour still opens the remainder, and the title says
    # the view is shifted. h pans back and the full keyword returns.
    panned = send_and_wait(process, master_fd, output, b"ll", b"(col 3)")
    if b"\x1b[33mt\x1b[0m x = \x1b[35m1\x1b[0m" not in panned:
        raise AssertionError(f"pan did not cut by cells under the style: {panned!r}")
    send_and_wait(process, master_fd, output, b"hh", b"\x1b[33mlet\x1b[0m")
    # d swaps the content for the working tree's diff against HEAD; Esc
    # swaps back to the lexed content.
    diff_frame = send_and_wait(process, master_fd, output, b"d", b"let a = 2")
    diff_plain = CSI_RE.sub(b"", diff_frame).decode("utf-8")
    for needle in ("diff vs HEAD: lib/a.ml", "let a = 1"):
        if needle not in diff_plain:
            raise AssertionError(
                f"the diff view missed {needle!r}: {diff_plain!r}"
            )
    send_and_wait(process, master_fd, output, b"\x1b", b"\x1b[33mlet\x1b[0m")
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
    if "Esc:code" not in history_plain:
        raise AssertionError(
            f"history footer does not offer the way back: {history_plain!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", b"\x1b[33mlet\x1b[0m")
    os.write(master_fd, b"q")


RUNTIME_PROBE_PATH = "/api/v1/dashboard/runtime-probe"
RUNTIME_PROBE_FORCE_PATH = f"{RUNTIME_PROBE_PATH}?force=1"
RUNTIME_RESOLVED_PATH = "/api/v1/runtime/resolved"


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
                "status": "reachable" if fresh else "degraded",
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
            tab_until(process, master_fd, output, b"MASC Connectors")
            read_available(master_fd, output)
            start = len(output)
            os.write(master_fd, b"\t")
            if not initial_probe.requested.wait(timeout=3.0):
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
                "MASC Runtime",
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
                re.compile(
                    rb"reachable(?:\x1b\[[0-9;]*m)* / "
                    rb"(?:\x1b\[[0-9;]*m)*fresh"
                ),
                start=fresh_start,
                timeout=3.0,
            )

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
                needle=b"MASC Runtime",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=30,
                columns=100,
                needle=b"MASC Runtime",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )

            fixtures[RUNTIME_PROBE_PATH] = (503, {"error": "probe refresh failed"})
            send_and_wait(
                process,
                master_fd,
                output,
                b"r",
                b"forced probe refresh failed",
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
            send_and_wait(process, master_fd, output, b"\t", b"MASC Tools")
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
                    "dispatch_status": "running",
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
                    "recurrence_summary": "every 30 minutes",
                    "payload_digest": "digest-proof-701",
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
                        "projection_status": "matched_recorded",
                        "latest_recorded_at_iso": "2026-08-25T09:31:00Z",
                    },
                }
            ],
        },
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
        tab_until(process, master_fd, output, b"MASC Schedules")
        detail = send_and_wait(
            process, master_fd, output, b"\x1b[C", b"instance-proof-701"
        )
        plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"Dispatch",
            b"Operator Proof (human_operator)",
            b"keeper_wake",
            b"digest-proof-701",
            b"PgUp/PgDn:page",
        ):
            if needle not in plain:
                raise AssertionError(f"Schedule detail omitted {needle!r}: {plain!r}")
        evidence = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"matched_pending"
        )
        evidence_plain = CSI_RE.sub(b"", evidence)
        for needle in (
            b"LAST WAKE",
            b"DELIVERY EVIDENCE",
            b"pending=2",
            b"matched_recorded",
        ):
            if needle not in evidence_plain:
                raise AssertionError(
                    f"Schedule evidence omitted {needle!r}: {evidence_plain!r}"
                )
        send_and_wait(process, master_fd, output, b"\x1b[D", b"right/Enter:details")
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
        "status": status,
    }


def fusion_runs_response(runs: list[dict[str, object]]) -> HttpResponse:
    return (
        200,
        {
            "generated_at": "2026-08-24T09:00:00Z",
            "count": len(runs),
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


def fusion_list_detail_interaction(
    fixtures: HttpFixtures,
    initial_runs: GatedHttpResponse,
) -> Interaction:
    """Select by run id across reorder, then show the result before evidence."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Harness")
        read_available(master_fd, output)
        start = len(output)
        os.write(master_fd, b"\t")
        if not initial_runs.requested.wait(timeout=3.0):
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
            b"fusion-target-501",
            start=start,
            timeout=3.0,
        )
        target_end = output.find(b"fusion-target-501", start) + len(
            b"fusion-target-501"
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
        for column in (b"TIME", b"STATUS", b"KEEPER", b"PRESET", b"TOPOLOGY", b"RUN"):
            if column not in plain:
                raise AssertionError(
                    f"Fusion did not draw the {column!r} source column: {plain!r}"
                )

        selected = send_and_wait(process, master_fd, output, b"j", b"fusion-target-501")
        if re.search(rb">[^\r\n]*fusion-target-501", CSI_RE.sub(b"", selected)) is None:
            raise AssertionError(f"Fusion did not select the target run: {selected!r}")

        target = fusion_run("fusion-target-501", keeper="beta")
        new = fusion_run("fusion-new-501", keeper="gamma")
        alpha = fusion_run("fusion-alpha-501", keeper="alpha")
        fixtures[FUSION_RUNS_PATH] = fusion_runs_response([target, new, alpha])
        refreshed = send_and_wait(process, master_fd, output, b"r", b"fusion-new-501")
        if (
            re.search(rb">[^\r\n]*fusion-target-501", CSI_RE.sub(b"", refreshed))
            is None
        ):
            raise AssertionError(
                f"Fusion refresh moved selection off its run id: {refreshed!r}"
            )

        detail = send_and_wait(process, master_fd, output, b"\r", b"judge-proof-501")
        detail_plain = CSI_RE.sub(b"", detail)
        judge_index = detail_plain.find(b"judge-proof-501")
        first_panel_index = detail_plain.find(b"panel-answer-first-501")
        if judge_index < 0 or (
            first_panel_index >= 0 and judge_index > first_panel_index
        ):
            raise AssertionError(
                f"Fusion detail did not put the result before panel evidence: {detail_plain!r}"
            )
        for needle in (
            b"RESULT",
            b"QUESTION",
            b"PANEL RESPONSES",
            b"PgUp/PgDn:page",
        ):
            if needle not in detail_plain:
                raise AssertionError(
                    f"Fusion detail omitted the {needle!r} summary: {detail_plain!r}"
                )
        panel = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"panel-failure-second-501"
        )
        panel_plain = CSI_RE.sub(b"", panel)
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
        "/api/v1/board": (200, {"posts": []}),
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
        acting = send_and_wait(process, master_fd, output, b"\t", b"MASC Acting")
        for needle, what in (
            (b"(1 of 1 held, actions)", "the held and shown counts"),
            (b"alpha", "the keeper that acted"),
            ("\u25b6 call".encode(), "the call glyph and label"),
            (b"read_file", "the tool"),
            (b"turn 7", "the turn"),
            (b"task-1", "the task"),
        ):
            if needle not in acting:
                raise AssertionError(f"Acting did not draw {what}: {acting!r}")
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
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
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
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        os.write(master_fd, b"q")

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
    missing_target_fixtures, late_b = board_missing_target_http_fixtures()
    message_switch_fixtures, alpha_history = keeper_message_switch_http_fixtures()
    lanes_fixtures = keeper_runtime_http_fixtures()
    lanes_gate = GatedHttpResponse(keeper_lanes_response([]))
    lanes_fixtures[KEEPER_LANES_PATH] = lanes_gate
    runtime_fixtures, runtime_initial_probe, runtime_force_probe = (
        runtime_http_fixtures()
    )
    schedule_fixtures = schedule_detail_http_fixtures()
    fusion_fixtures, fusion_initial_runs = fusion_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Image view over the frame",
        interact=image_view_interaction(),
        prepare_workspace=seed_image_workspace,
        preload_input=GRAPHICS_SUPPORTED_REPLY,
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
    chat_queue_fixtures, chat_queue_gate = chat_queue_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Keeper chat queue is drawn and walked",
        interact=chat_queue_interaction(chat_queue_gate),
        http_fixtures=chat_queue_fixtures,
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
    run_terminal_scenario(
        executable,
        description="Keeper Memory journal timeline",
        interact=memory_journal_timeline_interaction(),
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": (200, []),
            "/api/v1/keepers/alpha/memory-journal?limit=20": memory_journal_fixture(),
        },
    )
    run_terminal_scenario(
        executable,
        description="Keeper provider-input Context Inspector",
        interact=context_inspector_interaction(),
        http_fixtures=context_inspector_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Keeper chat visibility modes",
        interact=chat_visibility_modes_interaction(),
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": autonomous_turn_history_fixture(),
        },
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
        description="Keeper lanes unread, failed, empty, and populated",
        interact=keeper_lanes_interaction(lanes_fixtures, lanes_gate),
        http_fixtures=lanes_fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Code lane lists, drills, and lexes",
        interact=code_lane_interaction,
        http_fixtures=code_lane_fixtures(),
    )
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
        "/api/v1/workspace/children?path=repos/masc/lib&limit=500&keeper=alpha",
        "/api/v1/workspace/children?path=repos%2Fmasc%2Flib&limit=500&keeper=alpha",
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
    repositories_fixtures = keeper_runtime_http_fixtures()
    repositories_fixtures[REPOSITORIES_PATH] = repositories_fixture()
    repositories_fixtures["/api/v1/workspace/tree?depth=0&limit=200&repo_id=masc"] = (
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
    repo_file = (200, {"ok": True, "content": "let n = 3\n"})
    for file_path in (
        "/api/v1/workspace/file?path=note.ml&repo_id=masc",
    ):
        repositories_fixtures[file_path] = repo_file
    notes_response = (
        200,
        {
            "ok": True,
            "data": [
                {"id": "an-1", "file_path": "note.ml", "line_start": 1,
                 "line_end": 1, "keeper_id": "alpha", "kind": "Decision",
                 "content": "keep n at three until the probe lands",
                 "goal_id": None, "task_id": "task-77", "references": [],
                 "created_at_ms": 1, "updated_at_ms": 1},
            ],
        },
    )
    repositories_fixtures[
        "/api/v1/ide/annotations?codebase=github.com_jeong-sik_masc&file_path=note.ml"
    ] = notes_response
    repositories_fixtures[
        "/api/v1/ide/regions?codebase=github.com_jeong-sik_masc&file_path=note.ml"
    ] = (
        200,
        {"ok": True, "data": [
            {"file_path": "note.ml", "line_start": 1, "line_end": 1,
             "keeper_id": "alpha",
             "source": {"type": "tool_call", "tool_name": "Edit", "turn": 7},
             "timestamp_ms": 1787600000000},
        ]},
    )
    repositories_fixtures[
        "/api/v1/ide/annotations?codebase=github.com_jeong-sik_masc"
    ] = (
        201,
        {"ok": True, "data": {"id": "an-2", "file_path": "note.ml",
         "line_start": 1, "line_end": 1, "keeper_id": "masc-tui",
         "kind": "Question", "content": "why three?", "goal_id": None,
         "task_id": None, "references": [], "created_at_ms": 2,
         "updated_at_ms": 2}},
    )
    note_requests: HttpRequests = []
    with note_editor_script() as note_editor:
        run_terminal_scenario(
            executable,
            description="Repositories Enter opens the Code tree",
            interact=repositories_enter_interaction(note_requests),
            http_fixtures=repositories_fixtures,
            http_requests=note_requests,
            extra_env={"EDITOR": note_editor},
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
        description="Board missing target recovery",
        interact=board_missing_target_interaction(missing_target_fixtures, late_b),
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
        refresh=0.05,
    )
    run_terminal_scenario(
        executable,
        description="Keeper phase and model",
        interact=keeper_runtime_phase_and_model_interaction,
        http_fixtures=keeper_runtime_http_fixtures(),
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


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_keyboard_input.py <masc_tui.exe>")
    run_keyboard_regression(os.path.abspath(sys.argv[1]))
    print("tui keyboard PTY regression: PASS")


if __name__ == "__main__":
    main()
