"""A closed Board post shows a lock marker in the list and closer/successor/
summary detail in the read pane (task-1758/#39356 completion criterion 4)."""
import os
import sys

import tui_keyboard_harness as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without this
# a change to the closed-state drawing below reaches main with no scenario
# run. Both the list row and the detail lines are built in masc_tui_render_board.ml;
# the wire field is decoded in masc_tui_loader.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render_board.ml",
    "bin/masc_tui_render_board.mli",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_types.ml",
    "test/tui_keyboard_harness.py",
)

LOCK = b"\xf0\x9f\x94\x92"  # U+1F512 LOCK, the closed-post marker.


def closed_post(suffix: str, title: str, body: str, *, successor_id: str | None,
                 summary: str | None) -> dict[str, object]:
    post = h.board_selection_post(suffix, title, body)
    closed: dict[str, object] = {
        "closed_by": "closer-keeper",
        "closed_at": 1780000000,
    }
    if successor_id is not None:
        closed["successor_id"] = successor_id
    if summary is not None:
        closed["summary"] = summary
    post["closed"] = closed
    return post


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    closed = closed_post("closed", "Wrapped up thread", "Short body",
                          successor_id="post-succ", summary="moved \x1b[31mto\n the successor")
    open_post = h.board_selection_post("open", "Still going", "Other body")
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [closed, open_post]})
    fixtures["/api/v1/board/post-closed?format=flat"] = (
        200, h.board_detail_page(closed, []))

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        # The Board title renders before its list fetch lands ("(not
        # loaded)" is a real state), so wait for list content instead of
        # reading the first frame after the title.
        h.wait_for_output(process, fd, output, b"Still going", start=0,
                          timeout=10.0)
        h.read_available(fd, output)
        rows = h.screen_rows(bytes(output))
        closed_row = h.screen_row_of(rows, b"Wrapped up thread")
        if closed_row < 0:
            raise AssertionError("closed post title not found in the list")
        if LOCK not in rows[closed_row]:
            raise AssertionError(
                f"closed post row carries no lock marker: {rows[closed_row]!r}")
        open_row = h.screen_row_of(rows, b"Still going")
        if open_row < 0:
            raise AssertionError("open post title not found in the list")
        if LOCK in rows[open_row]:
            raise AssertionError(
                f"open post row wrongly carries the closed marker: {rows[open_row]!r}")

        # Move the cursor onto the closed row (it sorted where the fixture put
        # it, first) and open its detail.
        h.send_and_wait(process, fd, output, b"\r", b"closed by closer-keeper")
        h.read_available(fd, output)
        detail_rows = h.screen_rows(bytes(output), preserve_styles=True)
        closer_row = h.screen_row_of(detail_rows, b"closed by closer-keeper")
        if closer_row < 0:
            raise AssertionError("detail pane does not name the closer")
        if b"post-succ" not in detail_rows[closer_row]:
            raise AssertionError(
                f"detail closer row does not name the successor: "
                f"{detail_rows[closer_row]!r}")
        summary_row = h.screen_row_of(detail_rows, b"summary: moved")
        if summary_row < 0:
            raise AssertionError("detail pane does not show the close summary")
        summary_bytes = detail_rows[summary_row]
        if b"\x1b[31m" in summary_bytes or b"\n" in summary_bytes:
            raise AssertionError(
                f"detail summary leaked terminal control bytes/newline: "
                f"{summary_bytes!r}")
        if b"the successor" not in summary_bytes:
            raise AssertionError(
                f"detail summary lost its trailing text: {summary_bytes!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Closed Board post marker",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Closed Board post shows lock marker + closer/successor/summary: PASS")
