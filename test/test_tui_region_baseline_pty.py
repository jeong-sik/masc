"""Where the frame's rows sit on the Board, Config, keeper detail and keeper
chat, before the region steps move them.

The workbench RFC's region steps (section 5.9, G0 to G5) change how many rows
the frame spends on itself. G0 makes every reader of that count read one value
from Masc_tui_frame. This suite opens a screen for each reader below and pins
the body's top, title, rules, bottom border, last drawn row, blank rows and any
list window, the roster's borders and the key hints' row, so a step changes
these numbers on purpose and its diff shows what moved.
docs/evidence/tui-region-baseline-2026-09-28 maps every reader to the screen
that measures it; two more suites cover the overlays and the remaining detail
screens.

Readers measured here:
- surface_chrome_rows (masc_tui_render_prim.ml): the Board list and Config,
  both laid out by surface_chrome;
- keeper_roster_pane (masc_tui_render_prim.ml): the roster beside the keeper
  detail and beside the chat, shown with Ctrl-B from 110 columns;
- keeper_detail_pane (masc_tui_render.ml): the keeper detail without the
  roster (unframed) and with it (framed);
- chat_history_first_row (masc_tui_render_chat.ml): pinned with a press on a
  folded Gate argument row, which unfolds only if the press lands on it.

The Keepers list reads none of them: it counts the rows it drew
(render_keepers, count_frame_lines plus its three footer rows). It is measured
as the control, a body the frame lays out without the count.
"""
import os
import sys
import time

import tui_keyboard_approvals as _keyboard_approvals
import tui_keyboard_board as _keyboard_board
import tui_keyboard_fusion as _keyboard_fusion
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers
import tui_keyboard_observer as _keyboard_observer
import tui_keyboard_repositories as _keyboard_repositories
import tui_keyboard_runtime as _keyboard_runtime
import tui_keyboard_schedule as _keyboard_schedule
import tui_keyboard_workspace as _keyboard_workspace
import tui_region_harness as region

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names: the frame's
# count and its aliases (masc_tui_frame.ml, masc_tui_ansi.ml), the body's
# rows (masc_tui_types.ml, surface_body_rows), the files holding the readers
# measured here, the portrait band that sets the Info body's content height,
# the chat's row actions (masc_tui_message_layout.ml) and the shared helpers.
#
# Kept out of the default keyboard walk, which already runs near the CI limit
# (the PTY scenario guidance, #36343).
SOURCE_MODULES = (
    "bin/masc_tui_frame.ml",
    "bin/masc_tui_frame.mli",
    "bin/masc_tui_ansi.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_keeper_portrait.ml",
    "bin/masc_tui_keeper_portrait.mli",
    "bin/masc_tui_portrait_view.ml",
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui_message_layout.ml",
    "test/tui_region_harness.py",
    "test/tui_keyboard_approvals.py",
    "test/tui_keyboard_board.py",
    "test/tui_keyboard_fusion.py",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_keepers.py",
    "test/tui_keyboard_observer.py",
    "test/tui_keyboard_repositories.py",
    "test/tui_keyboard_runtime.py",
    "test/tui_keyboard_schedule.py",
    "test/tui_keyboard_workspace.py",
)

# 80 and 100 are the common terminals. The roster and the keeper detail's
# framed split open at 110 (Masc_tui_roster_pane.threshold_cols), so 109 and
# 110 sit either side of that edge; the Activity pane opens at 158
# (Masc_tui_acting_pane.threshold_cols), so 157 and 158 sit either side of
# that one.
WIDTHS = (80, 100, 109, 110, 157, 158)
# The roster opens at 110 and is not drawn at 158, where the Activity pane
# takes the columns.
ROSTER_WIDTHS = (110, 157)

ALPHA_CHAT = b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat"
INFO_TAB = b"\xe2\x96\xb8Info"
ROSTER_HEADING = b"KEEPERS"
CTRL_B = b"\x02"
CTRL_D = b"\x04"
BACKSPACE = b"\x7f"

# A Gate argument long enough to fold at every width here, with a head the
# screen finds and a tail that shows only once it has unfolded.
GATE_HEAD = b"GATE_CLICK"
GATE_TAIL = b"GATE_TAIL"
GATE_ARGUMENT = "GATE_CLICK " + "long-argument " * 16 + "GATE_TAIL"
# Where the presses land across a history row at 100 columns: past the row's
# clock and role label, inside the text the row carries.
CHAT_PRESS_COLUMN = 40
CHAT_PRESS_WIDTH = 100
# Typed into the chat's input after a press. Keys and presses reach the TUI in
# order, so once this is drawn every press before it has been handled.
INPUT_SENTINEL = b"QZX"

# The screens that end in the shared composer row; the chat draws its own.
COMPOSER_ROWS = {"keepers": 1, "board": 1, "config": 1, "keeper-detail": 1,
                 "keeper-detail-roster": 1, "keeper-chat": 0,
                 "keeper-chat-roster": 0}
# The screens with the roster beside them, and the cells it takes
# (Masc_tui_roster_pane.pane_cols).
ROSTER_SCREENS = frozenset(("keeper-detail-roster", "keeper-chat-roster"))
ROSTER_PANE_COLUMNS = 34

# How often the observer stream says it is still open. A write to a TUI that
# has gone fails, which is what ends the stream's handler.
OBSERVER_KEEPALIVE_SECONDS = 1.0

# The Config body's source: the harness's navigation fixture, whose first
# value line the sweep waits for.
CONFIG_LOADED = b"first-value = 1"



def layout(top, title, rules, bottom, last, blank, windows=(), **pinned):
    return {"top": top, "title": title, "rules": rules, "bottom": bottom,
            "last": last, "blank": blank, "windows": windows, **pinned}


# What measure() finds on each screen: measured by replaying Test run
# 36427566813's screens through the helpers, confirmed by run 36431311636
# (docs/evidence/tui-region-baseline-2026-09-28). Row 1 is
# the tab strip, row 2 the body's top and row 3 its title everywhere here; the
# key hints are the body's last row, 29 above the composer and 30 on the chat.
# The Activity pane beside the body from 158 columns leaves the body's rows
# where they were.
# #39750 places the three Identity rows beside a twelve-row mosaic portrait.
# The recorded CI frames from job 109222918530 retain the same 22-row viewport
# and borders, with nine more content rows; see the evidence README's refresh.
KEEPERS = layout("blank", 3, (4, 7, 28), None, 28, 17)
BOARD = layout("blank", 3, (4, 7, 9), None, 13, 15)
CONFIG = layout("blank", 3, (4, 9), None, 27, 1, last_source_line=18)
# The compact candle leaves one more transparent mosaic row than the old
# portrait; the title, rule, last content row and 22-row viewport do not move.
# PR-check job109790368513: replayed six unframed and two roster Info
# frames. Identity, failure, attention and Gate facts remain; the24px candle
# has two transparent bottom mosaic rows. Only unframed blank count changes.
DETAIL = layout("blank", 3, (4,), None, 27, 6, ("1-22/46",))
DETAIL_BESIDE_ROSTER = layout("border", 3, (4, 28), 28, 28, 0, ("1-22/46",),
                              roster={"top": 2, "bottom": 28})
# #39883 reserves rows below the roster for the chat Keeper's portrait.
# Only the left roster border moves. The right composer stays at row 27,
# column 39, so its blank-row count remains 19 (see the evidence README).
CHAT_BESIDE_ROSTER = layout("blank", 3, (4, 26), None, 29, 19,
                            roster={"top": 2, "bottom": 13})
CHAT = layout("blank", 3, (4, 26), None, 29, 19)
# At 157 the folded Gate argument fits one row instead of two.
CHAT_ONE_ROW_GATE = layout("blank", 3, (4, 26), None, 29, 20)

# (screen, width) -> what measure() finds there.
EXPECTED: dict[tuple[str, object], dict[str, object]] = {
    **{("keepers", width): KEEPERS for width in WIDTHS},
    **{("board", width): BOARD for width in WIDTHS},
    **{("config", width): CONFIG for width in WIDTHS},
    **{("keeper-detail", width): DETAIL for width in WIDTHS},
    **{("keeper-detail-roster", width): DETAIL_BESIDE_ROSTER
       for width in ROSTER_WIDTHS},
    **{("keeper-chat-roster", width): CHAT_BESIDE_ROSTER for width in ROSTER_WIDTHS},
    **{("keeper-chat", width): CHAT for width in WIDTHS},
    ("keeper-chat", 157): CHAT_ONE_ROW_GATE,
    # The folded Gate argument's first row in the chat at 100 columns.
    ("chat-gate-row", CHAT_PRESS_WIDTH): {"row": 6},
}


class Counted:
    """A fixture that counts the requests it answers."""

    def __init__(self, response: _keyboard_harness.HttpResponse) -> None:
        self.response = response
        self.count = 0

    def __call__(self) -> _keyboard_harness.HttpResponse:
        self.count += 1
        return self.response


# The file changes the chat reads when a press unfolds a Gate row.
FILE_CHANGE_READS = Counted((200, {
    "keeper": "alpha", "window_hours": 24.0, "calls_in_window": 0,
    "changes": [], "over_budget": 0, "malformed": 0,
}))


def observer_stream():
    while True:
        yield b": region baseline\n\n"
        time.sleep(OBSERVER_KEEPALIVE_SECONDS)


def fixtures() -> region.ServedFixtures:
    """Every request the TUI makes on its way to these screens, answered.

    Where nothing is waiting -- no approvals, asks, schedules, pull requests,
    open turns or lanes -- the answer is the empty reading, so no row on a
    measured screen reports a read that failed."""
    served = _keyboard_harness.keeper_runtime_http_fixtures()
    roster_path = "/api/v1/gate/keepers?detailed=true"
    keeper_roster = served[roster_path]
    served.update(_keyboard_board.board_reference_http_fixtures())
    # Keep Board's four posts while restoring the observed Keepers and their
    # portraits over Board's empty Overview roster.
    served[roster_path] = keeper_roster
    served["/api/v1/board/hearths"] = (200, {"hearths": []})
    served["/api/v1/dashboard/gate"] = _keyboard_harness.empty_gate_snapshot()
    served["/api/v1/dashboard/gate/keeper-settings"] = (200, {
        "modes": [], "modes_state": {"state": "ready"},
        "exact_lanes": [], "exact_lanes_state": {"state": "ready"},
    })
    served["/api/v1/keepers/tool-approval-mode"] = (200, {"overrides": []})
    served["/api/v1/keepers/tool-approvals"] = (200, {"pending": []})
    served[_keyboard_harness.KEEPER_ASKS_PATH] = (200, {"keeper": None, "open_count": 0, "asks": []})
    served[_keyboard_schedule.SCHEDULES_PATH] = (200, {
        "status": "ok", "schedule_runner": _keyboard_schedule.SCHEDULE_RUNNER_OK,
        "schedule_store_read_error": None, "request_count": 0,
        "truncated": False, "fsm": {"next_due_at": None}, "requests": [],
    })
    served[_keyboard_keepers.KEEPER_LANES_PATH] = _keyboard_keepers.keeper_lanes_response([])
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
    # The screens the Tab walk passes on its way to Config.
    served[_keyboard_fusion.FUSION_RUNS_PATH] = _keyboard_fusion.fusion_runs_response([])
    served[_keyboard_repositories.REPOSITORIES_PATH] = (200, {"repositories": [], "total": 0})
    served[_keyboard_approvals.VERIFICATION_QUEUE_PATH] = (200, _keyboard_approvals.verification_snapshot([]))
    served["/api/v1/keepers/alpha/board-attention/quarantines"] = (
        200, {"items": [], "errors": []})
    served[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = (200, {
        **_keyboard_runtime.runtime_config_read_metadata(),
        "path": "/workspace/config/runtime.toml",
        "source_text": _keyboard_runtime.config_navigation_source(),
    })
    served["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
        200, {"keeper": "alpha", "entries": []})
    # The MCP session the live feed opens: its handshake, and an observer
    # stream that stays open with nothing to say.
    served["/mcp"] = _keyboard_observer.observer_http_fixtures()["/mcp"]
    served["/mcp?sse_kind=observer"] = _keyboard_harness.StreamingHttpResponse(observer_stream)
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
    served[_keyboard_workspace.FILE_CHANGES_ALPHA_PATH] = FILE_CHANGE_READS
    return region.ServedFixtures(served)


def interaction(served: region.ServedFixtures):
    measured: dict[tuple[str, object], dict[str, object]] = {}

    def take(process, fd, output, screen: str, columns: int) -> None:
        region.settle(process, fd, output)
        rows = region.whole_screen(output)
        where = f"{screen} at {columns}"
        region.assert_answered(served, where)
        region.assert_whole(rows, where)
        left = ROSTER_PANE_COLUMNS if screen in ROSTER_SCREENS else 0
        right = (columns - _keyboard_harness.ACTING_PANE_NARROW_COLUMNS
                 if columns >= _keyboard_harness.ACTING_PANE_THRESHOLD_COLUMNS else columns)
        if left:
            region.assert_pane_edge(rows, left - 1, where)
        if right < columns:
            region.assert_pane_edge(rows, right, where)
        measured[(screen, columns)] = region.measure(
            rows, columns=columns, composer_rows=COMPOSER_ROWS[screen],
            left=left, right=right)
        if left:
            measured[(screen, columns)]["roster"] = region.measure_pane(
                rows, left=0, right=left)
        if screen in ("keeper-detail", "keeper-detail-roster"):
            body = "\n".join(region.body_row(rows, row, left=left, right=right)
                             for row in range(3, region.TERMINAL_ROWS - 1))
            for text in ("Identity", "Name: alpha", "Paused: no", "Current failure",
                         "Board attention", "Gate"):
                if text not in body:
                    raise AssertionError(f"{where}: Info omitted {text!r}: {body!r}")
        if screen == "config":
            # The body ends on a source line whose number leads the row. A
            # height one off shows a line more or fewer, or the frame cuts.
            last = measured[(screen, columns)]["last"]
            number = region.body_row(rows, last, left=left, right=right).split(" ", 1)[0]
            measured[(screen, columns)]["last_source_line"] = int(number)
        region.print_screen(screen, columns, output)

    def sweep(process, fd, output, screen: str, loaded, widths) -> None:
        for columns in widths:
            _keyboard_harness.resize_and_wait(process, fd, output, rows=region.TERMINAL_ROWS,
                              columns=columns, needle=loaded,
                              controls=(_keyboard_harness.FULL_REDRAW,))
            take(process, fd, output, screen, columns)

    def press(fd, row: int) -> None:
        os.write(fd, b"\x1b[<0;%d;%dM\x1b[<0;%d;%dm"
                 % (CHAT_PRESS_COLUMN, row, CHAT_PRESS_COLUMN, row))

    def handled(process, fd, output) -> None:
        """Every key and press sent so far has been handled."""
        _keyboard_harness.send_and_wait(process, fd, output, INPUT_SENTINEL, INPUT_SENTINEL)
        for _ in INPUT_SENTINEL:
            os.write(fd, BACKSPACE)
        region.settle(process, fd, output)
        if INPUT_SENTINEL in _keyboard_harness.screen_text(bytes(output)):
            raise AssertionError("the input sentinel was not erased")

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC Keepers")
        sweep(process, fd, output, "keepers", b"beta", WIDTHS)

        board = _keyboard_harness.screen_header(b"MASC Board", b" (4)")
        _keyboard_harness.palette_go(process, fd, output, b"go board", board)
        sweep(process, fd, output, "board", b"Hostile", WIDTHS)

        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        sweep(process, fd, output, "config", CONFIG_LOADED, WIDTHS)

        _keyboard_harness.tab_until(process, fd, output, b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", INFO_TAB)
        sweep(process, fd, output, "keeper-detail", INFO_TAB, WIDTHS)

        # The roster opens only where it fits: back to 157 before asking.
        _keyboard_harness.resize_and_wait(process, fd, output, rows=region.TERMINAL_ROWS,
                          columns=157, needle=INFO_TAB, controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, CTRL_B, ROSTER_HEADING)
        sweep(process, fd, output, "keeper-detail-roster", ROSTER_HEADING, ROSTER_WIDTHS)

        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, fd, output, b"c", ALPHA_CHAT)
        sweep(process, fd, output, "keeper-chat-roster", GATE_HEAD, ROSTER_WIDTHS)
        _keyboard_harness.send_and_wait(process, fd, output, CTRL_B, ALPHA_CHAT)
        sweep(process, fd, output, "keeper-chat", GATE_HEAD, WIDTHS)

        # The chat maps a press to a history row from the row its history
        # starts on. Folded, the Gate argument's first row is the one row that
        # acts on a press, so a press on the row the screen shows it on
        # unfolds it only when that mapping is right, and a press on the rows
        # either side does nothing. What an unfold does that nothing else in
        # this chat does is read the keeper's file changes.
        _keyboard_harness.resize_and_wait(process, fd, output, rows=region.TERMINAL_ROWS,
                          columns=CHAT_PRESS_WIDTH, needle=GATE_HEAD,
                          controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, CTRL_D, b"tools:results")
        region.settle(process, fd, output)
        gate_row = _keyboard_harness.screen_row_of(region.whole_screen(output), GATE_HEAD)
        measured[("chat-gate-row", CHAT_PRESS_WIDTH)] = {"row": gate_row}
        region.print_measured(measured)
        if gate_row < 0:
            raise AssertionError(f"the folded Gate row is not on screen: "
                                 f"{_keyboard_harness.screen_text(bytes(output))!r}")
        reads_before = FILE_CHANGE_READS.count
        for beside in (gate_row - 1, gate_row + 1):
            press(fd, beside)
            handled(process, fd, output)
            screen = _keyboard_harness.screen_text(bytes(output))
            if (FILE_CHANGE_READS.count != reads_before or GATE_TAIL in screen
                    or b"tools:results" not in screen):
                raise AssertionError(f"a press on row {beside} unfolded the Gate "
                                     f"row at {gate_row}")
        unfolded_from = len(output)
        press(fd, gate_row)
        handled(process, fd, output)
        _keyboard_harness.wait_for_output(process, fd, output, GATE_TAIL, start=unfolded_from,
                          timeout=region.QUIET_LIMIT_SECONDS)
        region.settle(process, fd, output)
        if b"tools:full" not in _keyboard_harness.screen_text(bytes(output)):
            raise AssertionError(f"a press on row {gate_row} did not unfold the Gate row")
        if FILE_CHANGE_READS.count == reads_before:
            raise AssertionError(f"the unfold at row {gate_row} read no file changes")

        region.check_all(measured, EXPECTED)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        _keyboard_harness.send_and_wait(process, fd, output, b"q", b"q: press again to quit")

    return interact


if __name__ == "__main__":
    served = fixtures()
    _keyboard_harness.run_terminal_scenario(
        os.path.abspath(sys.argv[1]),
        description="Region baseline: Board, Config, keeper detail and chat",
        interact=interaction(served),
        http_fixtures=served,
    )
    print("region baseline: PASS")
