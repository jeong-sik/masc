"""Dashboard measurement clauses survive long titles and a narrower terminal."""
import os
import sys
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml",)


def run(executable):
    goal = h.planning_goal("goal-layout", "긴 목표 제목 " * 40)
    goal.update({"metric": "accepted checks", "target_value": "5", "task_count": 4,
                 "task_done_count": 2, "measurement": {"state": "not_recorded"},
                 "stagnation_seconds": None, "tasks": [], "children": []})
    fixtures = {h.DASHBOARD_GOALS_PATH: (200, {"tree": [goal]})}

    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, b"actual not recorded", start=0, timeout=10)
        for width in (80, 60, 120, 30, 40):
            h.resize_and_wait(process, master_fd, output, rows=40, columns=width,
                              needle=b"actual not recorded", final_cursor=b"\x1b[?25l")
            h.drain_until_quiet(process, master_fd, output)
            end = output.rfind(h.FRAME_END)
            completed = bytes(output[:end + len(h.FRAME_END)])
            screen = h.unwrapped(h.screen_text(completed))
            for evidence in (b"actual not recorded", "target accepted checks → 5".encode(),
                             b"linked tasks 2/4 done"):
                if evidence not in screen:
                    raise AssertionError(f"Goal measurement hidden at {width} columns: {screen!r}")
            rows = h.screen_rows(completed)
            title_row = h.screen_row_of(rows, "긴 목표 제목".encode())
            actual_row = h.screen_row_of(rows, b"actual not recorded")
            if title_row < 0 or actual_row <= title_row:
                raise AssertionError(f"Goal title consumed metric row: {rows!r}")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Dashboard Goal metrics survive long titles",
                            interact=interact, http_fixtures=fixtures, terminal_rows=40)


def bounded_preview(executable):
    goals = []
    for index in range(2):
        goal = h.planning_goal(f"goal-verbose-{index}", f"Verbose Goal {index}")
        goal.update({"metric": "long metric clause " * 80, "target_value": "long target " * 80,
                     "task_count": 4, "task_done_count": 2,
                     "measurement": {"state": "not_recorded"},
                     "stagnation_seconds": None, "tasks": [], "children": []})
        goals.append(goal)
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.DASHBOARD_GOALS_PATH] = (200, {"tree": goals})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"More Goal detail in Work", start=0, timeout=10)
        for width in (80, 60, 120):
            frame = h.resize_and_wait(process, fd, output, rows=24, columns=width,
                                      needle=b"More Goal detail in Work", controls=(h.FULL_REDRAW,))
            screen = h.screen_text(frame)
            for required in (b"Work", b"Usage", b"Needs you", b"More Goal detail in Work"):
                assert required in screen, (width, required, screen)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Verbose Goal preview preserves Dashboard summaries",
                            interact=interact, http_fixtures=fixtures, terminal_rows=24)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    bounded_preview(os.path.abspath(sys.argv[1]))
    print("Dashboard Goal layout: PASS")
