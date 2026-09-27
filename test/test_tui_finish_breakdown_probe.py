"""One-off Board timing probe for issue #39292; no product assertions."""

import os
from pathlib import Path
import sys
import tempfile

import test_tui_keyboard_input as h


def run(executable: str, report_path: Path) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("stage", "535-comment stage probe", "Stage probe body")
    post["comment_count"] = 535
    comments = [
        h.board_detail_comment(f"stage-{i}", f"Comment {i:03d} body")
        for i in range(535)
    ]
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures["/api/v1/board/post-stage?format=flat"] = (
        200, {"post": post, "comments": comments}
    )

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.resize_and_wait(
            process, fd, output, rows=50, columns=180,
            needle=b"MASC Overview", controls=(h.FULL_REDRAW,),
        )
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, fd, output, b"\r", b"Comment 000")
        for _ in range(50):
            h.send_and_wait(process, fd, output, b"j", b"comment rows ")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Board finish breakdown probe",
        interact=interact, http_fixtures=fixtures, refresh=60.0,
        extra_env={"MASC_TUI_FRAME_TIMING": str(report_path)},
    )
    report = report_path.read_text(encoding="utf-8")
    for marker in ("build[board-read]", "stage[surface.body]",
                   "stage[surface.panes.roster]", "stage[surface.panes.side_read]",
                   "stage[surface.panes.acting]", "stage[surface.panes.side_paint]",
                   "stage[surface.panes.compose]", "stage[surface.panes.base_copy]",
                   "stage[surface.chrome]", "stage[surface.strip_frame]",
                   "stage[board.pane_prep]", "stage[board.render_prep]",
                   "name=unattributed"):
        if marker not in report:
            raise AssertionError(f"missing stage {marker}: {report}")
    print("=== board finish breakdown ===", flush=True)
    print(report, flush=True)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="tui-finish-breakdown-") as directory:
        run(sys.argv[1], Path(directory, "board.txt"))
