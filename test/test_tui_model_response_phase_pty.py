"""Actual TUI with controlled SSE: content, response and turn ends stay distinct."""
import base64
import hashlib
import json
from pathlib import Path
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
    content_gates = {stage: threading.Event() for stage in (
        "late-runtime-name", "repeated-runtime-name", "overlap", "thinking-ended", "text-ended", "native-start",
        "native-progress", "native-heartbeat-decreased", "native-end")}

    def stream(body):
        request = json.loads(body)
        response = fixture.stream(body)

        def event(name, value):
            return ("data: " + json.dumps({
                "type": "CUSTOM", "threadId": "keeper:alpha",
                "runId": "keeper-operation-run-" + request["request_id"],
                "timestamp": time.time(), "name": name, "value": value,
            }) + "\n\n").encode()

        def activity(scope, index, channel, state, provider_message_id=None):
            value = {"generation": 0, "stream_scope": scope,
                     "block_index": index, "channel": channel, "state": state}
            if provider_message_id is not None:
                value["provider_message_id"] = provider_message_id
            return event("KEEPER_MODEL_CONTENT_ACTIVITY", value)

        def content_gate(stage):
            assert content_gates[stage].wait(timeout=15), f"{stage} was not released"

        def chunks():
            original = response.chunks()
            try:
                prefix = []
                for block in next(original).split(b"\n\n"):
                    if block:
                        value = json.loads(block.removeprefix(b"data: "))
                        value["timestamp"] = time.time()
                        prefix.append(("data: " + json.dumps(value)).encode())
                yield (b"\n\n".join(prefix) + b"\n\n"
                       + activity(0, 0, "text", "observed"))
                content_gate("late-runtime-name")
                yield event("KEEPER_RUNTIME_ATTEMPT_STARTED", {
                    "runtime_id": "observed-runtime", "attempt_index": 0})
                yield event("KEEPER_STREAM_MESSAGE_DELTA", {"usage": {"output_tokens": 1}})
                content_gate("repeated-runtime-name")
                yield event("KEEPER_RUNTIME_ATTEMPT_STARTED", {
                    "runtime_id": "observed-runtime", "attempt_index": 0})
                yield event("KEEPER_STREAM_MESSAGE_DELTA", {"usage": {"output_tokens": 2}})
                content_gate("overlap")
                yield (event("KEEPER_THINKING_DELTA", {"index": 1, "delta": "checking alongside the answer"})
                       + activity(0, 1, "thinking", "observed"))
                content_gate("thinking-ended")
                yield activity(0, 1, "thinking", "ended")
                content_gate("text-ended")
                yield activity(0, 0, "text", "ended")
                # Native activity owns the leading status clause while open.
                # Its end must reveal the retained content-ended state again.
                native = {"toolStreamScope": 0, "toolCallBlockIndex": 2,
                          "toolCallId": "native-phase-read", "toolCallName": "Read"}
                content_gate("native-start")
                yield event("KEEPER_NATIVE_TOOL_START", native)
                content_gate("native-progress")
                for progress in (
                        {"kind": "message_reported", "message": "busy"},
                        {"kind": "output_observed", "byte_count": 13},
                        {"kind": "heartbeat_reported", "elapsed_seconds": 30}):
                    yield event("KEEPER_NATIVE_TOOL_PROGRESS", {**native, "progress": progress})
                content_gate("native-heartbeat-decreased")
                yield event("KEEPER_NATIVE_TOOL_PROGRESS", {**native, "progress": {
                    "kind": "heartbeat_reported", "elapsed_seconds": 3}})
                content_gate("native-end")
                yield event("KEEPER_NATIVE_TOOL_END", native)
                assert stop_answer.wait(timeout=15), "answer stop was not released"
                yield event("KEEPER_STREAM_MESSAGE_STOP", None)
                assert resume_reasoning.wait(timeout=15), "next response was not released"
                yield event("KEEPER_STREAM_MESSAGE_START", {
                    "provider_message_id": "next-response", "model": "observed-model"})
                yield (event("KEEPER_THINKING_DELTA", {"index": 0, "delta": "considering next step"})
                       + activity(1, 0, "thinking", "observed", "next-response"))
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
            # Capture original ANSI bytes from a complete redraw. Screenshot
            # replay checks xterm cells against this independently recorded PTY.
            frame = h.resize_and_wait(process, fd, output, rows=30, columns=121,
                needle=expected, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h")
            frame = h.resize_and_wait(process, fd, output, rows=30, columns=120,
                needle=expected, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h")
            cells = h.screen_rows(frame)
            print("STUDIO_CAPTURE=" + json.dumps({
                "suite": "test_tui_model_response_phase_pty", "name": label,
                "rows": 30, "columns": 120, "provenance": "fixture PTY",
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": b"\n".join(cells.get(row, b"") for row in range(1, 31)).decode(errors="replace")}), flush=True)
            return list(cells.values())

        def observe_native_progress(label, seconds):
            reported = f"provider elapsed {seconds}s".encode()
            # Retained rendering may write only changed cells (30s -> 3s).
            # Wait for the reconstructed current screen, not a repeated prefix.
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: reported in h.screen_text(bytes(output)), timeout=5), (label, bytes(output))
            rows = observe(label, b"native running", (b"STREAMING", b"THINKING"))
            screen = b"\n".join(rows)
            assert reported in screen, (label, screen)
            assert b"13 bytes observed" in screen and b"busy" in screen, (label, screen)
            assert b"TOOLS" in screen, (label, screen)
            # The authored response remains its own unchanged physical row;
            # provider metadata belongs to the independently rendered tool.
            body_rows = [row for row in rows if b"reply-phase-check" in row]
            assert body_rows and all(row.rstrip().endswith(b"reply-phase-check") for row in body_rows), body_rows
            assert all(b"provider elapsed" not in row and b"bytes observed" not in row for row in body_rows), body_rows
            if seconds == 3:
                assert b"provider elapsed 30s" not in screen, (label, screen)

        try:
            chat.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, b"phase-check", h.composer_showing(b"phase-check"))
            os.write(fd, b"\r")
            observe("answering", b"STREAMING")
            content_gates["late-runtime-name"].set()
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: b"out 1" in h.screen_text(bytes(output)), timeout=5), "late metadata counter did not arrive"
            observe("late-runtime-name", b"STREAMING", (b"model content ended",))
            content_gates["repeated-runtime-name"].set()
            # The following usage report is the ordered processing witness.
            # An unchanged status by itself cannot prove the preceding runtime
            # metadata was consumed by the TUI.
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: b"out 2" in h.screen_text(bytes(output)), timeout=5), "repeat metadata counter did not arrive"
            observe("repeated-runtime-name", b"STREAMING", (b"model content ended",))
            start = len(output)
            content_gates["overlap"].set()
            observe("content-overlap", b"THINKING", (b"model content ended", b"model response ended"), start=start)
            start = len(output)
            content_gates["thinking-ended"].set()
            observe("thinking-content-ended", b"STREAMING", (b"THINKING", b"model content ended"), start=start)
            start = len(output)
            content_gates["text-ended"].set()
            observe("content-ended", b"model content ended", (b"STREAMING", b"THINKING", b"model response ended"), start=start)
            start = len(output)
            content_gates["native-start"].set()
            observe("native-after-content", b"native running", (b"STREAMING", b"THINKING", b"model response ended"), start=start)
            h.send_and_wait(process, fd, output, b"\x04\x04", b"tools:full")
            content_gates["native-progress"].set()
            observe_native_progress("native-mixed-progress", 30)
            content_gates["native-heartbeat-decreased"].set()
            observe_native_progress("native-provider-elapsed-decreased", 3)
            start = len(output)
            content_gates["native-end"].set()
            observe("native-ended", b"model content ended", (b"native running", b"STREAMING", b"THINKING", b"model response ended"), start=start)
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
            for gate in content_gates.values():
                gate.set()
            fixture.release.set()
            fixture.release_interrupt.set()

    h.run_terminal_scenario(executable,
        description="Content identities and provider response stop preserve the open Keeper turn",
        interact=interact, http_fixtures=fixture.fixtures, refresh=0.2, terminal_cols=140)


if __name__ == "__main__":
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest(), flush=True)
    run(sys.argv[1])
    print("TUI model response phase PTY: PASS")
