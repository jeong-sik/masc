"""Home keeps unknown decisions visible and returns to an explicit chat target."""
import base64
import json
import os
import re
from pathlib import Path
import sys
import tui_keyboard_approvals as _keyboard_approvals
import tui_keyboard_harness as _keyboard_harness


SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_render_approvals.ml",
    "bin/masc_tui_render_approvals.mli",
    "bin/masc_tui_approvals_model.ml",
    "bin/masc_tui_approvals_model.mli",
    "bin/masc_tui_home.ml",
    "bin/masc_tui_home.mli",
    "bin/masc_tui_render_chat.ml",
    "test/tui_keyboard_approvals.py",
    "test/tui_keyboard_harness.py",
)


def select_destination(process, fd, output, label, *, destinations=12):
    os.write(fd, b"k" * destinations)
    _keyboard_harness.drain_until_quiet(process, fd, output)
    pattern = re.compile(rb"\x1b\[7m[^\r\n]*" + re.escape(label))
    for index in range(destinations):
        rows = _keyboard_harness.screen_rows(bytes(output), preserve_styles=True)
        if any(pattern.search(row) for row in rows.values()):
            return
        if index + 1 < destinations:
            os.write(fd, b"j")
            _keyboard_harness.drain_until_quiet(process, fd, output)
    raise AssertionError(f"Home destination not selected: {label!r}")


def capture(process, fd, output, name, needle, *, columns=80):
    frame = _keyboard_harness.resize_and_wait(
        process, fd, output, rows=24, columns=columns, needle=needle,
        controls=(_keyboard_harness.FULL_REDRAW,), final_cursor=b"\x1b[?25l",
    )
    visible = _keyboard_harness.screen_text(frame)
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
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"Choose a Keeper", start=0, timeout=10)
        frame = capture(process, fd, output, "unknown", b"Choose a Keeper")
        assert b"not fully read" in frame
        assert b"No decision is waiting" not in frame
        assert b"Continue with alpha" not in frame
        _keyboard_harness.send_and_wait(process, fd, output, b"i", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, fd, output, b"beta")
        _keyboard_harness.send_and_wait(process, fd, output, b"c", b"Esc:list")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        _keyboard_harness.palette_go(process, fd, output, b"go dashboard", b"Continue with beta")
        # Select the conversation by its visible destination, independent of cards.
        select_destination(process, fd, output, b"Continue with beta")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Esc:Dashboard")
        _keyboard_harness.send_and_wait(process, fd, output, b"home-draft", b"home-draft")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Continue with beta")
        capture(process, fd, output, "resume-beta", b"Continue with beta", columns=120)
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"home-draft")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Continue with beta")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Home unknown and explicit resume",
                            interact=interact, http_fixtures=fixtures,
                            prepare_workspace=seed_goals)


def requests_are_navigation(executable):
    fixtures, _items, _new = _keyboard_harness.approval_selection_http_fixtures()
    requests = []

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"Approvals and questions: 3", start=0, timeout=10)
        capture(process, fd, output, "requests", b"Approvals and questions: 3")
        select_destination(process, fd, output, b"namespace_pause")
        detail = _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"reason-token-a")
        assert b"reason-token-a" in _keyboard_harness.screen_text(detail), detail
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        assert_no_decision_posts(requests)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Home requests open without deciding",
                            interact=interact, http_fixtures=fixtures,
                            http_requests=requests, prepare_workspace=seed_goals)


def automatic_gate_is_not_a_human_decision(executable):
    requests = []
    fixtures, _items, _new = _keyboard_harness.approval_selection_http_fixtures()
    operator_path = "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
    fixtures[operator_path] = _keyboard_harness.approval_selection_snapshot([])
    gate = _keyboard_approvals.blocked_gate_detail_http_fixtures()["/api/v1/dashboard/gate"]
    template = gate[1]["approval_queue"][0]
    gate[1]["approval_queue"] = [
        dict(template, id=f"appr-{phase}", phase=phase)
        for phase in ("queued", "judging")
    ]
    fixtures["/api/v1/dashboard/gate"] = gate

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"No decision is waiting", start=0, timeout=10)
        frame = capture(process, fd, output, "automatic-gate", b"No decision is waiting")
        assert b"Needs your decision" not in frame
        # A blocked Auto Judge exposes manual resolution in Approvals.
        gate[1]["approval_queue"].append(dict(template, id="appr-blocked", phase="blocked"))
        _keyboard_harness.send_and_wait(process, fd, output, b"r", b"Approvals and questions: 1 need you")
        frame = capture(process, fd, output, "blocked-gate", b"appr-blocked", columns=100)
        assert b"appr-blocked" in frame
        assert b"appr-queued" not in frame and b"appr-judging" not in frame
        select_destination(process, fd, output, b"appr-blocked")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"AUTO JUDGE BLOCKED")
        assert_no_decision_posts(requests)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        # A separate explicit human handoff retains its own identity.
        gate[1]["approval_queue"].append(dict(template, id="appr-human", phase="human_required"))
        _keyboard_harness.send_and_wait(process, fd, output, b"r", b"Approvals and questions: 2 need you")
        # Change the width so capture receives a full redraw after refresh;
        # requesting the current 80x24 size does not produce another frame.
        frame = capture(process, fd, output, "mixed-gate", b"Approval", columns=120)
        assert b"Approvals and questions: 2 need you" in frame
        assert b"appr-blocked" in frame and b"appr-human" in frame
        assert frame.count(b"Approval ") == 2, frame
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Home excludes automatic Gate work",
                            interact=interact, http_fixtures=fixtures,
                            http_requests=requests, prepare_workspace=seed_goals)
    assert_no_decision_posts(requests)


def refresh_preserves_destination(executable):
    fixtures, items, _new = _keyboard_harness.approval_selection_http_fixtures()
    current = []
    operator_path = "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
    fixtures[operator_path] = lambda: _keyboard_harness.approval_selection_snapshot(list(current))
    requests = []

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"No decision is waiting", start=0, timeout=10)
        select_destination(process, fd, output, b"Choose a Keeper")
        current.extend(items)
        _keyboard_harness.send_and_wait(process, fd, output, b"r", b"Approvals and questions: 3")
        capture(process, fd, output, "request-inserted", b"Approvals and questions: 3")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"MASC Keepers")
        assert_no_decision_posts(requests)
        _keyboard_harness.palette_go(process, fd, output, b"go dashboard", b"Continue")
        select_destination(process, fd, output, b"namespace_pause")
        current.clear()
        _keyboard_harness.send_and_wait(process, fd, output, b"r", b"Selection changed")
        # A removed destination must never silently fall through to another.
        result = _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Selection changed")
        assert b"MASC Keepers" not in _keyboard_harness.screen_text(result)
        assert_no_decision_posts(requests)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Home refresh preserves selected identity",
                            interact=interact, http_fixtures=fixtures,
                            http_requests=requests, prepare_workspace=seed_goals)


def empty_roster_preserves_confirmation(executable):
    fixtures, _items, _new = _keyboard_harness.approval_selection_http_fixtures()
    goal = {
        "id": "goal-home", "title": "Retained goal", "criterion_revision": "r1",
        "phase": "awaiting_confirmation", "priority": 2,
        "created_at": "2026-09-28T00:00:00Z", "updated_at": "2026-09-29T00:00:00Z",
    }

    planning_goal = dict(_keyboard_harness.planning_goal("goal-home", "Retained goal"),
                         phase="awaiting_confirmation")
    fixtures[_keyboard_harness.PLANNING_PATH] = _keyboard_harness.planning_snapshot([planning_goal])

    def prepare(base):
        for path in (Path(base) / ".masc" / "keepers").glob("*.json"):
            path.unlink()
        seed_goals(base, [goal])

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"Confirm Goal", start=0, timeout=10)
        frame = capture(process, fd, output, "no-keepers-with-goal", b"Confirm Goal")
        assert b"Create a Keeper" in frame
        select_destination(process, fd, output, b"goal-home")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"metric-goal-home")
        _keyboard_harness.wait_for_output(process, fd, output, b"Retained goal", start=0, timeout=10)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Create a Keeper")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Home Keeper zero preserves decisions",
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
