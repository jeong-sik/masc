"""A long Board thread stays navigable across wheel bursts and live edits."""
import os
import sys
import time
import test_tui_keyboard_input as h


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("scroll", "Long thread", "Short body")
    post["comment_count"] = 128
    comments = [h.board_detail_comment(f"comment-{i}",
        f"Comment {i:03d}\n" + (
            "\n\n**관측 결과** 긴 댓글 스크롤을 검증합니다. `result` **confirmed**.\n" * 24))
        for i in range(128)]
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    detail_path = "/api/v1/board/post-scroll?format=flat"
    fixtures[detail_path] = (200, {"post": post, "comments": comments})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, fd, output, b"\r", b"Comment 000")
        h.read_available(fd, output)
        start = len(output)
        # Same input stream as a terminal wheel burst followed by Escape.
        # Returning to the list must not wait for 100 complete thread layouts.
        deadline = time.monotonic() + 3.0
        # A nonblocking PTY may accept only part of this 1,201-byte burst.
        # Deliver its trailing Escape too, and count delivery in the deadline.
        h.write_all(fd, output, b"\x1b[<65;70;20M" * 100 + b"\x1b")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError("wheel burst delivery exceeded the return-to-list deadline")
        list_header = h.screen_header(b"MASC Board", b" (1)")
        h.wait_for_output(process, fd, output,
                          list_header, start=start, timeout=remaining)
        h.wait_for_output(process, fd, output, h.FRAME_END,
                          start=h.end_of_needle(output, list_header, start), timeout=3)
        changed = [dict(c) for c in comments]
        changed[0]["content"] = "Live edit is visible"
        edited_detail = h.SequencedHttpResponse([(200, {"post": post, "comments": changed})])
        fixtures[detail_path] = edited_detail
        h.send_and_wait(process, fd, output, b"\r", b"Live edit is visible")
        if edited_detail.served < 1:
            raise AssertionError("edited Board detail was not fetched from HTTP")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Long Board thread wheel burst",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Long Board thread scrolling: PASS")
