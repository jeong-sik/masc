"""A Keeper's own portrait at the head of its detail, drawn by the real TUI in
a pseudo-terminal: a half-block mosaic beside the Identity facts, gone from a
terminal too short to spare its rows and back when the terminal grows, not
drawn at all under NO_COLOR, and real pixels over the band's rows where the
terminal answers the Kitty graphics query."""
from __future__ import annotations

import os
import hashlib
import json
import copy
import threading
import re
import sys
from pathlib import Path

import test_tui_keyboard_input as h

# scripts/ci/run-edited-tests.sh runs this suite when a pull request changes a
# path named here.
SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_keeper_items.ml",
    "bin/masc_tui_types.ml",
    "lib/tui_decode.ml",
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


ITEM_CATALOG = [
    ("glasses", "face"), ("shades", "face"), ("eye_patch", "face"),
    ("plaster", "face"), ("freckles", "face"), ("beard", "face"),
    ("scarf", "neck"), ("bow_tie", "neck"), ("medal", "neck"),
    ("bow", "head"), ("crown", "head"), ("beanie", "head"),
    ("book", "hand"), ("mug", "hand"), ("quill", "hand"),
    ("dish_gilt", "base"), ("dish_silver", "base"), ("dish_oak", "base"),
]


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



def item_tab_previews_accessories(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/items"] = (
        200,
        {
            "status": "ready", "keeper": "alpha", "balance_milli": "12500",
            "owned_items": ["glasses"],
            "catalog": [
                ({"id": item, "slot": slot, "price_status": "unpriced"}
                 if item == "dish_oak" else
                 {"id": item, "slot": slot, "price_status": "priced", "price_milli": "1000"})
                for item, slot in ITEM_CATALOG
            ],
        },
    )

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
        h.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        h.wait_for_output(process, fd, output, b"Balance 12.500 Candle", start=0, timeout=3.0)
        h.drain_until_quiet(process, fd, output)
        first = last_frame_rows(output)
        assert row_of(first, b"Items 1/18") > 0
        assert b"owned" in first[row_of(first, b"glasses")]
        assert portrait_rows(first), "the Item preview has no picture at 100x24"
        capture_item_screen(output, "owned-glasses")
        h.send_and_wait(process, fd, output, b"j", b"Items 2/18")
        h.drain_until_quiet(process, fd, output)
        second = last_frame_rows(output)
        assert row_of(second, b"shades") > 0
        assert portrait_rows(second), "the selected accessory lost its picture"
        assert row_of(second, b"Preview changes this picture only") > 0
        capture_item_screen(output, "shades-preview")
        # Read the current completed viewport after each navigation or resize.
        h.resize_and_wait(process, fd, output, rows=18, columns=COLUMNS,
                          needle=b"Items 2/18", controls=(h.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        h.send_and_wait(process, fd, output, b"\x1b[F", b"Items 18/18")
        h.drain_until_quiet(process, fd, output)
        assert row_of(last_frame_rows(output), b"> 18 base  dish_oak") > 0
        assert row_of(last_frame_rows(output), b"Selected: unpriced") > 0
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Items 1/18")
        h.drain_until_quiet(process, fd, output)
        assert row_of(last_frame_rows(output), b">  1 face  glasses") > 0
        h.send_and_wait(process, fd, output, b"\x1b[6~", b"Items ")
        h.drain_until_quiet(process, fd, output)
        paged = last_frame_rows(output)
        selected = [text for text in paged.values()
                    if re.search(rb">\s+\d+\s+(face|neck|head|hand|base)\s+", text)]
        assert len(selected) == 1, f"PageDown lost the selected item: {paged!r}"
        assert b">  1 face  glasses" not in selected[0], "PageDown did not move the item selection"
        h.send_and_wait(process, fd, output, b"\x1b[5~", b"Items 1/18")
        h.drain_until_quiet(process, fd, output)
        assert row_of(last_frame_rows(output), b">  1 face  glasses") > 0
        h.send_and_wait(process, fd, output, b"\x1b[F", b"Items 18/18")
        h.resize_and_wait(process, fd, output, rows=24, columns=50,
                          needle=b"Items 18/18", controls=(h.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        narrow = last_frame_rows(output)
        assert row_of(narrow, b"> 18 base  dish_oak") > 0, "resize lost the last accessory name"
        assert row_of(narrow, b"Selected: unpriced") > 0, "narrow Items hid the authoritative price"
        assert not portrait_rows(narrow), "narrow Items pane retained a portrait beside clipped names"
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="the Keeper Items tab browses accessories and previews them at 100x24",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=COLUMNS,
    )


def item_account_failure_keeps_the_preview(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    ready = {"status": "ready", "keeper": "alpha", "balance_milli": "12500",
             "owned_items": [], "catalog": [
                 {"id": item, "slot": slot, "price_status": "unpriced"}
                 for item, slot in ITEM_CATALOG]}
    response = [(200, ready)]
    fixtures["/api/v1/keepers/alpha/items"] = lambda: response[0]

    def await_account(process, fd, output, needle):
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: needle in b"\n".join(last_frame_rows(output).values()), timeout=10.0), \
            f"Item account never drew {needle!r}: {last_frame_rows(output)!r}"

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
        h.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        await_account(process, fd, output, b"Balance 12.500 Candle")
        response[0] = (503, {"error": "ledger unreadable"})
        os.write(fd, b"r")
        await_account(process, fd, output, b"Account unavailable:")
        h.drain_until_quiet(process, fd, output)
        rows = last_frame_rows(output)
        assert row_of(rows, b"Items 1/18") > 0
        assert portrait_rows(rows), "an account read failure hid the separate portrait preview"
        assert not any(b"Balance 12.500" in text for text in rows.values()), \
            "the failed account read retained its previous balance"
        capture_item_screen(output, "account-unavailable")
        response[0] = (200, dict(ready, balance_milli="13000"))
        os.write(fd, b"r")
        await_account(process, fd, output, b"Balance 13.000 Candle")
        assert not any(b"Account unavailable:" in text for text in last_frame_rows(output).values())
        capture_item_screen(output, "account-recovered")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="an unreadable Item account stays visible without hiding the preview",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=COLUMNS,
    )

def item_account_follows_roster_revision(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    roster_path = "/api/v1/gate/keepers?detailed=true"
    roster = copy.deepcopy(fixtures[roster_path][1])
    roster_polls = []
    roster["candle"] = {"status": "ready", "issued_milli": "12500",
                        "burned_milli": "0", "circulating_milli": "12500"}
    for row in roster["keepers"]:
        row["candle_balance_milli"] = "12500" if row["name"] == "alpha" else "0"
        row["candle_account_revision"] = "a" * 64
    def read_roster():
        roster_polls.append(copy.deepcopy(roster))
        return 200, copy.deepcopy(roster)

    fixtures[roster_path] = read_roster
    account = {"status": "ready", "keeper": "alpha", "balance_milli": "12500",
               "owned_items": [], "catalog": [
                   {"id": item, "slot": slot,
                    "price_status": "priced" if item == "glasses" else "unpriced",
                    **({"price_milli": "0"} if item == "glasses" else {})}
                   for item, slot in ITEM_CATALOG]}
    calls = []

    def read_account():
        calls.append(copy.deepcopy(account))
        return 200, copy.deepcopy(account)

    fixtures["/api/v1/keepers/alpha/items"] = read_account

    def await_text(process, fd, output, needle):
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: needle in b"\n".join(last_frame_rows(output).values()), timeout=10.0), \
            f"automatic Item refresh never drew {needle!r}: {last_frame_rows(output)!r}"

    def publish_revision(value):
        for row in roster["keepers"]:
            if row["name"] == "alpha":
                row["candle_account_revision"] = value * 64

    def interact(process, fd, _slave, output, _base):
        open_alpha_detail(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
        h.send_and_wait(process, fd, output, b"]", "▸Items".encode())
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
        previous_polls = len(roster_polls)
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: len(roster_polls) > previous_polls, timeout=10.0), \
            "ordinary roster cadence stopped after the price change"
        h.drain_until_quiet(process, fd, output)
        assert len(calls) == 3, f"unchanged roster revisions reread the account: {len(calls)}"
        assert all(reading["balance_milli"] == "12500" for reading in calls)
        os.write(fd, b"q")

    h.run_terminal_scenario(binary,
        description="an open Item account follows free purchase and price-only roster revisions",
        # The harness defaults to a 60-second cadence for keyboard tests;
        # this scenario specifically exercises the public refresh cadence.
        interact=interact, http_fixtures=fixtures, terminal_cols=COLUMNS, refresh=0.2)


def item_account_withdraws_unread_authority(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    identity = {"base": "", "unread": False, "probes": 0}
    held, release, served = threading.Event(), threading.Event(), threading.Event()
    arm = [False]
    balance = ["12500"]
    account = {"status": "ready", "keeper": "alpha", "owned_items": [],
               "catalog": [{"id": item, "slot": slot, "price_status": "unpriced"}
                           for item, slot in ITEM_CATALOG]}

    def health():
        identity["probes"] += 1
        value = ({"error": "identity unread"} if identity["unread"] else
                 {"paths": {"effective_base_path": identity["base"],
                            "effective_masc_root": os.path.join(identity["base"], ".masc")},
                  "state_ready": True})
        return h.RawHttpResponse(503 if identity["unread"] else 200,
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
        return h.StreamingHttpResponse(chunks)

    fixtures["/health"] = health
    fixtures["/api/v1/keepers/alpha/items"] = items

    def frame(process, fd, output, predicate):
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: predicate(b"\n".join(last_frame_rows(output).values())), timeout=10)

    def recover(process, fd, output):
        probes = identity["probes"]
        identity["unread"] = False
        # A subsequent serial full-refresh probe starts after the previous
        # identity answer has been applied. This is a fixture barrier, not age.
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: identity["probes"] >= probes + 2, timeout=10)

    def interact(process, fd, _slave, output, _base):
        try:
            open_alpha_detail(process, fd, output)
            h.resize_and_wait(process, fd, output, rows=SHORT_ROWS, columns=COLUMNS, needle=INFO_TAB)
            h.send_and_wait(process, fd, output, b"]", b"Balance 12.500 Candle")
            identity["unread"] = True
            frame(process, fd, output, lambda text:
                  b"Account unavailable:" in text and b"Balance 12.500 Candle" not in text)
            recover(process, fd, output)
            balance[0] = "13000"
            h.send_and_wait(process, fd, output, b"r", b"Balance 13.000 Candle")
            arm[0] = True
            os.write(fd, b"r")
            assert h.wait_for_fixture_state(process, fd, output, held.is_set, timeout=3)
            identity["unread"] = True
            frame(process, fd, output, lambda text: b"Account unavailable:" in text)
            balance[0] = "14000"
            recover(process, fd, output)
            # Revision-aware Items automatically resumes the account read on
            # ordinary roster cadence after authority recovers. Observe the
            # successor before releasing the older held response; neither the
            # retained screen nor a later frame may return to that old wallet.
            frame(process, fd, output, lambda text: b"Balance 14.000 Candle" in text)
            start = len(output)
            release.set()
            assert h.wait_for_fixture_state(process, fd, output, served.is_set, timeout=3)
            probes = identity["probes"]
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: identity["probes"] >= probes + 2, timeout=10)
            assert h.drain_until_quiet(process, fd, output), "late response did not settle"
            text = b"\n".join(last_frame_rows(output).values())
            assert b"Balance 14.000 Candle" in text
            assert b"Account unavailable:" not in text
            assert b"Balance 13.000 Candle" not in text
            assert b"Balance 13.000 Candle" not in output[start:]
            balance[0] = "15000"
            h.send_and_wait(process, fd, output, b"r", b"Balance 15.000 Candle")
            os.write(fd, b"q")
        finally:
            release.set()

    h.run_terminal_scenario(binary, description="Item balances and pending reads lose unread workspace authority",
                            interact=interact, http_fixtures=fixtures, terminal_cols=COLUMNS,
                            prepare_workspace=lambda base: identity.update(base=str(Path(base).resolve())),
                            refresh=0.2)


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    artifact_root = os.environ.get("RUNNER_TEMP")
    if artifact_root is not None:
        captures = Path(artifact_root) / "keeper-items-tui"
        captures.mkdir(parents=True, exist_ok=True)
        (captures / "manifest.json").write_text(json.dumps({
            "scope": "synthetic Item account HTTP responses through the real TUI in a PTY",
            "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            "source_sha": os.environ.get("GITHUB_SHA"),
            "columns": COLUMNS, "item_rows": SHORT_ROWS,
        }, indent=2) + "\n")
    portrait_follows_the_terminal_height(binary)
    no_portrait_under_no_color(binary)
    portrait_as_pixels(binary)
    item_tab_previews_accessories(binary)
    item_account_failure_keeps_the_preview(binary)
    item_account_follows_roster_revision(binary)
    item_account_withdraws_unread_authority(binary)
    print("tui keeper portrait: PASS (7 scenarios)")
