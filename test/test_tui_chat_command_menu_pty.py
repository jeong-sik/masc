"""Command discovery stays separate from draft, execution, and runtime status."""
import json
import os
import sys
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_command.ml", "bin/masc_tui.ml", "bin/masc_tui_types.ml",
    "bin/masc_tui_render_chat.ml", "bin/masc_tui_observation_layout.ml",
)
CHAT = "Keepers ▸ alpha ▸ chat".encode()


def open_chat(process, fd, output):
    h.resize_and_wait(process, fd, output, rows=38, columns=150, needle=b"MASC Overview")
    h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"\r", "Keepers ▸ \x1b[1malpha".encode())
    h.send_and_wait(process, fd, output, b"m", CHAT)
    h.drain_until_quiet(process, fd, output)


def screen(process, fd, output):
    h.drain_until_quiet(process, fd, output)
    return h.screen_rows(bytes(output))


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
        print("CHAT_MENU_FRAME " + json.dumps({str(k): v.decode('utf-8', 'replace') for k, v in rows.items()}, ensure_ascii=False))
        h.send_and_wait(process, fd, output, b"\x1b[B", b"Commands  2/")
        rows = screen(process, fd, output)
        if b"> /keeper" in b"\n".join(rows.values()):
            raise AssertionError("selection changed the draft before acceptance")
        h.send_and_wait(process, fd, output, b"\x1b", h.composer_showing(b"/"))
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
        h.send_and_wait(process, fd, output, b"\r", b"MASC Config")
        if len(requests) != baseline_posts:
            raise AssertionError("local settings command sent a provider request")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Chat command menu separates selection and execution",
                            interact=interact, http_fixtures=h.context_inspector_fixtures(), http_requests=requests)

    def compact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=14, columns=100, needle=CHAT)
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
                            interact=compact, http_fixtures=h.keeper_runtime_http_fixtures())


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("chat command menu and status hierarchy: PASS")
