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


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("long thread reaches its ends: PASS")
