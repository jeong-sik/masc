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


def run(executable: str) -> None:
    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", CURRENT + b"Info")
        h.send_and_wait(process, master_fd, output, b"]", CURRENT + b"Items")
        h.drain_until_quiet(process, master_fd, output)
        rows = h.screen_rows(
            bytes(output[: output.rfind(h.FRAME_END) + len(h.FRAME_END)]))

        def find_row(needle: bytes) -> bytes:
            matches = [text for _, text in sorted(rows.items()) if needle in text]
            # Exactly the item row: the Selected line carries facts only.
            item_rows = [row for row in matches if b"Selected:" not in row]
            if len(item_rows) != 1:
                raise AssertionError(
                    f"expected one {needle!r} item row, got {len(item_rows)}: {matches!r}")
            return item_rows[0]

        glasses = find_row(b"glasses")
        if b"0.200" not in glasses:
            raise AssertionError(
                f"account facts are hidden; widen the frame: {glasses!r}")
        if b"equipped" not in glasses or b"owned" in glasses:
            raise AssertionError(
                f"worn row must read equipped, not owned: {glasses!r}")
        shades = find_row(b"shades")
        if b"owned" not in shades or b"equipped" in shades:
            raise AssertionError(
                f"unworn owned row must read owned, not equipped: {shades!r}")
        os.write(master_fd, b"q")

    fixtures = h.keeper_runtime_http_fixtures()
    status, roster = fixtures["/api/v1/gate/keepers?detailed=true"]
    roster = copy.deepcopy(roster)
    for keeper in roster["keepers"]:
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
        description="Keeper Items tab marks equipped and owned exclusively",
        interact=interact,
        http_fixtures=fixtures,
        terminal_cols=140,
        terminal_rows=32,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("keeper items equip words: PASS")
