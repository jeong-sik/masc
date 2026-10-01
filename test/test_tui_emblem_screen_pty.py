"""The working Dashboard from the first frame; the candle belongs to /about.
Exercise real PTYs with mosaic, Kitty graphics and NO_COLOR terminals.
"""
from __future__ import annotations

import base64
import hashlib
import json
import zlib
import struct
import tempfile
import os
import re
import sys
from pathlib import Path

import test_tui_keyboard_input as h

# scripts/ci/run-edited-tests.sh runs this suite when a pull request changes a
# path named here.
SOURCE_MODULES = (
    "bin/masc_tui_home.ml", "bin/masc_tui_home.mli",
    "bin/masc_tui_input_reader.ml",
    "bin/masc_tui_input_reader.mli",
    "bin/masc_tui.ml",
    "bin/masc_tui_composer.ml",
    "bin/masc_tui_command.ml",
    "bin/masc_tui_config.ml",
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
    for label in (b"MASC Dashboard", b"Work:", b"Continue", b"Choose a Keeper"):
        assert label in screen, f"working Dashboard omitted {label!r}: {screen!r}"
    assert (b"Needs your decision" in screen
            or b"No decision is waiting on you." in screen), screen
    assert STARTUP_CAPTION not in screen, "startup branding replaced the work"
    # Home must remain usable without the startup candle's upper half blocks.
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
        assert h.drain_until_quiet(process, fd, output), "the chat did not settle before /about"
        chat_picture_rows = candle_rows(output)
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
        # Wide split chat has its own Keeper mosaic; Esc must restore that picture.
        assert candle_rows(output) == chat_picture_rows, "the candle stayed after /about closed"
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
        # Select a real Keeper before opening its message composer.
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, fd, output, b"c", b"Esc:detail")
        start = len(output)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        h.wait_for_output(process, fd, output, PLACEMENT, start=start, timeout=5.0)
        # Keep reading while the candle steps. A sleep that reads nothing lets
        # the terminal's buffer fill under a transfer, the TUI then
        # waits in write mid-picture, and one read afterwards sees a cut one.
        transfers = stepped_transfers(process, fd, output, start)
        wire = bytes(output[start:])
        assert b"i=43" in wire and b"i=44" in wire, \
            "registered Keepers lost their separate Kitty placements"
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
        # The candle keeps its own Kitty identity beside the Keeper images.
        placement = next(
            (match for match in PLACEMENT.finditer(wire)
             if kitty_fields(match[3]).get(b"i") == MASCOT_IMAGE_ID), None
        )
        assert placement is not None, "the candle had no Kitty placement"
        row, column = int(placement[1]), int(placement[2])
        rows_tall = int(fields[b"r"])
        cells_wide = -(-rows_tall * CELL_HEIGHT // CELL_WIDTH)
        caption_row = h.screen_row_of(h.screen_rows(bytes(output)), ABOUT_CAPTION)
        assert caption_row > row + rows_tall, \
            f"the picture spans rows {row}..{row + rows_tall - 1} but the caption is at {caption_row}"
        left = column - 1
        right = SCENARIO_COLUMNS - left - cells_wide
        assert abs(left - right) <= 1, f"picture not centred: left {left}, right {right}"
        assert not candle_rows(output), "real pixels were drawn as a mosaic as well"
        # Esc closes /about and takes the picture down with it.
        start = len(output)
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        h.wait_for_output(process, fd, output, MASCOT_DELETE, start=start, timeout=3.0)
        assert h.drain_until_quiet(process, fd, output), "the screen kept moving after /about closed"
        after = bytes(output[output.find(MASCOT_DELETE, start):])
        assert not mascot_transfers(after), "the candle was placed again after /about closed"
        h.send_and_wait(process, fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description="/about places the candle as real pixels on a Kitty terminal",
                            interact=interact, http_fixtures=fixtures,
                            terminal_cols=SCENARIO_COLUMNS,
                            preload_input=KITTY_TERMINAL_REPLIES)


def about_owns_the_keys(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    requests: list = []

    def interact(process, fd, slave, output, _base):
        # Open the selected Keeper's message composer.
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, fd, output, b"c", b"Esc:detail")
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        h.write_all(fd, output, b"q")
        h.wait_for_terminal_input_consumed(slave)
        assert h.drain_until_quiet(process, fd, output, quiet=0.35, cap=1.5), \
            "q did not settle the /about arrival"
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
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        assert h.drain_until_quiet(process, fd, output), "the screen kept moving after /about closed"
        screen = h.screen_text(bytes(output))
        assert ABOUT_CAPTION not in screen, "Esc left /about open"
        assert SWALLOWED_TEXT not in screen, "the swallowed text surfaced after /about closed"
        assert not any(CHAT_SEND_PATH in path for path, _ in requests), \
            "a message was sent while /about was open"
        h.send_and_wait(process, fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description="/about owns the keys until Esc",
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


def about_turns_the_candle(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def transfer_after(process, fd, output: bytearray, start: int, what: str):
        """A complete mascot transfer after the key, including its PNG."""
        # A settled style change sends one picture. Keep its header while the
        # remaining chunks arrive; there need not be another transfer to wait for.
        complete = h.wait_for_fixture_state(
            process, fd, output,
            lambda: bool(mascot_transfers(bytes(output[start:]))),
            timeout=STEP_WAIT_SECONDS * STEP_TRANSFER_LIMIT,
        )
        assert complete, f"no complete {what} candle was sent after the key"
        return mascot_transfers(bytes(output[start:]))[-1]

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, fd, output, b"c", b"Esc:detail")
        start = len(output)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        assert b"c:candle" in h.screen_text(bytes(output)), "/about does not say c turns the candle"
        transfer_after(process, fd, output, start, "painted")
        assert h.drain_until_quiet(process, fd, output, quiet=0.35, cap=4.5), \
            "/about did not reach its final frame"
        # The settled overlay owns q too. Two presses would quit if the first
        # had reached the global quit confirmation ahead of the modal handler.
        h.write_all(fd, output, b"qq")
        h.wait_for_terminal_input_consumed(_slave)
        h.resize_and_wait(process, fd, output, rows=SCENARIO_ROWS,
                          columns=RESIZED_COLUMNS, needle=ABOUT_CAPTION,
                          controls=(h.FULL_REDRAW,))
        assert process.poll() is None, "q quit from the settled /about screen"
        # The settled scene still answers c. Compare two full style cycles so
        # a transfer already in flight cannot serve as the baseline.
        start = len(output)
        h.write_all(fd, output, b"c")
        fields, dotted = transfer_after(process, fd, output, start, "dotted")
        edge = int(fields[b"s"])
        assert len(dotted) == edge * edge * 4, "the transfer is not the picture it declares"
        assert ABOUT_CAPTION in h.screen_text(bytes(output)), "c closed /about"
        start = len(output)
        h.write_all(fd, output, b"c")
        _, painted = transfer_after(process, fd, output, start, "painted")
        assert painted != dotted, "c did not change the candle's style"
        start = len(output)
        h.write_all(fd, output, b"c")
        _, dotted_again = transfer_after(process, fd, output, start, "dotted again")
        assert dotted_again == dotted, "the second style cycle changed the dotted candle"
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        h.send_and_wait(process, fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
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


def about_arrival_frames(binary: str, columns: int, *, reduced_motion: bool) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def prepare(base_path: str) -> None:
        if reduced_motion:
            config = Path(base_path, ".masc", "config")
            config.mkdir(parents=True, exist_ok=True)
            (config / "runtime.toml").write_text(
                "[tui]\nreduce_motion = true\n", encoding="utf-8"
            )

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", CHAT_TITLE)
        start = len(output)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        assert h.drain_until_quiet(process, fd, output, cap=4.5), \
            "/about kept repainting after its finite arrival"
        frames = []
        cursor = start
        while True:
            at = output.find(h.FRAME_END, cursor)
            if at < 0:
                break
            cursor = at + len(h.FRAME_END)
            prefix = bytes(output[:cursor])
            if ABOUT_CAPTION in h.screen_text(prefix):
                frames.append(prefix)
        assert frames, "/about drew no completed frame"
        screen = h.screen_text(frames[-1])
        assert b"alpha" in screen and b"beta" in screen, \
            f"the registered Keeper names are missing: {screen!r}"
        if reduced_motion:
            assert len(frames) <= 2, \
                f"reduce_motion animated /about through {len(frames)} frames"
            chosen = [(0, "final")]
        else:
            assert len(frames) >= 3, \
                f"the gathering and dispersal never reached the terminal: {len(frames)}"
            chosen = [(0, "start"), (len(frames) // 2, "middle"), (-1, "end")]
        for index, phase in chosen:
            frame_evidence(binary, f"about-{columns}x32-{phase}", bytearray(frames[index]))
        before = len(output)
        assert h.drain_until_quiet(process, fd, output, quiet=0.6, cap=1.0), \
            "the final /about frame restarted the animation clock"
        assert not MASCOT_TRANSFER_HEAD.search(bytes(output[before:])), \
            "a settled /about candle was placed again during four animation ticks"
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    with tempfile.TemporaryDirectory(prefix="masc-about-timing-") as timing_dir:
        timing = Path(timing_dir, "frames.txt")
        h.run_terminal_scenario(
            binary,
            description=f"/about finite arrival at {columns}x32" +
                        (" with reduced motion" if reduced_motion else ""),
            interact=interact,
            http_fixtures=fixtures,
            prepare_workspace=prepare,
            terminal_cols=columns,
            terminal_rows=32,
            extra_env={"MASC_TUI_FRAME_TIMING": str(timing)},
        )
        assert timing.is_file(), "/about frame timing report was not written at exit"
        print(json.dumps({"phase": f"about-{columns}x32-timing",
                          "report": timing.read_text(encoding="utf-8")},
                         ensure_ascii=False), flush=True)


def about_exit_stops_clock(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", CHAT_TITLE)
        h.send_and_wait(process, fd, output, b"/about\r", ABOUT_CAPTION)
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        after_close = len(output)
        assert h.drain_until_quiet(process, fd, output, quiet=0.7, cap=1.2), \
            "the closed /about screen kept repainting"
        assert ABOUT_CAPTION not in bytes(output[after_close:]), \
            "a closed /about drew again during four animation ticks"
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary, description="leaving /about stops its frame clock",
        interact=interact, http_fixtures=fixtures,
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
    about_arrival_frames(binary, 80, reduced_motion=False)
    about_arrival_frames(binary, 140, reduced_motion=False)
    about_arrival_frames(binary, 80, reduced_motion=True)
    about_exit_stops_clock(binary)
    print("tui emblem screens: PASS (15 scenarios)")
