"""The working Dashboard from the first frame; the candle belongs to /about.
Exercise real PTYs with mosaic, Kitty graphics and NO_COLOR terminals.
"""
from __future__ import annotations

import base64
import hashlib
import json
import zlib
import struct
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
STARTUP_CAPTION = "MASC · keepers on watch".encode()
ABOUT_CAPTION = b"Multi-Agent Shared Context"
CHAT_TITLE = "Keepers ▸ alpha ▸ chat".encode()
# Colour escapes the renderer writes for a foreground: 38;5 on a 256-colour
# terminal, 38;2 on a truecolour one.
FOREGROUND_ESCAPE = b"\x1b[38;"
UNREAD_BRIEFING = b"Connecting to workspace"
SCENARIO_COLUMNS = 100
# The fewest rows a drawn candle has: the smallest mosaic edge the renderer
# takes is 16 pixels, two to a row.
MIN_CANDLE_ROWS = 8
# Text typed while /about is open; it must reach neither the composer nor a
# Keeper.
SWALLOWED_TEXT = b"not-for-alpha-39658"
# The harness opens a 30-row terminal; one column narrower is a resize that
# redraws the whole screen without changing what fits on it.
SCENARIO_ROWS = 30
RESIZED_COLUMNS = 99
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
# A frame that rewrites a row under the candle sends the picture it already
# had, so a step can come a few transfers late.
STEP_TRANSFER_LIMIT = 8
# The painted candle is rendered at most this many pixels square
# (Masc_tui_portrait_view.pixel_edge_cap) and the terminal scales it; the
# dotted one is rendered as many pixels as its rows show, so no dot is scaled.
PAINTED_EDGE_CAP = 160


def wait_for_whole_frame(process, fd, output: bytearray, needle: bytes,
                         start: int, timeout: float) -> None:
    """Wait for [needle] and for the end of the frame that carries it. The
    candle steps every 150 ms, so the screen does not go quiet while it is up;
    the end of a frame is when that frame's rows can be read."""
    h.wait_for_output(process, fd, output, needle, start=start, timeout=timeout)
    h.wait_for_output(process, fd, output, h.FRAME_END,
                      start=h.end_of_needle(output, needle, start), timeout=3.0)


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


def rgba_png(payload: bytes) -> tuple[int, int, bytes]:
    """Decode the lossless RGBA PNG contract using independent stdlib codecs."""
    assert payload[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    offset, compressed = 8, bytearray()
    width = height = 0
    while offset < len(payload):
        size = struct.unpack_from(">I", payload, offset)[0]
        kind = payload[offset + 4:offset + 8]
        data = payload[offset + 8:offset + 8 + size]
        crc = struct.unpack_from(">I", payload, offset + 8 + size)[0]
        assert zlib.crc32(kind + data) == crc, "invalid PNG CRC"
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", data)
            assert (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0)
        elif kind == b"IDAT":
            compressed.extend(data)
        elif kind == b"IEND":
            break
        offset += size + 12
    scanlines = zlib.decompress(compressed)
    stride = width * 4 + 1
    assert len(scanlines) == stride * height
    assert all(scanlines[row * stride] == 0 for row in range(height)), "unexpected PNG filter"
    return width, height, b"".join(scanlines[row * stride + 1:(row + 1) * stride] for row in range(height))


def mascot_transfers(wire: bytes) -> list[tuple[dict[bytes, bytes], bytes]]:
    """Every whole transfer under the mascot's id: its first chunk's keys and
    the pixels decoded from the PNG, without invoking Kitty transport inflation."""
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
                payload = base64.b64decode(b"".join(pending[1]), validate=True)
                assert pending[0].get(b"f") == b"100", "portrait must use PNG"
                assert b"o" not in pending[0], "portrait must bypass Kitty transport inflation"
                width, height, pixels = rgba_png(payload)
                # Geometry assertions below read the PNG's authoritative dimensions.
                pending[0][b"s"] = str(width).encode()
                pending[0][b"v"] = str(height).encode()
                transfers.append((pending[0], pixels))
                pending = None
    return transfers


def assert_working_overview(output: bytearray) -> bytes:
    screen = h.screen_text(bytes(output))
    for label in (b"MASC Dashboard", b"Goals", b"Work", b"Usage", b"Needs you"):
        assert label in screen, f"working Dashboard omitted {label!r}: {screen!r}"
    assert STARTUP_CAPTION not in screen, "startup branding replaced the work"
    # Work's sparkline uses lower blocks, including U+2584. The candle's
    # mosaic also paints upper half blocks, which the chart never emits.
    assert b"\xe2\x96\x80" not in output, "startup drew a mosaic candle"
    assert not MASCOT_TRANSFER_HEAD.search(bytes(output)), "startup placed a mascot image"
    return screen


def frame_evidence(binary: str, phase: str, output: bytearray) -> None:
    print(json.dumps({
        "phase": phase,
        "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        "screen": h.screen_text(bytes(output)).decode("utf-8", "replace"),
    }, ensure_ascii=False), flush=True)


def startup_overview(binary: str, *, no_color: bool = False,
                     graphics: bool = False, narrow: bool = False,
                     fail_first: bool = False) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    briefing = fixtures[BRIEFING]
    response = (503, {"error": "briefing temporarily unavailable"}) if fail_first else briefing
    gate = h.GatedHttpResponse(response, subsequent_response=briefing, hold_seconds=20.0)
    fixtures[BRIEFING] = gate
    mode = "no-color" if no_color else "kitty" if graphics else "narrow" if narrow else "error" if fail_first else "mosaic"

    def interact(process, fd, _slave, output, _base):
        try:
            assert h.wait_for_fixture_event(process, fd, output, gate.requested, timeout=5.0), \
                "the first overview read never went out"
            wait_for_whole_frame(process, fd, output, UNREAD_BRIEFING, start=0, timeout=5.0)
            if narrow:
                h.resize_and_wait(process, fd, output, rows=24, columns=80,
                                  needle=UNREAD_BRIEFING, controls=(h.FULL_REDRAW,))
            screen = assert_working_overview(output)
            assert b"Connecting to workspace" in screen, repr(screen)
            assert b"press 'r'" not in screen and b"press r" not in screen, \
                "pending read already asks for a retry"
            assert b"0 attention items" not in screen, "unread attention was counted as empty"
            frame_evidence(binary, mode + ("-resized-80x24-loading" if narrow else "-loading"), output)
            start = len(output)
            gate.release.set()
            if fail_first:
                wait_for_whole_frame(process, fd, output, b"503", start=start, timeout=5.0)
                assert_working_overview(output)
                frame_evidence(binary, mode + "-failed", output)
                start = len(output)
                os.write(fd, b"r")
            wait_for_whole_frame(process, fd, output, b"Health:", start=start, timeout=5.0)
            assert_working_overview(output)
            frame_evidence(binary, mode + "-loaded", output)
            os.write(fd, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(binary, description="startup keeps the working Dashboard: " + mode,
                            interact=interact, http_fixtures=fixtures,
                            terminal_cols=80 if narrow else SCENARIO_COLUMNS,
                            extra_env={"NO_COLOR": "1"} if no_color else None,
                            preload_input=KITTY_TERMINAL_REPLIES if graphics else None)


def startup_keys_work(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    briefing = fixtures[BRIEFING]
    gate = h.GatedHttpResponse(briefing, subsequent_response=briefing, hold_seconds=20.0)
    fixtures[BRIEFING] = gate

    def interact(process, fd, _slave, output, _base):
        try:
            wait_for_whole_frame(process, fd, output, UNREAD_BRIEFING, start=0, timeout=5.0)
            assert_working_overview(output)
            h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
            assert h.drain_until_quiet(process, fd, output), "Dashboard kept animating"
            assert_working_overview(output)
            gate.release.set()
            os.write(fd, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(binary, description="Dashboard keys work during the first read",
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
        wait_for_whole_frame(process, fd, output, b"Keepers: 2", start=start, timeout=3.0)
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
        assert h.drain_until_quiet(process, fd, output), "the screen kept moving after /about closed"
        assert not candle_rows(output), "the candle stayed after /about closed"
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
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
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        start = len(output)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        h.wait_for_output(process, fd, output, PLACEMENT, start=start, timeout=5.0)
        # Keep reading while the candle steps. A sleep that reads nothing lets
        # the terminal's buffer fill under a transfer, the TUI then
        # waits in write mid-picture, and one read afterwards sees a cut one.
        transfers = stepped_transfers(process, fd, output, start)
        wire = bytes(output[start:])
        fields, pixels = transfers[0]
        assert fields.get(b"f") == b"100", "the candle is not sent as PNG"
        assert b"o" not in fields, "the candle requests Kitty transport inflation"
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
        right = SCENARIO_COLUMNS - left - cells_wide
        assert abs(left - right) <= 1, f"picture not centred: left {left}, right {right}"
        assert not candle_rows(output), "real pixels were drawn as a mosaic as well"
        # Esc closes /about and takes the picture down with it.
        start = len(output)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.wait_for_output(process, fd, output, MASCOT_DELETE, start=start, timeout=3.0)
        assert h.drain_until_quiet(process, fd, output), "the screen kept moving after /about closed"
        after = bytes(output[output.find(MASCOT_DELETE, start):])
        assert not mascot_transfers(after), "the candle was placed again after /about closed"
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description="/about places the candle as real pixels on a Kitty terminal",
                            interact=interact, http_fixtures=fixtures,
                            terminal_cols=SCENARIO_COLUMNS,
                            preload_input=KITTY_TERMINAL_REPLIES)


def about_owns_the_keys(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    requests: list = []

    def interact(process, fd, slave, output, _base):
        # The composer writes to the keeper the roster cursor holds.
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        # i would focus the composer, the text would be its draft and Enter
        # would send it -- under /about none of that may happen.
        h.write_all(fd, output, b"i" + SWALLOWED_TEXT + b"\r")
        # The candle keeps the screen moving, so quiet never says the keys
        # were handled. The TUI reads them and handles them before its next
        # loop turn; a resize redraw after that turn is on the far side of
        # the keys, and it draws the whole screen again.
        h.wait_for_terminal_input_consumed(slave)
        h.resize_and_wait(process, fd, output, rows=SCENARIO_ROWS, columns=RESIZED_COLUMNS,
                          needle=ABOUT_CAPTION, controls=(h.FULL_REDRAW,))
        screen = h.screen_text(bytes(output))
        assert ABOUT_CAPTION in screen, "a key typed under /about closed it: " + repr(screen)
        assert SWALLOWED_TEXT not in screen, "text typed under /about reached the composer"
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        assert h.drain_until_quiet(process, fd, output), "the screen kept moving after /about closed"
        screen = h.screen_text(bytes(output))
        assert ABOUT_CAPTION not in screen, "Esc left /about open"
        assert SWALLOWED_TEXT not in screen, "the swallowed text surfaced after /about closed"
        assert not any(CHAT_SEND_PATH in path for path, _ in requests), \
            "a message was sent while /about was open"
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description="/about owns the keys until Esc",
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


def about_turns_the_candle(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def is_painted(fields: dict[bytes, bytes]) -> bool:
        return int(fields[b"s"]) <= PAINTED_EDGE_CAP

    def is_dotted(fields: dict[bytes, bytes]) -> bool:
        return int(fields[b"s"]) == int(fields[b"r"]) * CELL_HEIGHT

    def transfer_after(process, fd, output: bytearray, start: int, wanted, what: str):
        """The first whole mascot transfer since ``start`` that ``wanted``
        accepts. Transfers already on their way when the key went in are
        passed over."""
        seen = start
        for _ in range(STEP_TRANSFER_LIMIT):
            h.wait_for_output(process, fd, output, MASCOT_TRANSFER_HEAD, start=seen,
                              timeout=STEP_WAIT_SECONDS)
            seen = MASCOT_TRANSFER_HEAD.search(bytes(output), seen).end()
            for fields, pixels in mascot_transfers(bytes(output[start:])):
                if wanted(fields):
                    return fields, pixels
        raise AssertionError(f"no {what} candle was sent after the key")

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        start = len(output)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        assert b"c:candle" in h.screen_text(bytes(output)), "/about does not say c turns the candle"
        transfer_after(process, fd, output, start, is_painted, "painted")
        # c turns it to the dotted figure, drawn as many pixels as it shows.
        start = len(output)
        h.write_all(fd, output, b"c")
        fields, pixels = transfer_after(process, fd, output, start, is_dotted, "dotted")
        edge = int(fields[b"s"])
        assert edge > PAINTED_EDGE_CAP, "the dotted candle is no larger than the painted one"
        assert len(pixels) == edge * edge * 4, "the transfer is not the picture it declares"
        assert ABOUT_CAPTION in h.screen_text(bytes(output)), "c closed /about"
        # And back again.
        start = len(output)
        h.write_all(fd, output, b"c")
        transfer_after(process, fd, output, start, is_painted, "painted")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="c on /about turns the candle between painted and dotted",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=SCENARIO_COLUMNS,
        preload_input=KITTY_TERMINAL_REPLIES,
    )


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    startup_overview(binary)
    startup_overview(binary, no_color=True)
    startup_overview(binary, graphics=True)
    startup_overview(binary, narrow=True)
    startup_overview(binary, fail_first=True)
    startup_keys_work(binary)
    about_screen(binary, no_color=False)
    about_screen(binary, no_color=True)
    about_screen_with_graphics(binary)
    about_owns_the_keys(binary)
    about_turns_the_candle(binary)
    print("tui emblem screens: PASS (11 scenarios)")
