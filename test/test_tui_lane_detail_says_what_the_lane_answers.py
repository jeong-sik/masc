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
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = _keyboard_keepers.standalone_lanes_response()

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.wait_for_output(process, fd, output, KEPT[0], start=0, timeout=10)
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
        # The words are not gone from the product, only from the pane.
        _keyboard_harness.send_and_wait(process, fd, output, b"?", b"MASC Cheat Sheet")
        # The slot-editor help above [e] puts [catalog-ref] below the first
        # viewport. Exercise the sheet's scroll to reach the full [e] hint.
        # On a thirty-row terminal the sheet shows 22 lines; [s] wraps to
        # nine, so [e] starts on sheet line 21 and [catalog-ref] sits on its
        # sixth wrapped line, line 26. Four presses show lines 5-26, which
        # still hold [preview-checked] on line 24. A longer Lanes hint above
        # [e] moves both lines down and needs more presses here.
        _keyboard_harness.send_and_wait(process, fd, output, b"jjjj", IN_THE_SHEET[0])
        _keyboard_harness.read_available(fd, output)
        sheet = screen_text(output)
        for needle in IN_THE_SHEET:
            if needle not in sheet:
                raise AssertionError(f"the sheet does not carry {needle!r}")
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
