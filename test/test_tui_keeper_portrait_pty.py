"""A Keeper's own portrait at the head of its detail, drawn by the real TUI in
a pseudo-terminal: a half-block mosaic beside the Identity facts, gone from a
terminal too short to spare its rows and back when the terminal grows, not
drawn at all under NO_COLOR, and real pixels over the band's rows where the
terminal answers the Kitty graphics query."""
from __future__ import annotations

import os
import hashlib
import copy
import threading
import json
import time
import re
import sys
from collections.abc import Callable
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_startup as _keyboard_startup



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
MOSAIC_BAND_ROWS = 8
MOSAIC_BAND_COLS = 16
PIXEL_BAND_ROWS = 4
# Where a portrait cell may sit: the frame's two cells, the fact indent, and
# the band. A half block further right is not the portrait.
PORTRAIT_CELLS = 2 + 2 + MOSAIC_BAND_COLS
# A 30-row terminal fits the mosaic and facts; 24 rows give all space to facts.
# Pixel icons use four rows; Items keeps its larger outfit preview.
TALL_ROWS = 30
SHORT_ROWS = 24
COLUMNS = 100
# CSI 6 ; height ; width t: the terminal saying a cell is 10 px wide and 20
# tall, then its answer to the graphics query.
KITTY_TERMINAL_REPLIES = b"\x1b[6;20;10t" + _keyboard_chat.GRAPHICS_SUPPORTED_REPLY
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


ITEM_CATALOG = [
    ("glasses", "face"), ("shades", "face"), ("eye_patch", "face"),
    ("plaster", "face"), ("freckles", "face"), ("beard", "face"),
    ("scarf", "neck"), ("bow_tie", "neck"), ("medal", "neck"),
    ("bow", "head"), ("crown", "head"), ("beanie", "head"),
    ("book", "hand"), ("mug", "hand"), ("quill", "hand"),
    ("dish_gilt", "base"), ("dish_silver", "base"), ("dish_oak", "base"),
]


class ItemWorkspaceFixture:
    """Synthetic Item server using the same workspace as fixture health by
    default. A blind-window scenario can replace only its serving workspace.
    The real route's workspace comparison is covered by the router suite.
    """

    def __init__(self, response: _keyboard_harness.HttpResponse | Callable[[], _keyboard_harness.HttpResponse]):
        self.response = response
        self.base_path: str | None = None
        self.served_base_path: str | None = None
        self.requests: list[dict[str, object]] = []

    def prepare(self, base):
        self.base_path = str(Path(base).resolve())
        self.served_base_path = self.base_path

    def read(self, path):
        expected = parse_qs(urlsplit(path).query, keep_blank_values=True).get("expected_workspace")
        assert expected is not None and len(expected) == 1, "TUI Item request omitted its workspace binding"
        assert self.served_base_path is not None
        captured_root = self.served_base_path
        if not expected[0].strip():
            result = 400, {"error": "expected workspace must not be blank"}
        elif expected[0] != captured_root:
            result = 409, {"error": "Server workspace changed; refresh its identity before reading Item accounts"}
        else:
            self.requests.append({"expected": expected[0], "served": captured_root, "matched": True})
            return self.response() if callable(self.response) else self.response
        self.requests.append({"expected": expected[0], "served": captured_root, "matched": False})
        return result


def capture_item_screen(output: bytearray, name: str) -> None:
    """Keep the actual terminal bytes and their last completed screen."""
    artifact_root = os.environ.get("RUNNER_TEMP")
    if artifact_root is None:
        return
    captures = Path(artifact_root) / "keeper-items-tui"
    captures.mkdir(parents=True, exist_ok=True)
    rows = last_frame_rows(output)
    (captures / f"{name}.txt").write_bytes(
        b"\n".join(text for _, text in sorted(rows.items())) + b"\n")
    (captures / f"{name}.pty").write_bytes(output)


def last_frame_rows(output: bytearray, *, preserve_styles: bool = False) -> dict[int, bytes]:
    """The screen as of the last completed frame."""
    end = output.rfind(_keyboard_harness.FRAME_END)
    assert end >= 0, "no frame was completed"
    drawn = PLACED_PICTURE.sub(b"", bytes(output[: end + len(_keyboard_harness.FRAME_END)]))
    return _keyboard_harness.screen_rows(drawn, preserve_styles=preserve_styles)


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
    number = _keyboard_harness.screen_row_of(rows, needle)
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
    identity_row(rows)
    assert row_of(rows, b"Current Work") > row_of(rows, PAUSED_ROW), \
        f"{why}, Current Work obscured the Identity facts: {rows!r}"


def assert_portrait_beside_identity(output: bytearray) -> None:
    rows = last_frame_rows(output)
    identity = identity_row(rows)
    band = portrait_rows(rows)
    assert band, "the detail drew no portrait: " + repr(rows)
    assert band[0] == identity and band[-1] < identity + MOSAIC_BAND_ROWS, \
        f"the portrait is not the {MOSAIC_BAND_ROWS} rows beside Identity: rows {band}, Identity {identity}"
    assert len(band) >= MOSAIC_BAND_ROWS // 2, f"too little of the portrait drew: rows {band}"
    for number, needle in ((identity, IDENTITY),
                           (row_of(rows, NAME_ROW), NAME_ROW),
                           (row_of(rows, PAUSED_ROW), PAUSED_ROW)):
        text = rows[number].decode("utf-8", "replace")
        cells = [text.find(cell) for cell in HALF_BLOCK if cell in text]
        assert cells and min(cells) < text.find(needle.decode()), \
            f"{needle!r} is not beside the portrait: {text!r}"
    assert b"alpha" in rows[row_of(rows, NAME_ROW)], "the Name row lost the name"
    assert row_of(rows, b"Current Work") > row_of(rows, PAUSED_ROW), \
        f"Current Work obscured the Identity facts: {rows!r}"
    styled = last_frame_rows(output, preserve_styles=True)
    assert FOREGROUND_ESCAPE in styled[identity], "the portrait was drawn without colour"


def open_alpha_detail(process, fd, output) -> None:
    _keyboard_harness.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
    _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
    _keyboard_harness.send_and_wait(process, fd, output, b"\r", INFO_TAB)
    _keyboard_harness.drain_until_quiet(process, fd, output)


def reopen_alpha_items(process, fd, output, balance: bytes) -> None:
    _keyboard_harness.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
    _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
    # Workspace withdrawal returns to the list but retains the chosen detail tab.
    _keyboard_harness.send_and_wait(process, fd, output, b"\r", balance)


def portrait_follows_the_terminal_height(binary: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        assert_portrait_beside_identity(output)
        # A short terminal keeps every row for facts.
        _keyboard_harness.resize_and_wait(process, fd, output, rows=20, columns=COLUMNS, needle=IDENTITY)
        _keyboard_harness.drain_until_quiet(process, fd, output)
        assert_facts_full_width(last_frame_rows(output), "on a short terminal")
        # And the portrait comes back when the rows do.
        _keyboard_harness.resize_and_wait(process, fd, output, rows=TALL_ROWS, columns=COLUMNS, needle=IDENTITY)
        _keyboard_harness.drain_until_quiet(process, fd, output)
        assert_portrait_beside_identity(output)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        binary,
        description="the keeper detail's portrait stands beside Identity and yields to a short terminal",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=COLUMNS,
    )


def no_portrait_under_no_color(binary: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        # A picture is the colour NO_COLOR opts out of.
        assert_facts_full_width(last_frame_rows(output), "under NO_COLOR")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        binary,
        description="the keeper detail draws no portrait under NO_COLOR",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=COLUMNS,
        extra_env={"NO_COLOR": "1"},
    )


def portrait_as_pixels(binary: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    reason = "fixture appraiser unavailable " + "long account headline " * 8
    revision = hashlib.sha256(("disabled\0" + reason).encode()).hexdigest()
    roster = fixtures["/api/v1/gate/keepers?detailed=true"][1]
    roster["candle"] = {"status": "disabled", "reason": reason}
    for keeper in roster["keepers"]:
        keeper["candle_account_revision"] = revision
    fixtures["/api/v1/keepers/alpha/items"] = (200, {
        "status": "disabled", "keeper": "alpha",
        "reason": reason, "account_revision": revision,
    })

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
        assert row_of(rows, b"Current Work") == identity + 4, \
            "the facts did not leave the picture its rows"
        # Item text that needs the full width must remove the actual Kitty
        # placement as well as its reserved columns. Mosaic-only proof cannot
        # detect a pixel overlay left above the text.
        start = len(output)
        _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: b"Candle disabled:" in b"\n".join(last_frame_rows(output).values()), timeout=10)
        _keyboard_harness.wait_for_output(process, fd, output, PORTRAIT_DELETE, start=start, timeout=3.0)
        _keyboard_harness.drain_until_quiet(process, fd, output)
        after = bytes(output[output.rfind(PORTRAIT_DELETE, start):])
        assert not any(kitty_fields(match[3]).get(b"i") == PORTRAIT_IMAGE_ID
                       for match in PLACEMENT.finditer(after)), \
            "long Item account headline retained a Kitty portrait over its text"
        assert row_of(last_frame_rows(output), b"glasses") > 0
        capture_item_screen(output, "kitty-account-full-width")
        start = len(output)
        _keyboard_harness.send_and_wait(process, fd, output, b"[", INFO_TAB)
        _keyboard_harness.drain_until_quiet(process, fd, output)
        assert any(kitty_fields(match[3]).get(b"i") == PORTRAIT_IMAGE_ID
                   for match in PLACEMENT.finditer(bytes(output[start:]))), \
            "Info did not restore its Kitty portrait after the full-width Item view"
        # Leaving the detail takes the picture down with it.
        start = len(output)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        _keyboard_harness.wait_for_output(process, fd, output, PORTRAIT_DELETE, start=start, timeout=3.0)
        _keyboard_harness.drain_until_quiet(process, fd, output)
        after = bytes(output[output.find(PORTRAIT_DELETE, start):])
        assert not any(
            kitty_fields(match[3]).get(b"i") == PORTRAIT_IMAGE_ID for match in PLACEMENT.finditer(after)
        ), "the portrait was placed again after the detail closed"
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        binary,
        description="the keeper detail places its portrait as real pixels on a Kitty terminal",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=COLUMNS,
        preload_input=KITTY_TERMINAL_REPLIES,
    )


def item_roster_fixtures():
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    roster = fixtures["/api/v1/gate/keepers?detailed=true"][1]
    roster.pop("candle", None)
    for row in roster["keepers"]:
        row.pop("candle_balance_milli", None)
        row.pop("candle_account_revision", None)
    return fixtures


def item_tab_previews_accessories(binary: str) -> None:
    fixtures = item_roster_fixtures()
    items = ItemWorkspaceFixture((
        200,
        {
            "status": "ready", "account_revision": "a" * 64, "keeper": "alpha", "balance_milli": "12500",
            "owned_items": ["glasses"],
            "catalog": [
                ({"id": item, "slot": slot, "price_status": "unpriced"}
                 if item == "dish_oak" else
                 {"id": item, "slot": slot, "price_status": "priced", "price_milli": "1000"})
                for item, slot in ITEM_CATALOG
            ],
        },
    ))
    fixtures["/api/v1/keepers/alpha/items"] = _keyboard_harness.PathHttpResponse(items.read)

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        _keyboard_harness.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
        _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        _keyboard_harness.wait_for_output(process, fd, output, b"Balance 12.500 Candle", start=0, timeout=3.0)
        _keyboard_harness.drain_until_quiet(process, fd, output)
        first = last_frame_rows(output)
        assert row_of(first, b"Items 1/18") > 0
        assert b"owned" in first[row_of(first, b"glasses")]
        assert portrait_rows(first), "the Item preview has no picture at 100x24"
        capture_item_screen(output, "owned-glasses")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Items 2/18")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        second = last_frame_rows(output)
        assert row_of(second, b"shades") > 0
        assert portrait_rows(second), "the selected accessory lost its picture"
        assert row_of(second, b"Selected: 1.000") > 0
        assert row_of(second, b"Preview changes this picture only") > 0
        capture_item_screen(output, "shades-preview")
        # Read the current completed viewport after each navigation or resize.
        _keyboard_harness.resize_and_wait(process, fd, output, rows=18, columns=COLUMNS,
                          needle=b"Items 2/18", controls=(_keyboard_harness.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[F", b"Items 18/18")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        assert row_of(last_frame_rows(output), b"> 18 base  dish_oak") > 0
        assert row_of(last_frame_rows(output), b"Selected: unpriced") > 0
        assert row_of(last_frame_rows(output), b"Preview changes this picture only") > 0
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[H", b"Items 1/18")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        assert row_of(last_frame_rows(output), b">  1 face  glasses") > 0
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[6~", b"Items ")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        paged = last_frame_rows(output)
        selected = [text for text in paged.values()
                    if re.search(rb">\s+\d+\s+(face|neck|head|hand|base)\s+", text)]
        assert len(selected) == 1, f"PageDown lost the selected item: {paged!r}"
        assert b">  1 face  glasses" not in selected[0], "PageDown did not move the item selection"
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[5~", b"Items 1/18")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        assert row_of(last_frame_rows(output), b">  1 face  glasses") > 0
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[F", b"Items 18/18")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=24, columns=50,
                          needle=b"Items 18/18", controls=(_keyboard_harness.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        narrow = last_frame_rows(output)
        assert row_of(narrow, b"> 18 base  dish_oak") > 0, "resize lost the last accessory name"
        assert row_of(narrow, b"Selected: unpriced") > 0, "narrow Items hid the authoritative price"
        assert row_of(narrow, b"Preview changes this picture only") > 0, "narrow Items hid the preview notice"
        assert not portrait_rows(narrow), "narrow Items pane retained a portrait beside clipped names"
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        binary,
        description="the Keeper Items tab browses accessories and previews them at 100x24",
        interact=interact,
        http_fixtures=fixtures, prepare_workspace=items.prepare,
        terminal_cols=COLUMNS,
    )


def item_account_failure_keeps_the_preview(binary: str) -> None:
    fixtures = item_roster_fixtures()
    ready = {"status": "ready", "account_revision": "a" * 64, "keeper": "alpha", "balance_milli": "12500",
             "owned_items": ["glasses"], "catalog": [
                 ({"id": item, "slot": slot, "price_status": "priced", "price_milli": "1000"}
                  if item == "glasses" else
                  {"id": item, "slot": slot, "price_status": "unpriced"})
                 for item, slot in ITEM_CATALOG]}
    response = [(200, ready)]
    items = ItemWorkspaceFixture(lambda: response[0])
    fixtures["/api/v1/keepers/alpha/items"] = _keyboard_harness.PathHttpResponse(items.read)

    def await_account(process, fd, output, needle):
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: needle in b"\n".join(last_frame_rows(output).values()), timeout=10.0), \
            f"Item account never drew {needle!r}: {last_frame_rows(output)!r}"

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        _keyboard_harness.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
        _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        await_account(process, fd, output, b"Balance 12.500 Candle")
        response[0] = (503, {"error": "ledger unreadable"})
        os.write(fd, b"r")
        await_account(process, fd, output, b"Account unavailable:")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        rows = last_frame_rows(output)
        assert row_of(rows, b"Items 1/18") > 0
        assert portrait_rows(rows), "an account read failure hid the separate portrait preview"
        assert not any(b"Balance 12.500" in text for text in rows.values()), \
            "the failed account read retained its previous balance"
        assert not any(b"1.000 owned" in text for text in rows.values()), \
            "the failed account read retained its previous price and ownership"
        capture_item_screen(output, "account-unavailable")
        response[0] = (200, dict(ready, balance_milli="13000"))
        os.write(fd, b"r")
        await_account(process, fd, output, b"Balance 13.000 Candle")
        assert not any(b"Account unavailable:" in text for text in last_frame_rows(output).values())
        capture_item_screen(output, "account-recovered")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        binary,
        description="an unreadable Item account stays visible without hiding the preview",
        interact=interact,
        http_fixtures=fixtures, prepare_workspace=items.prepare,
        terminal_cols=COLUMNS,
    )

def item_account_is_withdrawn_at_workspace_boundary(binary: str) -> None:
    fixtures = item_roster_fixtures()
    identity = {"base": None, "matched_reads": 0}
    held = threading.Event()
    release = threading.Event()
    served = threading.Event()
    held_at = [None]
    arm = [False]
    balance = ["12500"]
    ready = {"status": "ready", "account_revision": "a" * 64, "keeper": "alpha", "owned_items": [],
             "catalog": [{"id": item, "slot": slot, "price_status": "unpriced"}
                         for item, slot in ITEM_CATALOG]}

    def health():
        identity["matched_reads"] += 1
        base = identity["base"] or ""
        return 200, {"paths": {"effective_base_path": base,
                               "effective_masc_root": os.path.join(base, ".masc")}}

    def account():
        value = balance[0]
        if arm[0]:
            arm[0] = False
            held_at[0] = time.monotonic()
            held.set()
            if not release.wait(timeout=30):
                return 504, {"error": "held fixture read timeout"}
            def send_held_body():
                # The fixture server resumes this generator only after its
                # write and flush succeeded. A callable-return event alone
                # would fire before any HTTP body reached the socket.
                yield json.dumps(dict(ready, balance_milli=value)).encode()
                served.set()
            return _keyboard_harness.StreamingHttpResponse(send_held_body)
        return 200, dict(ready, balance_milli=value)

    fixtures["/health"] = health
    fixtures["/api/v1/keepers/alpha/items"] = account

    def await_frame(process, fd, output, predicate):
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: predicate(b"\n".join(last_frame_rows(output).values())), timeout=10), \
            f"workspace boundary did not settle: {last_frame_rows(output)!r}"

    def interact(process, fd, _slave, output, base):
        try:
            open_alpha_detail(process, fd, output)
            _keyboard_harness.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
            _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
            await_frame(process, fd, output, lambda frame: b"Balance 12.500 Candle" in frame)
            arm[0] = True
            os.write(fd, b"r")
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, held.is_set, timeout=10)
            identity["base"] = str(base) + "-other-workspace"
            await_frame(process, fd, output, lambda frame: "▸Items".encode() not in frame
                        and b"Balance 12.500 Candle" not in frame)
            previous_reads = identity["matched_reads"]
            identity["base"] = str(base)
            # Two serial full-refresh probes prove the first matching result
            # was admitted before its successor could start.
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: identity["matched_reads"] >= previous_reads + 2, timeout=10)
            balance[0] = "13000"
            _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", "▸Items".encode())
            await_frame(process, fd, output, lambda frame: b"Balance 13.000 Candle" in frame)
            # Masc_tui_http.default_timeout_sec is 10 seconds. Releasing
            # after that would test a timeout instead of a late successful read.
            assert held_at[0] is not None and time.monotonic() - held_at[0] < 10
            release.set()
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, served.is_set, timeout=3), \
                "held HTTP response was not written and flushed"
            assert time.monotonic() - held_at[0] < 10, "held read exceeded the TUI HTTP timeout"
            previous_reads = identity["matched_reads"]
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: identity["matched_reads"] >= previous_reads + 2, timeout=10)
            assert _keyboard_harness.drain_until_quiet(process, fd, output, quiet=0.05), "late response did not settle"
            frame = b"\n".join(last_frame_rows(output).values())
            assert b"Balance 13.000 Candle" in frame and b"Balance 12.500 Candle" not in frame
            capture_item_screen(output, "workspace-authority-return")
            os.write(fd, b"q")
        finally:
            release.set()

    _keyboard_harness.run_terminal_scenario(binary, description="Item detail tokens are withdrawn across a different workspace identity",
                            interact=interact, http_fixtures=fixtures, terminal_cols=COLUMNS,
                            prepare_workspace=lambda base: identity.update(base=str(base)),
                            refresh=0.2)


def item_account_follows_private_changes(binary: str) -> None:
    # Public discovery stays unchanged while the private account changes.
    fixtures = item_roster_fixtures()
    roster_path = "/api/v1/gate/keepers?detailed=true"
    roster = copy.deepcopy(fixtures[roster_path][1])
    roster_polls = []
    def read_roster():
        roster_polls.append(copy.deepcopy(roster))
        return 200, copy.deepcopy(roster)

    fixtures[roster_path] = read_roster
    account = {"status": "ready", "account_revision": "a" * 64, "keeper": "alpha", "balance_milli": "12500",
               "owned_items": [], "catalog": [
                   {"id": item, "slot": slot,
                    "price_status": "priced" if item == "glasses" else "unpriced",
                    **({"price_milli": "0"} if item == "glasses" else {})}
                   for item, slot in ITEM_CATALOG]}
    calls = []
    hold_next = [False]
    held, release = threading.Event(), threading.Event()

    def read_account():
        value = copy.deepcopy(account)
        calls.append(value)
        if hold_next[0]:
            hold_next[0] = False
            held.set()
            def chunks():
                if not release.wait(timeout=30):
                    raise AssertionError("private account fixture release missing")
                yield json.dumps(value).encode()
            return _keyboard_harness.StreamingHttpResponse(chunks)
        return 200, value

    items = ItemWorkspaceFixture(read_account)
    fixtures["/api/v1/keepers/alpha/items"] = _keyboard_harness.PathHttpResponse(items.read)

    def await_text(process, fd, output, needle):
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: needle in b"\n".join(last_frame_rows(output).values()), timeout=10.0), \
            f"automatic Item refresh never drew {needle!r}: {last_frame_rows(output)!r}"

    def publish_revision(value):
        account["account_revision"] = value * 64

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        _keyboard_harness.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
        _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        await_text(process, fd, output, b"Balance 12.500 Candle")
        account["owned_items"] = ["glasses"]
        publish_revision("b")
        # No key or tab transition: ordinary roster cadence must follow this.
        await_text(process, fd, output, b"0.000 owned")
        capture_item_screen(output, "automatic-free-purchase")
        account["catalog"][0]["price_milli"] = "1"
        publish_revision("c")
        await_text(process, fd, output, b"0.001 owned")
        capture_item_screen(output, "automatic-price-change")
        previous_calls = len(calls)
        previous_polls = len(roster_polls)
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: len(roster_polls) > previous_polls, timeout=10.0), \
            "ordinary roster cadence stopped after the price change"
        _keyboard_harness.drain_until_quiet(process, fd, output)
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: len(calls) > previous_calls, timeout=10.0), \
            "unchanged public roster stopped refreshing the private account"
        await_text(process, fd, output, b"0.001 owned")
        assert all(reading["balance_milli"] == "12500" for reading in calls)
        # A slow private response keeps its ticket across ordinary roster ticks.
        account["balance_milli"] = "13000"
        hold_next[0] = True
        try:
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, held.is_set, timeout=10.0)
            pending_calls = len(calls)
            pending_polls = len(roster_polls)
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: len(roster_polls) >= pending_polls + 2, timeout=10.0)
            assert len(calls) == pending_calls, "roster refresh superseded a pending private read"
            release.set()
            await_text(process, fd, output, b"Balance 13.000 Candle")
        finally:
            release.set()
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(binary,
        description="an open Item account follows private purchases and prices with unchanged public discovery",
        # The harness defaults to a 60-second cadence for keyboard tests;
        # this scenario specifically exercises the synthetic refresh cadence.
        interact=interact, http_fixtures=fixtures, prepare_workspace=items.prepare, terminal_cols=COLUMNS, refresh=0.2)


def item_account_follows_workspace_authority(binary: str) -> None:
    fixtures = item_roster_fixtures()
    ready = {"status": "ready", "account_revision": "a" * 64, "keeper": "alpha",
             "balance_milli": "12500", "owned_items": ["glasses"], "catalog": [
                 {"id": item, "slot": slot, "price_status": "priced", "price_milli": "1000"}
                 for item, slot in ITEM_CATALOG]}
    held = _keyboard_harness.GatedHttpResponse((200, dict(ready, balance_milli="90000")),
                              subsequent_response=(200, dict(ready, balance_milli="13000")),
                              hold_seconds=30.0)
    items = ItemWorkspaceFixture((200, ready))
    fixtures["/api/v1/keepers/alpha/items"] = _keyboard_harness.PathHttpResponse(items.read)
    phase = ["a"]
    workspace = [None]
    health_reads: list[str] = []

    def health():
        current = phase[0]
        health_reads.append(current)
        if current == "unread":
            return 503, {"error": "fixture identity unavailable"}
        assert workspace[0] is not None
        base = workspace[0] if current == "a" else str(Path(workspace[0], "other-workspace"))
        return _keyboard_harness.RawHttpResponse(200, json.dumps({"paths": {
            "effective_base_path": base, "effective_masc_root": str(Path(base, ".masc")),
        }}).encode(), content_type="application/json")

    fixtures["/health"] = health

    def prepare(base):
        items.prepare(base)
        workspace[0] = items.base_path

    def await_frame(process, fd, output, needle):
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: needle in b"\n".join(last_frame_rows(output).values()), timeout=10.0), \
            f"Item authority never drew {needle!r}: {last_frame_rows(output)!r}"

    def interact(process, fd, _slave, output, _base):
        try:
            open_alpha_detail(process, fd, output)
            _keyboard_harness.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
            _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
            await_frame(process, fd, output, b"Balance 12.500 Candle")
            items.response = held
            os.write(fd, b"r")
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, held.requested.is_set, timeout=10.0)
            await_frame(process, fd, output, "Loading Item account…".encode())
            assert not any(b"12.500" in row or b"1.000 owned" in row
                           for row in last_frame_rows(output).values()), "a pending reread retained its account"
            items.served_base_path = str(Path(items.base_path, "other-workspace"))
            phase[0] = "b"
            await_frame(process, fd, output, b"[workspace mismatch]")
            assert not any(b"Balance " in row or b"1.000 owned" in row
                           for row in last_frame_rows(output).values())
            items.served_base_path = items.base_path
            reads = len(health_reads)
            phase[0] = "a"
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: len(health_reads) >= reads + 2, timeout=10.0)
            reopen_alpha_items(process, fd, output, b"Balance 13.000 Candle")
            start = len(output)
            held.release.set()
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, held.completed.is_set, timeout=10.0)
            _keyboard_harness.drain_until_quiet(process, fd, output)
            assert b"Balance 90.000" not in output[start:], \
                "late first-A account became current after A/B/A"
            # Successful roster observations refresh the private account even
            # when the canonical workspace and public discovery are unchanged.
            calls_before_refresh = held.calls
            reads = len(health_reads)
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: len(health_reads) >= reads + 2, timeout=10.0)
            _keyboard_harness.drain_until_quiet(process, fd, output)
            assert any(b"Balance 13.000" in row for row in last_frame_rows(output).values())
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: held.calls > calls_before_refresh, timeout=10.0)
            phase[0] = "unread"
            await_frame(process, fd, output, b"MASC Keepers")
            assert not any(b"Balance 13.000" in row or b"1.000 owned" in row
                           for row in last_frame_rows(output).values()), "unread health retained account authority"
            calls_after_withdrawal = held.calls
            unread_probes = len(health_reads)
            os.write(fd, b"r")
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: len(health_reads) >= unread_probes + 2, timeout=10.0)
            _keyboard_harness.drain_until_quiet(process, fd, output)
            assert held.calls == calls_after_withdrawal, "unconfirmed workspace launched an Item request"
            reads = len(health_reads)
            phase[0] = "a"
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: len(health_reads) >= reads + 2, timeout=10.0)
            reopen_alpha_items(process, fd, output, b"Balance 13.000 Candle")
            capture_item_screen(output, "workspace-authority-recovered")
            os.write(fd, b"q")
        finally:
            held.release.set()

    _keyboard_harness.run_terminal_scenario(
        binary,
        description="Item accounts withdraw on workspace transition and refuse late A after A/B/A",
        interact=interact, prepare_workspace=prepare, http_fixtures=fixtures,
        refresh=0.1, terminal_cols=COLUMNS,
    )


def item_account_refuses_an_unobserved_server_workspace(binary: str) -> None:
    fixtures = item_roster_fixtures()
    ready = {"status": "ready", "account_revision": "a" * 64, "keeper": "alpha",
             "balance_milli": "12500", "owned_items": [], "catalog": [
                 {"id": item, "slot": slot, "price_status": "unpriced"}
                 for item, slot in ITEM_CATALOG]}
    items = ItemWorkspaceFixture((200, ready))
    refused = _keyboard_harness.GatedHttpResponse((409, {"error": "Server workspace changed"}), hold_seconds=30.0)

    def read(path):
        result = items.read(path)
        if result[0] == 409:
            refused.response = result
            return refused()
        return result

    fixtures["/api/v1/keepers/alpha/items"] = _keyboard_harness.PathHttpResponse(read)

    def await_frame(process, fd, output, needle):
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: needle in b"\n".join(last_frame_rows(output).values()), timeout=10.0), \
            f"Bound Item response never drew {needle!r}: {last_frame_rows(output)!r}"

    def interact(process, fd, _slave, output, _base):
        try:
            open_alpha_detail(process, fd, output)
            _keyboard_harness.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
            _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
            await_frame(process, fd, output, b"Balance 12.500 Candle")
            # Health continues naming A. Only the Item serving workspace is
            # temporarily B, with the same Keeper and a valid account body.
            items.served_base_path = str(Path(items.base_path, "blind-server-b"))
            items.response = (200, dict(ready, balance_milli="90000"))
            os.write(fd, b"r")
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, refused.requested.is_set, timeout=10.0)
            assert items.requests[-1] == {"expected": items.base_path,
                                          "served": items.served_base_path, "matched": False}
            # A returns before its pending refusal is delivered; no health B
            # observation or changed Keeper name can provide a second fence.
            items.served_base_path = items.base_path
            refused.release.set()
            await_frame(process, fd, output, b"Account unavailable:")
            _keyboard_harness.drain_until_quiet(process, fd, output)
            assert not any(b"Balance 90.000" in row or b"Balance 12.500" in row
                           for row in last_frame_rows(output).values()), "blind B or cached A account was published"
            assert len(items.requests) == 2, "workspace conflict silently retried the Item read"
            items.response = (200, dict(ready, balance_milli="13000"))
            os.write(fd, b"r")
            await_frame(process, fd, output, b"Balance 13.000 Candle")
            assert items.requests[-1]["matched"] is True
            capture_item_screen(output, "blind-workspace-refusal-recovered")
            os.write(fd, b"q")
        finally:
            refused.release.set()

    _keyboard_harness.run_terminal_scenario(
        binary,
        description="bound Item requests refuse blind same-peer workspace B while health remains A",
        interact=interact, prepare_workspace=items.prepare, http_fixtures=fixtures,
        terminal_cols=COLUMNS,
    )


def item_account_refreshes_without_public_currency(binary: str) -> None:
    fixtures = item_roster_fixtures()
    roster = fixtures["/api/v1/gate/keepers?detailed=true"][1]
    fixtures["/api/v1/gate/keepers?detailed=true"] = lambda: (200, roster)
    ready = {"status": "ready", "account_revision": "a" * 64, "keeper": "alpha",
             "balance_milli": "12500", "owned_items": ["glasses"], "catalog": [
                 {"id": item, "slot": slot, "price_status": "unpriced"}
                 for item, slot in ITEM_CATALOG]}
    items = ItemWorkspaceFixture((200, ready))
    fixtures["/api/v1/keepers/alpha/items"] = _keyboard_harness.PathHttpResponse(items.read)

    def await_frame(process, fd, output, needle):
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: needle in b"\n".join(last_frame_rows(output).values()), timeout=10.0), last_frame_rows(output)

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        _keyboard_harness.resize_and_wait(process, fd, output, rows=40, columns=200, needle=INFO_TAB)
        _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        await_frame(process, fd, output, b"Balance 12.500 Candle")
        # The public roster has no private account fields. The next accepted
        # roster refresh wakes the selected authenticated account reader.
        items.response = 200, dict(ready, account_revision="b" * 64, balance_milli="13000")
        await_frame(process, fd, output, b"Balance 13.000 Candle")
        assert "candle" not in roster
        assert all("candle_account_revision" not in row for row in roster["keepers"])
        # Passive decay keeps the revision stable but refreshes the balance.
        items.response = 200, dict(ready, account_revision="b" * 64, balance_milli="12000")
        await_frame(process, fd, output, b"Balance 12.000 Candle")
        assert not any(b"Balance 13.000" in line for line in last_frame_rows(output).values())
        items.response = 200, {"status": "off", "keeper": "alpha", "account_revision": None}
        await_frame(process, fd, output, b"Candle off")
        assert not any(b"Balance 12.000" in line for line in last_frame_rows(output).values())
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(binary,
        description="Item account refreshes from its authenticated response while public roster omits currency",
        interact=interact, prepare_workspace=items.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=200)


def item_account_withdraws_unread_authority(binary: str, boundary="identity") -> None:
    fixtures = item_roster_fixtures()
    identity = {"base": "", "unread": False, "probes": 0}
    held, release, served = threading.Event(), threading.Event(), threading.Event()
    arm = [False]
    balance = ["12500"]
    account = {"account_revision": "a" * 64, "status": "ready", "keeper": "alpha", "owned_items": [],
               "catalog": [{"id": item, "slot": slot, "price_status": "unpriced"}
                           for item, slot in ITEM_CATALOG]}

    def health():
        identity["probes"] += 1
        unavailable = identity["unread"] and boundary == "identity"
        value = ({"error": "identity unread"} if unavailable else
                 {"paths": {"effective_base_path": identity["base"],
                            "effective_masc_root": os.path.join(identity["base"], ".masc")},
                  "state_ready": True})
        return _keyboard_harness.RawHttpResponse(503 if unavailable else 200,
                                 json.dumps(value).encode(), content_type="application/json")

    def items():
        value = dict(account, balance_milli=balance[0])
        if not arm[0]:
            return 200, value
        arm[0] = False
        held.set()
        if not release.wait(timeout=30):
            return 504, {"error": "fixture release missing"}
        def chunks():
            yield json.dumps(value).encode()
            served.set()
        return _keyboard_harness.StreamingHttpResponse(chunks)

    public_response = fixtures["/api/v1/gate/keepers?detailed=true"]
    assert isinstance(public_response, tuple)
    public_roster = public_response[1]
    def roster():
        if identity["unread"] and boundary == "roster":
            return _keyboard_harness.RawHttpResponse(503, b'{"error":"roster unread"}', content_type="application/json")
        return 200, public_roster
    fixtures["/health"] = health
    fixtures["/api/v1/gate/keepers?detailed=true"] = roster
    fixtures["/api/v1/keepers/alpha/items"] = items

    def frame(process, fd, output, predicate):
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: predicate(b"\n".join(last_frame_rows(output).values())), timeout=10)

    def recover(process, fd, output):
        probes = identity["probes"]
        identity["unread"] = False
        # A subsequent serial full-refresh probe starts after the previous
        # identity answer has been applied. This is a fixture barrier, not age.
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: identity["probes"] >= probes + 2, timeout=10)

    def interact(process, fd, _slave, output, _base):
        try:
            open_alpha_detail(process, fd, output)
            _keyboard_harness.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
            _keyboard_harness.send_and_wait(process, fd, output, b"]", b"Balance 12.500 Candle")
            identity["unread"] = True
            if boundary == "identity":
                frame(process, fd, output, lambda text:
                      b"MASC Keepers" in text and b"Balance 12.500 Candle" not in text)
            else:
                frame(process, fd, output, lambda text: b"Account unavailable:" in text)
            balance[0] = "13000"
            recover(process, fd, output)
            if boundary == "identity":
                reopen_alpha_items(process, fd, output, b"Balance 13.000 Candle")
            else:
                frame(process, fd, output, lambda text: b"Balance 13.000 Candle" in text)
            arm[0] = True
            os.write(fd, b"r")
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, held.is_set, timeout=3)
            identity["unread"] = True
            if boundary == "identity":
                frame(process, fd, output, lambda text: b"MASC Keepers" in text and b"Balance " not in text)
            else:
                frame(process, fd, output, lambda text: b"Account unavailable:" in text)
            # Keep authority unread until the late response has settled.
            # Roster failure leaves health ready and must revoke the detail ticket.
            start = len(output)
            release.set()
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, served.is_set, timeout=3)
            probes = identity["probes"]
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: identity["probes"] >= probes + 2, timeout=10)
            assert _keyboard_harness.drain_until_quiet(process, fd, output), "late response did not settle"
            text = b"\n".join(last_frame_rows(output).values())
            if boundary == "identity":
                assert b"MASC Keepers" in text
            else:
                assert b"Account unavailable:" in text
            assert b"Balance 13.000 Candle" not in text
            assert b"Balance 13.000 Candle" not in output[start:]
            balance[0] = "14000"
            recover(process, fd, output)
            if boundary == "identity":
                reopen_alpha_items(process, fd, output, b"Balance 14.000 Candle")
            else:
                frame(process, fd, output, lambda text: b"Balance 14.000 Candle" in text)
            os.write(fd, b"q")
        finally:
            release.set()

    _keyboard_harness.run_terminal_scenario(binary, description=f"Item balances and pending reads lose unread {boundary} authority",
                            interact=interact, http_fixtures=fixtures, terminal_cols=COLUMNS,
                            prepare_workspace=lambda base: identity.update(base=str(Path(base).resolve())),
                            refresh=0.2)


def instructions_read_recovers_workspace_authority(binary: str, *, sandbox_logs: bool = False, leave: bool = False, fallback_exit: bool = False) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    identity = {"base": "", "unread": False, "probes": 0}
    held, release, served = threading.Event(), threading.Event(), threading.Event()
    reads = []
    old = b"instructions-obsolete-runtime"
    current = b"instructions-current-runtime"

    def health():
        identity["probes"] += 1
        value = ({"error": "identity unread"} if identity["unread"] else
                 {"paths": {"effective_base_path": identity["base"],
                            "effective_masc_root": os.path.join(identity["base"], ".masc")},
                  "state_ready": True})
        return _keyboard_harness.RawHttpResponse(503 if identity["unread"] else 200,
                                 json.dumps(value).encode(), content_type="application/json")

    def config():
        reads.append(True)
        marker = old if len(reads) == 1 else current
        # The actual config-view projection reads this nested runtime field.
        value = ({"state": "no_local_stream", "backend": None, "instances": [],
                  "tail": 200, "reason": marker.decode()} if sandbox_logs else
                 {"name": "alpha", "execution": {"selected_runtime_id": marker.decode()},
                  "prompt": {"instructions": "Synthetic Instructions recovery fixture"}})
        if len(reads) != 1:
            return 200, value
        held.set()
        assert release.wait(timeout=30), "held Instructions response was not released"
        def chunks():
            yield json.dumps(value).encode()
            served.set()
        return _keyboard_harness.StreamingHttpResponse(chunks)

    fixtures["/health"] = health
    fixtures[("/api/v1/gate/keeper-sandbox-logs" if sandbox_logs else
              "/api/v1/keepers/alpha/config")] = config

    def wait_refreshes(process, fd, output):
        before = identity["probes"]
        # Full refreshes are serial: the following probe starts after applying
        # the preceding identity response, so this crosses the state boundary.
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: identity["probes"] >= before + 2, timeout=10)

    def frame(output):
        return b"\n".join(last_frame_rows(output).values())

    def interact(process, fd, _slave, output, _base):
        try:
            open_alpha_detail(process, fd, output)
            _keyboard_harness.resize_and_wait(process, fd, output, rows=45, columns=COLUMNS, needle=INFO_TAB)
            # Enter Instructions, or Sandbox plus its separate initial log
            # read. Endpoint arrival confirms the request actually started.
            os.write(fd, b"]]o" if sandbox_logs else b"]]]")
            assert _keyboard_harness.wait_for_fixture_event(process, fd, output, held, timeout=3)
            identity["unread"] = True
            wait_refreshes(process, fd, output)
            # Health requests can overlap; wait until the TUI applies revocation.
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: b"No keeper selected" in frame(output), timeout=10), \
                "unread authority was not applied"
            # A manual read during revocation must not create a new token
            # that would admit an answering but unverified endpoint.
            os.write(fd, b"o" if sandbox_logs else b"r")
            wait_refreshes(process, fd, output)
            assert reads == [True], "unread authority restarted the held detail read"
            assert old not in frame(output)
            if leave or fallback_exit:
                if fallback_exit:
                    # Failed roster recovery retains suspended detail focus.
                    # Leave that detail before leaving the Keeper list.
                    metadata = Path(_base) / ".masc" / "keepers" / "alpha.json"
                    original_metadata = metadata.read_bytes()
                    metadata.write_text("{invalid fixture metadata")
                    try:
                        identity["unread"] = False
                        wait_refreshes(process, fd, output)
                        report = f"[masc-tui] decode failed for {metadata}:"
                        assert _keyboard_harness.wait_for_fixture_state(
                            process, fd, output,
                            lambda: report in _keyboard_startup.exit_reason_log(_base),
                            timeout=10,
                        ), "failed roster decode was not observed"
                        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                            lambda: b"No keeper selected" in frame(output), timeout=10)
                        assert reads == [True], "failed roster resumed detail"
                        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
                        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
                    finally:
                        metadata.write_bytes(original_metadata)
                else:
                    _keyboard_harness.palette_go(process, fd, output, b"go Dashboard", b"MASC Dashboard")
                    identity["unread"] = False
                wait_refreshes(process, fd, output)
                release.set()
                wait_refreshes(process, fd, output)
                _keyboard_harness.drain_until_quiet(process, fd, output)
                assert b"MASC Dashboard" in frame(output), "recovery stole navigation"
                assert reads == [True], "left detail restarted its suspended read"
                assert old not in frame(output) and current not in frame(output)
                os.write(fd, b"q")
                return
            identity["unread"] = False
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: current in frame(output), timeout=10), "Instructions did not recover automatically"
            assert len(reads) == 2, "authority recovery duplicated its detail read"
            start = len(output)
            release.set()
            assert _keyboard_harness.wait_for_fixture_event(process, fd, output, served, timeout=3)
            wait_refreshes(process, fd, output)
            assert _keyboard_harness.drain_until_quiet(process, fd, output), "late Instructions response did not settle"
            assert current in frame(output) and old not in frame(output)
            assert old not in output[start:], "obsolete Instructions callback replaced the recovery"
            assert len(reads) == 2, "ordinary full/scoped refresh relaunched the settled detail"
            capture_item_screen(output, "sandbox-log-authority-recovery" if sandbox_logs else "instructions-authority-recovery")
            os.write(fd, b"q")
        finally:
            release.set()

    _keyboard_harness.run_terminal_scenario(binary,
        description=("Esc from recovery fallback list retires suspended focus" if fallback_exit else
                     "Leaving revoked Instructions retires suspended focus" if leave else
                     "Held Sandbox logs are revoked and resumed on authority recovery" if sandbox_logs else
                     "Held Instructions reads are revoked and the visible pane resumes on same-workspace recovery"),
        interact=interact, http_fixtures=fixtures, terminal_cols=COLUMNS,
        prepare_workspace=lambda base: identity.update(base=str(Path(base).resolve())), refresh=0.2)


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    artifact_root = os.environ.get("RUNNER_TEMP")
    if artifact_root is not None:
        captures = Path(artifact_root) / "keeper-items-tui"
        captures.mkdir(parents=True, exist_ok=True)
        (captures / "manifest.json").write_text(json.dumps({
            "scope": "synthetic Item account, Instructions and Sandbox log authority-recovery HTTP responses through the real TUI in a PTY",
            "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            "source_sha": os.environ.get("GITHUB_SHA"),
            "columns": COLUMNS, "item_rows": SHORT_ROWS,
        }, indent=2) + "\n")
    portrait_follows_the_terminal_height(binary)
    no_portrait_under_no_color(binary)
    portrait_as_pixels(binary)
    item_account_refreshes_without_public_currency(binary)
    item_tab_previews_accessories(binary)
    item_account_failure_keeps_the_preview(binary)
    item_account_follows_private_changes(binary)
    item_account_follows_workspace_authority(binary)
    item_account_refuses_an_unobserved_server_workspace(binary)
    item_account_withdraws_unread_authority(binary)
    item_account_withdraws_unread_authority(binary, boundary="roster")
    item_account_is_withdrawn_at_workspace_boundary(binary)
    instructions_read_recovers_workspace_authority(binary)
    instructions_read_recovers_workspace_authority(binary, sandbox_logs=True)
    instructions_read_recovers_workspace_authority(binary, leave=True)
    instructions_read_recovers_workspace_authority(binary, fallback_exit=True)
    print("tui keeper portrait: PASS (16 scenarios)")
