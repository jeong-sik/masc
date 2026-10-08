"""Actual terminal order follows an admission prelude, not receipt clocks.

An external control change races ordinary Enter. The owner accepts that input
but reports stale control; buffered execution has an earlier event timestamp.
The HTTP wire fixture models this producer boundary, not Owner/SQLite execution.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import threading

import tui_keyboard_chat as chat
import tui_keyboard_harness as h


class ReceiptFixture:
    def __init__(self):
        self.environment = chat.AtomicChatFixture()
        self.received = threading.Event()
        self.release_buffered_events = threading.Event()
        self.requests = []
        self.fixtures = self.environment.fixtures
        self.fixtures["/api/v1/keepers/turns"] = self.turns
        self.fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(self.stream)
        self.fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
        self.fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
            200, {"keeper": "alpha", "entries": []})
        path = "/api/v1/gate/keepers?detailed=true"
        self.fixtures[path] = h.keeper_runtime_http_fixtures(alpha_runtime_id="cfg")[path]

    def turns(self):
        status, payload = self.environment.turns()
        turn = payload["keepers"][0]["turn"]
        if self.received.is_set() and turn is not None:
            turn["lane"] = "chat_operation"
            turn["interrupt_token"] = "bc0f634a-a244-4cf6-bd69-3c231cd86e47"
            turn["preview"]["text_tail"] = "Buffered accepted execution"
        return status, payload

    def stream(self, body):
        request = json.loads(body)
        intent = request["admission_intent"]
        assert intent == {"kind": "interactive", "control_token": "control-before-stop",
            "interrupt_token": None, "operation_id": None}, intent
        self.requests.append(request)
        # The external controller changes authority after the client's last
        # observed snapshot, immediately before the owner's admission decision.
        self.environment.token = "control-after-external-change"
        events = [json.loads(block.removeprefix(b"data: ")) for block in
            chat.keeper_chat_succeeded_response(body).body.split(b"\n\n") if block]
        receipt = events[0]
        receipt["timestamp"] = 200.0
        receipt["value"].update({"state": "Queued", "queued_count": 1,
            "interactive": {"outcome": "stale_control",
                "chat_control_token": self.environment.token, "signalled": False,
                "resumed": False, "interrupt_error": None}})
        for event in events[1:]:
            event["timestamp"] = 110.0
            if event["type"] == "TEXT_MESSAGE_CONTENT":
                event["delta"] = "계속할게요."
            if event["type"] == "CUSTOM" and event.get("name") == "KEEPER_REPLY_DETAILS":
                event["value"]["reply"] = "계속할게요."

        def encode(event):
            return ("data: " + json.dumps(event) + "\n\n").encode()

        def chunks():
            self.received.set()
            yield encode(receipt)
            if not self.release_buffered_events.wait(timeout=30):
                raise AssertionError("buffered execution gate was never released")
            self.environment.release.set()
            yield b"".join(encode(event) for event in events[1:])

        return h.StreamingHttpResponse(chunks)

    def close(self):
        self.release_buffered_events.set()
        self.environment.release.set()
        self.environment.release_interrupt.set()
        self.environment.release_first_acceptance.set()


def run(executable):
    fixture = ReceiptFixture()
    authored, reply = "아니야 진행해".encode(), "계속할게요.".encode()
    notice = b"Message queued:"

    def interact(process, fd, _slave, output, _base):
        def capture(stage, columns, executed):
            for width in (columns + 1, columns):
                frame = h.resize_and_wait(process, fd, output, rows=40, columns=width,
                    needle=reply if executed else notice, controls=(h.FULL_REDRAW,),
                    final_cursor=b"\x1b[?25h")
            cells = h.screen_rows(frame)
            screen = b"\n".join(cells.get(row, b"") for row in range(1, 41))
            assert screen.count(authored) == 1, (stage, screen)
            assert sum(notice in row for row in cells.values()) == 1, (stage, screen)
            if executed:
                user_row = h.screen_row_of(cells, authored)
                notice_row = h.screen_row_of(cells, notice)
                reply_row = h.screen_row_of(cells, reply)
                assert 0 < user_row < notice_row < reply_row, (stage, screen)
                assert b"YOU" in screen and "처리 대기".encode() not in screen, screen
            else:
                assert b"YOU" not in screen and reply not in screen, screen
                assert "처리 대기".encode() in screen, screen
            print("STUDIO_CAPTURE=" + json.dumps({
                "suite": "test_tui_admission_notice_pty", "name": f"{stage}-{columns}",
                "rows": 40, "columns": columns, "provenance": "fixture PTY",
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": screen.decode(errors="replace"),
            }), flush=True)

        try:
            chat.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, authored, h.composer_showing(authored))
            os.write(fd, b"\r")
            assert h.wait_for_fixture_event(process, fd, output, fixture.received, timeout=5)
            h.wait_for_output(process, fd, output, notice, start=0, timeout=5)
            for columns in (80, 140):
                capture("receipt-before-execution-evidence", columns, False)
            fixture.release_buffered_events.set()
            h.wait_for_output(process, fd, output, reply, start=0, timeout=10)
            for columns in (80, 140):
                capture("receipt-before-earlier-clock-reply", columns, True)
            assert len(fixture.requests) == 1 and fixture.requests[0]["message"] == authored.decode()
            h.send_and_wait(process, fd, output, b"\x11", b"Info")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            fixture.close()

    h.run_terminal_scenario(executable,
        description="Stale-control receipt precedes an earlier-clock reply without becoming USER speech",
        interact=interact, http_fixtures=fixture.fixtures, refresh=0.2)


if __name__ == "__main__":
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest(), flush=True)
    run(sys.argv[1])
    print("TUI admission notice PTY: PASS")
