"""Where the frame's rows sit on the surfaces, the keeper detail and the
keeper chat, before the region steps move them.

The workbench RFC's region steps (section 5.9, G0 to G5) change how many rows
the frame spends on itself. G0 makes every reader of that count read one value
from Masc_tui_frame. This suite opens a screen for each reader below and pins
the title row, the rule rows, the footer row, the blank rows between and any
list window the screen prints, so a step changes these numbers on purpose and
its diff shows what moved. docs/evidence/tui-region-baseline-2026-09-28 maps
every reader to the screen that measures it; two more suites cover the
overlays and the remaining detail screens.

Readers measured here:
- surface_chrome_rows (masc_tui_render_prim.ml): the Keepers list, the Board
  list and the Config heading, all finished by finish_surface;
- keeper_roster_pane (masc_tui_render_prim.ml): the roster beside the keeper
  detail and beside the chat, shown with Ctrl-B from 110 columns;
- keeper_detail_pane (masc_tui_render.ml): the keeper detail without the
  roster (unframed) and with it (framed);
- chat_history_first_row (masc_tui_render_chat.ml): pinned with a click on a
  folded Gate argument row, which unfolds only if the press lands on it.
"""
import os
import sys

import test_tui_keyboard_input as h
import tui_region_harness as region

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names: the frame's
# count and its aliases (masc_tui_frame.ml, masc_tui_ansi.ml) and the files
# holding the readers measured here.
#
# Kept out of the default keyboard walk, which already runs near the CI limit
# (the PTY scenario guidance, #36343).
SOURCE_MODULES = (
    "bin/masc_tui_frame.ml",
    "bin/masc_tui_frame.mli",
    "bin/masc_tui_ansi.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_chat.ml",
)

# 80 and 100 are the common terminals. The roster and the keeper detail's
# framed split open at 110 (Masc_tui_roster_pane.threshold_cols), so 109 and
# 110 sit either side of it; the Activity pane opens at 158
# (Masc_tui_acting_pane.threshold_cols), so 157 and 158 sit either side of
# that; 176 is where its wide layout fits.
WIDTHS = (80, 100, 109, 110, 157, 158, 176)
ROSTER_WIDTHS = (110, 158)

ALPHA_CHAT = b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat"
INFO_TAB = b"\xe2\x96\xb8Info"
ROSTER_HEADING = b"KEEPERS"
CTRL_B = b"\x02"
CTRL_D = b"\x04"

# A Gate argument long enough to fold at every width here, with a head the
# screen finds and a tail that shows only once it has unfolded.
GATE_HEAD = b"GATE_CLICK"
GATE_TAIL = b"GATE_TAIL"
GATE_ARGUMENT = "GATE_CLICK " + "long-argument " * 16 + "GATE_TAIL"

# The screens that end in the shared composer row; the chat draws its own.
COMPOSER_ROWS = {"keepers": 1, "board": 1, "config": 1, "keeper-detail": 1,
                 "keeper-detail-roster": 1, "keeper-chat": 0,
                 "keeper-chat-roster": 0}

# (screen, width) -> what measure() finds there.
EXPECTED: dict[tuple[str, int], dict[str, object]] = {}


# The Config body's source: the harness's navigation fixture, whose first
# value line the sweep waits for.
CONFIG_LOADED = b"first-value = 1"


def fixtures() -> region.ServedFixtures:
    """Every request the TUI makes on its way to these screens, answered.

    Where nothing is waiting -- no approvals, asks, schedules, pull requests,
    open turns or lanes -- the answer is the empty reading, so no row on a
    measured screen reports a read that failed."""
    served = h.keeper_runtime_http_fixtures()
    served.update(h.board_reference_http_fixtures())
    served["/api/v1/board/hearths"] = (200, {"hearths": []})
    served["/api/v1/dashboard/gate"] = h.empty_gate_snapshot()
    served["/api/v1/dashboard/gate/keeper-settings"] = (200, {
        "modes": [], "modes_state": {"state": "ready"},
        "exact_lanes": [], "exact_lanes_state": {"state": "ready"},
    })
    served["/api/v1/keepers/tool-approval-mode"] = (200, {"overrides": []})
    served["/api/v1/keepers/tool-approvals"] = (200, {"pending": []})
    served[h.KEEPER_ASKS_PATH] = (200, {"keeper": None, "open_count": 0, "asks": []})
    served[h.SCHEDULES_PATH] = (200, {
        "status": "ok", "schedule_runner": h.SCHEDULE_RUNNER_OK,
        "schedule_store_read_error": None, "request_count": 0,
        "truncated": False, "fsm": {"next_due_at_iso": None}, "requests": [],
    })
    served[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
    served["/api/v1/keepers/turns"] = (200, {
        "schema": "masc.keeper_turns.v1",
        "keepers": [
            {"keeper_name": name, "status": "ok",
             "chat_control_token": f"control-{name}", "turn": None}
            for name in ("alpha", "beta")
        ],
    })
    served["/api/v1/repositories/pulls"] = (200, {
        "reader": {"state": "ready", "keeper": "pr-updater"},
        "repositories_error": None, "keepers": {"state": "listed"},
        "repositories": [],
    })
    served[h.RUNTIME_CONFIG_RAW_PATH] = (200, {
        **h.runtime_config_read_metadata(),
        "path": "/workspace/config/runtime.toml",
        "source_text": h.config_navigation_source(),
    })
    # The MCP session the live feed opens: its handshake, and an observer
    # stream with nothing to say.
    served["/mcp"] = h.observer_http_fixtures()["/mcp"]
    served["/mcp?sse_kind=observer"] = h.RawHttpResponse(
        200, b": region baseline\n\n", content_type="text/event-stream")
    served["/api/v1/keepers/alpha/chat/history"] = (200, [{
        "id": "region-gate", "role": "system", "content": GATE_ARGUMENT,
        "ts": 1787348491.3,
        "approval_lifecycle": {
            "approval_id": "region-gate", "phase": "requested",
            "tool_name": "Execute", "call_summary": GATE_ARGUMENT,
        },
    }])
    served["/api/v1/keepers/alpha/tool-calls?limit=100"] = (
        200, {"keeper": "alpha", "count": 0, "health": "ok", "entries": []},
    )
    served[h.FILE_CHANGES_ALPHA_PATH] = (200, {
        "keeper": "alpha", "window_hours": 24.0, "calls_in_window": 0,
        "changes": [], "over_budget": 0, "malformed": 0,
    })
    return region.ServedFixtures(served)


def interaction(served: region.ServedFixtures):
    measured: dict[tuple[str, int], dict[str, object]] = {}

    def take(process, fd, output, screen: str, columns: int) -> None:
        # DISCOVERY (temporary, removed before review): collect instead of
        # failing so one run lists every unanswered request and measurement.
        try:
            region.settle(process, fd, output)
            rows = region.whole_screen(output)
            measured[(screen, columns)] = region.measure(
                rows, composer_rows=COMPOSER_ROWS[screen])
        except AssertionError as error:
            print(f"DISCOVERY {screen} {columns}: {str(error)[:600]}")
        print(f"DISCOVERY unanswered {screen} {columns}: {served.unanswered()}")
        region.print_screen(screen, columns, output)

    def sweep(process, fd, output, screen: str, loaded, widths) -> None:
        for columns in widths:
            h.resize_and_wait(process, fd, output, rows=region.TERMINAL_ROWS,
                              columns=columns, needle=loaded,
                              controls=(h.FULL_REDRAW,))
            take(process, fd, output, screen, columns)

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Keepers")
        sweep(process, fd, output, "keepers", b"beta", WIDTHS)

        board = h.screen_header(b"MASC Board", b" (4)")
        h.palette_go(process, fd, output, b"go board", board)
        sweep(process, fd, output, "board", b"Hostile", WIDTHS)

        h.tab_until(process, fd, output, b"MASC Config")
        sweep(process, fd, output, "config", CONFIG_LOADED, WIDTHS)

        h.tab_until(process, fd, output, b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", INFO_TAB)
        sweep(process, fd, output, "keeper-detail", INFO_TAB, WIDTHS)

        # The roster opens only where it fits; the last sweep ended at 176.
        h.send_and_wait(process, fd, output, CTRL_B, ROSTER_HEADING)
        sweep(process, fd, output, "keeper-detail-roster", ROSTER_HEADING, ROSTER_WIDTHS)

        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", ALPHA_CHAT)
        sweep(process, fd, output, "keeper-chat-roster", GATE_HEAD, ROSTER_WIDTHS)
        h.send_and_wait(process, fd, output, CTRL_B, ALPHA_CHAT)
        sweep(process, fd, output, "keeper-chat", GATE_HEAD, WIDTHS)

        # The chat maps a press to a history row from the row its history
        # starts on. Folded, the Gate argument's row is the one row that acts
        # on a press, so a press on the row where the screen shows it unfolds
        # the argument only when that mapping is right; a press on the rows
        # either side must not.
        h.resize_and_wait(process, fd, output, rows=region.TERMINAL_ROWS,
                          columns=100, needle=GATE_HEAD, controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, CTRL_D, b"tools:results")
        region.settle(process, fd, output)
        gate_row = h.screen_row_of(region.whole_screen(output), GATE_HEAD)
        if gate_row < 0:
            raise AssertionError(f"the folded Gate row is not on screen: "
                                 f"{h.screen_text(bytes(output))!r}")
        measured[("chat-gate-row", 100)] = {"row": gate_row}
        for beside in (gate_row - 1, gate_row + 1):
            os.write(fd, b"\x1b[<0;40;%dM\x1b[<0;40;%dm" % (beside, beside))
            region.settle(process, fd, output)
            if GATE_TAIL in h.screen_text(bytes(output)):
                raise AssertionError(f"a press on row {beside} unfolded the Gate "
                                     f"row at {gate_row}")
        h.send_and_wait(process, fd, output,
                        b"\x1b[<0;40;%dM\x1b[<0;40;%dm" % (gate_row, gate_row),
                        b"tools:full")
        region.settle(process, fd, output)
        if GATE_TAIL not in h.screen_text(bytes(output)):
            raise AssertionError("a press on the Gate row did not unfold it")

        region.check_all(measured, EXPECTED)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"q", b"q: press again to quit")

    return interact


if __name__ == "__main__":
    served = fixtures()
    h.run_terminal_scenario(
        os.path.abspath(sys.argv[1]),
        description="Region baseline: surfaces, keeper detail and chat",
        interact=interaction(served),
        http_fixtures=served,
    )
    print("region baseline: PASS")
