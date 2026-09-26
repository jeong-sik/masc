"""An ordinary Enter waits for the preceding Keeper admission receipt."""

import os
import sys

import test_tui_keyboard_input as h


SOURCE_MODULES = ("bin/masc_tui.ml",)


def run(executable: str) -> None:
    fixture = h.AtomicChatFixture(no_control_token=True, hold_first_acceptance=True)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            h.open_atomic_chat(process, master_fd, output)
            h.send_and_wait(process, master_fd, output, b"first", h.composer_showing(b"first"))
            os.write(master_fd, b"\r")
            if not fixture.first_post_received.wait(timeout=5):
                raise AssertionError("first POST never reached the HTTP fixture")
            h.send_and_wait(process, master_fd, output, b"second", h.composer_showing(b"second"))
            h.send_and_wait(process, master_fd, output, b"\r", b"Queue (1 waiting")
            # The /queue command first renders the local queue before its
            # server read. A parallel second POST removes this line locally,
            # even if its HTTP fiber has not yet reached the fixture.
            h.send_and_wait(process, master_fd, output, b"/queue", h.composer_showing(b"/queue"))
            h.read_available(master_fd, output)
            queue_start = len(output)
            local_frame = h.send_and_wait(
                process, master_fd, output, b"\r", b"Local unsent messages: 1"
            )
            local_snapshot = h.frame_containing(
                local_frame, b"Local unsent messages: 1"
            )
            if b"Reading server queue" not in h.screen_text(local_snapshot):
                raise AssertionError("local queue count was not from this /queue request")
            # The later snapshot proves the read-only server round trip also
            # completed while the first acceptance remains withheld.
            h.wait_for_output(
                process, master_fd, output, b"Queue snapshot", start=queue_start,
                timeout=3.0,
            )
            with fixture.lock:
                before_receipt = [item["message"] for item in fixture.received]
            if before_receipt != ["first"]:
                raise AssertionError(f"later Enter reached the server before first acceptance: {before_receipt!r}")
            fixture.release_first_acceptance.set()
            h.wait_for_atomic_admissions(process, master_fd, output, fixture, 2)
            with fixture.lock:
                received = [item["message"] for item in fixture.received]
            if received != ["first", "second"]:
                raise AssertionError(f"server admission order changed: {received!r}")
            if len({item["request_id"] for item in fixture.submitted}) != 2:
                raise AssertionError("distinct Enter sends lost their request identities")
            if fixture.release.is_set():
                raise AssertionError("second admission waited for model completion")
            fixture.release.set()
            h.wait_for_output(process, master_fd, output, b"reply-second", start=0, timeout=10)
            h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            fixture.release_first_acceptance.set()
            fixture.release_interrupt.set()
            fixture.release.set()

    h.run_terminal_scenario(
        executable,
        description="No-token Enter sends reach durable admission in order",
        interact=interact,
        http_fixtures=fixture.fixtures,
        refresh=0.2,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI FIFO admission: PASS")
