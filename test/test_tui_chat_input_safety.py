"""Real composer input cannot approve tools or discard queued image payloads."""

from __future__ import annotations

from collections.abc import Iterator
import base64
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_command.ml",
    "bin/masc_tui_command.mli",
    "bin/masc_tui_keeper_chat_transcript.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_footer.ml",
)
CHAT = "/api/v1/keepers/chat/stream"
APPROVAL = "/api/v1/keepers/tool-approval"


def open_chat(process: subprocess.Popen[bytes], fd: int, output: bytearray) -> None:
    h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"c", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")


def approval_typing(binary: str, decision: str) -> None:
    requests: h.HttpRequests = []
    show_approval = threading.Event()
    release = threading.Event()

    def respond(body: bytes) -> h.StreamingHttpResponse:
        normal = h.keeper_chat_succeeded_response(body)
        blocks = [block for block in normal.body.split(b"\n\n") if block]
        start = next(
            i
            for i, block in enumerate(blocks)
            if json.loads(block.removeprefix(b"data: "))["type"] == "RUN_STARTED"
        )
        run = json.loads(blocks[start].removeprefix(b"data: "))
        event = {
            "type": "CUSTOM",
            "threadId": run["threadId"],
            "runId": run["runId"],
            "timestamp": 1.0,
            "name": "KEEPER_TOOL_APPROVAL_REQUESTED",
            "value": {
                "tool_call_id": "typing-call",
                "tool_call_name": "Edit",
                "args": "{}",
                "question": "Apply isolated edit?",
                "because": "Fixture approval",
            },
        }

        def chunks() -> Iterator[bytes]:
            yield b"\n\n".join(blocks[: start + 1]) + b"\n\n"
            if show_approval.wait(timeout=30):
                yield b"data: " + json.dumps(event).encode() + b"\n\n"
                release.wait(timeout=30)

        return h.StreamingHttpResponse(chunks)

    def interact(
        process: subprocess.Popen[bytes],
        fd: int,
        _slave: int,
        output: bytearray,
        _base: str,
    ) -> None:
        try:
            open_chat(process, fd, output)
            h.send_and_wait(process, fd, output, b"first", h.composer_showing(b"first"))
            h.send_and_wait(process, fd, output, b"\r", b"IN PROGRESS")
            # Approval arrives while the operator is already writing NEXT.
            h.send_and_wait(process, fd, output, b"ma", h.composer_showing(b"ma"))
            before = len(output)
            show_approval.set()
            h.wait_for_output(process, fd, output, b"/approve", start=before, timeout=5)
            h.send_and_wait(process, fd, output, b"yYnN", h.composer_showing(b"mayYnN"))
            assert not [body for path, body in requests if path == APPROVAL], requests
            # An empty draft must also admit y/n as the first character.
            h.send_and_wait(process, fd, output, b"\x15", b"> ")
            h.send_and_wait(process, fd, output, b"yYnN", h.composer_showing(b"yYnN"))
            assert not [body for path, body in requests if path == APPROVAL], requests
            h.send_and_wait(process, fd, output, b"\x15", b"> ")
            command = ("/" + decision).encode()
            h.send_and_wait(process, fd, output, command, h.composer_showing(command))
            assert not [body for path, body in requests if path == APPROVAL], requests
            os.write(fd, b"\r")
            body = h.wait_for_http_request(process, fd, output, requests, path=APPROVAL)
            assert json.loads(body) == {
                "name": "alpha",
                "tool_call_id": "typing-call",
                "decision": decision,
            }, body
            assert len([body for path, body in requests if path == APPROVAL]) == 1
        finally:
            show_approval.set()
            release.set()
            os.killpg(process.pid, signal.SIGTERM)

    h.run_terminal_scenario(
        binary,
        description=f"approval typing requires explicit /{decision}",
        interact=interact,
        confirm_exit=b"",
        http_requests=requests,
        http_fixtures={
            CHAT: h.RequestHttpResponse(respond),
            APPROVAL: (200, {"settled": True, "remembered": False}),
        },
    )


def queued_attachments(binary: str) -> None:
    fixtures, gate = h.chat_queue_http_fixtures()
    requests: h.HttpRequests = []
    reference = "https://example.invalid/queued.png"
    draft_reference = "file-draft-image"

    def prepare(base: str) -> None:
        h.seed_uncoalesced_queue(base)
        h.seed_image_workspace(base)

    def interact(
        process: subprocess.Popen[bytes],
        fd: int,
        _slave: int,
        output: bytearray,
        base: str,
    ) -> None:
        try:
            open_chat(process, fd, output)
            h.send_and_wait(process, fd, output, b"first", h.composer_showing(b"first"))
            h.send_and_wait(process, fd, output, b"\r", b"IN PROGRESS")
            image_path = Path(base, h.IMAGE_NAME)
            h.send_and_wait(
                process, fd, output, f"/attach {image_path}\r".encode(), b"attached "
            )
            h.send_and_wait(
                process, fd, output, f"/ref {reference}\r".encode(), b"reference(s)"
            )
            h.send_and_wait(
                process, fd, output, b"queued-one", h.composer_showing(b"queued-one")
            )
            h.send_and_wait(process, fd, output, b"\r", b"NEXT 1")
            h.send_and_wait(
                process,
                fd,
                output,
                f"/ref {draft_reference}\r".encode(),
                b"reference(s)",
            )
            h.send_and_wait(process, fd, output, b"draft", h.composer_showing(b"draft"))
            # Returning past newest restores this draft's own reference.
            h.send_and_wait(
                process, fd, output, b"\x1b[A", h.composer_showing(b"queued-one")
            )
            h.send_and_wait(
                process, fd, output, b"\x1b[B", h.composer_showing(b"draft")
            )
            h.send_and_wait(process, fd, output, b"\r", b"NEXT 2")
            # Walking across two waiting lines restores each payload independently.
            h.send_and_wait(
                process, fd, output, b"\x1b[A", h.composer_showing(b"draft")
            )
            h.send_and_wait(
                process, fd, output, b"\x1b[A", h.composer_showing(b"queued-one")
            )
            h.send_and_wait(
                process, fd, output, b"-fixed", h.composer_showing(b"queued-one-fixed")
            )
            h.send_and_wait(process, fd, output, b"\r", b"Enter:queue(2)")
            before = len(output)
            gate.release.set()
            h.wait_for_output(
                process, fd, output, b"Enter:send", start=before, timeout=10
            )
            payloads = [json.loads(body) for path, body in requests if path == CHAT]
            assert [p["message"] for p in payloads] == [
                "first",
                "queued-one-fixed",
                "draft",
            ], payloads
            queued, draft = payloads[1:]
            assert len(queued["attachments"]) == 1, queued
            attachment = queued["attachments"][0]
            assert attachment["name"] == image_path.name, attachment
            assert base64.b64decode(attachment["data"]) == image_path.read_bytes()
            assert queued["user_blocks"][0]["attachment_id"] == attachment["id"]
            assert {"type": "image", "url": reference} in queued["user_blocks"], queued
            assert "attachments" not in draft, draft
            assert draft["user_blocks"] == [
                {"type": "image", "file_id": draft_reference},
                {"type": "text", "text": "draft"},
            ], draft
            # Cancelling a recall ends the saved draft, including its reference.
            h.send_and_wait(
                process, fd, output, b"/ref file-private\r", b"reference(s)"
            )
            h.send_and_wait(
                process, fd, output, b"private", h.composer_showing(b"private")
            )
            h.send_and_wait(
                process, fd, output, b"\x1b[A", h.composer_showing(b"draft")
            )
            h.send_and_wait(process, fd, output, b"\x15", b"> ")
            h.send_and_wait(
                process,
                fd,
                output,
                b"\x1b[Bcancel-check",
                h.composer_showing(b"cancel-check"),
            )
            h.send_and_wait(process, fd, output, b"\r", b"reply-cancel-check")
            cancelled = [json.loads(body) for path, body in requests if path == CHAT][
                -1
            ]
            assert (
                cancelled["message"] == "cancel-check"
                and "user_blocks" not in cancelled
            ), cancelled
            # The saved draft also belongs to alpha, never the next Keeper.
            h.send_and_wait(
                process, fd, output, b"/ref file-private\r", b"reference(s)"
            )
            h.send_and_wait(
                process, fd, output, b"private", h.composer_showing(b"private")
            )
            h.send_and_wait(
                process, fd, output, b"\x1b[A", h.composer_showing(b"cancel-check")
            )
            h.send_and_wait(
                process, fd, output, b"\x07", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat"
            )
            h.send_and_wait(
                process,
                fd,
                output,
                b"\x1b[Bbeta-check",
                h.composer_showing(b"beta-check"),
            )
            h.send_and_wait(process, fd, output, b"\r", b"reply-beta-check")
            switched = [json.loads(body) for path, body in requests if path == CHAT][-1]
            assert switched["name"] == "beta" and switched["message"] == "beta-check", (
                switched
            )
            assert "user_blocks" not in switched and "attachments" not in switched, (
                switched
            )
        finally:
            gate.release.set()
            os.killpg(process.pid, signal.SIGTERM)

    h.run_terminal_scenario(
        binary,
        description="queued recall retains attachments and restores draft references",
        interact=interact,
        confirm_exit=b"",
        http_fixtures=fixtures,
        http_requests=requests,
        prepare_workspace=prepare,
    )


if __name__ == "__main__":
    executable = str(Path(sys.argv[1]).resolve())
    approval_typing(executable, "approve")
    approval_typing(executable, "deny")
    queued_attachments(executable)
