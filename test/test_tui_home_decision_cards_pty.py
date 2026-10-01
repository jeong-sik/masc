"""Fixture PTY acceptance for Home request identities and bounded card windows.

Navigation only: no approval, confirmation or task mutation is authorized.
"""
import base64
import copy
import itertools
import json
import os
from pathlib import Path
import re
import sys
import threading

import test_tui_home_journey_pty as home
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml", "bin/masc_tui_types.ml", "bin/masc_tui_render.ml",
    "bin/masc_tui_loader.ml",
)
OPERATOR_PATH = "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
HELD_PATH = "/api/v1/keepers/tool-approvals"
GATE_PATH = "/api/v1/dashboard/gate"
FRAME_SEQUENCE = itertools.count(1)


def selected(label):
    return re.compile(rb"\x1b\[7m[^\r\n]*" + re.escape(label))


def assert_selected(output, label):
    rows = h.screen_rows(bytes(output), preserve_styles=True)
    assert any(selected(label).search(row) for row in rows.values()), rows


def select_home(process, fd, output, label, *, destinations):
    """Traverse the accepted fixture's destinations, checking the drawn band."""
    os.write(fd, b"k" * destinations)
    h.drain_until_quiet(process, fd, output)
    for index in range(destinations):
        rows = h.screen_rows(bytes(output), preserve_styles=True)
        if any(selected(label).search(row) for row in rows.values()):
            return
        if index + 1 < destinations:
            os.write(fd, b"j")
            h.drain_until_quiet(process, fd, output)
    raise AssertionError(f"Home never selected {label!r}: {h.screen_text(bytes(output))!r}")


def open_held_detail(process, fd, output, call_id, command):
    # The exact authority is a labelled call row, independent of copies in
    # args or question text. Finish the destination frame before checking it.
    h.send_and_wait(process, fd, output, b"\r", call_id)
    drawn = h.screen_rows(bytes(output))
    assert any(re.fullmatch(rb"\s*call\s+" + re.escape(call_id) + rb"\s*", row)
               for row in drawn.values()), drawn
    assert any(re.fullmatch(rb"\s*args\s+" + re.escape(command) + rb"\s*", row)
               for row in drawn.values()), drawn
    return h.screen_text(bytes(output))


def frame(process, fd, output, name):
    # Force a new full frame even when the previous viewport was also 80x24.
    h.resize_and_wait(process, fd, output, rows=24, columns=81,
                      needle=b"Enter:open", controls=(h.FULL_REDRAW,),
                      final_cursor=b"\x1b[?25l")
    drawn = h.resize_and_wait(process, fd, output, rows=24, columns=80,
                              needle=b"Enter:open", controls=(h.FULL_REDRAW,),
                              final_cursor=b"\x1b[?25l")
    rows = h.screen_rows(drawn)
    assert max(rows) <= 24, rows
    assert all(h.fixture_cell_width(row.decode()) <= 80 for row in rows.values()), rows
    print("HOME_JOURNEY_FRAME " + json.dumps({
        "name": f"{name}-{next(FRAME_SEQUENCE)}", "columns": 80, "rows": 24,
        "encoding": "base64", "pty": base64.b64encode(drawn).decode(),
    }))
    return h.screen_text(drawn)


def held(call_id, question):
    # Reuse the authoritative held-call wire fixture, including args/timing.
    template = h.escaped_question_http_fixtures()[HELD_PATH][1]["pending"][0]
    return dict(template, tool_call_id=call_id, question=question,
                args='{"command":"echo ' + call_id + '"}')


def fixtures_with_held(rows):
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    fixtures[OPERATOR_PATH] = h.approval_selection_snapshot([])
    fixtures[HELD_PATH] = lambda: (200, {"pending": copy.deepcopy(rows)})
    return fixtures


def run(executable, description, fixtures, interact, requests, *, prepare=home.seed_goals,
        refresh=60.0):
    h.run_terminal_scenario(executable, description=description, interact=interact,
                            http_fixtures=fixtures, http_requests=requests,
                            prepare_workspace=prepare, refresh=refresh)
    # Also inspect writes made during exit, after the last in-session assertion.
    home.assert_no_decision_posts(requests)


def same_keeper_distinct_and_duplicate(executable):
    first = held("call-home-a", "same held reason")
    rows = [first, held("call-home-b", "same held reason"), dict(first)]
    fixtures = fixtures_with_held(rows)
    requests = []

    def interact(process, fd, _slave, output, _base):
        # Held calls can arrive before the separate confirmation/question
        # reads. Observe their completed aggregate before measuring this frame;
        # the exact distinct call IDs and deduplication are still checked below.
        h.wait_for_output(process, fd, output,
                          b"Approvals and questions: 2 need you", start=0, timeout=10)
        visible = frame(process, fd, output, "distinct-authority-ids")
        assert visible.count(b"Held call") == 2, visible
        assert visible.count(b"same held reason") == 2, visible
        assert visible.count(b"[call-home-a]") == 1, visible
        assert visible.count(b"[call-home-b]") == 1, visible
        assert b"Approvals and questions: 2 need you" in visible, visible
        assert b"3 need you" not in visible, visible
        # After successful reads the focus may be the first known card or
        # the known aggregate. Transient boot rows are not assumed pinned.
        # Inserting a new top card must preserve the rendered known identity.
        styled = h.screen_rows(bytes(output), preserve_styles=True)
        initial = next((label for label in (b"[call-home-a]", b"Approvals and questions:")
                        if any(selected(label).search(row) for row in styled.values())), None)
        assert initial is not None, styled
        rows.insert(0, held("call-home-new-top", "home-new-top-card"))
        h.send_and_wait(process, fd, output, b"r", b"home-new-top-card")
        assert_selected(output, initial)
        select_home(process, fd, output, b"[call-home-b]", destinations=5)
        open_held_detail(process, fd, output, b"call-home-b",
                         b'{"command":"echo call-home-b"}')
        home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        assert_selected(output, b"[call-home-b]")
        os.write(fd, b"q")

    run(executable, "Home keeps two held calls for one Keeper and deduplicates authority ID",
        fixtures, interact, requests)


def failed_source_keeps_known_cards(executable):
    fixtures = fixtures_with_held([held("call-known", "known-held-card")])
    fixtures[OPERATOR_PATH] = (503, {"error": "confirm source offline"})
    gate = copy.deepcopy(h.blocked_gate_detail_http_fixtures()[GATE_PATH])
    gate[1]["approval_queue"][0].update(id="gate-known", phase="human_required",
                                        tool_name="known-gate-card")
    fixtures[GATE_PATH] = gate
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"known-gate-card", start=0, timeout=10)
        h.wait_for_output(process, fd, output, b"known-held-card", start=0, timeout=10)
        h.wait_for_output(process, fd, output, b"confirm queue not fully read", start=0, timeout=10)
        visible = frame(process, fd, output, "partial-source-success")
        for label in (b"known-held-card", b"known-gate-card", b"confirm queue not fully read"):
            assert label in visible, visible
        assert b"No decision is waiting" not in visible, visible
        select_home(process, fd, output, b"known-gate-card", destinations=4)
        h.send_and_wait(process, fd, output, b"\r", b"gate-known")
        home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        os.write(fd, b"q")

    run(executable, "Home source failure preserves current held and Gate cards",
        fixtures, interact, requests)


def hidden_help_does_not_pin_unseen_request(executable):
    rows = [held("call-hidden-b", "hidden-B-card")]
    fixtures = fixtures_with_held(rows)
    gate = copy.deepcopy(h.blocked_gate_detail_http_fixtures()[GATE_PATH])
    gate[1]["approval_queue"] = []
    fixtures[GATE_PATH] = gate
    fixtures[h.KEEPER_ASKS_PATH] = (200, {"keeper": None, "open_count": 0, "asks": []})
    release = threading.Event()
    requested = threading.Event()

    def held_read():
        requested.set()
        if not release.wait(30):
            raise AssertionError("hidden Home request fixture was not released")
        return 200, {"pending": copy.deepcopy(rows)}

    fixtures[HELD_PATH] = held_read
    requests = []

    def interact(process, fd, _slave, output, _base):
        try:
            assert h.wait_for_fixture_event(process, fd, output, requested, timeout=10)
            h.send_and_wait(process, fd, output, b"?", b"MASC Cheat Sheet")
            release.set()
            # This badge is computed from applied held-call rows, proving the
            # snapshot crossed the mailbox while Help still owned the frame.
            h.wait_for_output(process, fd, output, "Awaiting you·1".encode(),
                              start=len(output), timeout=10)
            assert b"MASC Cheat Sheet" in h.screen_text(bytes(output))
            rows.insert(0, held("call-hidden-a", "hidden-A-card"))
            h.wait_for_output(process, fd, output, "Awaiting you·2".encode(),
                              start=len(output), timeout=10)
            assert b"MASC Cheat Sheet" in h.screen_text(bytes(output))
            h.send_and_wait(process, fd, output, b"\x1b", b"hidden-A-card")
            assert_selected(output, b"hidden-A-card")
            open_held_detail(process, fd, output, b"call-hidden-a",
                             b'{"command":"echo call-hidden-a"}')
            home.assert_no_decision_posts(requests)
            os.write(fd, b"q")
        finally:
            release.set()

    run(executable, "Home first-visible request is not pinned by a hidden Help frame",
        fixtures, interact, requests, refresh=1.0)


def each_failed_source_keeps_other_cards(executable):
    cases = ((OPERATOR_PATH, b"confirm queue"), (HELD_PATH, b"held calls"),
             (GATE_PATH, b"Gate queue"), (h.KEEPER_ASKS_PATH, b"questions"))
    for failed_path, failed_label in cases:
        fixtures = fixtures_with_held([held("call-partial", "retained-held-card")])
        gate = copy.deepcopy(h.blocked_gate_detail_http_fixtures()[GATE_PATH])
        gate[1]["approval_queue"][0].update(id="gate-partial", phase="human_required",
                                            tool_name="retained-gate-card")
        fixtures[GATE_PATH] = gate
        fixtures[h.KEEPER_ASKS_PATH] = (200, {"keeper": None, "open_count": 0, "asks": []})
        fixtures[failed_path] = (503, {"error": "isolated source failure"})
        requests = []

        def interact(process, fd, _slave, output, _base):
            known = b"retained-gate-card" if failed_path == HELD_PATH else b"retained-held-card"
            h.wait_for_output(process, fd, output, known, start=0, timeout=10)
            note = b"Approvals and questions: " + failed_label + b" not fully read"
            # Match the sole-source label through the end of its drawn row,
            # so transient boot notes cannot satisfy the settled-source barrier.
            settled = re.compile(re.escape(note) + rb"(?: |\x1b\[[0-9;]*m)*\x1b\[0m\x1b\[[0-9;]*H")
            h.wait_for_output(process, fd, output, settled, start=0, timeout=10)
            h.resize_and_wait(process, fd, output, rows=24, columns=81,
                              needle=note, controls=(h.FULL_REDRAW,),
                              final_cursor=b"\x1b[?25l")
            for columns in (80, 140):
                drawn = h.resize_and_wait(process, fd, output, rows=24, columns=columns,
                                          needle=note, controls=(h.FULL_REDRAW,),
                                          final_cursor=b"\x1b[?25l")
                visible = h.screen_text(drawn)
                assert known in visible and note in visible, visible
                for _path, label in cases:
                    if label != failed_label:
                        assert label + b" not fully read" not in visible, visible
                assert b"No decision is waiting" not in visible, visible
            home.assert_no_decision_posts(requests)
            os.write(fd, b"q")

        run(executable, f"Home retains successful requests beside {failed_label.decode()} failure",
            fixtures, interact, requests)


def seed_operator_task(base, *, backup=False):
    home.seed_goals(base)
    root = Path(base) / ".masc"
    task = {
        "id": "task-777", "title": "Primary task remains visible", "description": "",
        "priority": 1, "files": [], "created_at": "2026-09-29T00:00:00Z",
        "status": "claimed", "assignee": "orphan-home-owner",
        "claimed_at": "2026-09-29T00:00:00Z",
    }
    snapshot = {"tasks": [task], "version": 1, "last_updated": "2026-09-29T00:00:00Z"}
    path = root / "tasks" / "backlog.json"
    path.write_text(json.dumps(snapshot))
    if backup:
        path.with_name(path.name + ".last-good").write_text(json.dumps(snapshot))
        path.write_text("{broken primary")


def operator_task_survives_supplemental_failure(executable):
    cases = (("tasks-archive.json", None), ("tasks/goal_task_links.json", None),
             ("tasks/goal_task_links.json", []),
             ("tasks/goal_task_links.json", [{"goal_id": "goal-recovery", "task_ids": ["task-777"]}]))
    for relative, recovery_links in cases:
        fixtures = fixtures_with_held([])
        fixtures["/api/v1/dashboard/tasks/history?task_id=task-777&limit=50"] = (200, [])
        requests = []

        def prepare(base):
            seed_operator_task(base)
            (Path(base) / ".masc" / relative).write_text("{broken supplemental source")
            if recovery_links is not None:
                recovery = Path(base) / ".masc" / (relative + ".last-good")
                recovery.write_text(json.dumps({"version": 1, "links": recovery_links}))

        def interact(process, fd, _slave, output, base):
            h.wait_for_output(process, fd, output, b"Operator task \xc2\xb7 task-777", start=0, timeout=10)
            visible = frame(process, fd, output, "operator-task-supplemental-failure")
            assert b"Operator tasks unavailable" not in visible, visible
            if relative == "tasks/goal_task_links.json":
                assert b"Work:" in visible, visible
                assert b"Work: reading unavailable" not in visible, visible
            select_home(process, fd, output, b"Operator task \xc2\xb7 task-777", destinations=4)
            h.send_and_wait(process, fd, output, b"\r", b"Primary task remains visible")
            drawn = h.screen_text(bytes(output))
            assert b"MASC Task" in drawn and b"task-777" in drawn, drawn
            if relative == "tasks/goal_task_links.json":
                assert b"links unavailable" in drawn, drawn
                assert b"not linked to a goal" not in drawn, drawn
                assert b"goal-recovery" not in drawn, drawn
                (Path(base) / ".masc" / relative).write_text(json.dumps({"version": 1, "links": []}))
                h.send_and_wait(process, fd, output, b"r", b"not linked to a goal")
            else:
                assert b"not linked to a goal" in drawn, drawn
                assert b"links unavailable" not in drawn, drawn
            path = Path(base) / ".masc" / "tasks" / "backlog.json"
            snapshot = json.loads(path.read_text())
            snapshot["tasks"][0]["title"] = "Same primary task after refresh"
            snapshot["version"] += 1
            path.write_text(json.dumps(snapshot))
            h.send_and_wait(process, fd, output, b"r", b"Same primary task after refresh")
            drawn = h.screen_text(bytes(output))
            assert b"MASC Task" in drawn and b"task-777" in drawn, drawn
            # The link registry was already repaired before the title refresh.
            assert b"not linked to a goal" in drawn, drawn
            assert b"links unavailable" not in drawn, drawn
            assert b"membership unknown" not in drawn, drawn
            home.assert_no_decision_posts(requests)
            h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
            assert_selected(output, b"Operator task \xc2\xb7 task-777")
            os.write(fd, b"q")

        backup_kind = "no-backup" if recovery_links is None else "empty-backup" if not recovery_links else "linked-backup"
        run(executable, f"Home current task and exact detail survive {relative} failure ({backup_kind})",
            fixtures, interact, requests, prepare=prepare)


def planning_link_failure_has_own_diagnostic(executable):
    fixtures = fixtures_with_held([])
    goal = h.planning_goal("goal-source-truth", "Planning link source fixture")
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([goal])
    fixtures["/api/v1/dashboard/goals/detail?goal_id=goal-source-truth"] = (200, {"timeline": []})
    requests = []

    def prepare(base):
        seed_operator_task(base)
        path = Path(base) / ".masc" / "tasks" / "goal_task_links.json"
        path.write_text("{unreadable primary")
        path.with_name(path.name + ".last-good").write_text(json.dumps({"version": 1,
            "links": [{"goal_id": goal["id"], "task_ids": ["task-777"]}]}))

    def interact(process, fd, _slave, output, base):
        h.wait_for_output(process, fd, output, b"Operator task", start=0, timeout=10)
        visible = frame(process, fd, output, "primary-work-with-unavailable-goal-links")
        assert b"Work:" in visible and b"Work: reading unavailable" not in visible, visible
        # Enter the palette only after it owns input, then navigate by name.
        h.send_and_wait(process, fd, output, b":", b"MASC Command palette")
        h.send_and_wait(process, fd, output, b"go Work", b"go Work")
        h.send_and_wait(process, fd, output, b"\r", goal["title"].encode())
        h.send_and_wait(process, fd, output, b"\r", b"Open tasks  (links unavailable)")
        unavailable = h.screen_text(bytes(output))
        assert b"(none)" not in unavailable, unavailable
        assert b"task-777" not in unavailable, unavailable
        path = Path(base) / ".masc" / "tasks" / "goal_task_links.json"
        path.write_text(json.dumps({"version": 1, "links": []}))
        h.send_and_wait(process, fd, output, b"r", b"Open tasks  (none)")
        repaired = h.screen_text(bytes(output))
        assert b"links unavailable" not in repaired, repaired
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    run(executable, "Planning owns unavailable Goal-link coverage beside a current Task backlog",
        fixtures, interact, requests, prepare=prepare)


def planning_backlog_failure_recovers(executable):
    fixtures = fixtures_with_held([])
    goal = h.planning_goal("goal-backlog-truth", "Planning backlog source fixture")
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([goal])
    fixtures["/api/v1/dashboard/goals/detail?goal_id=goal-backlog-truth"] = (200, {"timeline": []})
    requests = []

    def prepare(base):
        seed_operator_task(base)
        root = Path(base) / ".masc"
        (root / "tasks" / "backlog.json").write_text("{unreadable backlog")
        (root / "tasks" / "goal_task_links.json").write_text(json.dumps({"version": 1, "links": []}))

    def interact(process, fd, _slave, output, base):
        h.wait_for_output(process, fd, output, b"Operator tasks unavailable", start=0, timeout=10)
        h.send_and_wait(process, fd, output, b":", b"MASC Command palette")
        h.send_and_wait(process, fd, output, b"go Work", b"go Work")
        h.send_and_wait(process, fd, output, b"\r", goal["title"].encode())
        h.send_and_wait(process, fd, output, b"\r", b"Open tasks  (nothing here is a reading)")
        failed = h.screen_text(bytes(output))
        assert b"links not read" not in failed, failed
        assert b"Open tasks  (none)" not in failed, failed
        seed_operator_task(base)
        # An auxiliary archive error must not impersonate a primary failure.
        (Path(base) / ".masc" / "tasks-archive.json").write_text("{unreadable archive")
        h.send_and_wait(process, fd, output, b"r", b"Open tasks  (none)")
        repaired = h.screen_text(bytes(output))
        assert b"nothing here is a reading" not in repaired, repaired
        assert b"links not read" not in repaired, repaired
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    run(executable, "Planning prioritizes failed backlog and recovers on refresh",
        fixtures, interact, requests, prepare=prepare)


def recovered_tasks_are_not_current_cards(executable):
    fixtures = fixtures_with_held([])
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Operator tasks unavailable", start=0, timeout=10)
        visible = frame(process, fd, output, "operator-task-backup-reading")
        assert "Operator task ·".encode() not in visible, visible
        assert b"task-777" not in visible, visible
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    run(executable, "Home recovery-only task source cannot create a current task card",
        fixtures, interact, requests, prepare=lambda base: seed_operator_task(base, backup=True))


def refresh_identity_and_deletion(executable):
    rows = [held("call-refresh-a", "refresh-card-A"), held("call-refresh-b", "refresh-card-B")]
    fixtures = fixtures_with_held(rows)
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"refresh-card-B", start=0, timeout=10)
        select_home(process, fd, output, b"refresh-card-B", destinations=4)
        rows.insert(0, held("call-inserted", "inserted-card"))
        h.send_and_wait(process, fd, output, b"r", b"inserted-card")
        assert_selected(output, b"refresh-card-B")
        open_held_detail(process, fd, output, b"call-refresh-b",
                         b'{"command":"echo call-refresh-b"}')
        # A second insertion while the detail is open exercises mailbox-drain
        # reconciliation, not just Home's selected-row reconciliation.
        rows.insert(0, held("call-detail-inserted", "detail-inserted-card"))
        rows[-1]["args"] = '{"command":"echo refreshed-call-refresh-b"}'
        h.send_and_wait(process, fd, output, b"r", b"refreshed-call-refresh-b")
        detail = h.screen_text(bytes(output))
        assert re.search(rb"(?m)^\s*call\s+call-refresh-b\s*$", detail), detail
        assert re.search(rb'(?m)^\s*args\s+\{"command":"echo refreshed-call-refresh-b"\}\s*$', detail), detail
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        rows[:] = [row for row in rows if row["tool_call_id"] != "call-refresh-b"]
        h.send_and_wait(process, fd, output, b"r", b"Selection changed")
        result = h.send_and_wait(process, fd, output, b"\r", b"Selection changed")
        assert b"MASC Approvals" not in h.screen_text(result), result
        select_home(process, fd, output, b"refresh-card-A", destinations=5)
        open_held_detail(process, fd, output, b"call-refresh-a",
                         b'{"command":"echo call-refresh-a"}')
        # Deleting the currently opened authority must eject its detail.
        rows[:] = [row for row in rows if row["tool_call_id"] != "call-refresh-a"]
        h.send_and_wait(process, fd, output, b"r", b"Selection changed")
        result = h.send_and_wait(process, fd, output, b"\r", b"Selection changed")
        assert b"MASC Approvals" not in h.screen_text(result), result
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    run(executable, "Home refresh pins selected and opened authority and deletion requires reselect",
        fixtures, interact, requests)


def many_cards_keep_continuation(executable):
    rows = [held(f"call-window-{index:02}", f"window-card-{index:02}") for index in range(30)]
    fixtures = fixtures_with_held(rows)
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"window-card-00", start=0, timeout=10)
        h.send_and_wait(process, fd, output, b"i", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.palette_go(process, fd, output, b"go dashboard", b"Continue with beta")
        for label in (b"window-card-00", b"window-card-29"):
            select_home(process, fd, output, label, destinations=33)
            visible = frame(process, fd, output, "many-requests-initial")
            for required in (label, b"Continue with beta", b"New work", b"Enter:open"):
                assert required in visible, visible
            position = re.search(rb"rows (\d+)-(\d+)/(\d+)", visible)
            assert position, visible
            first, last, total = map(int, position.groups())
            assert 1 <= first <= last <= total == 31, visible
            index = 1 if label.endswith(b"00") else 30
            assert first <= index <= last, visible
            if index == 1:
                h.send_and_wait(process, fd, output, b"j", selected(b"Held call"))
                within_window = frame(process, fd, output, "many-requests-selected")
                assert position.group() in within_window, within_window
        retained_position = position.group()
        open_held_detail(process, fd, output, b"call-window-29",
                         b'{"command":"echo call-window-29"}')
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        assert_selected(output, b"window-card-29")
        assert retained_position in frame(process, fd, output, "many-requests-return")
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    run(executable, "Home 80x24 windows many cards and retains Continue new work and position",
        fixtures, interact, requests)


def goal_opens_exact_detail(executable):
    fixtures = fixtures_with_held([])
    goal = dict(h.planning_goal("goal-home-exact", "Exact goal confirmation"),
                phase="awaiting_confirmation", criterion_revision="r1",
                created_at="2026-09-28T00:00:00Z", updated_at="2026-09-29T00:00:00Z")
    other = dict(h.planning_goal("goal-home-other", "Other goal confirmation"),
                 phase="awaiting_confirmation", criterion_revision="r1",
                 created_at=goal["created_at"], updated_at=goal["updated_at"])
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([other, goal])
    stored_goals = [
        {key: value for key, value in row.items()
         if key not in ("verification", "verifier_unreconciled")}
        for row in (other, goal)
    ]
    requests = []

    def interact(process, fd, _slave, output, base):
        path = Path(base) / ".masc" / "goals.json"
        before = path.read_bytes()
        h.wait_for_output(process, fd, output, b"Confirm Goal", start=0, timeout=10)
        select_home(process, fd, output, b"goal-home-exact", destinations=3)
        h.send_and_wait(process, fd, output, b"\r", b"Exact goal confirmation")
        visible = h.screen_text(bytes(output))
        assert b"goal-home-exact" in visible and b"metric-goal-home-exact" in visible, visible
        assert b"metric-goal-home-other" not in visible, visible
        # Stable phase/priority ordering is [other, exact]. The initial Planning
        # cursor is zero; Home must bind it to exact before relative navigation.
        h.send_and_wait(process, fd, output, b"[", b"Other goal confirmation")
        visible = h.screen_text(bytes(output))
        assert b"metric-goal-home-other" in visible, visible
        h.send_and_wait(process, fd, output, b"]", b"Exact goal confirmation")
        assert b"metric-goal-home-exact" in h.screen_text(bytes(output))
        assert path.read_bytes() == before
        home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        os.write(fd, b"q")

    run(executable, "Home Goal card opens the same Goal detail without mutation",
        fixtures, interact, requests, prepare=lambda base: home.seed_goals(base, stored_goals))


def question_identity_and_return(executable):
    fixtures = fixtures_with_held([])
    status, response = copy.deepcopy(h.keeper_asks_response())
    first = response["asks"][0]
    first["questions"].append(dict(first["questions"][0], question_id="q-extra",
                                    prompt="second question in the same request"))
    second = copy.deepcopy(first)
    second.update(ask_id="ask-home-other", context="other-question-card")
    second["questions"] = [dict(first["questions"][0], question_id="q-other",
                                 prompt="exact other request prompt")]
    response.update(open_count=3, asks=[first, second, copy.deepcopy(first)])
    current = [(status, response)]
    fixtures[h.KEEPER_ASKS_PATH] = lambda: copy.deepcopy(current[0])
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Approvals and questions: 2 need you", start=0, timeout=10)
        visible = frame(process, fd, output, "question-cards")
        assert visible.count(b"Question ") == 2, visible
        assert b"Approvals and questions: 2 need you" in visible, visible
        select_home(process, fd, output, b"other-question-card", destinations=4)
        h.send_and_wait(process, fd, output, b"\r", b"exact other request prompt")
        # Esc leaves answering and returns directly to the Home reference.
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        assert_selected(output, b"other-question-card")
        h.send_and_wait(process, fd, output, b"\r", b"exact other request prompt")
        # Bracket explicitly changes the answering request and releases the
        # Home reference. Reordering must then retain that new ask ID.
        h.send_and_wait(process, fd, output, b"[", b"ship the cold-start change now?")
        reordered = copy.deepcopy(response)
        pinned = reordered["asks"][0]
        pinned["questions"][0]["prompt"] = "refreshed pinned ask-one prompt"
        reordered["asks"] = [reordered["asks"][1], pinned]
        reordered["open_count"] = 2
        current[0] = (200, reordered)
        h.wait_for_output(process, fd, output, b"refreshed pinned ask-one prompt",
                          start=len(output), timeout=5)
        drawn = h.send_and_wait(process, fd, output, b"1", b"1 answered")
        assert b"1 (o) c-yes" in h.screen_text(drawn)
        home.assert_no_decision_posts(requests)
        current[0] = (503, {"error": "question source offline"})
        h.wait_for_output(process, fd, output, b"questions stale", start=len(output), timeout=5)
        h.send_and_wait(process, fd, output, b"\r", b"Question source unavailable")
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    run(executable, "Home unique ask IDs direct Esc bracket reorder and failed-source submit refusal",
        fixtures, interact, requests, refresh=1.0)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    for scenario in (same_keeper_distinct_and_duplicate, failed_source_keeps_known_cards,
                     each_failed_source_keeps_other_cards, hidden_help_does_not_pin_unseen_request,
                     operator_task_survives_supplemental_failure, planning_link_failure_has_own_diagnostic,
                     planning_backlog_failure_recovers,
                     recovered_tasks_are_not_current_cards,
                     refresh_identity_and_deletion, many_cards_keep_continuation,
                     goal_opens_exact_detail, question_identity_and_return):
        scenario(executable)
    print("Home decision cards PTY: PASS")
