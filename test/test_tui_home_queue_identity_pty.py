"""Unread workspace identity retains local Enter input and rejects /steer and /run-next.

Fixture PTY only: this exercises client admission, not owner-store execution.
The first acceptance is held so the second Enter is genuinely local unsent
input, rather than an operation already admitted by the server.
"""
import json
import os
import re
import sys

import tui_keyboard_harness as h
import tui_keyboard_chat as chat
import tui_keyboard_keepers as keepers




def queue_identity_journey(executable):
    fixture = chat.AtomicChatFixture(first_working=True, hold_first_acceptance=True)
    requests = []

    def interact(process, fd, _slave, output, _base):
        try:
            chat.open_atomic_chat(process, fd, output)
            h.send_and_wait(process, fd, output, b"preceding-turn",
                            h.composer_showing(b"preceding-turn"))
            os.write(fd, b"\r")
            assert h.wait_for_fixture_event(process, fd, output,
                                            fixture.first_post_received, timeout=5)
            h.send_and_wait(process, fd, output, b"identity-held-next",
                            h.composer_showing(b"identity-held-next"))
            h.send_and_wait(process, fd, output, b"\r", b"Queue (1 waiting")

            def inspect_local(*, capture_id=False):
                h.send_and_wait(process, fd, output, b"/queue",
                                h.composer_showing(b"/queue"))
                h.read_available(fd, output)
                queue_start = len(output)
                result = h.send_and_wait(process, fd, output, b"\r",
                                         b"Local unsent messages: 1")
                plain = h.screen_text(h.frame_containing(result, b"Local unsent messages: 1"))
                assert b"Reading server queue" in plain, "inspection reused a stale local notice"
                h.wait_for_output(process, fd, output, b"Queue snapshot",
                                  start=queue_start, timeout=5)
                if not capture_id:
                    return None
                notice = plain.split(b"Local unsent messages: 1", 1)[1]
                ids = re.findall(
                    rb"tui-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                    notice,
                )
                assert len(ids) == 1 and b"identity-held-next" in notice, (
                    f"local queue did not expose the saved request identity: {plain!r}"
                )
                return ids[0].decode()

            saved_id = inspect_local(capture_id=True)
            # The harness has filled both successful health tuples with its
            # temporary workspace paths. Save those exact readings for recovery.
            health = {key: fixture.fixtures[key]
                      for key in ("/health", "/health?full=1")}
            for key in health:
                fixture.fixtures[key] = (503, {"error": "identity fixture unread"})

            # Home's identity clause proves the failed health reading was
            # applied, rather than merely requested by a background fiber.
            keepers.press_label_on_screen(process, fd, output, b"Dashboard", row=1,
                                    needle=b"workspace identity not read")
            # Identity is applied before admission is released, so awaiting
            # control cannot dispatch the queued request. Release promptly;
            # subsequent navigation does not consume the fixture's hold limit.
            fixture.release_first_acceptance.set()
            chat.wait_for_atomic_admissions(process, fd, output, fixture, 1)
            h.send_and_wait(process, fd, output, b"i", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
            h.send_and_wait(process, fd, output, b"m",
                            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
            draft = b"/steer unread-replacement"
            h.send_and_wait(process, fd, output, draft, h.composer_showing(draft))
            deadline_output = len(output)
            os.write(fd, b"\r")
            h.wait_for_output(process, fd, output,
                              b"Cannot steer: workspace identity is unverified",
                              start=deadline_output, timeout=5)
            assert draft in h.screen_text(bytes(output)), "unread steer lost its draft"
            assert not fixture.interrupt_requests, "unread /steer interrupted the preceding turn"
            assert len(fixture.received) == 1, "unread /steer posted a replacement"
            os.write(fd, b"\x15")
            run_next_draft = b"/run-next"
            h.send_and_wait(process, fd, output, run_next_draft,
                            h.composer_showing(run_next_draft))
            rejection_start = len(output)
            os.write(fd, b"\r")
            h.wait_for_output(process, fd, output,
                              b"Cannot run next: workspace identity is unverified",
                              start=rejection_start, timeout=5)
            assert run_next_draft in h.screen_text(bytes(output)), "unread run-next lost its draft"
            assert len(fixture.received) == 1, "unread /run-next posted queued input"
            assert fixture.run_next_calls == 0, "unread /run-next sent a control request"
            assert not any(path == "/api/v1/keepers/turn/run-next"
                           for path, _ in requests), "unread /run-next reached the server"
            os.write(fd, b"\x15")
            inspect_local()  # Current unsent count; final wire admission proves identity.
            # Clear the retained draft so composition cannot mask a faulty drain.
            os.write(fd, b"\x15")
            h.drain_until_quiet(process, fd, output, cap=1)
            fixture.release.set()
            h.wait_for_output(process, fd, output, b"reply-preceding-turn",
                              start=0, timeout=10)
            inspect_local()  # The retained request ID is verified at recovery admission.
            assert len(fixture.received) == 1, "queued input posted while identity was unread"

            # A matching health refresh resumes the already-authorized local
            # request without navigation or another Enter. Reuse the settled wire response without modeling
            # remote priority operations or owner-store execution.
            def recovered_stream(body):
                request = json.loads(body)
                assert request["request_id"] == saved_id
                with fixture.admitted:
                    fixture.received.append(request)
                    fixture.submitted.append(request)
                    fixture.admitted.notify_all()
                return chat.keeper_chat_succeeded_response(body)

            fixture.fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(recovered_stream)
            fixture.fixtures.update(health)
            chat.wait_for_atomic_admissions(process, fd, output, fixture, 2)
            recovered = fixture.submitted[1]
            assert recovered["request_id"] == saved_id, "recovery minted another request"
            assert recovered["message"] == "identity-held-next"
            assert recovered["name"] == "alpha"
            # Replies belong to their original request blocks; queue
            # inspections added below them can place that block offscreen.
            # Admission above occurred without a gesture. Scroll only now
            # to inspect its response, as the Atomic queue family does.
            os.write(fd, b"\x1b[5~" * 5)
            h.wait_for_output(process, fd, output, b"reply-identity-held-next",
                              start=0, timeout=10)
            h.drain_until_quiet(process, fd, output, cap=1)
            assert len(fixture.received) == 2, "recovery duplicated admission"
            assert not fixture.interrupt_requests
            assert not any(path == "/api/v1/keepers/turn/interrupt" for path, _ in requests)
            keepers.press_label_on_screen(process, fd, output, b"Dashboard", row=1,
                                    needle=b"Continue with alpha")
            os.write(fd, b"q")
        finally:
            fixture.release_first_acceptance.set()
            fixture.release_interrupt.set()
            fixture.release.set()

    h.run_terminal_scenario(
        executable, description="Home queue retains identity across unread settlement",
        interact=interact, http_fixtures=fixture.fixtures,
        http_requests=requests, refresh=0.2,
    )


if __name__ == "__main__":
    queue_identity_journey(os.path.abspath(sys.argv[1]))
    print("Home queue identity PTY: PASS (1 scenario)")
