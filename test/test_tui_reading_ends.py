"""A long thread reaches its last comment with one key.

The reported case: a post with three hundred comments took a page key held
down to reach the newest comment, and the way back took it held down again.
Every reading pane in the TUI had the same gap -- rows the drawing formats
have no count at the keypress, so nothing bound End to them.

Pressing the key is the only way to know it is bound. The unit tests cannot
reach the dispatcher: nothing links the TUI executable.
"""
import os
import sys
import test_tui_keyboard_input as h

COMMENTS = 300


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("ends", "A thread with three hundred comments",
                                  "The post body, which the reading opens on.")
    post["comment_count"] = COMMENTS
    # One line each, so the reading is about twenty pages long and the last
    # comment's own line is what sits at the end. A long body would put the
    # tail of comment 299 on the last screen instead of its heading, and the
    # assertion would be about wrapping rather than about the jump.
    comments = [h.board_detail_comment(f"comment-{i}", f"Comment {i:03d}")
                for i in range(COMMENTS)]
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures["/api/v1/board/post-ends?format=flat"] = (
        200, {"post": post, "comments": comments})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=15)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        # The reading opens on the post body, so the first comment is what is
        # on screen and the last one is not.
        h.send_and_wait(process, fd, output, b"\r", b"Comment 000")

        last = f"Comment {COMMENTS - 1:03d}".encode()

        # One key to the end of the thread. Before this the page key was the
        # only way down and took about twenty presses.
        h.send_and_wait(process, fd, output, b"\x1b[F", last)

        # And one key back to the top. The heading the reading opens on is
        # the proof it is the top and not merely a different place.
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Comment 000")

        # End again, so the second jump is not the first one still settling.
        h.send_and_wait(process, fd, output, b"\x1b[F", last)

        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="a long thread reaches its ends",
        interact=interact,
        http_fixtures=fixtures)


def run_list_pane(executable: str) -> None:
    """The post list reaches its ends while a post is being read.

    With the list pane focused, j/k and the page keys move the list and open
    what they land on. The edge keys did nothing there: the reading-pane arm
    only answers when the detail is focused, and the row-list arm had no Board
    entry for a post that is open.
    """
    fixtures = h.overview_event_http_fixtures()
    posts = [
        h.board_selection_post(f"p{i}", f"Post {i:02d}", f"Body of post {i:02d}.")
        for i in range(12)
    ]
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})
    for post in posts:
        fixtures[f"/api/v1/board/{post['id']}?format=flat"] = (
            200, {"post": post, "comments": []})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=15)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        # Enter opens the first post with the detail focused.
        h.send_and_wait(process, fd, output, b"\r", b"Body of post 00")
        # The list pane beside the reading -- and Ctrl-W with it -- needs 110
        # inner columns (Masc_tui_roster_pane.threshold_cols). The harness
        # opens at 100, so at the default width this case does not exist: the
        # press is swallowed by its own guard and End answers for the reading
        # behind it. 120 and not something wider: from
        # Masc_tui_acting_pane.threshold_cols (132) the side pane takes 56
        # columns off the top, which puts the inner width back under 110
        # until 166.
        h.resize_and_wait(process, fd, output, rows=30, columns=120,
                          needle=b"Ctrl-W:switch")
        # Ctrl-W moves the focus to the list, which is where the edge keys had
        # nothing to move. The footer says which pane has j/k, so the press is
        # waited for rather than assumed.
        h.send_and_wait(process, fd, output, b"\x17", b"j/k:posts")
        # End opens the last post, the way j/k would if held down.
        h.send_and_wait(process, fd, output, b"\x1b[F", b"Body of post 11")
        # And Home comes back to the first.
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Body of post 00")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="the post list reaches its ends while reading",
        interact=interact,
        http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("long thread reaches its ends: PASS")
    run_list_pane(os.path.abspath(sys.argv[1]))
    print("post list reaches its ends while reading: PASS")
