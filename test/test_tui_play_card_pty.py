"""/play invite draws the invite's link and a QR on a card, and keeps them until closed.

The server answers an invite once, and the link it carries is the only way in,
so the card is the link's only copy on this screen: it stays until Esc or q,
Enter does not close it, [y] copies the link exactly as issued, and
/play link brings it back.

SOURCE_MODULES makes the PR edited-tests selector run this scenario when the
card, the request or the terminal writer changes.
"""
import base64
import hashlib
import json
import os
import re
import sys
import zlib
from pathlib import Path

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_http.ml",
    "bin/masc_tui_play_card.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "lib/tui_decode.ml",
)

TOKEN = "3f9a1c07d25b48e6a0c1d7e2f4b86a59c3d10e7f2a4b6c8d9e0f1a2b3c4d5e6f"
LINK = "https://masc.example.com/play#" + TOKEN
EXPIRES = "2026-09-30T04:12:33Z"
INVITES = "/api/v1/play/invites"
ISSUED = (201, {"name": "minsu", "expires_at": EXPIRES, "link": LINK})
OSC52 = re.compile(rb"\x1b\]52;c;([A-Za-z0-9+/=]+)\x07")
UPPER_HALF_BLOCK = "▀".encode()
CTRL_T = b"\x14"
MOUSE_TRACKING_OFF = b"\x1b[?1006;1000l"
MOUSE_TRACKING_ON = b"\x1b[?1006;1000h"
CHAT_TITLE = "Keepers ▸ alpha ▸ chat".encode()
CHAT_HISTORY = "/api/v1/keepers/alpha/chat/history"

# The 94-byte fixture link needs QR version 6 at the library's default error
# correction (level M holds 84 bytes in version 5 and 106 in version 6): 41
# modules across and a 4-module quiet zone on each side, so 49 columns of
# cells. A cell stacks two pixel rows, and 49 of them take 25 text rows.
QR_COLUMNS = 49
QR_TEXT_ROWS = 25

# The card's body budget is the window less the composer row, the agenda strip
# when it shows, and five rows of frame. The text above the QR and the QR need
# 32 of them: 37 or 38 are left in 44 rows, 23 or 24 in 30.
TALL_ROWS = 44
SHORT_ROWS = 30
WIDE_COLUMNS = 110


def copied_link(frame: bytes) -> bytes:
    match = OSC52.search(frame)
    assert match is not None, "the terminal clipboard write is missing"
    return base64.b64decode(match.group(1), validate=True)


def settled(process, fd, output) -> bytes:
    """Everything the TUI has written, once it has been quiet for a moment, so
    the screen read from it is a finished frame and not one still arriving."""
    h.drain_until_quiet(process, fd, output)
    return bytes(output)


def qr_cells(drawn: bytes) -> list[int]:
    """QR cells on each screen row that holds any, top row first."""
    rows = h.screen_rows(drawn)
    return [
        text.count(UPPER_HALF_BLOCK)
        for _, text in sorted(rows.items())
        if UPPER_HALF_BLOCK in text
    ]


def press(process, fd, output, key: bytes, needle) -> int:
    """Send [key] and wait for [needle] alone, not for the frame after it: a
    key that leaves the screen as it was writes no frame at all. Returns where
    the key's output starts."""
    h.read_available(fd, output)
    start = len(output)
    h.write_all(fd, output, key)
    h.wait_for_output(process, fd, output, needle, start=start, timeout=3.0)
    return start


def press_y(process, fd, output) -> bytes:
    start = press(process, fd, output, b"y", OSC52)
    return copied_link(bytes(output[start:]))


def open_chat(process, fd, output):
    h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    h.send_and_wait(process, fd, output, b"m", CHAT_TITLE)


def resize(process, fd, output, *, rows: int, needle) -> bytes:
    return h.resize_and_wait(
        process, fd, output,
        rows=rows, columns=WIDE_COLUMNS, needle=needle, controls=(h.FULL_REDRAW,),
    )


def type_line(process, fd, output, line: bytes) -> None:
    h.send_and_wait(process, fd, output, line, h.composer_showing(line))


def leave(process, fd, output) -> None:
    h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
    os.write(fd, b"q")


def posted(requests, path: str) -> list:
    return [json.loads(body) for request, body in requests if request == path and body]


def issued_card(binary: str) -> None:
    binary_digest = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    requests: list[tuple[str, bytes]] = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[CHAT_HISTORY] = (200, [])
    fixtures[INVITES] = ISSUED

    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        resize(process, fd, output, rows=TALL_ROWS, needle=CHAT_TITLE)
        type_line(process, fd, output, b"/play invite minsu 2")
        card = h.send_and_wait(process, fd, output, b"\r", b"MASC Play invite")

        drawn = settled(process, fd, output)
        screen = h.screen_text(drawn)
        assert LINK.encode() in screen, f"the card lost the link: {screen!r}"
        assert b"minsu" in screen and EXPIRES.encode() in screen, screen
        assert qr_cells(drawn) == [QR_COLUMNS] * QR_TEXT_ROWS, (
            f"the QR is not {QR_TEXT_ROWS} rows of {QR_COLUMNS} cells: {qr_cells(drawn)}"
        )
        # The frame that drew the card, for a reader who wants to scan it.
        print("PLAY_CARD_PTY " + json.dumps({
            "columns": WIDE_COLUMNS, "rows": TALL_ROWS,
            "binary_sha256": binary_digest, "link": LINK,
            "encoding": "zlib+base64",
            "pty": base64.b64encode(zlib.compress(card)).decode(),
        }), flush=True)

        # A window too short for the whole QR draws none of it and says what it
        # needs: a QR cut short scans as nothing.
        resize(process, fd, output, rows=SHORT_ROWS, needle=b"the QR needs")
        drawn = settled(process, fd, output)
        assert qr_cells(drawn) == [], "a QR was drawn in a window too short for it"
        assert LINK.encode() in h.screen_text(drawn), (
            "the link is what remains when the QR does not fit"
        )
        resize(process, fd, output, rows=TALL_ROWS, needle=UPPER_HALF_BLOCK)
        assert qr_cells(settled(process, fd, output)) == [QR_COLUMNS] * QR_TEXT_ROWS

        # A terminal that ignores OSC 52 has only the mouse to copy the link
        # with, so Ctrl-T still hands the mouse back while the card is open.
        press(process, fd, output, CTRL_T, MOUSE_TRACKING_OFF)
        press(process, fd, output, CTRL_T, MOUSE_TRACKING_ON)
        assert qr_cells(settled(process, fd, output)) == [QR_COLUMNS] * QR_TEXT_ROWS, (
            "Ctrl-T closed the card"
        )

        copied = press_y(process, fd, output)
        assert copied == LINK.encode(), f"the clipboard got {copied!r}"
        h.wait_for_output(
            process, fd, output, b"Copied the invite link", start=0, timeout=5
        )
        assert TOKEN.encode() not in h.screen_text(
            settled(process, fd, output)
        ).replace(LINK.encode(), b""), "the token is drawn outside the link rows"

        # An Enter pressed while the answer was on its way lands after the card
        # opens. It must not close it: [y] still copying proves the card took
        # the key.
        os.write(fd, b"\r")
        again = press_y(process, fd, output)
        assert again == LINK.encode(), "Enter closed the card"

        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        drawn = settled(process, fd, output)
        after = h.screen_text(drawn)
        assert TOKEN.encode() not in after, "the link stayed on screen after the card closed"
        assert qr_cells(drawn) == [], "QR cells stayed on screen after the card closed"
        # The conversation says an invite was issued, and never carries its link.
        assert b"Play invite minsu issued" in after, after

        # /play link brings the card back, and it is the same link.
        type_line(process, fd, output, b"/play link")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Play invite")
        assert qr_cells(settled(process, fd, output)) == [QR_COLUMNS] * QR_TEXT_ROWS
        assert press_y(process, fd, output) == LINK.encode()
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)

        leave(process, fd, output)

    h.run_terminal_scenario(
        binary,
        description="the invite card keeps the link until it is closed",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )
    assert posted(requests, INVITES) == [{"name": "minsu", "hours": 2}], (
        f"the request was {posted(requests, INVITES)!r}"
    )


def refused_invite(binary: str) -> None:
    requests: list[tuple[str, bytes]] = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[CHAT_HISTORY] = (200, [])
    # The wording is the server's; what is under test is that the operator
    # reads its sentence, not the code alone.
    fixtures[INVITES] = (
        409,
        {
            "error": "not_ready",
            "message": "an invite needs require_token",
            "missing": ["no_public_base_url"],
        },
    )

    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        # The refusal is one footer line, and the footer keeps what it can of
        # a long one: this width leaves the sentence its room.
        resize(process, fd, output, rows=SHORT_ROWS, needle=CHAT_TITLE)
        type_line(process, fd, output, b"/play invite minsu 24")
        h.send_and_wait(
            process, fd, output, b"\r", b"HTTP 409: an invite needs require_token"
        )
        drawn = settled(process, fd, output)
        assert b"MASC Play invite" not in drawn, "a refused invite opened a card"
        assert b"HTTP 409: not_ready" not in h.screen_text(drawn), (
            "the refusal showed the code and not the server's sentence"
        )
        leave(process, fd, output)

    h.run_terminal_scenario(
        binary,
        description="a refused invite says why and opens no card",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )
    assert posted(requests, INVITES) == [{"name": "minsu", "hours": 24}]


def second_request_waits(binary: str) -> None:
    requests: list[tuple[str, bytes]] = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[CHAT_HISTORY] = (200, [])
    held = h.GatedHttpResponse(ISSUED, hold_seconds=30.0)
    fixtures[INVITES] = held

    def interact(process, fd, _slave, output, _base):
        try:
            open_chat(process, fd, output)
            resize(process, fd, output, rows=TALL_ROWS, needle=CHAT_TITLE)
            type_line(process, fd, output, b"/play invite minsu 2")
            os.write(fd, b"\r")
            assert h.wait_for_fixture_state(
                process, fd, output, held.requested.is_set, timeout=5.0
            ), "the first invite request never reached the server"

            # Its answer would open a card over the first one, and the server
            # will not show the first link again.
            type_line(process, fd, output, b"/play invite jiwon 3")
            h.send_and_wait(
                process, fd, output, b"\r", b"An invite request is still waiting"
            )
            held.release.set()
            h.wait_for_output(process, fd, output, b"MASC Play invite", start=0, timeout=5)
            assert qr_cells(settled(process, fd, output)) == [QR_COLUMNS] * QR_TEXT_ROWS
            h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
            leave(process, fd, output)
        finally:
            held.release.set()

    h.run_terminal_scenario(
        binary,
        description="a second invite request waits for the first card",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )
    assert posted(requests, INVITES) == [{"name": "minsu", "hours": 2}], (
        f"the second request reached the server: {posted(requests, INVITES)!r}"
    )


def run(binary: str) -> None:
    issued_card(binary)
    refused_invite(binary)
    second_request_waits(binary)
    print("play invite card: PASS")


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
