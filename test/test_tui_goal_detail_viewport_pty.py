"""Goal evidence scrolls by physical rows; visible commands retain identity."""
import json
import os
import re
import sys
from pathlib import Path
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml", "bin/masc_tui.ml", "bin/masc_tui_planning_detail.ml",
                  "bin/masc_tui_render_prim.ml", "bin/masc_tui_types.ml")
GOAL_ID = "goal-detail-viewport"
TITLE = "TITLEHEAD " + "한 " * 18 + "goal evidence " * 8 + "TITLEEND"
METRIC = "metric-" + "0123456789abcdef" * 14 + "METRICEND"
TARGET = "TARGETHEAD " + "measured target " * 12 + "TARGETEND"
DUE = "2026-09-30T01:02:03Z source timezone " + "due-evidence-" * 10 + "DUEEND"
NOTE = "NOTEHEAD\n\n" + "review observation " * 12 + "\nNOTEEND"
STAMP = "2026-09-30T01:02:03Z"
APPROVAL = "approval-" + "0123456789abcdef" * 10 + "APPROVALEND"
KEEPER = "keeper-" + "delegated-" * 18 + "KEEPEREND"
RAW_CLOCK = "unreadable-clock-" + "raw-timestamp-" * 12 + "CLOCKEND"
WINDOW = re.compile(rb"\[lines (\d+)-(\d+)/(\d+)\]")

def screen(output):
    end = output.rfind(h.FRAME_END)
    rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output))
    return b"\n".join(rows[key] for key in sorted(rows))


def compact(text):
    return b"".join(h.unwrapped(text).split())


def window(output):
    match = WINDOW.search(screen(output))
    if match is None:
        raise AssertionError(f"Task window missing: {screen(output)!r}")
    return tuple(int(group) for group in match.groups())



def run(executable):
    goal = h.planning_goal(GOAL_ID, TITLE)
    goal.update(metric=METRIC, target_value=TARGET, due_date=DUE,
                priority=2, created_at=STAMP, updated_at=STAMP, last_review_at=STAMP,
                last_review_note=NOTE)
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([goal])
    fixtures[f"/api/v1/dashboard/goals/detail?goal_id={GOAL_ID}"] = (200, {"timeline": [
        {"ts": STAMP, "kind": "approval_state", "lane": "approval:" + APPROVAL,
         "title": "approval evidence", "summary": "pending approval", "severity": "warn"},
        {"ts": RAW_CLOCK, "kind": "keeper_event", "lane": "keeper:" + KEEPER,
         "title": "keeper observation", "summary": "TIMELINEEND", "severity": "ok"},
    ]})
    requests = []
    posted = []

    def transition(body):
        posted.append(json.loads(body))
        return 503, {"error": "fixture intentionally refuses transition"}

    fixtures["/api/v1/tools/masc_goal_transition"] = h.RequestHttpResponse(transition)

    def prepare(base):
        tasks = [{"id": f"task-linked-{index:02d}", "title": "Linked title 한 " + "evidence " * 8 + f"LINKEND{index:02d}",
                  "status": "todo", "priority": 1, "created_at": STAMP} for index in range(12)]
        folder = Path(base) / ".masc" / "tasks"
        (folder / "backlog.json").write_text(json.dumps({"tasks": tasks, "last_updated": STAMP, "version": 1}), encoding="utf-8")
        (folder / "goal_task_links.json").write_text(json.dumps({"links": [{"goal_id": GOAL_ID,
                        "task_ids": [task["id"] for task in tasks]}]}), encoding="utf-8")

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Work", b"TITLEHEAD")
        h.send_and_wait(process, fd, output, b"\r", b"Actions:")
        for width in (30, 60, 80, 120):
            h.resize_and_wait(process, fd, output, rows=400, columns=width,
                              needle=b"TITLEHEAD", final_cursor=b"\x1b[?25l")
            h.wait_for_output(process, fd, output, b"TIMELINEEND", start=0, timeout=10)
            h.drain_until_quiet(process, fd, output)
            all_text = compact(screen(output))
            for value in (TITLE, GOAL_ID, METRIC, TARGET, DUE, NOTE, STAMP, APPROVAL, KEEPER, RAW_CLOCK):
                assert compact(value.encode()) in all_text, (width, value, all_text)
            assert b"Owner:" not in screen(output), (width, screen(output))
            for index in range(12):
                assert f"task-linked-{index:02d}".encode() in all_text, (width, index, all_text)
                assert f"LINKEND{index:02d}".encode() in all_text, (width, index, all_text)
            for rows in (18, 24):
                h.resize_and_wait(process, fd, output, rows=rows, columns=width,
                                  needle=b"TITLEHEAD", final_cursor=b"\x1b[?25l")
                h.drain_until_quiet(process, fd, output)
                painted = h.screen_rows(bytes(output))
                assert max(painted) <= rows, (width, rows, max(painted))
                for text in painted.values():
                    assert h.fixture_cell_width(text.decode("utf-8", "replace")) <= width, (width, rows, text)
                first, last, total = window(output)
                assert first == 1 and last < total, (width, rows, first, last, total)
                for key in (b"[c]", b"[x]", b"[o]"):
                    assert key in screen(output), (width, rows, key, screen(output))
                h.send_and_wait(process, fd, output, b"\x1b[6~", b"[lines ")
                h.drain_until_quiet(process, fd, output)
                assert window(output)[0] == first + max(1, last - first), (width, rows, window(output), last)
                h.send_and_wait(process, fd, output, b"\x1b[5~", b"TITLEHEAD")
                h.send_and_wait(process, fd, output, b"j", b"[lines ")
                h.drain_until_quiet(process, fd, output)
                assert window(output)[0] == 2, window(output)
                h.send_and_wait(process, fd, output, b"k", b"TITLEHEAD")
                h.send_and_wait(process, fd, output, b"\x1b[F", b"TIMELINEEND")
                h.drain_until_quiet(process, fd, output)
                start, end, count = window(output)
                assert start > 1 and end == count, (start, end, count)
                print("GOAL_DETAIL_VIEWPORT " + json.dumps({"width": width, "rows": rows,
                       "window": [start, end, count], "screen": screen(output).decode("utf-8", "replace")}), flush=True)
                h.send_and_wait(process, fd, output, b"\x1b[H", b"TITLEHEAD")
        # The action row is pinned; its first press names the exact Goal and
        # second press posts once. The controlled server refuses the mutation.
        h.resize_and_wait(process, fd, output, rows=400, columns=80,
                          needle=b"TITLEHEAD", final_cursor=b"\x1b[?25l")
        h.send_and_wait(process, fd, output, b"c", b"press c again")
        assert not posted, posted
        h.resize_and_wait(process, fd, output, rows=18, columns=20,
                          needle=b"Goal detail needs", final_cursor=b"\x1b[?25l")
        assert b"Actions:" not in screen(output), screen(output)
        for key in (b"c", b"x", b"o", b"a"):
            h.press_and_settle(process, fd, output, key)
        assert not posted, "hidden actions dispatched through the too-small frame"
        h.resize_and_wait(process, fd, output, rows=400, columns=80,
                          needle=b"TITLEHEAD", final_cursor=b"\x1b[?25l")
        # An unrelated key cancels the arm; restore it on the readable frame.
        h.send_and_wait(process, fd, output, b"c", b"press c again")
        h.send_and_wait(process, fd, output, b"c", b"fixture intentionally refuses transition")
        assert posted == [{"goal_id": GOAL_ID, "action": "request_complete"}], posted
        # Refresh removes the Goal and reconciles the detail back to list mode.
        # This checks list-mode behavior, not the inconsistent-detail guard.
        fixtures[h.PLANNING_PATH] = h.planning_snapshot([])
        h.send_and_wait(process, fd, output, b"r", b"(no goals)")
        h.drain_until_quiet(process, fd, output)
        before = len(requests)
        os.write(fd, b"ccxxooaa")
        h.drain_until_quiet(process, fd, output)
        assert len(posted) == 1, posted
        assert not any("/api/v1/goals/confirmation" in path for path, _ in requests[before:]), requests[before:]
        assert b"Actions:" not in screen(output), screen(output)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Goal metadata and all linked Tasks remain reachable",
                            interact=interact, prepare_workspace=prepare,
                            http_fixtures=fixtures, http_requests=requests)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Goal detail physical-row viewport: PASS")
