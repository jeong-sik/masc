"""The lane detail keeps what the lane answers; the sheet keeps the rest."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names, so without this a
# change to the drawn text below reaches main with no scenario run. The pane
# is masc_tui_render.ml's and the sheet row is masc_tui_keys.ml's -- the move
# this proves takes words from one to the other, so both are named.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_keys.ml",
)

# Two sentences that read the same under every lane. They belong with the key
# that acts on them, not on a pane that has a lane selected.
MOVED = (b"TOML spec:", b"Press e to open")
# What this lane answers, and nothing else does.
KEPT = (b"Output meaning:", b"Evidence:")
# The same words, in the sheet, under [e].
IN_THE_SHEET = (b"catalog-ref", b"preview-checked")


def screen_text(output: bytearray) -> bytes:
    rows = h.screen_rows(bytes(output))
    return b"\n".join(rows[row] for row in sorted(rows))


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        h.wait_for_output(process, fd, output, KEPT[0], start=0, timeout=10)
        h.read_available(fd, output)
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
        h.send_and_wait(process, fd, output, b"?", b"MASC Cheat Sheet")
        # The slot-editor help added above [e] makes the last wrapped line of
        # [e] the first line below a thirty-row viewport. Exercise the sheet's
        # advertised scroll instead of assuming every key fits at offset zero.
        h.send_and_wait(process, fd, output, b"j", IN_THE_SHEET[0])
        h.read_available(fd, output)
        sheet = screen_text(output)
        for needle in IN_THE_SHEET:
            if needle not in sheet:
                raise AssertionError(f"the sheet does not carry {needle!r}")
        # Close the sheet before quitting: the two keys sent back to back
        # left the pane mid-transition and the exit snapshot never settled.
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Lanes")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Lane detail says what the lane answers",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("lane detail says what the lane answers: PASS")
