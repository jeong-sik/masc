"""An ordinary Enter waits for the preceding Keeper admission receipt."""

import os
import json
import sys
import threading

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

    priority_fixture = h.AtomicChatFixture()
    promoted: list[dict[str, object]] = []
    promotion_lock = threading.Lock()
    first_promotion_seen = threading.Event()
    second_promotion_seen = threading.Event()
    third_promotion_seen = threading.Event()
    release_first_promotion = threading.Event()

    def promote(body: bytes):
        request = json.loads(body)
        with promotion_lock:
            promoted.append(request)
            position = len(promoted)
        if position == 1:
            first_promotion_seen.set()
            if not release_first_promotion.wait(timeout=10):
                raise AssertionError("first run-next receipt was never released")
        elif position == 2:
            second_promotion_seen.set()
        elif position == 3:
            third_promotion_seen.set()
        return 200, {
            "request_id": request["request_id"],
            "prioritized": True,
            "signalled": False,
            "detail": "Queued message moved first",
        }

    priority_fixture.fixtures["/api/v1/keepers/turn/run-next"] = h.RequestHttpResponse(promote)

    def priority_interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            h.open_atomic_chat(process, master_fd, output)
            h.send_and_wait(process, master_fd, output, b"first", h.composer_showing(b"first"))
            os.write(master_fd, b"\r")
            h.wait_for_atomic_admissions(process, master_fd, output, priority_fixture, 1)
            command = b"/priority on"
            h.send_and_wait(process, master_fd, output, command, h.composer_showing(command))
            h.send_and_wait(process, master_fd, output, b"\r", b"User input auto-next priority: ON")
            h.send_and_wait(process, master_fd, output, b"second", h.composer_showing(b"second"))
            os.write(master_fd, b"\r")
            h.wait_for_atomic_admissions(process, master_fd, output, priority_fixture, 2)
            second = priority_fixture.submitted[1]
            if second.get("admission_intent", {}).get("kind") != "interactive":
                raise AssertionError(f"second message did not use the observed control token: {second!r}")
            if not h.wait_for_fixture_event(process, master_fd, output, first_promotion_seen, timeout=5):
                raise AssertionError("/priority on did not promote the token-bearing message")
            h.send_and_wait(process, master_fd, output, b"third", h.composer_showing(b"third"))
            h.read_available(master_fd, output)
            third_start = len(output)
            os.write(master_fd, b"\r")
            h.wait_for_atomic_admissions(process, master_fd, output, priority_fixture, 3)
            h.wait_for_output(
                process, master_fd, output, b"3 messages in the keeper's queue",
                start=third_start, timeout=5,
            )
            third = priority_fixture.submitted[2]
            if third.get("admission_intent", {}).get("kind") != "interactive":
                raise AssertionError(f"third message did not use the observed control token: {third!r}")
            h.send_and_wait(process, master_fd, output, b"fourth", h.composer_showing(b"fourth"))
            h.read_available(master_fd, output)
            fourth_start = len(output)
            os.write(master_fd, b"\r")
            h.wait_for_atomic_admissions(process, master_fd, output, priority_fixture, 4)
            h.wait_for_output(
                process, master_fd, output, b"4 messages in the keeper's queue",
                start=fourth_start, timeout=5,
            )
            fourth = priority_fixture.submitted[3]
            if fourth.get("admission_intent", {}).get("kind") != "interactive":
                raise AssertionError(f"fourth message did not use the observed control token: {fourth!r}")
            with promotion_lock:
                before_release = list(promoted)
            if len(before_release) != 1:
                raise AssertionError(f"same-Keeper run-next requests ran in parallel: {before_release!r}")
            release_first_promotion.set()
            if not h.wait_for_fixture_event(process, master_fd, output, second_promotion_seen, timeout=5):
                raise AssertionError("third message lost its run-next request")
            if not h.wait_for_fixture_event(process, master_fd, output, third_promotion_seen, timeout=5):
                raise AssertionError("fourth message lost its run-next request")
            with promotion_lock:
                completed_promotions = list(promoted)
            if [item.get("request_id") for item in completed_promotions] != [
                second["request_id"], third["request_id"], fourth["request_id"]
            ]:
                raise AssertionError(f"priority targeted another message: {completed_promotions!r}")
            if any(item.get("interrupt_token", "missing") is not None for item in completed_promotions):
                raise AssertionError(f"automatic priority tried to interrupt a turn: {completed_promotions!r}")
            if priority_fixture.release.is_set():
                raise AssertionError("automatic priority waited for model completion")
            priority_fixture.release.set()
            h.wait_for_output(process, master_fd, output, b"reply-fourth", start=0, timeout=10)
            h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            release_first_promotion.set()
            priority_fixture.release_interrupt.set()
            priority_fixture.release.set()

    h.run_terminal_scenario(
        executable,
        description="Auto-next promotes every token-bearing Enter in a burst",
        interact=priority_interact,
        http_fixtures=priority_fixture.fixtures,
        refresh=0.2,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI FIFO admission: PASS")
