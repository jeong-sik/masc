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
import re
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

        # "n/N" names two keys, so the setting that takes the key text off the
        # footer takes it too; the query and its count are status and stay.
        # "?:help" directly after the marker is the footer with its hints off --
        # with them on, the surface's own keys sit between the two.
        h.send_and_wait(process, fd, output, b"?", b"MASC Cheat Sheet")
        os.write(fd, b"h")
        h.send_and_wait(process, fd, output, b"\x1b", b"/Alpha (2)  ?:help")
        h.send_and_wait(process, fd, output, b"?", b"MASC Cheat Sheet")
        os.write(fd, b"h")
        h.send_and_wait(process, fd, output, b"\x1b", b"/Alpha (2) n/N")

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

    def memory_interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Memory")
        h.wait_for_output(process, fd, output, b"Total 3 facts", start=0, timeout=5)
        h.send_and_wait(process, fd, output, b"\r", b"\xe2\x96\xb8 alpha")
        h.wait_for_output(
            process, fd, output, b"the deploy needs assets", start=0, timeout=5)
        h.send_and_wait(process, fd, output, b"/", b"/")
        # Origin is a searchable field, even when the claim does not name it.
        h.send_and_wait(process, fd, output, b"authored", b"/authored (1)")
        h.send_and_wait(process, fd, output, b"\x7f" * len("authored"), b"/\xe2\x96\x8c")
        h.send_and_wait(process, fd, output, b"unmatched-fact", b"/unmatched-fact (none)")
        h.send_and_wait(process, fd, output, b"\r", b"/unmatched-fact (none) n/N")
        # An empty filtered listing remains searchable, not an unsupported pane.
        h.send_and_wait(process, fd, output, b"/", b"/")
        h.send_and_wait(process, fd, output, b"deploy", b"/deploy (1)")
        h.send_and_wait(process, fd, output, b"\x1b", b"/unmatched-fact (none) n/N")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Memory search distinguishes zero matches from an unavailable pane",
        interact=memory_interact,
        http_fixtures=h.memory_facts_http_fixtures())


def run_git_changes_overlay(executable: str) -> None:
    """The Git changes overlay is what the search reaches, wherever it is drawn.

    [d] on the Keepers roster opens the overlay without leaving the Keepers
    surface, and the frame draws it there. The search asked the surface for its
    rows and got the roster back: the count described keeper names, and the key
    that steps to the next match moved the keeper cursor under the overlay.
    """
    fixtures = h.keeper_runtime_http_fixtures()
    # quokka first, so the cursor starts somewhere the query does not name and
    # a landing is a move rather than where it already was. Neither path
    # carries "alpha" or "beta", the two keeper names behind the overlay.
    fixtures["/api/v1/git/status"] = (
        200,
        {
            "scope": {"kind": "project"},
            "changes": [
                {"path": "bin/quokka.ml", "staged": True, "unstaged": False,
                 "untracked": False, "conflicted": False},
                {"path": "lib/zebra.ml", "staged": False, "unstaged": True,
                 "untracked": False, "conflicted": False},
            ],
            "total": 2,
        },
    )

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=15)
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.wait_for_output(process, fd, output, b"alpha", start=0, timeout=5)
        h.send_and_wait(process, fd, output, b"d", b"MASC Git Changes")
        h.wait_for_output(process, fd, output, b"lib/zebra.ml", start=0, timeout=5)

        # One path carries it and neither keeper name does, so a count of one
        # is the overlay's rows being counted and not the roster's.
        h.send_and_wait(process, fd, output, b"/", b"/")
        frame = h.send_and_wait(process, fd, output, b"zebra", b"/zebra (1)")

        # And the row the search landed on is the overlay's, not the keeper
        # cursor under it. The selected row is the one drawn in reverse video;
        # the bytes between that and the path must carry no escape of their
        # own, or the pattern spans the rows after it -- the frame separates
        # rows by cursor moves and not by newlines, so a [^\r\n]* reach here
        # matched the selected row above and a path drawn below it.
        selected = re.compile(rb"\x1b\[7m[^\x1b]*zebra\.ml")
        if not selected.search(frame):
            raise AssertionError(
                "the overlay does not draw the landed row as selected")

        h.send_and_wait(process, fd, output, b"\r", b"/zebra (1) n/N")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="the Git changes overlay is what the search counts",
        interact=interact,
        http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("search count on the footer: PASS")
    run_git_changes_overlay(os.path.abspath(sys.argv[1]))
    print("the overlay is what the search counts: PASS")
