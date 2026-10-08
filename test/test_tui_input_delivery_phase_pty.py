"""Actual PTY input: local retention, transport, receipt and execution differ.

The first HTTP receipt is held while a second Enter stays local. Releasing
the receipt admits both inputs, but RUN_STARTED stays gated independently.
Authored text must survive each transition without becoming a delivery notice.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys

import tui_keyboard_chat as chat
import tui_keyboard_harness as h


def run(executable):
    fixture = chat.AtomicChatFixture(hold_first_acceptance=True)
    fixture.fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixture.fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
        200, {"keeper": "alpha", "entries": []})
    runtime_path = "/api/v1/gate/keepers?detailed=true"
    fixture.fixtures[runtime_path] = h.keeper_runtime_http_fixtures(
        alpha_runtime_id="cfg")[runtime_path]
    first, second = "엉...".encode(), "대기한 입력".encode()

    def interact(process, fd, _slave, output, _base):
        def capture(name, required, absent=()):
            # The complete redraw supplies the original PTY bytes and an
            # independent cell reading for xterm screenshot replay.
            frame = h.resize_and_wait(process, fd, output, rows=40, columns=121,
                needle=required[0], controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25h")
            frame = h.resize_and_wait(process, fd, output, rows=40, columns=120,
                needle=required[0], controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25h")
            cells = h.screen_rows(frame)
            screen = b"\n".join(cells.values())
            assert all(word in screen for word in required), (name, screen)
            assert not any(word in screen for word in absent), (name, screen)
            print("STUDIO_CAPTURE=" + json.dumps({
                "suite": "test_tui_input_delivery_phase_pty", "name": name,
                "rows": 40, "columns": 120, "provenance": "fixture PTY",
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": b"\n".join(cells.get(row, b"")
                    for row in range(1, 41)).decode(errors="replace"),
            }), flush=True)
            return screen

        try:
            chat.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, first, h.composer_showing(first))
            os.write(fd, b"\r")
            assert h.wait_for_fixture_event(process, fd, output,
                fixture.first_post_received, timeout=5), "first POST never arrived"
            h.wait_for_output(process, fd, output, "전송 중".encode(),
                start=0, timeout=5)
            capture("transport-awaiting-receipt", (first, "전송 중".encode()),
                (b"reply-", "처리 대기".encode(), b"YOU"))

            h.send_and_wait(process, fd, output, second, h.composer_showing(second))
            h.send_and_wait(process, fd, output, b"\r", "내 메시지 2건 대기".encode())
            capture("local-input-behind-transport", (
                first, second, "전송 중".encode(), "전송 대기".encode()),
                (b"reply-", "처리 대기".encode(), b"YOU"))
            with fixture.lock:
                assert [request["message"] for request in fixture.received] == [first.decode()], (
                    "the retained second Enter reached HTTP before the first receipt")

            fixture.release_first_acceptance.set()
            chat.wait_for_atomic_admissions(process, fd, output, fixture, 2)
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: "처리 대기".encode() in h.screen_text(bytes(output))
                    and "전송 중".encode() not in h.screen_text(bytes(output)),
                timeout=5), "server receipts did not reach the visible state"
            capture("server-received-before-execution", (
                first, second, "처리 대기".encode()),
                (b"reply-", "전송 중".encode(), "전송 대기".encode(), b"YOU"))
            with fixture.lock:
                assert [request["message"] for request in fixture.submitted] == [
                    first.decode(), second.decode()], "admission changed input or order"

            fixture.release.set()
            h.wait_for_output(process, fd, output, b"reply-" + first, start=0, timeout=10)
            h.wait_for_output(process, fd, output, b"reply-" + second, start=0, timeout=10)
            capture("execution-consumed-original-inputs", (
                b"reply-" + first, b"reply-" + second, b"YOU"),
                ("대기 입력".encode(), "전송 중".encode(), "처리 대기".encode()))
            # Leave through the existing chat navigation after both operations
            # have settled; Escape must not request a new interruption.
            h.send_and_wait(process, fd, output, b"\x11", b"Info")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            fixture.release_first_acceptance.set()
            fixture.release.set()
            fixture.release_interrupt.set()

    h.run_terminal_scenario(executable,
        description="Original input and delivery state stay separate across admission",
        interact=interact, http_fixtures=fixture.fixtures, refresh=0.2)


if __name__ == "__main__":
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(
        Path(sys.argv[1]).read_bytes()).hexdigest(), flush=True)
    run(sys.argv[1])
    print("TUI input delivery phase PTY: PASS")
