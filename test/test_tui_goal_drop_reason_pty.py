"""A Goal drop reaches the Server only with the reason the operator typed."""
import json
import os
import sys
from pathlib import Path

import test_tui_keyboard_input as h


GOAL_ID = "goal-drop-reason"
TITLE = "DROPTITLE goal the operator gives up on"
# q twice quits, and j, k, x, o, c and r scroll, act and refresh elsewhere on
# the detail. While the reason is open every one of them is a letter.
TYPED = b"qq: quarterly jobs work took over xoc"
PASTED = "  superseded by the quarterly jobs work  "


def screen(output):
    end = output.rfind(h.FRAME_END)
    rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output))
    return b"\n".join(rows[key] for key in sorted(rows))


def run(executable):
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([h.planning_goal(GOAL_ID, TITLE)])
    posted = []

    def transition(body):
        posted.append(json.loads(body))
        return 503, {"error": "fixture refuses the drop"}

    fixtures["/api/v1/tools/masc_goal_transition"] = h.RequestHttpResponse(transition)

    def settled(process, fd, output, data):
        h.press_and_settle(process, fd, output, data)
        return screen(output)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Work", b"DROPTITLE")
        h.send_and_wait(process, fd, output, b"\r", b"Actions:")
        h.resize_and_wait(process, fd, output, rows=40, columns=120,
                          needle=b"DROPTITLE", final_cursor=b"\x1b[?25l")
        shown = settled(process, fd, output, b"x")
        assert b"DROP REASON: _" in shown, shown
        assert b"ARMED" not in shown, shown
        assert b"type why  Enter:drop  Esc:cancel" in shown, shown
        assert b"q:quit" not in shown, shown
        shown = settled(process, fd, output, b"\r")
        assert b"A drop needs a reason" in shown, shown
        assert b"DROP REASON: _" in shown, shown
        assert not posted, posted
        shown = settled(process, fd, output, TYPED)
        assert b"DROP REASON: " + TYPED + b"_" in shown, shown
        shown = settled(process, fd, output, b"\x7f")
        assert b"DROP REASON: " + TYPED[:-1] + b"_" in shown, shown
        assert not posted, posted
        shown = settled(process, fd, output, b"\x1b")
        assert b"DROP REASON" not in shown, shown
        assert b"A drop needs a reason" not in shown, shown
        assert b"DROPTITLE" in shown, shown
        assert not posted, posted
        # A reopened reason starts empty; a paste lands in it and Enter sends
        # the text without the spaces typed around it as the drop's note.
        shown = settled(process, fd, output, b"x")
        assert b"DROP REASON: _" in shown, shown
        settled(process, fd, output, b"  ")
        h.write_all(fd, output, b"\x1b[200~" + PASTED.encode() + b"\x1b[201~")
        settled(process, fd, output, b"  ")
        h.send_and_wait(process, fd, output, b"\r", b"fixture refuses the drop")
        workspace = Path(_base).resolve()
        assert posted == [{
            "expected_workspace": {
                "base_path": str(workspace),
                "masc_root": str(workspace / ".masc"),
            },
            "goal_id": GOAL_ID,
            "action": "drop",
            "note": PASTED.strip(),
        }], posted
        h.drain_until_quiet(process, fd, output)
        assert b"DROP REASON" not in screen(output), screen(output)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="A Goal drop sends the typed reason",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Goal drop reason: PASS")
