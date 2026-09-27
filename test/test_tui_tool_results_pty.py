"""A results-mode Gate click opens the argument and loads full detail evidence."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui_gate_text.ml",
)


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    argument = "GATE_CLICK " + "long-argument " * 16 + "GATE_TAIL"
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [{
        "id": "results-gate", "role": "system", "content": argument,
        "ts": 1787348491.3,
        "approval_lifecycle": {
            "approval_id": "gate-results", "phase": "requested",
            "tool_name": "Execute", "call_summary": argument,
        },
    }])
    fixtures["/api/v1/keepers/alpha/tool-calls?limit=100"] = (
        200, {"keeper": "alpha", "count": 0, "health": "ok", "entries": []},
    )
    changes = h.GatedHttpResponse((200, {
        "keeper": "alpha", "window_hours": 24.0, "calls_in_window": 0,
        "changes": [], "over_budget": 0, "malformed": 0,
    }))
    fixtures[h.FILE_CHANGES_ALPHA_PATH] = changes

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            h.resize_and_wait(process, master_fd, output, rows=30, columns=120,
                              needle=b"MASC Overview")
            # Palette Keeper entries come from the asynchronous roster; the
            # Overview title alone can arrive before alpha is selectable.
            h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
            h.select_keeper_row(process, master_fd, output, b"alpha")
            h.palette_go(process, master_fd, output, b"keeper alpha", b"GATE_CLICK")
            h.send_and_wait(process, master_fd, output, b"\x04", b"tools:results")
            h.drain_until_quiet(process, master_fd, output)
            before = h.screen_text(bytes(output))
            if b"GATE_TAIL" in before or changes.calls:
                raise AssertionError(f"results mode prematurely expanded details: {before!r}")
            row = h.screen_row_of(h.screen_rows(bytes(output)), b"GATE_CLICK")
            if row < 0:
                raise AssertionError(f"folded Gate row missing: {before!r}")
            h.send_and_wait(process, master_fd, output,
                            b"\x1b[<0;6;%dM\x1b[<0;6;%dm" % (row, row),
                            b"tools:full")
            if not h.wait_for_fixture_event(process, master_fd, output,
                                            changes.requested, timeout=3.0):
                raise AssertionError("Gate click did not request file-change details")
            response_start = len(output)
            changes.release.set()
            h.wait_for_output(process, master_fd, output, b"diffs 24h",
                              start=response_start, timeout=5.0)
            h.drain_until_quiet(process, master_fd, output)
            after = h.screen_text(bytes(output))
            if b"GATE_TAIL" not in after or b"diffs pending" in after:
                raise AssertionError(f"Gate click did not settle full details: {after!r}")
            # Palette chat returns to the roster, retaining its selected row.
            h.send_and_wait(process, master_fd, output, b"\x1b",
                            h.keeper_row_selected(b"alpha"))
            os.write(master_fd, b"q")
        finally:
            changes.release.set()

    h.run_terminal_scenario(
        executable, description="Results Gate click loads full details",
        interact=interact, http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("tui tool results Gate click: PASS")
