"""Home keeps unknown decisions visible and returns to an explicit chat target."""
import base64
import json
import os
from pathlib import Path
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml", "bin/masc_tui_types.ml", "bin/masc_tui_render.ml",
    "bin/masc_tui_render_prim.ml", "bin/masc_tui_keys.ml",
    "bin/masc_tui_render_chat.ml",
)


def capture(process, fd, output, name, needle, *, columns=80):
    frame = h.resize_and_wait(
        process, fd, output, rows=24, columns=columns, needle=needle,
        controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l",
    )
    visible = h.screen_text(frame)
    for text in (b"Continue", b"Enter:open"):
        assert text in visible, (text, visible)
    for text in (b"scope windows in Usage", b"linked tasks", b"Start here"):
        assert text not in visible, (text, visible)
    print("HOME_JOURNEY_FRAME " + json.dumps({
        "name": name, "columns": columns, "rows": 24,
        "encoding": "base64", "pty": base64.b64encode(frame).decode(),
    }))
    return visible


def seed_goals(base, rows=()):
    (Path(base) / ".masc" / "goals.json").write_text(json.dumps({
        "version": 1, "updated_at": "2026-09-29T00:00:00Z", "goals": list(rows),
    }))


def assert_no_decision_posts(requests):
    # The fixture records protocol initialization as well as product writes.
    # Only those two MCP setup messages are harmless here; tools/call and
    # every product POST must still fail this navigation-only assertion.
    unexpected = [
        (path, body) for path, body in requests
        if path != "/mcp" or json.loads(body).get("method") not in (
            "initialize", "notifications/initialized",
        )
    ]
    assert not unexpected, f"Home navigation sent a decision POST: {unexpected!r}"


def unknown_and_resume(executable):
    fixtures = h.overview_event_http_fixtures()
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Choose a Keeper", start=0, timeout=10)
        frame = capture(process, fd, output, "unknown", b"Choose a Keeper")
        assert b"not fully read" in frame
        assert b"No decision is waiting" not in frame
        assert b"Continue with alpha" not in frame
        h.send_and_wait(process, fd, output, b"i", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.palette_go(process, fd, output, b"go dashboard", b"Continue with beta")
        # Approvals are unread; the next row is the explicitly opened chat.
        h.send_and_wait(process, fd, output, b"j\r", b"Esc:Dashboard")
        h.send_and_wait(process, fd, output, b"home-draft", b"home-draft")
        h.send_and_wait(process, fd, output, b"\x1b", b"Continue with beta")
        capture(process, fd, output, "resume-beta", b"Continue with beta", columns=120)
        h.send_and_wait(process, fd, output, b"\r", b"home-draft")
        h.send_and_wait(process, fd, output, b"\x1b", b"Continue with beta")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Home unknown and explicit resume",
                            interact=interact, http_fixtures=fixtures,
                            prepare_workspace=seed_goals)


def requests_are_navigation(executable):
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Approvals and questions: 3", start=0, timeout=10)
        capture(process, fd, output, "requests", b"Approvals and questions: 3")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Approvals")
        assert_no_decision_posts(requests)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Home requests open without deciding",
                            interact=interact, http_fixtures=fixtures,
                            http_requests=requests, prepare_workspace=seed_goals)


def automatic_gate_is_not_a_human_decision(executable):
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    operator_path = "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
    fixtures[operator_path] = h.approval_selection_snapshot([])
    gate = h.blocked_gate_detail_http_fixtures()["/api/v1/dashboard/gate"]
    template = gate[1]["approval_queue"][0]
    gate[1]["approval_queue"] = [
        dict(template, id=f"appr-{phase}", phase=phase)
        for phase in ("queued", "judging", "blocked")
    ]
    fixtures["/api/v1/dashboard/gate"] = gate

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"No decision is waiting", start=0, timeout=10)
        frame = capture(process, fd, output, "automatic-gate", b"No decision is waiting")
        assert b"Needs your decision" not in frame
        # The same read becomes actionable only with the typed human handoff.
        gate[1]["approval_queue"].append(dict(template, id="appr-human", phase="human_required"))
        h.send_and_wait(process, fd, output, b"r", b"Approvals and questions: 1")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Home excludes automatic Gate work",
                            interact=interact, http_fixtures=fixtures,
                            prepare_workspace=seed_goals)


def refresh_preserves_destination(executable):
    fixtures, items, _new = h.approval_selection_http_fixtures()
    current = []
    operator_path = "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
    fixtures[operator_path] = lambda: h.approval_selection_snapshot(list(current))
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"No decision is waiting", start=0, timeout=10)
        # Resolve the initial unread selection, leaving Choose highlighted.
        h.send_and_wait(process, fd, output, b"j", b"Choose a Keeper")
        current.extend(items)
        h.send_and_wait(process, fd, output, b"r", b"Approvals and questions: 3")
        capture(process, fd, output, "request-inserted", b"Approvals and questions: 3")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Keepers")
        assert_no_decision_posts(requests)
        h.palette_go(process, fd, output, b"go dashboard", b"Continue")
        h.send_and_wait(process, fd, output, b"k", b"Approvals and questions: 3")
        current.clear()
        h.send_and_wait(process, fd, output, b"r", b"Selection changed")
        # A removed destination must never silently fall through to another.
        result = h.send_and_wait(process, fd, output, b"\r", b"Selection changed")
        assert b"MASC Keepers" not in h.screen_text(result)
        assert_no_decision_posts(requests)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Home refresh preserves selected identity",
                            interact=interact, http_fixtures=fixtures,
                            http_requests=requests, prepare_workspace=seed_goals)


def empty_roster_preserves_confirmation(executable):
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    goal = {
        "id": "goal-home", "title": "Retained goal", "criterion_revision": "r1",
        "phase": "awaiting_confirmation", "priority": 2,
        "created_at": "2026-09-28T00:00:00Z", "updated_at": "2026-09-29T00:00:00Z",
    }

    def prepare(base):
        for path in (Path(base) / ".masc" / "keepers").glob("*.json"):
            path.unlink()
        seed_goals(base, [goal])

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"1 Goals to confirm", start=0, timeout=10)
        frame = capture(process, fd, output, "no-keepers-with-goal", b"1 Goals to confirm")
        assert b"Create a Keeper" in frame
        h.send_and_wait(process, fd, output, b"j\r", b"MASC Agenda")
        h.wait_for_output(process, fd, output, b"Retained goal", start=0, timeout=10)
        h.send_and_wait(process, fd, output, b"\x1b", b"Create a Keeper")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Home Keeper zero preserves decisions",
                            interact=interact, http_fixtures=fixtures,
                            prepare_workspace=prepare)


if __name__ == "__main__":
    exe = os.path.abspath(sys.argv[1])
    unknown_and_resume(exe)
    requests_are_navigation(exe)
    empty_roster_preserves_confirmation(exe)
    automatic_gate_is_not_a_human_decision(exe)
    refresh_preserves_destination(exe)
    print("Home journey PTY: PASS (5 scenarios)")
