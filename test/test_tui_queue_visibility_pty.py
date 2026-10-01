"""Pending input stays visible as ownership moves from the TUI to the server."""
import argparse
import json
import os
from pathlib import Path
import threading

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render_chat.ml",
)
CHAT = "Keepers ▸ alpha ▸ chat".encode()


class AcceptedQueueReconnectFixture:
    """Keep acceptance, transport loss, run start and terminal truth separate.

    The Atomic fixture's held Esc receipt keeps a later Enter local. Rechecking
    delivery alone is not expected to prevent an already accepted FIFO input
    from admitting another message.
    """

    def __init__(self):
        self.queue = h.AtomicChatFixture()
        self.fixtures = self.queue.fixtures
        self.fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(self.stream)
        self.disconnect = threading.Event()
        self.reconnect_requested = threading.Event()
        self.release_run_start = threading.Event()
        self.release_terminal = threading.Event()
        self.terminal_sent = threading.Event()
        self.attempts = []
        self.lock = threading.Lock()
        self.acceptance = None

    def stream(self, body):
        request = json.loads(body)
        with self.lock:
            attempt = len(self.attempts)
            self.attempts.append(request)
        if attempt == 0:
            response = self.queue.stream(body)

            def accepted_then_disconnect():
                chunks = response.chunks()
                try:
                    self.acceptance = next(chunks)
                    yield self.acceptance
                    if not self.disconnect.wait(timeout=30):
                        raise AssertionError("accepted stream was never disconnected")
                    # Closing this HTTP body without RUN_FINISHED makes its
                    # accepted operation unresolved, rather than failed.
                finally:
                    chunks.close()

            return h.StreamingHttpResponse(accepted_then_disconnect)
        if attempt == 1:
            original = self.attempts[0]
            if request["request_id"] != original["request_id"] or request["message"] != original["message"]:
                raise AssertionError("reconnect did not preserve the accepted request")
            self.reconnect_requested.set()
            if not self.release_run_start.wait(timeout=30):
                raise AssertionError("reconnect run-start gate was never released")
            response = h.keeper_chat_succeeded_response(body)
            blocks = [block for block in response.body.split(b"\n\n") if block]

            def run_then_terminal():
                if self.acceptance is None:
                    raise AssertionError("reconnect preceded the initial acceptance")
                # A re-subscription repeats acceptance, then exposes only
                # RUN_STARTED. No reply or terminal event can explain the
                # ensuing reduction in the pending count.
                yield self.acceptance + blocks[1] + b"\n\n"
                if not self.release_terminal.wait(timeout=30):
                    raise AssertionError("reconnect terminal gate was never released")
                self.terminal_sent.set()
                yield b"\n\n".join(blocks[2:]) + b"\n\n"

            return h.StreamingHttpResponse(run_then_terminal)
        if attempt != 2 or request["message"] != "held-local-next":
            raise AssertionError(f"unexpected additional chat POST: {request!r}")
        return self.queue.stream(body)

    def release_all(self):
        self.disconnect.set()
        self.release_run_start.set()
        self.release_terminal.set()
        self.queue.release_interrupt.set()
        self.queue.release.set()


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
    fixture.fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])

    def current_screen(output):
        end = output.rfind(h.FRAME_END)
        if end < 0:
            raise AssertionError("no completed terminal frame to capture")
        raw = bytes(output[:end + len(h.FRAME_END)])
        return raw, h.screen_text(raw)

    def capture(output, name, *, columns=120):
        raw, text = current_screen(output)
        if evidence_dir is not None:
            evidence_dir.mkdir(parents=True, exist_ok=True)
            (evidence_dir / f"{name}-{columns}x40.ansi").write_bytes(raw)
            (evidence_dir / f"{name}-{columns}x40.txt").write_bytes(text)
        return text

    def interact(process, fd, _slave_fd, output, _base_path):
        try:
            h.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, b"\x04\x04", CHAT)
            h.send_and_wait(process, fd, output, b"queued-one", h.composer_showing(b"queued-one"))
            os.write(fd, b"\r")
            if not h.wait_for_fixture_event(process, fd, output, fixture.first_post_received, timeout=5):
                raise AssertionError("first request did not reach the server")
            h.send_and_wait(process, fd, output, b"queued-two", h.composer_showing(b"queued-two"))
            h.send_and_wait(process, fd, output, b"\r", b"Queue (2 pending")
            if b"1 awaiting receipt" not in capture(output, "local-waiting"):
                raise AssertionError("pending POST was not distinguished from a queued receipt")

            fixture.release_first_acceptance.set()
            if not h.wait_for_fixture_event(process, fd, output, second_post_received, timeout=5):
                raise AssertionError("the locally queued request was not dispatched")
            # Ownership changed without changing the count. A draft edit
            # forces a completed frame while the second POST is still held.
            h.send_and_wait(process, fd, output, b"admission-check", h.composer_showing(b"admission-check"))
            if b"Queue (2 pending" not in capture(output, "awaiting-second-admission"):
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
            if b"Queue (2 pending" not in screen or b"2 queued at Keeper" not in screen:
                raise AssertionError(
                    "server accepted both messages but the queue summary lost pending input: "
                    + repr(screen)
                )

            # An unchanged queue row is retained without being emitted again.
            # The draft change after each scroll key provides an ordered frame
            # barrier; assertions use the reconstructed screen, not new bytes.
            h.send_and_wait(process, fd, output, b"\x1b[5~scroll-check", h.composer_showing(b"scroll-check"))
            if b"Queue (2 pending" not in capture(output, "reading-back"):
                raise AssertionError("reading older rows hid the waiting queue")
            h.send_and_wait(process, fd, output, b"\x05\x15newest-check", h.composer_showing(b"newest-check"))
            if b"Queue (2 pending" not in capture(output, "newest"):
                raise AssertionError("returning to newest hid the waiting queue")
            h.send_and_wait(process, fd, output, b"\x15", h.composer_showing(b""))

            # A held stop receipt keeps the next Enter local while both
            # existing requests remain accepted. This is an isolated HTTP
            # fixture; the test never sends control to a live Keeper.
            os.write(fd, b"\x1b")
            if not h.wait_for_fixture_event(process, fd, output, fixture.interrupted, timeout=5):
                raise AssertionError("the mixed queue's control receipt was not held")
            h.send_and_wait(process, fd, output, b"local-three", h.composer_showing(b"local-three"))
            h.send_and_wait(process, fd, output, b"\r", b"Queue (3 pending")
            h.resize_and_wait(process, fd, output, rows=40, columns=80,
                              needle=b"Queue (3 pending", controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h")
            screen = capture(output, "mixed-queue", columns=80)
            rows = h.screen_rows(current_screen(output)[0])
            queue_row = h.screen_row_of(rows, b"Queue (3 pending")
            accepted_row = h.screen_row_of(rows, b"2 queued at Keeper")
            local_row = h.screen_row_of(rows, b"Local NEXT")
            if not (0 < queue_row < accepted_row < local_row):
                raise AssertionError("mixed queue status/preview rows overlap: " + repr(screen))
            if b"Ctrl-T:queue" not in rows[queue_row] or b'"local-three"' not in rows[local_row]:
                raise AssertionError("80-column queue clipped its action or local preview: " + repr(screen))

            # Ctrl-Q leaves without issuing another interrupt. Queue identity
            # must survive a different screen and a different chat target.
            h.send_and_wait(process, fd, output, b"\x11", b"Info")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"beta")
            h.send_and_wait(process, fd, output, b"\r", "Keepers ▸ \x1b[1mbeta".encode())
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ beta ▸ chat".encode())
            if b"Queue (" in capture(output, "other-keeper", columns=80):
                raise AssertionError("alpha's pending queue leaked into beta's chat")
            h.send_and_wait(process, fd, output, b"\x11", b"Info")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", "Keepers ▸ \x1b[1malpha".encode())
            h.send_and_wait(process, fd, output, b"m", CHAT)
            restored = capture(output, "restored-pending", columns=80)
            for expected in (b"Queue (3 pending", b"2 queued at Keeper", b'Local NEXT: "local-three"', b"Ctrl-T:queue"):
                if expected not in restored:
                    raise AssertionError("returning to alpha lost pending queue information: " + repr(restored))
            if len(fixture.submitted) != 2:
                raise AssertionError("navigation dispatched local input before the stop receipt")
            fixture.release_interrupt.set()
            h.wait_for_atomic_admissions(process, fd, output, fixture, 3)
            start = len(output)
            fixture.release.set()
            replies = (b"reply-queued-one", b"reply-queued-two", b"reply-local-three")
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
            if b"Queue (" in capture(output, "settled", columns=80) or not settled:
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

    fixtures, gate = h.chat_reconcile_http_fixtures()
    requests = []
    h.run_terminal_scenario(
        executable,
        description="Pending queue distinguishes unknown admission during reconnect",
        interact=h.chat_reconcile_interaction(gate, requests),
        http_fixtures=fixtures,
        http_requests=requests,
    )

    reconnect = AcceptedQueueReconnectFixture()

    def accepted_reconnect_interaction(process, fd, _slave_fd, output, _base_path):
        def assert_local_pending(name, *, count, delivery=None):
            screen = capture(output, name)
            for expected in (f"Queue ({count} pending".encode(), b'Local NEXT: "held-local-next"'):
                if expected not in screen:
                    raise AssertionError("pending queue lost its local input: " + repr(screen))
            if delivery is not None and delivery not in screen:
                raise AssertionError("pending queue lost its delivery evidence: " + repr(screen))
            return screen

        try:
            h.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, b"\x04\x04", CHAT)
            h.send_and_wait(process, fd, output, b"accepted-before-cut", h.composer_showing(b"accepted-before-cut"))
            h.send_and_wait(process, fd, output, b"\r", b"1 queued at Keeper")
            accepted = capture(output, "accepted-before-disconnect")
            if b"Queue (1 pending" not in accepted or b"rechecking delivery" in accepted:
                raise AssertionError("initial queued receipt was not visible: " + repr(accepted))

            # This explicit control receipt, not reconnect state, is what
            # keeps the next Enter local across RUN_STARTED and terminal.
            os.write(fd, b"\x1b")
            if not h.wait_for_fixture_event(process, fd, output, reconnect.queue.interrupted, timeout=5):
                raise AssertionError("Esc control receipt was not held")
            h.send_and_wait(process, fd, output, b"held-local-next", h.composer_showing(b"held-local-next"))
            h.send_and_wait(process, fd, output, b"\r", b"Queue (2 pending")
            assert_local_pending("accepted-with-local-next", count=2, delivery=b"1 queued at Keeper")

            disconnected_from = len(output)
            reconnect.disconnect.set()
            if not h.wait_for_fixture_event(process, fd, output, reconnect.reconnect_requested, timeout=5):
                raise AssertionError("accepted operation was not re-subscribed")
            h.wait_for_output(process, fd, output, b"1 rechecking delivery", start=disconnected_from, timeout=5)
            rechecking_end = h.end_of_needle(output, b"1 rechecking delivery", disconnected_from)
            h.wait_for_output(process, fd, output, h.FRAME_END, start=rechecking_end, timeout=5)
            rechecking = assert_local_pending("accepted-rechecking", count=2, delivery=b"1 rechecking delivery")
            if b"queued at Keeper" in rechecking:
                raise AssertionError("the old queued receipt still appeared current after disconnect")
            if len(reconnect.attempts) != 2:
                raise AssertionError("local input was dispatched before the control receipt")

            running_from = len(output)
            reconnect.release_run_start.set()
            h.wait_for_output(process, fd, output, b"Queue (1 pending", start=running_from, timeout=5)
            running_end = h.end_of_needle(output, b"Queue (1 pending", running_from)
            h.wait_for_output(process, fd, output, h.FRAME_END, start=running_end, timeout=5)
            running = assert_local_pending("reconnected-running", count=1)
            if any(stale in running for stale in (b"queued at Keeper", b"rechecking delivery", b"awaiting receipt")):
                raise AssertionError("RUN_STARTED left the accepted request in pending delivery: " + repr(running))
            if reconnect.release_terminal.is_set() or reconnect.terminal_sent.is_set():
                raise AssertionError("terminal truth escaped before the RUN_STARTED frame assertion")
            if len(reconnect.attempts) != 2:
                raise AssertionError("RUN_STARTED dispatched the local input despite its held control receipt")

            terminal_from = len(output)
            reconnect.release_terminal.set()
            h.wait_for_output(process, fd, output, b"reply-accepted-before-cut", start=terminal_from, timeout=5)
            # Release the explicit Esc receipt only after the original reply.
            # The remaining local input must enter the server exactly once.
            local_reply_from = len(output)
            reconnect.queue.release.set()
            reconnect.queue.release_interrupt.set()
            h.wait_for_atomic_admissions(process, fd, output, reconnect.queue, 2)
            local_reply = b"reply-held-local-next"
            h.wait_for_output(process, fd, output, local_reply, start=local_reply_from, timeout=10)
            local_reply_end = h.end_of_needle(output, local_reply, local_reply_from)
            h.wait_for_output(process, fd, output, h.FRAME_END, start=local_reply_end, timeout=5)
            original, retry, later = reconnect.attempts
            if original["request_id"] != retry["request_id"] or later["request_id"] == original["request_id"]:
                raise AssertionError("reconnect or later input changed request identity")
            if [item["message"] for item in reconnect.attempts] != [
                "accepted-before-cut", "accepted-before-cut", "held-local-next"
            ]:
                raise AssertionError("accepted input or local NEXT was lost or duplicated")
            # A reply-bearing completed frame proves that pending input
            # drained. It does not prove the client consumed RUN_FINISHED:
            # working requests also correctly disappear from this count.
            drained = capture(output, "reconnect-pending-drained")
            if local_reply not in drained or b"Queue (" in drained:
                raise AssertionError("the local reply frame did not show a drained pending queue: " + repr(drained))
            h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            reconnect.release_all()

    h.run_terminal_scenario(
        executable,
        description="Accepted queue rechecks delivery and leaves pending at RUN_STARTED",
        interact=accepted_reconnect_interaction,
        http_fixtures=reconnect.fixtures,
        refresh=0.2,
    )


def run_compact(executable: str, evidence_dir: Path | None = None, *, fail_priority=False) -> None:
    fixture = h.AtomicChatFixture()
    priority_seen = threading.Event()
    priority_release = threading.Event()
    priority_calls = []

    def priority(body):
        request = json.loads(body)
        assert request.get("interrupt_token") is None, "priority must not interrupt existing work"
        priority_calls.append(request)
        priority_seen.set()
        assert priority_release.wait(timeout=15), "priority receipt fixture was not released"
        if fail_priority and len(priority_calls) == 2:
            return 503, {"error": "fixture priority refused"}
        return 200, {"request_id": request["request_id"], "prioritized": True,
                     "signalled": False, "detail": "fixture priority confirmed"}

    fixture.fixtures["/api/v1/keepers/turn/run-next"] = h.RequestHttpResponse(priority)

    def interact(process, fd, _slave, output, _base):
        try:
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"Info")
            h.send_and_wait(process, fd, output, b"m", CHAT)
            h.wait_for_output(process, fd, output, "기존 작업 처리 중".encode(), start=0, timeout=10)
            h.send_and_wait(process, fd, output, b"/priority on", h.composer_showing(b"/priority on"))
            h.send_and_wait(process, fd, output, b"\r", b"User input auto-next priority: ON")
            for message in (b"compact-one", b"compact-two"):
                h.send_and_wait(process, fd, output, message, h.composer_showing(message))
                os.write(fd, b"\r")
            h.wait_for_atomic_admissions(process, fd, output, fixture, 2)
            assert h.wait_for_fixture_event(process, fd, output, priority_seen, timeout=5)
            pending = h.resize_and_wait(process, fd, output, rows=30, columns=80,
                needle="내 메시지 2건 대기".encode(), controls=(h.FULL_REDRAW,))
            text = h.screen_text(pending)
            assert "다음 순서로 접수됨".encode() not in text, "unconfirmed priority shown as confirmed"
            priority_release.set()
            expected = "다음 순서 확인 불가" if fail_priority else "다음 순서로 접수됨"
            h.wait_for_output(process, fd, output, expected.encode(), start=0, timeout=10)
            # A changed geometry owns a redraw; repeated 80x30 does not.
            h.resize_and_wait(process, fd, output, rows=30, columns=100,
                needle=expected.encode(), controls=(h.FULL_REDRAW,))
            final = h.resize_and_wait(process, fd, output, rows=30, columns=80,
                needle=expected.encode(), controls=(h.FULL_REDRAW,))
            text = h.screen_text(final)
            rows = h.screen_rows(final)
            status = [row for row in rows.values() if "내 메시지 2건 대기".encode() in row]
            assert len(status) == 1, "pending input has duplicate status owners"
            assert expected.encode() in status[0], "receipt evidence clipped from composite status"
            assert "Esc:중단".encode() in status[0], "the actual stop action was clipped"
            for old in (b"Current direct conversation", b"Queue (", b"Requesting priority", b"(waiting", b"(running"):
                assert old not in text, f"obsolete repeated status remained: {old!r}"
            assert not fixture.interrupt_requests and not fixture.release.is_set(), "message submission stopped existing work"
            if evidence_dir:
                evidence_dir.mkdir(parents=True, exist_ok=True)
                name = "compact-refused" if fail_priority else "compact-confirmed"
                (evidence_dir / f"{name}-80x30.ansi").write_bytes(bytes(output))
                (evidence_dir / f"{name}-80x30.txt").write_bytes(text)
            fixture.release.set()
            h.wait_for_output(process, fd, output, b"reply-compact-two", start=0, timeout=10)
            if not h.wait_for_fixture_state(
                process, fd, output,
                lambda: b"Esc:detail" in h.screen_text(bytes(output)),
                timeout=5,
            ):
                raise AssertionError("settled chat did not restore detail navigation")
            h.send_and_wait(process, fd, output, b"\x1b", b"Info")
            os.write(fd, b"q")
        finally:
            priority_release.set()
            fixture.release.set()
            fixture.release_interrupt.set()

    h.run_terminal_scenario(executable,
        description="Compact chat pending input priority refusal" if fail_priority else "Compact chat pending input confirmed priority",
        interact=interact, http_fixtures=fixture.fixtures, refresh=0.2,
        extra_env={"NO_COLOR": "1"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    run_compact(os.path.abspath(args.executable), args.evidence_dir)
    run_compact(os.path.abspath(args.executable), args.evidence_dir, fail_priority=True)
    run(os.path.abspath(args.executable), args.evidence_dir)
    print("queue remains visible across admission: PASS")
