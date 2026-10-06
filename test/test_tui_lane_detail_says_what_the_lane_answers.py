"""The lane detail keeps what the lane answers; the sheet keeps the rest."""
import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers



# Two sentences that read the same under every lane. They belong with the key
# that acts on them, not on a pane that has a lane selected.
MOVED = (b"TOML spec:", b"Press e to open")
# What this lane answers, and nothing else does.
KEPT = (b"Output meaning:", b"Evidence:")
# The same words, in the sheet, under [e].
IN_THE_SHEET = (b"catalog-ref", b"preview-checked")


def screen_text(output: bytearray) -> bytes:
    rows = _keyboard_harness.screen_rows(bytes(output))
    return b"\n".join(rows[row] for row in sorted(rows))


def run(executable: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_keepers.LANE_INVENTORY_PATH] = _keyboard_keepers.lane_inventory_response()

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.wait_for_output(process, fd, output, b"Board Attention", start=0, timeout=10)
        _keyboard_harness.send_and_wait(process, fd, output, b"d", KEPT[0])
        _keyboard_harness.drain_until_quiet(process, fd, output)
        _keyboard_harness.read_available(fd, output)
        pane = screen_text(output)
        for needle in MOVED:
            if needle in pane:
                raise AssertionError(
                    f"the lane detail still spends a row on {needle!r}")
        # Checked after the rows are known to be gone: with them present this
        # pane overruns a thirty-row terminal and the evidence line -- the one
        # thing only this lane can say -- is what falls off the bottom.
        for needle in KEPT:
            if needle not in pane:
                raise AssertionError(
                    f"the lane detail lost what the lane answers: {needle!r}")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Lanes")
        # The words are not gone from the product, only from the pane.
        _keyboard_harness.send_and_wait(process, fd, output, b"?", b"MASC Cheat Sheet")
        # New common-inventory keys may wrap above this entry; look at the
        # current sheet while scrolling instead of hardcoding a row offset.
        for _ in range(24):
            _keyboard_harness.drain_until_quiet(process, fd, output)
            sheet = screen_text(output)
            if all(needle in sheet for needle in IN_THE_SHEET):
                break
            _keyboard_harness.send_and_wait(process, fd, output, b"j", b"MASC Cheat Sheet")
        else:
            raise AssertionError(f"sheet omitted slot-editor guidance: {sheet!r}")
        # Close the sheet before quitting: the two keys sent back to back
        # left the pane mid-transition and the exit snapshot never settled.
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Lanes")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Lane detail says what the lane answers",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("lane detail says what the lane answers: PASS")
