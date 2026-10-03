import unicodedata
"""Command discovery stays separate from draft, execution, and runtime status."""
import json
import os
import re
import sys

import tui_keyboard_harness as h


CHAT = "Keepers ▸ alpha ▸ chat".encode()


def open_chat(process, fd, output):
    h.resize_and_wait(process, fd, output, rows=38, columns=150, needle=b"MASC Dashboard")
    h.tab_until(process, fd, output, b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"\r", "Keepers ▸ \x1b[1malpha".encode())
    h.send_and_wait(process, fd, output, b"m", CHAT)
    h.drain_until_quiet(process, fd, output)


def screen(process, fd, output):
    h.drain_until_quiet(process, fd, output)
    return h.screen_rows(bytes(output))


# The black-background fixture already used by test_tui_theme: the user
# surface is RGB(30,30,30). Both foreground and background responses are
# required for an observed terminal palette; no production terminal is used.
DARK_PALETTE = b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\\x1b]11;rgb:0000/0000/0000\x1b\\"
SGR = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")


def styled_cells(row):
    """Cell-level reverse/background state for the SGR emitted by the TUI."""
    cells, reverse, background, cursor = [], False, None, 0

    def text(raw):
        for char in raw.decode('utf-8', 'strict'):
            width = 0 if unicodedata.combining(char) or unicodedata.category(char).startswith('C') else (2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1)
            cells.extend([(char, reverse, background)] * width)

    for escape in SGR.finditer(row):
        text(row[cursor:escape.start()])
        cursor = escape.end()
        if not escape[0].endswith(b'm'):
            continue
        values = [int(value or b'0') for value in escape[0][2:-1].split(b';')]
        index = 0
        while index < len(values):
            value = values[index]
            if value == 0:
                reverse, background = False, None
            elif value == 7:
                reverse = True
            elif value == 27:
                reverse = False
            elif value == 49:
                background = None
            elif value in (38, 48) and index + 1 < len(values):
                count = 4 if values[index + 1] == 2 else 2
                color = tuple(values[index + 1:index + count + 1])
                if value == 48:
                    background = color
                index += count
            index += 1
    text(row[cursor:])
    return cells


def styled_screen(output):
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "no completed frame"
    return h.screen_rows(bytes(output[:end + len(h.FRAME_END)]), preserve_styles=True)


def assert_menu_selection(output, rows, *, selected_offset):
    menu = h.screen_row_of(rows, b"Commands")
    draft = h.screen_row_of(rows, b"> /")
    assert menu > 0 and draft > menu + 2, "menu has no visible candidates"
    styled = styled_screen(output)
    # At 150 columns the automatic roster owns the first 34 cells.
    for number in range(menu + 1, draft - 1):
        cells = styled_cells(styled[number])[34:150]
        selected = number == menu + selected_offset
        assert len(cells) == 116, "menu candidate did not fill the chat pane"
        assert ('›' in ''.join(cell[0] for cell in cells)) == selected, "selection marker disagrees with selected candidate"
        assert all(cell[1] == selected for cell in cells), "selection did not reverse the complete candidate row, or leaked to another"


def run(executable):
    requests = []

    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        baseline_posts = len(requests)
        h.send_and_wait(process, fd, output, b"/", b"Commands  1/")
        rows = screen(process, fd, output)
        title = h.screen_row_of(rows, CHAT)
        menu = h.screen_row_of(rows, b"Commands  1/")
        draft = h.screen_row_of(rows, b"> /")
        context = h.screen_row_of(rows, b"Context")
        keys = h.screen_row_of(rows, b"Tab/Enter:insert")
        if not (0 < title < menu < draft < context < keys):
            raise AssertionError(f"chat zones overlap or change order: {rows!r}")
        assert_menu_selection(output, rows, selected_offset=1)
        print("CHAT_MENU_FRAME " + json.dumps({str(k): v.decode('utf-8', 'replace') for k, v in rows.items()}, ensure_ascii=False))
        h.send_and_wait(process, fd, output, b"\x1b[B", b"Commands  2/")
        rows = screen(process, fd, output)
        assert_menu_selection(output, rows, selected_offset=2)
        if b"> /keeper" in b"\n".join(rows.values()):
            raise AssertionError("selection changed the draft before acceptance")
        start = len(output)
        h.write_all(fd, output, b"\x1b")
        # Closing an overlay leaves the draft at the same row. The presenter
        # need not repaint that unchanged row; wait for the changed frame.
        h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=3.0)
        rows = screen(process, fd, output)
        if h.screen_row_of(rows, b"Commands") != -1 or h.screen_row_of(rows, CHAT) < 0:
            raise AssertionError("Escape did not close only the command menu")
        h.send_and_wait(process, fd, output, b"\x15/", b"Commands  1/")
        # A replacement query resets the selection. Enter inserts the full
        # command; only the following Enter executes its existing local action.
        h.send_and_wait(process, fd, output, b"\x15/se", b"Commands  1/1")
        h.send_and_wait(process, fd, output, b"\r", h.composer_showing(b"/settings"))
        rows = screen(process, fd, output)
        if h.screen_row_of(rows, CHAT) < 0 or len(requests) != baseline_posts:
            raise AssertionError("accepting a suggestion executed or submitted work")
        h.send_and_wait(process, fd, output, b"\r", b"MASC System")
        if len(requests) != baseline_posts:
            raise AssertionError("local settings command sent a provider request")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Chat command menu separates selection and execution",
                            interact=interact, http_fixtures=h.context_inspector_fixtures(), http_requests=requests)

    def compact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=15, columns=100, needle=CHAT)
        h.send_and_wait(process, fd, output, b"/", h.composer_showing(b"/"))
        rows = screen(process, fd, output)
        if h.screen_row_of(rows, b"Commands") != -1:
            raise AssertionError("menu displaced the minimum conversation viewport")
        h.resize_and_wait(process, fd, output, rows=38, columns=20, needle=b"Keeper chat")
        # An invisible menu must not steal the Escape needed to leave this pane.
        os.write(fd, b"\x1b")
        h.drain_until_quiet(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=38, columns=150, needle=b"Info")
        rows = screen(process, fd, output)
        if h.screen_row_of(rows, CHAT) >= 0:
            raise AssertionError("an invisible menu consumed Escape")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Hidden command menu does not consume keys",
                            interact=compact, http_fixtures=h.context_inspector_fixtures())

    def telemetry(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=30, columns=120, needle=CHAT)
        h.wait_for_output(process, fd, output, b"KEEPERS", start=0, timeout=3.0)
        rows = screen(process, fd, output)
        status_row = h.screen_row_of(rows, b"Context")
        status = rows[status_row] if status_row >= 0 else b""
        if not status.lstrip().startswith("alpha · ".encode()):
            raise AssertionError(f"telemetry must start below both panes: {rows!r}")
        for field in (b"healthy", b"configured: anthropic.claude-opus-5", b"Context"):
            if field not in status:
                raise AssertionError(f"120-column roster truncated runtime status {field!r}: {status!r}")
        # Moving the roster cursor does not switch the conversation yet.
        h.send_and_wait(process, fd, output, b"\x1b[D", b"Enter:open")
        h.send_and_wait(process, fd, output, b"\x1b[B", b"\x1b[7m \xc2\xb7 beta")
        rows = screen(process, fd, output)
        status_row = h.screen_row_of(rows, b"Context")
        if status_row < 0 or not rows[status_row].lstrip().startswith("alpha · ".encode()):
            raise AssertionError("roster focus retargeted the chat telemetry")
        h.send_and_wait(process, fd, output, b"\x1b[C", b"Enter:send")
        for columns in (70, 50):
            h.resize_and_wait(process, fd, output, rows=31, columns=columns,
                              needle=b"Context", controls=(h.FULL_REDRAW,))
            rows = screen(process, fd, output)
            status_row = h.screen_row_of(rows, b"Context")
            if status_row < 0 or not rows[status_row].lstrip().startswith("alpha · ".encode()):
                raise AssertionError(f"narrow telemetry lost its Keeper or unknown context: {rows!r}")
            if not any(mark in rows[status_row] for mark in (b"unavailable", "—".encode())):
                raise AssertionError(f"unknown context became a fabricated measurement: {rows[status_row]!r}")
            for row in rows.values():
                if h.fixture_cell_width(row.decode('utf-8', 'replace')) > columns:
                    raise AssertionError(f"{columns}-column frame overflowed: {row!r}")
        # q is draft text in chat; return to the read-only detail before quitting.
        h.send_and_wait(process, fd, output, b"\x1b", b"Info")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Chat telemetry spans panes and keeps unknown context",
                            interact=telemetry, http_fixtures=h.keeper_runtime_http_fixtures())


    def input_surface(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        h.send_and_wait(process, fd, output, b"input-surface-proof", h.composer_showing(b"input-surface-proof"))
        rows = screen(process, fd, output)
        draft = h.screen_row_of(rows, b"> input-surface-proof")
        context = h.screen_row_of(rows, b"Context")
        assert 0 < draft < draft + 1 < context, "input padding displaced operational status"
        styled = styled_screen(output)
        for number in (draft, draft + 1):
            cells = styled_cells(styled[number])
            inner = cells[36:148]
            if len(inner) != 112 or any(cell[2] != (2, 30, 30, 30) for cell in inner):
                # Preserve the actual failed cells before changing either the
                # expected palette or renderer. A missing palette, indexed
                # projection, reset inside the draft, and a wrong row slice
                # need different fixes.
                runs = []
                for column, (char, reverse, background) in enumerate(cells):
                    if runs and runs[-1]["reverse"] == reverse and runs[-1]["background"] == background:
                        runs[-1]["text"] += char
                    else:
                        runs.append({"column": column, "reverse": reverse,
                                     "background": background, "text": char})
                diagnostic = {"row": number, "draft_row": draft, "context_row": context,
                              "expected_background": (2, 30, 30, 30), "expected_inner_columns": [36, 148],
                              "actual_cells": len(cells), "actual_inner_cells": len(inner),
                              "raw_row": repr(styled[number]), "cell_runs": runs,
                              "plain_rows": {key: value.decode("utf-8", "replace") for key, value in rows.items()},
                              "osc10_query_emitted": b"\x1b]10;?" in output,
                              "osc11_query_emitted": b"\x1b]11;?" in output,
                              "background_sgrs": sorted({escape[0].decode("ascii") for escape in SGR.finditer(bytes(output))
                                                          if escape[0].startswith(b"\x1b[48;")})}
                print("CHAT_INPUT_SURFACE_DIAGNOSTIC " + json.dumps(diagnostic, ensure_ascii=False), flush=True)
                raise AssertionError("draft and bottom padding do not share the observed user-surface background; see CHAT_INPUT_SURFACE_DIAGNOSTIC")
        assert not any(cell[2] is not None for cell in styled_cells(styled[context])), "input background leaked into operational status"
        h.write_all(fd, output, b"\x15")
        h.drain_until_quiet(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=30, columns=80, needle=CHAT)
        rows = screen(process, fd, output)
        footer = next((row for row in rows.values() if b"/:commands" in row), b"")
        assert b"Enter:send" in footer and b"Esc:" in footer, "80-column idle footer lost send, commands or escape"
        assert h.fixture_cell_width(footer.decode()) <= 80, "compact footer exceeds the terminal"
        h.send_and_wait(process, fd, output, b"\x1b", b"Info")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Chat input and padding share the terminal theme while status stays outside",
                            interact=input_surface, http_fixtures=h.keeper_runtime_http_fixtures(),
                            preload_input=DARK_PALETTE, extra_env={"COLORTERM": "truecolor"})

    def monochrome(process, fd, _slave, output, _base):
        h.resize_and_wait(process, fd, output, rows=38, columns=150, needle=b"MASC Dashboard")
        h.tab_until(process, fd, output, b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        # Open by identity to keep this case independent of roster navigation.
        h.palette_go(process, fd, output, b"keeper alpha", CHAT)
        h.send_and_wait(process, fd, output, b"/", b"Commands  1/")
        rows = screen(process, fd, output)
        assert_menu_selection(output, rows, selected_offset=1)
        h.send_and_wait(process, fd, output, b"\x1b[B", b"Commands  2/")
        rows = screen(process, fd, output)
        assert_menu_selection(output, rows, selected_offset=2)
        assert h.screen_row_of(rows, b"> /") > 0, "NO_COLOR selection changed the draft"
        assert not any(cell[2] is not None for row in styled_screen(output).values() for cell in styled_cells(row)), "NO_COLOR still painted a background"
        h.write_all(fd, output, b"\x15")
        h.drain_until_quiet(process, fd, output)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="NO_COLOR command selection remains visible without a painted background",
                            interact=monochrome, http_fixtures=h.keeper_runtime_http_fixtures(),
                            preload_input=DARK_PALETTE, extra_env={"NO_COLOR": "1"})


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("chat command menu and status hierarchy: PASS")
