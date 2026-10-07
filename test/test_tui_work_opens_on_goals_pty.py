"""Work opens on its Goals; only a jump to one task opens it on Tasks."""
import os
import sys

import test_tui_keyboard_input as h


GOAL_ID = "goal-work-entry"
TITLE = "WORKGOAL goal shown when Work opens"


def screen(output):
    end = output.rfind(h.FRAME_END)
    rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output))
    return b"\n".join(rows[key] for key in sorted(rows))


def run(executable):
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([h.planning_goal(GOAL_ID, TITLE)])

    def settled(process, fd, output, data):
        h.press_and_settle(process, fd, output, data)
        return screen(output)

    def on_goals(shown, how):
        assert b"MASC Work / Tasks" not in shown, (how, shown)
        assert b"WORKGOAL" in shown, (how, shown)

    def interact(process, fd, _slave, output, _base):
        h.resize_and_wait(process, fd, output, rows=40, columns=120,
                          needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        h.palette_go(process, fd, output, b"go Work", b"WORKGOAL")
        h.send_and_wait(process, fd, output, b"t", b"MASC Work / Tasks")
        # Leaving and coming back by Tab, by Shift-Tab, and by the palette
        # each opens Work on its Goals again.
        settled(process, fd, output, b"\t")
        on_goals(settled(process, fd, output, b"\x1b[Z"), "shift-tab back")
        h.send_and_wait(process, fd, output, b"t", b"MASC Work / Tasks")
        settled(process, fd, output, b"\x1b[Z")
        on_goals(settled(process, fd, output, b"\t"), "tab back")
        h.send_and_wait(process, fd, output, b"t", b"MASC Work / Tasks")
        h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
        h.palette_go(process, fd, output, b"go Work", b"WORKGOAL")
        on_goals(screen(output), "palette back")
        # A jump to one task still lands on Tasks with that task open.
        h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
        h.palette_go(process, fd, output, b"task task-3", b"Task task-3")
        h.drain_until_quiet(process, fd, output)
        shown = screen(output)
        assert b"Task task-3" in shown, shown
        assert b"WORKGOAL" not in shown, shown
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Work opens on its Goals",
                            interact=interact, prepare_workspace=h.seed_row_budget_workspace,
                            http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Work opens on Goals: PASS")
