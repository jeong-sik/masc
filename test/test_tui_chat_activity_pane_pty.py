"""Self-composed chat and Board frames reserve the Activity pane above the footer."""
import sys
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui.ml",
)

def board_interaction(process, fd, _slave, output, _base):
    h.palette_go(process, fd, output, b"go board", b"MASC Board")
    h.send_and_wait(process, fd, output, b"w", b"first line: title")
    for draft in (b"", b"short draft"):
        if draft:
            h.write_all(fd, output, draft)
        h.drain_until_quiet(process, fd, output, cap=4.0)
        screen = h.screen_rows(bytes(output))
        # A self-composed frame owns its footer, even when the draft is empty.
        footer = h.screen_row_of(screen, b"Esc:")
        if footer != 30:
            raise AssertionError(f"Board footer is at {footer}, expected 30: {screen!r}")
        if b"\xe2\x94\x82" in screen[30]:
            raise AssertionError(f"Activity extends into Board footer: {screen[30]!r}")
        # Empty Activity rows intentionally have no vertical rule. Check its
        # header to prove the pane is present, and the footer's final position
        # to prove short drafts were padded before it.
        pane_cell = h.acting_pane_header_cell(output)
        expected = h.KEEPER_CHAT_PANE_COLUMNS - h.ACTING_PANE_NARROW_COLUMNS + 1
        if pane_cell != expected:
            raise AssertionError(f"Board Activity header at {pane_cell}, expected {expected}")
    h.send_and_wait(process, fd, output, b"\x1b", b"d:discard")
    h.send_and_wait(process, fd, output, b"d", b"MASC Board")
    h.write_all(fd, output, b"q")


if __name__ == "__main__":
    h.run_terminal_scenario(
        sys.argv[1],
        description="Keeper chat draws the Activity pane beside it",
        interact=h.keeper_chat_draws_activity_pane_interaction,
        terminal_cols=h.KEEPER_CHAT_PANE_COLUMNS,
    )
    h.run_terminal_scenario(
        sys.argv[1],
        description="Board drafts keep the footer below the Activity pane",
        interact=board_interaction,
        terminal_cols=h.KEEPER_CHAT_PANE_COLUMNS,
    )
    print("tui chat Activity pane: PASS")
