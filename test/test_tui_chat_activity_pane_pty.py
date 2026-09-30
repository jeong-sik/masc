"""Self-composed chat and Board frames reserve the Activity pane above the footer."""
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers

SOURCE_MODULES = (
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui.ml",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_keepers.py",
    "test/tui_keyboard_runtime.py",
)

def board_interaction(process, fd, _slave, output, _base):
    _keyboard_harness.palette_go(process, fd, output, b"go board", b"MASC Board")
    _keyboard_harness.send_and_wait(process, fd, output, b"w", b"first line: title")
    for draft in (b"", b"short draft"):
        if draft:
            _keyboard_harness.write_all(fd, output, draft)
        _keyboard_harness.drain_until_quiet(process, fd, output, cap=4.0)
        screen = _keyboard_harness.screen_rows(bytes(output))
        # A self-composed frame owns its footer, even when the draft is empty.
        footer = _keyboard_harness.screen_row_of(screen, b"Esc:")
        if footer != 30:
            raise AssertionError(f"Board footer is at {footer}, expected 30: {screen!r}")
        if b"\xe2\x94\x82" in screen[30]:
            raise AssertionError(f"Activity extends into Board footer: {screen[30]!r}")
        # Empty Activity rows intentionally have no vertical rule. Check its
        # header to prove the pane is present, and the footer's final position
        # to prove short drafts were padded before it.
        pane_cell = _keyboard_keepers.acting_pane_header_cell(output)
        expected = _keyboard_keepers.KEEPER_CHAT_PANE_COLUMNS - _keyboard_harness.ACTING_PANE_NARROW_COLUMNS + 1
        if pane_cell != expected:
            raise AssertionError(f"Board Activity header at {pane_cell}, expected {expected}")
    _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"d:discard")
    _keyboard_harness.send_and_wait(process, fd, output, b"d", b"MASC Board")
    _keyboard_harness.write_all(fd, output, b"q")


if __name__ == "__main__":
    _keyboard_harness.run_terminal_scenario(
        sys.argv[1],
        description="Keeper chat draws the Activity pane beside it",
        interact=_keyboard_keepers.keeper_chat_draws_activity_pane_interaction,
        terminal_cols=_keyboard_keepers.KEEPER_CHAT_PANE_COLUMNS,
    )
    _keyboard_harness.run_terminal_scenario(
        sys.argv[1],
        description="Board drafts keep the footer below the Activity pane",
        interact=board_interaction,
        terminal_cols=_keyboard_keepers.KEEPER_CHAT_PANE_COLUMNS,
    )
    print("tui chat Activity pane: PASS")
