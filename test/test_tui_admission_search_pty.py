"""A searched request receipt stays pinned when its execution changes.

The canonical request is outside this pane. Its observed follower receives
Run_started then Batch_bound and one long text delta while the terminal stays
held. This exercises real TUI keys and wire folds, not Owner/SQLite execution.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import time

import tui_keyboard_chat as chat
import tui_keyboard_harness as h


class BoundFollowerFixture:
    def __init__(self):
        self.environment = chat.AtomicChatFixture()
        self.release_growth = threading.Event()
        self.release_terminal = threading.Event()
        self.received = threading.Event()
        self.requests = []
        self.canonical_id = "other-surface-canonical-request"
        self.answer = "\n".join(f"BATCH_ANSWER_{line:03d}" for line in range(100))
        self.fixtures = self.environment.fixtures
        self.fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(self.stream)
        self.fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
        self.fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
            200, {"keeper": "alpha", "entries": []})

    @staticmethod
    def encode(event):
        return ("data: " + json.dumps(event) + "\n\n").encode()

    def stream(self, body):
        request = json.loads(body)
        self.requests.append(request)
        assert request["request_id"] != self.canonical_id
        events = [json.loads(block.removeprefix(b"data: ")) for block in
            chat.keeper_chat_succeeded_response(body).body.split(b"\n\n") if block]
        receipt = events[0]
        receipt["timestamp"] = time.time()
        receipt["value"].update({"state": "Queued", "queued_count": 2,
            "interactive": {"outcome": "paused", "chat_control_token": self.environment.token,
                "signalled": False, "resumed": False, "interrupt_error": None}})

        def chunks():
            self.received.set()
            yield self.encode(receipt)
            if not self.release_growth.wait(timeout=30):
                raise AssertionError("batch growth was never released")
            self.environment.release.set()
            for event in events[1:]:
                event["timestamp"] = time.time()
                if event["type"] == "TEXT_MESSAGE_CONTENT":
                    event["delta"] = self.answer
                if event["type"] == "CUSTOM" and event.get("name") == "KEEPER_REPLY_DETAILS":
                    event["value"]["reply"] = self.answer
            # The real producer rewrites lifecycle IDs for each member, so
            # the ordinary follower event IDs stay as the constructor made them.
            binding = {"type": "CUSTOM", "threadId": events[1]["threadId"],
                "runId": events[1]["runId"], "timestamp": time.time(),
                "name": "KEEPER_CHAT_BATCH_BOUND", "value": {
                    "operation_id": request["request_id"], "execution_id": self.canonical_id}}
            yield self.encode(events[1]) + self.encode(binding) + b"".join(
                self.encode(event) for event in events[2:4])
            if not self.release_terminal.wait(timeout=30):
                raise AssertionError("batch terminal was never released")
            for event in events[4:]:
                event["timestamp"] = time.time()
            yield b"".join(self.encode(event) for event in events[4:])

        return h.StreamingHttpResponse(chunks)

    def close(self):
        self.release_growth.set()
        self.release_terminal.set()
        self.environment.release.set()
        self.environment.release_interrupt.set()
        self.environment.release_first_acceptance.set()


def run(executable):
    fixture = BoundFollowerFixture()
    authored = "내 입력만 남겨 줘".encode()
    notice = b"Message queued:"

    def interact(process, fd, _slave, output, _base):
        def capture(stage, columns, streaming):
            for width in (columns + 1, columns):
                frame = h.resize_and_wait(process, fd, output, rows=40, columns=width,
                    needle=notice, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h")
            cells = h.screen_rows(frame)
            screen = b"\n".join(cells.get(row, b"") for row in range(1, 41))
            assert notice in screen, (stage, screen)
            # The old pause belongs to the receipt snapshot, even while the
            # current turn's footer reports streamed answer growth.
            assert b"RECEIPT" in screen and "접수 당시: ".encode() in screen, (stage, screen)
            assert b"Keeper remains paused" in screen, (stage, screen)
            if streaming:
                # The answer is a single delta. STREAMING proves that the
                # actual client fold includes all 100 lines, not just a server gate.
                assert b"STREAMING" in screen, (stage, screen)
                assert b"YOU" in screen and authored in screen, (stage, screen)
                assert b"BATCH_ANSWER_099" not in screen, (stage, screen)
            else:
                assert b"YOU" not in screen, (stage, screen)
            print("STUDIO_CAPTURE=" + json.dumps({"suite": "test_tui_admission_search_pty",
                "name": f"{stage}-{columns}", "rows": 40, "columns": columns,
                "provenance": "fixture PTY", "frame_b64": base64.b64encode(frame).decode(),
                "screen": screen.decode(errors="replace")}), flush=True)

        try:
            chat.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, authored, h.composer_showing(authored))
            os.write(fd, b"\r")
            assert h.wait_for_fixture_event(process, fd, output, fixture.received, timeout=5)
            h.wait_for_output(process, fd, output, notice, start=0, timeout=5)
            query = b"/find Message queued:"
            h.send_and_wait(process, fd, output, query, h.composer_showing(query))
            h.send_and_wait(process, fd, output, b"\r", b"row(s) back")
            for columns in (80, 140):
                capture("searched-receipt-before-binding", columns, False)
            start = len(output)
            fixture.release_growth.set()
            h.wait_for_output(process, fd, output, b"STREAMING", start=start, timeout=10)
            # No End or second search before these captures: either would
            # replace the saved pre-binding pin and conceal the regression.
            for columns in (80, 140):
                capture("searched-receipt-during-batch-growth", columns, True)
            fixture.release_terminal.set()
            h.send_and_wait(process, fd, output, b"\x1b[F", b"BATCH_ANSWER_099")
            assert len(fixture.requests) == 1 and fixture.requests[0]["message"] == authored.decode()
            assert not fixture.environment.interrupt_requests and fixture.environment.run_next_calls == 0
            h.send_and_wait(process, fd, output, b"\x11", b"Info")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            fixture.close()

    h.run_terminal_scenario(executable,
        description="Receipt search pin survives follower binding and a long batch answer",
        interact=interact, http_fixtures=fixture.fixtures, refresh=0.2)


if __name__ == "__main__":
    executable = Path(sys.argv[1]).resolve()
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(executable.read_bytes()).hexdigest(), flush=True)
    run(executable)
    print("TUI admission search PTY: PASS", flush=True)
