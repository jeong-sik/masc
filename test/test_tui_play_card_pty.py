"""/play invite draws the invite's link and a QR on a card, and keeps them until closed.

The server answers an invite once and keeps only a hash of its link, so the
card is where the link is read: it stays until Esc or q, Enter does not close
it, [y] copies the link exactly as issued, a paste does not reach the composer
under it, /play link opens it again, /play link <name> opens an earlier one,
and a link longer than the card scrolls to its last byte.

SOURCE_MODULES makes the PR edited-tests selector run this scenario when the
card, the request, the command parser, the scrolling frame or the terminal
writer changes.
"""
import base64
import hashlib
import json
import os
import re
import sys
import zlib
from pathlib import Path

import tui_keyboard_harness as h
from tui_keyboard_chat import PASTE_START, PASTE_END



TOKEN = "3f9a1c07d25b48e6a0c1d7e2f4b86a59c3d10e7f2a4b6c8d9e0f1a2b3c4d5e6f"
LINK = "https://masc.example.com/play#" + TOKEN
SECOND_TOKEN = "9c1e2d3f4a5b60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9"
SECOND_LINK = "https://masc.example.com/play#" + SECOND_TOKEN
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
PASTED = b"pasted-under-the-card"
QR_NEEDS = re.compile(rb"the QR needs a window of (\d+) columns by (\d+) rows")

# The first advice line under the heading: on screen at the top of the card and
# scrolled off at its end.
TOP_OF_CARD = b"Send this link to one person"
KEY_DOWN = b"\x1b[B"
KEY_UP = b"\x1b[A"
WHEEL_DOWN = b"\x1b[<65;5;5M"
WHEEL_UP = b"\x1b[<64;5;5M"
# More steps than the long card has rows to give, so a way of scrolling ends at
# the top or the end whichever row it started from.
SCROLL_STEPS = 30

# The 94-byte fixture link needs QR version 6 at the library's default error
# correction (level M holds 84 bytes in version 5 and 106 in version 6): 41
# modules across and a 4-module quiet zone on each side, so 49 columns of
# cells. A cell stacks two pixel rows, and 49 of them take 25 text rows.
QR_COLUMNS = 49
QR_TEXT_ROWS = 25

# The card's body budget is the window less the composer row, the agenda strip
# when it shows, and five rows of frame. The text above the QR and the QR need
# 33 of them: 37 or 38 are left in 44 rows, 23 or 24 in 30.
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


# QR pixels are opaque black/white; portraits use this glyph too, with
# their own colours or a default background for a transparent pixel. Decode
# actual SGR colour state so even one remaining QR cell fails the close check.
Color = tuple[str, tuple[int, ...]]
QR_COLORS: frozenset[Color] = frozenset({
    ("rgb", (0, 0, 0)), ("rgb", (255, 255, 255)),
    # Fixed xterm-256 cube entries, independent of the terminal's ANSI theme.
    ("indexed", (16,)), ("indexed", (231,)),
})
SGR_OR_HALF_BLOCK = re.compile(rb"\x1b\[([0-9;]*)m|" + UPPER_HALF_BLOCK)


def qr_row_cells(text: bytes) -> int:
    foreground: Color | None = None
    background: Color | None = None
    count = 0
    for token in SGR_OR_HALF_BLOCK.finditer(text):
        encoded = token.group(1)
        if encoded is None:
            if foreground in QR_COLORS and background in QR_COLORS:
                count += 1
            continue
        parameters = [int(value or b"0") for value in encoded.split(b";")]
        index = 0
        while index < len(parameters):
            code = parameters[index]
            index += 1
            if code == 0:
                foreground = background = None
            elif code == 39:
                foreground = None
            elif code == 49:
                background = None
            elif code in (38, 48):
                color: Color | None = None
                if index < len(parameters):
                    mode = parameters[index]
                    index += 1
                    size = {2: 3, 5: 1}.get(mode, 0)
                    if size and index + size <= len(parameters):
                        color = ("rgb" if mode == 2 else "indexed",
                                 tuple(parameters[index:index + size]))
                        index += size
                if code == 38:
                    foreground = color
                else:
                    background = color
            elif 30 <= code <= 37 or 90 <= code <= 97:
                foreground = None  # ANSI theme colours are not fixed QR pixels.
            elif 40 <= code <= 47 or 100 <= code <= 107:
                background = None
    return count


def qr_cells(drawn: bytes) -> list[int]:
    """Opaque black/white QR cells per painted screen row, top row first."""
    rows = h.screen_rows(drawn, preserve_styles=True)
    return [count for _, text in sorted(rows.items())
            if (count := qr_row_cells(text))]


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
    h.tab_until(process, fd, output, b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    h.send_and_wait(process, fd, output, b"m", CHAT_TITLE)


def resize(process, fd, output, *, rows: int, needle, columns: int = WIDE_COLUMNS) -> bytes:
    return h.resize_and_wait(
        process, fd, output,
        rows=rows, columns=columns, needle=needle, controls=(h.FULL_REDRAW,),
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
    links = {"minsu": LINK, "jiwon": SECOND_LINK}

    def issue(body: bytes):
        if not body:
            return 200, {"invites": []}
        name = json.loads(body)["name"]
        return 201, {"name": name, "expires_at": EXPIRES, "link": links[name]}

    fixtures[INVITES] = h.RequestHttpResponse(issue)

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

        # A window too short for the whole QR draws none of it and says how big
        # the window must be: a QR cut short scans as nothing. The sentence is
        # in window units, so it is checked by resizing to exactly that.
        resize(process, fd, output, rows=SHORT_ROWS, needle=b"the QR needs a window of")
        drawn = settled(process, fd, output)
        assert qr_cells(drawn) == [], "a QR was drawn in a window too short for it"
        assert LINK.encode() in h.screen_text(drawn), (
            "the link is what remains when the QR does not fit"
        )
        needs = QR_NEEDS.search(h.screen_text(drawn))
        assert needs is not None, h.screen_text(drawn)
        need_columns, need_rows = int(needs.group(1)), int(needs.group(2))
        assert need_columns == WIDE_COLUMNS, (
            f"a window already wide enough was asked for {need_columns} columns"
        )
        assert need_rows > SHORT_ROWS, f"the QR asked for {need_rows} rows in {SHORT_ROWS}"
        resize(
            process, fd, output, rows=need_rows - 1, columns=need_columns,
            needle=b"the QR needs a window of",
        )
        assert qr_cells(settled(process, fd, output)) == [], (
            f"a QR was drawn one row short of the {need_rows} it asked for"
        )
        resize(
            process, fd, output, rows=need_rows, columns=need_columns,
            needle=UPPER_HALF_BLOCK,
        )
        assert qr_cells(settled(process, fd, output)) == [QR_COLUMNS] * QR_TEXT_ROWS, (
            f"no QR at the {need_rows} rows it asked for"
        )
        resize(process, fd, output, rows=TALL_ROWS, needle=UPPER_HALF_BLOCK)

        # A terminal that ignores OSC 52 has only the mouse to copy the link
        # with, so Ctrl-T still hands the mouse back while the card is open.
        press(process, fd, output, CTRL_T, MOUSE_TRACKING_OFF)
        press(process, fd, output, CTRL_T, MOUSE_TRACKING_ON)
        assert qr_cells(settled(process, fd, output)) == [QR_COLUMNS] * QR_TEXT_ROWS, (
            "Ctrl-T closed the card"
        )

        # A paste is keys. Under the card it would land in the composer, and
        # the next Enter would send it to the Keeper: [y] puts the link on the
        # clipboard, so a paste is what an operator does next. It is dropped,
        # and [y] straight after it shows the card still owns the keys.
        h.write_all(fd, output, PASTE_START + PASTED + PASTE_END)
        copied = press_y(process, fd, output)
        assert copied == LINK.encode(), f"the clipboard got {copied!r}"
        h.wait_for_output(
            process, fd, output, b"Asked the terminal to copy the invite link",
            start=0, timeout=5,
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
        assert PASTED not in after, "a paste under the card reached the composer"
        # The conversation says an invite was issued, and never carries its link.
        assert b"Play invite minsu issued" in after, after

        # /play link brings the card back, and it is the same link.
        type_line(process, fd, output, b"/play link")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Play invite")
        assert qr_cells(settled(process, fd, output)) == [QR_COLUMNS] * QR_TEXT_ROWS
        assert press_y(process, fd, output) == LINK.encode()
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)

        # A second invite keeps the first link available by name while the
        # unnamed command continues to reopen the newest card.
        type_line(process, fd, output, b"/play invite jiwon 3")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Play invite")
        drawn = settled(process, fd, output)
        assert SECOND_LINK.encode() in h.screen_text(drawn), "the second card lost its link"
        assert press_y(process, fd, output) == SECOND_LINK.encode()
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        assert b"Play invite jiwon issued" in h.screen_text(settled(process, fd, output))
        type_line(process, fd, output, b"/play link minsu")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Play invite")
        assert press_y(process, fd, output) == LINK.encode(), (
            "/play link minsu did not retain the earlier one-time link"
        )
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        type_line(process, fd, output, b"/play link")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Play invite")
        assert press_y(process, fd, output) == SECOND_LINK.encode(), (
            "/play link did not bring back the newest card"
        )
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)

        # A name nothing was issued under has no card to open. The operator is
        # told so, and no other invite's link takes its place.
        type_line(process, fd, output, b"/play link nobody")
        h.send_and_wait(process, fd, output, b"\r", b"No local play link for nobody")
        assert b"MASC Play invite" not in h.screen_text(settled(process, fd, output)), (
            "an unknown name opened a card"
        )

        leave(process, fd, output)

    h.run_terminal_scenario(
        binary,
        description="the invite card keeps the link until it is closed",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )
    assert posted(requests, INVITES) == [
        {"name": "minsu", "hours": 2},
        {"name": "jiwon", "hours": 3},
    ], f"the requests were {posted(requests, INVITES)!r}"


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


def unreadable_link(binary: str) -> None:
    """The server made the invite, but its link is not one a card can draw (a
    public base URL with no scheme is enough). The card says why and never
    draws the link, and the request is over: the next invite is sent."""
    requests: list[tuple[str, bytes]] = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[CHAT_HISTORY] = (200, [])

    def issue(body: bytes):
        if not body:
            return 200, {"invites": []}
        if json.loads(body)["name"] == "minsu":
            return 201, {
                "name": "minsu", "expires_at": EXPIRES,
                "link": "masc.example.com/play#" + TOKEN,
            }
        return 409, {"error": "not_ready", "message": "auth is off"}

    fixtures[INVITES] = h.RequestHttpResponse(issue)

    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        resize(process, fd, output, rows=SHORT_ROWS, needle=CHAT_TITLE)
        type_line(process, fd, output, b"/play invite minsu 2")
        h.send_and_wait(
            process, fd, output, b"\r", b"play invite may exist, but its link cannot be shown"
        )
        drawn = settled(process, fd, output)
        assert b"MASC Play invite" not in drawn, "an unreadable link opened a card"
        assert TOKEN.encode() not in h.screen_text(drawn), "the unreadable link was drawn"

        # The failed request released the guard: this one reaches the server,
        # and its own answer is what the footer says.
        type_line(process, fd, output, b"/play invite jiwon 3")
        h.send_and_wait(process, fd, output, b"\r", b"HTTP 409: auth is off")
        leave(process, fd, output)

    h.run_terminal_scenario(
        binary,
        description="an unreadable invite link is never drawn and does not block the next invite",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )
    assert posted(requests, INVITES) == [
        {"name": "minsu", "hours": 2},
        {"name": "jiwon", "hours": 3},
    ], f"the requests were {posted(requests, INVITES)!r}"


def without_colour(binary: str) -> None:
    """Under NO_COLOR there is no black and white the card may draw in, and a
    QR in the terminal's own colours scans as nothing. It draws none, says so,
    and the link is still there to copy and send."""
    requests: list[tuple[str, bytes]] = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[CHAT_HISTORY] = (200, [])
    fixtures[INVITES] = ISSUED

    def interact(process, fd, _slave, output, _base):
        # NO_COLOR draws no bold either, so the chat is opened by the key the
        # emblem scenario uses and left by Esc.
        h.tab_until(process, fd, output, b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", CHAT_TITLE)
        resize(process, fd, output, rows=TALL_ROWS, needle=CHAT_TITLE)
        type_line(process, fd, output, b"/play invite minsu 2")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Play invite")
        drawn = settled(process, fd, output)
        screen = h.screen_text(drawn)
        assert LINK.encode() in screen, f"the card lost the link: {screen!r}"
        assert qr_cells(drawn) == [], "a QR was drawn with no colour to draw it in"
        assert b"cannot draw the black and white a QR needs" in screen, screen
        assert press_y(process, fd, output) == LINK.encode()
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="the invite card draws no QR under NO_COLOR and keeps the link",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
        extra_env={"NO_COLOR": "1"},
    )


def second_request_is_refused(binary: str) -> None:
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

            # One request at a time: a second command sent while the first
            # answer is on its way is refused and never reaches the server.
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
        description="a second invite request is refused until the first answers",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )
    assert posted(requests, INVITES) == [{"name": "minsu", "hours": 2}], (
        f"the second request reached the server: {posted(requests, INVITES)!r}"
    )


def long_link_scrolls_to_end(binary: str) -> None:
    long_link = "https://masc.example.com/play#" + ("a" * 512) + "deadbeef"
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[CHAT_HISTORY] = (200, [])
    fixtures[INVITES] = h.RequestHttpResponse(
        lambda body: (201, {"name": "minsu", "expires_at": EXPIRES, "link": long_link})
    )

    def interact(process, fd, _slave, output, _base):
        open_chat(process, fd, output)
        resize(process, fd, output, rows=20, columns=60, needle=CHAT_TITLE)
        type_line(process, fd, output, b"/play invite minsu 2")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Play invite")
        opened = h.screen_text(settled(process, fd, output))
        assert TOP_OF_CARD in opened, "the card did not open at its top"
        assert b"deadbeef" not in opened, "the long link did not overflow the small card"
        h.send_and_wait(process, fd, output, b"G", b"deadbeef")
        at_end = h.screen_text(settled(process, fd, output))
        assert b"deadbeef" in at_end, "scrolling to the end did not expose the token suffix"
        assert TOP_OF_CARD not in at_end, "the end of the card still shows its top"
        assert press_y(process, fd, output) == long_link.encode()

        # g goes back to the top. From there each way of scrolling reaches the
        # end and comes back, and stops at both.
        h.send_and_wait(process, fd, output, b"g", TOP_OF_CARD)
        assert b"deadbeef" not in h.screen_text(settled(process, fd, output)), (
            "g did not return to the top"
        )
        for way, up, down in (
            ("j and k", b"k", b"j"),
            ("the arrow keys", KEY_UP, KEY_DOWN),
            ("the mouse wheel", WHEEL_UP, WHEEL_DOWN),
        ):
            h.send_and_wait(process, fd, output, down * SCROLL_STEPS, b"deadbeef")
            assert TOP_OF_CARD not in h.screen_text(settled(process, fd, output)), (
                f"{way} did not scroll down to the end"
            )
            h.send_and_wait(process, fd, output, up * SCROLL_STEPS, TOP_OF_CARD)
            assert b"deadbeef" not in h.screen_text(settled(process, fd, output)), (
                f"{way} did not scroll back to the top"
            )
        h.send_and_wait(process, fd, output, b"\x1b", CHAT_TITLE)
        leave(process, fd, output)

    h.run_terminal_scenario(
        binary,
        description="a long invite link scrolls to its last token bytes",
        interact=interact,
        http_fixtures=fixtures,
    )


def run(binary: str) -> None:
    issued_card(binary)
    refused_invite(binary)
    unreadable_link(binary)
    without_colour(binary)
    second_request_is_refused(binary)
    long_link_scrolls_to_end(binary)
    print("play invite card: PASS")


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
