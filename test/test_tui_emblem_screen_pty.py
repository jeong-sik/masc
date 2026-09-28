"""MASC's candle: the startup splash while the first overview read is out, and
/about over the chat, drawn by the real TUI in a pseudo-terminal -- as a
half-block mosaic, as real pixels where the terminal answers the Kitty
graphics query, and not at all under NO_COLOR."""
from __future__ import annotations

import base64
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
    "bin/masc_tui_graphics.ml",
    "bin/masc_tui_image_mosaic.ml",
    "bin/masc_tui_portrait_view.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_types.ml",
    "lib/keeper_portrait/keeper_portrait_draw.ml",
    "lib/keeper_portrait/keeper_portrait_look.ml",
)

BRIEFING = "/api/v1/dashboard/briefing"
# U+2580 and U+2584, the half blocks the mosaic is drawn in.
HALF_BLOCK = re.compile(rb"\xe2\x96[\x80\x84]")
SPLASH_CAPTION = "MASC · keepers on watch".encode()
ABOUT_CAPTION = b"Multi-Agent Shared Context"
CHAT_TITLE = "Keepers ▸ alpha ▸ chat".encode()
# Colour escapes the renderer writes for a foreground: 38;5 on a 256-colour
# terminal, 38;2 on a truecolour one.
FOREGROUND_ESCAPE = b"\x1b[38;"
# The Overview's own line for a briefing not read yet, which the splash keeps.
UNREAD_BRIEFING = b"Overview briefing not read yet"
# The terminal width the centring checks measure against, passed to the
# harness so it is the terminal the TUI drew in.
SPLASH_COLUMNS = 100
# How far the candle's drawn cells may sit off centre. The picture is a round
# backdrop centred in a square box, so its drawn extent is symmetric up to the
# rounding of an antialiased edge; a box drawn from the left edge of the body
# would miss by about half the body's width, several times this.
CENTRE_TOLERANCE_CELLS = 6
# The fewest rows a drawn candle has: the smallest mosaic edge the renderer
# takes is 16 pixels, two to a row.
MIN_CANDLE_ROWS = 8
# Text typed while /about is open; it must reach neither the composer nor a
# Keeper.
SWALLOWED_TEXT = b"not-for-alpha-39658"
CHAT_SEND_PATH = "/api/v1/keepers/chat/stream"
# CSI 6 ; height ; width t: the terminal saying a cell is 10 px wide and 20
# tall, then its answer to the graphics query.
KITTY_TERMINAL_REPLIES = b"\x1b[6;20;10t" + h.GRAPHICS_SUPPORTED_REPLY
CELL_WIDTH, CELL_HEIGHT = 10, 20
# The id the TUI places its candle under (Masc_tui_portrait_view).
MASCOT_IMAGE_ID = b"41"
PLACEMENT = re.compile(rb"\x1b7\x1b\[(\d+);(\d+)H\x1b_G([^;]*);")
KITTY_CHUNK = re.compile(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\")
MASCOT_DELETE = b"\x1b_Ga=d,d=I,i=" + MASCOT_IMAGE_ID + b",q=2\x1b\\"
# How long the candle has to step once: a few of the TUI's 150 ms steps.
STEP_WAIT_SECONDS = 1.0
# The first chunk of a transfer that places the candle.
MASCOT_TRANSFER_HEAD = re.compile(rb"\x1b_G(?=[^;]*a=T)(?=[^;]*i=" + MASCOT_IMAGE_ID + rb"\b)[^;]*;")
# Transfers the Kitty scenario reads before it says the candle does not step.
# A repainted frame sends the picture it already had, so a step can come a few
# transfers late.
STEP_TRANSFER_LIMIT = 8


def stepped_transfers(process, fd, output: bytearray,
                      start: int) -> list[tuple[dict[bytes, bytes], bytes]]:
    """The candle's whole transfers since ``start``, read until two of them
    are different pictures. A transfer is whole once the next one has begun,
    so this reads one transfer head at a time and looks again."""
    seen = start
    transfers: list[tuple[dict[bytes, bytes], bytes]] = []
    for _ in range(STEP_TRANSFER_LIMIT):
        h.wait_for_output(process, fd, output, MASCOT_TRANSFER_HEAD, start=seen,
                          timeout=STEP_WAIT_SECONDS)
        seen = MASCOT_TRANSFER_HEAD.search(bytes(output), seen).end()
        transfers = mascot_transfers(bytes(output[start:]))
        if len({pixels for _, pixels in transfers}) > 1:
            return transfers
    raise AssertionError(
        f"the candle went out {len(transfers)} times as one picture; it does not step")


def candle_rows(output: bytearray, *, preserve_styles: bool = False) -> list[bytes]:
    rows = h.screen_rows(bytes(output), preserve_styles=preserve_styles)
    return [text for _, text in sorted(rows.items()) if HALF_BLOCK.search(text)]


def kitty_fields(control: bytes) -> dict[bytes, bytes]:
    return dict(field.split(b"=", 1) for field in control.split(b",") if b"=" in field)


def mascot_transfers(wire: bytes) -> list[tuple[dict[bytes, bytes], bytes]]:
    """Every whole transfer under the mascot's id: its first chunk's keys and
    the decoded pixels."""
    transfers = []
    pending: tuple[dict[bytes, bytes], list[bytes]] | None = None
    for match in KITTY_CHUNK.finditer(wire):
        fields = kitty_fields(match[1])
        if fields.get(b"i") == MASCOT_IMAGE_ID and fields.get(b"a") == b"T":
            assert pending is None, "a new picture interrupted a pending transfer"
            pending = (fields, [])
        if pending is not None:
            pending[1].append(match[2])
            if fields.get(b"m", b"0") == b"0":
                transfers.append((pending[0], base64.b64decode(b"".join(pending[1]), validate=True)))
                pending = None
    return transfers


def assert_centred(rows: list[bytes], columns: int) -> None:
    text = [row.decode("utf-8", "replace") for row in rows]
    left = min(len(row) - len(row.lstrip(" ")) for row in text)
    right = min(columns - len(row.rstrip(" ")) for row in text)
    assert abs(left - right) <= CENTRE_TOLERANCE_CELLS, \
        f"candle not centred: left {left}, right {right}"


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
            rows = candle_rows(output)
            assert len(rows) >= MIN_CANDLE_ROWS, \
                "no candle on the Overview while its first read is out: " + repr(screen)
            assert b"connecting" in screen, "the splash does not say it is connecting"
            assert UNREAD_BRIEFING in screen, \
                "the splash hid that the briefing is not read yet: " + repr(screen)
            assert_centred(rows, SPLASH_COLUMNS)
            # It flickers: a later frame redraws some of its rows.
            start = len(output)
            h.wait_for_output(process, fd, output, HALF_BLOCK, start=start, timeout=STEP_WAIT_SECONDS * 3)
            start = len(output)
            gate.release.set()
            h.wait_for_output(process, fd, output, b"Health:", start=start, timeout=5.0)
            h.drain_until_quiet(process, fd, output)
            assert not candle_rows(output), "the candle stayed after the Overview loaded"
            assert SPLASH_CAPTION not in h.screen_text(bytes(output)), \
                "the splash caption stayed after the Overview loaded"
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
            # The key that ends the splash still does its own job: 2 opens the
            # Keepers surface, it is not spent on dismissing the candle.
            h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
            h.drain_until_quiet(process, fd, output)
            assert not candle_rows(output), "the splash came back after a key ended it"
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
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", CHAT_TITLE)
        start = len(output)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        # The workspace the harness seeds holds alpha and beta.
        h.wait_for_output(process, fd, output, b"Keepers: 2", start=start, timeout=3.0)
        h.drain_until_quiet(process, fd, output)
        rows = candle_rows(output, preserve_styles=True)
        if no_color:
            # A picture is the colour NO_COLOR opts out of: none at all, and
            # the caption and facts still say what /about says.
            assert not rows, "NO_COLOR still drew the candle: " + repr(rows[:1])
        else:
            assert len(rows) >= MIN_CANDLE_ROWS, "/about drew no candle"
            assert any(FOREGROUND_ESCAPE in row for row in rows), \
                "the candle was drawn without colour"
        # Esc closes /about and nothing else: the chat is still underneath.
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        h.drain_until_quiet(process, fd, output)
        assert not candle_rows(output), "the candle stayed after /about closed"
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="/about shows the candle " + ("not at all under NO_COLOR" if no_color else "as a coloured mosaic"),
        interact=interact,
        http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else None,
    )


def about_screen_with_graphics(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        # The composer writes to the keeper the roster cursor holds, and it
        # holds none until the roster is read: an i that arrives first has
        # nobody to write to and is dropped. Choose alpha first, as
        # about_owns_the_keys does.
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        start = len(output)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        h.wait_for_output(process, fd, output, PLACEMENT, start=start, timeout=5.0)
        # Keep reading while the candle steps. A sleep that reads nothing lets
        # the terminal's buffer fill under a 137 KB transfer, the TUI then
        # waits in write mid-picture, and one read afterwards sees a cut one.
        transfers = stepped_transfers(process, fd, output, start)
        wire = bytes(output[start:])
        fields, pixels = transfers[0]
        assert fields.get(b"f") == b"32", "the candle is not sent with its alpha"
        edge = int(fields[b"s"])
        assert int(fields[b"v"]) == edge, "the candle's picture is not square"
        assert len(pixels) == edge * edge * 4, "the transfer is not the picture it declares"
        assert fields.get(b"C") == b"1", "placing the candle moves the cursor"
        assert any(pixels[index + 3] == 0 for index in range(0, len(pixels), 4)), \
            "the candle's surround is not transparent"
        assert any(pixels[index + 3] == 255 for index in range(0, len(pixels), 4)), \
            "the candle itself is not opaque"
        # Where it went: the rows the frame left blank for it, centred, one
        # blank row above the caption.
        placement = PLACEMENT.search(wire)
        row, column = int(placement[1]), int(placement[2])
        rows_tall = int(fields[b"r"])
        cells_wide = -(-rows_tall * CELL_HEIGHT // CELL_WIDTH)
        caption_row = h.screen_row_of(h.screen_rows(bytes(output)), ABOUT_CAPTION)
        assert caption_row == row + rows_tall + 1, \
            f"the picture spans rows {row}..{row + rows_tall - 1} but the caption is at {caption_row}"
        left = column - 1
        right = SPLASH_COLUMNS - left - cells_wide
        assert abs(left - right) <= 1, f"picture not centred: left {left}, right {right}"
        assert not candle_rows(output), "real pixels were drawn as a mosaic as well"
        # Esc closes /about and takes the picture down with it.
        start = len(output)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        h.wait_for_output(process, fd, output, MASCOT_DELETE, start=start, timeout=3.0)
        h.drain_until_quiet(process, fd, output)
        after = bytes(output[output.find(MASCOT_DELETE, start):])
        assert not mascot_transfers(after), "the candle was placed again after /about closed"
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description="/about places the candle as real pixels on a Kitty terminal",
                            interact=interact, http_fixtures=fixtures,
                            terminal_cols=SPLASH_COLUMNS,
                            preload_input=KITTY_TERMINAL_REPLIES)


def about_owns_the_keys(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    requests: list = []

    def interact(process, fd, _slave, output, _base):
        # The composer writes to the keeper the roster cursor holds.
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        # i would focus the composer, the text would be its draft and Enter
        # would send it -- under /about none of that may happen.
        h.write_all(fd, output, b"i" + SWALLOWED_TEXT + b"\r")
        h.drain_until_quiet(process, fd, output)
        screen = h.screen_text(bytes(output))
        assert ABOUT_CAPTION in screen, "a key typed under /about closed it: " + repr(screen)
        assert SWALLOWED_TEXT not in screen, "text typed under /about reached the composer"
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
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
    about_screen_with_graphics(binary)
    about_owns_the_keys(binary)
    print("tui emblem screens: PASS (6 scenarios)")
