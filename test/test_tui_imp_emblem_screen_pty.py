"""The turning imp: the startup splash while the first overview read is out,
and /about over the chat, drawn by the real TUI in a pseudo-terminal."""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import test_tui_keyboard_input as h

# scripts/ci/run-edited-tests.sh runs this suite when a pull request changes a
# path named here.
SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_composer.ml",
    "bin/masc_tui_command.ml",
    "bin/masc_tui_emblem_screen.ml",
    "bin/masc_tui_imp_emblem.ml",
    "bin/masc_tui_imp_shape.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
)

BRIEFING = "/api/v1/dashboard/briefing"
# U+2800..U+28FF, the Braille block the imp is drawn in.
BRAILLE = re.compile(rb"\xe2[\xa0-\xa3][\x80-\xbf]")
SPLASH_CAPTION = "MASC · keepers on watch".encode()
ABOUT_CAPTION = b"Multi-Agent Shared Context"
CHAT_TITLE = "Keepers ▸ alpha ▸ chat".encode()
# CSI ? 997 ; 1 n: the terminal saying its page is dark. The TUI asks with
# CSI ? 996 n at start, so a reply already waiting is read as that answer.
DARK_PAGE_REPLY = b"\x1b[?997;1n"
# Colour escapes the renderer writes for a foreground: 38;5 on a 256-colour
# terminal, 38;2 on a truecolour one.
FOREGROUND_ESCAPE = b"\x1b[38;"
# The Dashboard's line for a briefing not read yet, which the splash keeps.
UNREAD_BRIEFING = b"Dashboard briefing not read yet"
# The splash scenario's terminal width, passed to the harness so the centring
# check measures against the terminal it drew in.
SPLASH_COLUMNS = 100
# How far the imp's lit cells may sit off centre. The splash holds the imp at
# its settled pose -- turned a little so its bevel shows -- so the lit part is
# not symmetric inside its box; a block drawn from the left edge would miss by
# about half the width, several times this.
CENTRE_TOLERANCE_CELLS = 10
# Text typed while /about is open; it must reach neither the composer nor a
# Keeper.
SWALLOWED_TEXT = b"not-for-alpha-39658"
CHAT_SEND_PATH = "/api/v1/keepers/chat/stream"


def imp_rows(output: bytearray, *, preserve_styles: bool = False) -> list[bytes]:
    rows = h.screen_rows(bytes(output), preserve_styles=preserve_styles)
    return [text for _, text in sorted(rows.items()) if BRAILLE.search(text)]


def startup_splash(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    briefing = fixtures[BRIEFING]
    gate = h.GatedHttpResponse(briefing, subsequent_response=briefing, hold_seconds=20.0)
    fixtures[BRIEFING] = gate

    def interact(process, fd, _slave, output, _base):
        try:
            assert h.wait_for_fixture_event(process, fd, output, gate.requested, timeout=5.0), \
                "the first overview read never went out"
            h.wait_for_output(process, fd, output, SPLASH_CAPTION, start=0, timeout=5.0)
            h.drain_until_quiet(process, fd, output)
            screen = h.screen_text(bytes(output))
            rows = imp_rows(output)
            assert rows, "no imp on the Dashboard while its first read is out: " + repr(screen)
            assert b"connecting" in screen, "the splash does not say it is connecting"
            assert UNREAD_BRIEFING in screen, \
                "the splash hid that the briefing is not read yet: " + repr(screen)
            # Centred: the imp's lit extent leaves about as much on its left as
            # on its right. The held pose is turned a little, so the lit part is
            # not exactly symmetric; a left-aligned block would miss by half
            # the width.
            text = [row.decode("utf-8", "replace") for row in rows]
            left = min(len(row) - len(row.lstrip(" ")) for row in text)
            right = min(SPLASH_COLUMNS - len(row.rstrip(" ")) for row in text)
            assert abs(left - right) <= CENTRE_TOLERANCE_CELLS, \
                f"imp not centred: left {left}, right {right}"
            start = len(output)
            gate.release.set()
            h.wait_for_output(process, fd, output, b"Health:", start=start, timeout=5.0)
            h.drain_until_quiet(process, fd, output)
            assert not imp_rows(output), "the imp stayed after the Dashboard loaded"
            assert SPLASH_CAPTION not in h.screen_text(bytes(output)), \
                "the splash caption stayed after the Dashboard loaded"
            # Quit is armed by one q and confirmed by the harness's second.
            os.write(fd, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(binary, description="startup splash stands until the overview answers",
                            interact=interact, http_fixtures=fixtures,
                            terminal_cols=SPLASH_COLUMNS)


def splash_key_passes_through(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    briefing = fixtures[BRIEFING]
    gate = h.GatedHttpResponse(briefing, subsequent_response=briefing, hold_seconds=20.0)
    fixtures[BRIEFING] = gate

    def interact(process, fd, _slave, output, _base):
        try:
            h.wait_for_output(process, fd, output, SPLASH_CAPTION, start=0, timeout=5.0)
            # The key that ends the splash still does its own job: 3 opens the
            # Keepers surface, it is not spent on dismissing the imp.
            h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
            h.drain_until_quiet(process, fd, output)
            assert not imp_rows(output), "the splash came back after a key ended it"
            gate.release.set()
            os.write(fd, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(binary, description="a key ends the startup splash and still does its job",
                            interact=interact, http_fixtures=fixtures)


def about_screen(binary: str, *, no_color: bool) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", CHAT_TITLE)
        start = len(output)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        # The workspace the harness seeds holds alpha and beta.
        h.wait_for_output(process, fd, output, b"Keepers: 2", start=start, timeout=3.0)
        rows = imp_rows(output, preserve_styles=True)
        assert rows, "/about drew no imp"
        coloured = [row for row in rows if FOREGROUND_ESCAPE in row]
        if no_color:
            assert not coloured, "NO_COLOR still coloured the imp: " + repr(coloured[:1])
        else:
            assert coloured, "a dark page drew the imp without colour"
        # Esc closes /about and nothing else: the chat is still underneath.
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="/about shows the imp " + ("without colour under NO_COLOR" if no_color else "in colour on a dark page"),
        interact=interact,
        http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else None,
        # Under NO_COLOR the TUI asks nothing about the page, so an answer
        # waiting would be typed as keys; only the colour case sends one.
        preload_input=None if no_color else DARK_PAGE_REPLY,
    )


def about_owns_the_keys(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    requests: list = []

    def interact(process, fd, _slave, output, _base):
        # The composer writes to the keeper the roster cursor holds.
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        # i would focus the composer, the text would be its draft and Enter
        # would send it -- under /about none of that may happen.
        h.write_all(fd, output, b"i" + SWALLOWED_TEXT + b"\r")
        h.drain_until_quiet(process, fd, output)
        screen = h.screen_text(bytes(output))
        assert ABOUT_CAPTION in screen, "a key typed under /about closed it: " + repr(screen)
        assert SWALLOWED_TEXT not in screen, "text typed under /about reached the composer"
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.drain_until_quiet(process, fd, output)
        screen = h.screen_text(bytes(output))
        assert ABOUT_CAPTION not in screen, "Esc left /about open"
        assert SWALLOWED_TEXT not in screen, "the swallowed text surfaced after /about closed"
        assert not any(CHAT_SEND_PATH in path for path, _ in requests), \
            "a message was sent while /about was open"
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description="/about owns the keys until Esc",
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    startup_splash(binary)
    splash_key_passes_through(binary)
    about_screen(binary, no_color=False)
    about_screen(binary, no_color=True)
    about_owns_the_keys(binary)
    print("tui imp emblem screens: PASS (5 scenarios)")
