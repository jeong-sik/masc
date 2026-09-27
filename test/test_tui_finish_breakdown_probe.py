"""One-off Board timing probe for issue #39292; no product assertions."""

import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile

import test_tui_keyboard_input as h


def run(
    executable: str, report_path: Path | None
) -> tuple[bytes, list[dict[int, bytes]]]:
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

    last_frame: list[bytes] = []
    screens: list[dict[int, bytes]] = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.resize_and_wait(
            process, fd, output, rows=50, columns=180,
            needle=b"MASC Overview", controls=(h.FULL_REDRAW,),
        )
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        frame = h.send_and_wait(process, fd, output, b"\r", b"Comment 000")
        screens.append(h.screen_rows(frame, preserve_styles=True))
        for _ in range(50):
            frame = h.send_and_wait(process, fd, output, b"j", b"comment rows ")
            screens.append(h.screen_rows(frame, preserve_styles=True))
        last_frame.append(h.frame_containing(frame, b"comment rows "))
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Board finish breakdown probe",
        interact=interact, http_fixtures=fixtures, refresh=60.0,
        extra_env={"MASC_TUI_FRAME_TIMING": str(report_path) if report_path else ""},
    )
    if not last_frame:
        raise AssertionError("the Board detail frame was not captured")
    if len(screens) != 51:
        raise AssertionError(f"expected 51 Board screens, got {len(screens)}")
    if report_path is None:
        return last_frame[0], screens
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
    builds = {
        int(frame): float(ms)
        for frame, ms in re.findall(
            r"build frame=(\d+) ms=([0-9.]+) tag=board-read", report
        )
    }
    hits = [
        int(frame)
        for frame in re.findall(
            r"stage frame=(\d+) name=board\.cache\.compare\.hit", report
        )
    ]
    if (
        len(hits) < 50
        or len(hits) != len(set(hits))
        or any(n not in builds for n in hits)
    ):
        raise AssertionError(f"cache-hit Build frames did not pair: {len(hits)} hits")
    costs = sorted(builds[n] for n in hits)
    index = int(0.95 * (len(costs) - 1) + 0.5)
    print(
        f"Board cache-hit whole Build frames={len(costs)} "
        f"p95={costs[index]:.3f}ms max={costs[-1]:.3f}ms index={index}",
        flush=True,
    )
    print("=== board finish breakdown ===", flush=True)
    print(report, flush=True)
    return last_frame[0], screens


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="tui-finish-breakdown-") as directory:
        plain, plain_screens = run(sys.argv[1], None)
        timed, timed_screens = run(sys.argv[1], Path(directory, "board.txt"))
        for index, (before, after) in enumerate(zip(plain_screens, timed_screens)):
            if before != after:
                row = next(
                    row for row in sorted(before.keys() | after.keys())
                    if before.get(row) != after.get(row)
                )
                raise AssertionError(
                    f"timing changed Board screen {index} row {row}: "
                    f"plain={before.get(row, b'')[:160]!r} "
                    f"timed={after.get(row, b'')[:160]!r}"
                )
        print("Board styled-row parity: PASS (51 frames)", flush=True)
        if plain != timed:
            difference = next((i for i, (a, b) in enumerate(zip(plain, timed)) if a != b),
                              min(len(plain), len(timed)))
            raise AssertionError(
                f"timing changed Board frame bytes at {difference}: "
                f"plain={plain[difference:difference+80]!r} timed={timed[difference:difference+80]!r}"
            )
        print(f"board frame bytes identical: {len(plain)} bytes sha256={hashlib.sha256(plain).hexdigest()}",
              flush=True)
