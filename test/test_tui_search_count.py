"""The "/" query says how many rows it reaches, and stays after Enter.

Two things the footer did not say. A query that matches nothing moves no
cursor, which looks the same as a query whose only match is already under
the cursor -- without a count they are indistinguishable. And Enter took the
query off the row while n and N went on stepping through its matches.
"""
import os
import sys
import test_tui_keyboard_input as h


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    posts = [
        h.board_selection_post("a1", "Alpha one", "body"),
        h.board_selection_post("a2", "Alpha two", "body"),
        h.board_selection_post("b1", "Beta", "body"),
    ]
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=15)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")

        # Two of the three titles carry it, and the footer says so while the
        # query is still being typed.
        h.send_and_wait(process, fd, output, b"/", b"/")
        h.send_and_wait(process, fd, output, b"Alpha", b"/Alpha (2)")

        # Enter settles it. The query used to vanish here.
        h.send_and_wait(process, fd, output, b"\r", b"/Alpha (2) n/N")

        # A query nothing carries says so rather than going quiet.
        h.send_and_wait(process, fd, output, b"/", b"/")
        h.send_and_wait(process, fd, output, b"Gamma", b"/Gamma (none)")

        # Esc abandons this query and falls back to the settled one, which
        # n and N still step -- so its own count comes back with it.
        start = len(output)
        h.send_and_wait(process, fd, output, b"\x1b", b"/Alpha (2) n/N")
        if h.find_needle(output, b"/Gamma", start) >= 0:
            raise AssertionError("Esc left the abandoned query on the footer")

        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="the search query says how many rows it reaches",
        interact=interact,
        http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("search count on the footer: PASS")
