"""A Keeper's own portrait at the head of its detail, drawn by the real TUI in
a pseudo-terminal: a half-block mosaic beside the Identity facts, gone from a
terminal too short to spare its rows and back when the terminal grows, not
drawn at all under NO_COLOR, and real pixels over the band's rows where the
terminal answers the Kitty graphics query."""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import test_tui_keyboard_input as h

# scripts/ci/run-edited-tests.sh runs this suite when a pull request changes a
# path named here.
SOURCE_MODULES = (
    "bin/masc_tui_graphics.ml",
    "bin/masc_tui_image_mosaic.ml",
    "bin/masc_tui_keeper_portrait.ml",
    "bin/masc_tui_portrait_view.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_prim.ml",
    "lib/keeper_portrait/keeper_portrait_draw.ml",
    "lib/keeper_portrait/keeper_portrait_look.ml",
)

# U+2580 and U+2584, the half blocks the mosaic is drawn in.
HALF_BLOCK = "▀▄"
# Colour escapes the renderer writes for a foreground: 38;5 on a 256-colour
# terminal, 38;2 on a truecolour one.
FOREGROUND_ESCAPE = b"\x1b[38;"
INFO_TAB = "▸Info".encode()
IDENTITY = b"Identity"
NAME_ROW = b"Name:"
PAUSED_ROW = b"Paused:"
CURRENT_FAILURE = b"Current failure"
# Masc_tui_keeper_portrait.band_size: the rows and cells a mosaic portrait
# takes, and the rows a placed one does on a 20 px cell.
MOSAIC_BAND_ROWS = 12
MOSAIC_BAND_COLS = 24
PIXEL_BAND_ROWS = 8
# Where a portrait cell may sit: the frame's two cells, the fact indent, and
# the band. A half block further right is not the portrait.
PORTRAIT_CELLS = 2 + 2 + MOSAIC_BAND_COLS
# The harness terminal's 30 rows leave the detail 23 content rows, over a
# mosaic's Masc_tui_keeper_portrait.min_content_rows (20); 24 rows leave it
# 17, under.
TALL_ROWS = 30
SHORT_ROWS = 24
COLUMNS = 100
# CSI 6 ; height ; width t: the terminal saying a cell is 10 px wide and 20
# tall, then its answer to the graphics query.
KITTY_TERMINAL_REPLIES = b"\x1b[6;20;10t" + h.GRAPHICS_SUPPORTED_REPLY
# Masc_tui_graphics.image_id Keeper_portrait.
PORTRAIT_IMAGE_ID = b"42"
# A picture at a corner: a transfer, whose control data ends at the payload's
# ";", or a put of pixels the terminal already holds, which ends the escape.
PLACEMENT = re.compile(rb"\x1b7\x1b\[(\d+);(\d+)H\x1b_G([^;\x1b]*)(?:;|\x1b\\)")
# A placement is written after the frame, between a cursor save and restore;
# it is not text on the row it starts on.
PLACED_PICTURE = re.compile(rb"\x1b7.*?\x1b8", re.S)
PORTRAIT_DELETE = b"\x1b_Ga=d,d=I,i=" + PORTRAIT_IMAGE_ID + b",q=2\x1b\\"
# The pane's content starts two cells in (Masc_tui_ansi.framed_content_column)
# and the portrait two more (the fact indent): column 5, counted from 1.
PORTRAIT_COLUMN = 1 + 2 + 2


def last_frame_rows(output: bytearray, *, preserve_styles: bool = False) -> dict[int, bytes]:
    """The screen as of the last completed frame."""
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "no frame was completed"
    drawn = PLACED_PICTURE.sub(b"", bytes(output[: end + len(h.FRAME_END)]))
    return h.screen_rows(drawn, preserve_styles=preserve_styles)


def kitty_fields(control: bytes) -> dict[bytes, bytes]:
    return dict(field.split(b"=", 1) for field in control.split(b",") if b"=" in field)


def portrait_rows(rows: dict[int, bytes]) -> list[int]:
    """Rows with a mosaic cell where the portrait stands."""
    return [
        number
        for number, text in sorted(rows.items())
        if any(cell in HALF_BLOCK for cell in text.decode("utf-8", "replace")[:PORTRAIT_CELLS])
    ]


def row_of(rows: dict[int, bytes], needle: bytes) -> int:
    number = h.screen_row_of(rows, needle)
    assert number >= 0, f"no row says {needle!r}: {rows!r}"
    return number


def identity_row(rows: dict[int, bytes]) -> int:
    """The Info section's Identity heading: the row above Name:. The tab
    strip names an Identity tab too, higher up."""
    identity = row_of(rows, NAME_ROW) - 1
    assert IDENTITY in rows.get(identity, b""), f"no Identity heading above Name: {rows!r}"
    return identity


def assert_facts_full_width(rows: dict[int, bytes], why: str) -> None:
    assert not portrait_rows(rows), f"{why}, the portrait still drew: {rows!r}"
    identity = identity_row(rows)
    # Identity, Name, Paused, a blank row: the facts keep every row.
    assert row_of(rows, CURRENT_FAILURE) == identity + 4, \
        f"{why}, the rows the portrait took were not given back: {rows!r}"


def assert_portrait_beside_identity(output: bytearray) -> None:
    rows = last_frame_rows(output)
    identity = identity_row(rows)
    band = portrait_rows(rows)
    assert band, "the detail drew no portrait: " + repr(rows)
    assert band[0] == identity and band[-1] < identity + MOSAIC_BAND_ROWS, \
        f"the portrait is not the {MOSAIC_BAND_ROWS} rows beside Identity: rows {band}, Identity {identity}"
    assert len(band) >= MOSAIC_BAND_ROWS // 2, f"too little of the portrait drew: rows {band}"
    for offset, needle in enumerate((IDENTITY, NAME_ROW, PAUSED_ROW)):
        text = rows[identity + offset].decode("utf-8", "replace")
        cells = [text.find(cell) for cell in HALF_BLOCK if cell in text]
        assert cells and min(cells) < text.find(needle.decode()), \
            f"{needle!r} is not beside the portrait: {text!r}"
    assert b"alpha" in rows[identity + 1], "the Name row lost the name"
    # The band holds the facts' rows: the blank row after the portrait, then
    # the next section.
    assert row_of(rows, CURRENT_FAILURE) == identity + MOSAIC_BAND_ROWS + 1, \
        f"the facts after the portrait moved: {rows!r}"
    styled = last_frame_rows(output, preserve_styles=True)
    assert FOREGROUND_ESCAPE in styled[identity], "the portrait was drawn without colour"


def open_alpha_detail(process, fd, output) -> None:
    h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"\r", INFO_TAB)
    h.drain_until_quiet(process, fd, output)


def portrait_follows_the_terminal_height(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        assert_portrait_beside_identity(output)
        # A short terminal keeps every row for facts.
        h.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=IDENTITY)
        h.drain_until_quiet(process, fd, output)
        assert_facts_full_width(last_frame_rows(output), "on a short terminal")
        # And the portrait comes back when the rows do.
        h.resize_and_wait(process, fd, output, rows=TALL_ROWS, columns=COLUMNS, needle=IDENTITY)
        h.drain_until_quiet(process, fd, output)
        assert_portrait_beside_identity(output)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="the keeper detail's portrait stands beside Identity and yields to a short terminal",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=COLUMNS,
    )


def no_portrait_under_no_color(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        # A picture is the colour NO_COLOR opts out of.
        assert_facts_full_width(last_frame_rows(output), "under NO_COLOR")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="the keeper detail draws no portrait under NO_COLOR",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=COLUMNS,
        extra_env={"NO_COLOR": "1"},
    )


def portrait_as_pixels(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        start = len(output)
        open_alpha_detail(process, fd, output)
        # The transfers: a later row rewritten across the picture puts the
        # held pixels back (a=p), which carries no format to check.
        placements = [
            match for match in PLACEMENT.finditer(bytes(output[start:]))
            if kitty_fields(match[3]).get(b"i") == PORTRAIT_IMAGE_ID
            and kitty_fields(match[3]).get(b"a") == b"T"
        ]
        assert placements, "the detail placed no portrait on a Kitty terminal"
        placement = placements[-1]
        fields = kitty_fields(placement[3])
        rows = last_frame_rows(output)
        identity = identity_row(rows)
        assert int(placement[1]) == identity, \
            f"the picture starts on row {placement[1].decode()}, Identity is on {identity}"
        assert int(placement[2]) == PORTRAIT_COLUMN, \
            f"the picture starts at column {placement[2].decode()}, not {PORTRAIT_COLUMN}"
        assert int(fields[b"r"]) == PIXEL_BAND_ROWS, "the picture is not the band's rows tall"
        assert fields.get(b"f") == b"100", "the portrait is not sent as RGBA PNG"
        assert b"o" not in fields, "the portrait requests Kitty transport inflation"
        assert not portrait_rows(rows), "real pixels were drawn as a mosaic as well"
        assert row_of(rows, CURRENT_FAILURE) == identity + PIXEL_BAND_ROWS + 1, \
            "the facts did not leave the picture its rows"
        # Leaving the detail takes the picture down with it.
        start = len(output)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.wait_for_output(process, fd, output, PORTRAIT_DELETE, start=start, timeout=3.0)
        h.drain_until_quiet(process, fd, output)
        after = bytes(output[output.find(PORTRAIT_DELETE, start):])
        assert not any(
            kitty_fields(match[3]).get(b"i") == PORTRAIT_IMAGE_ID for match in PLACEMENT.finditer(after)
        ), "the portrait was placed again after the detail closed"
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="the keeper detail places its portrait as real pixels on a Kitty terminal",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=COLUMNS,
        preload_input=KITTY_TERMINAL_REPLIES,
    )


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    portrait_follows_the_terminal_height(binary)
    no_portrait_under_no_color(binary)
    portrait_as_pixels(binary)
    print("tui keeper portrait: PASS (3 scenarios)")
