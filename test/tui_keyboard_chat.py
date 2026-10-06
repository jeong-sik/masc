from __future__ import annotations

import copy
import json
import os
import re
import struct
import subprocess
import threading
import time
import zlib
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from tui_keyboard_harness import (
    CONSOLE_DIAGNOSTIC,
    CSI_RE,
    CURSOR_RE,
    FRAME_END,
    FULL_REDRAW,
    GatedHttpResponse,
    HttpFixtures,
    HttpRequests,
    HttpResponse,
    Interaction,
    RawHttpResponse,
    RequestHttpResponse,
    SequencedHttpResponse,
    StreamingHttpResponse,
    assert_message_input_frame,
    autonomous_turn_history_fixture,
    composer_showing,
    context_inspector_fixtures,
    drain_until_quiet,
    end_of_needle,
    escape_to_keeper_detail,
    find_needle,
    frame_containing,
    keeper_row_selected,
    keeper_runtime_http_fixtures,
    palette_go,
    read_available,
    resize_and_wait,
    run_terminal_scenario,
    screen_header,
    screen_row_of,
    screen_rows,
    screen_text,
    select_keeper_row,
    send_and_wait,
    tab_until,
    wait_for_fixture_event,
    wait_for_http_request,
    wait_for_output,
    wait_for_terminal_input_consumed,
    write_all,
)
from tui_keyboard_observer import (
    observer_http_fixtures,
)
from tui_keyboard_tools import (
    skills_usage_clarity_http_fixtures,
    skills_usage_clarity_interaction,
)


def keeper_message_missing_target_interaction(requests: HttpRequests) -> Interaction:
    draft = b"beta-periodic-draft-29453"
    chat_path = "/api/v1/keepers/chat/stream"

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        # j on a roster that has not arrived moves nothing and redraws
        # nothing, so the wait for beta's band times out. Ask for the row.
        select_keeper_row(process, master_fd, output, b"beta")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
        send_and_wait(process, master_fd, output, draft, composer_showing(draft))

        read_available(master_fd, output)
        refresh_start = len(output)
        keeper_path = Path(base_path) / ".masc" / "keepers" / "beta.json"
        keeper_path.unlink()
        unavailable = b"Keeper beta is no longer registered"
        wait_for_output(
            process,
            master_fd,
            output,
            unavailable,
            start=refresh_start,
            timeout=3.0,
        )
        unavailable_end = output.find(unavailable, refresh_start) + len(unavailable)
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=unavailable_end,
            timeout=3.0,
        )

        refreshed = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        refreshed_plain = CSI_RE.sub(b"", refreshed)
        for expected in (
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            unavailable,
            b"Enter:disabled (Keeper unavailable)",
            b"> " + draft,
        ):
            if expected not in refreshed_plain:
                raise AssertionError(
                    f"periodic refresh lost Keeper message state {expected!r}: "
                    f"{refreshed!r}"
                )
        if b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat" in refreshed_plain:
            raise AssertionError(
                f"periodic refresh retargeted the draft to alpha: {refreshed!r}"
            )

        send_and_wait(
            process,
            master_fd,
            output,
            b"\rx",
            composer_showing(draft + b"x"),
        )
        if any(path == chat_path for path, _body in requests):
            raise AssertionError(
                "Enter sent a message after the target Keeper disappeared"
            )

        keepers = send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b",
            screen_header(b"MASC Keepers", b" (1)"),
        )
        keepers_frame = frame_containing(keepers, screen_header(b"MASC Keepers", b" (1)"))
        if b"Keepers \xe2\x96\xb8 alpha" in CSI_RE.sub(b"", keepers_frame):
            raise AssertionError(
                f"Esc opened alpha detail after beta disappeared: {keepers!r}"
            )
        os.write(master_fd, b"q")

    return interact


def keeper_message_unreliable_roster_interaction(
    requests: HttpRequests,
) -> Interaction:
    draft = b"beta-unreliable-draft-29453"
    chat_path = "/api/v1/keepers/chat/stream"

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        # j on a roster that has not arrived moves nothing and redraws
        # nothing, so the wait for beta's band times out. Ask for the row.
        select_keeper_row(process, master_fd, output, b"beta")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
        send_and_wait(process, master_fd, output, draft, composer_showing(draft))

        read_available(master_fd, output)
        refresh_start = len(output)
        alpha_path = Path(base_path) / ".masc" / "keepers" / "alpha.json"
        alpha_path.write_text("{", encoding="utf-8")
        wait_for_output(
            process,
            master_fd,
            output,
            CONSOLE_DIAGNOSTIC,
            start=refresh_start,
            timeout=3.0,
        )
        unreliable = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        unreliable_plain = CSI_RE.sub(b"", unreliable)
        for expected in (
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            b"Keeper roster is unavailable",
            b"Enter:disabled (roster unavailable)",
            b"> " + draft,
        ):
            if expected not in unreliable_plain:
                raise AssertionError(
                    f"unreliable roster did not block Keeper message {expected!r}: "
                    f"{unreliable!r}"
                )

        send_and_wait(
            process,
            master_fd,
            output,
            b"\rx",
            composer_showing(draft + b"x"),
        )
        if any(path == chat_path for path, _body in requests):
            raise AssertionError("unreliable Keeper roster allowed a message POST")
        # One Escape, and it lands on the Keepers list rather than on a
        # keeper's detail: a detail is drawn from the roster, and the roster
        # read is the thing this walk broke. Walking to alpha's detail first
        # spent all four presses looking for a title the pane was never going
        # to draw and left the TUI out on Overview.
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


BRACKETED_PASTE_ON = b"\x1b[?2004h"
PASTE_START = b"\x1b[200~"
PASTE_END = b"\x1b[201~"


def paste_into_a_field_interaction() -> Interaction:
    """A paste goes into the field that is taking characters.

    Seven fields take typed characters; paste used to name four, and row
    search and the command palette were not among them. Their text went to
    the chat draft behind the surface -- invisible there, and on a surface
    with no keeper selected, nowhere at all. The operator saw paste work on
    one screen and do nothing on the next."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(
            process, master_fd, output, BRACKETED_PASTE_ON, start=0, timeout=5.0
        )
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")

        # Row search draws its query in the footer, so the pasted characters
        # are asserted where they landed rather than through what they did.
        send_and_wait(process, master_fd, output, b"/", b"MASC Keepers")
        send_and_wait(
            process,
            master_fd,
            output,
            PASTE_START + b"alph" + PASTE_END,
            b"/alph",
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")

        # The palette runs what it was given. Its first entry with an empty
        # query is "settings", so landing on Lanes is only possible if the
        # pasted characters reached the query: a dropped paste sends the
        # operator to Config instead.
        send_and_wait(
            process,
            master_fd,
            output,
            b":" + PASTE_START + b"go lanes" + PASTE_END + b"\r",
            b"MASC Lanes",
        )

        # A board post is written in its own draft, not in the chat composer,
        # and it holds many lines: the paste goes in whole. CR is what a
        # terminal writes for a break in pasted text, which is the byte that
        # would otherwise have been Return.
        palette_go(process, master_fd, output, b"go board", b"MASC Board")
        send_and_wait(process, master_fd, output, b"w", b"MASC Board")
        send_and_wait(
            process,
            master_fd,
            output,
            PASTE_START + b"pasted board line\rsecond board line" + PASTE_END,
            b"second board line",
        )
        # Esc arms the draft's send-or-discard; d throws it away and leaves
        # the pane, where q is draft text rather than quit.
        #
        # The armed footer names more than those two -- editing in $EDITOR and
        # cycling the hearth sit between them -- so the two keys this step is
        # about are matched with what may come between, the way the tool lane
        # needle tolerates padding. A literal "s:send  d:discard" pinned a
        # footer that had since grown, and starved.
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b",
            re.compile(rb"s:send" + rb"[\x1b\x20-\x7e]*?" + rb"d:discard"),
        )
        send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        os.write(master_fd, b"q")

    return interact


def bracketed_paste_interaction(requests: HttpRequests) -> Interaction:
    """A multi-line paste is one draft, not one message per line.

    Without the mode the terminal delivers a paste as the keys it looks like,
    so each newline in it is Return. The three lines below would be three
    sends -- and while a turn was running, three queued fragments."""

    # A terminal writes CR for a line break in pasted text -- the same byte
    # Return sends, which is exactly why a paste without this mode is one
    # message per line. Pasting the shape that breaks is the point.
    on_the_wire = b"first line\rsecond line\r- https://example.invalid/a?b=1"
    expected_draft = "first line\nsecond line\n- https://example.invalid/a?b=1"

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The mode has to be on before a paste can arrive as a paste. Asserted
        # on the stream rather than inferred from the behaviour below: a
        # terminal that never saw the enable would deliver Return, and the
        # difference between "the enable was not written" and "the reader
        # mishandled it" is the thing this pins down.
        wait_for_output(
            process, master_fd, output, BRACKETED_PASTE_ON, start=0, timeout=5.0
        )

        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        frame = send_and_wait(
            process,
            master_fd,
            output,
            PASTE_START + on_the_wire + PASTE_END,
            b"example.invalid",
        )
        plain = CSI_RE.sub(b"", frame)
        for line in (b"first line", b"second line", b"- https://example.invalid"):
            if line not in plain:
                raise AssertionError(f"the draft lost {line!r}: {plain!r}")

        # Three lines, one draft: nothing was sent and nothing is queued.
        posted = [path for path, _ in requests if path.endswith("/chat/stream")]
        if posted:
            raise AssertionError(
                f"a pasted newline was taken as Return: {posted!r}"
            )
        if b"queued 1" in plain or b"(sending " in plain:
            raise AssertionError(f"the paste dispatched something: {plain!r}")

        # Enter still sends, and it sends the whole thing at once.
        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != expected_draft:
            raise AssertionError(
                f"the keeper was sent something other than what was pasted: "
                f"{message!r}"
            )
        # Chat opened from detail, so Esc goes back there first.
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def word_delete_interaction(requests: HttpRequests) -> Interaction:
    """Ctrl-W and Alt+Backspace delete the word behind the composer cursor.

    A chat draft answers two readline muscle memories: Ctrl-W rubs out the
    last word, and Alt+Backspace -- ESC DEL on the wire -- does the same.
    Without a binding Ctrl-W fell through to a no-op, and ESC DEL was
    swallowed as a bare Esc: the draft stayed whole and the chat closed
    under the typist's thumb."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(
            process, master_fd, output, BRACKETED_PASTE_ON, start=0, timeout=5.0
        )
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        # Ctrl-W takes the last word and keeps the separator before it: the
        # draft reads "hello ", and the caret ends one cell past it. The
        # composer row is all a draft edit repaints, so the caret's column is
        # where "kept the separator" can be told from "ate it": 13 is the
        # prompt plus "hello ", 12 is what "hello" would give.
        send_and_wait(process, master_fd, output, b"hello world", b"hello world")
        frame = send_and_wait(process, master_fd, output, b"\x17", b"hello")
        plain = CSI_RE.sub(b"", frame)
        if b"hello world" in plain:
            raise AssertionError(f"Ctrl-W left the whole draft: {plain!r}")
        if b"hello" not in plain:
            raise AssertionError(f"Ctrl-W took more than the word: {plain!r}")
        cursor = CURSOR_RE.search(frame)
        if cursor is None or cursor.group(2) != b"13":
            raise AssertionError(
                f"Ctrl-W did not stop after the kept separator: {frame!r}"
            )

        # Alt+Backspace arrives as ESC DEL: delete-word-back like Ctrl-W, not
        # Esc. A draft edit does not repaint the breadcrumb, so the proof the
        # chat stayed open is that the next letters still land in the
        # composer -- on the detail surface they would bind to keys instead.
        os.write(master_fd, b"\x1b\x7f")
        frame = send_and_wait(process, master_fd, output, b"still here", b"still here")
        plain = CSI_RE.sub(b"", frame)
        if b"hello" in plain:
            raise AssertionError(f"Alt+Backspace left the draft: {plain!r}")

        # Nothing was sent while the draft was being edited.
        posted = [path for path, _ in requests if path.endswith("/chat/stream")]
        if posted:
            raise AssertionError(f"an edit dispatched something: {posted!r}")

        # Enter still sends what survived the editing.
        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "still here":
            raise AssertionError(f"the keeper was sent {message!r}")
        # Chat opened from detail, so Esc goes back there first.
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


GRAPHICS_QUERY_ID = 31
GRAPHICS_SUPPORTED_REPLY = b"\x1b_Gi=%d;OK\x1b\\" % GRAPHICS_QUERY_ID
IMAGE_NAME = "shot.png"


def seed_image_workspace(base_path: str) -> None:
    # A real 8x8 PNG rather than arbitrary bytes: the TUI hands the file
    # straight to the terminal, and a scenario that passed on nonsense would
    # not have shown that a picture can make the trip.
    def chunk(kind: bytes, body: bytes) -> bytes:
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    width = height = 8
    raw = b"".join(b"\x00" + bytes([255, 0, 0, 255] * width) for _ in range(height))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )
    Path(base_path, IMAGE_NAME).write_bytes(png)


def image_view_interaction() -> Interaction:
    """A terminal that says it draws pictures gets one, and gets it taken away.

    The reply to the capability query is preloaded, so this scenario is a
    terminal that answers. What a terminal that stays silent does is the other
    half, asserted below by asking for an image it cannot be given."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        # Asked before the first frame, so it is already on the stream.
        for expected in (b"\x1b_G", b"i=%d" % GRAPHICS_QUERY_ID, b"a=q"):
            if expected not in output:
                raise AssertionError(
                    f"the capability query never went out; missing {expected!r}"
                )

        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        path = str(Path(base_path, IMAGE_NAME))
        command = f"/image {path}".encode()
        # The 100-column fixture leaves 92 cells for the draft. Long Dune
        # sandbox paths therefore draw the composer's omission marker and
        # newest tail, while Enter still submits the complete buffer.
        # One cell for the marker, 91 for the tail -- three bytes, one cell.
        visible_command = (
            command if len(command) <= 92 else b"\xe2\x80\xa6" + command[-91:]
        )
        send_and_wait(
            process,
            master_fd,
            output,
            command,
            composer_showing(visible_command),
        )

        read_available(master_fd, output)
        drawn_from = len(output)
        os.write(master_fd, b"\r")
        wait_for_output(
            process, master_fd, output, b"a=T", start=drawn_from, timeout=5.0
        )
        drawn = bytes(output[drawn_from:])
        for expected in (b"\x1b_G", b"f=100", b"a=T"):
            if expected not in drawn:
                raise AssertionError(
                    f"the image was not placed; missing {expected!r}: {drawn!r}"
                )

        # The terminal keeps a picture in its own layer, so leaving has to say
        # so explicitly; clearing the screen does not remove one.
        read_available(master_fd, output)
        dismissed_from = len(output)
        os.write(master_fd, b" ")
        wait_for_output(
            process, master_fd, output, b"a=d", start=dismissed_from, timeout=5.0
        )

        # Back on the frame, and the space that dismissed the picture is not
        # also a character in the draft.
        wait_for_output(
            process,
            master_fd,
            output,
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            start=dismissed_from,
            timeout=5.0,
        )

        # Short on purpose: every character typed into the composer is a
        # frame, and a long path spends the scenario's patience on redraws
        # rather than on the thing being asserted.
        missing = b"/image /nope.png"
        send_and_wait(process, master_fd, output, missing, composer_showing(missing))
        send_and_wait(process, master_fd, output, b"\r", b"No such file")
        # The step that did not work is the operator's, not the keeper's: it
        # reads on the footer for a moment and leaves no row in the
        # conversation.
        drain_until_quiet(process, master_fd, output)
        rows = screen_rows(bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        footer = max(row for row, text in rows.items() if text.strip())
        saying = [row for row, text in rows.items() if b"No such file" in text]
        if saying != [footer]:
            raise AssertionError(
                f"the failed /image is not the footer alone (rows {saying}, footer {footer}): "
                f"{screen_text(bytes(output))!r}"
            )

        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def paste_spill_interaction(requests: HttpRequests) -> Interaction:
    """A paste too big for the composer shows as one line and is sent whole.

    The composer is five rows. Four hundred lines in it is a draft the
    operator cannot read, and a draft they cannot read is a message they
    cannot check. The text is kept and goes back in on the way out."""

    pasted = "\r".join(f"line {index}" for index in range(400))
    expected = "\n".join(f"line {index}" for index in range(400))

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        read_available(master_fd, output)
        start = len(output)
        write_all(master_fd, output, PASTE_START + pasted.encode() + PASTE_END)
        wait_for_output(process, master_fd, output, b"[pasted ", start=start, timeout=10.0)
        frame = frame_containing(bytes(output[start:]), b"[pasted ")
        plain = CSI_RE.sub(b"", frame)
        if b"400 line(s)" not in plain:
            raise AssertionError(f"the placeholder does not say the size: {plain!r}")
        # The point of the placeholder: the pasted text is not in the composer.
        if b"line 399" in plain:
            raise AssertionError(f"the draft still flooded: {plain!r}")

        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != expected:
            head = "" if message is None else message[:80]
            raise AssertionError(
                f"the keeper was sent the placeholder, not the paste: {head!r}"
            )

        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def seed_playground_workspace(base_path: str) -> None:
    """Give alpha the directory a Docker keeper reads its files from.

    A keeper reads paths relative to its own sandbox root, and the root the
    profile names is the one that has to exist: a Docker keeper's is
    .masc/playground/docker/<name>/. Seeding .masc/playground/<name>/
    instead leaves the declared root absent, and the TUI then has nowhere to
    write -- it falls back to sending the text, and no file is written at
    all."""
    Path(base_path, ".masc", "config", "keepers").mkdir(parents=True, exist_ok=True)
    Path(base_path, ".masc", "config", "keepers", "alpha.toml").write_text(
        '[keeper]\nsandbox_profile = "docker"\nsandbox_image = "base"\n',
        encoding="utf-8"
    )
    Path(base_path, ".masc", "playground", "docker", "alpha").mkdir(
        parents=True, exist_ok=True
    )


def paste_to_file_interaction(requests: HttpRequests) -> Interaction:
    """A spilled paste is written where the keeper can read it, and the
    message names the file instead of carrying the text."""

    pasted = "\r".join(f"line {index}" for index in range(400))
    expected_file = "\n".join(f"line {index}" for index in range(400))

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )

        read_available(master_fd, output)
        start = len(output)
        write_all(master_fd, output, PASTE_START + pasted.encode() + PASTE_END)
        wait_for_output(process, master_fd, output, b"[pasted ", start=start, timeout=10.0)

        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message") or ""

        playground = Path(base_path, ".masc", "playground", "docker", "alpha")
        written = sorted(playground.glob("pasted-*.txt"))
        if len(written) != 1:
            raise AssertionError(
                f"expected one file in the keeper's directory, found {written!r}"
            )
        if written[0].read_text(encoding="utf-8") != expected_file:
            raise AssertionError("the file is not what was pasted")

        # The message points at the file rather than carrying the text: that
        # is the whole reason for writing one.
        if written[0].name not in message:
            raise AssertionError(f"the message does not name the file: {message!r}")
        if "line 399" in message:
            raise AssertionError(
                f"the message carried the text as well as the file: {message[:120]!r}"
            )

        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def keeper_chat_succeeded_response(request_body: bytes) -> RawHttpResponse:
    request = json.loads(request_body)
    request_id = request.get("request_id")
    keeper_name = request.get("name")
    message = request.get("message")
    run_id = f"keeper-operation-run-{request_id}"
    message_id = f"keeper-operation-message-{request_id}"
    reply = f"reply-{message}"
    thread_id = f"keeper:{keeper_name}"
    events = [
        {
            "type": "CUSTOM",
            "threadId": "default",
            "timestamp": 1.0,
            "name": "KEEPER_CHAT_OPERATION_ACCEPTED",
            "value": {
                "operation_id": request_id,
                "state": "Queued",
                "queued_count": 0,
            },
        },
        {
            "type": "RUN_STARTED",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
        },
        {
            "type": "TEXT_MESSAGE_START",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "messageId": message_id,
            "role": "assistant",
        },
        {
            "type": "TEXT_MESSAGE_CONTENT",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "messageId": message_id,
            "delta": reply,
        },
        {
            "type": "CUSTOM",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "name": "KEEPER_REPLY_DETAILS",
            "value": {
                "reply": reply,
                "turn_outcome": "visible_reply",
                "turn_ref": "trace-pty#1",
            },
        },
        {
            "type": "TEXT_MESSAGE_END",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "messageId": message_id,
        },
        {
            "type": "RUN_FINISHED",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
        },
    ]
    return RawHttpResponse(
        200,
        "".join(f"data: {json.dumps(event)}\n\n" for event in events).encode(),
        content_type="text/event-stream",
    )


ERROR_DETAIL_REASON = (
    b"Provider stream parse failed: json decoder rejected nested payload "
    b"at byte 8192; exact terminal detail survives wrapping"
)
# The whole row the pane draws for the failure: its badge, then the complete
# detail, in order. Checked as one phrase so a detail missing its middle, or
# drawn with its end above its start, does not pass on its two ends.
ERROR_DETAIL_ROW = b"ERROR Keeper turn failed: " + ERROR_DETAIL_REASON
ERROR_DETAIL_TAIL = b"exact terminal detail survives wrapping"
# The tail as it may arrive on the wire: wrapped at any of its spaces, with
# the row's padding and the next row's cursor move between the words. Where
# the wrap falls depends on the body width, which the speaker column sets,
# so a needle that requires the phrase on one row pins the column instead
# of the detail. The gap between two words is a row's padding and cursor
# move, or a whole redrawn row when the two arrive in different frames, so
# it is bounded at a screen's width of bytes rather than a line's.
ERROR_DETAIL_TAIL_WRAPPED = re.compile(
    b".{0,4000}?".join(re.escape(word) for word in ERROR_DETAIL_TAIL.split()),
    re.DOTALL,
)


def unwrapped(plain: bytes) -> bytes:
    """Screen text with the chat rows' chrome read as blanks -- the turn
    rail's box-drawing glyphs (U+2500..U+257F) down the left margin -- and
    every run of blanks (a wrap's padding, the next row's indent) read as
    one space, so a phrase wrapped across rows compares equal to the
    phrase."""
    without_rail = re.sub(rb"\xe2[\x94\x95][\x80-\xbf]", b" ", plain)
    return re.sub(rb"\s+", b" ", without_rail)


def keeper_chat_failed_response(request_body: bytes) -> RawHttpResponse:
    request = json.loads(request_body)
    request_id = request.get("request_id")
    keeper_name = request.get("name")
    run_id = f"keeper-operation-run-{request_id}"
    thread_id = f"keeper:{keeper_name}"
    reason = ERROR_DETAIL_REASON.decode()
    events = [
        {
            "type": "CUSTOM",
            "threadId": "default",
            "timestamp": 1.0,
            "name": "KEEPER_CHAT_OPERATION_ACCEPTED",
            "value": {
                "operation_id": request_id,
                "state": "Queued",
                "queued_count": 0,
            },
        },
        {
            "type": "RUN_STARTED",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
        },
        {
            "type": "RUN_ERROR",
            "threadId": thread_id,
            "timestamp": 1.0,
            "runId": run_id,
            "message": reason,
        },
    ]
    return RawHttpResponse(
        200,
        "".join(f"data: {json.dumps(event)}\n\n" for event in events).encode(),
        content_type="text/event-stream",
    )


def keeper_chat_error_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process, master_fd, output, rows=24, columns=100, needle=b"MASC Dashboard"
        )
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"c", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        send_and_wait(process, master_fd, output, b"trigger-error", b"trigger-error")
        send_and_wait(
            process, master_fd, output, b"\r", ERROR_DETAIL_TAIL_WRAPPED
        )
        plain = unwrapped(screen_text(bytes(output)))
        if unwrapped(ERROR_DETAIL_ROW) not in plain:
            raise AssertionError(
                "the Keeper error row did not carry its badge and whole detail "
                f"in order: {plain!r}"
            )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


class AtomicChatFixture:
    """A held server turn with durable admissions and a separately gated Esc ack.

    Events, rather than model completion or a guessed sleep, release each phase.
    The real TUI runs against this wire fixture; Owner/SQLite execution is tested
    by the OCaml suites, not simulated as a claimed production success here.
    """

    def __init__(self, *, first_working: bool = False,
                 no_control_token: bool = False,
                 hold_first_acceptance: bool = False,
                 retained_after_resume_message: str | None = None) -> None:
        self.first_working = first_working
        self.no_control_token = no_control_token
        self.hold_first_acceptance = hold_first_acceptance
        self.retained_after_resume_message = retained_after_resume_message
        self.resume_confirmed = False
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.run_next_calls = 0
        self.interrupt_requests: list[dict[str, Any]] = []
        self.release = threading.Event()
        self.interrupted = threading.Event()
        self.release_interrupt = threading.Event()
        self.old_poll_seen = threading.Event()
        self.first_post_received = threading.Event()
        self.release_first_acceptance = threading.Event()
        self.received: list[dict[str, Any]] = []
        self.submitted: list[dict[str, Any]] = []
        self.admitted = threading.Condition(self.lock)
        self.edited = threading.Event()
        self.paused = False
        self.token = "control-before-stop"
        self.turn_token = "9dd7c86d-0ca9-4a91-a24f-4d57085f0372"
        self.operations: list[dict[str, Any]] = []
        self.fixtures: HttpFixtures = {
            "/api/v1/keepers/turns": self.turns,
            "/api/v1/keepers/chat/stream": RequestHttpResponse(self.stream),
            "/api/v1/keepers/turn/interrupt": RequestHttpResponse(self.interrupt),
            "/api/v1/keepers/turn/run-next": RequestHttpResponse(self.unexpected_run_next),
            "/api/v1/keepers/alpha/directive": RequestHttpResponse(self.directive),
            "/api/v1/keepers/alpha/waiting-inventory": self.inventory,
            "/api/v1/keepers/alpha/chat/operations?state=queued": self.queue,
        }

    def turns(self) -> HttpResponse:
        if self.interrupted.is_set() and not self.release_interrupt.is_set():
            self.old_poll_seen.set()
        return 200, {"schema": "masc.keeper_turns.v1", "keepers": [{
            "keeper_name": "alpha", "status": "ok",
            "chat_control_token": None if self.no_control_token else self.token,
            "turn": None if self.release.is_set() else {
                "lane": "autonomous", "started_at_unix": self.started_at,
                "interrupt_token": self.turn_token,
                "preview": {"text_tail": "Atomic fixture ready", "last_tool": None,
                            "status_text": "waiting for cooperative settlement", "updated_at_unix": self.started_at},
            },
        }]}

    def inventory(self) -> HttpResponse:
        return 200, {"keepers": [{"state": "busy", "paused": self.paused,
            "waiting_on": [{"source": "direct_chat", "what": "Accepted messages waiting for the held turn",
                            "next_action": "settle current turn", "detail": {}}]}]}

    def queue(self) -> HttpResponse:
        with self.lock:
            return 200, {"operations": list(self.operations)}

    def stream(self, body: bytes) -> StreamingHttpResponse:
        request = json.loads(body)
        with self.lock:
            self.received.append(request)
            first_post = len(self.received) == 1
        if first_post:
            self.first_post_received.set()
            if self.hold_first_acceptance and not self.release_first_acceptance.wait(timeout=10):
                raise AssertionError("first admission receipt was never released")
        intent = request.get("admission_intent")
        # The saved Enter predates the stop receipt; resume sends that original
        # request without inventing a new interactive admission intent.
        resumed_retained = (
            self.resume_confirmed
            and request.get("message") == self.retained_after_resume_message
            and intent is None
        )
        if self.no_control_token:
            if intent is not None:
                raise AssertionError(f"Enter without a control token must queue only: {request!r}")
        elif not resumed_retained:
            if not isinstance(intent, dict) or intent.get("kind") != "interactive":
                raise AssertionError(f"ordinary Enter lost interactive admission: {request!r}")
            if intent.get("control_token") != self.token:
                raise AssertionError(f"Enter used stale control authority: {request!r}")
        # Enter admits the line in queue order and names nothing to stop. Until
        # 2026-09-14 it bound the working direct execution, else the observed
        # autonomous turn, as the interrupt target, so every line typed while
        # the Keeper worked cancelled that work. Esc still targets the exact
        # turn (see [interrupt] below); Enter must not.
        if isinstance(intent, dict) and (
            intent.get("interrupt_token") is not None
            or intent.get("operation_id") is not None
        ):
            raise AssertionError(f"Enter named a turn to stop; it must only admit to the queue: {request!r}")
        with self.admitted:
            self.submitted.append(request)
            sequence = len(self.submitted)
            operation = {
                "operation_id": request["request_id"], "sequence": str(sequence),
                "source": {"schema": "masc.keeper_chat_operation.source.v2", "submitted_by": "masc-tui",
                    "thread_id": "keeper:alpha", "continuation_channel": {"kind": "dashboard", "thread_id": "keeper:alpha"},
                    "surface": {"kind": "dashboard"}, "channel": "", "channel_user_id": "", "channel_user_name": "",
                    "channel_workspace_id": "", "conversation_id": None, "external_message_id": None,
                    "workspace_id": None, "extra_mentions": [], "sender_keeper": None,
                    "user_row_origin": "needs_append"},
                # The server keeps the input as submitted, so a later /queue edit
                # reads the staged media and attachments back from here.
                "input": {"schema": "masc.keeper_chat_operation.input.v1", "message": request["message"],
                    "user_blocks": request.get("user_blocks", []), "turn_instructions": None,
                    "surface_context": None, "attachments": request.get("attachments", [])},
            }
            self.operations.append(operation)
            path = "/api/v1/keepers/alpha/chat/operations/" + request["request_id"]
            self.fixtures[path] = lambda: (200, operation)
            self.fixtures[path + "/edit"] = RequestHttpResponse(lambda body: self.edit(operation, body))
            self.fixtures[f"/api/v1/keepers/alpha/chat/operations?state=queued&after_sequence={sequence}"] = (200, {"operations": []})
            self.admitted.notify_all()
        response = keeper_chat_succeeded_response(body)
        blocks = [block for block in response.body.split(b"\n\n") if block]
        acceptance = json.loads(blocks[0].removeprefix(b"data: "))
        working = self.first_working and sequence == 1
        acceptance["value"]["state"] = "Running" if working else "Queued"
        acceptance["value"]["queued_count"] = sequence - 1 if self.first_working else sequence
        if self.no_control_token or resumed_retained:
            acceptance["value"].pop("interactive", None)
        else:
            acceptance["value"]["interactive"] = {
                "outcome": "applied", "chat_control_token": self.token,
                "signalled": not self.paused, "resumed": self.paused, "interrupt_error": None,
            }
        self.paused = False

        def chunks() -> Iterator[bytes]:
            prefix = f"data: {json.dumps(acceptance)}\n\n".encode()
            if working:
                prefix += blocks[1] + b"\n\n"
            yield prefix
            if not self.release.wait(timeout=30):
                raise AssertionError("interaction never released the held server turn")
            # The original request id is retained even when queued text is edited.
            terminal = keeper_chat_succeeded_response(json.dumps({**request, "message": operation["input"]["message"]}).encode())
            yield b"\n\n".join(terminal.body.split(b"\n\n")[2 if working else 1:])

        return StreamingHttpResponse(chunks)

    def edit(self, operation: dict[str, Any], body: bytes) -> HttpResponse:
        operation["input"] = json.loads(body)["input"]
        self.edited.set()
        return 200, operation

    def interrupt(self, body: bytes) -> HttpResponse:
        request = json.loads(body)
        if self.release.is_set():
            # A periodic preview may outlive the completed fixture execution.
            # Refuse that stale target without pretending to signal or pause it.
            return 409, {"error": "target is no longer current", "signalled": False,
                         "paused": False, "chat_control_token": self.token}
        if self.first_working and self.submitted:
            expected = self.submitted[0]["request_id"]
            if request.get("request_id") != expected or request.get("interrupt_token") is not None:
                raise AssertionError(f"Esc ignored the locally working direct execution {expected}: {request!r}")
        elif request.get("interrupt_token") != self.turn_token:
            raise AssertionError(f"Esc targeted another turn: {request!r}")
        with self.lock:
            self.interrupt_requests.append(request)
        self.paused = True
        self.interrupted.set()
        if not self.release_interrupt.wait(timeout=20):
            raise AssertionError("interaction never acknowledged Esc")
        self.token = "control-after-stop"
        target = ({"request_id": request["request_id"]} if "request_id" in request
                  else {"interrupt_token": self.turn_token})
        return 200, {"signalled": True, "paused": True, **target, "chat_control_token": self.token}

    def directive(self, body: bytes) -> HttpResponse:
        request = json.loads(body)
        if request.get("action") != "resume":
            raise AssertionError(f"retained input expected explicit resume: {request!r}")
        self.paused = False
        self.resume_confirmed = True
        return 200, {"ok": True}

    def unexpected_run_next(self, body: bytes) -> HttpResponse:
        self.run_next_calls += 1
        raise AssertionError(f"ordinary Enter must not require run-next: {body!r}")


def open_atomic_chat(process: subprocess.Popen[bytes], master_fd: int, output: bytearray) -> None:
    resize_and_wait(process, master_fd, output, rows=40, columns=120, needle=b"MASC Dashboard")
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    # Establish the detail return target used by the scenario's Escape checks.
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
    # Seeing the preview proves the same observer response carrying the control
    # token has reached the UI before the first Enter.
    wait_for_output(process, master_fd, output, "기존 작업 처리 중".encode(), start=0, timeout=10)


def wait_for_atomic_admissions(process: subprocess.Popen[bytes], master_fd: int,
                               output: bytearray, fixture: AtomicChatFixture, count: int) -> None:
    deadline = time.monotonic() + 10
    while len(fixture.submitted) < count:
        read_available(master_fd, output)
        if process.poll() is not None or time.monotonic() >= deadline:
            raise AssertionError(f"only {len(fixture.submitted)} of {count} messages reached server admission")
        with fixture.admitted:
            fixture.admitted.wait(timeout=0.02)


def chat_queue_interaction(fixture: AtomicChatFixture) -> Interaction:
    """Plain Enter admits every message; /queue edits durable pending input."""
    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            open_atomic_chat(process, master_fd, output)
            for index, text in enumerate((b"queued-one", b"queued-two"), 1):
                send_and_wait(process, master_fd, output, text, composer_showing(text))
                os.write(master_fd, b"\r")
                wait_for_atomic_admissions(process, master_fd, output, fixture, index)
            if fixture.release.is_set():
                raise AssertionError("messages were admitted only after model completion")
            if [item["message"] for item in fixture.submitted] != ["queued-one", "queued-two"]:
                raise AssertionError(f"accepted message order changed: {fixture.submitted!r}")
            if len({item["request_id"] for item in fixture.submitted}) != 2:
                raise AssertionError("distinct Enter messages lost their durable identities")
            send_and_wait(process, master_fd, output, b"/queue", composer_showing(b"/queue"))
            send_and_wait(process, master_fd, output, b"\r", b"Server queued messages: 2")
            plain = screen_text(bytes(output))
            for expected in (b"queued-one", b"queued-two", b"Local unsent messages: 0"):
                if expected not in plain:
                    raise AssertionError(f"queue inspection omitted {expected!r}: {plain!r}")
            first_id = fixture.submitted[0]["request_id"]
            command = f"/queue edit {first_id} queued-one-fixed".encode()
            send_and_wait(process, master_fd, output, command, composer_showing(command))
            send_and_wait(process, master_fd, output, b"\r", b"queued-one-fixed")
            if not wait_for_fixture_event(process, master_fd, output, fixture.edited, timeout=5):
                raise AssertionError("queue edit never reached the server")
            if len(fixture.submitted) != 2 or fixture.operations[0]["operation_id"] != first_id:
                raise AssertionError("edit submitted a replacement operation instead of retaining its identity")
            fixture.release.set()
            # Replies stay in their original request blocks. The later /queue
            # inspections fill the bottom viewport, so inspect older blocks
            # with the same PageUp gesture an operator uses.
            os.write(master_fd, b"\x1b[5~" * 5)
            wait_for_output(process, master_fd, output, b"reply-queued-one-fixed", start=0, timeout=10)
            wait_for_output(process, master_fd, output, b"reply-queued-two", start=0, timeout=10)
            escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            fixture.release_interrupt.set()
            fixture.release.set()
    return interact


def chat_steer_interaction(fixture: AtomicChatFixture, requests: HttpRequests) -> Interaction:
    """Separate Enter sends during Esc retain order and wait for its receipt."""
    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            open_atomic_chat(process, master_fd, output)
            send_and_wait(process, master_fd, output, b"original", composer_showing(b"original"))
            os.write(master_fd, b"\r")
            wait_for_atomic_admissions(process, master_fd, output, fixture, 1)
            os.write(master_fd, b"\x1b")
            if not wait_for_fixture_event(process, master_fd, output, fixture.interrupted, timeout=5):
                raise AssertionError("Esc never reached its exact observed turn")
            send_and_wait(process, master_fd, output, b"new-course", composer_showing(b"new-course"))
            send_and_wait(process, master_fd, output, b"\r", "내 메시지 2건 대기".encode())
            send_and_wait(process, master_fd, output, b"one-more", composer_showing(b"one-more"))
            send_and_wait(process, master_fd, output, b"\r", "내 메시지 3건 대기".encode())
            if not wait_for_fixture_event(process, master_fd, output, fixture.old_poll_seen, timeout=10):
                raise AssertionError("no stale observation arrived during pending Esc")
            read_available(master_fd, output)
            if len(fixture.submitted) != 1:
                raise AssertionError("a stale observer token released input before Esc acknowledgement")
            fixture.release_interrupt.set()
            wait_for_atomic_admissions(process, master_fd, output, fixture, 3)
            if fixture.submitted[1]["admission_intent"]["control_token"] != "control-after-stop":
                raise AssertionError("retained Enter did not use the exact stop receipt authority")
            if [item["message"] for item in fixture.submitted] != ["original", "new-course", "one-more"]:
                raise AssertionError(f"separate Enter sends changed order or merged: {fixture.submitted!r}")
            if len({item["request_id"] for item in fixture.submitted}) != 3:
                raise AssertionError("separate Enter sends lost their request identities")
            if fixture.release.is_set():
                raise AssertionError("retained Enter waited for old model completion")
            if fixture.run_next_calls or any(path == "/api/v1/keepers/turn/run-next" for path, _ in requests):
                raise AssertionError("plain Enter used a second run-next control request")
            fixture.release.set()
            wait_for_output(process, master_fd, output, b"reply-new-course", start=0, timeout=10)
            wait_for_output(process, master_fd, output, b"reply-one-more", start=0, timeout=10)
            escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            fixture.release_interrupt.set()
            fixture.release.set()
    return interact


def chat_working_target_interaction(fixture: AtomicChatFixture) -> Interaction:
    """Esc targets the locally running direct turn over a stale autonomous poll; Enter names nothing."""
    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            open_atomic_chat(process, master_fd, output)
            send_and_wait(process, master_fd, output, b"working-question", composer_showing(b"working-question"))
            send_and_wait(process, master_fd, output, b"\r", "기존 작업 처리 중".encode())
            wait_for_atomic_admissions(process, master_fd, output, fixture, 1)
            send_and_wait(process, master_fd, output, b"follow-up", composer_showing(b"follow-up"))
            os.write(master_fd, b"\r")
            wait_for_atomic_admissions(process, master_fd, output, fixture, 2)
            # The fixture still advertises its autonomous token, so accepting
            # this POST proves local Working ownership won the target choice.
            os.write(master_fd, b"\x1b")
            if not wait_for_fixture_event(process, master_fd, output, fixture.interrupted, timeout=5):
                raise AssertionError("Esc did not target the locally working direct execution")
            # A newer queued request must not cause a duplicate Esc to send
            # another interrupt while the first acknowledgement is pending.
            os.write(master_fd, b"\x1b")
            time.sleep(0.08)  # delimit the terminal's lone Escape before typing
            read_available(master_fd, output)
            send_and_wait(process, master_fd, output, b"after-stop", composer_showing(b"after-stop"))
            send_and_wait(process, master_fd, output, b"\r", "내 메시지 2건 대기".encode())
            if len(fixture.interrupt_requests) != 1 or len(fixture.submitted) != 2:
                raise AssertionError("double Esc duplicated control or released input before acknowledgement")
            fixture.release_interrupt.set()
            wait_for_atomic_admissions(process, master_fd, output, fixture, 3)
            if fixture.submitted[2]["admission_intent"]["control_token"] != "control-after-stop":
                raise AssertionError("held Enter did not use the one stop acknowledgement")
            fixture.release.set()
            wait_for_output(process, master_fd, output, b"reply-after-stop", start=0, timeout=10)
            escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            fixture.release_interrupt.set()
            fixture.release.set()
    return interact


def chat_pending_stop_leave_interaction(fixture: AtomicChatFixture) -> Interaction:
    """An unanswered stop permits leaving the view after the existing Esc grace."""
    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            open_atomic_chat(process, master_fd, output)
            send_and_wait(process, master_fd, output, b"working-question", composer_showing(b"working-question"))
            send_and_wait(process, master_fd, output, b"\r", "기존 작업 처리 중".encode())
            os.write(master_fd, b"\x1b")
            if not wait_for_fixture_event(process, master_fd, output, fixture.interrupted, timeout=5):
                raise AssertionError("stop acknowledgement was not held")
            escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            if fixture.release_interrupt.is_set() or len(fixture.interrupt_requests) != 1:
                raise AssertionError("leaving required an acknowledgement or sent another interrupt")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            fixture.release_interrupt.set()
            fixture.release.set()
    return interact


def quit_names_waiting_messages_interaction(fixture: AtomicChatFixture) -> Interaction:
    """The quit warning counts input retained while a real Esc ack is pending."""
    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            open_atomic_chat(process, master_fd, output)
            os.write(master_fd, b"\x1b")
            if not wait_for_fixture_event(process, master_fd, output, fixture.interrupted, timeout=5):
                raise AssertionError("Esc acknowledgement was not gated")
            send_and_wait(process, master_fd, output, b"waiting-line", composer_showing(b"waiting-line"))
            send_and_wait(process, master_fd, output, b"\r", "내 메시지 1건 대기".encode())
            if fixture.received:
                raise AssertionError("pending control input was already sent to the server")
            escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
            send_and_wait(process, master_fd, output, b"q", b"q: 1 unsent message is dropped")
            if fixture.received:
                raise AssertionError(f"navigation dispatched input before control acknowledgement: {fixture.received!r}")
            # Confirm exit before releasing the server handler. Goodbye is a
            # visible completed exit; the harness still verifies terminal mode.
            #
            # Waited for on its own, not through send_and_wait: the farewell is
            # the last thing written. Terminal_restore.finish_after_restore
            # restores the terminal and only then prints it, so the frame
            # terminator send_and_wait looks for after a needle has already
            # gone by and no other follows.
            read_available(master_fd, output)
            start = len(output)
            write_all(master_fd, output, b"q")
            wait_for_output(
                process, master_fd, output, b"Goodbye!", start=start, timeout=3.0
            )
        finally:
            fixture.release_interrupt.set()
            fixture.release.set()
    return interact


def chat_retained_stop_interaction(fixture: AtomicChatFixture) -> Interaction:
    """A later Esc keeps earlier input local even after its own acknowledgement."""
    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            open_atomic_chat(process, master_fd, output)
            os.write(master_fd, b"\x1b")
            if not wait_for_fixture_event(process, master_fd, output, fixture.interrupted, timeout=5):
                raise AssertionError("initial stop never reached the server")
            send_and_wait(process, master_fd, output, b"retained-original", composer_showing(b"retained-original"))
            send_and_wait(process, master_fd, output, b"\r", "내 메시지 1건 대기".encode())
            send_and_wait(process, master_fd, output, b"\x1b", "중단 뒤 보관 중".encode())
            if fixture.received:
                raise AssertionError(f"second Esc dispatched retained input: {fixture.received!r}")
            fixture.release_interrupt.set()
            wait_for_output(process, master_fd, output, b"Interrupt received", start=0, timeout=10)
            # A completed queue read causes the generic drainer to run. It must
            # still respect retention after the control callback has settled.
            send_and_wait(process, master_fd, output, b"/queue", composer_showing(b"/queue"))
            send_and_wait(process, master_fd, output, b"\r", b"Queue snapshot")
            if fixture.received:
                raise AssertionError(f"stop acknowledgement dispatched retained input: {fixture.received!r}")
            send_and_wait(process, master_fd, output, b"explicit-followup", composer_showing(b"explicit-followup"))
            os.write(master_fd, b"\r")
            wait_for_atomic_admissions(process, master_fd, output, fixture, 1)
            if fixture.submitted[0]["message"] != "explicit-followup":
                raise AssertionError(f"fresh Enter did not keep its own request: {fixture.submitted!r}")
            if fixture.submitted[0]["admission_intent"]["control_token"] != "control-after-stop":
                raise AssertionError("fresh Enter did not use the completed stop authority")
            send_and_wait(process, master_fd, output, b"/queue", composer_showing(b"/queue"))
            queued = send_and_wait(process, master_fd, output, b"\r", b"Local unsent messages: 1")
            if b"retained-original" not in screen_text(frame_containing(queued, b"Local unsent messages: 1")):
                raise AssertionError("fresh Enter discarded the Esc-retained input")
            fixture.release.set()
            wait_for_output(process, master_fd, output, b"reply-explicit-followup", start=0, timeout=10)
            if len(fixture.submitted) != 1:
                raise AssertionError("retained input reached admission before explicit resume")
            send_and_wait(process, master_fd, output, b"/queue resume", composer_showing(b"/queue resume"))
            send_and_wait(process, master_fd, output, b"\r", b"Server confirmed queue resume")
            wait_for_atomic_admissions(process, master_fd, output, fixture, 2)
            if [item["message"] for item in fixture.submitted] != ["explicit-followup", "retained-original"]:
                raise AssertionError(f"explicit resume lost or merged an Enter request: {fixture.submitted!r}")
            if fixture.submitted[0]["request_id"] == fixture.submitted[1]["request_id"]:
                raise AssertionError("separate Enter sends shared a request identity")
            if fixture.submitted[1].get("admission_intent") is not None:
                raise AssertionError("resumed retained input invented fresh Enter authority")
            escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            fixture.release_interrupt.set()
            fixture.release.set()
    return interact


def chat_reconcile_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    gate = GatedHttpResponse((200, {}), hold_seconds=30.0)
    calls = 0
    lock = threading.Lock()

    def response(request_body: bytes) -> HttpResponse | RawHttpResponse:
        nonlocal calls
        with lock:
            call_index = calls
            calls += 1
        if call_index == 0:
            return 503, {"error": "first stream outcome is unknown"}
        if call_index == 1:
            gate.requested.set()
            try:
                if not gate.release.wait(timeout=gate.hold_seconds):
                    return 504, {"error": "reconciliation gate timed out"}
            finally:
                gate.completed.set()
        return keeper_chat_succeeded_response(request_body)

    return {
        "/api/v1/keepers/chat/stream": RequestHttpResponse(response)
    }, gate


def chat_reconcile_interaction(
    gate: GatedHttpResponse, requests: HttpRequests
) -> Interaction:
    """New Enter waits for the original identity's admission receipt."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Keepers \xe2\x96\xb8 \x1b[1malpha",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        send_and_wait(
            process, master_fd, output, b"uncertain", composer_showing(b"uncertain")
        )
        # The first connection fails before any RUN_STARTED. Its replacement
        # is intentionally withheld: the second HTTP arrival below proves the
        # reconnect regardless of which transient status line is visible.
        os.write(master_fd, b"\r")
        if not wait_for_fixture_event(
            process,
            master_fd,
            output,
            gate.requested,
            timeout=5.0,
        ):
            raise AssertionError("exact Keeper chat re-subscribe did not start")
        try:
            send_and_wait(
                process, master_fd, output, b"held-next", composer_showing(b"held-next")
            )
            send_and_wait(process, master_fd, output, b"\r", "내 메시지 2건 대기".encode())
            completed = output.rfind(FRAME_END) + len(FRAME_END)
            pending_screen = screen_text(bytes(output[:completed]))
            if "1건 전달 재확인 중".encode() not in pending_screen or "접수됨".encode() in pending_screen:
                raise AssertionError("unknown admission was presented as confirmed queued: " + repr(pending_screen))
            before_release = [
                json.loads(body).get("message")
                for path, body in requests
                if path == "/api/v1/keepers/chat/stream"
            ]
            if "held-next" in before_release:
                raise AssertionError(
                    f"later Enter overtook unverified admission: {before_release!r}"
                )
            gate.release.set()
            wait_for_output(
                process, master_fd, output, b"reply-held-next", start=0, timeout=10.0
            )
            bodies = [
                body
                for path, body in requests
                if path == "/api/v1/keepers/chat/stream"
            ]
            messages = [json.loads(body).get("message") for body in bodies]
            originals = [json.loads(body) for body in bodies if json.loads(body).get("message") == "uncertain"]
            if len(originals) < 2 or len({item["request_id"] for item in originals}) != 1:
                raise AssertionError(f"reconnect changed original request identity: {originals!r}")
            if messages.count("held-next") != 1:
                raise AssertionError(f"later Enter was lost or replayed: {messages!r}")
            escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            send_and_wait(
                process, master_fd, output, b"\x1b", b"MASC Keepers"
            )
            os.write(master_fd, b"q")
        finally:
            gate.release.set()

    return interact

def utf8_message_interaction(requests: HttpRequests) -> Interaction:
    expected_text = "Aé한🙂"
    expected_bytes = expected_text.encode()

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        ascii_frame = send_and_wait(process, master_fd, output, b"A", composer_showing(b"A"))
        # Thirty terminal rows: composer, frame bottom, runtime/context,
        # and key footer occupy the last four rows.
        assert_message_input_frame(
            ascii_frame,
            row=27,
            columns=100,
            input_text="A",
            cursor_column=8,
        )
        send_and_wait(process, master_fd, output, b"\x15", b"> ")

        combining_text = "e\u0301"
        combining_frame = send_and_wait(
            process,
            master_fd,
            output,
            combining_text.encode(),
            composer_showing(combining_text.encode()),
        )
        assert_message_input_frame(
            combining_frame,
            row=27,
            columns=100,
            input_text=combining_text,
            cursor_column=8,
        )
        send_and_wait(process, master_fd, output, b"\x15", b"> ")

        typed_frame = send_and_wait(
            process, master_fd, output, expected_bytes, composer_showing(expected_bytes)
        )
        typed_frame.decode("utf-8")
        assert_message_input_frame(
            typed_frame,
            row=27,
            columns=100,
            input_text=expected_text,
            cursor_column=13,
        )
        # The narrowest terminal the chat pane draws in. #33096 gated the pane
        # on Masc_tui_message_layout.chat_min_terminal_cols; below it the pane
        # draws "Keeper chat needs a larger terminal" and has no composer at
        # all, so this step waited on a composer that was never going to
        # arrive and stalled the whole lane (#34125).
        #
        # 41, not the 38 that commit's subject named: the constant is derived
        # (4 + 2 + turn_rail_cells + chat_role_label_column + 20) and the
        # derivation has grown by three since. Pinned at the floor rather than
        # comfortably above it -- at 60 this would still pass while the floor
        # moved underneath, which is how it got to 41 unnoticed.
        narrow_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=41,
            needle=composer_showing(b"A"),
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        assert_message_input_frame(
            narrow_frame,
            row=27,
            columns=41,
            input_text=expected_text,
            cursor_column=13,
        )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=100,
            needle=composer_showing(expected_bytes),
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        backspace_cases = (
            (composer_showing("Aé한".encode()), "🙂".encode()),
            (composer_showing("Aé".encode()), "한".encode()),
            (composer_showing(b"A"), "é".encode()),
        )
        for expected, removed in backspace_cases:
            frame = send_and_wait(process, master_fd, output, b"\x7f", expected)
            frame.decode("utf-8")
            if removed[:1] in frame:
                raise AssertionError(
                    f"backspace left part of UTF-8 scalar {removed!r}: {frame!r}"
                )

        send_and_wait(process, master_fd, output, b"\xe2x", composer_showing(b"Ax"))
        send_and_wait(process, master_fd, output, b"\x7f", composer_showing(b"A"))
        send_and_wait(process, master_fd, output, b"\xe2\x15", b"> ")
        send_and_wait(process, master_fd, output, b"A", composer_showing(b"A"))
        os.write(master_fd, b"\xe2")
        wait_for_terminal_input_consumed(slave_fd)
        time.sleep(0.08)
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=29,
            columns=100,
            needle=b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        send_and_wait(process, master_fd, output, b"y", composer_showing(b"Ay"))

        send_and_wait(process, master_fd, output, b"\x15", b"> ")
        send_and_wait(
            process, master_fd, output, expected_bytes, composer_showing(expected_bytes)
        )
        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        payload = json.loads(body)
        if payload.get("message") != expected_text:
            raise AssertionError(f"Keeper chat changed UTF-8 message bytes: {body!r}")

        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def clipboard_paste_key_interaction() -> Interaction:
    """Ctrl-V reaches the composer at all.

    Ctrl-V is VLNEXT's default character. While IEXTEN is set the tty layer
    consumes that byte and passes the *following* one through uninterpreted, so
    the pane would see the letter after Ctrl-V and never Ctrl-V itself -- which
    is what a handler alone could not fix. The pane answering is the evidence
    the key arrived.

    What the answer says depends on the host: a machine with no clipboard
    reader installed says so, and one with a reader and no image on the
    clipboard says that instead. Both are answers. The success path needs an
    image on the running machine's clipboard, so it is not asserted here and
    stays a local check.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x16",
            re.compile(rb"Ctrl-V: |pasted \[Image #1\]"),
        )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def chat_visibility_modes_interaction(
    tool_calls_gate: GatedHttpResponse | None = None,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=180,
            needle=b"MASC Dashboard",
        )
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        # Keep the roster cursor on beta, then open alpha through the palette.
        # Durable call details belong to the chat target, not that unrelated
        # cursor; the old response guard discarded this successful GET.
        select_keeper_row(process, master_fd, output, b"beta")
        pane_start = len(output)
        initial = palette_go(
            process,
            master_fd,
            output,
            b"keeper alpha",
            b"ci-red-attribution",
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"anthropic.claude-opus-5",
            start=pane_start,
            timeout=5.0,
        )
        # The tool lane colours each token separately and pads columns,
        # so a literal "✗ masc_fusion · 1200ms" never exists as contiguous
        # bytes. Match the tokens while tolerating SGR runs and padding
        # between them, like the [tag]constraint probe needle tolerates
        # tags between words.
        wait_for_output(
            process,
            master_fd,
            output,
            re.compile(
                re.escape("\u2717".encode())
                + rb"[\x1b\x20-\x7e]*?"
                + rb"masc_fusion"
                + rb"[\x1b\x20-\x7e]*?"
                + rb"\xc2\xb7"
                + rb"[\x1b\x20-\x7e]*?"
                + rb"1200ms"
            ),
            start=pane_start,
            timeout=5.0,
        )
        # Same tool-lane token colouring: cross-check needles that span
        # word boundaries must tolerate SGR runs and padding inside them.
        settled_at = pane_start
        for needle in (
            # The header names the stance in the [w] chooser's words now,
            # not the wire token (#35974).
            b"gate: Auto Judge",
            "\u25c6".encode(),
            re.compile(
                rb"AUTO[\x1b\x20-\x7e]*?\xc2\xb7[\x1b\x20-\x7e]*?gate"
            ),
            # The compact skill row is the skill's name: how far one
            # invocation got, and what followed from it, ride the tool
            # toggle and are waited for in that world below. A turn that
            # triggered a skill once says its name alone; a count and a
            # failed trigger's words are what else the row can carry.
            b"ci-red-attribution",
        ):
            wait_for_output(
                process,
                master_fd,
                output,
                needle,
                start=pane_start,
                timeout=5.0,
            )
            settled_at = max(settled_at, end_of_needle(output, needle, pane_start))
        wait_for_output(
            process, master_fd, output, FRAME_END,
            start=settled_at,
            timeout=5.0,
        )
        initial += bytes(output[pane_start:])
        # The Skill can arrive before the gate identity. Reconstruct the
        # accumulated screen at the completed observation barrier instead of
        # selecting the first frame that happened to contain the Skill name.
        completed = bytes(output[:output.rfind(FRAME_END) + len(FRAME_END)])
        observed_rows = screen_rows(completed)
        title_row = screen_row_of(
            observed_rows, b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat"
        )
        identity_row = screen_row_of(observed_rows, b"gate: Auto Judge")
        composer_row = screen_row_of(observed_rows, b"> ")
        footer_row = screen_row_of(observed_rows, b"Enter:send")
        if not (0 < title_row < composer_row < identity_row < footer_row):
            raise AssertionError(
                "chat navigation, composer, operational identity and key footer "
                f"did not occupy separate ordered rows: {observed_rows!r}"
            )
        if b"2 reasoning steps \xc2\xb7 text not recorded" in initial:
            raise AssertionError(f"hidden reasoning was still drawn: {initial!r}")
        # The lane word went: the skill row leads with its mark and the
        # skill's name, with the badge padding and SGR runs between -- the
        # same token-split shape the tool-lane needles above take, because
        # a literal "◆ ci-red-attribution" never exists as contiguous
        # bytes. The rail is a token of its own, the way " · " is above: a
        # needle anchored on the gutter mark crosses into the body, and
        # Skill rows are Shade_quoted, so the renderer draws "│" (>= 0x80,
        # outside the gap class) between badge padding and body.
        # Body-anchored needles (✗, 씀, proof) never cross it and keep the
        # plain gap.
        if re.search(
            "◆".encode()
            + rb"[\x1b\x20-\x7e]*?"
            + "│".encode()
            + rb"[\x1b\x20-\x7e]*?"
            + rb"ci-red-attribution",
            initial,
        ) is None:
            raise AssertionError(
                f"the exact Skill evidence did not start its turn: {initial!r}"
            )
        # How far one invocation got is not on the resting row any more:
        # the row stands for every trigger of that skill.
        if "전달됨".encode() in initial:
            raise AssertionError(
                f"the compact skill row still spells a lifecycle: {initial!r}"
            )
        if b"\x1b[1mci-red-attribution" not in initial:
            raise AssertionError(f"the Skill name was not bold: {initial!r}")
        # The rest of the skill row rides the tool toggle now: the action
        # rows and the proof line exist only behind Ctrl-D, so the compact
        # frame must not carry them. Their presence is waited for below,
        # after the flip.
        for leaked in (
            re.compile(
                rb"masc_fusion[\x1b\x20-\x7e]*?\xc2\xb7[\x1b\x20-\x7e]*?observed"
            ),
            re.compile(rb"proof[\x1b\x20-\x7e]*?\xc2\xb7[\x1b\x20-\x7e]*?turn="),
        ):
            if leaked.search(initial) is not None:
                raise AssertionError(
                    f"skill detail leaked into the compact frame: {initial!r}"
                )
        # The lane word is gone for good: a revert that puts SKILL back on
        # the badge must fail here, not pass silently. Stripped, because
        # the badge's SGR runs make a raw-byte absence shape-dependent.
        if b"SKILL" in CSI_RE.sub(b"", initial):
            raise AssertionError(f"the lane word SKILL is back: {initial!r}")

        folded = send_and_wait(
            process, master_fd, output, b"\x12", b"reasoning:folded"
        )
        # The fold marker's wording changed: the count line is the thinking
        # lane's mark and its padding over "2 reasoning steps · text not
        # recorded" (no lane word -- the mark says the lane); for this
        # one-line count row the old "Reasoning / N line(s) folded" label
        # does not exist (it still fires for multi-line thinking bodies).
        if b"2 reasoning steps" not in folded or b"text not recorded" not in folded:
            raise AssertionError(f"folded reasoning did not draw its count: {folded!r}")

        # \x12 flips reasoning visibility and the renderer answers with a
        # diff frame: the header tag (reasoning:folded -> reasoning:full)
        # is what gets re-emitted. The thinking-lane count row is unchanged
        # by the flip, so it is not redrawn -- asserting its reappearance
        # here starves even though the row stays on screen.
        full = send_and_wait(
            process,
            master_fd,
            output,
            b"\x12",
            b"reasoning:full",
        )
        if b"reasoning:full" not in full:
            raise AssertionError(f"full reasoning did not flip the tag: {full!r}")

        # The first press opens result previews; the second opens the
        # full call evidence whose fields this scenario checks below.
        send_and_wait(
            process, master_fd, output, b"\x04", b"reasoning:full tools:results"
        )
        tools_start = len(output)
        tools = send_and_wait(
            process,
            master_fd,
            output,
            b"\x04",
            b"reasoning:full tools:full",
        )
        if tool_calls_gate is not None:
            if not wait_for_fixture_event(
                process,
                master_fd,
                output,
                tool_calls_gate.requested,
                timeout=3.0,
            ):
                raise AssertionError("tool-call detail GET did not reach fixture gate")
            # A forced open while the first GET is held must coalesce into
            # one follow-up. Leave results visible when the first GET returns:
            # the continuation must launch the pending read in this mode too.
            # Compact is the resting mode, so the header omits its tools tag.
            send_and_wait(
                process, master_fd, output, b"\x04", b"tool calls compact"
            )
            completed_end = output.rfind(FRAME_END) + len(FRAME_END)
            compact_rows = screen_rows(bytes(output[:completed_end]))
            header_row = screen_row_of(compact_rows, b"reasoning:full")
            footer_row = screen_row_of(compact_rows, b"tool calls compact")
            if (
                header_row < 0
                or footer_row <= header_row
                or b"tools:" in compact_rows[header_row]
            ):
                raise AssertionError(
                    f"compact screen did not show its header and footer: {compact_rows!r}"
                )
            send_and_wait(
                process, master_fd, output, b"\x04", b"reasoning:full tools:results"
            )
            if tool_calls_gate.calls != 1:
                raise AssertionError(
                    "same-Keeper in-flight detail refresh was duplicated: "
                    f"{tool_calls_gate.calls} GETs"
                )
            refresh_start = len(output)
            tool_calls_gate.release.set()
            if not wait_for_fixture_event(
                process,
                master_fd,
                output,
                tool_calls_gate.subsequent_requested,
                timeout=3.0,
            ):
                raise AssertionError("results mode did not relaunch the pending GET")
            if tool_calls_gate.calls != 2:
                raise AssertionError(
                    "same-Keeper refresh did not coalesce to one follow-up: "
                    f"{tool_calls_gate.calls} GETs"
                )
            wait_for_output(
                process,
                master_fd,
                output,
                b"panel-output-refreshed",
                start=refresh_start,
                timeout=5.0,
            )
            send_and_wait(
                process, master_fd, output, b"\x04", b"reasoning:full tools:full"
            )
        # The flip re-renders the transcript rows it changes: the skill row's
        # action list and proof line exist only in this world, so they are
        # waited for after tools_start rather than asserted of the compact
        # frame. The pane's own first badge is the fusion row's state
        # (FAILED) at tools_start.
        wait_for_output(
            process,
            master_fd,
            output,
            b"FAILED",
            start=tools_start,
            timeout=5.0,
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"execution=exec-fusion-1",
            start=tools_start,
            timeout=5.0,
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"provider-call=call-fusion-1",
            start=tools_start,
            timeout=5.0,
        )
        # The skill detail the compact frame must not carry: this world's
        # redraw of the transcript rows is the one place the action rows and
        # the proof line are emitted, so they are waited for here.
        for needle in (
            # The action row's "↳" leads its body, so the needle starts
            # there: the glyph is the fold's own shape, not just its text.
            re.compile(
                "\u21b3".encode()
                + rb"[\x1b\x20-\x7e]*?"
                + rb"masc_fusion[\x1b\x20-\x7e]*?\xc2\xb7[\x1b\x20-\x7e]*?observed"
            ),
            re.compile(rb"proof[\x1b\x20-\x7e]*?\xc2\xb7[\x1b\x20-\x7e]*?turn="),
            # How far this invocation got, and what followed from it. The
            # phrase names the model's side of the step: 받아서 씀 said who
            # received without saying who sent (#36268). Each Korean piece is
            # matched on its own so the comma and space the label carries, or
            # an SGR run between them, does not hide it.
            re.compile(
                "전달됨".encode()
                + rb"[\x1b\x20-\x7e]*?"
                + "도구".encode()
                + rb"[\x1b\x20-\x7e]*?"
                + "씀".encode()
                + rb"[\x1b\x20-\x7e]*?"
                + rb"\xc2\xb7"
                + rb"[\x1b\x20-\x7e]*?"
                + rb"ci-red-attribution"
                + rb"[\x1b\x20-\x7e]*?"
                + rb"\xc2\xb7"
                + rb"[\x1b\x20-\x7e]*?"
                + rb"1 action"
            ),
        ):
            wait_for_output(
                process,
                master_fd,
                output,
                needle,
                start=tools_start,
                timeout=5.0,
            )
        tools += bytes(output[tools_start:])
        # "batch 2"/"width 3" are colour-split per token in the pane, so
        # they are asserted as token regexes; the turn= proof row belongs to
        # the transcript's skill row and is waited for above, not read out
        # of this buffer.
        for needle in (
            b"masc_fusion",
            b"state",
            b"FAILED",
            b"DEFERRED",
            b"ASYNC CONTINUATION",
            b"concurrent",
            re.compile(rb"batch[\x1b\x20-\x7e]*?2"),
            re.compile(rb"width[\x1b\x20-\x7e]*?3"),
            b"panel-input-exact",
            (
                b"panel-output-refreshed"
                if tool_calls_gate is not None
                else b"panel-output-exact"
            ),
            b"execution=exec-fusion-1",
        ):
            if find_needle(tools, needle, 0) < 0:
                raise AssertionError(
                    f"full tool view did not restore {needle!r}: {tools!r}"
                )
        if b"keeper_skill" in CSI_RE.sub(b"", tools):
            raise AssertionError(
                f"exact Skill evidence was duplicated as a generic tool: {tools!r}"
            )
        # Leaving the chat returns to the Keepers list with the chat target
        # selected: message navigation follows its explicit target, so the
        # roster cursor is alpha, not the beta it held before the palette jump.
        send_and_wait(process, master_fd, output, b"\x1b", keeper_row_selected(b"alpha"))
        os.write(master_fd, b"q")

    return interact


def chat_clarity_http_fixtures() -> HttpFixtures:
    fixtures = context_inspector_fixtures()
    history = autonomous_turn_history_fixture()
    history_rows = history[1]
    if not isinstance(history_rows, list):
        raise AssertionError("chat clarity history fixture is not a list")
    trace = history_rows[0]["blocks"][0]["trace"]
    trace[1]["name"] = "keeper_skill"
    trace[3]["name"] = "masc_fusion"
    trace[3]["execution_id"] = "exec-fusion-1"
    history_rows[0]["skill_activations"] = {
        "schema": "masc.keeper_chat.skill_activations.v1",
        "status": "available",
        "activations": [
            {
                "identity": {
                    "source_id": "workspace",
                    "package_id": "ops",
                    "name": "ci-red-attribution",
                },
                "content_revision": "sha256:content-rev-1",
                "snapshot_revision": "sha256:snapshot-rev-1",
                "turn_ref": "trace-1787333555531-00020#54",
                "runtime_id": "anthropic.claude-opus-5",
                "skill_tool_use_id": "skill-use-1",
                "agent_core_turn": 54,
                "invocation": {"kind": "instruction"},
                "delivery": {"boundary": {"kind": "model_response"}},
                "actions": [
                    {
                        "tool_name": "masc_fusion",
                        "runtime_id": "anthropic.claude-opus-5",
                    }
                ],
                "activated_at": "2026-09-01T08:00:00Z",
            }
        ],
    }
    fixtures["/api/v1/keepers/alpha/chat/history"] = history
    fixtures["/api/v1/dashboard/gate"] = (
        200,
        {
            "approval_queue": [],
            "approval_queue_state": None,
            "hitl": {
                "gate_mode": {"mode": "auto_judge"},
                "external_gate_mode": {"mode": "manual"},
            },
            "approval_rules": None,
            "approval_rules_state": None,
        },
    )
    fixtures["/api/v1/dashboard/gate/keeper-settings"] = (
        200,
        {
            "modes": [],
            "modes_state": {"state": "ready"},
            "exact_lanes": [],
            "exact_lanes_state": {"state": "ready"},
        },
    )
    fixtures["/api/v1/keepers/tool-approval-mode"] = (200, {"overrides": []})
    fixtures["/api/v1/keepers/alpha/tool-calls?limit=100"] = (
        200,
        {
            "keeper": "alpha",
            "count": 1,
            "health": "ok",
            "entries": [
                {
                    "ts": 1787348490.3,
                    "keeper": "alpha",
                    "tool": "masc_fusion",
                    "input": {"prompt": "panel-input-exact"},
                    "output": "panel-output-exact",
                    "duration_ms": 1200.0,
                    "execution_id": "exec-fusion-1",
                    "tool_use_id": "call-fusion-1",
                    "planned_index": 4,
                    "batch_index": 1,
                    "batch_size": 3,
                    "execution_mode": "concurrent",
                    "disposition": "deferred",
                    "result_bytes": 18,
                }
            ],
        },
    )
    return fixtures


def message_origin_history_fixture() -> HttpResponse:
    return (
        200,
        [
            {
                "id": "origin-user",
                "role": "user",
                "content": "operator-body-neutral",
                "ts": 1787348490.3,
                "speaker_name": "vincent",
                "surface": {"kind": "dashboard"},
            },
            {
                "id": "origin-keeper",
                "role": "assistant",
                "content": "keeper-body-neutral",
                "ts": 1787348491.3,
            },
        ],
    )


def viewport_gap_history_fixture() -> HttpResponse:
    return (
        200,
        [
            {
                "id": "oversized-keeper-reply",
                "role": "assistant",
                "content": "\n".join(f"line-{index:02d}" for index in range(24)),
                "ts": 1787348491.3,
            }
        ],
    )


def viewport_gap_history_page_fixture() -> HttpResponse:
    # The only stored message is already in the initial history. The server
    # answers strictly before its timestamp, so this page must be empty;
    # repeating that message fabricates an older row and moves the scroll pin.
    return (200, {"messages": [], "has_more": False, "next_before": None})


LIVE_MARKDOWN_REPLY = """@keeper-haneul-agent — 고마워요! Execute가 작동하는 세션이 있다면 정말 큰 도움이 됩니다.

## 정확한 5개 git 명령 (task478 worktree에서 실행):

```bash
cd <task478 worktree path>   # 저도 경로를 잃어버렸습니다 — branch: task478-server-unreadable-store
git status --short
git add lib/keeper/keeper_meta_store.ml lib/keeper/keeper_meta_store.mli
git commit --amend -m 'feat(keeper): extend Problem_report_state with unreadable-store entries (task-478)'
git fetch origin && git rebase origin/main
git push --force-with-lease
```

## 작업 내역 (이미 working tree에 적용됨):
- `keeper_meta_store.ml`: Problem_report_state에 entry type (detail+first_observed), snapshot(), snapshot_to_yojson(), unreadable_store_snapshot_to_yojson 추가
- `keeper_meta_store.mli`: unreadable_store_snapshot_to_yojson 노출
- `store_unreadable.ml`, `test_store_unreadable.ml`, `test_store_unreadable.inc`: `git rm`으로 삭제 (이미 staged)
- `test/dune`: include 제거, entangled hunk revert

## 참고:
- task-470 릴리스는 operator에게 요청해야 할 수 있습니다 (제가 제3자 task를 릴리스하는 도구가 없음)
- worktree 경로는 `git worktree list`로 찾을 수 있을 것입니다
- PR #29815가 업데이트됩니다. CI는 이미 복구됨 (#29837 merged)"""


def live_markdown_history_fixture() -> HttpResponse:
    # Production reply msg-1787516761351436-321. The concrete Keeper identity
    # is replaced with the same-length fixture identity required by the suite.
    return (
        200,
        [
            {
                "id": "msg-1787516761351436-321",
                "role": "assistant",
                "content": LIVE_MARKDOWN_REPLY,
                "ts": 1787516761.351436,
            }
        ],
    )


def live_markdown_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=80,
        columns=90,
        needle=b"MASC Dashboard",
    )
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    pane_start = len(output)
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
    tail_head = b"task478-server"
    tail_rest = b"-unreadable-store"
    wait_for_output(
        process,
        master_fd,
        output,
        tail_head,
        start=pane_start,
        timeout=5.0,
    )
    tail_end = end_of_needle(output, tail_head, pane_start)
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=tail_end,
        timeout=3.0,
    )
    frame = frame_containing(bytes(output[pane_start:]), tail_head)
    plain = CSI_RE.sub(b"", frame)
    header = "┌─ bash".encode()
    footer = "└".encode()
    prose = "작업 내역".encode()
    positions = [plain.find(needle) for needle in (header, tail_head, tail_rest, footer, prose)]
    if any(position < 0 for position in positions):
        raise AssertionError(
            "live Markdown frame omitted its language header, complete long line, "
            f"closing border, or following prose: {frame!r}"
        )
    if positions != sorted(positions):
        raise AssertionError(f"live Markdown rows were reordered: {frame!r}")
    if b"\x1b[7m" + header not in frame:
        raise AssertionError(f"language header has no neutral background: {frame!r}")
    if b"```bash" in plain:
        raise AssertionError(f"raw fence marker leaked into the chat: {frame!r}")
    escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
    os.write(master_fd, b"q")


# The three metadata densities differ in where the origin sits, not in what it
# says, so the reading that tells them apart is which screen row each piece
# landed on. A frame is no help: it addresses rows absolutely and writes no
# newlines, so two rows read as one string and "name then body" matches the
# stacked layout as readily as the inline one.
def origin_screen_shape(
    output: bytearray, badge: bytes, body: bytes
) -> tuple[bytes, int]:
    """The screen row carrying [badge], and how far below it [body] sits."""
    rows = screen_rows(bytes(output))
    badge_row = screen_row_of(rows, badge)
    body_row = screen_row_of(rows, body)
    if badge_row < 0 or body_row < 0:
        raise AssertionError(
            f"chat screen lost {badge!r} or {body!r}: "
            f"{screen_text(bytes(output))!r}"
        )
    return rows[badge_row], body_row - badge_row


# The speaker's colour belongs to the badge. A body drawn in it turns the whole
# message into the speaker's colour and the pane loses the one contrast it has.
# Written as the escape rather than as the three colours a speaker happens to
# use today, so a wash in a fourth is caught the day someone writes it.
BODY_WASH = rb"\x1b\[(?:3[0-7]|4[0-7]|9[0-7]|10[0-7])m *"


def assert_bodies_unwashed(frame: bytes, description: str) -> None:
    for body in (b"operator-body-neutral", b"keeper-body-neutral"):
        washed = re.search(BODY_WASH + re.escape(body), frame)
        if washed is not None:
            raise AssertionError(
                f"{description} washed {body!r} in the speaker's colour: {frame!r}"
            )


def message_origin_badge_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    pane_start = len(output)
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
    # The pane draws before its history arrives, and every step below reads a
    # row the history draws, so the walk starts once the later speaker is on
    # screen.
    wait_for_output(
        process,
        master_fd,
        output,
        b"keeper-body-neutral",
        start=pane_start,
        timeout=5.0,
    )
    # The fixture names a speaker, so the operator's line arrives here as
    # someone else's and takes the inbound mark rather than the one a line
    # typed at this pane would take.
    operator_badge = "◀ vincent".encode()
    keeper_badge = "● alpha".encode()
    operator_body = b"operator-body-neutral"
    keeper_body = b"keeper-body-neutral"

    # Ctrl-F walks bare -> inline -> row -> bare and the pane opens on inline,
    # which is the one stop with no header word: the summary names the two
    # projections away from the resting layout ("metadata:off" and
    # "metadata:full") and stays silent about the layout itself. So the first
    # press lands on the full row, and the press that comes back to inline is
    # waited on by the short clock instead -- the one thing neither other stop
    # draws.
    full_row = send_and_wait(process, master_fd, output, b"\x06", b"metadata:full")
    # The pane's own keeper is not named on its full heading -- the
    # breadcrumb says whose chat this is -- so its row opens on the mark and
    # goes straight into the rule.
    keeper_full_heading = "● ─".encode()
    for badge, body, description in (
        (operator_badge, operator_body, "operator"),
        (keeper_full_heading, keeper_body, "Keeper"),
    ):
        row, gap = origin_screen_shape(output, badge, body)
        if gap != 1:
            raise AssertionError(
                f"the full origin row did not put the {description} body on the "
                f"row below its origin (gap {gap}): {screen_text(bytes(output))!r}"
            )
        # The full row ends on its clock: the name at the left, the clock at
        # the right edge and a rule between, not "[HH:MM:SS]" ahead of the
        # name.
        if re.search(rb"\d\d:\d\d:\d\d\s*$", row) is None:
            raise AssertionError(
                f"the full {description} origin row did not end on its clock: {row!r}"
            )
    if b"\x1b[7mvincent" not in full_row:
        raise AssertionError(
            f"chat origin did not keep its reverse-video badge for vincent: "
            f"{full_row!r}"
        )
    keeper_heading, _ = origin_screen_shape(output, keeper_full_heading, keeper_body)
    if b"alpha" in keeper_heading:
        raise AssertionError(
            f"the full heading named the pane's own keeper: {keeper_heading!r}"
        )
    assert_bodies_unwashed(full_row, "the full origin row")

    bare = send_and_wait(process, master_fd, output, b"\x06", b"metadata:off")
    for badge, body, description in (
        (operator_badge, operator_body, "operator"),
        (keeper_badge, keeper_body, "Keeper"),
    ):
        row, gap = origin_screen_shape(output, badge, body)
        if gap != 0:
            raise AssertionError(
                f"the clock-free layout did not keep the {description} body beside "
                f"its origin (gap {gap}): {screen_text(bytes(output))!r}"
            )
        if body not in row:
            raise AssertionError(
                f"the clock-free {description} row lost its body: {row!r}"
            )
        if re.search(rb"\d\d:\d\d", row) is not None:
            raise AssertionError(
                f"the clock-free {description} row still drew a clock: {row!r}"
            )
    assert_bodies_unwashed(bare, "the clock-free layout")

    inline = send_and_wait(
        process,
        master_fd,
        output,
        b"\x06",
        # The clock recedes in a span of its own and the mark opens the
        # speaker's colour after it, so the raw stream carries SGR sequences
        # between the two. The wait is still on the short clock; the needle
        # just lets the styles through.
        re.compile(rb"\d\d:\d\d (?:\x1b\[[0-9;]*m)*" + re.escape("◀".encode())),
    )
    for badge, body, description in (
        (operator_badge, operator_body, "operator"),
        (keeper_badge, keeper_body, "Keeper"),
    ):
        row, gap = origin_screen_shape(output, badge, body)
        if gap != 0:
            raise AssertionError(
                f"the inline layout did not keep the {description} body beside its "
                f"origin (gap {gap}): {screen_text(bytes(output))!r}"
            )
        if body not in row:
            raise AssertionError(
                f"the inline {description} row lost its body: {row!r}"
            )
    # Only the first row of a minute draws the clock, so the operator's row
    # carries it and the Keeper's row a second later does not.
    operator_row, _ = origin_screen_shape(output, operator_badge, operator_body)
    if re.search(rb"\d\d:\d\d " + re.escape("◀".encode()), operator_row) is None:
        raise AssertionError(
            f"the inline layout drew no clock beside the operator origin: "
            f"{operator_row!r}"
        )
    assert_bodies_unwashed(inline, "the inline layout")

    draft_frame = send_and_wait(
        process, master_fd, output, b"draft-neutral", b"draft-neutral"
    )
    # Restore only the foreground after the accented prompt. A full reset
    # would erase the input surface background; accepting arbitrary SGR here
    # could instead leave the draft tinted or clear its background with 49m.
    if b"\x1b[96m  > \x1b[39mdraft-neutral" not in draft_frame:
        raise AssertionError(
            f"chat composer did not restore default foreground while preserving its background: {draft_frame!r}"
        )
    escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
    os.write(master_fd, b"q")


def viewport_gap_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    # This fixture has no agenda strip. Fourteen physical rows leave only
    # thirteen below navigation; the hint must name the usable physical size.
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=14,
        columns=100,
        needle=b"resize to at least 15 rows",
    )
    # Following the displayed size must restore the surface, not the warning.
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=15,
        columns=100,
        needle=b"MASC Dashboard",
    )
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    # The opened title row renders "Keepers ▸ alpha" plainly now (the bold
    # run was dropped from the renderer); asserting the old \x1b[1m spelling
    # starves on the plain bytes.
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 alpha")
    opened = send_and_wait(process, master_fd, output, b"m", b"hidden")
    plain = CSI_RE.sub(b"", opened)
    marker = "⋯".encode()
    positions = [plain.find(needle) for needle in (b"line-00", marker, b"line-23")]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise AssertionError(
            f"oversized live edge did not order opening, gap, and latest row: {opened!r}"
        )

    complete = send_and_wait(
        process, master_fd, output, b"\x1b[5~", b"line-18"
    )
    complete_plain = CSI_RE.sub(b"", complete)
    if marker in complete_plain or b"hidden" in complete_plain:
        raise AssertionError(
            f"PgUp retained a synthetic gap inside transcript rows: {complete!r}"
        )
    # An exhausted older page leaves the transcript intact. PgDn must restore
    # the oversized live-edge projection in this response, including its gap
    # and newest row; previously emitted bytes cannot prove that transition.
    newest = send_and_wait(process, master_fd, output, b"\x1b[6~", b"line-23")
    newest_plain = CSI_RE.sub(b"", newest)
    positions = [newest_plain.find(needle) for needle in (b"line-00", marker, b"line-23")]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise AssertionError(
            "PgDn did not restore the oversized live-edge projection "
            f"after one PgUp: {newest!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 alpha")
    os.write(master_fd, b"q")


def keeper_message_switch_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    fixtures = keeper_runtime_http_fixtures()
    alpha_history = GatedHttpResponse(
        (
            200,
            [
                {
                    "id": "alpha-stale-history",
                    "role": "assistant",
                    "content": "alpha-stale-history-marker",
                    "ts": 1787348500.3,
                }
            ],
        ),
        subsequent_response=(
            200,
            [
                {
                    "id": "alpha-current-history",
                    "role": "assistant",
                    "content": "alpha-current-history-marker",
                    "ts": 1787348502.3,
                }
            ],
        ),
    )
    fixtures["/api/v1/keepers/alpha/chat/history"] = alpha_history
    fixtures["/api/v1/keepers/beta/chat/history"] = (
        200,
        [
            {
                "id": "beta-current-history",
                "role": "assistant",
                "content": "beta-current-history-marker",
                "ts": 1787348501.3,
            }
        ],
    )
    return fixtures, alpha_history


# The width at which the roster shares the screen with the chat and nothing
# else does. Two thresholds bound it: the roster needs the surface at
# Masc_tui_roster_pane.threshold_cols (110), and from
# Masc_tui_acting_pane.threshold_cols (158) the acting pane takes its 56
# columns off the top, which leaves the surface 102 and takes the roster away
# again until 166, where both panes fit.
# The status row names the keeper, then its automation and gate, then the
# runtime. Joining the health word to the runtime pinned that order, and the
# two fields that arrived between them broke both readings at once. The pair
# these scenarios care about is "this keeper's own health and its own
# runtime", which is a question about one row.
def assert_runtime_row(
    frame: bytes, *, keeper: bytes, health: bytes, runtime: bytes, description: str
) -> None:
    """Both halves of the runtime identity on one screen row.

    The runtime half is the text the chat header draws around the model
    name, not the model name alone: #35458 folded the turn gauge into one
    line and the header now says "<state> \u00b7 configured: <model>", where
    it used to say "<state> <model>". The two callers below kept the old
    spelling and stopped matching any row, which reads as "the header lost
    the health" rather than "the header renamed the field".
    """
    rows = screen_rows(frame)
    row = screen_row_of(rows, runtime)
    if row < 0 or health not in rows[row]:
        raise AssertionError(
            f"{description} did not carry {health!r} beside {runtime!r}: {frame!r}"
        )
    if not rows[row].lstrip().startswith(keeper + " · ".encode()) or b"Context" not in rows[row]:
        raise AssertionError(f"{description} lost its Keeper attribution or context reading: {rows[row]!r}")


ROSTER_BESIDE_CHAT_COLUMNS = 120


def keeper_message_switch_interaction(alpha_history: GatedHttpResponse) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"MASC Dashboard",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"3",
            b"anthropic.claude-opus-5",
        )
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        if not wait_for_fixture_event(
            process, master_fd, output, alpha_history.requested, timeout=10.0
        ):
            raise AssertionError("alpha history request did not reach its fixture")
        send_and_wait(
            process,
            master_fd,
            output,
            b"alpha-draft",
            composer_showing(b"alpha-draft"),
        )

        # Wide chat shows the roster by default. Leave that preference
        # untouched while checking the selected Keeper and draft handoff.
        wait_for_output(process, master_fd, output, b"KEEPERS", start=0, timeout=3.0)

        beta_start = len(output)
        # A drawn roster is an input pane: Left focuses it, Down moves its
        # cursor, and Enter opens that Keeper without changing the draft.
        send_and_wait(process, master_fd, output, b"\x1b[D", b"Enter:open")
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[B",
            b"\x1b[7m \xc2\xb7 beta",
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"beta-current-history-marker",
            start=beta_start,
            timeout=3.0,
        )
        beta_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        beta_plain = CSI_RE.sub(b"", beta_frame)
        assert_runtime_row(
            beta_frame,
            keeper=b"beta",
            health=b"idle",
            runtime=b"paused \xc2\xb7 configured: anthropic.claude-sonnet-4",
            description="switched beta chat",
        )
        for expected in (
            b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            b"beta-current-history-marker",
        ):
            if expected not in beta_plain:
                raise AssertionError(
                    f"switched beta chat omitted {expected!r}: {beta_frame!r}"
                )
        if b"alpha-draft" in beta_plain:
            raise AssertionError(f"alpha draft leaked into beta chat: {beta_frame!r}")
        send_and_wait(
            process,
            master_fd,
            output,
            b"beta-draft",
            composer_showing(b"beta-draft"),
        )

        alpha_start = len(output)
        send_and_wait(process, master_fd, output, b"\x07", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        wait_for_output(
            process,
            master_fd,
            output,
            b"alpha-current-history-marker",
            start=alpha_start,
            timeout=3.0,
        )
        alpha_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        alpha_plain = CSI_RE.sub(b"", alpha_frame)
        assert_runtime_row(
            alpha_frame,
            keeper=b"alpha",
            health=b"healthy",
            runtime=b"running \xc2\xb7 configured: anthropic.claude-opus-5",
            description="restored alpha chat",
        )
        for expected in (
            b"alpha-current-history-marker",
            b"> alpha-draft",
        ):
            if expected not in alpha_plain:
                raise AssertionError(
                    f"restored alpha chat omitted {expected!r}: {alpha_frame!r}"
                )

        # The first alpha request now finishes after alpha was left and opened
        # again. Keeper identity matches; only the load generation can reject
        # this ABA response in favour of the second alpha request above.
        alpha_history.release.set()
        if not wait_for_fixture_event(
            process, master_fd, output, alpha_history.completed, timeout=10.0
        ):
            raise AssertionError("released alpha history fixture did not complete")
        time.sleep(0.1)
        stale_check = resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        stale_plain = CSI_RE.sub(b"", stale_check)
        if b"alpha-current-history-marker" not in stale_plain:
            raise AssertionError(
                f"late first alpha response replaced current history: {stale_check!r}"
            )
        if b"alpha-stale-history-marker" in stale_plain:
            raise AssertionError(
                f"late first alpha response survived generation guard: {stale_check!r}"
            )

        beta_again_start = len(output)
        send_and_wait(process, master_fd, output, b"\x07", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
        wait_for_output(
            process,
            master_fd,
            output,
            b"beta-current-history-marker",
            start=beta_again_start,
            timeout=3.0,
        )
        beta_again = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=ROSTER_BESIDE_CHAT_COLUMNS,
            needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25h",
        )
        beta_again_plain = CSI_RE.sub(b"", beta_again)
        for expected in (b"beta-current-history-marker", b"> beta-draft"):
            if expected not in beta_again_plain:
                raise AssertionError(
                    f"beta chat did not restore {expected!r}: {beta_again!r}"
                )
        escape_to_keeper_detail(process, master_fd, output, name=b"beta")
        os.write(master_fd, b"q")

    return interact


def keeper_calls_fixture() -> HttpResponse:
    return (
        200,
        {
            "keeper": "alpha",
            "count": 2,
            "health": "ok",
            "latest_age_s": 8.0,
            "stale_reason": "fresh",
            "entries": [
                {
                    "ts": 1787534998.4,
                    "keeper": "alpha",
                    "tool": "Read",
                    "input": '{"file_path": "lib/a.ml"}',
                    "output": "sentinel-digest-31506",
                    "wire_outcome": "ok",
                    "duration_ms": 28.4,
                    "turn": 2143,
                },
                {
                    "ts": 1787535017.4,
                    "keeper": "alpha",
                    "tool": "tool_execute",
                    "input": '{"argv": ["dune", "build"]}',
                    "wire_outcome": "error",
                    "duration_ms": 14534.0,
                    "turn": 2144,
                },
            ],
        },
    )


def keeper_calls_interaction() -> Interaction:
    """t on the roster opens the keeper's durable call log."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        # The header is drawn before the asynchronous roster, so t can land
        # while nothing is selected and open no keeper's log at all.
        select_keeper_row(process, master_fd, output, b"alpha")
        pane_start = len(output)
        send_and_wait(
            process,
            master_fd,
            output,
            b"t",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 calls",
        )
        wait_for_output(
            process, master_fd, output, b"tool_execute", start=pane_start, timeout=5.0
        )
        pane = bytes(output[pane_start:])
        for needle, what in (
            (b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 calls (2)", "the count"),
            ("ok \u00b7 latest 8s ago".encode(), "the freshness verdict"),
            ("\u2713".encode(), "the returned-call verdict"),
            (b"#1 tool Read", "the returned-call tool"),
            (b"28ms", "its duration"),
            ("\u2717".encode(), "the failed-call verdict"),
            (b"#2 tool tool_execute", "the failed-call tool"),
            (b"14.5s", "the failure's duration"),
            (b"lib/a.ml", "the recorded input path"),
            (b"sentinel-digest-31506", "the returned call output"),
        ):
            if needle not in pane:
                raise AssertionError(f"Keeper Calls did not draw {what}: {pane!r}")
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


TASK_TOOL_ANSWER = RawHttpResponse(
    200,
    (
        b'event: message\n'
        b'data: {"jsonrpc":"2.0","result":{"content":[{"type":"text",'
        b'"text":"{\\"ok\\":true,\\"task_id\\":\\"task-9\\"}"}],"isError":false}}\n\n'
    ),
    content_type="text/event-stream",
)


def task_dispatch_http_fixtures() -> HttpFixtures:
    fixtures = observer_http_fixtures()
    fixtures["/mcp"] = SequencedHttpResponse(
        [
            RawHttpResponse(
                200,
                json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode(),
                content_type="application/json",
                headers=(("Mcp-Session-Id", "mcp_fixture_session"),),
            ),
            TASK_TOOL_ANSWER,
        ]
    )
    fixtures["/api/v1/keepers/chat/stream"] = (
        503,
        {"error": "stop after the dispatch request capture"},
    )
    return fixtures


def task_dispatch_interaction(requests: HttpRequests) -> Interaction:
    """/task in the composer creates the task over MCP and hands the keeper
    the operator's words with the task id in front."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The closed feed row says the MCP session was opened; it is on
        # Activity's status line, and the composer is read on the Overview.
        tab_until(process, master_fd, output, b"MASC System")
        send_and_wait(process, master_fd, output, b"A", b"MASC Activity")
        wait_for_output(
            process, master_fd, output, b"feed: closed", start=0, timeout=10.0
        )
        tab_until(process, master_fd, output, b"MASC Dashboard")
        send_and_wait(process, master_fd, output, b"i", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        send_and_wait(process, master_fd, output, b"c", b"Esc:detail")
        send_and_wait(process, master_fd, output, b"/task Lanes surface", b"/task Lanes surface")
        os.write(master_fd, b"\r")
        chat_body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        tool_calls = [
            json.loads(body) for path, body in requests if path == "/mcp"
        ]
        add_task = [
            p for p in tool_calls
            if p.get("method") == "tools/call"
            and p.get("params", {}).get("name") == "masc_add_task"
        ]
        if len(add_task) != 1:
            raise AssertionError(f"expected one masc_add_task call: {tool_calls!r}")
        arguments = add_task[0]["params"]["arguments"]
        if arguments.get("title") != "Lanes surface" or "description" in arguments:
            raise AssertionError(f"unexpected add_task arguments: {arguments!r}")
        message = json.loads(chat_body).get("message")
        if message != "[task-9] Lanes surface":
            raise AssertionError(f"keeper message did not carry the task id: {message!r}")
        # The dispatch lands the operator in the keeper's chat, where the
        # send (and its 503 from the fixture) is on screen; the POST bodies
        # above are the proof of what went out.
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def composer_newline_interaction(requests: HttpRequests) -> Interaction:
    """Ctrl-J and Shift+Enter open lines; Return sends.

    Ctrl-J and Return are one byte apart only because the TUI turns off the
    terminal's CR-to-LF translation. With it on, Return arrives as LF -- the
    byte Ctrl-J sends -- and the composer cannot tell them apart. Enhanced
    keys keep Shift+Enter separate as the raw CSI sequence driven below.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        send_and_wait(process, master_fd, output, b"first", composer_showing(b"first"))
        # Ctrl-J. The prompt stays on the first line and the second is indented
        # under it, so the two rows read as one message.
        second_frame = send_and_wait(
            process,
            master_fd,
            output,
            b"\nsecond",
            composer_showing(b"second", prefix=b"    "),
        )
        rendered = CSI_RE.sub(b"", second_frame).decode("utf-8")
        if "> first" not in rendered:
            raise AssertionError(f"composer lost its first line: {rendered!r}")
        if "firstsecond" in rendered:
            raise AssertionError(f"composer joined the two lines: {rendered!r}")

        # Kitty keyboard disambiguation reports Shift+Enter as CSI 13;2u.
        # It opens another line and, like Ctrl-J, must not send on its own.
        third_frame = send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[13;2uthird",
            composer_showing(b"third", prefix=b"    "),
        )
        third_rendered = CSI_RE.sub(b"", third_frame).decode("utf-8")
        if "first" not in third_rendered or "second" not in third_rendered:
            raise AssertionError(
                f"Shift+Enter lost an earlier composer line: {third_rendered!r}"
            )
        posted = [path for path, _body in requests if path.endswith("/chat/stream")]
        if posted:
            raise AssertionError(f"Shift+Enter sent the composer: {posted!r}")

        # Return sends what Ctrl-J and Shift+Enter composed, newlines and all.
        os.write(master_fd, b"\r")
        body = wait_for_http_request(
            process,
            master_fd,
            output,
            requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body)["message"]
        if message != "first\nsecond\nthird":
            raise AssertionError(f"the newline did not survive the send: {message!r}")
        # The fixture answers 503, so the turn settles rather than streaming.
        # Esc then leaves the pane instead of interrupting, and q quits from
        # the detail view -- in the pane it would be typed into the composer.
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def run_quit_waiting_regression(executable: str) -> None:
    fixture = AtomicChatFixture()
    run_terminal_scenario(
        executable,
        description="Quit names input retained during pending Esc acknowledgement",
        interact=quit_names_waiting_messages_interaction(fixture),
        http_fixtures=fixture.fixtures,
        refresh=0.2,
    )


def run_chat_retained_stop_regression(executable: str) -> None:
    retained = AtomicChatFixture(retained_after_resume_message="retained-original")
    run_terminal_scenario(executable, description="Stopped input stays retained after ack until explicit Enter",
        interact=chat_retained_stop_interaction(retained), http_fixtures=retained.fixtures, refresh=0.2)


# RFC-0429 §3.3 draws a mermaid fence rather than lexing it, and §4 asks a
# chat PTY scenario to show that the drawing reaches the screen. The golden
# suite (test_tui_mermaid) already pins what the renderer produces; what it
# cannot see is the wiring -- chat text goes through Masc_tui_render's
# [chat_markdown], which reaches Masc_tui_markdown under a local alias, and a
# fence whose language is not routed there falls through to the plain code
# path and prints its own source.
MERMAID_CHAT_SOURCE_ARROW = b"-->"
MERMAID_CHAT_LABELS = (b"Intake", b"Gate", b"Keeper")


def mermaid_chat_history_fixture() -> HttpResponse:
    return (
        200,
        [
            {
                "id": "mermaid-chat-reply",
                "role": "assistant",
                "content": (
                    "Here is the shape:\n\n"
                    "```mermaid\n"
                    "graph TD\n"
                    "  intake[Intake] --> gate{Gate}\n"
                    "  gate --> keeper[Keeper]\n"
                    "```\n"
                ),
                "ts": 1787348491.3,
            }
        ],
    )


def mermaid_chat_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    # run_terminal_scenario already opens the pty at 30x100, so resizing to
    # that size draws nothing and a wait on the first screen starves.
    wait_for_output(
        process, master_fd, output, b"MASC Dashboard", start=0, timeout=5.0
    )
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    # Enter opens the keeper's Info tabs; the transcript hangs off the palette.
    # The wait needle is a node label because the fallback prints the source,
    # which carries the labels too -- the assertions below, not this wait,
    # decide whether it was drawn.
    drawn = palette_go(
        process, master_fd, output, b"keeper alpha", MERMAID_CHAT_LABELS[0]
    )
    # A frame carries only the rows that changed, so the box may have been
    # written before the row this wait returned on. Ask the reconstructed
    # screen, not the last frame.
    screen = screen_text(drawn)

    missing = [label for label in MERMAID_CHAT_LABELS if label not in screen]
    if missing:
        raise AssertionError(
            "the mermaid fence lost its node labels "
            f"{[label.decode() for label in missing]}: {screen!r}"
        )
    if MERMAID_CHAT_SOURCE_ARROW in screen:
        raise AssertionError(
            "the mermaid fence printed its own source instead of a drawing -- "
            "either the fence never reached Masc_tui_mermaid, or the render "
            f"failed and fell back to the source: {screen!r}"
        )
    # Labels without a frame around them would also satisfy the two checks
    # above, and that is what the plain code path draws.
    if not any(glyph in screen for glyph in ("┌".encode(), "─".encode(), "│".encode())):
        raise AssertionError(
            f"the node labels are on screen but nothing was drawn around them: {screen!r}"
        )

    # Leaving the transcript before q: the chat surface does not quit on q,
    # and where Escape lands (keeper detail or the list) is not what this
    # scenario is about. send_and_wait only scans bytes written after the key,
    # so the repainted tab bar is enough to say the surface changed.
    send_and_wait(process, master_fd, output, b"\x1b", b"Keepers")
    os.write(master_fd, b"q")


def run_mermaid_chat_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="A mermaid fence in keeper chat is drawn, not printed",
        interact=mermaid_chat_interaction,
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": mermaid_chat_history_fixture(),
            "/api/v1/keepers/alpha/chat/history/page": (
                200,
                {"messages": [], "has_more": False, "next_before": None},
            ),
        },
    )


def run_chat_clarity_regression(executable: str) -> None:
    fixtures = chat_clarity_http_fixtures()
    tool_calls_path = "/api/v1/keepers/alpha/tool-calls?limit=100"
    tool_calls_response = fixtures[tool_calls_path]
    if not isinstance(tool_calls_response, tuple):
        raise AssertionError("chat clarity tool-call fixture must be a JSON response")
    refreshed_body = copy.deepcopy(tool_calls_response[1])
    if not isinstance(refreshed_body, dict):
        raise AssertionError("chat clarity tool-call fixture body must be a JSON object")
    refreshed_body["entries"][0]["output"] = "panel-output-refreshed"
    tool_calls_gate = GatedHttpResponse(
        tool_calls_response,
        subsequent_response=(tool_calls_response[0], refreshed_body),
    )
    fixtures[tool_calls_path] = tool_calls_gate
    run_terminal_scenario(
        executable,
        description="Keeper chat mode and Tool detail clarity",
        interact=chat_visibility_modes_interaction(tool_calls_gate),
        http_fixtures=fixtures,
    )
    run_terminal_scenario(
        executable,
        description="Skill usage date clarity",
        interact=skills_usage_clarity_interaction(),
        http_fixtures=skills_usage_clarity_http_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Keeper oversized viewport gap under NO_COLOR",
        interact=viewport_gap_interaction,
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": viewport_gap_history_fixture(),
            "/api/v1/keepers/alpha/chat/history/page": (
                viewport_gap_history_page_fixture()
            ),
        },
        extra_env={"NO_COLOR": "1"},
    )
