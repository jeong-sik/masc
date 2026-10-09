"""Controlled native Agent retry wire observed by the actual compiled TUI.

This is a screen-consumer witness, not a live Claude invocation. Runtime tests
own session/parent/UUID admission and stale-clear rejection. Each producer gate
is released only after the preceding state is visible in terminal cells.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

import tui_keyboard_chat as chat
import tui_keyboard_harness as h


SUITE = "test_tui_claude_agent_retry_pty"
USER_BODY = "엉... 아니야 진행해"
ANSWER = "Answer remains unchanged."
THINKING = "Observed thinking."
ROWS = 36
PROVIDER_MESSAGE = "controlled-response"
NATIVE = {"toolStreamScope": 0, "toolCallBlockIndex": 2,
          "providerMessageId": PROVIDER_MESSAGE,
          "toolCallId": "controlled-agent-call", "toolCallName": "Agent"}
AGENT = {"agent_id": "controlled-child", "subagent_type": "Explore"}


def run(executable: str, columns: int) -> None:
    fixture = chat.AtomicChatFixture(first_working=True)
    runtime_path = "/api/v1/gate/keepers?detailed=true"
    fixture.fixtures[runtime_path] = h.keeper_runtime_http_fixtures(
        alpha_runtime_id="claude.fixture")[runtime_path]
    # Supply the actual empty read contracts; a missing history endpoint is
    # not part of this retry observation scenario.
    fixture.fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixture.fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
        200, {"keeper": "alpha", "entries": []})
    gates = {name: threading.Event() for name in (
        "native-open", "retry", "heartbeat-decreased", "clear", "retry-again",
        "native-ended", "content-ended", "response-ended")}

    def stream(body):
        request = json.loads(body)
        assert request["name"] == "alpha" and request["message"] == USER_BODY, request
        response = fixture.stream(body)

        def wire(value):
            return ("data: " + json.dumps({**value, "timestamp": time.time()}) + "\n\n").encode()

        def custom(name, value):
            return wire({"type": "CUSTOM", "threadId": "keeper:alpha",
                "runId": "keeper-operation-run-" + request["request_id"],
                "name": name, "value": value})

        def activity(index, channel, state):
            return custom("KEEPER_MODEL_CONTENT_ACTIVITY", {
                "generation": 0, "stream_scope": 0, "block_index": index,
                "provider_message_id": PROVIDER_MESSAGE,
                "channel": channel, "state": state})

        def progress(value):
            return custom("KEEPER_NATIVE_TOOL_PROGRESS", {**NATIVE, "progress": value})

        def retry(attempt):
            return progress({"kind": "retry_reported", **AGENT, "attempt": attempt,
                "max_retries": 3, "retry_delay_ms": 1500,
                "error_status": 529, "error_category": "overloaded"})

        def chunks():
            original = response.chunks()
            try:
                prefix = []
                for block in next(original).split(b"\n\n"):
                    if not block:
                        continue
                    value = json.loads(block.removeprefix(b"data: "))
                    if value.get("name") == "KEEPER_CHAT_OPERATION_ACCEPTED":
                        # This ordinary Enter names no interruption target.
                        # A receipt must not invent an interruption notice.
                        value["value"]["interactive"]["signalled"] = False
                    if value["type"] == "TEXT_MESSAGE_CONTENT":
                        prefix.append(custom("KEEPER_STREAM_MESSAGE_START", {
                            "provider_message_id": PROVIDER_MESSAGE,
                            "model": "controlled-claude-model"}))
                        value["delta"] = ANSWER
                    prefix.append(wire(value))
                yield (b"".join(prefix) + activity(0, "text", "observed")
                    + custom("KEEPER_THINKING_DELTA", {"index": 1, "delta": THINKING})
                    + activity(1, "thinking", "observed"))
                gates["native-open"].wait()
                yield (custom("KEEPER_NATIVE_TOOL_START", NATIVE)
                    + progress({"kind": "heartbeat_reported", "elapsed_seconds": 30}))
                gates["retry"].wait()
                yield retry(1)
                gates["heartbeat-decreased"].wait()
                yield progress({"kind": "heartbeat_reported", "elapsed_seconds": 3})
                gates["clear"].wait()
                yield progress({"kind": "retry_cleared", **AGENT})
                gates["retry-again"].wait()
                yield retry(2)
                gates["native-ended"].wait()
                yield custom("KEEPER_NATIVE_TOOL_END", {**NATIVE, "completion": {
                    "kind": "result_received", "is_error": None, "exit_code": None}})
                gates["content-ended"].wait()
                yield activity(0, "text", "ended") + activity(1, "thinking", "ended")
                gates["response-ended"].wait()
                yield custom("KEEPER_STREAM_MESSAGE_STOP", None)
                fixture.release.wait()
                for tail in original:
                    for block in tail.split(b"\n\n"):
                        if block:
                            value = json.loads(block.removeprefix(b"data: "))
                            if value.get("name") == "KEEPER_REPLY_DETAILS":
                                value["value"]["reply"] = ANSWER
                            yield wire(value)
            finally:
                original.close()

        return h.StreamingHttpResponse(chunks)

    fixture.fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(stream)

    def interact(process, fd, _slave, output, _base):
        def current_rows():
            # Retained rendering can overwrite only the changed digit (30→3).
            # Inspect completed current cells, never a historical raw substring.
            end = output.rfind(h.FRAME_END)
            return h.screen_rows(bytes(output[:end + len(h.FRAME_END)])) if end >= 0 else {}

        def screen(rows):
            return chat.unwrapped(b"\n".join(value for _, value in sorted(rows.items())))

        def progress_row(rows):
            return next((row for row in rows.values()
                         if b"TURN" in row and b"IN PROGRESS" in row), None)

        def check_rows(label, rows, status, required, absent):
            visible = screen(rows)
            assert progress_row(rows) is not None, (label, rows)
            assert status in progress_row(rows), (label, progress_row(rows))
            assert all(text in visible for text in required), (label, required, visible)
            assert not any(text in visible for text in absent), (label, absent, visible)
            assert b"native completion reported" not in visible and b"SUCCESS" not in visible, (label, visible)
            for body, role in ((USER_BODY.encode(), b"YOU"),
                               (ANSWER.encode(), b"alpha"),
                               (THINKING.encode(), b"THINKING")):
                authored = [row for row in rows.values() if body in row]
                assert len(authored) == 1, (label, body, authored)
                assert authored[0].rstrip().endswith(body), (label, body, authored)
                assert role in authored[0], (label, role, authored)
                assert not any(value in authored[0] for value in (
                    b"provider retry", b"provider elapsed", b"error flag")), (label, authored)
            assert b"THINKING" in visible, (label, visible)  # real provided reasoning row
            if label != "provided-thinking":
                assert b"TOOLS" in visible, (label, visible)
            if status == b"native running":
                assert b"STREAMING" not in progress_row(rows) and b"THINKING" not in progress_row(rows), (label, rows)
            return visible

        def observe(label, status, required=(), absent=()):
            # The timeout bounds a failed observation. It never releases a
            # producer stage or supplies readiness in place of a visible fact.
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: progress_row(current_rows()) is not None
                    and status in progress_row(current_rows())
                    and all(value in screen(current_rows()) for value in required)
                    and not any(value in screen(current_rows()) for value in absent),
                timeout=5), (label, screen(current_rows()))
            h.resize_and_wait(process, fd, output, rows=ROWS, columns=columns + 1,
                needle=status, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h")
            frame = h.resize_and_wait(process, fd, output, rows=ROWS, columns=columns,
                needle=status, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h")
            rows = h.screen_rows(frame)
            check_rows(label, rows, status, required, absent)
            print("STUDIO_CAPTURE=" + json.dumps({
                "suite": SUITE, "name": f"{columns}cols-{label}",
                "rows": ROWS, "columns": columns, "provenance": "fixture PTY",
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": b"\n".join(rows.get(row, b"") for row in range(1, ROWS + 1)).decode(errors="replace"),
            }), flush=True)

        try:
            chat.open_atomic_chat(process, fd, output)
            h.resize_and_wait(process, fd, output, rows=ROWS, columns=columns,
                needle=b"chat", controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h")
            h.send_and_wait(process, fd, output, USER_BODY.encode(), h.composer_showing(USER_BODY.encode()))
            os.write(fd, b"\r")
            observe("provided-thinking", b"THINKING", (THINKING.encode(),),
                    (b"model content ended", b"model response ended"))
            gates["native-open"].set()
            observe("native-open", b"native running", (b"Agent", b"provider elapsed 30s"))
            gates["retry"].set()
            observe("retry-reported", b"native running",
                    (b"provider retry 1/3", b"provider elapsed 30s", b"status 529"),
                    (b"notice cleared", b"model response ended"))
            gates["heartbeat-decreased"].set()
            observe("heartbeat-decreased", b"native running",
                    (b"provider retry 1/3", b"provider elapsed 3s"), (b"provider elapsed 30s",))
            gates["clear"].set()
            observe("notice-cleared-turn-open", b"native running",
                    (b"provider retry notice cleared", b"provider elapsed 3s"),
                    (b"provider retry 1/3", b"model content ended", b"model response ended"))
            gates["retry-again"].set()
            observe("second-retry", b"native running",
                    (b"provider retry 2/3", b"provider elapsed 3s"), (b"notice cleared",))
            gates["native-ended"].set()
            observe("native-ended-last-note", b"THINKING",
                    (b"last observed provider retry 2/3", b"native result received", b"error flag not reported"),
                    (b"notice cleared", b"native running", b"model response ended"))
            gates["content-ended"].set()
            observe("content-ended-turn-open", b"model content ended",
                    (b"last observed provider retry 2/3",), (b"model response ended", b"notice cleared"))
            gates["response-ended"].set()
            observe("response-ended-turn-open", b"model response ended",
                    (b"last observed provider retry 2/3",), (b"notice cleared",))
            with fixture.lock:
                assert len(fixture.received) == 1 and fixture.received[0]["message"] == USER_BODY, fixture.received
            fixture.release.set()
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: progress_row(current_rows()) is None and ANSWER.encode() in screen(current_rows()),
                timeout=5), "terminal event did not settle the controlled turn"
            h.send_and_wait(process, fd, output, b"\x11", b"Info")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            for gate in gates.values():
                gate.set()
            fixture.release.set()
            fixture.release_interrupt.set()

    h.run_terminal_scenario(executable,
        description=f"Claude Agent retry notes preserve body and open turn at {columns} columns",
        interact=interact, http_fixtures=fixture.fixtures,
        refresh=0.2, terminal_rows=ROWS, terminal_cols=140)


if __name__ == "__main__":
    executable = str(Path(sys.argv[1]).resolve())
    identity = subprocess.run([executable, "--build-commit"], check=True,
                              capture_output=True, text=True)
    commit = identity.stdout.strip()
    assert (len(commit) == 40 and all(char in "0123456789abcdef" for char in commit)
            and identity.stdout == commit + "\n" and not identity.stderr), identity
    # The capture workflow compares this executable-owned identity with its
    # actual candidate checkout; the suite does not substitute a caller SHA.
    print("STUDIO_BINARY_COMMIT=" + commit, flush=True)
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(Path(executable).read_bytes()).hexdigest(), flush=True)
    for columns in (80, 140):
        run(executable, columns)
    print("TUI Claude Agent retry PTY: PASS")
