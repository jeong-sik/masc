"""Left opens Keepers from Home/chat, across hidden panes and terminal resizing.

Exercise real key input, rendered list placement, chat draft ownership, and
the HTTP boundary: browsing/dismissing must never send a chat or interrupt.
"""

import sys

import tui_keyboard_harness as h


LEFT = b"\x1b[D"
RIGHT = b"\x1b[C"
UP = b"\x1b[A"
DOWN = b"\x1b[B"
HOME = b"MASC Dashboard"
ALPHA = "Keepers ▸ alpha ▸ chat".encode()
BETA = "Keepers ▸ beta ▸ chat".encode()


def screen(process, fd, output):
    h.drain_until_quiet(process, fd, output)
    return h.screen_rows(bytes(output))


def assert_list(process, fd, output, *, beside):
    rows = screen(process, fd, output)
    title = next((line for line in rows.values() if b"KEEPERS" in line), None)
    assert title is not None, rows
    assert b"alpha" in b"\n".join(rows.values()), rows
    assert b"beta" in b"\n".join(rows.values()), rows
    if beside:
        # Both titles share the row: list on the left, Home on the right.
        assert b"MASC Dashboard" in title, rows
        assert title.index(b"KEEPERS") < title.index(b"MASC Dashboard"), rows
    else:
        assert not any(HOME in row for row in rows.values()), rows


def run(executable, *, columns, no_color=False):
    fixtures = h.keeper_runtime_http_fixtures()
    for keeper in ("alpha", "beta"):
        fixtures[f"/api/v1/keepers/{keeper}/chat/history"] = (200, [])
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, HOME, start=0, timeout=15)
        h.send_and_wait(process, fd, output, LEFT, b"KEEPERS")
        # A title can arrive before the roster; wait for actual rows.
        h.wait_for_output(process, fd, output, b"beta", start=0, timeout=15)
        assert_list(process, fd, output, beside=columns >= 110)
        h.send_and_wait(process, fd, output, RIGHT, HOME)
        assert b"KEEPERS" not in b"\n".join(screen(process, fd, output).values())

        h.send_and_wait(process, fd, output, LEFT, b"KEEPERS")
        h.send_and_wait(process, fd, output, b"\r", ALPHA)
        assert b"KEEPERS" not in b"\n".join(screen(process, fd, output).values())
        # A nonempty composer owns Left, including at byte zero. Insertion,
        # deletion and bracketed paste must operate at its actual cursor.
        h.send_and_wait(process, fd, output, "가나".encode(), "가나".encode())
        h.write_all(fd, output, LEFT)
        h.send_and_wait(process, fd, output, b"X", "가X나".encode())
        h.write_all(fd, output, b"\x7f" + LEFT + LEFT)
        h.send_and_wait(process, fd, output, b"\x1b[200~pasted\x1b[201~", "pasted가나".encode())
        assert b"KEEPERS" not in b"\n".join(screen(process, fd, output).values())
        h.write_all(fd, output, b"\x15")
        h.send_and_wait(process, fd, output, LEFT, b"Enter:open")
        h.send_and_wait(process, fd, output, RIGHT, ALPHA)
        assert b"KEEPERS" not in b"\n".join(screen(process, fd, output).values())
        h.send_and_wait(process, fd, output, b"alpha-unsent-draft", b"alpha-unsent-draft")
        # Explicit next-Keeper retains drafts even while there is text.
        h.send_and_wait(process, fd, output, b"\x07", BETA)
        assert b"alpha-unsent-draft" not in b"\n".join(screen(process, fd, output).values())
        h.send_and_wait(process, fd, output, b"beta-unsent-draft", b"beta-unsent-draft")
        h.send_and_wait(process, fd, output, b"\x07", ALPHA)
        assert b"alpha-unsent-draft" in b"\n".join(screen(process, fd, output).values())
        h.write_all(fd, output, b"\x15")
        h.send_and_wait(process, fd, output, LEFT, b"Enter:open")
        h.send_and_wait(process, fd, output, DOWN, b"beta")
        h.send_and_wait(process, fd, output, b"\r", BETA)
        assert b"beta-unsent-draft" in b"\n".join(screen(process, fd, output).values())
        h.write_all(fd, output, b"\x15")
        h.send_and_wait(process, fd, output, LEFT, b"Enter:open")
        h.send_and_wait(process, fd, output, UP, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", ALPHA)

        # Resizing keeps the visible navigator in charge of the arrows/Enter.
        h.send_and_wait(process, fd, output, LEFT, b"Enter:open")
        current = columns
        for width in (80, 120):
            # A resize to the size the terminal already has draws nothing.
            if width != current:
                h.resize_and_wait(process, fd, output, rows=30, columns=width,
                                  needle=b"KEEPERS", controls=(h.FULL_REDRAW,))
                current = width
            rows = screen(process, fd, output)
            text = b"\n".join(rows.values())
            assert b"alpha" in text and b"beta" in text, rows
            assert (ALPHA in text) == (width >= 110), rows
            if width < 110:
                assert b"alpha-unsent-draft" not in text, "hidden draft was relabelled in the list"
                h.write_all(fd, output, b"\x1b[200~must-not-enter-draft\x1b[201~")
                h.drain_until_quiet(process, fd, output)
        h.send_and_wait(process, fd, output, b"\x1b", ALPHA)
        text = b"\n".join(screen(process, fd, output).values())
        assert b"alpha-unsent-draft" not in text, text
        assert b"must-not-enter-draft" not in text, "navigator paste changed the draft"
        if columns >= 110:
            assert b"KEEPERS" not in text, "Left overwrote the hidden preference"
        # This chat came from Home; leaving returns there, with no write request.
        h.send_and_wait(process, fd, output, b"\x1b", HOME)
        assert not [path for path, _ in requests if path in
                    ("/api/v1/keepers/chat/stream", "/api/v1/keepers/turn/interrupt")], requests
        h.write_all(fd, output, b"q")

    h.run_terminal_scenario(
        executable,
        description=f"Keeper navigation at {columns} columns (NO_COLOR={no_color})",
        interact=interact, terminal_cols=columns, http_fixtures=fixtures,
        http_requests=requests, extra_env={"NO_COLOR": "1"} if no_color else {},
    )


def activity_focus(executable):
    """The left list takes arrows/Enter even after Activity owned the keyboard."""
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, HOME, start=0, timeout=15)
        h.send_and_wait(process, fd, output, b"\x0c", b"[Recent]")
        h.write_all(fd, output, b"\x17")
        h.drain_until_quiet(process, fd, output)
        h.send_and_wait(process, fd, output, LEFT, b"KEEPERS")
        h.wait_for_output(process, fd, output, b"beta", start=0, timeout=15)
        # Ctrl-W must not hand arrows back to the right-hand pane.
        h.write_all(fd, output, b"\x17")
        h.drain_until_quiet(process, fd, output)
        h.send_and_wait(process, fd, output, DOWN, b"beta")
        h.send_and_wait(process, fd, output, b"\r", BETA)
        h.send_and_wait(process, fd, output, b"\x1b", HOME)
        h.write_all(fd, output, b"q")

    h.run_terminal_scenario(executable, description="Keeper list takes Activity focus",
                            interact=interact, terminal_cols=180, http_fixtures=fixtures)


if __name__ == "__main__":
    run(sys.argv[1], columns=120)
    run(sys.argv[1], columns=80, no_color=True)
    activity_focus(sys.argv[1])
    print("tui Keeper navigation PTY: PASS")
