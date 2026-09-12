"""The "/" query says how many rows it reaches, and stays after Enter.

Two things the footer did not say. A query that matches nothing moves no
cursor, which looks the same as a query whose only match is already under
the cursor -- without a count they are indistinguishable. And Enter took the
query off the row while n and N went on stepping through its matches.

The number and the "n/N" belong to the rows the surface offers right now,
which is why opening a post drops both and closing it brings them back: the
same surface, a different row source.
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
    # Either Alpha may be the one the search lands on, so both open onto the
    # same body and the assertion does not depend on which.
    for post in posts[:2]:
        detail = dict(post, body="detail-body-alpha")
        fixtures[f"/api/v1/board/{post['id']}?format=flat"] = (
            200, {"post": detail, "comments": []})

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

        # Reading a post is the same surface with a different row source.
        # The count was taken over the list, and n/N step rows this pane does
        # not have, so both come off while the query itself stays.
        detail = h.send_and_wait(process, fd, output, b"\r", b"detail-body-alpha")
        if h.find_needle(detail, b"/Alpha") < 0:
            raise AssertionError("the post dropped the settled query")
        for stale in (b"/Alpha (2)", b"/Alpha n/N"):
            if h.find_needle(detail, stale) >= 0:
                raise AssertionError(
                    f"the post kept the list's marker: {stale!r}")

        # Back on the list the number is there again without a key being
        # pressed for it. A count cleared on the way into the post would come
        # back blank here and stay blank until the next n.
        h.send_and_wait(process, fd, output, b"\x1b", b"/Alpha (2) n/N")

        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="the search query says how many rows it reaches",
        interact=interact,
        http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("search count on the footer: PASS")
