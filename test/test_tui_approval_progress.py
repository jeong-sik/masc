"""Exercise the real TUI while one approval and another call coexist.

Runs against an existing binary and a local fixture only. No Keeper runs.
The captured PTY frame is emitted with the executable digest for CI evidence.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import threading
import zlib

import test_tui_keyboard_input as h


def scenario(binary: str, columns: int) -> None:
    release = threading.Event()

    def respond(body: bytes):
        normal = h.keeper_chat_succeeded_response(body)
        blocks = [block for block in normal.body.split(b"\n\n") if block]
        start = next(i for i, block in enumerate(blocks)
                     if json.loads(block.removeprefix(b"data: "))["type"] == "RUN_STARTED")
        run = json.loads(blocks[start].removeprefix(b"data: "))

        def event(kind, **fields):
            return {"type": kind, "threadId": run["threadId"],
                    "runId": run["runId"], "timestamp": 1.0, **fields}

        def tool(kind, number, name=None):
            fields = {"toolStreamScope": 0, "toolCallBlockIndex": number,
                      "toolCallId": f"call-{number}"}
            if name is not None:
                fields["toolCallName"] = name
            return event(kind, **fields)

        progress = [
            tool("TOOL_CALL_START", 0, "Edit"),
            event("CUSTOM", name="KEEPER_TOOL_APPROVAL_REQUESTED", value={
                "tool_call_id": "call-0", "tool_call_name": "Edit", "args": "{}",
                "question": "Apply isolated edit?", "because": "Fixture approval",
            }),
            tool("TOOL_CALL_START", 1, "Read"),
            tool("TOOL_CALL_END", 1),
        ]

        def chunks():
            yield b"\n\n".join(blocks[:start + 1]) + b"\n\n"
            for row in progress:
                yield b"data: " + json.dumps(row).encode() + b"\n\n"
            # A harness deadline fails the scenario; it never claims a result.
            release.wait(timeout=30)

        return h.StreamingHttpResponse(chunks)

    fixtures = {"/api/v1/keepers/chat/stream": h.RequestHttpResponse(respond)}

    def interact(process, master, _slave, output, _base):
        try:
            h.resize_and_wait(process, master, output, rows=30, columns=columns - 1,
                              needle=b"MASC Overview")
            h.resize_and_wait(process, master, output, rows=30, columns=columns,
                              needle=b"MASC Overview")
            h.send_and_wait(process, master, output, b"2", b"MASC Keepers")
            h.select_keeper_row(process, master, output, b"alpha")
            h.send_and_wait(process, master, output, b"c",
                            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
            h.send_and_wait(process, master, output, b"observe", b"observe")
            before = len(output)
            os.write(master, b"\r")
            h.wait_for_output(process, master, output, b"awaiting results: Read",
                              start=before, timeout=10)
            # Force a complete frame so retained terminal cells cannot hide a
            # missing approval or activity row in an incremental update.
            h.resize_and_wait(process, master, output, rows=30, columns=columns - 1,
                              needle=b"awaiting results: Read")
            before = len(output)
            h.resize_and_wait(process, master, output, rows=30, columns=columns,
                              needle=b"awaiting results: Read", controls=(h.FULL_REDRAW,))
            redraw = output.find(h.FULL_REDRAW, before)
            assert redraw >= 0
            h.wait_for_output(process, master, output, h.FRAME_END, start=redraw, timeout=3)
            end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
            start = output.rfind(h.FRAME_START, before, redraw)
            assert start >= 0
            frame = bytes(output[start:end])
            screen = h.screen_text(frame)
            assert b"IN PROGRESS" in screen and b"awaiting results: Read" in screen, screen
            assert b"approval for Edit:" in screen and b"[y]" in screen and b"[n]" in screen, screen
            assert b"held at a tool call" not in screen, screen
            # This fixture uses ASCII content and single-cell frame glyphs.
            # Check the required text's actual addressed row and column span,
            # not merely its presence somewhere in the emitted bytes.
            rows = h.screen_rows(frame)
            for needle in (b"IN PROGRESS", b"awaiting results: Read",
                           b"approval for Edit:", b"[y]", b"[n]"):
                row = h.screen_row_of(rows, needle)
                assert 1 <= row <= 30, (needle, row)
                end_column = h.fixture_cell_width(
                    rows[row][:rows[row].index(needle) + len(needle)].decode())
                assert end_column <= columns, (needle, end_column, columns)
            print("APPROVAL_PROGRESS_PTY " + json.dumps({
                "columns": columns, "rows": 30,
                "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                "encoding": "zlib+base64", "pty": base64.b64encode(zlib.compress(frame)).decode(),
            }), flush=True)
        finally:
            release.set()
        # End the isolated process through its normal signal cleanup. Chat
        # navigation after an intentionally unfinished stream is not this
        # scenario's assertion, and its parent surface depends on layout.
        os.killpg(process.pid, signal.SIGTERM)

    h.run_terminal_scenario(binary, description=f"approval and other work coexist ({columns} columns)",
                            interact=interact, http_fixtures=fixtures, confirm_exit=b"")


if __name__ == "__main__":
    executable = str(Path(sys.argv[1]).resolve())
    for width in (100, 160):
        scenario(executable, width)
