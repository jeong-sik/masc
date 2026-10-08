"""A delayed dispatch cannot consume a new draft with identical words.

The actual workspace preflight GET stays gated after Enter staged the first
request. The operator types the same words again, optionally visits another
Keeper, then the old request reaches HTTP. No second Enter is sent.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys

import tui_keyboard_chat as chat
import tui_keyboard_harness as h


def run(executable, *, visit_other_keeper):
    fixture = chat.AtomicChatFixture(first_working=True)
    for keeper in ("alpha", "beta"):
        fixture.fixtures[f"/api/v1/keepers/{keeper}/chat/history"] = (200, [])
        fixture.fixtures[f"/api/v1/keepers/{keeper}/memory-journal?limit=20"] = (
            200, {"keeper": keeper, "entries": []})
    draft = "네".encode()
    mode = "saved" if visit_other_keeper else "focused"
    gates = []

    def interact(process, fd, _slave, output, _base):
        def capture(stage):
            frame = h.resize_and_wait(process, fd, output, rows=40, columns=121,
                needle=h.composer_showing(draft), controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25h")
            frame = h.resize_and_wait(process, fd, output, rows=40, columns=120,
                needle=h.composer_showing(draft), controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25h")
            cells = h.screen_rows(frame)
            assert any(h.composer_showing(draft).search(row)
                for row in cells.values()), "the independently authored draft disappeared"
            print("STUDIO_CAPTURE=" + json.dumps({
                "suite": "test_tui_draft_dispatch_pty", "name": f"{mode}-{stage}",
                "rows": 40, "columns": 120, "provenance": "fixture PTY",
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": b"\n".join(cells.get(row, b"")
                    for row in range(1, 41)).decode(errors="replace"),
            }), flush=True)

        try:
            chat.open_atomic_chat(process, fd, output)
            for path in ("/health", "/health?full=1"):
                gate = h.GatedHttpResponse(fixture.fixtures[path], hold_seconds=30)
                gates.append(gate)
                fixture.fixtures[path] = gate
            h.send_and_wait(process, fd, output, draft, h.composer_showing(draft))
            h.send_and_wait(process, fd, output, b"\r", h.composer_showing(b""))
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: any(gate.requested.is_set() for gate in gates), timeout=5), (
                    "no workspace GET reached the preflight gate")
            assert not fixture.first_post_received.is_set(), "request bypassed preflight"
            h.send_and_wait(process, fd, output, draft, h.composer_showing(draft))
            capture("new-draft-before-old-dispatch")
            if visit_other_keeper:
                # The fixture has exactly alpha/beta. Ctrl-G saves/restores
                # their drafts without treating a palette command as text.
                h.send_and_wait(process, fd, output, b"\x07",
                    "Keepers ▸ beta ▸ chat".encode())
            for gate in gates:
                gate.release.set()
            assert h.wait_for_fixture_event(process, fd, output,
                fixture.first_post_received, timeout=5), "old request never reached HTTP"
            if visit_other_keeper:
                h.send_and_wait(process, fd, output, b"\x07",
                    "Keepers ▸ alpha ▸ chat".encode())
            h.wait_for_output(process, fd, output, b"reply-" + draft, start=0, timeout=5)
            capture("new-draft-after-old-dispatch")
            with fixture.lock:
                assert len(fixture.received) == 1, "draft was submitted without a second Enter"
                assert fixture.received[0]["message"] == draft.decode()
            fixture.release.set()
            h.send_and_wait(process, fd, output, b"\x15", h.composer_showing(b""))
            h.send_and_wait(process, fd, output, b"\x11", b"Info")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            for gate in gates:
                gate.release.set()
            fixture.close()

    h.run_terminal_scenario(executable,
        description=f"Delayed dispatch preserves independently authored {mode} draft",
        interact=interact, http_fixtures=fixture.fixtures, refresh=0.2)


if __name__ == "__main__":
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(
        Path(sys.argv[1]).read_bytes()).hexdigest(), flush=True)
    for visit_other_keeper in (False, True):
        run(sys.argv[1], visit_other_keeper=visit_other_keeper)
    print("TUI draft dispatch PTY: PASS")
