"""Switching recipients preserves complete drafts without leaking their media."""
import base64
import json
import os
from pathlib import Path
import sys
import threading

import test_tui_keyboard_input as h
import tui_keyboard_chat as chat
import tui_keyboard_harness as terminal




def recipient_bound_draft(executable, *, with_text):
    requests = []
    fixtures = h.overview_event_http_fixtures()
    fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(
        h.keeper_chat_succeeded_response
    )
    for name in ("alpha", "beta"):
        fixtures[f"/api/v1/keepers/{name}/chat/history"] = (200, [])

    def interact(process, fd, _slave, output, base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        image = Path(base, h.IMAGE_NAME)
        reference = "https://example.invalid/alpha-draft.png"
        h.send_and_wait(process, fd, output, f"/attach {image}\r".encode(), b"attached ")
        h.send_and_wait(process, fd, output, f"/ref {reference}\r".encode(), b"reference(s)")
        if with_text:
            h.send_and_wait(process, fd, output, b"alpha-draft", h.composer_showing(b"alpha-draft"))
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"beta-only\r", b"reply-beta-only")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        if with_text:
            h.wait_for_output(process, fd, output, h.composer_showing(b"alpha-draft"), start=0, timeout=10)
            message = "alpha-draft"
        else:
            # A media-only draft is retained even before text is composed.
            h.send_and_wait(process, fd, output, b"alpha-after-return", h.composer_showing(b"alpha-after-return"))
            message = "alpha-after-return"
        h.send_and_wait(process, fd, output, b"\r", f"reply-{message}".encode())
        sent = [json.loads(body) for path, body in requests if path == "/api/v1/keepers/chat/stream"]
        assert len(sent) == 2, sent
        beta, alpha = sent
        assert (beta["name"], beta["message"]) == ("beta", "beta-only"), beta
        assert not beta.get("attachments"), beta
        assert all(block["type"] == "text" for block in beta.get("user_blocks", [])), beta
        assert (alpha["name"], alpha["message"]) == ("alpha", message), alpha
        assert len(alpha["attachments"]) == 1, alpha
        attachment = alpha["attachments"][0]
        assert attachment["name"] == image.name, attachment
        assert base64.b64decode(attachment["data"]) == image.read_bytes(), attachment
        assert {"type": "image", "url": reference} in alpha["user_blocks"], alpha
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description=f"Keeper draft payload with_text={with_text}",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=h.seed_image_workspace,
    )


def queue_refusal_retains_payload(executable, *, steer):
    """A refused local enqueue can be retried with the exact staged payload."""
    fixture = chat.AtomicChatFixture(first_working=True, no_control_token=True)
    blocker_received = threading.Event()
    release_blocker = threading.Event()
    # This is the existing queue's capacity, not a new test-only product limit.
    # Authority: bin/masc_tui_keeper_chat_queue.ml [cap].
    queue_capacity = 32

    def stream(body):
        request = json.loads(body)
        if request["message"] == "admission-blocker":
            blocker_received.set()
            if not release_blocker.wait(timeout=30):
                raise AssertionError("local queue admission barrier was not released")
        return fixture.stream(body)

    fixture.fixtures["/api/v1/keepers/chat/stream"] = terminal.RequestHttpResponse(stream)

    def interact(process, fd, _slave, output, base):
        try:
            chat.open_atomic_chat(process, fd, output)
            terminal.send_and_wait(process, fd, output, b"working\r", b"reply-working")
            terminal.send_and_wait(process, fd, output, b"admission-blocker\r", terminal.composer_showing(b""))
            if not terminal.wait_for_fixture_event(process, fd, output, blocker_received, timeout=5):
                raise AssertionError("second POST did not reach its admission barrier")
            for index in range(queue_capacity):
                text = f"local-{index}".encode()
                terminal.send_and_wait(process, fd, output, text, terminal.composer_showing(text))
                terminal.send_and_wait(process, fd, output, b"\r", terminal.composer_showing(b""))

            image = Path(base, chat.IMAGE_NAME)
            reference = "https://example.invalid/refused-draft.png"
            terminal.send_and_wait(process, fd, output, f"/attach {image}\r".encode(), b"attached ")
            terminal.send_and_wait(process, fd, output, f"/ref {reference}\r".encode(), b"reference(s)")
            text = b"retained-payload"
            command = b"/steer " + text if steer else text
            terminal.send_and_wait(process, fd, output, command, terminal.composer_showing(command))
            terminal.send_and_wait(process, fd, output, b"\r", b"not queued and is still in the composer")
            if command not in terminal.screen_text(bytes(output)):
                raise AssertionError("queue refusal lost the authored composer text")

            # Ctrl-K cancels only the newest queued item. It must not clear a
            # separate refused draft. The outstanding POST still blocks dispatcterminal.
            terminal.send_and_wait(process, fd, output, b"\x0b", b"Cancelled queued message")
            if steer:
                # Retry as ordinary input without Ctrl-U, which intentionally
                # discards staged media. Backspace edits only the authored text.
                terminal.send_and_wait(process, fd, output, b"\x7f" * len(command) + text,
                                terminal.composer_showing(text))
            terminal.send_and_wait(process, fd, output, b"\r", terminal.composer_showing(b""))
            release_blocker.set()
            chat.wait_for_atomic_admissions(process, fd, output, fixture, queue_capacity + 2)
            with fixture.lock:
                sent = list(fixture.submitted)
            expected = ["working", "admission-blocker"] + [
                f"local-{index}" for index in range(queue_capacity - 1)
            ] + [text.decode()]
            assert [request["message"] for request in sent] == expected, sent
            retried = sent[-1]
            assert len(retried["attachments"]) == 1, retried
            attachment = retried["attachments"][0]
            assert attachment["name"] == image.name, attachment
            assert base64.b64decode(attachment["data"]) == image.read_bytes(), attachment
            assert {"type": "image", "url": reference} in retried["user_blocks"], retried

            terminal.send_and_wait(process, fd, output, b"after-retry\r", terminal.composer_showing(b""))
            chat.wait_for_atomic_admissions(process, fd, output, fixture, queue_capacity + 3)
            with fixture.lock:
                following = fixture.submitted[-1]
            assert following["message"] == "after-retry", following
            assert not following.get("attachments"), following
            assert all(block["type"] == "text" for block in following["user_blocks"]), following
            assert not fixture.release.is_set(), "retry incorrectly waited for model completion"
            fixture.release.set()
            terminal.escape_to_keeper_detail(process, fd, output, name=b"alpha")
            terminal.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            release_blocker.set()
            fixture.release_interrupt.set()
            fixture.release.set()

    terminal.run_terminal_scenario(
        executable, description=f"Queue refusal preserves complete draft steer={steer}",
        interact=interact, http_fixtures=fixture.fixtures,
        prepare_workspace=chat.seed_image_workspace, refresh=0.2,
    )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    recipient_bound_draft(executable, with_text=True)
    recipient_bound_draft(executable, with_text=False)
    queue_refusal_retains_payload(executable, steer=False)
    queue_refusal_retains_payload(executable, steer=True)
    print("Keeper draft payload PTY: PASS (4 scenarios)")
