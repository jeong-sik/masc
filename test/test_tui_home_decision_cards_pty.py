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

import test_tui_home_journey_pty as home
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml", "bin/masc_tui_types.ml", "bin/masc_tui_render.ml",
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
        h.wait_for_output(process, fd, output, b"[call-home-b]", start=0, timeout=10)
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
        detail = h.send_and_wait(process, fd, output, b"\r", b"call-home-b")
        assert b"echo call-home-b" in h.screen_text(detail), detail
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
        h.send_and_wait(process, fd, output, b"\r", b"call-refresh-b")
        # A second insertion while the detail is open exercises mailbox-drain
        # reconciliation, not just Home's selected-row reconciliation.
        rows.insert(0, held("call-detail-inserted", "detail-inserted-card"))
        rows[-1]["args"] = '{"command":"echo refreshed-call-refresh-b"}'
        h.send_and_wait(process, fd, output, b"r", b"refreshed-call-refresh-b")
        detail = h.screen_text(bytes(output))
        assert b"call-refresh-b" in detail and b"echo refreshed-call-refresh-b" in detail, detail
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        rows[:] = [row for row in rows if row["tool_call_id"] != "call-refresh-b"]
        h.send_and_wait(process, fd, output, b"r", b"Selection changed")
        result = h.send_and_wait(process, fd, output, b"\r", b"Selection changed")
        assert b"MASC Approvals" not in h.screen_text(result), result
        select_home(process, fd, output, b"refresh-card-A", destinations=5)
        h.send_and_wait(process, fd, output, b"\r", b"call-refresh-a")
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
        h.send_and_wait(process, fd, output, b"\r", b"call-window-29")
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
    goal["priority"] = 2
    adjacent = dict(h.planning_goal("goal-home-next", "Next Work goal"),
                    phase="awaiting_confirmation", priority=3)
    hidden = dict(h.planning_goal("goal-home-hidden", "Completed hidden goal"),
                  phase="completed", priority=0)
    # Work filters and sorts this raw order to other -> Home target -> adjacent.
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([adjacent, hidden, goal, other])
    requests = []

    def interact(process, fd, _slave, output, base):
        path = Path(base) / ".masc" / "goals.json"
        before = path.read_bytes()
        h.wait_for_output(process, fd, output, b"Confirm Goal", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go Work", b"Other goal confirmation")
        h.send_and_wait(process, fd, output, b"\r", b"metric-goal-home-other")
        assert b"metric-goal-home-other" in h.screen_text(bytes(output))
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        h.send_and_wait(process, fd, output, b"\x1b", b"Confirm Goal")
        select_home(process, fd, output, b"goal-home-exact", destinations=3)
        h.send_and_wait(process, fd, output, b"\r", b"Exact goal confirmation")
        visible = h.screen_text(bytes(output))
        assert b"goal-home-exact" in visible and b"metric-goal-home-exact" in visible, visible
        assert b"metric-goal-home-other" not in visible, visible
        for key, goal_id in ((b"]", b"goal-home-next"),
                             (b"[", b"goal-home-exact"),
                             (b"[", b"goal-home-other")):
            h.send_and_wait(process, fd, output, key, b"metric-" + goal_id)
            # Redraw also exercises reconciliation after releasing the Home pin.
            for columns in (81, 80):
                h.resize_and_wait(process, fd, output, rows=24, columns=columns,
                                  needle=b"metric-" + goal_id,
                                  controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            visible = h.screen_text(bytes(output))
            assert b"metric-" + goal_id in visible, visible
            for other_id in (b"goal-home-exact", b"goal-home-next", b"goal-home-other"):
                if other_id != goal_id:
                    assert b"metric-" + other_id not in visible, visible
        assert path.read_bytes() == before
        home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        os.write(fd, b"q")

    run(executable, "Home Goal syncs a stale Work cursor and brackets follow visible adjacent IDs",
        fixtures, interact, requests, prepare=lambda base: home.seed_goals(base, [other, goal]))


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
        h.wait_for_output(process, fd, output, b"other-question-card", start=0, timeout=10)
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
        h.send_and_wait(process, fd, output, b"1", re.compile(rb"\(o\) (?:\x1b\[[0-9;:]*m)*c-yes"))
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
                     refresh_identity_and_deletion, many_cards_keep_continuation,
                     goal_opens_exact_detail, question_identity_and_return):
        scenario(executable)
    print("Home decision cards PTY: PASS (6 scenarios)")
