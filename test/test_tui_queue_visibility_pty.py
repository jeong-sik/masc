"""Pending input stays visible as ownership moves from the TUI to the server."""
import argparse
import os
from pathlib import Path
import threading

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render_chat.ml",
)


def run(executable: str, evidence_dir: Path | None = None) -> None:
    fixture = h.AtomicChatFixture(hold_first_acceptance=True)
    second_post_received = threading.Event()
    release_second_acceptance = threading.Event()

    def stream(body):
        if fixture.first_post_received.is_set():
            second_post_received.set()
            if not release_second_acceptance.wait(timeout=10):
                raise AssertionError("second admission receipt was never released")
        return fixture.stream(body)

    fixture.fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(stream)

    def current_screen(output):
        end = output.rfind(h.FRAME_END)
        if end < 0:
            raise AssertionError("no completed terminal frame to capture")
        raw = bytes(output[:end + len(h.FRAME_END)])
        return raw, h.screen_text(raw)

    def capture(output, name):
        raw, text = current_screen(output)
        if evidence_dir is not None:
            evidence_dir.mkdir(parents=True, exist_ok=True)
            (evidence_dir / f"{name}-120x40.ansi").write_bytes(raw)
            (evidence_dir / f"{name}-120x40.txt").write_bytes(text)
        return text

    def interact(process, fd, _slave_fd, output, _base_path):
        try:
            h.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, b"queued-one", h.composer_showing(b"queued-one"))
            os.write(fd, b"\r")
            if not h.wait_for_fixture_event(process, fd, output, fixture.first_post_received, timeout=5):
                raise AssertionError("first request did not reach the server")
            h.send_and_wait(process, fd, output, b"queued-two", h.composer_showing(b"queued-two"))
            h.send_and_wait(process, fd, output, b"\r", b"Queue (2 waiting")
            capture(output, "local-waiting")

            fixture.release_first_acceptance.set()
            if not h.wait_for_fixture_event(process, fd, output, second_post_received, timeout=5):
                raise AssertionError("the locally queued request was not dispatched")
            # Ownership changed without changing the count. A draft edit
            # forces a completed frame while the second POST is still held.
            h.send_and_wait(process, fd, output, b"admission-check", h.composer_showing(b"admission-check"))
            if b"Queue (2 waiting" not in capture(output, "awaiting-second-admission"):
                raise AssertionError("dispatch lost the waiting request before its receipt arrived")
            h.send_and_wait(process, fd, output, b"\x15", h.composer_showing(b""))

            start = len(output)
            release_second_acceptance.set()
            h.wait_for_atomic_admissions(process, fd, output, fixture, 2)
            h.wait_for_output(process, fd, output, b"2 messages in the keeper's queue", start=start, timeout=10)
            receipt_end = h.end_of_needle(output, b"2 messages in the keeper's queue", start)
            h.wait_for_output(process, fd, output, h.FRAME_END, start=receipt_end, timeout=5)
            h.drain_until_quiet(process, fd, output)
            screen = capture(output, "server-waiting")
            if b"Queue (2 waiting" not in screen:
                raise AssertionError(
                    "server accepted both messages but the queue summary lost pending input: "
                    + repr(screen)
                )

            # An unchanged queue row is retained without being emitted again.
            # The draft change after each scroll key provides an ordered frame
            # barrier; assertions use the reconstructed screen, not new bytes.
            h.send_and_wait(process, fd, output, b"\x1b[5~scroll-check", h.composer_showing(b"scroll-check"))
            if b"Queue (2 waiting" not in capture(output, "reading-back"):
                raise AssertionError("reading older rows hid the waiting queue")
            h.send_and_wait(process, fd, output, b"\x05\x15newest-check", h.composer_showing(b"newest-check"))
            if b"Queue (2 waiting" not in capture(output, "newest"):
                raise AssertionError("returning to newest hid the waiting queue")
            h.send_and_wait(process, fd, output, b"\x15", h.composer_showing(b""))
            start = len(output)
            fixture.release.set()
            replies = (b"reply-queued-one", b"reply-queued-two")
            for reply in replies:
                h.wait_for_output(process, fd, output, reply, start=start, timeout=10)
            reply_end = max(h.end_of_needle(output, reply, start) for reply in replies)
            h.wait_for_output(process, fd, output, h.FRAME_END, start=reply_end, timeout=5)
            # A reply delta may precede its terminal event. Wait until a
            # completed frame reflects both settled streams before asserting.
            settled = h.wait_for_fixture_state(
                process, fd, output,
                lambda: b"Queue (" not in current_screen(output)[1],
                timeout=5,
            )
            if b"Queue (" in capture(output, "settled") or not settled:
                raise AssertionError("settled requests are still reported as queued")
            h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            fixture.release_first_acceptance.set()
            release_second_acceptance.set()
            fixture.release_interrupt.set()
            fixture.release.set()

    h.run_terminal_scenario(
        executable,
        description="Queue remains visible across local and server admission",
        interact=interact,
        http_fixtures=fixture.fixtures,
        refresh=0.2,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    run(os.path.abspath(args.executable), args.evidence_dir)
    print("queue remains visible across admission: PASS")
