"""Keeper Items tab marks equipped and owned items with exclusive words.

Scenario: alpha owns glasses (worn on face) and shades (unworn). The
glasses row must read "equipped" without "owned"; the shades row must
read "owned" without "equipped". Equipped implies owned, so a worn row
that also says "owned" is the regression this pins.
"""
import copy
import os
import sys

import tui_keyboard_harness as h


CURRENT = b"\xe2\x96\xb8"

CATALOG = [
    ("glasses", "face"), ("shades", "face"), ("eye_patch", "face"),
    ("plaster", "face"), ("freckles", "face"), ("beard", "face"),
    ("scarf", "neck"), ("bow_tie", "neck"), ("medal", "neck"),
    ("bow", "head"), ("crown", "head"), ("beanie", "head"),
    ("book", "hand"), ("mug", "hand"), ("quill", "hand"),
    ("dish_gilt", "base"), ("dish_silver", "base"), ("dish_oak", "base"),
]

REVISION = "ab" * 32


def account_fixture() -> tuple[int, dict]:
    return (
        200,
        {
            "status": "ready",
            "keeper": "alpha",
            "balance_milli": "1500",
            "owned_items": ["glasses", "shades"],
            "catalog": [
                {"id": item_id, "slot": slot, "price_status": "priced",
                 "price_milli": "200"}
                for item_id, slot in CATALOG
            ],
            "account_revision": REVISION,
        },
    )


def run(executable: str, no_color: bool = False) -> None:
    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", CURRENT + b"Info")
        h.send_and_wait(process, master_fd, output, b"]", CURRENT + b"Items")
        # The account fetch is async; wait for its data, not the tab chrome.
        h.wait_for_output(
            process, master_fd, output, b"Balance 1.500 Candle",
            start=0, timeout=10.0)
        h.drain_until_quiet(process, master_fd, output)

        def screen():
            return h.screen_rows(
                bytes(output[: output.rfind(h.FRAME_END) + len(h.FRAME_END)]))

        def screen_styled():
            return h.screen_rows(
                bytes(output[: output.rfind(h.FRAME_END) + len(h.FRAME_END)]),
                preserve_styles=True)

        def screen_text(rows) -> bytes:
            return b"\n".join(text for _, text in sorted(rows.items()))

        def find_row(rows, needle: bytes) -> bytes:
            matches = [text for _, text in sorted(rows.items()) if needle in text]
            # Exactly the item row: the Selected line carries no item id.
            item_rows = [row for row in matches if b"Selected:" not in row]
            if len(item_rows) != 1:
                raise AssertionError(
                    f"expected one {needle!r} item row, got {len(item_rows)}: {matches!r}")
            return item_rows[0]

        rows = screen()
        glasses = find_row(rows, b"glasses")
        if b"0.200" not in glasses:
            raise AssertionError(
                f"account facts are hidden; widen the frame: {glasses!r}")
        if b"equipped" not in glasses or b"owned" in glasses:
            raise AssertionError(
                f"worn row must read equipped, not owned: {glasses!r}")
        shades = find_row(rows, b"shades")
        if b"owned" not in shades or b"equipped" in shades:
            raise AssertionError(
                f"unworn owned row must read owned, not equipped: {shades!r}")
        # The worn marker is bold; the owned state word is not. The words
        # stay the distinguisher (NO_COLOR drops the weight), so this
        # asserts emphasis only, beside the word assertions above.
        styled = screen_styled()
        styled_glasses = find_row(styled, b"glasses")
        if no_color:
            if b"\x1b[1m" in styled_glasses:
                raise AssertionError(
                    "NO_COLOR must drop the worn weight: "
                    f"{styled_glasses!r}")
        elif b"\x1b[1mequipped" not in styled_glasses:
            raise AssertionError(
                f"worn row must bold equipped: {styled_glasses!r}")
        styled_shades = find_row(styled, b"shades")
        if b"\x1b[1m" in styled_shades:
            raise AssertionError(
                f"owned row must carry no bold: {styled_shades!r}")
        selected_rows = [
            row for _, row in sorted(styled.items()) if b"Selected:" in row]
        if no_color:
            if any(b"\x1b[1m" in row for row in selected_rows):
                raise AssertionError(
                    "NO_COLOR must drop the Selected weight")
        elif b"Selected: 0.200  \x1b[1mequipped" not in screen_text(styled):
            raise AssertionError("Selected line must bold the worn marker")
        # Cursor starts at item 0 (glasses): the Selected line pins the
        # same exclusive words outside the row list.
        if b"Selected: 0.200  equipped" not in screen_text(rows):
            raise AssertionError("Selected line must mark the worn item")
        h.send_and_wait(process, master_fd, output, b"j", b"Items 2/18")
        h.drain_until_quiet(process, master_fd, output)
        moved = screen_text(screen())
        if b"Selected: 0.200 owned" not in moved:
            raise AssertionError("Selected line must mark the unworn owned item")
        if b"Selected: 0.200 owned  equipped" in moved:
            raise AssertionError("Selected line must not join both words")
        # Narrow frames hide account facts; the worn suffix must survive.
        h.resize_and_wait(
            process, master_fd, output, rows=32, columns=80,
            needle=CURRENT + b"Items")
        h.drain_until_quiet(process, master_fd, output)
        narrow_glasses = find_row(screen(), b"glasses")
        if b"equipped" not in narrow_glasses or b"owned" in narrow_glasses:
            raise AssertionError(
                f"narrow worn row must keep equipped only: {narrow_glasses!r}")
        narrow_styled_glasses = find_row(screen_styled(), b"glasses")
        if no_color:
            if b"\x1b[1m" in narrow_styled_glasses:
                raise AssertionError(
                    "narrow NO_COLOR must drop the worn weight: "
                    f"{narrow_styled_glasses!r}")
        elif b"\x1b[1mequipped" not in narrow_styled_glasses:
            raise AssertionError(
                "narrow worn row must keep bold equipped: "
                f"{narrow_styled_glasses!r}")
        os.write(master_fd, b"q")

    fixtures = h.keeper_runtime_http_fixtures()
    status, roster = fixtures["/api/v1/gate/keepers?detailed=true"]
    roster = copy.deepcopy(roster)
    # Ready items pair with a candle-less roster (item_roster_fixtures);
    # a candle-off roster answering Ready items is incoherent.
    roster.pop("candle", None)
    for keeper in roster["keepers"]:
        keeper.pop("candle_balance_milli", None)
        keeper.pop("candle_account_revision", None)
        if keeper["name"] == "alpha":
            keeper["portrait"] = {
                "state": "ready",
                "equipment": {
                    "face": "glasses", "neck": "bare_neck",
                    "head": "bare_head", "hand": "empty_hand",
                    "base": "no_dish",
                },
            }
    fixtures["/api/v1/gate/keepers?detailed=true"] = (status, roster)
    fixtures["/api/v1/keepers/alpha/items"] = account_fixture()
    h.run_terminal_scenario(
        executable,
        description="Keeper Items tab marks equipped and owned exclusively"
        + (" without color" if no_color else ""),
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=140,
        terminal_rows=32,
        extra_env={"NO_COLOR": "1"} if no_color else None,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    run(os.path.abspath(sys.argv[1]), no_color=True)
    print("keeper items equip words: PASS")
