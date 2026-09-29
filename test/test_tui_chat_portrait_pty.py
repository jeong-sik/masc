"""The active conversation's portrait below its roster, through the real TUI.

No model calls: two fixture Keepers let selection and the open chat disagree.
The Kitty case decodes complete PNG transfers, including identity changes;
other cases check the colour fallback and the space returned on small screens.
"""
from __future__ import annotations

import base64
import os
import re
import struct
import sys
import zlib
from pathlib import Path

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_chat_portrait.ml",
    "bin/masc_tui_keeper_portrait.ml",
    "bin/masc_tui_portrait_view.ml",
    "bin/masc_tui_graphics.ml",
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_roster_pane.ml",
)

COLUMNS = 150  # Roster fits; the separate Activity pane does not open.
TALL_ROWS = 30
SHORT_ROWS = 18
ROSTER_COLUMNS = 34
CAPTION = "대화 · ".encode()
IMAGE_ID = b"42"
DELETE = b"\x1b_Ga=d,d=I,i=42,q=2\x1b\\"
KITTY_REPLIES = b"\x1b[6;20;10t" + h.GRAPHICS_SUPPORTED_REPLY
PLACED = re.compile(rb"\x1b7\x1b\[(\d+);(\d+)H(.*?)\x1b8", re.S)
CHUNK = re.compile(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\")
HALF_BLOCKS = "▀▄"


def chat_title(name: bytes) -> bytes:
    return b"Keepers \xe2\x96\xb8 " + name + b" \xe2\x96\xb8 chat"


def screen(output: bytearray) -> dict[int, bytes]:
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "no completed text frame"
    # Cursor moves used to place an image are not text-row updates.
    return h.screen_rows(PLACED.sub(b"", bytes(output[:end + len(h.FRAME_END)])))


def left_text(row: bytes) -> str:
    return row.decode("utf-8", "replace")[:ROSTER_COLUMNS]


def caption_row(rows: dict[int, bytes], name: bytes) -> int:
    caption = (CAPTION + name).decode()
    matching = [row for row, text in rows.items() if caption in left_text(text)]
    assert len(matching) == 1, f"expected one active-chat caption {caption!r}: {rows!r}"
    return matching[0]


def mosaic_rows(rows: dict[int, bytes]) -> list[int]:
    return [row for row, text in sorted(rows.items())
            if any(cell in left_text(text) for cell in HALF_BLOCKS)]


def png_transfers(output: bytes) -> list[tuple[int, int, bytes]]:
    """Return complete keeper placements; reject unsafe/malformed transport."""
    pictures = []
    for placement in PLACED.finditer(output):
        chunks = list(CHUNK.finditer(placement[3]))
        if not chunks:
            continue
        fields = dict(item.split(b"=", 1) for item in chunks[0][1].split(b",") if b"=" in item)
        if fields.get(b"i") != IMAGE_ID:
            continue
        assert fields.get(b"f") == b"100", "portrait must use the PNG decoder"
        assert b"o" not in fields, "portrait must not use Kitty transport inflation"
        assert fields.get(b"p") == b"1" and fields.get(b"C") == b"1", "unstable placement identity/cursor"
        assert fields.get(b"r") == b"8", "pixel portrait must reserve eight rows"
        for index, chunk in enumerate(chunks):
            keys = dict(item.split(b"=", 1) for item in chunk[1].split(b",") if b"=" in item)
            assert keys.get(b"m") == (b"0" if index == len(chunks) - 1 else b"1"), "unfinished PNG chunks"
            if index:
                assert set(keys) == {b"m"}, "continuation chunk must not repeat image controls"
        png = base64.b64decode(b"".join(chunk[2] for chunk in chunks), validate=True)
        assert png[:8] == b"\x89PNG\r\n\x1a\n", "portrait payload is not PNG"
        width, height = struct.unpack(">II", png[16:24])
        assert width == height and 0 < width <= 160, "portrait exceeds the existing pixel cap"
        assert png[24:26] == b"\x08\x06", "portrait lost 8-bit RGBA alpha"
        offset, compressed = 8, []
        while offset < len(png):
            length = int.from_bytes(png[offset:offset + 4], "big")
            kind = png[offset + 4:offset + 8]
            data = png[offset + 8:offset + 8 + length]
            assert offset + length + 12 <= len(png), "truncated PNG chunk"
            assert zlib.crc32(kind + data) == int.from_bytes(png[offset + 8 + length:offset + 12 + length], "big"), "PNG checksum mismatch"
            if kind == b"IDAT":
                compressed.append(data)
            offset += length + 12
            if kind == b"IEND":
                break
        assert offset == len(png) and kind == b"IEND", "PNG did not end cleanly"
        assert len(zlib.decompress(b"".join(compressed))) == height * (width * 4 + 1), "RGBA scanlines incomplete"
        pictures.append((int(placement[1]), int(placement[2]), png))
    return pictures


def open_chat(process, fd, output) -> None:
    h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"c", chat_title(b"alpha"))
    h.drain_until_quiet(process, fd, output)
    assert any(b"KEEPERS" in row for row in screen(output).values()), "wide chat must show its roster by default"


def assert_chat_intact(rows: dict[int, bytes], name: bytes) -> None:
    text = b"\n".join(rows.values())
    assert chat_title(name) in text, "portrait replaced the conversation heading"
    assert b"Context" in text, "portrait displaced the runtime/context status row"
    assert b"  > " in text, "portrait displaced the input row"
    if any("KEEPERS" in left_text(row) for row in rows.values()):
        # Even the blank row after the portrait must retain the left pane's
        # width when zipped with the longer chat. A bare newline moves the
        # composer into the portrait column while its cursor stays right.
        composer = [row for row in rows.values() if b"  > " in row]
        assert len(composer) == 1, f"expected one composer row: {composer!r}"
        assert h.fixture_cell_width(composer[0].split(b">", 1)[0].decode()) == ROSTER_COLUMNS + 4, (
            f"composer moved out of the right pane: {composer[0]!r}")


def assert_hidden(rows: dict[int, bytes]) -> None:
    assert not any(CAPTION in row for row in rows.values()), "hidden portrait left its caption"
    assert not mosaic_rows(rows), "hidden portrait left mosaic cells"


def close_chat(process, fd, output) -> None:
    h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
    os.write(fd, b"q")


def mosaic_resizes(binary: str) -> None:
    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)

        def visible():
            rows = screen(output)
            caption = caption_row(rows, b"alpha")
            band = mosaic_rows(rows)
            assert len(band) >= 6 and all(caption < row <= caption + 12 for row in band), "mosaic escaped its reserved band"
            # Row 1 is the tab strip; the roster starts at row 2. Its
            # eight drawn rows leave four entries after its four chrome rows.
            assert caption - 2 >= 8, "portrait left fewer than four selectable roster rows"
            assert_chat_intact(rows, b"alpha")

        visible()
        h.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=chat_title(b"alpha"))
        h.drain_until_quiet(process, fd, output)
        assert_hidden(screen(output))
        assert_chat_intact(screen(output), b"alpha")
        h.resize_and_wait(process, fd, output, rows=TALL_ROWS, columns=109, needle=chat_title(b"alpha"))
        h.drain_until_quiet(process, fd, output)
        assert_hidden(screen(output))
        h.resize_and_wait(process, fd, output, rows=TALL_ROWS, columns=COLUMNS, needle=chat_title(b"alpha"))
        h.drain_until_quiet(process, fd, output)
        visible()
        h.send_and_wait(process, fd, output, b"\x02", chat_title(b"alpha"))
        h.drain_until_quiet(process, fd, output)
        assert_hidden(screen(output))
        h.send_and_wait(process, fd, output, b"\x02", b"KEEPERS")
        h.drain_until_quiet(process, fd, output)
        visible()
        close_chat(process, fd, output)

    h.run_terminal_scenario(binary, description="chat portrait yields to short, narrow and hidden roster layouts",
                            interact=interact, http_fixtures=h.keeper_runtime_http_fixtures(), terminal_cols=COLUMNS)


def pixels_follow_conversation(binary: str) -> None:
    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        pictures = png_transfers(bytes(output))
        assert pictures, "chat sent no keeper portrait"
        row, column, alpha = pictures[-1]
        rows = screen(output)
        caption = caption_row(rows, b"alpha")
        assert row == caption + 1, f"pixels at row {row} are not below caption row {caption}"
        assert column == 10, "16-cell portrait is not centered in the 30-cell roster interior"
        assert row + 7 < h.screen_row_of(rows, b"Context"), "portrait crossed the full-width status row"
        assert not mosaic_rows(rows), "Kitty portrait also drew a mosaic"
        assert_chat_intact(rows, b"alpha")
        h.drain_until_quiet(process, fd, output)
        typing_start = len(output)
        draft = b"portrait10"
        for count, key in enumerate(draft, 1):
            h.send_and_wait(process, fd, output, bytes([key]), h.composer_showing(draft[:count]))
        h.drain_until_quiet(process, fd, output)
        typing_transfers = png_transfers(bytes(output[typing_start:]))
        print(f"portrait PNG transfers during {len(draft)} typed characters: {len(typing_transfers)}")
        assert not typing_transfers, "typing below the portrait retransmitted its PNG"
        assert_chat_intact(screen(output), b"alpha")
        h.send_and_wait(process, fd, output, b"\x1b[D", b"Enter:open")
        cursor_start = len(output)
        h.send_and_wait(process, fd, output, b"\x1b[B", h.keeper_row_selected(b"beta"))
        h.drain_until_quiet(process, fd, output)
        caption_row(screen(output), b"alpha")
        assert DELETE not in output[cursor_start:], "moving the roster cursor removed the active chat portrait"
        assert png_transfers(bytes(output))[-1][2] == alpha, "roster cursor retargeted the portrait before chat opened"
        start = len(output)
        h.send_and_wait(process, fd, output, b"\r", chat_title(b"beta"))
        h.drain_until_quiet(process, fd, output)
        beta = png_transfers(bytes(output[start:]))
        assert beta and beta[-1][2] != alpha, "new conversation kept alpha's portrait"
        rows = screen(output)
        assert beta[-1][0] == caption_row(rows, b"beta") + 1
        assert_chat_intact(rows, b"beta")
        assert draft not in b"\n".join(rows.values()), "alpha's draft leaked into beta's conversation"
        h.send_and_wait(process, fd, output, b"\x07", chat_title(b"alpha"))
        h.drain_until_quiet(process, fd, output)
        caption_row(screen(output), b"alpha")
        assert png_transfers(bytes(output))[-1][2] == alpha, "returning to alpha did not restore its portrait"
        assert draft in b"\n".join(screen(output).values()), "alpha's draft was not retained"
        h.write_all(fd, output, b"\x15")
        h.drain_until_quiet(process, fd, output)
        start = len(output)
        h.send_and_wait(process, fd, output, b"\x02", chat_title(b"alpha"))
        h.wait_for_output(process, fd, output, DELETE, start=start, timeout=3.0)
        h.drain_until_quiet(process, fd, output)
        assert_hidden(screen(output))
        assert not png_transfers(bytes(output[output.index(DELETE, start):])), "hidden portrait was placed again"
        close_chat(process, fd, output)

    h.run_terminal_scenario(binary, description="chat PNG portrait follows the open Keeper instead of the roster cursor",
                            interact=interact, http_fixtures=h.keeper_runtime_http_fixtures(),
                            terminal_cols=COLUMNS, preload_input=KITTY_REPLIES)


def no_colour(binary: str) -> None:
    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        assert_hidden(screen(output))
        assert not png_transfers(bytes(output)), "NO_COLOR still transmitted a keeper portrait"
        assert_chat_intact(screen(output), b"alpha")
        close_chat(process, fd, output)

    h.run_terminal_scenario(binary, description="NO_COLOR chat preserves the full roster without a portrait",
                            interact=interact, http_fixtures=h.keeper_runtime_http_fixtures(),
                            terminal_cols=COLUMNS, preload_input=KITTY_REPLIES, extra_env={"NO_COLOR": "1"})


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    mosaic_resizes(binary)
    pixels_follow_conversation(binary)
    no_colour(binary)
    print("tui chat portrait: PASS (3 scenarios)")
