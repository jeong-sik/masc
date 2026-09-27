"""Probe-only paired Board measurement; both modes use this CI job and binary."""
from pathlib import Path
import os
import sys
import tempfile

import test_tui_keyboard_input as h


def run_case(executable: str, label: str, legacy: bool, directory: Path):
    post = h.board_selection_post("stage", "535-comment stage probe", "Stage probe body")
    post["comment_count"] = 535
    comments = [
        h.board_detail_comment(f"stage-{i}", f"Comment {i:03d} body")
        for i in range(535)
    ]
    fixtures = h.overview_event_http_fixtures()
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures["/api/v1/board/post-stage?format=flat"] = (
        200, {"post": post, "comments": comments}
    )
    frame_timing = directory / f"{label}-frame.txt"
    rows_wrap = directory / f"{label}-rows-wrap.txt"
    visible_comments = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.resize_and_wait(
            process, fd, output, rows=50, columns=180,
            needle=b"MASC Overview", controls=(h.FULL_REDRAW,),
        )
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        frame = h.send_and_wait(process, fd, output, b"\r", b"Comment 000")
        visible_comments.extend(
            line for line in h.screen_text(frame).splitlines() if b"Comment " in line
        )
        for _ in range(50):
            h.send_and_wait(process, fd, output, b"j", b"comment rows ")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description=f"{label} paired Board rows wrap",
        interact=interact, http_fixtures=fixtures, refresh=60.0,
        extra_env={
            "MASC_TUI_ROWS_WRAP_LEGACY": "1" if legacy else "0",
            "MASC_TUI_ROWS_WRAP_PROBE": str(rows_wrap),
            "MASC_TUI_FRAME_TIMING": str(frame_timing),
        },
    )
    report = frame_timing.read_text(encoding="utf-8")
    board_lines = [line.strip() for line in report.splitlines()
                   if line.strip().startswith("build[board-read] ")]
    if len(board_lines) != 1:
        raise AssertionError(f"{label}: expected one Board timing line: {report}")
    samples = [int(line) for line in rows_wrap.read_text(encoding="ascii").splitlines()]
    if not samples or not visible_comments:
        raise AssertionError(f"{label}: rows_wrap or Board screen was not reached")
    print(
        f"{label} mode={'legacy' if legacy else 'candidate'} "
        f"rows_wrap_ms={[round(ns / 1e6, 3) for ns in samples]} "
        f"{board_lines[0]}",
        flush=True,
    )
    return tuple(visible_comments)


def main(executable: str):
    with tempfile.TemporaryDirectory(prefix="tui-rows-wrap-paired-") as temporary:
        directory = Path(temporary)
        results = [
            run_case(executable, label, legacy, directory)
            for label, legacy in (
                ("before-a", True), ("after-a", False),
                ("after-b", False), ("before-b", True)
            )
        ]
        if not all(result == results[0] for result in results[1:]):
            raise AssertionError("visible Board comment rows changed between modes")
        print(f"paired Board probe: PASS; visible comment rows={len(results[0])}")


if __name__ == "__main__":
    main(sys.argv[1])
