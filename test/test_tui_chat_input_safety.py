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
    # The composer decides whether a letter reaches the row at all: "i"
    # focuses only when the row would accept input, and every scenario here
    # types into it. A change there took this suite red on main while no pull
    # request ran it, because the list stopped at the files above.
    "bin/masc_tui_composer.ml",
    # Draws the composer row and the two hints the scenarios wait for --
    # "(i to write)" before focus and the capture key after it.
    "bin/masc_tui_render_prim.ml",
    # Draws the chat surface the scenarios open, including the breadcrumb
    # open_chat waits for before it types anything.
    "bin/masc_tui_render_chat.ml",
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
    """Staged media rides with the line it was staged for, and survives /queue edit.

    Enter admits each line to the server while a turn is held, so the queue
    that used to live in this TUI is the server's. What the scenario proves
    is the wire: the attachment and reference staged before "queued-one" go
    out with it and only it, the next reference goes out with "draft", and
    editing the queued text on the server keeps the media it was sent with.
    """
    fixture = h.AtomicChatFixture()
    requests: h.HttpRequests = []
    reference = "https://example.invalid/queued.png"
    draft_reference = "file-draft-image"

    def interact(
        process: subprocess.Popen[bytes],
        fd: int,
        _slave: int,
        output: bytearray,
        base: str,
    ) -> None:
        try:
            h.open_atomic_chat(process, fd, output)
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
            os.write(fd, b"\r")
            h.wait_for_atomic_admissions(process, fd, output, fixture, 1)
            h.send_and_wait(
                process,
                fd,
                output,
                f"/ref {draft_reference}\r".encode(),
                b"reference(s)",
            )
            h.send_and_wait(process, fd, output, b"draft", h.composer_showing(b"draft"))
            os.write(fd, b"\r")
            h.wait_for_atomic_admissions(process, fd, output, fixture, 2)
            queued, draft = fixture.submitted
            assert [queued["message"], draft["message"]] == ["queued-one", "draft"], (
                fixture.submitted
            )
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
            # Editing the queued text on the server keeps the attachment and
            # the reference that were sent with it; only the text changes.
            first_id = queued["request_id"]
            command = f"/queue edit {first_id} queued-one-fixed".encode()
            h.send_and_wait(process, fd, output, command, h.composer_showing(command))
            os.write(fd, b"\r")
            if not h.wait_for_fixture_event(
                process, fd, output, fixture.edited, timeout=5
            ):
                raise AssertionError("queue edit never reached the server")
            edited = fixture.operations[0]["input"]
            assert edited["message"] == "queued-one-fixed", edited
            assert [item["name"] for item in edited["attachments"]] == [
                image_path.name
            ], edited
            assert {"type": "image", "url": reference} in edited["user_blocks"], edited
            assert {"type": "text", "text": "queued-one-fixed"} in edited["user_blocks"], (
                edited
            )
            assert fixture.operations[0]["operation_id"] == first_id, fixture.operations
        finally:
            fixture.release_interrupt.set()
            fixture.release.set()
            os.killpg(process.pid, signal.SIGTERM)

    h.run_terminal_scenario(
        binary,
        description="staged media rides with its line and survives a queue edit",
        interact=interact,
        confirm_exit=b"",
        http_fixtures=fixture.fixtures,
        http_requests=requests,
        prepare_workspace=h.seed_image_workspace,
    )


def quiet_leave_belongs_to_the_chat_surface(binary: str) -> None:
    """Ctrl-Q leaves the chat pane, and only from the chat pane.

    The composer row is drawn on every surface and hands its keys to the same
    handler the chat pane uses. The quiet leave changes the view, so without a
    surface guard a Ctrl-Q typed on Overview moved the reader into the Keeper
    detail the chat would have returned to.
    """

    def interact(
        process: subprocess.Popen[bytes],
        fd: int,
        _slave: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The row takes a target before it takes letters, so the scenario
        # picks one the way the keyboard suite does: the Keepers list, a row
        # selected, and only then the focus key. Pressing i on a surface whose
        # roster has not arrived focuses a row with nothing to send to, and
        # the letters below would land nowhere.
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        h.send_and_wait(process, fd, output, b"zqx", b"zqx")
        os.write(fd, b"\x11")
        h.drain_until_quiet(process, fd, output)
        frame = h.screen_text(bytes(output))
        if b"MASC Keepers" not in frame:
            raise AssertionError(
                f"Ctrl-Q on the composer row left the surface: {frame[-600:]!r}"
            )
        if b"zqx" not in frame:
            raise AssertionError(
                f"Ctrl-Q emptied the row it was typed into: {frame[-600:]!r}"
            )
        os.write(fd, b"\x15")
        h.drain_until_quiet(process, fd, output)
        # Release the row before quitting: a focused composer takes "q" as a
        # letter. The harness supplies the second q that confirms the exit.
        os.write(fd, b"\x1b")
        h.drain_until_quiet(process, fd, output)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="the quiet leave belongs to the chat surface",
        interact=interact,
        http_fixtures=h.overview_event_http_fixtures(),
    )


if __name__ == "__main__":
    executable = str(Path(sys.argv[1]).resolve())
    approval_typing(executable, "approve")
    approval_typing(executable, "deny")
    queued_attachments(executable)
    quiet_leave_belongs_to_the_chat_surface(executable)
