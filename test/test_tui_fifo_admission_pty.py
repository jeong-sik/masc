"""An ordinary Enter waits for the preceding Keeper admission receipt."""

import json
import os
import sys
import threading

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "test/tui_keyboard_chat.py",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_observer.py",
    "test/tui_keyboard_tools.py",
)


def run(executable: str) -> None:
    fixture = _keyboard_chat.AtomicChatFixture(no_control_token=True, hold_first_acceptance=True)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            _keyboard_chat.open_atomic_chat(process, master_fd, output)
            _keyboard_harness.send_and_wait(process, master_fd, output, b"first", _keyboard_harness.composer_showing(b"first"))
            os.write(master_fd, b"\r")
            if not _keyboard_harness.wait_for_fixture_event(process, master_fd, output, fixture.first_post_received, timeout=5):
                raise AssertionError("first POST never reached the HTTP fixture")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"second", _keyboard_harness.composer_showing(b"second"))
            _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", "내 메시지 2건 대기".encode())
            # The /queue command first renders the local queue before its
            # server read. A parallel second POST removes this line locally,
            # even if its HTTP fiber has not yet reached the fixture.
            _keyboard_harness.send_and_wait(process, master_fd, output, b"/queue", _keyboard_harness.composer_showing(b"/queue"))
            _keyboard_harness.read_available(master_fd, output)
            queue_start = len(output)
            local_frame = _keyboard_harness.send_and_wait(
                process, master_fd, output, b"\r", b"Local unsent messages: 1"
            )
            local_snapshot = _keyboard_harness.frame_containing(
                local_frame, b"Local unsent messages: 1"
            )
            if b"Reading server queue" not in _keyboard_harness.screen_text(local_snapshot):
                raise AssertionError("local queue count was not from this /queue request")
            # The later snapshot proves the read-only server round trip also
            # completed while the first acceptance remains withheld.
            _keyboard_harness.wait_for_output(
                process, master_fd, output, b"Queue snapshot", start=queue_start,
                timeout=3.0,
            )
            with fixture.lock:
                before_receipt = [item["message"] for item in fixture.received]
            if before_receipt != ["first"]:
                raise AssertionError(f"later Enter reached the server before first acceptance: {before_receipt!r}")
            fixture.release_first_acceptance.set()
            _keyboard_chat.wait_for_atomic_admissions(process, master_fd, output, fixture, 2)
            with fixture.lock:
                received = [item["message"] for item in fixture.received]
            if received != ["first", "second"]:
                raise AssertionError(f"server admission order changed: {received!r}")
            if len({item["request_id"] for item in fixture.submitted}) != 2:
                raise AssertionError("distinct Enter sends lost their request identities")
            if fixture.release.is_set():
                raise AssertionError("second admission waited for model completion")
            fixture.release.set()
            _keyboard_harness.wait_for_output(process, master_fd, output, b"reply-second", start=0, timeout=10)
            _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            fixture.release_first_acceptance.set()
            fixture.release_interrupt.set()
            fixture.release.set()

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="No-token Enter sends reach durable admission in order",
        interact=interact,
        http_fixtures=fixture.fixtures,
        refresh=0.2,
    )

    priority_fixture = _keyboard_chat.AtomicChatFixture()
    replay_lock = threading.Lock()
    accepted_streams: dict[str, _keyboard_harness.StreamingHttpResponse] = {}
    replayed_acceptance = threading.Event()

    def priority_stream(body: bytes):
        request = json.loads(body)
        if request["message"] != "second":
            return priority_fixture.stream(body)
        request_id = request["request_id"]
        with replay_lock:
            original = accepted_streams.get(request_id)
            if original is None:
                # Durable admission succeeds, but the client receives no
                # status/acceptance. Its idempotent reconnect must reuse this
                # operation rather than inventing another queued message.
                accepted_streams[request_id] = priority_fixture.stream(body)
                return _keyboard_harness.DroppedHttpResponse()
        with priority_fixture.lock:
            priority_fixture.received.append(request)

        def replay_chunks():
            chunks = iter(original.chunks())
            acceptance = json.loads(next(chunks).removeprefix(b"data: ").strip())
            receipt = acceptance["value"]["interactive"]
            receipt.update(outcome="replayed", signalled=False, resumed=False)
            replayed_acceptance.set()
            yield f"data: {json.dumps(acceptance)}\n\n".encode()
            yield from chunks

        return _keyboard_harness.StreamingHttpResponse(replay_chunks)

    priority_fixture.fixtures["/api/v1/keepers/chat/stream"] = _keyboard_harness.RequestHttpResponse(priority_stream)
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

    priority_fixture.fixtures["/api/v1/keepers/turn/run-next"] = _keyboard_harness.RequestHttpResponse(promote)

    def priority_interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            _keyboard_chat.open_atomic_chat(process, master_fd, output)
            _keyboard_harness.send_and_wait(process, master_fd, output, b"first", _keyboard_harness.composer_showing(b"first"))
            os.write(master_fd, b"\r")
            _keyboard_chat.wait_for_atomic_admissions(process, master_fd, output, priority_fixture, 1)
            command = b"/priority on"
            _keyboard_harness.send_and_wait(process, master_fd, output, command, _keyboard_harness.composer_showing(command))
            _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"User input auto-next priority: ON")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"second", _keyboard_harness.composer_showing(b"second"))
            os.write(master_fd, b"\r")
            _keyboard_chat.wait_for_atomic_admissions(process, master_fd, output, priority_fixture, 2)
            second = priority_fixture.submitted[1]
            if second.get("admission_intent", {}).get("kind") != "interactive":
                raise AssertionError(f"second message did not use the observed control token: {second!r}")
            if not _keyboard_harness.wait_for_fixture_event(process, master_fd, output, first_promotion_seen, timeout=5):
                raise AssertionError("/priority on did not promote the token-bearing message")
            if not replayed_acceptance.is_set():
                raise AssertionError("priority succeeded without exercising the lost acceptance reconnect")
            with priority_fixture.lock:
                retries = [item for item in priority_fixture.received
                           if item["request_id"] == second["request_id"]]
                admissions = [item for item in priority_fixture.submitted
                              if item["request_id"] == second["request_id"]]
            if len(retries) < 2 or len(admissions) != 1:
                raise AssertionError("reconnect did not preserve one durable request identity")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"third", _keyboard_harness.composer_showing(b"third"))
            _keyboard_harness.read_available(master_fd, output)
            third_start = len(output)
            os.write(master_fd, b"\r")
            _keyboard_chat.wait_for_atomic_admissions(process, master_fd, output, priority_fixture, 3)
            _keyboard_chat.wait_for_output(
                process, master_fd, output, "내 메시지 3건 대기".encode(),
                start=third_start, timeout=5,
            )
            third = priority_fixture.submitted[2]
            if third.get("admission_intent", {}).get("kind") != "interactive":
                raise AssertionError(f"third message did not use the observed control token: {third!r}")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"fourth", _keyboard_harness.composer_showing(b"fourth"))
            _keyboard_harness.read_available(master_fd, output)
            fourth_start = len(output)
            os.write(master_fd, b"\r")
            _keyboard_chat.wait_for_atomic_admissions(process, master_fd, output, priority_fixture, 4)
            _keyboard_chat.wait_for_output(
                process, master_fd, output, "내 메시지 4건 대기".encode(),
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
            if not _keyboard_harness.wait_for_fixture_event(process, master_fd, output, second_promotion_seen, timeout=5):
                raise AssertionError("third message lost its run-next request")
            if not _keyboard_harness.wait_for_fixture_event(process, master_fd, output, third_promotion_seen, timeout=5):
                raise AssertionError("fourth message lost its run-next request")
            with promotion_lock:
                completed_promotions = list(promoted)
            if [item.get("request_id") for item in completed_promotions] != [
                second["request_id"], third["request_id"], fourth["request_id"]
            ]:
                raise AssertionError(f"priority targeted another message: {completed_promotions!r}")
            if [item.get("priority_predecessors") for item in completed_promotions] != [
                [], [second["request_id"]],
                [second["request_id"], third["request_id"]],
            ]:
                raise AssertionError(
                    f"automatic priority lost the accepted FIFO predecessors: {completed_promotions!r}"
                )
            if any(item.get("interrupt_token", "missing") is not None for item in completed_promotions):
                raise AssertionError(f"automatic priority tried to interrupt a turn: {completed_promotions!r}")
            if priority_fixture.release.is_set():
                raise AssertionError("automatic priority waited for model completion")
            priority_fixture.release.set()
            _keyboard_harness.wait_for_output(process, master_fd, output, b"reply-fourth", start=0, timeout=10)
            _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            release_first_promotion.set()
            priority_fixture.release_interrupt.set()
            priority_fixture.release.set()

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Auto-next keeps a reconnected admission ahead of later Enter sends",
        interact=priority_interact,
        http_fixtures=priority_fixture.fixtures,
        refresh=0.2,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI FIFO admission: PASS")
