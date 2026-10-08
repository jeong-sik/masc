"""Actual TUI: provider stop ends activity, while the Keeper turn stays open."""
import json
import os
import sys
import threading
import time

import tui_keyboard_chat as chat
import tui_keyboard_harness as h


def run(executable):
    fixture = chat.AtomicChatFixture(first_working=True)
    stop_answer = threading.Event()
    resume_reasoning = threading.Event()
    stop_reasoning = threading.Event()

    def stream(body):
        request = json.loads(body)
        response = fixture.stream(body)

        def event(name, value):
            return ("data: " + json.dumps({
                "type": "CUSTOM", "threadId": "keeper:alpha",
                "runId": "keeper-operation-run-" + request["request_id"],
                "timestamp": time.time(), "name": name, "value": value,
            }) + "\n\n").encode()

        def chunks():
            original = response.chunks()
            try:
                prefix = []
                for block in next(original).split(b"\n\n"):
                    if block:
                        value = json.loads(block.removeprefix(b"data: "))
                        value["timestamp"] = time.time()
                        prefix.append(("data: " + json.dumps(value)).encode())
                yield b"\n\n".join(prefix) + b"\n\n"
                assert stop_answer.wait(timeout=15), "answer stop was not released"
                yield event("KEEPER_STREAM_MESSAGE_STOP", None)
                assert resume_reasoning.wait(timeout=15), "next response was not released"
                yield event("KEEPER_STREAM_MESSAGE_START", {
                    "provider_message_id": "next-response", "model": "observed-model"})
                yield event("KEEPER_THINKING_DELTA", {"index": 0, "delta": "considering next step"})
                assert stop_reasoning.wait(timeout=15), "reasoning stop was not released"
                yield event("KEEPER_STREAM_MESSAGE_STOP", None)
                yield from original
            finally:
                original.close()

        return h.StreamingHttpResponse(chunks)

    fixture.fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(stream)

    def interact(process, fd, _slave, output, _base):
        def observe(label, expected, absent=(), *, start=0):
            h.wait_for_output(process, fd, output, expected, start=start, timeout=5)
            # Editing the draft completes a new frame even when the status row
            # is retained; screen_rows reconstructs the actual terminal cells.
            marker = ("frame-" + label).encode()
            h.send_and_wait(process, fd, output, b"\x15" + marker, h.composer_showing(marker))
            rows = list(h.screen_rows(bytes(output)).values())
            progress = next((row for row in rows if b"TURN" in row and b"IN PROGRESS" in row), None)
            assert progress is not None, repr(rows)
            assert expected in progress, (label, progress)
            assert not any(word in progress for word in absent), (label, progress)
            assert any(b"reply-phase-check" in row for row in rows), "response body disappeared"
            print("MODEL_PHASE_FRAME=" + json.dumps({"stage": label,
                  "screen": h.screen_text(bytes(output)).decode("utf-8", errors="replace")}), flush=True)

        try:
            chat.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, b"phase-check", h.composer_showing(b"phase-check"))
            os.write(fd, b"\r")
            observe("answering", b"STREAMING")
            start = len(output)
            stop_answer.set()
            observe("answer-ended", b"model response ended", (b"STREAMING", b"THINKING"), start=start)
            start = len(output)
            resume_reasoning.set()
            observe("reasoning", b"THINKING", (b"model response ended",), start=start)
            start = len(output)
            stop_reasoning.set()
            observe("reasoning-ended", b"model response ended", (b"STREAMING", b"THINKING"), start=start)
            fixture.release.set()
            fixture.release_interrupt.set()
            h.send_and_wait(process, fd, output, b"\x15", h.composer_showing(b""))
            h.send_and_wait(process, fd, output, b"\x11", b"Info")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            stop_answer.set()
            resume_reasoning.set()
            stop_reasoning.set()
            fixture.release.set()
            fixture.release_interrupt.set()

    h.run_terminal_scenario(executable,
        description="Provider response stop clears activity without ending the Keeper turn",
        interact=interact, http_fixtures=fixture.fixtures, refresh=0.2)


if __name__ == "__main__":
    run(sys.argv[1])
    print("TUI model response phase PTY: PASS")
