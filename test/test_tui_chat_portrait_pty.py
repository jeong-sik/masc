"""The active conversation's portrait above its roster, through the real TUI.

No model calls: two fixture Keepers let selection and the open chat disagree.
The Kitty case decodes complete PNG transfers, including identity changes;
other cases check the colour fallback and the space returned on small screens.
The running-turn case holds a fixture turn open and counts what the portrait
costs the wire while the rows beside it keep changing.
"""
from __future__ import annotations

import base64
import json
import os
import re
import select
import struct
import sys
import threading
import time
import zlib
from collections.abc import Iterator
from pathlib import Path

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    # The running turn's progress row and the mark that steps on it.
    "bin/masc_tui_answering.ml",
    "bin/masc_tui_keeper_chat_transcript.ml",
    "bin/masc_tui_chat_portrait.ml",
    "bin/masc_tui_keeper_portrait.ml",
    "bin/masc_tui_portrait_view.ml",
    "bin/masc_tui_frame_presenter.ml",
    "bin/masc_tui_graphics.ml",
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_roster_pane.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui.ml",
)

COLUMNS = 150  # Roster fits; the separate Activity pane does not open.
TALL_ROWS = 30
SHORT_ROWS = 15
ROSTER_COLUMNS = 34
CAPTION = "대화 · ".encode()
IMAGE_ID = b"42"
DELETE = b"\x1b_Ga=d,d=I,i=42,q=2\x1b\\"
KITTY_REPLIES = b"\x1b[6;20;10t" + h.GRAPHICS_SUPPORTED_REPLY
PLACED = re.compile(rb"\x1b7\x1b\[(\d+);(\d+)H(.*?)\x1b8", re.S)
CHUNK = re.compile(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\")
# A put names pixels the terminal already holds: no payload, no format.
PUT = re.compile(rb"\x1b_Ga=p,([^;\x1b]*)\x1b\\")
PUT_KEYS = {b"i": IMAGE_ID, b"p": b"1", b"C": b"1", b"r": b"4", b"q": b"2"}
HALF_BLOCKS = "▀▄"
PORTRAIT_ROWS = 4  # Compact chat icon, independently of detail portraits.
ROW_WRITE = re.compile(rb"\x1b\[(\d+);1H\x1b\[0m\x1b\[2K")  # Frame_presenter.append_row
CHAT = "/api/v1/keepers/chat/stream"
PROGRESS = b"IN PROGRESS"
RUNNING_MARKS = tuple(mark.encode() for mark in "◐◓◑◒")  # Masc_tui_answering.running_frames
# Motion steps (150 ms each) the running turn is watched for, and the least
# number of frames that must rewrite a row beside the portrait for the count
# to say anything about it.
MOTION_STEPS = 8
STREAMED_LINES = 12


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
        assert fields.get(b"r") == b"4", "chat icon must reserve four rows"
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
        kind = b""
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


def portrait_put(placement: re.Match[bytes]) -> tuple[int, int] | None:
    """Where a put of the keeper portrait stands, or None for anything else."""
    put = PUT.fullmatch(placement[3])
    if put is None:
        return None
    fields = dict(item.split(b"=", 1) for item in put[1].split(b",") if b"=" in item)
    if fields.get(b"i") != IMAGE_ID:
        return None
    assert fields == PUT_KEYS, f"portrait put is not the transferred placement: {fields!r}"
    return int(placement[1]), int(placement[2])


def portrait_resends(output: bytes, *, row: int, column: int, image: bytes,
                     what: str) -> tuple[list[dict[str, object]], int, int]:
    """Transfers of the unchanged portrait that nothing but a clear explains.

    A clear (ESC [2J) takes every image, and Kitty and Ghostty free the pixels
    with it, so only a transfer brings the picture back -- one transfer for
    each clear, the first after it. Nothing else a frame writes is a reason to
    send the pixels again. A put of the held pixels is counted but allowed: it
    is a few dozen bytes. Returns the evidence for each unexplained transfer,
    the transfers a clear explains, and the puts.
    """
    unexplained: list[dict[str, object]] = []
    after_clear = puts = 0
    previous_transfer_end = 0
    for placement in PLACED.finditer(output):
        put = portrait_put(placement)
        if put is not None:
            assert put == (row, column), f"{what} moved the portrait"
            puts += 1
            continue
        pictures = png_transfers(placement[0])
        if not pictures:
            continue
        for sent_row, sent_column, sent_image in pictures:
            assert (sent_row, sent_column) == (row, column), f"{what} moved the portrait"
            assert sent_image == image, f"{what} changed the conversation's portrait"
        frame_start = output.rfind(h.FRAME_START, 0, placement.start())
        frame = output[frame_start:placement.start()] if frame_start >= 0 else b""
        # A clear that already explained a transfer explains no second one.
        fresh = frame_start >= previous_transfer_end
        previous_transfer_end = placement.end()
        if fresh and h.FULL_REDRAW in frame:
            after_clear += 1
            continue
        # A bounded row summary per transfer, no image payload or screen dump.
        unexplained.append({
            "transfer_offset": placement.start(), "frame_offset": frame_start, "fresh_frame": fresh,
            "rewritten_rows": sorted({int(match[1]) for match in ROW_WRITE.finditer(frame)}),
            "portrait_rows": list(range(row, row + PORTRAIT_ROWS)),
        })
    return unexplained, after_clear, puts


def presentations(output: bytes) -> list[bytes]:
    """Every complete text frame in ``output``, a partial first one left out."""
    frames = []
    start = output.find(h.FRAME_START)
    while start >= 0:
        end = output.find(h.FRAME_END, start)
        if end < 0:
            break
        frames.append(output[start:end + len(h.FRAME_END)])
        start = output.find(h.FRAME_START, end)
    return frames


def written_rows(frame: bytes) -> dict[int, bytes]:
    """The 1-based rows a frame erased and wrote again, with what it wrote."""
    matches = list(ROW_WRITE.finditer(frame))
    return {int(match[1]): frame[match.end():matches[index + 1].start() if index + 1 < len(matches) else len(frame)]
            for index, match in enumerate(matches)}


def motion_steps(output: bytes) -> list[int]:
    """The row of every frame that moved the running turn's mark on a step."""
    steps, last = [], None
    for frame in presentations(output):
        for row, text in written_rows(frame).items():
            mark = next((mark for mark in RUNNING_MARKS if mark in text), None)
            if PROGRESS in text and mark is not None and mark != last:
                steps.append(row)
                last = mark
    return steps


def frames_beside(output: bytes, portrait_rows: set[int]) -> int:
    """Frames that rewrote at least one row the portrait stands on."""
    return sum(1 for frame in presentations(output) if portrait_rows.intersection(written_rows(frame)))


def open_chat(process, fd, output) -> None:
    h.tab_until(process, fd, output, b"MASC Keepers")
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
            assert len(band) >= 4 and all(caption < row <= caption + 8 for row in band), "mosaic escaped its reserved band"
            roster = [row for row, text in rows.items() if b"KEEPERS" in text[:ROSTER_COLUMNS]]
            assert len(roster) == 1 and roster[0] > caption + 8, "conversation icon must precede the selectable roster"
            assert any(b"alpha" in text[:ROSTER_COLUMNS] for row, text in rows.items() if row > roster[0]), "portrait displaced the roster entries"
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
        assert column == 14, "8-cell pixel icon is not centered in the 30-cell roster interior"
        assert row + 7 < h.screen_row_of(rows, b"Context"), "portrait crossed the full-width status row"
        assert not mosaic_rows(rows), "Kitty portrait also drew a mosaic"
        assert_chat_intact(rows, b"alpha")
        assert h.drain_until_quiet(process, fd, output), "chat did not settle before typing measurement"
        typing_start = len(output)
        draft = b"portrait10"
        for count, key in enumerate(draft, 1):
            h.send_and_wait(process, fd, output, bytes([key]), h.composer_showing(draft[:count]))
        assert h.drain_until_quiet(process, fd, output), "chat did not settle after typing measurement"
        typing_output = bytes(output[typing_start:])
        resent, after_clear, puts = portrait_resends(typing_output, row=row, column=column, image=alpha,
                                                     what="typing")
        print(f"portrait during {len(draft)} typed characters: {len(resent)} PNG transfers without a clear, "
              f"{after_clear} after one, {puts} puts; "
              f"frames beside it: {frames_beside(typing_output, set(range(row, row + PORTRAIT_ROWS)))}", flush=True)
        assert not resent, f"typing sent the unchanged portrait's pixels again: {resent[:3]}"
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
        hidden = bytes(output[output.index(DELETE, start):])
        assert not png_transfers(hidden), "hidden portrait was placed again"
        assert not any(portrait_put(placement) for placement in PLACED.finditer(hidden)), "hidden portrait was put back"
        close_chat(process, fd, output)

    h.run_terminal_scenario(binary, description="chat PNG portrait follows the open Keeper instead of the roster cursor",
                            interact=interact, http_fixtures=h.keeper_runtime_http_fixtures(),
                            terminal_cols=COLUMNS, preload_input=KITTY_REPLIES)


def running_turn_keeps_the_portrait(binary: str) -> None:
    """A turn stays running beside the portrait: its mark steps every 150 ms,
    then its reply streams in line by line. The picture itself never changes,
    so none of that may send its pixels again."""
    streaming = threading.Event()
    streamed = threading.Event()
    finishing = threading.Event()
    lines = [f"streamed-{index:02d}" for index in range(1, STREAMED_LINES + 1)]

    def respond(body: bytes) -> h.StreamingHttpResponse:
        events = [json.loads(block.removeprefix(b"data: "))
                  for block in h.keeper_chat_succeeded_response(body).body.split(b"\n\n") if block]
        kinds = [event["type"] for event in events]
        started, content = kinds.index("RUN_STARTED"), kinds.index("TEXT_MESSAGE_CONTENT")
        reply = "\n".join(lines)
        for event in events:
            if event.get("name") == "KEEPER_REPLY_DETAILS":
                event["value"]["reply"] = reply

        def sse(batch: list[dict[str, object]]) -> bytes:
            return b"".join(b"data: " + json.dumps(event).encode() + b"\n\n" for event in batch)

        def chunks() -> Iterator[bytes]:
            yield sse(events[:started + 1])
            if not streaming.wait(timeout=30):
                return
            yield sse(events[started + 1:content])
            for index, line in enumerate(lines):
                yield sse([{**events[content], "delta": ("\n" if index else "") + line}])
                time.sleep(0.15)
            streamed.set()
            if finishing.wait(timeout=30):
                yield sse(events[content + 1:])

        return h.StreamingHttpResponse(chunks)

    def read_until(process, fd, output, done, what: str, timeout: float = 10.0) -> None:
        deadline = time.monotonic() + timeout
        while not done():
            assert process.poll() is None, f"TUI exited while {what}"
            assert time.monotonic() < deadline, f"timed out while {what}"
            select.select([fd], [], [], 0.05)
            h.read_available(fd, output)

    def interact(process, fd, _slave, output, _base):
        try:
            open_chat(process, fd, output)
            # Motion steps are carried by the diagnostic progress row.
            # Select Full explicitly before measuring its redraws.
            h.send_and_wait(process, fd, output, b"\x04\x04", b"tools:full")
            pictures = png_transfers(bytes(output))
            assert pictures, "chat sent no keeper portrait"
            row, column, alpha = pictures[-1]
            portrait_rows = set(range(row, row + PORTRAIT_ROWS))
            h.send_and_wait(process, fd, output, b"steady", h.composer_showing(b"steady"))
            start = len(output)
            h.send_and_wait(process, fd, output, b"\r", PROGRESS)
            read_until(process, fd, output, lambda: len(motion_steps(bytes(output[start:]))) >= MOTION_STEPS,
                       f"watching {MOTION_STEPS} motion steps of the running turn")
            spinning = bytes(output[start:])
            streaming.set()
            read_until(process, fd, output, streamed.is_set, "streaming the reply")
            finishing.set()
            # The mark steps every 150 ms while the turn runs, so quiet is
            # the turn having finished.
            assert h.drain_until_quiet(process, fd, output), "the finished turn kept the screen moving"
            assert PROGRESS not in b"\n".join(screen(output).values()), "the turn is still drawn as running"
            window = bytes(output[start:])
            assert lines[-1].encode() in window, "the streamed reply never reached the screen"
            steps = motion_steps(spinning)
            evidence = {
                "motion_steps": len(steps), "progress_rows": sorted(set(steps)),
                "portrait_rows": sorted(portrait_rows),
                "frames_beside_while_spinning": frames_beside(spinning, portrait_rows),
                "frames_beside_in_turn": frames_beside(window, portrait_rows),
                "full_redraw": h.FULL_REDRAW in window,
            }
            resent, after_clear, puts = portrait_resends(window, row=row, column=column, image=alpha,
                                                         what="running turn")
            evidence.update(resent_without_clear=len(resent), transfers_after_clear=after_clear, puts=puts)
            print("portrait during a running turn: " + json.dumps(evidence, sort_keys=True), flush=True)
            # Without rows beside the picture changing, a zero would say
            # nothing about the picture. The whole turn counts: where the
            # progress row lands is the layout's choice, so its rows are
            # recorded above rather than required beside the picture.
            assert evidence["frames_beside_in_turn"] > 0, f"the turn never repainted the icon's rows: {evidence}"
            assert puts > 0 or evidence["full_redraw"], f"the repainted icon was not restored: {evidence}"
            assert not resent, f"the running turn sent the unchanged portrait's pixels again: {resent[:3]}"
            assert_chat_intact(screen(output), b"alpha")
            close_chat(process, fd, output)
        finally:
            streaming.set()
            finishing.set()

    h.run_terminal_scenario(binary, description="a running turn beside the chat portrait never resends its pixels",
                            interact=interact,
                            http_fixtures={**h.keeper_runtime_http_fixtures(), CHAT: h.RequestHttpResponse(respond)},
                            terminal_cols=COLUMNS, preload_input=KITTY_REPLIES)


def hidden_roster_releases_focus(binary: str, *, resize: bool) -> None:
    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        draft = b"alpha-kept-draft"
        h.send_and_wait(process, fd, output, draft, h.composer_showing(draft))
        h.send_and_wait(process, fd, output, b"\x1b[D", b"Up/Down:move")
        # Leave the roster cursor on beta, distinct from the open conversation.
        # A stale focus would let Enter switch chats and abandon alpha's draft.
        h.write_all(fd, output, b"\x1b[B")
        h.drain_until_quiet(process, fd, output)
        if resize:
            h.resize_and_wait(process, fd, output, rows=TALL_ROWS, columns=109,
                              needle=chat_title(b"alpha"))
        else:
            h.send_and_wait(process, fd, output, b"\x02", chat_title(b"alpha"))
        h.drain_until_quiet(process, fd, output)
        rows = screen(output)
        assert not any(b"KEEPERS" in row for row in rows.values()), "roster is still visible"
        assert draft in b"\n".join(rows.values()), "hiding the roster discarded the draft"
        assert b"Up/Down:move" not in b"\n".join(rows.values()), "hidden roster still owns the footer"
        assert output.rfind(b"\x1b[?25h") > output.rfind(b"\x1b[?25l"), "hidden roster still hides the input cursor"
        h.send_and_wait(process, fd, output, b"-typed", h.composer_showing(draft + b"-typed"))

        def composer_keys():
            # Arrow keys must select command candidates, then Enter must insert
            # the chosen command, without executing it or opening beta.
            h.send_and_wait(process, fd, output, b"\x15/", b"Commands  1/")
            h.send_and_wait(process, fd, output, b"\x1b[B", b"Commands  2/")
            h.send_and_wait(process, fd, output, b"\x1b[A", b"Commands  1/")
            h.send_and_wait(process, fd, output, b"\x15/se", b"Commands  1/1")
            h.send_and_wait(process, fd, output, b"\r", h.composer_showing(b"/settings"))
            h.drain_until_quiet(process, fd, output)
            assert chat_title(b"alpha") in b"\n".join(screen(output).values()), "Enter left alpha's composer"

        composer_keys()
        if resize:
            h.resize_and_wait(process, fd, output, rows=TALL_ROWS, columns=COLUMNS,
                              needle=chat_title(b"alpha"))
        else:
            h.send_and_wait(process, fd, output, b"\x02", b"KEEPERS")
        h.drain_until_quiet(process, fd, output)
        assert any(b"KEEPERS" in row for row in screen(output).values()), "roster did not return"
        # Showing it again must not restore the former invisible focus.
        composer_keys()
        h.write_all(fd, output, b"\x15")
        h.drain_until_quiet(process, fd, output)
        close_chat(process, fd, output)

    reason = "resize" if resize else "Ctrl-B"
    h.run_terminal_scenario(binary, description=f"chat roster {reason} hands focus back to the composer",
                            interact=interact, http_fixtures=h.keeper_runtime_http_fixtures(),
                            terminal_cols=COLUMNS)


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
    running_turn_keeps_the_portrait(binary)
    no_colour(binary)
    hidden_roster_releases_focus(binary, resize=True)
    hidden_roster_releases_focus(binary, resize=False)
    print("tui chat portrait: PASS (6 scenarios)")
