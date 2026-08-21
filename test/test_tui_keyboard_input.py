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
import subprocess
import sys
import tempfile
import termios
import threading
import time
from typing import Any

Interaction = Callable[[subprocess.Popen[bytes], int, int, bytearray, str], None]
HttpFixtures = dict[str, tuple[int, object]]
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
BOARD_CELL_BODY = ("한" * 20) + " " + ("한" * 20)


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
            status, payload = fixtures.get(
                self.path,
                (503, {"error": "fixture endpoint unavailable"}),
            )
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
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
    needle: bytes,
    *,
    start: int,
    timeout: float,
) -> None:
    deadline = time.monotonic() + timeout
    while needle not in output[start:]:
        read_available(master_fd, output)
        if process.poll() is not None:
            raise AssertionError(f"TUI exited before {needle!r}: {bytes(output)!r}")
        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            raise AssertionError(f"timed out waiting for {needle!r}: {bytes(output)!r}")
        select.select([master_fd], [], [], min(0.1, remaining))


def send_and_wait(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    data: bytes,
    needle: bytes,
) -> bytes:
    read_available(master_fd, output)
    start = len(output)
    os.write(master_fd, data)
    wait_for_output(process, master_fd, output, needle, start=start, timeout=3.0)
    needle_end = output.find(needle, start) + len(needle)
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
    if not rendered_row.endswith("│"):
        raise AssertionError(f"message row lost its right border: {rendered_row!r}")
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
    needle: bytes,
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
    needle_end = output.find(needle, frame_start) + len(needle)
    if final_cursor is not None:
        wait_for_output(
            process,
            master_fd,
            output,
            final_cursor,
            start=needle_end,
            timeout=3.0,
        )
        cursor_start = output.find(final_cursor, needle_end)
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


def keeper_metadata(name: str) -> dict[str, object]:
    metadata: dict[str, object] = {
        "schema": "masc.keeper_meta.v1",
        "name": name,
        "agent_name": f"keeper-{name}-agent",
        "instructions": "",
        "autonomous_instructions": None,
        "trace_id": f"trace-{name}",
        "multimodal_policy": "inherit",
        "trace_history": [],
        "generation": 1,
        "created_at": "2026-08-22T00:00:00Z",
        "updated_at": "2026-08-22T00:00:00Z",
        "last_proactive_outcome": "never_started",
        "last_proactive_reason": "",
        "last_proactive_preview": "",
        "last_compaction_decision": "initialized",
        "last_autonomous_action_at": "",
        "message_scope_ack_id": None,
        "last_blocker": None,
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
        "last_compaction_check_ts",
        "autonomous_action_count",
        "autonomous_turn_count",
        "autonomous_text_turn_count",
        "autonomous_tool_turn_count",
        "board_reactive_turn_count",
        "mention_reactive_turn_count",
        "noop_turn_count",
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
            "content": f"comment-{index}",
            "created_at_iso": "2026-08-22T00:00:00Z",
        }
        for index in range(1, 6)
    ]
    return {
        "/api/v1/dashboard/briefing": (
            200,
            {
                "summary": {
                    "workspace_health": "ok",
                    "cluster": "cluster-a",
                    "project": "project-a",
                    "active_agents": 2,
                    "incident_count": 6,
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
    refresh: float = 60.0,
    http_fixtures: HttpFixtures | None = None,
    http_requests: HttpRequests | None = None,
    prepare_workspace: WorkspaceSetup | None = None,
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
                environment.update(
                    {
                        "MASC_BASE_PATH": base_path,
                        "MASC_HOST": "127.0.0.1",
                        "MASC_TUI_SYNC": "off",
                        "TERM": "xterm-256color",
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
        b"\x1b[7m>\x1b[0m  \x1b[1mbeta",
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[A",
        b"\x1b[7m>\x1b[0m  \x1b[1malpha",
    )
    send_and_wait(process, master_fd, output, b"\r", b"Keeper: \x1b[1malpha")
    send_and_wait(process, master_fd, output, b"m", b"Message to: alpha")
    send_and_wait(process, master_fd, output, b"q2Q", b"> q2Q")

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
        needle=b"> q2Q",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25h",
    )
    if b"> q2Qx" in restored_message_patch or b"(sending " in restored_message_patch:
        raise AssertionError(
            "compact viewport accepted hidden message input: "
            f"{restored_message_patch!r}"
        )

    send_and_wait(process, master_fd, output, b"\x1b", b"Keeper: \x1b[1malpha")
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
        needle=b"Keeper: \x1b[1malpha",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )

    send_and_wait(process, master_fd, output, b"l", b"Keeper Logs: alpha")
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
        needle=b"Keeper Logs: alpha",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"q")


def interrupt_with_ctrl_c(
    _process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    _output: bytearray,
    _base_path: str,
) -> None:
    os.write(master_fd, b"\x03")


def quit_from_compact_message(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
    send_and_wait(process, master_fd, output, b"\r", b"Keeper: \x1b[1malpha")
    send_and_wait(process, master_fd, output, b"m", b"Message to: alpha")
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
    send_and_wait(process, master_fd, output, b"\t", b"MASC Keepers")
    send_and_wait(process, master_fd, output, b"\t", b"MASC Approvals")
    send_and_wait(process, master_fd, output, b"\t", b"MASC Board")
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
    if b"comment-4" in board or b"comment-5" in board:
        raise AssertionError(f"14-row Board exceeded its row budget: {board!r}")
    if "└".encode() not in board:
        raise AssertionError(f"14-row Board omitted its bottom border: {board!r}")

    send_and_wait(process, master_fd, output, b"j", b"comment-4")
    send_and_wait(process, master_fd, output, b"j", b"comment-5")
    os.write(master_fd, b"q")


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
        send_and_wait(process, master_fd, output, b"\r", b"Keeper: \x1b[1malpha")
        send_and_wait(process, master_fd, output, b"m", b"Message to: alpha")

        ascii_frame = send_and_wait(process, master_fd, output, b"A", b"> A")
        assert_message_input_frame(
            ascii_frame,
            row=25,
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
            b"> " + combining_text.encode(),
        )
        assert_message_input_frame(
            combining_frame,
            row=25,
            columns=100,
            input_text=combining_text,
            cursor_column=8,
        )
        send_and_wait(process, master_fd, output, b"\x15", b"> ")

        typed_frame = send_and_wait(
            process, master_fd, output, expected_bytes, b"> " + expected_bytes
        )
        typed_frame.decode("utf-8")
        assert_message_input_frame(
            typed_frame,
            row=25,
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
            needle=b"> A",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        assert_message_input_frame(
            narrow_frame,
            row=25,
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
            needle=b"> " + expected_bytes,
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        backspace_cases = (
            ("> Aé한".encode(), "🙂".encode()),
            ("> Aé".encode(), "한".encode()),
            (b"> A", "é".encode()),
        )
        for expected, removed in backspace_cases:
            frame = send_and_wait(process, master_fd, output, b"\x7f", expected)
            frame.decode("utf-8")
            if removed[:1] in frame:
                raise AssertionError(
                    f"backspace left part of UTF-8 scalar {removed!r}: {frame!r}"
                )

        send_and_wait(process, master_fd, output, b"\xe2x", b"> Ax")
        send_and_wait(process, master_fd, output, b"\x7f", b"> A")
        send_and_wait(process, master_fd, output, b"\xe2\x15", b"> ")
        send_and_wait(process, master_fd, output, b"A", b"> A")
        os.write(master_fd, b"\xe2")
        wait_for_terminal_input_consumed(slave_fd)
        time.sleep(0.08)
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=29,
            columns=100,
            needle=b"Message to: alpha",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        send_and_wait(process, master_fd, output, b"y", b"> Ay")

        send_and_wait(process, master_fd, output, b"\x15", b"> ")
        send_and_wait(
            process, master_fd, output, expected_bytes, b"> " + expected_bytes
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

        send_and_wait(process, master_fd, output, b"\x1b", b"Keeper: \x1b[1malpha")
        os.write(master_fd, b"q")

    return interact


def run_keyboard_regression(executable: str) -> None:
    utf8_requests: HttpRequests = []
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
        description="q",
        interact=navigate_with_arrows_and_quit,
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
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_keyboard_input.py <masc_tui.exe>")
    run_keyboard_regression(os.path.abspath(sys.argv[1]))
    print("tui keyboard PTY regression: PASS")


if __name__ == "__main__":
    main()
